--[[
Copyright (C) 2026 finlater and contributors (weread.koplugin, AGPL-3.0)
Copyright (C) 2026 weread.nvim contributors

The payload shapes below follow
https://github.com/QiuYukang/weread.koplugin (weread/lib/read_report.lua and
weread/lib/protocol.lua).

weread.nvim is free software: you can redistribute it and/or modify it under
the terms of the GNU Affero General Public License as published by the Free
Software Foundation, either version 3 of the License, or (at your option) any
later version.
]]

--[[
Reading progress and time reporting.

WeRead has no official write endpoint, so the browser's own call is reproduced:
`POST /web/book/read` with a signed body, sent when entering the reader and
periodically while reading. Everything here is best effort: failing to report
must never disturb reading.
(微信读书没有官方的写入接口，因此复刻浏览器自己的调用：签名后的 POST
 /web/book/read，进入阅读器时发一次、阅读中按间隔发。这里一切都是「尽力而为」，
 上报失败绝不能影响阅读)

`sg` deserves a note: it is `sha256(ts .. rn .. token)` where the token comes
from the chapter's reader page. When the page did not yield one, the well known
default token is used, which is what the app shipped for years.
(`sg` = sha256(ts .. rn .. token)，token 来自章节阅读器页面；页面没给出时使用
 广为流传的默认 token)
]]

local P = require("weread.protocol")
local config = require("weread.config")
local http = require("weread.http")
local cache = require("weread.cache")
local log = require("weread.log")

local M = {}

local READ_URL = "/web/book/read"

---Seconds a reader context (psvts/pclts/token) is trusted before it is fetched
---again, and the minimum gap between two cookie renewals. Both follow the
---reference client.
---(阅读上下文（psvts/pclts/token）在多少秒内可信、两次续期 cookie 至少间隔多久。
--- 两个数值都沿用参考实现)
local CONTEXT_TTL = 15 * 60
local RENEWAL_COOLDOWN = 10 * 60

---A push is preceded by a pull when the last pull is older than this: the
---phone may have moved on while this window sat still.
---(上一次拉取早于这么多秒时，先拉再推：这个窗口静止时手机可能已经往后读了)
local PULL_BEFORE_PUSH = 60

---Longest `:qa` may wait for the final report, and the curl `--max-time` (whole
---seconds, so rounded up) it is sent with.
---(`:qa` 最多为最后一次上报等多久，以及随请求带上的 curl `--max-time`（整秒，所以向上取整）)
local EXIT_BUDGET_MS = 1500
local EXIT_REQUEST_TIMEOUT = 2

---Declared ahead: the report pipeline settles reading time through it.
---(提前声明：上报管线要通过它结算阅读时长)
local accumulate

local state = require("weread.progress_state")
local Remote = require("weread.progress_remote")

---Identity of a reading position, as the service sees it.
---(阅读位置的标识，以服务端的视角)
local position_key = Remote.position_key

---@return string
function M.read_url()
  return require("weread.content").base_url() .. READ_URL
end

---@return boolean
function M.enabled()
  return (tonumber(config.get().sync_interval) or 0) > 0
end

---Seconds without a key press after which the reader counts as away.
---(多少秒没有按键就算读者离开了)
---@return integer
local function idle_limit()
  return math.max(10, tonumber(config.get().sync_idle) or 120)
end

---Is someone at the keyboard right now?
---(此刻有人在键盘前吗？)
---@return boolean
function M.active()
  return vim.uv.now() - (state.last_input or 0) < idle_limit() * 1000
end

---Note a key press or a cursor move. Coming back after a long pause is the
---moment the phone may have moved on, so that one also asks the service.
---(记一次按键或光标移动。长时间停顿之后回来，正是手机可能已经往后读了的时刻，因此那一次
--- 还会去问一下服务端)
function M.touch()
  local now = vim.uv.now()
  local away = now - (state.last_input or 0) >= idle_limit() * 1000
  if away and accumulate then
    -- settle the time up to the moment the reader left, before the clock moves
    -- (在时钟前移之前，把时长结算到读者离开的那一刻)
    accumulate(require("weread.reader").buffer_info() ~= nil)
  end
  state.last_input = now
  if away then
    vim.schedule(function()
      M.poll({ force = true })
    end)
  end
end

