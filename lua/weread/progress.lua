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
local log = require("weread.log")

local M = {}

local READ_URL = "/web/book/read"

local state = {
  reported_at = nil,
  pending_seconds = 0,
  timer = nil,
  last_error = nil,
  synced_at = nil,
}

---@return string
function M.read_url()
  return require("weread.content").base_url() .. READ_URL
end

---@return boolean
function M.enabled()
  return (tonumber(config.get().sync_interval) or 0) > 0
end

---Character offset of the cursor inside the chapter's text.
---(光标在章节正文中的字符偏移)
---@param buf integer
---@return integer
local function chapter_offset(buf)
  local cursor_line = vim.api.nvim_win_get_cursor(0)[1]
  local cursor_col = vim.api.nvim_win_get_cursor(0)[2]
  local lines = vim.api.nvim_buf_get_lines(buf, 0, cursor_line - 1, false)
  local chars = 0
  for _, line in ipairs(lines) do
    chars = chars + vim.fn.strchars(line) + 1
  end
  local current = vim.api.nvim_buf_get_lines(buf, cursor_line - 1, cursor_line, false)[1] or ""
  chars = chars + vim.fn.strchars(current:sub(1, cursor_col))
  return chars
end

---Text near the cursor, used for the "where are you" summary field.
---(光标附近的文本，用于定位摘要字段)
---@param buf integer
---@return string
local function summary_at_cursor(buf)
  local cursor_line = vim.api.nvim_win_get_cursor(0)[1]
  local line = vim.api.nvim_buf_get_lines(buf, cursor_line - 1, cursor_line, false)[1] or ""
  -- markdown syntax would end up in the summary; strip the obvious bits
  -- (markdown 语法会混进摘要，去掉显眼的部分)
  line = line:gsub("^#+%s*", ""):gsub("^>%s*", ""):gsub("^%-%s*", "")
  return vim.trim(line)
end

---Percentage of the book the reader has reached.
---(已读到全书的百分之几)
---@param reader table weread.reader module
---@param info table buffer marker
---@return integer
local function book_progress(reader, info)
  local position, total = reader.position_of(info.chapter_index)
  if total <= 1 then
    return 0
  end
  return math.floor((position - 1) / total * 100)
end

---Build a read payload from the current buffer. Pure apart from reading the
---buffer and the clock, so tests can drive it directly.
---(根据当前 buffer 构造上报负载；除读 buffer 与时钟外无副作用，便于测试直接驱动)
---@param reader table
---@param opts table|nil { elapsed_seconds, now, ts, rn }
---@return table|nil payload
---@return string|nil error
function M.build_payload(reader, opts)
  opts = opts or {}
  local buf = vim.api.nvim_get_current_buf()
  local info = reader.buffer_info(buf)
  if not info then
    return nil, "当前 buffer 不是微信读书章节"
  end

  local session = reader.state
  local book = session.book
  local chapter = ((session.catalog or {}).chapters or {})[info.chapter_index]
  if not book or not chapter then
    return nil, "缺少书籍或章节信息"
  end

  return {
    book_id = info.book_id,
    chapter_uid = tostring(chapter.chapterUid),
    chapter_idx = tonumber(chapter.chapterIdx) or info.chapter_index,
    chapter_offset = chapter_offset(buf),
    progress = book_progress(reader, info),
    summary = summary_at_cursor(buf),
    psvts = book.psvts,
    pclts = book.pclts,
    token = book.token,
    elapsed_seconds = math.max(0, math.floor(opts.elapsed_seconds or 0)),
    now = opts.now or os.time(),
    ts = opts.ts,
    rn = opts.rn,
  }
end

