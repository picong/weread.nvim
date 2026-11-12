--[[
Tests for weread.progress: the payload shape, the read-report round trip and
the reading-time accounting.
(progress 单测：负载结构、上报往返、阅读时长结算)

The mock server verifies the signature *and* the `sg` hash, so a 200 here means
the body we sent was internally consistent, not merely well formed.
(mock 服务端同时校验签名与 sg 哈希，因此返回 200 说明我们发出去的 body 自洽，
 而不只是格式正确)
]]

local mock_lib = dofile(vim.fn.getcwd() .. "/tests/mock.lua")

local tmpdir = vim.fn.tempname()
vim.fn.mkdir(tmpdir, "p")

local FIXTURE = {
  token = nil, -- filled from the reader page during the test
}

---Recompute `sg` exactly like the plugin does, from the values in the body.
---(按插件同样的方式，用 body 里的值重算 sg)
local function sg_is_valid(body)
  local body_json = vim.json.decode(body)
  local crypto = require("weread.crypto")
  -- the enter report of the first chapter can land before the test reads the token
  -- (第一章的 enter 上报可能在测试读到 token 之前就到了)
  local token = FIXTURE.token or ((require("weread.reader").state.book or {}).token) or ""
  local expected = crypto.sha256_hex(tostring(body_json.ts) .. tostring(body_json.rn) .. token)
  if expected ~= body_json.sg then
    return false, string.format("sg mismatch: got %s, expected %s", tostring(body_json.sg), expected)
  end
  if tostring(body_json.rt) == nil then
    return false, "missing rt"
  end
  return true, ""
end

local read_reports = {}
local enter_reports = {}