---Character offset of the cursor in the *rendered* buffer. Only a fallback for
---a chapter without an offset map: the apps count in source runes.
---(光标在**渲染后** buffer 里的字符偏移。只是没有偏移表时的退路：各端用的是源 rune)
---@param buf integer
---@param win integer
---@return integer
local function rendered_offset(buf, win)
  local cursor_line = vim.api.nvim_win_get_cursor(win)[1]
  local cursor_col = vim.api.nvim_win_get_cursor(win)[2]
  local lines = vim.api.nvim_buf_get_lines(buf, 0, cursor_line - 1, false)
  local chars = 0
  for _, line in ipairs(lines) do
    chars = chars + vim.fn.strchars(line) + 1
  end
  local current = vim.api.nvim_buf_get_lines(buf, cursor_line - 1, cursor_line, false)[1] or ""
  chars = chars + vim.fn.strchars(current:sub(1, cursor_col))
  return chars
end

---Where the cursor is, in the coordinates the WeRead apps use.
---(光标位置，用微信读书各端的坐标表示)
---@param reader table
---@param buf integer
---@param win integer
---@return integer offset
---@return number|nil fraction share of the chapter before the cursor(光标之前占本章的比例)
local function cursor_position(reader, buf, win)
  local offset, runes = nil, nil
  if reader.source_offset then
    offset, runes = reader.source_offset(buf, win)
  end
  if offset then
    local fraction = (runes and runes > 0) and (offset / runes) or nil
    return offset, fraction
  end
  local line = vim.api.nvim_win_get_cursor(win)[1]
  local count = vim.api.nvim_buf_line_count(buf)
  return rendered_offset(buf, win), count > 1 and (line - 1) / (count - 1) or 0
end

---Text near the cursor, used for the "where are you" summary field.
---(光标附近的文本，用于定位摘要字段)
---@param buf integer
---@param win integer
---@return string
local function summary_at_cursor(buf, win)
  local cursor_line = vim.api.nvim_win_get_cursor(win)[1]
  local line = vim.api.nvim_buf_get_lines(buf, cursor_line - 1, cursor_line, false)[1] or ""
  -- markdown syntax and the page's own padding would end up in the summary
  -- (markdown 语法与页面自己的缩进/补白会混进摘要)
  -- `[%s　]` would be a byte class that also eats the lead bytes of `《`
  -- (`[%s　]` 是字节类，会连带吃掉 `《` 的前导字节)
  local function strip_white(text)
    local before
    repeat
      before = text
      text = text:gsub("^%s+", ""):gsub("^　", "")
    until text == before
    return text
  end
  line = strip_white(line):gsub("^#+%s*", ""):gsub("^>%s*", ""):gsub("^%-%s*", "")
  line = line:gsub("[%*_`]", "")
  return vim.trim(strip_white(line))
end

---Percentage of the book the reader has reached.
---(已读到全书的百分之几)
---@param info table buffer marker
---@param fraction number|nil
---@return integer
local function book_progress(info, fraction)
  local ok, percent = pcall(function()
    return require("weread.shell").book_percent(info.chapter_index, fraction or 0)
  end)
  return ok and percent or 0
end

---Build a read payload from the current buffer. Pure apart from reading the
---buffer and the clock, so tests can drive it directly.
---(根据当前 buffer 构造上报负载；除读 buffer 与时钟外无副作用，便于测试直接驱动)
---@param reader table
---
---`buf`/`win` name a chapter window that is not the current one: the editor may
---be closing from a sidebar while the book is still open next to it.
---(`buf`/`win` 指定一个不是当前窗口的章节窗口：编辑器可能是从侧边栏里退出的，而书还开在旁边)
---@param opts table|nil { elapsed_seconds, now, ts, rn, buf, win }
---@return table|nil payload
---@return string|nil error
function M.build_payload(reader, opts)
  opts = opts or {}
  local win = opts.win or vim.api.nvim_get_current_win()
  if not vim.api.nvim_win_is_valid(win) then
    return nil, "当前 buffer 不是微信读书章节"
  end
  local buf = opts.buf or vim.api.nvim_win_get_buf(win)
  if vim.api.nvim_win_get_buf(win) ~= buf then
    return nil, "当前 buffer 不是微信读书章节"
  end
  local info = reader.buffer_info(buf)
  if not info then
    return nil, "当前 buffer 不是微信读书章节"
  end

  local session = reader.state
  local book = session.book
  if book and tostring(book.book_id) ~= tostring(info.book_id) then
    -- a chapter of another book than the one loaded: its context would sign
    -- the wrong book
    -- (不是当前载入那本书的章节：用它的上下文签名会签错书)
    return nil, "章节不属于当前书"
  end
  local chapter = ((session.catalog or {}).chapters or {})[info.chapter_index]
  if not book or not chapter then
    return nil, "缺少书籍或章节信息"
  end

  local offset, fraction = cursor_position(reader, buf, win)
  return {
    book_id = info.book_id,
    chapter_uid = tostring(chapter.chapterUid),
    chapter_idx = tonumber(chapter.chapterIdx) or info.chapter_index,
    chapter_offset = offset,
    progress = book_progress(info, fraction),
    summary = summary_at_cursor(buf, win),
    psvts = book.psvts,
    pclts = book.pclts,
    token = book.token,
    elapsed_seconds = math.max(0, math.floor(opts.elapsed_seconds or 0)),
    now = opts.now or os.time(),
    ts = opts.ts,
    rn = opts.rn,
  }