---POST the payload. Never raises: reporting is best effort.
---(POST 负载；绝不抛异常：上报只是尽力而为)
---@param payload table
---@param callback fun(ok: boolean, err: string|nil)|nil
function M.report(payload, callback)
  callback = callback or function() end
  local body = P.make_read_payload(payload)

  http.request({
    url = M.read_url(),
    method = "POST",
    json = true,
    body = body,
    referer = require("weread.content").reader_url(payload.book_id, payload.chapter_uid),
    timeout = 15,
    retries = 1,
  }, function(res)
    local data = http.decode_json(res)
    if not data then
      state.last_error = res.error or "上报请求失败"
      log.warn("progress report failed: %s", tostring(state.last_error))
      callback(false, state.last_error)
      return
    end
    if not P.is_success_response(data) then
      local message = require("weread.auth").describe_error(data) or "上报被拒绝"
      state.last_error = message
      log.warn("progress report rejected: %s", message)
      callback(false, message)
      return
    end
    state.last_error = nil
    state.synced_at = os.time()
    log.info("progress reported (chapter %s, %d%%)", payload.chapter_uid, payload.progress)
    callback(true, nil)
  end)
end

---Note that a chapter was opened: reset the clock and report the position with
---zero reading time.
---(记录进入章节：重置计时并以 0 阅读时长上报一次位置)
---@param reader table
function M.enter(reader)
  if not M.enabled() then
    return
  end
  state.reported_at = vim.uv.now()
  state.pending_seconds = 0

  local payload = M.build_payload(reader, { elapsed_seconds = 0 })
  if not payload then
    return
  end
  M.report(payload)
end

---Fold the time since the last mark into the pending counter.
---(把距上次计时点的时间累加进待上报计数)
---`counting = false` advances the mark without crediting time, which is what
---happens while the user is somewhere else entirely: reading time should track
---time inside a chapter buffer, not nvim uptime.
---(counting = false 只推进计时点不记时：用户跑去干别的时不应计入阅读时长，
--- 阅读时长必须对应真正待在看章 buffer 里的时间)
---@param counting boolean
---@return integer pending_seconds
local function accumulate(counting)
  local now = vim.uv.now()
  if state.reported_at and counting then
    local elapsed = math.floor((now - state.reported_at) / 1000)
    if elapsed > 0 then
      state.pending_seconds = state.pending_seconds + elapsed
    end
  end
  state.reported_at = now
  return state.pending_seconds
end

---Accumulate reading time and report when enough has piled up.
---(累计阅读时长，攒够了就上报)
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
  if not opts.force and pending < interval then
    return false
  end
  if pending <= 0 and not opts.force then
    return false
  end

  local payload = M.build_payload(reader, { elapsed_seconds = pending })
  if not payload then
    return false
  end
  state.pending_seconds = 0
  M.report(payload)
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
    M.tick(reader, { force = true })
  end
end

---Manual sync: `<leader>ws` / `:WeReadSync`.
---(手动同步)
function M.sync_now()
  local reader = require("weread.reader")
  local info = reader.buffer_info()
  if not info then
    vim.notify("weread: 当前不在章节 buffer 中", vim.log.levels.WARN)
    return
  end
  if not M.enabled() then
    vim.notify("weread: 进度回传已关闭（setup 的 sync_interval = 0）", vim.log.levels.INFO)
    return
  end

  local payload = M.build_payload(reader, { elapsed_seconds = accumulate(true) })
  if not payload then
    vim.notify("weread: 无法构造上报数据", vim.log.levels.WARN)
    return
  end
  state.pending_seconds = 0
  M.report(payload, function(ok, err)
    if ok then
      vim.notify(string.format("weread: 已回传进度（第 %s 章，%d%%）", payload.chapter_uid, payload.progress))
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
    pending_seconds = state.pending_seconds,
  }
end

-- ------------------------------------------------------------------ timer

local function stop_timer()
  if state.timer then
    pcall(vim.fn.timer_stop, state.timer)
    state.timer = nil
  end
end

local function schedule()
  stop_timer()
  if not M.enabled() then
    return
  end
  local interval_ms = math.max(5000, (tonumber(config.get().sync_interval) or 60) * 1000)
  state.timer = vim.defer_fn(function()
    state.timer = nil
    -- Always tick: with a non-chapter buffer this only advances the clock so
    -- that time spent elsewhere is not credited as reading.
    -- (总是 tick：不在章节 buffer 时只推进计时点，不把别处的时间算作阅读)
    M.tick(require("weread.reader"))
    schedule()
  end, interval_ms)
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

return M
