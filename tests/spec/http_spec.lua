--[[
Tests for weread.http's session handling.

An expired WeRead session answers with `-2012` / `登录超时` — sometimes as HTTP
401, sometimes as a 200 carrying an error object. Until this was handled here, a
session that aged out simply reported failures for every web request, and the
reader's cookie renewal (which the README has always advertised) was never
called by anything.
(http 单测：会话处理。微信读书对过期会话回 `-2012` / `登录超时`，有时是 HTTP 401，有时是
 200 里带错误对象。在把它放在这里处理之前，会话一过期所有 web 请求就直接失败，而 README
 一直宣称的 cookie 续期从来没有被任何代码调用过)

The test drives the real http client against a local mock that rejects the first
request of each kind, so the renewal-then-retry path runs end to end offline.
(测试用真实 http 客户端打本地 mock：mock 拒绝每类请求的第一次，于是「续期后重试」这条路径
 可以在离线状态下端到端跑完)
]]

local mock_lib = dofile(vim.fn.getcwd() .. "/tests/mock.lua")

local tmpdir = vim.fn.tempname()
vim.fn.mkdir(tmpdir, "p")

local calls = { read = 0, renew = 0 }
local ref = {}

---Reject the first `read` request with an expired session, then serve it.
---(第一次 read 请求回「登录超时」，之后正常返回)
---@return table[] routes
local function routes()
  return {
    {
      path = "/web/book/read",
      handler = function()
        calls.read = calls.read + 1
        if calls.read == 1 then
          return { status = 200, ctype = "application/json", body = '{"errCode":-2012,"errMsg":"登录超时"}' }
        end
        return { status = 200, ctype = "application/json", body = '{"ok":true,"calls":' .. calls.read .. "}" }
      end,
    },
    {
      path = "/web/login/renewal",
      handler = function()
        calls.renew = calls.renew + 1
        return { status = 200, ctype = "application/json", body = '{"succ":1,"errCode":0}' }
      end,
    },
  }
end

local server = mock_lib.start(routes())
ref.url = server.url

local config = require("weread.config")
local http = require("weread.http")
local auth = require("weread.auth")
local log = require("weread.log")

config.setup({ data_dir = tmpdir, base_url = server.url, proxy = "direct", retries = 0 })
config.ensure_dirs()
http.setup({ jar = config.path("cookies.txt"), tmpdir = config.path("tmp"), timeout = 8, retries = 0, proxy = "direct" })
log.setup({ debug = false, path = config.path("weread.log") })

describe("http session renewal", function()
  it("renews once and retries when the service says the session expired", function()
    calls.read, calls.renew = 0, 0
    local res = http.request_sync({
      url = server.url .. "/web/book/read",
      method = "POST",
      json = true,
      body = { bookId = "43208843" },
      timeout = 8,
    }, 30000)

    truthy(res, "a response came back")
    eq(res.code, 200, "the retry succeeded: " .. tostring(res.body))
    truthy(tostring(res.body):find('"ok":true', 1, true), "and it is the second answer: " .. tostring(res.body))
    eq(calls.read, 2, "the request was sent again after renewing")
    eq(calls.renew, 1, "and the session was renewed exactly once")
  end)

  it("does not renew a second time when the retry fails too", function()
    calls.read, calls.renew = 0, 0
    local original = routes()[1].handler
    -- make every read answer "expired": the client must give up rather than
    -- renew in a loop
    -- (让每次 read 都回「已过期」：客户端必须放弃，而不是循环续期)
    local stubborn = mock_lib.start({
      {
        path = "/web/book/read",
        handler = function()
          calls.read = calls.read + 1
          return { status = 200, ctype = "application/json", body = '{"errCode":-2012,"errMsg":"登录超时"}' }
        end,
      },
      {
        path = "/web/login/renewal",
        handler = function()
          calls.renew = calls.renew + 1
          return { status = 200, ctype = "application/json", body = '{"succ":1,"errCode":0}' }
        end,
      },
    })
    local res = http.request_sync({
      url = stubborn.url .. "/web/book/read",
      method = "POST",
      json = true,
      body = { bookId = "43208843" },
      timeout = 8,
    }, 30000)
    truthy(tostring(res.body):find("-2012", 1, true), "the failure is reported: " .. tostring(res.body))
    eq(calls.read, 2, "two attempts, no more")
    eq(calls.renew, 1, "one renewal, no loop")
    truthy(original, "the shared route table is untouched")
  end)

  it("never renews while logging in", function()
    calls.renew = 0
    local login_server = mock_lib.start({
      {
        path = "/login",
        handler = function()
          calls.renew = calls.renew + 1
          return { status = 200, ctype = "application/json", body = '{"errCode":-2012,"errMsg":"登录超时"}' }
        end,
      },
    })
    local res = http.request_sync({
      url = login_server.url .. "/login",
      method = "POST",
      json = true,
      body = { deviceType = 3 },
      timeout = 8,
    }, 30000)
    truthy(tostring(res.body):find("-2012", 1, true), "the login failure is reported as is")
    eq(calls.renew, 1, "the login endpoint itself was called once and nothing else happened")
  end)
end)