end

---Did the service take the report? `succ` is the documented answer, but an
---answer that only carries a `synckey` is an accepted report too.
---(服务端收下这次上报了吗？`succ` 是明文的回答，但只带 `synckey` 的回答同样表示已收下)
---@param data table|nil
---@return boolean
local function accepted(data)
  if type(data) ~= "table" then
    return false
  end
  if P.is_success_response(data) then
    return true
  end
  return data.synckey ~= nil and data.errCode == nil and data.errcode == nil
end
M.accepted = accepted

---Request options for a read report.
---(一次阅读上报的请求选项)
---@param body table
---@param payload table
---@param timeout integer
---@param retries integer
---@return table
local function read_request(body, payload, timeout, retries)
  return {
    url = M.read_url(),
    method = "POST",
    json = true,
    body = body,
    referer = require("weread.content").reader_url(payload.book_id, payload.chapter_uid),
    timeout = timeout,
    retries = retries,
    -- a report sent twice counts the reading time twice (上报发两次，阅读时长就记两次)
    write = true,
  }
end

---Bookkeeping after the service took a report.
---(服务端收下上报之后的记账)
---@param payload table
local function record_success(payload)
  state.last_error = nil
  state.synced_at[tostring(payload.book_id)] = os.time()
  state.last_report_at = os.time()
  state.last_position = position_key(payload)
end

---POST the payload. Never raises: reporting is best effort.
---(POST 负载；绝不抛异常：上报只是尽力而为)
---@param payload table
---@param callback fun(ok: boolean, err: string|nil, rejected: boolean|nil)|nil
function M.report(payload, callback)
  callback = callback or function() end
  local body = P.make_read_payload(payload)

  http.request(read_request(body, payload, 15, 1), function(res)
    local data = http.decode_json(res)
    if not data then
      state.last_error = res.error or "上报请求失败"
      log.warn("progress report failed: %s", tostring(state.last_error))
      callback(false, state.last_error, false)
      return
    end
    if not accepted(data) then
      local message = require("weread.auth").describe_error(data) or "上报被拒绝"
      state.last_error = message
      log.warn("progress report rejected: %s", message)
      callback(false, message, true)
      return
    end
    record_success(payload)
    log.info("progress reported (chapter %s, %d%%)", payload.chapter_uid, payload.progress)
    callback(true, nil, nil)
  end)
end

---Tell the service a reading session starts here: the web reader does this
---once before its periodic reports, and the reference client does the same.
---(告诉服务端这里开始了一次阅读：网页阅读器在定期上报之前先发一次，参考实现同样如此)
---@param payload table
---@param callback fun()
local function send_enter(payload, callback)
  local body = P.make_enter_read_payload(payload)
  http.request(read_request(body, payload, 15, 0), function(res)
    local data = http.decode_json(res)
    if accepted(data) then
      state.entered[tostring(payload.book_id)] = true
    else
      log.debug("enter handshake not accepted: %s", tostring(res and res.body))
    end
    callback()
  end)
end

---Refresh the psvts/pclts/token a report signs with. They are issued per
---reader page and rotate; a book loaded from the cache carries hours-old ones,
---which is exactly when the service answers a well formed report with a
---rejection.
---(刷新上报所用的 psvts/pclts/token。它们由阅读页逐次下发且会轮换；从缓存载入的书
--- 携带的可能是几小时前的值——服务端正是用「拒绝一个格式无误的上报」来回应这种情况)
---@param book_id string
---@param callback fun(ok: boolean)
local function refresh_context(book_id, callback)
  local reader = require("weread.reader")
  require("weread.content").fetch_reader_state(book_id, nil, { timeout = 15 }, function(ok, st)
    local book = reader.state and reader.state.book
    if ok and book and tostring(book.book_id) == tostring(book_id) then
      book.psvts = st.psvts or book.psvts
      book.pclts = st.pclts or book.pclts
      book.token = st.token or book.token
      book.updated_at = os.time()
      pcall(cache.write_meta, book_id, book)
      state.context_at[tostring(book_id)] = os.time()
      -- a new context is a new session as far as the service is concerned
      -- (对服务端来说，新的上下文就是新的会话)
      state.entered[tostring(book_id)] = nil
      log.info("reader context refreshed for %s", tostring(book_id))
    end
    callback(ok == true)
  end)
