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

-- Deferred callbacks are queued into a stopable timer table instead of running
-- immediately. `vim.fn.timer_stop` cancels them exactly like the real thing, so
-- a stale poll scheduled before a terminal state cannot fire afterwards, and a
-- test can observe the flow between steps.
-- (延迟回调进入可停止的定时器表，而非立即执行；timer_stop 能像真实实现一样取消它，
--  因此终态之前排队的旧轮询不会在之后诈尸，测试也能在步骤之间做观察)
local timers = {}
local timer_seq = 0
vim.defer_fn = function(fn)
  timer_seq = timer_seq + 1
  timers[timer_seq] = fn
  return timer_seq
end
vim.fn.timer_stop = function(id)
  timers[id] = nil
end

---Run every queued timer until none is left.
---(把所有排队的定时器跑完)
---@param limit integer|nil
local function drain(limit)
  limit = limit or 50
  local count = 0
  while true do
    local id, fn = next(timers)
    if not id then
      break
    end
    timers[id] = nil
    count = count + 1
    if count > limit then
      error("timers did not settle: the poll never reached a terminal state")
    end
    fn()
  end
  return count
end

local fake_http = {
  routes = {},
  requests = {},
  jar = {},
}

function fake_http.setup() end
function fake_http.load_cookies()
  return vim.deepcopy(fake_http.jar)
end
function fake_http.set_cookies(list)
  fake_http.jar = vim.deepcopy(list)
end
function fake_http.clear_cookies()
  fake_http.jar = {}
end
function fake_http.cookie_header()
  return ""
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
  for _, route in ipairs(fake_http.routes) do
    if opts.url:find(route.pattern, 1, true) and #route.queue > 0 then
      local response = table.remove(route.queue, 1)
      if response == "pending" then
        callback({ code = 0, error = "curl: (28) timed out", status = nil, headers = {} })
      else
        callback({
          code = response.status or 200,
          status = response.status or 200,
          body = type(response.body) == "table" and vim.json.encode(response.body) or response.body,
          headers = response.headers or {},
        })
      end
      return
    end
  end
  error("unexpected request or empty route queue: " .. opts.url)
end

local fake_qr = { shown = {} }
function fake_qr.show(text, opts)
  fake_qr.shown[#fake_qr.shown + 1] = { text = text, title = opts and opts.title }
  return {
    mode = "ascii",
    float = {
      is_open = function()
        return true
      end,
      close = function() end,
      set_title = function() end,
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
  fake_http.jar = {}
  fake_qr.shown = {}
  scripted_input = { "1234" }
  for key in pairs(timers) do
    timers[key] = nil
  end
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

  it("reports an account without the WeRead skill enabled", function()
    reset()
    fake_http.expect("/r/weread-skills", { { body = "ok" } })
    fake_http.expect("/api/auth/getLoginUid", { { body = { uid = "uid-4" } } })
    fake_http.expect("/api/auth/getLoginInfo", { { body = LOGIN_OK } })
    fake_http.expect("/api/userInfo", { { body = { name = "no-skill" } } })
    fake_http.expect("/api/skills/apikeyGet", { { body = {} }, { body = {} }, { body = {} } })

    auth.login()
    drain()

    truthy(notified("微信读书 Skill"), "explains how to enable the skill")
    eq(credentials(), nil, "nothing persisted without an API key")
    falsy(auth.is_logged_in())
  end)

  it("expires the QR code after the session budget", function()
    reset()
    fake_http.expect("/r/weread-skills", { { body = "ok" } })
    fake_http.expect("/api/auth/getLoginUid", { { body = { uid = "uid-5" } } })
    fake_http.expect("/api/auth/getLoginInfo", { { body = LOGIN_OK } })

    local session = auth.login()
    local before = #fake_http.requests
    session.started = os.time() - 4000
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

  it("fails cleanly when the login page is unreachable", function()
    reset()
    fake_http.expect("/r/weread-skills", { { status = 500, body = "boom" } })

    auth.login()

    truthy(notified("无法打开微信读书登录页"))
    falsy(auth.is_logged_in())
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
