--[[
End-to-end test of the login state machine with the network and the UI
stubbed out. This is the only way to test the OTP branch and the credential
hand-off without a phone in the loop.
(登录状态机的端到端测试，网络与 UI 全部打桩；这是在“没有手机”的前提下唯一能
 覆盖 OTP 分支与凭据落地的方式)
]]

local tmpdir = vim.fn.tempname()
vim.fn.mkdir(tmpdir, "p")

-- ---------------------------------------------------------------- stubs

local notifications = {}
local inputs = {}

vim.notify = function(message, level)
  notifications[#notifications + 1] = { message = message, level = level }
end

local scripted_input = { "1234" }
vim.ui.input = function(opts, on_confirm)
  local next_value = table.remove(scripted_input, 1)
  on_confirm(next_value)
end

-- The login flow schedules its polls through weread.timer (which owns uv
-- handles). The stub below models that contract: queued callbacks that a
-- `stop` can cancel, so a stale poll scheduled before a terminal state cannot
-- fire afterwards.
-- (登录流程通过 weread.timer 调度轮询，它自己持有 uv 句柄。下面的桩复刻该契约：
--  排队回调可被 stop 取消，因此终态之前排队的旧轮询不会在之后诈尸)
local fake_timer = { queue = {}, next_id = 0 }

function fake_timer.defer(fn)
  fake_timer.next_id = fake_timer.next_id + 1
  local handle = { id = fake_timer.next_id, fn = fn, cancelled = false }
  fake_timer.queue[#fake_timer.queue + 1] = handle
  return handle
end

fake_timer.every = fake_timer.defer

function fake_timer.stop(handle)
  if type(handle) == "table" then
    handle.cancelled = true
  end
end

---Run every queued timer callback until none is left.
---(把所有排队的定时器回调跑完)
---@param limit integer|nil
local function drain(limit)
  limit = limit or 50
  local count = 0
  while true do
    local handle
    for index, candidate in ipairs(fake_timer.queue) do
      if not candidate.cancelled then
        handle = candidate
        table.remove(fake_timer.queue, index)
        break
      end
    end
    if not handle then
      break
    end
    count = count + 1
    if count > limit then
      error("timers did not settle: the poll never reached a terminal state")
    end
    handle.fn()
  end
  return count
end

package.loaded["weread.timer"] = fake_timer

-- vim.defer_fn still backs the API-key retry, which only needs to run soon.
-- (vim.defer_fn 仍用于 API Key 重试，只需尽快执行即可)
vim.defer_fn = function(fn)
  fn()
  return 0
end

local fake_http = {
  routes = {},
  requests = {},
  handles = {},
  jar = {},
}

function fake_http.setup() end
-- `path` selects the private login jar; without it this is the shared jar.
-- (path 选择私有的登录 jar；不传就是共享 jar)
function fake_http.load_cookies(path)
  if path then
    return vim.deepcopy(fake_http.login_jar)
  end
  return vim.deepcopy(fake_http.jar)
end
-- `jar_error` makes the next jar writes fail the way the real layer reports it.
-- (jar_error 让之后的 jar 写入按真实层的方式失败)
function fake_http.set_cookies(list, path)
  if fake_http.jar_error then
    return nil, fake_http.jar_error
  end
  if path then
    fake_http.login_jar = vim.deepcopy(list)
  else
    fake_http.jar = vim.deepcopy(list)
  end
  return true
end
function fake_http.clear_cookies(path)
  return fake_http.set_cookies({}, path)
end
function fake_http.decode_json(res)
  if not res or res.code == 0 or not res.body or res.body == "" then
    return nil, "request failed"
  end
  local ok, data = pcall(vim.json.decode, res.body)
  return ok and data or nil, ok and nil or "invalid JSON"
end

---@param pattern string substring the request url must contain
---@param responses table[] queued responses; drain order is first in, first out
function fake_http.expect(pattern, responses)
  fake_http.routes[#fake_http.routes + 1] = { pattern = pattern, queue = responses }
end

function fake_http.request(opts, callback)
  fake_http.requests[#fake_http.requests + 1] = opts
  -- Like the real client, hand back a handle that can abort the request.
  -- (与真实客户端一样，返回一个可中止请求的句柄)
  local handle = { killed = false }
  function handle.kill()
    handle.killed = true
  end
  fake_http.handles[#fake_http.handles + 1] = handle
  for _, route in ipairs(fake_http.routes) do
    if opts.url:find(route.pattern, 1, true) and #route.queue > 0 then
      local response = table.remove(route.queue, 1)
      if response == "hold" then
        -- The answer arrives later, when the spec calls `release`.
        -- (应答稍后到，由 spec 调用 release 触发)
        handle.release = function(result)
          callback(result)
        end
        return handle
      elseif type(response) == "table" and response.raise then
        error(response.raise)
      elseif response == "pending" then
        callback({ code = 0, error = "curl: (28) timed out", status = nil, headers = {} })
      else
        callback({
          code = response.status or 200,
          status = response.status or 200,
          body = type(response.body) == "table" and vim.json.encode(response.body) or response.body,
          headers = response.headers or {},
        })
      end
      return handle
    end
  end
  error("unexpected request or empty route queue: " .. opts.url)
end

local fake_qr = { shown = {} }
function fake_qr.show(text, opts)
  local entry = { text = text, title = opts and opts.title, opts = opts, footers = {}, titles = {} }
  fake_qr.shown[#fake_qr.shown + 1] = entry
  return {
    mode = "text",
    float = {
      width = 80,
      is_open = function()
        return true
      end,
      close = function()
        entry.closed = true
      end,
      set_title = function(_, title)
        entry.titles[#entry.titles + 1] = title
      end,
      set_footer = function(_, footer)
        entry.footers[#entry.footers + 1] = footer
      end,
    },
  },
  nil
end
function fake_qr.image_supported()
  return false
end

package.loaded["weread.http"] = fake_http
package.loaded["weread.qr"] = fake_qr

local config = require("weread.config")
config.setup({ data_dir = tmpdir })

local auth = require("weread.auth")
local http = require("weread.http")
local cookies = require("weread.cookies")

-- ---------------------------------------------------------------- helpers

local function reset()
  notifications = {}
  inputs = {}
  fake_http.routes = {}
  fake_http.requests = {}
  fake_http.handles = {}
  fake_http.jar = {}
  fake_http.login_jar = {}
  fake_http.jar_error = nil
  fake_qr.shown = {}
  scripted_input = { "1234" }
  fake_timer.queue = {}
  auth.cancel()
  -- credentials are cached in module state, so nuke the file and the cache
  -- (凭据被模块状态缓存，这里同时清掉文件与缓存)
  local path = auth.credentials_path()
  vim.fn.delete(path)
  package.loaded["weread.auth"] = nil
  auth = require("weread.auth")
end

---@return table[] cookies in the fake jar
local function jar()
  return http.load_cookies()
end

---@return table|nil cookie
local function jar_cookie(name)
  return cookies.get(jar(), name)
end

---@return table|nil credentials
local function credentials()
  local file = io.open(tmpdir .. "/credentials.json", "rb")
  if not file then
    return nil
  end
  local text = file:read("*a")
  file:close()
  return vim.json.decode(text)
end

---@return string[] messages
local function messages()
  local out = {}
  for _, entry in ipairs(notifications) do
    out[#out + 1] = entry.message
  end
  return out
end

---@param needle string
---@return boolean
local function notified(needle)
  for _, message in ipairs(messages()) do
    if message:find(needle, 1, true) then
      return true
    end
  end
  return false
end

local LOGIN_OK = {
  succeed = true,
  webLoginVid = "vid-0001",
  accessToken = "skey-0001",
  refreshToken = "refresh-0001",
}

-- ---------------------------------------------------------------- tests

describe("auth.login", function()
  it("walks the happy path: uid, QR, poll, credentials, api key", function()
    reset()
    fake_http.expect("/r/weread-skills", { { body = "<html>ok</html>" } })
    fake_http.expect("/api/auth/getLoginUid", { { body = { uid = "uid-1" } } })
    fake_http.expect("/api/auth/getLoginInfo", {
      "pending",
      { body = LOGIN_OK },
    })
    fake_http.expect("/api/userInfo", { { body = { name = "测试账号" } } })
    fake_http.expect("/api/skills/apikeyGet", { { body = { apikey = "wrk-test-key" } } })

    auth.login()
    drain()

    eq(#fake_qr.shown, 1, "one QR code")
    eq(fake_qr.shown[1].text, "https://weread.qq.com/web/confirm?uid=uid-1")

    truthy(auth.is_logged_in())
    eq(auth.account_name(), "测试账号")
    eq(auth.api_key(), "wrk-test-key")

    local stored = credentials()
    truthy(stored, "credentials.json written")
    eq(stored.cookies.wr_vid, "vid-0001")
    eq(stored.cookies.wr_skey, "skey-0001")
    eq(stored.cookies.wr_ql, "0")
    eq(stored.account.name, "测试账号")
    eq(stored.account.user_vid, "vid-0001")
    eq(stored.login_method, "qr")

    eq(vim.fn.getfperm(tmpdir .. "/credentials.json"), "rw-------", "0600 permissions")

    for _, name in ipairs({ "wr_vid", "wr_skey", "wr_ql", "wr_rt" }) do
      truthy(jar_cookie(name), "jar holds " .. name)
    end

    truthy(notified("登录成功"))
  end)

  it("asks for the OTP when the phone requires it", function()
    reset()
    scripted_input = { "4321" }
    fake_http.expect("/r/weread-skills", { { body = "ok" } })
    fake_http.expect("/api/auth/getLoginUid", { { body = { uid = "uid-2" } } })
    fake_http.expect("/api/auth/getLoginInfo", {
      { body = { logicCode = "NEED_OTP" } },
      { body = LOGIN_OK },
    })
    fake_http.expect("/api/userInfo", { { body = { name = "otp-user" } } })
    fake_http.expect("/api/skills/apikeyGet", { { body = { apikey = "wrk-otp" } } })

    auth.login()
    drain()

    local otp_request = nil
    for _, request in ipairs(fake_http.requests) do
      if request.url:find("getLoginInfo", 1, true) and request.url:find("otp=" .. "4321", 1, true) then
        otp_request = request
      end
    end
    truthy(otp_request, "poll carried the typed OTP")
    truthy(auth.is_logged_in())
  end)

  it("retries the OTP when the code is wrong", function()
    reset()
    scripted_input = { "0000", "9999" }
    fake_http.expect("/r/weread-skills", { { body = "ok" } })
    fake_http.expect("/api/auth/getLoginUid", { { body = { uid = "uid-3" } } })
    fake_http.expect("/api/auth/getLoginInfo", {
      { body = { logicCode = "NEED_OTP" } },
      { body = { logicCode = "OTP_NOT_MATCH" } },
      { body = LOGIN_OK },
    })
    fake_http.expect("/api/userInfo", { { body = { name = "n" } } })
    fake_http.expect("/api/skills/apikeyGet", { { body = { apikey = "wrk-x" } } })

    auth.login()
    drain()

    truthy(notified("验证码不正确"), "told the user the code was wrong")
    truthy(auth.is_logged_in(), "second attempt succeeded")
  end)

  it("keeps polling with the OTP after a delayed verification", function()
    reset()
    scripted_input = { "4321" }
    fake_http.expect("/r/weread-skills", { { body = "ok" } })
    fake_http.expect("/api/auth/getLoginUid", { { body = { uid = "uid-otp-late" } } })
    fake_http.expect("/api/auth/getLoginInfo", {
      { body = { logicCode = "NEED_OTP" } },
      -- the server has not finished verifying yet (服务端还没验完)
      "pending",
      { body = LOGIN_OK },
    })
    fake_http.expect("/api/userInfo", { { body = { name = "late-otp" } } })
    fake_http.expect("/api/skills/apikeyGet", { { body = { apikey = "wrk-late" } } })

    auth.login()
    drain()

    local with_otp = 0
    for _, request in ipairs(fake_http.requests) do
      if request.url:find("getLoginInfo", 1, true) and request.url:find("otp=4321", 1, true) then
        with_otp = with_otp + 1
      end
    end
    eq(with_otp, 2, "the retried poll still carried the code")
    truthy(auth.is_logged_in())
  end)

  it("recognises a numeric succeed flag", function()
    reset()
    fake_http.expect("/r/weread-skills", { { body = "ok" } })
    fake_http.expect("/api/auth/getLoginUid", { { body = { uid = "uid-num" } } })
    fake_http.expect("/api/auth/getLoginInfo", {
      {
        body = {
          succeed = 1,
          webLoginVid = "vid-num",
          accessToken = "skey-num",
          refreshToken = "refresh-num",
        },
      },
    })
    fake_http.expect("/api/userInfo", { { body = { name = "numeric" } } })
    fake_http.expect("/api/skills/apikeyGet", { { body = { apikey = "wrk-num" } } })

    auth.login()
    drain()

    truthy(auth.is_logged_in())
    eq(auth.account_name(), "numeric")
  end)

  it("turns a rejected login session into an expired QR instead of spinning", function()
    reset()
    fake_http.expect("/r/weread-skills", { { body = "ok" } })
    fake_http.expect("/api/auth/getLoginUid", { { body = { uid = "uid-revoked" } } })
    fake_http.expect("/api/auth/getLoginInfo", {
      {
        status = 401,
        body = {
          statusCode = 401,
          message = "Cgi Request Error",
          data = { errcode = -2013, errmsg = "鉴权失败" },
        },
      },
    })

    auth.login()
    drain()

    truthy(notified("二维码已过期"), "the dead session is surfaced")
    matches(fake_qr.shown[1].footers[#fake_qr.shown[1].footers], "二维码已过期")
    eq(credentials(), nil)
  end)

  it("runs the handshake in a private jar instead of the logged-in account", function()
    reset()
    fake_http.jar = {
      { name = "wr_vid", value = "old-vid", domain = ".weread.qq.com", path = "/", expires = 0 },
    }
    fake_http.expect("/r/weread-skills", { { body = "ok" } })
    fake_http.expect("/api/auth/getLoginUid", { { body = { uid = "uid-jar-iso" } } })
    fake_http.expect("/api/auth/getLoginInfo", { { body = LOGIN_OK } })
    fake_http.expect("/api/userInfo", { { body = { name = "iso" } } })
    fake_http.expect("/api/skills/apikeyGet", { { body = { apikey = "wrk-iso" } } })

    auth.login()
    drain()

    local handshake = 0
    for _, request in ipairs(fake_http.requests) do
      if
        request.url:find("/r/weread-skills", 1, true)
        or request.url:find("/api/auth/getLoginUid", 1, true)
        or request.url:find("/api/auth/getLoginInfo", 1, true)
      then
        handshake = handshake + 1
        eq(request.cookie_jar, auth.login_jar_path(), request.url)
      end
    end
    truthy(handshake >= 3, "all handshake requests were seen")
    truthy(auth.is_logged_in())
    eq(credentials().cookies.wr_vid, "vid-0001", "the confirmed account replaced the old one")
  end)

  it("keeps a successful login even when the WeRead skill is not enabled", function()
    reset()
    fake_http.expect("/r/weread-skills", { { body = "ok" } })
    fake_http.expect("/api/auth/getLoginUid", { { body = { uid = "uid-4" } } })
    fake_http.expect("/api/auth/getLoginInfo", { { body = LOGIN_OK } })
    fake_http.expect("/api/userInfo", { { body = { name = "no-skill" } } })
    fake_http.expect("/api/skills/apikeyGet", { { body = {} }, { body = {} }, { body = {} } })

    auth.login()
    drain()

    truthy(notified("未获取到官方 API Key"), "explains that the shelf needs the skill")
    truthy(notified("微信读书 Skill"), "and how to enable it")
    truthy(auth.is_logged_in(), "the cookie-authenticated reader is logged in")
    eq(auth.api_key(), nil)
    eq(credentials().account.name, "no-skill")
    truthy(jar_cookie("wr_vid"), "the new account's cookies are in the jar")
  end)

  it("expires the QR code after the session budget", function()
    reset()
    fake_http.expect("/r/weread-skills", { { body = "ok" } })
    fake_http.expect("/api/auth/getLoginUid", { { body = { uid = "uid-5" } } })
    fake_http.expect("/api/auth/getLoginInfo", { { body = LOGIN_OK } })

    local session = auth.login()
    local before = #fake_http.requests
    -- The deadline is monotonic; pushing it into the past simulates a budget
    -- that ran out without depending on the wall clock.
    -- (截止时间用单调时钟；把它推到过去即可模拟预算耗尽，不依赖系统时钟)
    session.deadline = vim.uv.hrtime() - 1
    drain()

    truthy(notified("二维码已过期"))
    eq(#fake_http.requests, before, "the expired session issued no poll")
    eq(credentials(), nil)
  end)

  it("stops polling after cancel", function()
    reset()
    fake_http.expect("/r/weread-skills", { { body = "ok" } })
    fake_http.expect("/api/auth/getLoginUid", { { body = { uid = "uid-6" } } })
    fake_http.expect("/api/auth/getLoginInfo", { { body = LOGIN_OK } })

    local session = auth.login()
    local before = #fake_http.requests
    auth.cancel()
    drain()
    auth._poll(session)

    eq(#fake_http.requests, before, "no further requests after cancel")
    eq(credentials(), nil)
    falsy(auth.is_logged_in())
  end)

  it("clears the old account first when the command has a bang", function()
    reset()
    auth.save_credentials({
      version = 1,
      api_key = "old-key",
      cookies = { wr_vid = "old", wr_skey = "old", wr_ql = "0", wr_rt = "old" },
    })
    fake_http.expect("/r/weread-skills", { { body = "ok" } })
    fake_http.expect("/api/auth/getLoginUid", { { body = { uid = "uid-force" } } })

    auth.login({ force = true })

    falsy(auth.is_logged_in(), "the old credentials are gone before the handshake")
    eq(#jar(), 0, "and so are the old cookies")
    eq(fake_qr.shown[1].title, "微信读书 · 请用微信扫码", "no switch-account hint")
    auth.cancel()
  end)

  it("fails cleanly when the login page is unreachable", function()
    reset()
    fake_http.expect("/r/weread-skills", { { status = 500, body = "boom" } })

    auth.login()

    truthy(notified("无法打开微信读书登录页"))
    falsy(auth.is_logged_in())
  end)
  it("keeps the dialog open on expiry and refreshes the code with r", function()
    reset()
    fake_http.expect("/r/weread-skills", { { body = "ok" }, { body = "ok" } })
    fake_http.expect("/api/auth/getLoginUid", { { body = { uid = "uid-old" } }, { body = { uid = "uid-new" } } })
    fake_http.expect("/api/auth/getLoginInfo", { { body = { logicCode = "LOGIN_TIMEOUT" } }, { body = LOGIN_OK } })
    fake_http.expect("/api/userInfo", { { body = { name = "refreshed" } } })
    fake_http.expect("/api/skills/apikeyGet", { { body = { apikey = "wrk-new" } } })

    auth.login()
    drain()

    local first = fake_qr.shown[1]
    truthy(notified("按 r 刷新"), "the expiry points at the refresh key")
    matches(first.footers[#first.footers], "二维码已过期")
    falsy(auth.is_logged_in())

    first.opts.actions.r()
    drain()

    eq(#fake_qr.shown, 2, "a second QR code")
    eq(fake_qr.shown[2].text, "https://weread.qq.com/web/confirm?uid=uid-new")
    truthy(auth.is_logged_in(), "the refreshed code logged in")
  end)

  it("closes an expired dialog without calling it a cancel", function()
    reset()
    fake_http.expect("/r/weread-skills", { { body = "ok" } })
    fake_http.expect("/api/auth/getLoginUid", { { body = { uid = "uid-x" } } })
    fake_http.expect("/api/auth/getLoginInfo", { { body = { logicCode = "LOGIN_TIMEOUT" } } })

    auth.login()
    drain()
    fake_qr.shown[1].opts.on_close()

    falsy(notified("已取消登录"))
  end)

  it("copies the confirm link with y", function()
    reset()
    fake_http.expect("/r/weread-skills", { { body = "ok" } })
    fake_http.expect("/api/auth/getLoginUid", { { body = { uid = "uid-copy" } } })

    auth.login()
    fake_qr.shown[1].opts.actions.y()

    eq(vim.fn.getreg('"'), "https://weread.qq.com/web/confirm?uid=uid-copy")
    truthy(notified("已复制登录链接"))
    auth.cancel()
  end)

  it("shows a countdown and the keys in the footer", function()
    reset()
    fake_http.expect("/r/weread-skills", { { body = "ok" } })
    fake_http.expect("/api/auth/getLoginUid", { { body = { uid = "uid-footer" } } })

    auth.login()

    local footers = fake_qr.shown[1].footers
    truthy(#footers > 0, "a footer was drawn")
    matches(footers[1], "等待扫码 [45]:%d%d")
    matches(footers[1], "r 刷新")
    auth.cancel()
  end)

  it("tells the user when the network keeps failing", function()
    reset()
    local refused = { status = 0, body = "" }
    fake_http.expect("/r/weread-skills", { { body = "ok" } })
    fake_http.expect("/api/auth/getLoginUid", { { body = { uid = "uid-net" } } })
    fake_http.expect("/api/auth/getLoginInfo", { refused, refused, refused, { body = LOGIN_OK } })
    fake_http.expect("/api/userInfo", { { body = { name = "n" } } })
    fake_http.expect("/api/skills/apikeyGet", { { body = { apikey = "wrk-net" } } })

    auth.login()
    drain()

    local saw = false
    for _, footer in ipairs(fake_qr.shown[1].footers) do
      if footer:find("网络异常", 1, true) then
        saw = true
      end
    end
    truthy(saw, "the footer reported the network")
    truthy(auth.is_logged_in(), "polling carried on and succeeded")
  end)
end)

describe("auth.apply_cookies", function()
  it("rebuilds the jar from credentials and drops duplicates", function()
    reset()
    -- a stale duplicate is the documented cause of `登录超时`
    -- (重复的旧 cookie 是官方文档记录的「登录超时」成因)
    fake_http.jar = {
      { name = "wr_skey", value = "stale", domain = ".weread.qq.com", path = "/", expires = 0 },
      { name = "wr_skey", value = "stale-2", domain = ".weread.qq.com", path = "/", expires = 0 },
    }
    auth.save_credentials({
      version = 1,
      account = { name = "n", user_vid = "v" },
      api_key = "k",
      cookies = { wr_vid = "v", wr_skey = "fresh", wr_ql = "0", wr_rt = "r" },
    })

    local count = 0
    for _, cookie in ipairs(jar()) do
      if cookie.name == "wr_skey" then
        count = count + 1
        eq(cookie.value, "fresh")
      end
    end
    eq(count, 1, "exactly one wr_skey")
  end)
end)

describe("auth.describe_error", function()
  it("maps the documented error codes to actions", function()
    matches(auth.describe_error({ errCode = -2012 }), ":WeReadLogin")
    matches(auth.describe_error({ errCode = -2010 }), ":WeReadLogin")
    eq(auth.describe_error({ errCode = -1, errMsg = "自定义错误" }), "自定义错误")
    eq(auth.describe_error({}), nil)
    eq(auth.describe_error(nil), nil)
  end)
end)

describe("auth.logout", function()
  it("clears credentials and the cookie jar", function()
    reset()
    auth.save_credentials({
      version = 1,
      account = { name = "n", user_vid = "v" },
      api_key = "k",
      cookies = { wr_vid = "v", wr_skey = "s", wr_ql = "0", wr_rt = "r" },
    })
    truthy(auth.is_logged_in())

    auth.logout()

    falsy(auth.is_logged_in())
    eq(#jar(), 0, "jar emptied")
    eq(vim.fn.filereadable(auth.credentials_path()), 0, "credentials removed")
  end)
end)

-- ---------------------------------------------------------------- hardening
-- (加固相关)

local RENEWED = { code = 200, status = 200, body = '{"succ":1,"errCode":0}', headers = {} }

---@param list string[]
---@param needle string
---@return boolean
local function any_request(needle)
  for _, request in ipairs(fake_http.requests) do
    if request.url:find(needle, 1, true) then
      return true
    end
  end
  return false
end

describe("auth login when the cookie jar cannot be written", function()
  it("fails the login with the reason instead of hanging on the finishing dialog", function()
    reset()
    fake_http.expect("/r/weread-skills", { { body = "ok" } })
    fake_http.expect("/api/auth/getLoginUid", { { body = { uid = "uid-jar" } } })
    fake_http.expect("/api/auth/getLoginInfo", { { body = LOGIN_OK } })

    auth.login()
    -- The private login jar was created already; make the next write (writing
    -- the confirmed credentials into it) fail.
    -- (私有登录 jar 已经创建；让下一次写入——把确认后的凭据写进去——失败)
    fake_http.jar_error = "disk full"
    drain()

    truthy(notified("登录凭据写入失败"), "the failure is reported")
    truthy(notified("disk full"), "with its reason")
    truthy(fake_qr.shown[1].closed, "the dialog was closed, not left on 正在完成登录")
    falsy(any_request("/api/userInfo"), "nothing was requested with a stale jar")
    falsy(any_request("/api/skills/apikeyGet"))
    falsy(auth.is_logged_in())
    eq(credentials(), nil)
  end)

  it("also copes with a jar write that raises", function()
    reset()
    fake_http.expect("/r/weread-skills", { { body = "ok" } })
    fake_http.expect("/api/auth/getLoginUid", { { body = { uid = "uid-jar2" } } })
    fake_http.expect("/api/auth/getLoginInfo", { { body = LOGIN_OK } })
    auth.login()
    local original = fake_http.set_cookies
    fake_http.set_cookies = function()
      error("boom")
    end

    local ok = pcall(function()
      drain()
    end)
    fake_http.set_cookies = original

    truthy(ok, "the login flow did not blow up")
    truthy(notified("登录凭据写入失败"))
    truthy(notified("boom"))
    truthy(fake_qr.shown[1].closed)
  end)

  it("save_credentials raises when the jar cannot be written", function()
    reset()
    fake_http.jar_error = "read-only file system"
    local ok, err = pcall(auth.save_credentials, {
      version = 1,
      api_key = "k",
      cookies = { wr_vid = "v", wr_skey = "s", wr_ql = "0", wr_rt = "r" },
    })
    falsy(ok)
    matches(err, "read%-only file system")
  end)

  it("logout still removes the credentials when the jar cannot be emptied", function()
    reset()
    auth.save_credentials({
      version = 1,
      api_key = "k",
      cookies = { wr_vid = "v", wr_skey = "s", wr_ql = "0", wr_rt = "r" },
    })
    fake_http.jar_error = "disk full"
    local ok = pcall(auth.logout)
    truthy(ok, "logout does not raise")
    eq(vim.fn.filereadable(auth.credentials_path()), 0)
    falsy(auth.is_logged_in())
  end)
end)

describe("auth credentials on disk", function()
  local function stale_backups()
    local found = {}
    for name in vim.fs.dir(tmpdir) do
      if name:find("credentials.json.corrupt-", 1, true) then
        found[#found + 1] = tmpdir .. "/" .. name
      end
    end
    return found
  end

  local function remove_backups()
    for _, path in ipairs(stale_backups()) do
      vim.fn.delete(path)
    end
  end

  it("writes atomically with mode 0600 and leaves no temp file", function()
    reset()
    auth.save_credentials({
      version = 1,
      api_key = "k",
      cookies = { wr_vid = "v", wr_skey = "s", wr_ql = "0", wr_rt = "r" },
    })
    eq(vim.fn.getfperm(auth.credentials_path()), "rw-------")
    for name in vim.fs.dir(tmpdir) do
      falsy(name:find("credentials.json.tmp", 1, true), "stray temp file " .. name)
    end
  end)

  it("keeps the old credentials when the write fails", function()
    if vim.env.USER == "root" then
      return -- root ignores directory permissions(root 不受目录权限约束)
    end
    reset()
    local original = {
      version = 1,
      api_key = "old-key",
      cookies = { wr_vid = "v", wr_skey = "s", wr_ql = "0", wr_rt = "r" },
    }
    auth.save_credentials(original)

    -- ensure_dirs adjusts the data directory's permissions; keep it out of the
    -- way so the read-only directory is what the write actually meets.
    -- (ensure_dirs 会调整数据目录的权限；让它别插手，写入遇到的才是那个只读目录)
    local ensure_dirs = config.ensure_dirs
    config.ensure_dirs = function()
      return tmpdir
    end
    vim.uv.fs_chmod(tmpdir, 360) -- 0550
    local ok, err = pcall(auth.save_credentials, vim.tbl_extend("force", original, { api_key = "new-key" }))
    vim.uv.fs_chmod(tmpdir, 493) -- 0755
    config.ensure_dirs = ensure_dirs

    falsy(ok)
    matches(err, "could not write credentials")
    eq(credentials().api_key, "old-key", "the file on disk is the old one")
  end)

  it("warns once and keeps a backup when the file is corrupt", function()
    reset()
    remove_backups()
    vim.fn.writefile({ "{this is not json" }, auth.credentials_path())

    eq(auth.load_credentials(), nil)
    falsy(auth.is_logged_in())
    truthy(notified("登录文件损坏"), "the user is told")
    truthy(notified(".corrupt-"), "and where the backup went")
    truthy(notified("重新登录"))
    eq(vim.uv.fs_stat(auth.credentials_path()), nil, "the bad file is out of the way")
    eq(#stale_backups(), 1)

    local count = #notifications
    auth.load_credentials()
    auth.is_logged_in()
    eq(#notifications, count, "no second warning")
    remove_backups()
  end)

  it("treats valid JSON that is not an object as corrupt too", function()
    reset()
    remove_backups()
    vim.fn.writefile({ "null" }, auth.credentials_path())
    eq(auth.load_credentials(), nil)
    truthy(notified("登录文件损坏"))
    remove_backups()
  end)

  it("stays quiet when there is simply no credentials file", function()
    reset()
    eq(auth.load_credentials(), nil)
    falsy(notified("登录文件损坏"))
    eq(#notifications, 0)
  end)
end)

describe("auth.renew is single-flight", function()
  it("sends one request for concurrent callers and answers all of them", function()
    reset()
    fake_http.expect("/web/login/renewal", { "hold" })
    local answers = {}
    for index = 1, 3 do
      auth.renew(function(ok, err)
        answers[index] = { ok = ok, err = err }
      end)
    end

    local renewals = 0
    for _, request in ipairs(fake_http.requests) do
      if request.url:find("/web/login/renewal", 1, true) then
        renewals = renewals + 1
      end
    end
    eq(renewals, 1, "three callers, one request")
    eq(#answers, 0, "nobody has an answer yet")

    fake_http.handles[1].release(RENEWED)

    eq(#answers, 3, "all three were answered together")
    for index = 1, 3 do
      eq(answers[index].ok, true)
    end
    truthy(auth.last_renewed_at() > 0, "the success is recorded")
  end)

  it("starts a fresh renewal once the previous one is done", function()
    reset()
    fake_http.expect("/web/login/renewal", { RENEWED, RENEWED })
    auth.renew()
    auth.renew()
    local renewals = 0
    for _, request in ipairs(fake_http.requests) do
      if request.url:find("/web/login/renewal", 1, true) then
        renewals = renewals + 1
      end
    end
    eq(renewals, 2)
  end)

  it("passes a failure to every waiter and records no renewal", function()
    reset()
    fake_http.expect("/web/login/renewal", { "hold", RENEWED })
    local answers = {}
    for index = 1, 2 do
      auth.renew(function(ok, err)
        answers[index] = { ok = ok, err = err }
      end)
    end
    fake_http.handles[1].release({ code = 0, status = nil, error = "refused", headers = {} })

    eq(#answers, 2)
    eq(answers[1].ok, false)
    eq(answers[2].ok, false)
    matches(answers[1].err, "续期请求失败")
    eq(auth.last_renewed_at(), 0, "a failure is not a renewal")

    local again
    auth.renew(function(ok)
      again = ok
    end)
    eq(again, true, "and the next call is not stuck behind the failed one")
  end)

  it("does not stay wedged when the request raises before calling back", function()
    reset()
    fake_http.expect("/web/login/renewal", { { raise = "spawn exploded" }, RENEWED })
    local first
    auth.renew(function(ok, err)
      first = { ok = ok, err = err }
    end)
    eq(first.ok, false)
    matches(first.err, "spawn exploded")

    local second
    auth.renew(function(ok)
      second = ok
    end)
    eq(second, true, "the next renewal goes through")
  end)

  it("lets one failing waiter not strand the others", function()
    reset()
    fake_http.expect("/web/login/renewal", { "hold" })
    local last
    auth.renew(function()
      error("waiter blew up")
    end)
    auth.renew(function(ok)
      last = ok
    end)
    fake_http.handles[1].release(RENEWED)
    eq(last, true)
  end)

  it("mirrors the refreshed cookies into credentials.json", function()
    reset()
    auth.save_credentials({
      version = 1,
      api_key = "k",
      cookies = { wr_vid = "v", wr_skey = "old-skey", wr_ql = "0", wr_rt = "r" },
    })
    -- what curl would have persisted into the jar(curl 会写进 jar 的内容)
    fake_http.jar = {
      { name = "wr_skey", value = "new-skey", domain = ".weread.qq.com", path = "/", expires = 0 },
    }
    fake_http.expect("/web/login/renewal", { RENEWED })
    local result
    auth.renew(function(ok)
      result = ok
    end)
    eq(result, true)
    eq(credentials().cookies.wr_skey, "new-skey")
    eq(vim.fn.getfperm(auth.credentials_path()), "rw-------")
  end)
end)

describe("auth.cancel aborts the login long poll", function()
  it("kills the poll in flight and ignores its late answer", function()
    reset()
    fake_http.expect("/r/weread-skills", { { body = "ok" } })
    fake_http.expect("/api/auth/getLoginUid", { { body = { uid = "uid-cancel" } } })
    fake_http.expect("/api/auth/getLoginInfo", { "hold" })
    fake_http.expect("/api/userInfo", { { body = { name = "must-not-happen" } } })

    auth.login()
    drain()
    local poll = fake_http.handles[#fake_http.handles]
    falsy(poll.killed, "the poll is running")

    auth.cancel()
    truthy(poll.killed, "cancel aborted the poll")

    poll.release({ code = 200, status = 200, body = vim.json.encode(LOGIN_OK), headers = {} })
    falsy(any_request("/api/userInfo"), "the late success changed nothing")
    falsy(auth.is_logged_in())
    eq(credentials(), nil)
  end)

  it("does not touch requests that are not the poll", function()
    reset()
    fake_http.expect("/r/weread-skills", { { body = "ok" } })
    fake_http.expect("/api/auth/getLoginUid", { { body = { uid = "uid-cancel2" } } })
    auth.login()
    auth.cancel()
    for _, handle in ipairs(fake_http.handles) do
      falsy(handle.killed)
    end
  end)

  it("a new login replaces the old poll", function()
    reset()
    fake_http.expect("/r/weread-skills", { { body = "ok" }, { body = "ok" } })
    fake_http.expect("/api/auth/getLoginUid", { { body = { uid = "uid-a" } }, { body = { uid = "uid-b" } } })
    fake_http.expect("/api/auth/getLoginInfo", { "hold", "hold" })
    auth.login()
    drain()
    local first = fake_http.handles[#fake_http.handles]
    auth.login()
    truthy(first.killed, "starting over cancels the previous attempt's poll")
  end)
end)

describe("auth service root", function()
  it("is built from config.web_origin, trailing slash and all", function()
    config.setup({ data_dir = tmpdir, base_url = "https://example.test/" })
    eq(auth.skills_url(), "https://example.test/r/weread-skills")
    eq(auth.renewal_url(), "https://example.test/web/login/renewal")
    config.setup({ data_dir = tmpdir })
    eq(auth.skills_url(), "https://weread.qq.com/r/weread-skills")
  end)

  it("no longer carries the unused change listeners and header helper", function()
    eq(auth.on_change, nil)
    eq(auth.api_headers, nil)
  end)
end)