end

---Make sure the context is fresh and the session announced before a report.
---(上报之前确保上下文新鲜、会话已经宣告)
---@param reader table
---@param book_id string
---@param opts table build options
---@param callback fun()
local function prepare(reader, book_id, opts, callback)
  local function handshake()
    if state.entered[book_id] then
      callback()
      return
    end
    local payload = M.build_payload(reader, opts) or opts.snapshot
    if not payload then
      callback()
      return
    end
    send_enter(payload, callback)
  end
  local fetched = state.context_at[book_id]
  if fetched and os.time() - fetched < CONTEXT_TTL then
    handshake()
    return
  end
  refresh_context(book_id, function()
    -- a failed refresh is not fatal: the cached context may still be good
    -- (刷新失败不致命：缓存里的上下文也许仍然可用)
    state.context_at[book_id] = state.context_at[book_id] or os.time()
    handshake()
  end)
end

---Renew the session cookies, at most once per cooldown.
---(续期会话 cookie，冷却期内至多一次)
---@param callback fun(ok: boolean)
local function renew_session(callback)
  if state.renewed_at and os.time() - state.renewed_at < RENEWAL_COOLDOWN then
    callback(false)
    return
  end
  state.renewed_at = os.time()
  require("weread.auth").renew(function(ok)
    callback(ok == true)
  end)
end

---Build, send, and on a rejection walk the recovery chain once: refresh the
---context and retry, then renew the session, refresh again and retry.
---(构造并发送；被拒时把恢复链走一遍：刷新上下文后重试，再续期会话、再刷新、再重试)
---@param reader table
---@param opts table build options
---@param callback fun(ok: boolean, err: string|nil)
local function send(reader, opts, callback)
  local payload = M.build_payload(reader, opts) or opts.snapshot
  if not payload then
    callback(false, "当前 buffer 不是微信读书章节")
    return
  end
  local book_id = tostring(payload.book_id)
  local function attempt(done)
    local fresh = M.build_payload(reader, opts) or payload
    -- a refreshed context belongs in the body even for a snapshot
    -- (即使是快照，刷新过的上下文也要写进 body)
    local book = reader.state and reader.state.book
    if fresh == payload and book and tostring(book.book_id) == tostring(payload.book_id) then
      fresh.psvts, fresh.pclts, fresh.token = book.psvts, book.pclts, book.token
    end
    M.report(fresh, done)
  end
  prepare(reader, book_id, opts, function()
    attempt(function(ok, err, rejected)
      if ok or not rejected then
        callback(ok, err)
        return
      end
      refresh_context(book_id, function()
        prepare(reader, book_id, opts, function()
          attempt(function(ok2, err2, rejected2)
            if ok2 or not rejected2 then
              callback(ok2, err2)
              return
            end
            renew_session(function(renewed)
              if not renewed then
                callback(false, err2)
                return
              end
              refresh_context(book_id, function()
                prepare(reader, book_id, opts, function()
                  attempt(function(ok3, err3)
                    callback(ok3, err3)
                  end)
                end)
              end)
            end)
          end)
        end)
      end)
    end)
  end)
end

