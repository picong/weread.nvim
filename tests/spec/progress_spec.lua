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
  local expected = crypto.sha256_hex(
    tostring(body_json.ts) .. tostring(body_json.rn) .. FIXTURE.token
  )
  if expected ~= body_json.sg then
    return false, string.format("sg mismatch: got %s, expected %s", tostring(body_json.sg), expected)
  end
  if tostring(body_json.rt) == nil then
    return false, "missing rt"
  end
  return true, ""
end

local read_reports = {}

local ref = {}
local routes = mock_lib.weread_routes(ref)
table.insert(routes, 1, {
  path = "/web/book/read",
  handler = function(_, _, body, headers)
    local signature_ok, signature_err = mock_lib.signature_is_valid(body)
    if not signature_ok then
      return { status = 400, ctype = "text/plain", body = "bad signature: " .. signature_err }
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
    truthy(payload.progress >= 0 and payload.progress <= 100)
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