local ref = {}
local routes = mock_lib.weread_routes(ref)
table.insert(routes, 1, {
  path = "/web/book/read",
  handler = function(_, _, body, headers)
    local signature_ok, signature_err = mock_lib.signature_is_valid(body)
    if not signature_ok then
      return { status = 400, ctype = "text/plain", body = "bad signature: " .. signature_err }
    end
    -- the enter handshake carries no reading time, hence no sg
    -- (enter 握手不带阅读时长，因此没有 sg)
    if not vim.json.decode(body).sg then
      enter_reports[#enter_reports + 1] = body
      return { status = 200, ctype = "application/json", body = '{"succ":1}' }
    end
    local sg_ok, sg_err = sg_is_valid(body)
    if not sg_ok then
      return { status = 400, ctype = "text/plain", body = "bad sg: " .. sg_err }
    end
    read_reports[#read_reports + 1] = { body = body, headers = headers }
    if body:find('"rt":-1', 1, true) then
      return { status = 200, ctype = "application/json", body = '{"errCode":-2012,"errMsg":"登录超时"}' }
    end
    return { status = 200, ctype = "application/json", body = '{"succ":1,"synckey":12345}' }
  end,
})

local server = mock_lib.start(routes)
ref.url = server.url

local config = require("weread.config")
local http = require("weread.http")
local cache = require("weread.cache")
local reader = require("weread.reader")
local progress = require("weread.progress")

config.setup({ data_dir = tmpdir, base_url = server.url, proxy = "direct", sync_interval = 60, keymaps = false })
config.ensure_dirs()
http.setup({ jar = config.path("cookies.txt"), tmpdir = config.path("tmp"), timeout = 8, retries = 0, proxy = "direct" })
http.set_cookies({
  { name = "wr_skey", value = "skey", domain = ".weread.qq.com", path = "/", expires = 0, include_subdomains = true },
})

local BOOK_ID = "43208843"
local unpack_values = table.unpack or unpack

local function await_async(runner, timeout)
  local captured
  local done = false
  runner(function(...)
    captured = { n = select("#", ...), ... }
    done = true
  end)
  vim.wait(timeout or 20000, function()
    return done
  end, 20)
  if not captured then
    error("timed out waiting for the callback")
  end
  return unpack_values(captured, 1, captured.n)
end

local function notifications(fn)
  local captured = {}
  local original = vim.notify
  vim.notify = function(message)
    captured[#captured + 1] = message
  end
  local ok, err = pcall(fn)
  vim.notify = original
  if not ok then
    error(err)
  end
  return captured
end

---Wait long enough for async work to land, without asserting anything.
---(等异步工作落地，不做断言)
local function settle(ms)
  vim.wait(ms or 900, function()
    return false
  end, 50)
end

---Load the book and open chapter 2 so the buffer is a real chapter buffer.
---Entering a chapter sends an enter-report, so callers must settle before
---counting traffic.
---(打开章节会发一次 enter 上报，因此调用方要先 settle 再统计流量)
local function open_chapter()
  await_async(function(cb)
    reader.load_book(BOOK_ID, cb)
  end)
  reader.open_index(2, {})
  vim.wait(20000, function()
    return reader.buffer_info() ~= nil
  end, 50)
  settle()
  read_reports = {}
  return reader.buffer_info()
end

describe("progress.build_payload", function()
  it("describes the current position", function()
    local info = open_chapter()
    FIXTURE.token = reader.state.book.token

    -- locate the paragraph instead of hardcoding a line: the layout changes
    -- (章节标题是否出现在正文里) must not break this
    -- (按内容定位而不是写死行号：版式变化不该弄坏这个测试)
    local lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)
    local target = nil
    for index, line in ipairs(lines) do
      if line:find("汪淼把车停在楼下", 1, true) then
        target = index
        break
      end
    end
    truthy(target, "the paragraph is in the buffer")
    vim.api.nvim_win_set_cursor(0, { target, 0 })
    local payload, err = progress.build_payload(reader, { elapsed_seconds = 30 })
    truthy(payload, tostring(err))
    eq(payload.book_id, info.book_id)
    eq(payload.chapter_uid, "2")
    eq(payload.chapter_idx, 2)
    eq(payload.elapsed_seconds, 30)
    eq(payload.psvts, reader.state.book.psvts)
    truthy(payload.token, "token carried for the sg hash")
    -- The offset must grow as the cursor moves down; asserting "> 0" would
    -- depend on how many lines happen to precede the paragraph.
    -- (偏移应随光标下移而增大；断言 "> 0" 会依赖段落前面恰好有几行)
    local first_offset = payload.chapter_offset
    vim.api.nvim_win_set_cursor(0, { vim.api.nvim_buf_line_count(0), 0 })
    local later = progress.build_payload(reader, { elapsed_seconds = 30 })
    truthy(later.chapter_offset > first_offset, "a later position has a larger offset")
    vim.api.nvim_win_set_cursor(0, { target, 0 })
    matches(payload.summary, "汪淼把车停在楼下")
    falsy(payload.summary:find("^　"), "no page indent in the summary")
    truthy(payload.progress >= 0 and payload.progress <= 100)
  end)

  it("reports the offset in source runes, the coordinate the apps use", function()
    local info = reader.buffer_info()
    local chapter = reader.state.catalog.chapters[info.chapter_index]
    local source = table.concat(vim.fn.readfile(cache.chapter_file(BOOK_ID, chapter, "xhtml"), "b"), "\n")
    local byte = source:find("汪淼把车停在楼下", 1, true)
    truthy(byte, "the sentence is in the chapter source")
    local expected = vim.str_utfindex(source:sub(1, byte - 1), "utf-32")

    local target = nil
    for index, line in ipairs(vim.api.nvim_buf_get_lines(0, 0, -1, false)) do
      local col = line:find("汪淼把车停在楼下", 1, true)
      if col then
        target = { index, col - 1 }
        break
      end
    end
    vim.api.nvim_win_set_cursor(0, target)
    local payload = progress.build_payload(reader, {})
    eq(payload.chapter_offset, expected, "co is the sentence's rune index in the XHTML, not a buffer offset")
  end)

  it("counts the share of the current chapter in the book percentage", function()
    vim.api.nvim_win_set_cursor(0, { 1, 0 })
    local top = progress.build_payload(reader, {}).progress
    vim.api.nvim_win_set_cursor(0, { vim.api.nvim_buf_line_count(0), 0 })
    local bottom = progress.build_payload(reader, {}).progress
    truthy(bottom > top, string.format("reading further into the chapter raises the percentage (%d -> %d)", top, bottom))
  end)

  it("refuses to build a payload outside a chapter buffer", function()
    local scratch = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_win_set_buf(0, scratch)
    local payload, err = progress.build_payload(reader, {})
    eq(payload, nil)
    matches(err, "不是微信读书章节")
    vim.api.nvim_buf_delete(scratch, { force = true })
  end)
end)

describe("progress.report", function()
  it("round trips through a signed body the server can verify", function()
    open_chapter()
    FIXTURE.token = reader.state.book.token

    local payload = progress.build_payload(reader, { elapsed_seconds = 42 })
    local ok, err = await_async(function(cb)
      progress.report(payload, cb)
    end)
    truthy(ok, tostring(err))

    eq(#read_reports, 1, "one report")
    local body = vim.json.decode(read_reports[1].body)
    eq(body.rt, 42)
    eq(body.b, require("weread.protocol").e(BOOK_ID))
    eq(body.pr, payload.progress)
    truthy(read_reports[1].headers:find("Referer: .-web/reader/"), "the referer looks like the reader")
  end)

  it("surfaces a revoked session instead of failing silently", function()
    -- A second server whose read endpoint always answers -2012, so the failure
    -- path is exercised the way it happens in reality.
    -- (第二个服务，其 read 端点总是返回 -2012，按真实方式触发失败路径)
    local denied = mock_lib.start({
      {
        path = "/web/book/read",
        handler = function()
          return { status = 200, ctype = "application/json", body = '{"errCode":-2012,"errMsg":"登录超时"}' }
        end,
      },
    })
    local previous = config.get().base_url
    config.setup({ data_dir = tmpdir, base_url = denied.url, proxy = "direct", sync_interval = 60 })

    local payload = progress.build_payload(reader, { elapsed_seconds = 10 })
    local ok, err = await_async(function(cb)
      progress.report(payload, cb)
    end)
    config.setup({ data_dir = tmpdir, base_url = previous, proxy = "direct", sync_interval = 60 })
    denied.stop()

    falsy(ok)
    matches(err, ":WeReadLogin")
    eq(progress.status().last_error, err, "the failure is recorded for checkhealth")
  end)
end)

describe("progress accounting", function()
  it("counts reading time only while a chapter buffer is focused", function()
    open_chapter()
    FIXTURE.token = reader.state.book.token

    progress.enter(reader)
    settle(900)
    read_reports = {}

    -- read for a while inside the chapter
    -- (在章节里读一会儿)
    settle(1200)

    -- leaving the chapter flushes the reading time (BufLeave fires while the
    -- chapter buffer is still current)
    -- (离开章节时结算阅读时长：BufLeave 触发时章节 buffer 仍是当前 buffer)
    local scratch = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_win_set_buf(0, scratch)
    settle(800)
    eq(#read_reports, 1, "leaving the chapter flushed the reading time")
    local flushed = vim.json.decode(read_reports[1].body)
    truthy(tonumber(flushed.rt) >= 1, "flushed seconds: " .. tostring(flushed.rt))
    eq(progress.pending(), 0, "nothing is banked after the flush")

    -- time spent away must not be credited as reading
    -- (离开期间的时间不能算作阅读)
    settle(1200)
    progress.tick(reader, { force = true })
    settle(400)
    eq(#read_reports, 1, "no report while away from a chapter")

    -- back in the chapter, the clock resumes
    -- (回到章节后重新开始计时)
    vim.api.nvim_buf_delete(scratch, { force = true })
    reader.open_index(2, {})
    vim.wait(5000, function()
      return reader.buffer_info() ~= nil
    end, 50)
    settle(900)
    read_reports = {}
    settle(1200)
    progress.tick(reader, { force = true })
    vim.wait(5000, function()
      return #read_reports > 0
    end, 100)
    truthy(#read_reports > 0, "a report went out after coming back")
    local resumed = vim.json.decode(read_reports[1].body)
    truthy(tonumber(resumed.rt) >= 1, "resumed seconds: " .. tostring(resumed.rt))
  end)

  it("reports a settled cursor once, and not again for the same spot", function()
    open_chapter()
    config.setup({ data_dir = tmpdir, base_url = server.url, proxy = "direct", sync_debounce = 0.1 })
    read_reports = {}
    FIXTURE.token = reader.state.book.token

    -- move somewhere new and let the cursor settle
    -- (挪到一个新位置，等光标停稳)
    local lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)
    local target = nil
    for index, line in ipairs(lines) do
      if line:find("汪淼", 1, true) then
        target = index
        break
      end
    end
    vim.api.nvim_win_set_cursor(0, { target, 0 })
    vim.api.nvim_exec_autocmds("CursorMoved", { buffer = 0 })
    truthy(vim.wait(2000, function()
      return #read_reports >= 1
    end, 20), "a settled cursor uploads its position")
    local body = vim.json.decode(read_reports[1].body)
    truthy(tonumber(body.rt) >= 0, "the report carries the reading time so far")

    -- the same spot again: nothing to tell
    -- (还在原地：没什么好说的)
    read_reports = {}
    vim.api.nvim_win_set_cursor(0, { target, 1 })
    vim.api.nvim_exec_autocmds("CursorMoved", { buffer = 0 })
    settle(500)
    eq(#read_reports, 0, "no second report for the same position")

    -- further down the page: worth a word
    -- (再往下读：值得说一声)
    vim.api.nvim_win_set_cursor(0, { target + 2, 0 })
    vim.api.nvim_exec_autocmds("CursorMoved", { buffer = 0 })
    truthy(vim.wait(2000, function()
      return #read_reports >= 1
    end, 20), "a new position is uploaded")
    local moved = vim.json.decode(read_reports[1].body)
    truthy(tonumber(moved.co) > tonumber(body.co), "and it is further into the chapter")

    progress.cancel_debounce()
    config.setup({ data_dir = tmpdir, base_url = server.url, proxy = "direct", sync_debounce = 5 })
  end)

  it("reports immediately when the terminal focus is lost", function()
    open_chapter()
    read_reports = {}
    FIXTURE.token = reader.state.book.token
    vim.api.nvim_win_set_cursor(0, { math.max(3, vim.fn.line("w0")), 0 })
    vim.api.nvim_exec_autocmds("FocusLost", {})
    truthy(vim.wait(3000, function()
      return #read_reports >= 1
    end, 20), "the place is uploaded without waiting for the interval")
    local saved = cache.read_position(BOOK_ID)
    truthy(saved, "and banked locally too")
  end)

  it("sends a final report synchronously on exit", function()
    open_chapter()
    read_reports = {}
    FIXTURE.token = reader.state.book.token
    vim.api.nvim_win_set_cursor(0, { vim.api.nvim_buf_line_count(0), 0 })
    local ok = progress.flush_sync()
    truthy(ok, "the exit report went through")
    truthy(#read_reports >= 1, "against the server")
    local body = vim.json.decode(read_reports[#read_reports].body)
    truthy(tonumber(body.rt) >= 0, "carrying the reading time")
    eq(progress.status().last_error, nil, "and leaving no error behind")
  end)

  it("does nothing when reporting is disabled", function()
    open_chapter()
    config.setup({ data_dir = tmpdir, base_url = server.url, proxy = "direct", sync_interval = 0 })
    read_reports = {}
    progress.enter(reader)
    progress.tick(reader, { force = true })
    settle(600)
    eq(#read_reports, 0, "no traffic while disabled")

    local messages = notifications(function()
      progress.sync_now()
    end)
    truthy(#messages > 0, "the manual sync explains why nothing happened")
    truthy(messages[1]:find("已关闭", 1, true) ~= nil)

    config.setup({ data_dir = tmpdir, base_url = server.url, proxy = "direct", sync_interval = 60 })
  end)

  it("reports on demand", function()
    open_chapter()
    FIXTURE.token = reader.state.book.token

    -- the notification is delivered asynchronously, so the stub has to stay in
    -- place while waiting for it
    -- (通知是异步送达的，因此等待期间必须保持打桩)
    local captured = {}
    local original = vim.notify
    vim.notify = function(message)
      captured[#captured + 1] = message
    end
    local ok, err = pcall(function()
      progress.sync_now()
      vim.wait(6000, function()
        return #captured > 0 and #read_reports > 0
      end, 50)
    end)
    vim.notify = original
    truthy(ok, tostring(err))
    eq(#read_reports, 1, "manual sync sent exactly one report")
    truthy(#captured > 0, "the user was told")
    truthy(captured[1]:find("已回传进度", 1, true) ~= nil, "got: " .. tostring(captured[1]))
  end)
end)

describe("progress sync safety", function()
  it("does not stamp an unmoved place over and over", function()
    open_chapter()
    FIXTURE.token = reader.state.book.token
    progress.flush()
    vim.wait(3000, function()
      return #read_reports > 0 and not progress.status().inflight
    end, 20)
    config.setup({ data_dir = tmpdir, base_url = server.url, proxy = "direct", sync_interval = 1, sync_idle = 10, sync_pull = false })

    -- nobody at the keyboard while the interval timer keeps firing
    -- (定时器一直到点，键盘前却没人)
    local original = vim.uv.now
    local base = original()
    local function at(seconds)
      vim.uv.now = function()
        return base + seconds * 1000
      end
    end
    local ok, err = pcall(function()
      at(30)
      progress.tick(reader)
      vim.wait(3000, function()
        return not progress.status().inflight
      end, 20)
      read_reports = {}
      at(90)
      progress.tick(reader)
      at(150)
      progress.tick(reader)
    end)
    vim.uv.now = original
    truthy(ok, tostring(err))
    settle(600)
    eq(#read_reports, 0, "an unmoved, unattended window says nothing")
    config.setup({ data_dir = tmpdir, base_url = server.url, proxy = "direct", sync_interval = 60 })
  end)

  it("announces the session once before its first report", function()
    progress._reset()
    enter_reports = {}
    open_chapter()
    FIXTURE.token = reader.state.book.token
    vim.api.nvim_win_set_cursor(0, { math.floor(vim.api.nvim_buf_line_count(0) / 2), 0 })
    progress.flush()
    truthy(vim.wait(5000, function()
      return #read_reports > 0 and not progress.status().inflight
    end, 20), "a report went out")
    eq(#enter_reports, 1, "one enter handshake")
    vim.api.nvim_win_set_cursor(0, { vim.api.nvim_buf_line_count(0), 0 })
    progress.flush()
    vim.wait(3000, function()
      return #read_reports > 1 and not progress.status().inflight
    end, 20)
    eq(#enter_reports, 1, "and not again for the next report")
  end)

  it("keeps one report on the wire and sends the latest position last", function()
    open_chapter()
    FIXTURE.token = reader.state.book.token
    read_reports = {}
    local count = vim.api.nvim_buf_line_count(0)
    vim.api.nvim_win_set_cursor(0, { 2, 0 })
    progress.flush()
    vim.api.nvim_win_set_cursor(0, { math.floor(count / 2), 0 })
    progress.flush()
    vim.api.nvim_win_set_cursor(0, { count, 0 })
    progress.flush()
    truthy(vim.wait(5000, function()
      return not progress.status().inflight and #read_reports >= 2
    end, 20), "the reports went out")
    settle(300)
    eq(#read_reports, 2, "the middle request was replaced by the last one")
    local last = vim.json.decode(read_reports[#read_reports].body)
    local expected = progress.build_payload(reader, {}).chapter_offset
    eq(last.co, expected, "the service ends on the latest position")
  end)

  it("accepts an answer that only carries a synckey", function()
    truthy(progress.accepted({ synckey = 1 }))
    truthy(progress.accepted({ succ = 1 }))
    falsy(progress.accepted({ errCode = -2012, synckey = 1 }))
    falsy(progress.accepted({ errCode = -2012 }))
    falsy(progress.accepted(nil))
  end)

  it("does not count time away from the keyboard as reading", function()
    open_chapter()
    config.setup({ data_dir = tmpdir, base_url = server.url, proxy = "direct", sync_interval = 60, sync_idle = 10 })
    progress.enter(reader)
    settle(300)
    progress.tick(reader) -- start a clean mark(重新起算)
    local before = progress.pending()
    -- pretend the last key press was a minute ago
    -- (假装最后一次按键在一分钟之前)
    local original = vim.uv.now
    local base = original()
    vim.uv.now = function()
      return base + 60 * 1000
    end
    local ok, err = pcall(function()
      progress.tick(reader)
    end)
    vim.uv.now = original
    truthy(ok, tostring(err))
    truthy(progress.pending() - before <= 11, "at most the idle allowance is credited: " .. tostring(progress.pending() - before))
    config.setup({ data_dir = tmpdir, base_url = server.url, proxy = "direct", sync_interval = 60 })
  end)

  it("does not report an unmoved place on exit", function()
    open_chapter()
    FIXTURE.token = reader.state.book.token
    vim.api.nvim_win_set_cursor(0, { 3, 0 })
    truthy(progress.flush_sync(), "a moved place goes out")
    read_reports = {}
    falsy(progress.flush_sync(), "the same place again is not news")
    eq(#read_reports, 0)
  end)
end)

---Replace fields of `target` for the duration of `fn`, and put them back after,
---whatever happens.
---(在 fn 执行期间替换 target 的字段，无论成败都恢复)
---@param target table
---@param replacements table<string, any>
---@param fn fun()
local function stubbed(target, replacements, fn)
  local originals = {}
  for key, value in pairs(replacements) do
    originals[key] = target[key]
    target[key] = value
  end
  local ok, err = pcall(fn)
  for key in pairs(replacements) do
    target[key] = originals[key]
  end
  if not ok then
    error(err, 0)
  end
end

describe("progress.flush_sync budget", function()
  ---A chapter with the cursor somewhere the service has not been told about.
  ---(光标停在服务端还不知道的位置上的章节)
  local function unreported_place()
    open_chapter()
    FIXTURE.token = reader.state.book.token
    progress._reset()
    vim.api.nvim_win_set_cursor(0, { vim.api.nvim_buf_line_count(0), 0 })
  end

  it("waits at most 1500 ms for the one request it makes", function()
    unreported_place()
    local calls = {}
    stubbed(http, {
      request_sync = function(opts, timeout_ms)
        calls[#calls + 1] = { opts = opts, timeout_ms = timeout_ms }
        return { code = 200, status = 200, body = '{"succ":1}' }
      end,
    }, function()
      truthy(progress.flush_sync(), "an accepted report is a success")
    end)
    eq(#calls, 1, "one request")
    eq(calls[1].timeout_ms, 1500, "the local wait is capped at 1.5 s")
    truthy(calls[1].opts.timeout <= 2, "curl itself gives up within 2 s: " .. tostring(calls[1].opts.timeout))
    eq(calls[1].opts.retries, 0, "and does not retry")
  end)

  it("gives up on a rejection instead of refreshing the context and posting again", function()
    unreported_place()
    local posts, refreshes = 0, 0
    local content = require("weread.content")
    stubbed(http, {
      request_sync = function()
        posts = posts + 1
        return { code = 200, status = 200, body = '{"errCode":-2012,"errMsg":"登录超时"}' }
      end,
    }, function()
      stubbed(content, {
        fetch_reader_state = function(_, _, _, callback)
          refreshes = refreshes + 1
          callback(false)
        end,
      }, function()
        local started = vim.uv.hrtime()
        falsy(progress.flush_sync(), "a rejected report is not a success")
        truthy((vim.uv.hrtime() - started) / 1e6 < 1000, "and nothing waits for a second round")
      end)
    end)
    eq(posts, 1, "no second post")
    eq(refreshes, 0, "and no context refresh on the way out")
    truthy(progress.status().last_error, "the failure is on record")
  end)

  it("does not retry a transport failure either", function()
    unreported_place()
    local posts = 0
    stubbed(http, {
      request_sync = function()
        posts = posts + 1
        return { code = 0, error = "request timed out locally" }
      end,
    }, function()
      falsy(progress.flush_sync())
    end)
    eq(posts, 1)
    eq(progress.status().last_error, "request timed out locally")
  end)

  it("does not spend the budget when the network is down", function()
    unreported_place()
    local original = config.get().base_url
    -- a port nothing listens on: curl is refused at once
    -- (没人监听的端口：curl 立刻被拒绝)
    local probe = assert(vim.uv.new_tcp())
    probe:bind("127.0.0.1", 0)
    local closed_port = probe:getsockname().port
    probe:close()
    config.get().base_url = "http://127.0.0.1:" .. closed_port
    local started = vim.uv.hrtime()
    local ok, result = pcall(progress.flush_sync)
    local elapsed = (vim.uv.hrtime() - started) / 1e6
    config.get().base_url = original
    truthy(ok, tostring(result))
    falsy(result, "nothing was reported")
    truthy(elapsed < 1200, "refused connections end the wait early, took " .. math.floor(elapsed) .. " ms")
    truthy(progress.status().last_error, "and the reason is kept")
  end)
end)

describe("progress remote pull", function()
  local api_gateway = require("weread.api_gateway")
  local auth = require("weread.auth")
  local PULL_BOOK = "pull-book"

  ---A saved local position, as the position file keeps it.
  ---(位置文件里保存的本地位置)
  ---@param fields table
  local function save_position(fields)
    cache.write_position(PULL_BOOK, vim.tbl_extend("force", { chapter_uid = "5", src_from = 100, updated_at = 1000 }, fields))
  end

  ---A remote record the way `fetch_remote` hands it over.
  ---(fetch_remote 交出来的远端记录)
  ---@param fields table|nil
  ---@return table
  local function remote_record(fields)
    return vim.tbl_extend("force", {
      book_id = PULL_BOOK,
      chapter_uid = "9",
      chapter_offset = 500,
      progress = 40,
      summary = "",
      update_time = 5000,
    }, fields or {})
  end

  ---The gateway's answer for `/book/getprogress`.
  ---(网关对 /book/getprogress 的回答)
  ---@param fields table|nil
  ---@return table
  local function gateway_book(fields)
    return { book = vim.tbl_extend("force", { chapterUid = 9, chapterOffset = 500, progress = 40, updateTime = 5000 }, fields or {}) }
  end

  local function fresh()
    progress._reset()
    local positions = config.path("positions.json")
    pcall(vim.fn.delete, positions)
  end

  describe("can_pull", function()
    it("needs an api key", function()
      stubbed(auth, { api_key = function() return "wrk-abc" end }, function()
        truthy(progress.can_pull())
      end)
      stubbed(auth, { api_key = function() return nil end }, function()
        falsy(progress.can_pull(), "no key, no pull")
      end)
      stubbed(auth, { api_key = function() return "" end }, function()
        falsy(progress.can_pull(), "an empty key is no key")
      end)
    end)

    it("survives credentials that cannot be read", function()
      stubbed(auth, { api_key = function() error("unreadable") end }, function()
        falsy(progress.can_pull())
      end)
    end)

    it("is switched off by sync_pull = false", function()
      config.setup({ data_dir = tmpdir, base_url = server.url, proxy = "direct", sync_interval = 60, sync_pull = false })
      stubbed(auth, { api_key = function() return "wrk-abc" end }, function()
        falsy(progress.can_pull())
      end)
      config.setup({ data_dir = tmpdir, base_url = server.url, proxy = "direct", sync_interval = 60 })
    end)
  end)

  describe("remote_is_newer", function()
    it("takes any later remote when nothing is saved locally", function()
      fresh()
      truthy(progress.remote_is_newer(PULL_BOOK, remote_record()))
    end)

    it("ignores a remote that is not later than the saved place, within the clock tolerance", function()
      fresh()
      save_position({ updated_at = 1000 })
      falsy(progress.remote_is_newer(PULL_BOOK, remote_record({ update_time = 900 })), "older")
      falsy(progress.remote_is_newer(PULL_BOOK, remote_record({ update_time = 1005 })), "5 s later is the same moment")
      truthy(progress.remote_is_newer(PULL_BOOK, remote_record({ update_time = 1006 })), "6 s later is news")
    end)

    it("ignores the position this machine itself uploaded", function()
      fresh()
      save_position({ updated_at = 1000 })
      local synced = os.time()
      progress.adopted({ book_id = PULL_BOOK, chapter_uid = "9", chapter_offset = 500 })
      falsy(progress.remote_is_newer(PULL_BOOK, remote_record({ update_time = synced + 3 })), "our own report echoed back")
      truthy(progress.remote_is_newer(PULL_BOOK, remote_record({ update_time = synced + 60 })), "a later one is another device")
    end)

    it("ignores the same spot in the same chapter", function()
      fresh()
      save_position({ chapter_uid = "9", src_from = 490, updated_at = 1000 })
      falsy(progress.remote_is_newer(PULL_BOOK, remote_record({ chapter_offset = 500 })), "10 runes apart is the same spot")
      truthy(progress.remote_is_newer(PULL_BOOK, remote_record({ chapter_offset = 600 })), "100 runes on is not")
      truthy(progress.remote_is_newer(PULL_BOOK, remote_record({ chapter_uid = "10", chapter_offset = 490 })), "another chapter is not")
    end)

    it("ignores the place the last accepted report left", function()
      fresh()
      save_position({ updated_at = 1000 })
      local remote = remote_record()
      truthy(progress.remote_is_newer(PULL_BOOK, remote))
      -- the key `record_success` leaves behind (record_success 留下的那个键)
      local reported = string.format("%s#%s@%s", PULL_BOOK, remote.chapter_uid, remote.chapter_offset)
      require("weread.progress_state").last_position = reported
      falsy(progress.remote_is_newer(PULL_BOOK, remote))
      progress._reset()
    end)
  end)

  describe("pull", function()
    it("hands over a remote that is newer, and remembers the pull", function()
      fresh()
      local asked
      stubbed(api_gateway, {
        progress = function(book_id, _, callback)
          asked = book_id
          callback(true, gateway_book())
        end,
      }, function()
        local got, got_err = "unset", "unset"
        progress.pull(PULL_BOOK, function(remote, err)
          got, got_err = remote, err
        end)
        eq(asked, PULL_BOOK)
        eq(got_err, nil)
        eq(got.chapter_uid, "9", "the chapter is a string")
        eq(got.chapter_offset, 500)
        eq(got.update_time, 5000)
        eq(progress.status().pulled_position, got, "kept for the exit check")
        truthy(progress.status().pulled_at, "and when it was pulled")
        eq(progress.status().pull_error, nil)
      end)
    end)

    it("answers nil without an error when the remote is not newer", function()
      fresh()
      save_position({ updated_at = 6000 })
      stubbed(api_gateway, {
        progress = function(_, _, callback)
          callback(true, gateway_book({ updateTime = 5000 }))
        end,
      }, function()
        local got, got_err = "unset", "unset"
        progress.pull(PULL_BOOK, function(remote, err)
          got, got_err = remote, err
        end)
        eq(got, nil, "nothing to follow")
        eq(got_err, nil, "and nothing went wrong")
        eq(progress.status().pulled_position.update_time, 5000, "the pull is still on record")
      end)
    end)

    it("reports a failed question instead of guessing", function()
      fresh()
      stubbed(api_gateway, {
        progress = function(_, _, callback)
          callback(false, "network down")
        end,
      }, function()
        local got, got_err = "unset", nil
        progress.pull(PULL_BOOK, function(remote, err)
          got, got_err = remote, err
        end)
        eq(got, nil)
        eq(got_err, "network down")
        eq(progress.status().pull_error, "network down")
      end)
    end)

    it("treats a record without a chapter or time as no record", function()
      fresh()
      stubbed(api_gateway, {
        progress = function(_, _, callback)
          callback(true, { book = { progress = 3 } })
        end,
      }, function()
        local got_err
        progress.pull(PULL_BOOK, function(_, err)
          got_err = err
        end)
        matches(got_err, "没有可用的进度记录")
      end)
    end)

    it("asks the service once for callers that arrive together", function()
      fresh()
      local calls, release = 0, nil
      stubbed(api_gateway, {
        progress = function(_, _, callback)
          calls = calls + 1
          release = callback
        end,
      }, function()
        local answers = {}
        for index = 1, 3 do
          progress.pull(PULL_BOOK, function(remote)
            answers[index] = remote
          end)
        end
        eq(calls, 1, "one question on the wire")
        release(true, gateway_book())
        truthy(answers[1] and answers[2] and answers[3], "every caller got the answer")
        eq(answers[1], answers[3])
        -- and the next pull is a new question (之后的拉取是新的问题)
        progress.pull(PULL_BOOK, function() end)
        eq(calls, 2)
        release(true, gateway_book())
      end)
    end)

    it("does not ask at all when pulling is switched off", function()
      fresh()
      config.setup({ data_dir = tmpdir, base_url = server.url, proxy = "direct", sync_interval = 60, sync_pull = false })
      local calls = 0
      stubbed(api_gateway, {
        progress = function(_, _, callback)
          calls = calls + 1
          callback(true, gateway_book())
        end,
      }, function()
        local got_err
        progress.pull(PULL_BOOK, function(_, err)
          got_err = err
        end)
        eq(calls, 0)
        eq(got_err, "disabled")
      end)
      config.setup({ data_dir = tmpdir, base_url = server.url, proxy = "direct", sync_interval = 60 })
    end)

    it("answers every waiter even when the gateway call raises or a waiter does", function()
      fresh()
      stubbed(api_gateway, {
        progress = function()
          error("boom")
        end,
      }, function()
        local got_err
        progress.pull(PULL_BOOK, function(_, err)
          got_err = err
        end)
        matches(got_err, "boom")
      end)
      stubbed(api_gateway, {
        progress = function(_, _, callback)
          callback(true, gateway_book())
        end,
      }, function()
        local survivor
        -- the first waiter raises; the second must still hear the answer
        -- (第一个等待者抛异常；第二个仍然要听到回答)
        stubbed(api_gateway, {
          progress = function(_, _, callback)
            progress.pull(PULL_BOOK, function(remote)
              survivor = remote
            end)
            callback(true, gateway_book())
          end,
        }, function()
          progress.pull(PULL_BOOK, function()
            error("a broken callback")
          end)
        end)
        truthy(survivor, "the other waiter was not cut off")
      end)
      eq(next(require("weread.progress_state").pulling), nil, "and nothing is left marked as in flight")
    end)
  end)

  describe("deferred positions", function()
    it("holds a remote position per book until it is followed or let go", function()
      fresh()
      local remote = remote_record({ book_id = PULL_BOOK })
      eq(progress.deferred(PULL_BOOK), nil)
      progress.defer(remote)
      eq(progress.deferred(PULL_BOOK), remote)
      eq(progress.deferred(12345), nil, "only for its own book")
      progress.undefer(remote_record())
      eq(progress.deferred(PULL_BOOK), remote, "another record does not release it")
      progress.undefer(remote)
      eq(progress.deferred(PULL_BOOK), nil)
    end)

    it("is released once the reader sits at the remote position", function()
      fresh()
      local remote = remote_record()
      progress.defer(remote)
      progress.adopted(remote)
      eq(progress.deferred(PULL_BOOK), nil)
      eq(progress.status().pulled_position, remote)
      truthy(progress.status().synced_at[PULL_BOOK], "and our own enter report is not news later")
    end)

    it("follows a held position, but a failed chapter is not retried at once", function()
      fresh()
      local followed = 0
      local session = { book = { book_id = PULL_BOOK } }
      stubbed(reader, {
        current = function() return session end,
        follow_remote = function()
          followed = followed + 1
          return false
        end,
      }, function()
        eq(progress.follow_deferred(), false, "nothing held, nothing to follow")
        progress.defer(remote_record())
        eq(progress.follow_deferred(), false)
        eq(followed, 1, "followed once")
        progress.follow_deferred()
        eq(followed, 1, "and not again within a minute")
      end)
      progress._reset()
    end)
  end)

  describe("poll", function()
    local function session()
      return { book = { book_id = PULL_BOOK } }
    end

    it("does nothing outside a book or with pulling off", function()
      fresh()
      local asked = 0
      stubbed(api_gateway, {
        progress = function(_, _, callback)
          asked = asked + 1
          callback(true, gateway_book())
        end,
      }, function()
        stubbed(reader, { current = function() return nil end }, function()
          progress.poll({ force = true })
        end)
        eq(asked, 0, "no book, no question")
        config.setup({ data_dir = tmpdir, base_url = server.url, proxy = "direct", sync_interval = 60, sync_pull = false })
        stubbed(reader, { current = session }, function()
          progress.poll({ force = true })
        end)
        eq(asked, 0, "pulling off, no question")
        config.setup({ data_dir = tmpdir, base_url = server.url, proxy = "direct", sync_interval = 60 })
      end)
    end)

    it("follows a newer remote position", function()
      fresh()
      local followed
      stubbed(api_gateway, {
        progress = function(_, _, callback)
          callback(true, gateway_book())
        end,
      }, function()
        stubbed(reader, {
          current = session,
          follow_remote = function(remote)
            followed = remote
            return true
          end,
        }, function()
          progress.poll({ force = true })
        end)
      end)
      truthy(followed, "the reader was sent to the phone's place")
      eq(followed.chapter_uid, "9")
      eq(progress.deferred(PULL_BOOK), nil, "nothing is left waiting")
    end)

    it("keeps a newer position for later when a key was pressed meanwhile", function()
      fresh()
      local followed = false
      local release
      stubbed(api_gateway, {
        progress = function(_, _, callback)
          release = callback
        end,
      }, function()
        stubbed(reader, {
          current = session,
          follow_remote = function()
            followed = true
            return true
          end,
        }, function()
          progress.poll({ force = true })
          -- the reader types after the question went out (问题发出之后读者有了按键)
          require("weread.progress_state").last_input = require("weread.progress_state").last_input + 1
          release(true, gateway_book())
        end)
      end)
      falsy(followed, "the reader is not pulled away mid-page")
      truthy(progress.deferred(PULL_BOOK), "but the position is kept, so no report buries it")
    end)

    it("asks at most every 30 s unless forced", function()
      fresh()
      local asked = 0
      stubbed(api_gateway, {
        progress = function(_, _, callback)
          asked = asked + 1
          callback(true, gateway_book({ updateTime = 1 }))
        end,
      }, function()
        stubbed(reader, { current = session, follow_remote = function() return true end }, function()
          progress.poll()
          eq(asked, 1, "the first poll asks")
          progress.poll()
          eq(asked, 1, "the second, right after, is held back")
          progress.poll({ force = true })
          eq(asked, 2, "a forced one asks anyway")
          local original = vim.uv.now
          local base = original()
          vim.uv.now = function()
            return base + 31 * 1000
          end
          local ok, err = pcall(progress.poll)
          vim.uv.now = original
          truthy(ok, tostring(err))
          eq(asked, 3, "and after 30 s the plain poll asks again")
        end)
      end)
    end)
  end)
end)