---Queue a report. One is on the wire at a time; while it is, a newer request
---replaces whatever was waiting, so the service always ends on the latest
---position. The position is read when the report actually leaves, not when it
---was asked for.
---(把一次上报排进队列。同一时刻只有一个在路上；在路上时，更新的请求会替换正在等的那个，
--- 因此服务端最后停在的总是最新位置。位置在上报真正发出时才读取，而不是请求时)
---@param reader table
---@param opts table build options
---@param callback fun(ok: boolean, err: string|nil)|nil
local function dispatch(reader, opts, callback)
  callback = callback or function() end
  -- Bound to the chapter window it was asked from: a report that waits in the
  -- queue must not be lost because the reader switched to another window.
  -- (绑定到发起它的章节窗口：在队列里等着的上报，不能因为读者切到了别的窗口就丢掉)
  if not opts.win then
    opts.win = vim.api.nvim_get_current_win()
    opts.buf = vim.api.nvim_win_get_buf(opts.win)
  end
  -- and the place as it was when asked, for when that window is gone by then
  -- (以及请求时的位置，以防那时窗口已经不在了)
  opts.snapshot = opts.snapshot or M.build_payload(reader, opts)
  -- A chain that never called back (a crashed callback, a request that never
  -- returned) must not block every report after it.
  -- (从未回调的链（回调崩了、请求一去不回）不能挡住之后的所有上报)
  if state.inflight and state.inflight_since and vim.uv.now() - state.inflight_since > 90 * 1000 then
    log.warn("a progress report never finished; releasing the queue")
    state.inflight = false
  end
  if state.inflight then
    if state.queued then
      -- the replaced request still owes its caller an answer, and its reading
      -- time must not be lost
      -- (被替换的请求仍欠调用方一个回答，它的阅读时长也不能丢)
      local previous = state.queued
      opts.elapsed_seconds = (opts.elapsed_seconds or 0) + (previous.opts.elapsed_seconds or 0)
      local previous_callback = previous.callback
      local next_callback = callback
      callback = function(ok, err)
        previous_callback(ok, err)
        next_callback(ok, err)
      end
    end
    state.queued = { reader = reader, opts = opts, callback = callback }
    return
  end
  local token = {}
  state.inflight = token
  state.inflight_since = vim.uv.now()
  local finished = false
  local function done(ok, err)
    if finished then
      return
    end
    finished = true
    if state.inflight ~= token then
      -- Released by the watchdog: a newer chain owns the queue now. Only this
      -- caller's own answer is left to give.
      -- (已被看门狗放行：队列现在归更新的那条链。只剩回答自己的调用方)
      pcall(callback, ok, err)
      return
    end
    state.inflight = false
    if not ok and (opts.elapsed_seconds or 0) > 0 then
      -- nothing was credited: keep the time for the next report
      -- (什么都没记上：把时长留给下一次上报)
      state.pending_seconds = state.pending_seconds + opts.elapsed_seconds
    end
    pcall(callback, ok, err)
    local queued = state.queued
    state.queued = nil
    if queued then
      dispatch(queued.reader, queued.opts, queued.callback)
    end
  end
  local ok, raised = pcall(send, reader, opts, done)
  if not ok then
    log.warn("progress report raised: %s", tostring(raised))
    done(false, tostring(raised))
  end
end

---Note that a chapter was opened: reset the clock and report the position with
---zero reading time.
---(记录进入章节：重置计时并以 0 阅读时长上报一次位置)
---@param reader table
function M.enter(reader)
  if not M.enabled() then
    return
  end
  -- time read in the chapter just left belongs to that chapter's report
  -- (刚离开那一章读的时间，属于那一章的上报)
  local carried = accumulate(true)
  state.pending_seconds = 0
  local payload = M.build_payload(reader, { elapsed_seconds = 0 })
  if not payload then
    state.pending_seconds = carried
    return
  end
  M.cancel_debounce()
  dispatch(reader, { elapsed_seconds = carried })
end

---Fold the time since the last mark into the pending counter.
---(把距上次计时点的时间累加进待上报计数)
---`counting = false` advances the mark without crediting time, which is what
---happens while the user is somewhere else entirely: reading time should track
---time inside a chapter buffer, not nvim uptime. Time with nobody at the
---keyboard is not reading either.
---(counting = false 只推进计时点不记时：用户跑去干别的时不应计入阅读时长，
--- 阅读时长必须对应真正待在看章 buffer 里的时间。键盘前没人的时间也不算阅读)
---@param counting boolean
---@return integer pending_seconds
accumulate = function(counting)
  local now = vim.uv.now()
  if state.reported_at and counting then
    -- credit only up to the last sign of life plus the idle allowance
    -- (只计到最后一次有动静再加上空闲宽限为止)
    local until_ms = math.min(now, (state.last_input or now) + idle_limit() * 1000)
    local elapsed = math.floor((until_ms - state.reported_at) / 1000)
    if elapsed > 0 then
      state.pending_seconds = state.pending_seconds + elapsed
    end
  end
  state.reported_at = now
  return state.pending_seconds
end

-- ------------------------------------------------------------------ debounce