-- ---------------------------------------------------------------- hardening
-- (加固相关)

---Run `body` with `vim.system` replaced, restoring it whatever happens: the
---runner does not restore it between specs.
---(用桩替换 vim.system 跑 body，无论如何都还原：runner 不会在 spec 之间还原它)
---@param stub function
---@param body function
local function with_system(stub, body)
  local original = vim.system
  vim.system = stub
  local ok, err = pcall(body)
  vim.system = original
  if not ok then
    error(err, 0)
  end
end

---@return table[] files wr-* files currently in the http tmp directory(tmp 目录里的 wr-* 文件)
local function tmp_leftovers()
  local out = {}
  for name in vim.fs.dir(config.path("tmp")) do
    if name:sub(1, 3) == "wr-" then
      out[#out + 1] = name
    end
  end
  table.sort(out)
  return out
end

---A server that accepts connections and never answers: a request to it hangs
---until something kills it.
---(接受连接但永不应答的服务器：请求会一直挂着，直到被杀)
local function hanging_server()
  local srv = vim.uv.new_tcp()
  assert(srv:bind("127.0.0.1", 0))
  local port = srv:getsockname().port
  local clients = {}
  srv:listen(16, function()
    local client = vim.uv.new_tcp()
    srv:accept(client)
    clients[#clients + 1] = client
    client:read_start(function() end)
  end)
  return {
    url = "http://127.0.0.1:" .. port,
    stop = function()
      for _, client in ipairs(clients) do
        pcall(function()
          client:close()
        end)
      end
      pcall(function()
        srv:close()
      end)
    end,
  }
end

local echo_server = mock_lib.start({
  {
    path = "/echo",
    handler = function(_, _, _, head)
      return { status = 200, ctype = "text/plain", body = head }
    end,
  },
  {
    path = "/big",
    handler = function()
      return { status = 200, ctype = "application/octet-stream", body = string.rep("a", 100000) }
    end,
  },
  {
    path = "/small",
    handler = function()
      return { status = 200, ctype = "application/octet-stream", body = "tiny" }
    end,
  },
})

describe("http when curl cannot be started", function()
  it("still calls back when vim.system raises ENOENT", function()
    local calls_to_system = 0
    local res
    with_system(function()
      calls_to_system = calls_to_system + 1
      error("ENOENT: no such file or directory (cmd): 'curl'")
    end, function()
      http.request({ url = "http://127.0.0.1:1/x", retries = 2 }, function(r)
        res = r
      end)
      vim.wait(2000, function()
        return res ~= nil
      end, 10)
    end)
    truthy(res, "the callback fired")
    eq(res.code, 0)
    matches(res.error, "could not start curl")
    matches(res.error, "ENOENT")
    eq(calls_to_system, 1, "no point retrying a missing binary")
  end)

  it("still calls back for a download, so the caller can clean up", function()
    local dest = tmpdir .. "/dl/never.bin"
    local res
    with_system(function()
      error("ENOENT: no such file or directory (cmd): 'curl'")
    end, function()
      http.download("http://127.0.0.1:1/x", dest, { retries = 1 }, function(r)
        res = r
      end)
      vim.wait(2000, function()
        return res ~= nil
      end, 10)
    end)
    truthy(res, "image.lua's in-flight bookkeeping depends on this callback")
    eq(res.code, 0)
    eq(vim.uv.fs_stat(dest), nil, "and no file appeared")
  end)

  it("still calls back when the body cannot be encoded", function()
    local spawned = 0
    local res
    with_system(function()
      spawned = spawned + 1
      return { kill = function() end }
    end, function()
      http.request({ url = "http://127.0.0.1:1/x", method = "POST", json = true, body = { f = function() end } }, function(r)
        res = r
      end)
      vim.wait(2000, function()
        return res ~= nil
      end, 10)
    end)
    truthy(res)
    eq(res.code, 0)
    matches(res.error, "encode")
    eq(spawned, 0, "curl was never started")
  end)

  it("still calls back for a request without a url", function()
    local res
    http.request({}, function(r)
      res = r
    end)
    vim.wait(2000, function()
      return res ~= nil
    end, 10)
    truthy(res)
    eq(res.code, 0)
    matches(res.error, "url")
  end)

  it("leaves no temp file behind after those failures", function()
    eq(tmp_leftovers(), {})
    eq(http._active_count(), 0)
  end)
end)

describe("http credentials stay off the command line", function()
  local headers = {
    Authorization = "Bearer wrk-secret-key-123",
    ["X-Skey"] = "skey-value-456",
    ["X-Vid"] = "vid-value-789",
    Cookie = "wr_skey=cookie-secret-000",
    ["X-Plain"] = "visible",
  }

  ---@param exit_code integer
  ---@return table captured
  ---@return table res
  local function run_stubbed(exit_code)
    local captured = {}
    local res
    with_system(function(argv, _, on_exit)
      captured.argv = vim.deepcopy(argv)
      for index, arg in ipairs(argv) do
        if arg:sub(1, 1) == "@" and argv[index - 1] == "--header" then
          captured.path = arg:sub(2)
          local file = io.open(captured.path, "rb")
          captured.text = file and file:read("*a") or nil
          if file then
            file:close()
          end
          captured.perm = vim.fn.getfperm(captured.path)
        end
      end
      -- Synchronously, as a stub may: the job must not be registered after it
      -- has already finished.
      -- (同步触发，桩可能这样做：job 已结束就不能再被登记)
      on_exit({ code = exit_code, stdout = exit_code == 0 and "200" or "", stderr = "" })
      return { kill = function() end }
    end, function()
      http.request({ url = "https://example.invalid/x", headers = headers, retries = 0 }, function(r)
        res = r
      end)
      vim.wait(2000, function()
        return res ~= nil
      end, 10)
    end)
    return captured, res
  end

  it("keeps every secret out of argv", function()
    local captured = run_stubbed(0)
    local joined = table.concat(captured.argv, "\n")
    for _, secret in ipairs({ "wrk-secret-key-123", "skey-value-456", "vid-value-789", "cookie-secret-000" }) do
      falsy(joined:find(secret, 1, true), secret .. " leaked into argv")
    end
    falsy(joined:find("wrk-", 1, true))
  end)

  it("still passes harmless headers on the command line", function()
    local captured = run_stubbed(0)
    truthy(vim.tbl_contains(captured.argv, "X-Plain: visible"))
  end)

  it("hands the secrets to curl through a private header file", function()
    local captured = run_stubbed(0)
    truthy(captured.path, "a --header @file argument was passed")
    eq(captured.perm, "rw-------")
    matches(captured.text, "Authorization: Bearer wrk%-secret%-key%-123")
    matches(captured.text, "X%-Skey: skey%-value%-456")
    matches(captured.text, "X%-Vid: vid%-value%-789")
    matches(captured.text, "Cookie: wr_skey=cookie%-secret%-000")
    falsy(captured.text:find("visible", 1, true), "harmless headers are not in the file")
  end)

  for _, code in ipairs({ 0, 7, 28 }) do
    it("removes the header file when curl exits with " .. code, function()
      local captured, res = run_stubbed(code)
      truthy(res, "the request finished")
      truthy(captured.path)
      eq(vim.uv.fs_stat(captured.path), nil, "the header file is gone")
      eq(tmp_leftovers(), {})
      eq(http._active_count(), 0, "and the job is not left registered")
    end)
  end

  it("refuses a secret header value containing a line break", function()
    local res
    with_system(function()
      error("must not be spawned")
    end, function()
      http.request({ url = "https://example.invalid/x", headers = { Authorization = "a\r\nX-Evil: 1" }, retries = 0 }, function(r)
        res = r
      end)
      vim.wait(2000, function()
        return res ~= nil
      end, 10)
    end)
    truthy(res)
    eq(res.code, 0)
    matches(res.error, "line break")
    eq(tmp_leftovers(), {})
  end)

  it("really delivers the secrets to the server through the file", function()
    local res = http.request_sync({
      url = echo_server.url .. "/echo",
      headers = { Authorization = "Bearer wrk-real-key", ["X-Skey"] = "real-skey", ["X-Vid"] = "real-vid" },
      timeout = 8,
      retries = 0,
    }, 20000)
    eq(res.code, 200, tostring(res.error))
    matches(res.body, "Authorization: Bearer wrk%-real%-key")
    matches(res.body, "X%-Skey: real%-skey")
    matches(res.body, "X%-Vid: real%-vid")
    eq(tmp_leftovers(), {}, "and the file was removed afterwards")
  end)
end)

describe("http curl hardening", function()
  it("restricts the protocols, redirects included", function()
    local argv
    with_system(function(args, _, on_exit)
      argv = vim.deepcopy(args)
      on_exit({ code = 0, stdout = "200", stderr = "" })
      return { kill = function() end }
    end, function()
      local done = false
      http.request({ url = "https://example.invalid/x", retries = 0 }, function()
        done = true
      end)
      vim.wait(2000, function()
        return done
      end, 10)
    end)
    local joined = " " .. table.concat(argv, " ") .. " "
    truthy(joined:find(" --proto =http,https ", 1, true))
    truthy(joined:find(" --proto-redir =http,https ", 1, true))
  end)

  it("does not read local files through a file:// url", function()
    local secret = tmpdir .. "/local-secret.txt"
    vim.fn.writefile({ "SECRET-FILE-CONTENT" }, secret)
    local res = http.request_sync({ url = "file://" .. secret, retries = 0, timeout = 8 }, 20000)
    falsy((res.body or ""):find("SECRET-FILE-CONTENT", 1, true), "curl was not allowed to read it")
  end)

  it("caps downloads but not ordinary requests", function()
    local seen = {}
    with_system(function(args, _, on_exit)
      seen[#seen + 1] = vim.deepcopy(args)
      on_exit({ code = 0, stdout = "200", stderr = "" })
      return { kill = function() end }
    end, function()
      local pending = 2
      local function finished()
        pending = pending - 1
      end
      http.request({ url = "https://example.invalid/api", retries = 0 }, finished)
      http.download("https://example.invalid/file", tmpdir .. "/dl/capped.bin", { retries = 0 }, finished)
      vim.wait(2000, function()
        return pending == 0
      end, 10)
    end)
    falsy(vim.tbl_contains(seen[1], "--max-filesize"), "an API request has no cap")
    local index
    for i, arg in ipairs(seen[2]) do
      if arg == "--max-filesize" then
        index = i
      end
    end
    truthy(index, "a download is capped by default")
    eq(tonumber(seen[2][index + 1]), 200 * 1024 * 1024)
  end)

  it("lets a caller override the cap", function()
    local argv
    with_system(function(args, _, on_exit)
      argv = vim.deepcopy(args)
      on_exit({ code = 0, stdout = "200", stderr = "" })
      return { kill = function() end }
    end, function()
      local done = false
      http.download("https://example.invalid/file", tmpdir .. "/dl/cap2.bin", { retries = 0, max_filesize = 1234 }, function()
        done = true
      end)
      vim.wait(2000, function()
        return done
      end, 10)
    end)
    for i, arg in ipairs(argv) do
      if arg == "--max-filesize" then
        eq(argv[i + 1], "1234")
        return
      end
    end
    error("no --max-filesize in argv")
  end)

  it("stops an oversized download without retrying and leaves no file", function()
    echo_server.reset()
    local dest = tmpdir .. "/dl/oversized.bin"
    local res
    http.download(echo_server.url .. "/big", dest, { max_filesize = 1000, retries = 2, timeout = 8 }, function(r)
      res = r
    end)
    vim.wait(20000, function()
      return res ~= nil
    end, 20)
    truthy(res)
    eq(res.code, 0)
    truthy(res.fatal, "a bigger file will not shrink on the second try")
    eq(#echo_server.requests, 1, "asked once")
    eq(vim.uv.fs_stat(dest), nil, "nothing partial was left")
  end)

  it("downloads a file under the cap", function()
    local dest = tmpdir .. "/dl/small.bin"
    local res
    http.download(echo_server.url .. "/small", dest, { max_filesize = 1000, retries = 0, timeout = 8 }, function(r)
      res = r
    end)
    vim.wait(20000, function()
      return res ~= nil
    end, 20)
    eq(res.code, 200, tostring(res.error))
    eq(table.concat(vim.fn.readfile(dest), "\n"), "tiny")
    eq(vim.uv.fs_stat(dest .. ".headers"), nil, "the dump-header side file is cleaned too")
  end)

  it("does not delete a file that was already there when a download fails", function()
    local dest = tmpdir .. "/dl/precious.bin"
    vim.fn.mkdir(vim.fs.dirname(dest), "p")
    vim.fn.writefile({ "keep me" }, dest)
    local dead = mock_lib.start({})
    local dead_url = dead.url
    dead.stop()
    local res
    http.download(dead_url .. "/x", dest, { retries = 0, timeout = 4 }, function(r)
      res = r
    end)
    vim.wait(20000, function()
      return res ~= nil
    end, 20)
    eq(res.code, 0)
    eq(vim.fn.readfile(dest), { "keep me" })
  end)
end)

---The header lines of an echoed request, as a set. The mock strips the final
---CRLF of the header block, so matching on line ends would miss the last one.
---(回显请求的头行集合。mock 会去掉头块末尾的 CRLF，按行尾匹配会漏掉最后一行)
---@param text string
---@return table<string, boolean>
local function header_lines(text)
  local lines = {}
  for line in (text or ""):gmatch("[^\r\n]+") do
    lines[line] = true
  end
  return lines
end

describe("http origin and referer", function()
  it("follow the configured service root", function()
    local res = http.request_sync({ url = echo_server.url .. "/echo", retries = 0, timeout = 8 }, 20000)
    eq(res.code, 200, tostring(res.error))
    local lines = header_lines(res.body)
    truthy(lines["Origin: " .. server.url], "Origin: " .. tostring(res.body))
    truthy(lines["Referer: " .. server.url .. "/"], "Referer: " .. tostring(res.body))
  end)

  it("are read per request, not fixed when the module loads", function()
    local original = config.get().base_url
    config.get().base_url = "http://changed.example:9/"
    local res = http.request_sync({ url = echo_server.url .. "/echo", retries = 0, timeout = 8 }, 20000)
    config.get().base_url = original
    local lines = header_lines(res.body)
    truthy(lines["Origin: http://changed.example:9"], tostring(res.body))
    truthy(lines["Referer: http://changed.example:9/"], tostring(res.body))
  end)
end)

describe("http renewal is single-flight", function()
  it("renews once when several requests hit -2012 together", function()
    local state = { read = 0 }
    local read_server = mock_lib.start({
      {
        path = "/web/book/read",
        handler = function()
          state.read = state.read + 1
          if state.read <= 3 then
            return { status = 200, ctype = "application/json", body = '{"errCode":-2012,"errMsg":"登录超时"}' }
          end
          return { status = 200, ctype = "application/json", body = '{"ok":true}' }
        end,
      },
    })
    calls.renew = 0

    local results = {}
    for index = 1, 3 do
      http.request({
        url = read_server.url .. "/web/book/read",
        method = "POST",
        json = true,
        body = { n = index },
        timeout = 8,
      }, function(res)
        results[#results + 1] = res
      end)
    end
    vim.wait(30000, function()
      return #results == 3
    end, 20)

    eq(#results, 3, "every request got an answer")
    for _, res in ipairs(results) do
      eq(res.code, 200)
      matches(res.body, '"ok":true')
    end
    eq(calls.renew, 1, "the renewal endpoint was called once")
    truthy(auth.last_renewed_at() > 0, "and the renewal was recorded")
    read_server.stop()
  end)

  it("retries without renewing when the session was renewed after the request went out", function()
    local state = { read = 0 }
    local read_server = mock_lib.start({
      {
        path = "/web/book/read",
        handler = function()
          state.read = state.read + 1
          if state.read == 1 then
            return { status = 200, ctype = "application/json", body = '{"errCode":-2012,"errMsg":"登录超时"}' }
          end
          return { status = 200, ctype = "application/json", body = '{"ok":true}' }
        end,
      },
    })
    calls.renew = 0
    local original = auth.last_renewed_at
    auth.last_renewed_at = function()
      return vim.uv.hrtime() + 60 * 1e9 -- "a renewal finished after this request was sent"(此请求发出之后已有一次续期完成)
    end
    local res = http.request_sync({
      url = read_server.url .. "/web/book/read",
      method = "POST",
      json = true,
      body = {},
      timeout = 8,
    }, 30000)
    auth.last_renewed_at = original

    eq(res.code, 200)
    matches(res.body, '"ok":true')
    eq(state.read, 2, "sent again")
    eq(calls.renew, 0, "without another renewal")
    read_server.stop()
  end)
end)

describe("http cancellation and cleanup", function()
  it("a handle kills the request and its callback reports the cancel", function()
    local hang = hanging_server()
    local res
    local started = vim.uv.hrtime()
    local handle = http.request({ url = hang.url .. "/slow", timeout = 30, retries = 2 }, function(r)
      res = r
    end)
    vim.wait(300)
    eq(http._active_count(), 1, "the poll is in flight")
    handle.kill()
    vim.wait(10000, function()
      return res ~= nil
    end, 20)
    hang.stop()

    truthy(res, "the callback fired")
    eq(res.code, 0)
    eq(res.cancelled, true)
    truthy((vim.uv.hrtime() - started) / 1e9 < 10, "long before the 30 s timeout")
    eq(http._active_count(), 0)
    eq(tmp_leftovers(), {})
  end)

  it("a request that finished is not left in the active table", function()
    local res = http.request_sync({ url = echo_server.url .. "/small", retries = 0, timeout = 8 }, 20000)
    eq(res.code, 200)
    eq(http._active_count(), 0)
  end)

  it("kill_all stops everything in flight", function()
    local hang = hanging_server()
    local results = {}
    for _ = 1, 2 do
      http.request({ url = hang.url .. "/slow", timeout = 30, retries = 2 }, function(r)
        results[#results + 1] = r
      end)
    end
    vim.wait(300)
    eq(http._active_count(), 2)
    http.kill_all()
    eq(http._active_count(), 0)
    vim.wait(10000, function()
      return #results == 2
    end, 20)
    hang.stop()
    eq(#results, 2, "both callbacks fired")
    for _, res in ipairs(results) do
      eq(res.cancelled, true)
    end
  end)

  it("registers one VimLeavePre handler in its own group, however often setup runs", function()
    http.setup({ jar = config.path("cookies.txt"), tmpdir = config.path("tmp") })
    http.setup({ jar = config.path("cookies.txt"), tmpdir = config.path("tmp") })
    local found = vim.api.nvim_get_autocmds({ group = "WereadHttp", event = "VimLeavePre" })
    eq(#found, 1)
  end)

  it("kills in-flight requests when the editor is leaving", function()
    local hang = hanging_server()
    local res
    http.request({ url = hang.url .. "/slow", timeout = 30, retries = 0 }, function(r)
      res = r
    end)
    vim.wait(300)
    local found = vim.api.nvim_get_autocmds({ group = "WereadHttp", event = "VimLeavePre" })
    found[1].callback()
    vim.wait(10000, function()
      return res ~= nil
    end, 20)
    hang.stop()
    truthy(res)
    eq(res.cancelled, true)
  end)
end)

describe("http temp directory sweep", function()
  ---@param name string
  ---@param age integer seconds old(多少秒前)
  local function make(name, age)
    local path = config.path("tmp") .. "/" .. name
    vim.fn.writefile({ "x" }, path)
    local when = os.time() - age
    vim.uv.fs_utime(path, when, when)
    return path
  end

  it("removes old leftovers of its own and nothing else", function()
    local old_body = make("wr-1-1-body", 7200)
    local old_headers = make("wr-1-1-body.headers", 7200)
    local old_secret = make("wr-1-2-hdr", 7200)
    local fresh = make("wr-1-3-body", 10)
    local foreign = make("somebody-elses.json", 7200)
    local subdir = config.path("tmp") .. "/wr-old-dir"
    vim.fn.mkdir(subdir, "p")
    vim.uv.fs_utime(subdir, os.time() - 7200, os.time() - 7200)

    local removed = http.sweep_tmp()

    eq(removed, 3)
    eq(vim.uv.fs_stat(old_body), nil)
    eq(vim.uv.fs_stat(old_headers), nil)
    eq(vim.uv.fs_stat(old_secret), nil)
    truthy(vim.uv.fs_stat(fresh), "a recent file may belong to a live request")
    truthy(vim.uv.fs_stat(foreign), "files without our prefix are never touched")
    truthy(vim.uv.fs_stat(subdir), "directories are never touched")
    vim.fn.delete(fresh)
    vim.fn.delete(foreign)
    vim.fn.delete(subdir, "d")
  end)

  it("runs as part of setup", function()
    local old = make("wr-9-9-body", 7200)
    http.setup({ jar = config.path("cookies.txt"), tmpdir = config.path("tmp") })
    eq(vim.uv.fs_stat(old), nil)
  end)
end)

describe("http dead code", function()
  it("no longer carries the unused cookie and json helpers", function()
    eq(http.add_cookies, nil)
    eq(http.remove_cookies, nil)
    eq(http.get_json, nil)
    eq(http.post_json, nil)
    eq(type(http.cookie_header), "function", "cookie_header stays")
    eq(type(http.kill_all), "function")
  end)
end)

describe("http jar", function()
  it("reports a failed write from set_cookies", function()
    local original = http.jar_path()
    -- setup creates the jar's directory, so pull it out from under the jar afterwards
    -- (setup 会建出 jar 所在目录，所以事后再把目录抽掉)
    local dir = tmpdir .. "/jar-gone"
    http.setup({ jar = dir .. "/cookies.txt" })
    vim.fn.delete(dir, "rf")
    local ok, err = http.set_cookies({})
    http.setup({ jar = original })
    eq(ok, nil)
    truthy(err and err ~= "")
  end)

  it("keeps the jar private", function()
    http.set_cookies({ { name = "a", value = "1", domain = ".weread.qq.com", path = "/", expires = 0 } })
    eq(vim.fn.getfperm(http.jar_path()), "rw-------")
  end)
end)