---A settled cursor is worth sending right away: waiting for the reading-time
---interval is what made another device sit 60 seconds behind. The report still
---carries the reading time accumulated so far, so nothing is lost.
---(光标停稳就值得立刻上报：等阅读时长的间隔，正是另一端落后 60 秒的原因。上报仍带上
--- 已累计的阅读时长，因此不丢数据)
---@param reader table
---@param opts table|nil { force = boolean, callback = fun(ok, err) }
---@return boolean reported
local function report_position(reader, opts)
  opts = opts or {}
  if not M.enabled() then
    return false
  end
  local info = reader.buffer_info()
  if info and M.deferred(info.book_id) then
    -- Another device is ahead and the reader has not followed yet. The cursor
    -- just settled: this is the quiet moment to follow it, instead of
    -- reporting this machine's place over it.
    -- (另一端领先，而读者还没跟过去。光标刚刚停稳：正是跟过去的安静时刻，而不是把本机的位置
    --  报上去盖掉它)
    M.follow_deferred()
    return false
  end
  local elapsed = accumulate(true)
  local payload = M.build_payload(reader, { elapsed_seconds = elapsed })
  if not payload then
    return false
  end
  if not opts.force and position_key(payload) == state.last_position then
    -- The position did not move since the last accepted report; the reading
    -- time stays pending for the interval timer to settle.
    -- (位置与上次被接受的上报一致；阅读时长留给定时器去结算)
    return false
  end
  state.pending_seconds = 0
  dispatch(reader, { elapsed_seconds = elapsed }, opts.callback)
  return true
end

---Restart the settle timer: every cursor move pushes "now" further away.
---(重启停稳计时：光标每动一次，「现在」就再推远一点)
function M.moved()
  M.touch()
  local seconds = tonumber(config.get().sync_debounce)
  if not seconds or seconds <= 0 or not M.enabled() then
    return
  end
  if state.debounce then
    require("weread.timer").stop(state.debounce)
    state.debounce = nil
  end
  state.debounce = require("weread.timer").defer(function()
    state.debounce = nil
    report_position(require("weread.reader"))
  end, seconds * 1000)
end

---Cancel a pending debounced report, e.g. because a remote jump is about to
---move the reader somewhere else.
---(取消待发的防抖上报，比如即将按远端进度跳转)
function M.cancel_debounce()
  if state.debounce then
    require("weread.timer").stop(state.debounce)
    state.debounce = nil
  end
end

---Accumulate reading time and report when enough has piled up.
---(累计阅读时长，攒够了就上报)
---
---This is the timer's report, and the timer also fires while nobody is
---reading. Re-sending the place this window has been sitting on would stamp it
---over whatever the phone uploaded in the meantime — so with the position
---unchanged, only time someone actually spent reading is worth a report.
---(这是定时器的上报，而定时器在没人读的时候也会触发。把这个窗口一直停着的位置再发一遍，
--- 就会把手机在此期间上传的进度盖掉——因此位置不变时，只有真有人读过的时长才值得上报)
---@param reader table
---@param opts table|nil { force = boolean }
---@return boolean reported
function M.tick(reader, opts)
  opts = opts or {}
  if not M.enabled() then
    return false
  end

  local counting = reader.buffer_info() ~= nil
  local pending = accumulate(counting)
  if not counting then
    return false
  end
  local interval = tonumber(config.get().sync_interval) or 60
  if not opts.force and not opts.settle and pending < interval then
    return false
  end
  if pending <= 0 and not opts.force then
    return false
  end

  local payload = M.build_payload(reader, { elapsed_seconds = pending })
  if not payload then
    return false
  end
  local book_id = tostring(payload.book_id)
  if M.deferred(book_id) then
    return false
  end
  state.pending_seconds = 0
  local stale = position_key(payload) == state.last_position
  if opts.force or not stale or not M.can_pull() then
    -- with no way to ask the other devices there is nothing to bury either
    -- (没办法问其它设备时，也就没有可埋掉的东西)
    dispatch(reader, { elapsed_seconds = pending })
    return true
  end
  -- Same place as last time: before stamping it again, ask whether another
  -- device has moved on. Only a clear "no" lets the report go out; a failed
  -- question keeps the time for later instead of guessing.
  -- (和上次同一个位置：再盖一次章之前，先问问别的设备有没有往后读。只有明确的「没有」才放行；
  --  问不出来就把时长留到以后，而不是去猜)
  M.pull(book_id, function(remote, err)
    local current = reader.current and reader.current()
    if not current or tostring(current.book.book_id) ~= book_id then
      state.pending_seconds = state.pending_seconds + pending
      return
    end
    if remote then
      log.info("remote progress newer than this window; following instead of reporting")
      state.pending_seconds = state.pending_seconds + pending
      reader.follow_remote(remote)
      return
    end
    if err then
      state.pending_seconds = state.pending_seconds + pending
      return
    end
    dispatch(reader, { elapsed_seconds = pending })
  end)
  return true
end

---Force a report of the current position now — focus lost, window left, editor
---closing.
---(立刻强制上报当前位置：失焦、离开窗口、退出编辑器)
function M.flush()
  M.cancel_debounce()
  local reader = require("weread.reader")
  -- a moved place goes out now; an unmoved one only settles its reading time,
  -- through the path that asks the other devices first
  -- (动过的位置立刻发出；没动的只结算阅读时长，并且走「先问其它设备」的那条路)
  if not report_position(reader) then
    accumulate(true)
    if state.pending_seconds > 0 then
      M.tick(reader, { settle = true })
    end
  end
end

---Same, but synchronous: the editor is closing and the request must complete
---before the process does. Best effort, capped at `EXIT_BUDGET_MS`.
---(同样的动作，但同步：编辑器正在退出，请求必须赶在进程结束前完成。尽力而为，上限为 `EXIT_BUDGET_MS`)
---@param target table|nil { buf, win } the chapter window to report, when it is not the current one
---@return boolean
function M.flush_sync(target)
  if not M.enabled() then
    return false
  end
  target = target or {}
  local reader = require("weread.reader")
  local opts = { elapsed_seconds = accumulate(true), buf = target.buf, win = target.win }
  local payload = M.build_payload(reader, opts)
  if not payload then
    return false
  end
  M.cancel_debounce()
  -- Leaving is not news when the place did not move, and must never bury a
  -- newer position from another device: `:qa` typed right after reading on the
  -- phone used to put this machine's old place back on the service.
  -- (位置没动时，退出不算新消息，更不能埋掉另一端更新的位置：在手机上读完回来直接 `:qa`，
  --  曾经会把本机的旧位置重新放回服务端)
  local book_id = tostring(payload.book_id)
  if M.deferred(book_id) then
    return false
  end
  local pulled = state.pulled_position
  if pulled and pulled.book_id == book_id and M.remote_is_newer(book_id, pulled) then
    return false
  end
  if position_key(payload) == state.last_position then
    log.info("final report skipped: the place did not move")
    return false
  end
  state.pending_seconds = 0
  -- One attempt, no recovery round: a rejected report (stale psvts/token) is
  -- given up on here instead of refreshing the context and posting again, since
  -- that second round used to hold `:qa` for several more seconds. The next
  -- start takes the service's position as the truth anyway. `vim.wait` inside
  -- `request_sync` returns the moment curl fails, so being offline does not
  -- spend the budget either.
  -- (只试一次，不走恢复流程：被拒（psvts/token 过期）就放弃，而不是刷新上下文再发一遍——
  --  第二轮曾让 `:qa` 多卡好几秒，反正下次启动以服务端位置为准。`request_sync` 里的
  --  `vim.wait` 在 curl 失败的瞬间就返回，所以离线时也不会耗尽预算)
  local fresh = M.build_payload(reader, opts) or payload
  local res = http.request_sync(
    read_request(P.make_read_payload(fresh), fresh, EXIT_REQUEST_TIMEOUT, 0),
    EXIT_BUDGET_MS
  )
  local data = http.decode_json(res)
  if not accepted(data) then
    state.last_error = (data and require("weread.auth").describe_error(data)) or res.error or "退出前上报失败"
    log.warn("final report failed: %s", tostring(state.last_error))
    return false
  end
  record_success(payload)
  log.info("final report sent (chapter %s, %d%%)", payload.chapter_uid, payload.progress)
  return true
end

---Called when a chapter buffer loses focus.
---(章节 buffer 失焦时调用)
---@param reader table
function M.leave(reader)
  if not M.enabled() then
    return
  end
  accumulate(true)
  if config.get().sync_on_leave then
    -- Only the time is settled here; the place is the one the next chapter's
    -- enter report carries, or the one already on record.
    -- (这里只结算时长；位置由下一章的 enter 上报带上，或者就是已经记下的那个)
    if state.pending_seconds > 0 then
      M.tick(reader, { settle = true })
    end
  end
end

---Report the reading position and time now.
---(立刻回传阅读进度与时长)
---
---`routine` marks the background timer's own report: that one lands in the middle
---of a page and says nothing a reader needs to act on, so `notify = "quiet"`
---(the default) keeps it out of the message area. A manual `<leader>ws` on the
---other hand is answered.
---(`routine` 表示这是后台定时器自己发的上报：它出现在页面正中，且没有读者需要处理的信息，
--- 因此 `notify = "quiet"`（默认）会把它挡在消息区之外；而手动 `<leader>ws` 则一定会得到回应)
---@param opts table|nil { routine = boolean }
function M.sync_now(opts)
  opts = opts or {}
  -- A plain call is manual: the timer is the one that marks itself.
  -- (不带参数的调用就是手动：只有定时器会给自己的调用打上标记)
  local routine = type(opts) == "table" and opts.routine == true
  local reader = require("weread.reader")
  local info = reader.buffer_info()
  if not info then
    require("weread.ui").notify("weread: 当前不在章节 buffer 中", vim.log.levels.WARN)
    return
  end
  if not M.enabled() then
    require("weread.ui").notify(
      "weread: 进度回传已关闭（setup 的 sync_interval = 0）",
      vim.log.levels.INFO,
      { routine = routine }
    )
    return
  end

  local payload = M.build_payload(reader, { elapsed_seconds = accumulate(true) })
  if not payload then
    vim.notify("weread: 无法构造上报数据", vim.log.levels.WARN)
    return
  end
  state.pending_seconds = 0
  dispatch(reader, { elapsed_seconds = payload.elapsed_seconds }, function(ok, err)
    if ok then
      -- a paper plane only for a manual send: the timer's are routine
      -- (只有手动回传才放纸飞机：定时器的回传是例行的)
      if not routine then
        require("weread.sprites").moment("plane", "进度已送出")
      end
      require("weread.ui").notify(
        string.format("weread: 已回传进度（第 %s 章，%d%%）", payload.chapter_uid, payload.progress),
        vim.log.levels.INFO,
        { routine = routine }
      )
    else
      vim.notify("weread: 进度回传失败：" .. tostring(err), vim.log.levels.WARN)
    end
  end)
end

---@return table
function M.status()
  return {
    enabled = M.enabled(),
    last_error = state.last_error,
    synced_at = state.synced_at,
    deferred = state.deferred,
    pending_seconds = state.pending_seconds,
    pulled_at = state.pulled_at,
    pulled_position = state.pulled_position,
    pull_error = state.pull_error,
    inflight = state.inflight,
    active = M.active(),
  }
end

-- ------------------------------------------------------------------ remote pull

-- The remote half lives in progress_remote.lua; re-exported so callers (and
-- tests) keep using `require("weread.progress")`.
-- (远端的那一半在 progress_remote.lua；这里重新导出，调用方（和测试）仍然用
--  `require("weread.progress")`)
M.can_pull = Remote.can_pull
M.remote_is_newer = Remote.remote_is_newer
M.pull = Remote.pull
M.deferred = Remote.deferred
M.defer = Remote.defer
M.undefer = Remote.undefer
M.follow_deferred = Remote.follow_deferred
M.adopted = Remote.adopted
M.poll = Remote.poll

-- ------------------------------------------------------------------ timer

local function stop_timer()
  require("weread.timer").stop(state.timer)
  state.timer = nil
  require("weread.timer").stop(state.pull_timer)
  state.pull_timer = nil
end

local function schedule()
  stop_timer()
  if not M.enabled() then
    return
  end
  local interval_ms = math.max(5000, (tonumber(config.get().sync_interval) or 60) * 1000)
  state.timer = require("weread.timer").every(function()
    -- Always tick: with a non-chapter buffer this only advances the clock so
    -- that time spent elsewhere is not credited as reading.
    -- (总是 tick：不在章节 buffer 时只推进计时点，不把别处的时间算作阅读)
    M.tick(require("weread.reader"))
  end, interval_ms)
  -- Terminals behind a multiplexer often never report focus changes, so the
  -- phone's progress is also checked on a slow clock while a chapter is open.
  -- (多路复用器后面的终端常常收不到焦点变化，因此章节打开时也按一个慢节奏去看手机的进度)
  local pull_seconds = tonumber(config.get().sync_pull_interval) or 120
  if pull_seconds > 0 and config.get().sync_pull ~= false then
    state.pull_timer = require("weread.timer").every(function()
      M.poll({ force = true })
    end, math.max(10, pull_seconds) * 1000)
  end
end

---Start or restart the reporting timer. Called by setup and after config changes.
---(启动/重启上报定时器；由 setup 调用)
function M.setup()
  schedule()
end

function M.stop()
  stop_timer()
end

---@return integer seconds of unreported reading time
function M.pending()
  return state.pending_seconds
end

---Forget per-session state. For tests.
---(忘掉会话级状态。供测试使用)
function M._reset()
  state.inflight = false
  state.queued = nil
  state.entered = {}
  state.context_at = {}
  state.renewed_at = nil
  state.last_position = nil
  state.synced_at = {}
  state.pulling = {}
  state.deferred = nil
  state.pending_seconds = 0
  state.last_input = vim.uv.now()
  state.last_poll = 0
end

return M
