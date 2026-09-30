--[[
Account layer: QR login, credential storage, cookie renewal.
(账号层：扫码登录、凭据存储、cookie 续期)

Protocol notes, all of them verified against the live service:
(协议要点，均已对线上服务实测)

* `GET /r/weread-skills` bootstraps an anonymous session.
* `GET /api/auth/getLoginUid` returns `{uid}`; the QR payload is
  `https://weread.qq.com/web/confirm?uid=<uid>`.
* `GET /api/auth/getLoginInfo?uid=&otp=` long-polls. It answers with
  `{succeed:true, webLoginVid, accessToken, refreshToken}` once the phone
  confirms, `{logicCode:"NEED_OTP"}` when the phone shows a four digit code,
  `OTP_NOT_MATCH` / `OTP_EXPIRED` / `LOGIN_TIMEOUT` for the other outcomes,
  and simply times out while nothing has happened yet.
* Credentials are returned in the JSON body, **not** in Set-Cookie headers, so
  the jar has to be written by hand.
* `/api/*` calls authenticate with the `X-Vid` + `X-Skey` headers.
]]

local P = require("weread.protocol")
local cookies = require("weread.cookies")
local config = require("weread.config")
local http = require("weread.http")
local log = require("weread.log")
local qr = require("weread.qr")

local M = {}

local BASE = "https://weread.qq.com"

M.SKILLS_URL = BASE .. "/r/weread-skills"
M.LOGIN_UID_URL = BASE .. "/api/auth/getLoginUid"
M.LOGIN_INFO_URL = BASE .. "/api/auth/getLoginInfo"
M.USER_INFO_URL = BASE .. "/api/userInfo"
M.API_KEY_URL = BASE .. "/api/skills/apikeyGet?only_show=1"
M.RENEWAL_URL = BASE .. "/web/login/renewal"

---Long poll budget in seconds. A curl timeout here is the normal idle state,
---not an error, which is why the poll runs without retries.
---(长轮询超时；curl 超时在这里代表“还没扫码”，是正常状态，因此轮询不做重试)
local POLL_TIMEOUT = 8
local POLL_INTERVAL_MS = 1500
local SESSION_TIMEOUT = 300
local CREDENTIAL_COOKIES = { "wr_vid", "wr_skey", "wr_ql", "wr_rt" }

local state = {
  generation = 0,
  session = nil,
  credentials = nil,
  loaded = false,
  listeners = {},
}

local function notify(message, level)
  vim.notify("weread: " .. message, level or vim.log.levels.INFO)
end

function M.on_change(listener)
  state.listeners[#state.listeners + 1] = listener
end

local function notify_change()
  for _, listener in ipairs(state.listeners) do
    pcall(listener)
  end
end

---@return string
function M.credentials_path()
  return config.path("credentials.json")
end

---@return table|nil
function M.load_credentials()
  if state.loaded then
    return state.credentials
  end
  state.loaded = true
  local path = M.credentials_path()
  if vim.fn.filereadable(path) == 0 then
    return nil
  end
  local file = io.open(path, "rb")
  if not file then
    return nil
  end
  local text = file:read("*a")
  file:close()
  local ok, data = pcall(vim.json.decode, text or "")
  if not ok or type(data) ~= "table" then
    log.warn("credentials.json is not valid JSON; ignoring it")
    return nil
  end
  state.credentials = data
  return data
end

---@param cookie table
---@return table
local function credential_row(cookie)
  return {
    name = cookie.name,
    value = cookie.value or "",
    domain = ".weread.qq.com",
    include_subdomains = true,
    path = "/",
    secure = true,
    http_only = true,
    expires = os.time() + 30 * 24 * 3600,
  }
end

---Push the stored credentials into the curl cookie jar.
---(把存档中的凭据写回 curl cookie jar)
function M.apply_cookies()
  local credentials = M.load_credentials()
  if not credentials or type(credentials.cookies) ~= "table" then
    return false
  end
  local jar = http.load_cookies()
  -- Stale duplicates of wr_skey/wr_rt are a documented cause of `登录超时`.
  -- (重复的 wr_skey/wr_rt 是官方文档记录的「登录超时」成因，先清再写)
  for _, name in ipairs(CREDENTIAL_COOKIES) do
    jar = cookies.remove(jar, name)
  end
  for _, name in ipairs(CREDENTIAL_COOKIES) do
    local value = credentials.cookies[name]
    if type(value) == "string" then
      cookies.upsert(jar, credential_row({ name = name, value = value }))
    end
  end
  http.set_cookies(jar)
  return true
end

---@param credentials table
function M.save_credentials(credentials)
  config.ensure_dirs()
  local path = M.credentials_path()
  local tmp = path .. ".tmp"
  local file = assert(io.open(tmp, "wb"))
  file:write(vim.json.encode(credentials))
  file:close()
  pcall(vim.uv.fs_chmod, tmp, 384) -- 0600(凭据文件权限)
  local ok, err = vim.uv.fs_rename(tmp, path)
  if not ok then
    os.remove(tmp)
    error("could not write credentials: " .. tostring(err))
  end
  state.credentials = credentials
  state.loaded = true
  M.apply_cookies()
  notify_change()
end

---@return boolean
function M.is_logged_in()
  local credentials = M.load_credentials()
  if not credentials or type(credentials.cookies) ~= "table" then
    return false
  end
  return (credentials.cookies.wr_vid or "") ~= "" and (credentials.cookies.wr_skey or "") ~= ""
end

---@return string|nil
function M.account_name()
  local credentials = M.load_credentials()
  local name = credentials and credentials.account and credentials.account.name
  if type(name) == "string" and name ~= "" then
    return name
  end
  return nil
end

---@return string|nil
function M.api_key()
  local credentials = M.load_credentials()
  local key = credentials and credentials.api_key
  if type(key) == "string" and key ~= "" then
    return key
  end
  return nil
end

---@return string|nil vid
---@return string|nil skey
function M.api_headers()
  local credentials = M.load_credentials()
  if not credentials or type(credentials.cookies) ~= "table" then
    return nil, nil
  end
  return credentials.cookies.wr_vid, credentials.cookies.wr_skey
end

---Turn a WeRead error payload into a Chinese action hint.
---(把微信读书的错误负载翻译成可执行的中文提示)
---Field casing differs between services: the web API answers `errCode`,
---while the Agent gateway answers `errcode`. Both must be understood.
---(不同服务的字段大小写不一致：网页 API 返回 `errCode`，Agent gateway 返回
--- `errcode`，两者都要能识别)
---@param data table|nil
---@return string|nil
function M.describe_error(data)
  if type(data) ~= "table" then
    return nil
  end
  local code = tonumber(data.errCode or data.errcode)
  if code == -2012 then
    return "登录已过期，请执行 :WeReadLogin 重新扫码"
  elseif code == -2010 then
    return "未登录或凭据无效，请执行 :WeReadLogin"
  end
  local message = data.errMsg or data.errmsg
  if type(message) == "string" and message ~= "" then
    return message
  end
  return nil
end

---Report a WeRead error payload to the user when it carries one.
---(当响应带错误时提示用户)
---@param data table|nil
---@return boolean ok
function M.check(data)
  local message = M.describe_error(data)
  if message then
    notify(message, vim.log.levels.WARN)
    return false
  end
  return true
end

---POST /web/login/renewal, refreshing and persisting the session cookies.
---(续期：刷新并落盘会话 cookie)
---@param callback fun(ok: boolean, err: string|nil)
function M.renew(callback)
  callback = callback or function() end
  http.request({
    url = M.RENEWAL_URL,
    method = "POST",
    json = true,
    body = { rq = "%2Fweb%2Fbook%2Fread", ql = false },
    timeout = 15,
    persist = true,
  }, function(res)
    local data = http.decode_json(res)
    if not data then
      callback(false, "续期请求失败")
      return
    end
    if not P.is_success_response(data) then
      local message = M.describe_error(data) or "会话续期失败"
      callback(false, message)
      return
    end

    -- curl persisted the refreshed Set-Cookie values; mirror them back into
    -- credentials.json so the next nvim start uses the newest tokens.
    -- (curl 已落盘刷新后的 Set-Cookie；同步回 credentials.json，供下次启动使用)
    local credentials = M.load_credentials()
    if credentials then
      local jar = http.load_cookies()
      credentials.cookies = credentials.cookies or {}
      for _, name in ipairs(CREDENTIAL_COOKIES) do
        local cookie = cookies.get(jar, name)
        if cookie and cookie.value ~= "" then
          credentials.cookies[name] = cookie.value
        end
      end
      local ok = pcall(M.save_credentials, credentials)
      if not ok then
        log.warn("could not persist renewed cookies")
      end
    end
    log.info("session renewed")
    callback(true, nil)
  end)
end

---@return table|nil
local function new_session()
  state.generation = state.generation + 1
  local session = {
    generation = state.generation,
    started = os.time(),
    dialog = nil,
    uid = nil,
    timer = nil,
  }
  state.session = session
  return session
end

local function set_title(session, title)
  if session.dialog and session.dialog.float and session.dialog.float:is_open() then
    session.dialog.float:set_title(title)
  end
end

local function stop_timer(session)
  require("weread.timer").stop(session.timer)
  session.timer = nil
end

local function close_dialog(session)
  stop_timer(session)
  if session.dialog then
    session.dialog.float:close()
    session.dialog = nil
  end
end

---@param session table
---@param message string
---@param is_error boolean|nil
local function finish(session, message, is_error)
  if session.generation ~= state.generation then
    return
  end
  close_dialog(session)
  state.session = nil
  if is_error then
    log.warn("login failed: %s", message)
    notify(message, vim.log.levels.ERROR)
  else
    log.info("login finished: %s", message)
    notify(message)
  end
end

local function is_current(session)
  return session.generation == state.generation
end

---@param session table
local function schedule_poll(session)
  if not is_current(session) then
    return
  end
  require("weread.timer").stop(session.timer)
  session.timer = require("weread.timer").defer(function()
    session.timer = nil
    M._poll(session)
  end, POLL_INTERVAL_MS)
end

---@param session table
---@param message string|nil
local function ask_otp(session, message)
  if not is_current(session) then
    return
  end
  stop_timer(session)
  set_title(session, "请输入手机上的 4 位验证码")
  if message then
    notify(message, vim.log.levels.WARN)
  end
  vim.ui.input({ prompt = "微信读书 4 位验证码: " }, function(input)
    if not is_current(session) then
      return
    end
    local otp = vim.trim(input or "")
    if otp == "" then
      finish(session, "已取消登录", true)
      return
    end
    if not otp:match("^%d%d%d%d$") then
      ask_otp(session, "验证码必须是 4 位数字")
      return
    end
    set_title(session, "正在校验验证码…")
    M._poll(session, otp)
  end)
end

---@param session table
---@param code string
local function handle_logic_code(session, code)
  if code == "NEED_OTP" then
    ask_otp(session)
  elseif code == "OTP_NOT_MATCH" then
    ask_otp(session, "验证码不正确，请重试")
  elseif code == "OTP_EXPIRED" then
    finish(session, "验证码已过期，请重新执行 :WeReadLogin", true)
  elseif code == "LOGIN_TIMEOUT" then
    finish(session, "二维码已过期，请重新执行 :WeReadLogin", true)
  else
    finish(session, "登录失败：" .. code, true)
  end
end

---Poll the login state once. Exposed for tests and for the timer callback.
---(轮询一次登录状态；供定时器与测试调用)
---@param session table
---@param otp string|nil
function M._poll(session, otp)
  if not is_current(session) then
    return
  end
  if os.time() - session.started > SESSION_TIMEOUT then
    finish(session, "二维码已过期，请重新执行 :WeReadLogin", true)
    return
  end

  local url = M.LOGIN_INFO_URL .. "?uid=" .. P.urlencode(session.uid) .. "&otp=" .. P.urlencode(otp or "")
  http.request({
    url = url,
    referer = M.SKILLS_URL,
    timeout = POLL_TIMEOUT,
    retries = 0,
    persist = true,
  }, function(res)
    if not is_current(session) then
      return
    end
    local data = http.decode_json(res)
    if not data then
      -- Nothing happened yet: curl gives up on the long poll and we try again.
      -- (还没有人扫码：curl 结束长轮询后重新发起)
      log.debug("login poll pending (%s)", tostring(res.error or res.status))
      schedule_poll(session)
      return
    end
    if data.succeed == true then
      M._complete(session, data)
      return
    end
    local code = tostring(data.logicCode or "")
    if code == "" then
      log.debug("login poll returned no logicCode: %s", vim.json.encode(data))
      schedule_poll(session)
      return
    end
    handle_logic_code(session, code)
  end)
end

---Exchange a successful login result for credentials and persist them.
---(把登录结果换成凭据并落盘)
---@param session table
---@param login_result table
function M._complete(session, login_result)
  local vid = tostring(login_result.webLoginVid or "")
  local skey = tostring(login_result.accessToken or "")
  local refresh = tostring(login_result.refreshToken or "")
  if vid == "" or skey == "" then
    finish(session, "登录响应缺少账号凭据", true)
    return
  end

  set_title(session, "正在完成登录…")

  local jar = http.load_cookies()
  for _, name in ipairs(CREDENTIAL_COOKIES) do
    jar = cookies.remove(jar, name)
  end
  local rows = {
    credential_row({ name = "wr_vid", value = vid }),
    credential_row({ name = "wr_skey", value = skey }),
    credential_row({ name = "wr_ql", value = "0" }),
  }
  if refresh ~= "" then
    rows[#rows + 1] = credential_row({ name = "wr_rt", value = P.urlencode(refresh) })
  end
  for _, row in ipairs(rows) do
    cookies.upsert(jar, row)
  end
  http.set_cookies(jar)

  local function api_headers()
    return { ["X-Vid"] = vid, ["X-Skey"] = skey }
  end

  -- 1) account name
  http.request({
    url = M.USER_INFO_URL .. "?userVid=" .. P.urlencode(vid),
    referer = M.SKILLS_URL,
    headers = api_headers(),
    persist = true,
  }, function(user_res)
    if not is_current(session) then
      return
    end
    local user = http.decode_json(user_res) or {}
    local name = type(user.name) == "string" and user.name or ""

    -- 2) official API key; retried because the service sometimes lags behind
    -- the freshly issued login.
    -- (官方 API Key；刚登录后服务端偶有延迟，故重试)
    local attempt = 0
    local function fetch_key()
      attempt = attempt + 1
      http.request({
        url = M.API_KEY_URL,
        referer = M.SKILLS_URL,
        headers = api_headers(),
        persist = true,
      }, function(key_res)
        if not is_current(session) then
          return
        end
        local payload = http.decode_json(key_res) or {}
        local api_key = type(payload.apikey) == "string" and payload.apikey or ""
        if api_key == "" and attempt < 3 then
          vim.defer_fn(fetch_key, 500)
          return
        end
        if api_key == "" then
          finish(
            session,
            "官方 API Key 获取失败。请先在「微信读书 App → 我 → 设置 → 微信读书 Skill」中开通并获取 API Key，再重新扫码。",
            true
          )
          return
        end

        local credentials = {
          version = 1,
          login_method = "qr",
          login_time = os.time(),
          account = { name = name, user_vid = vid },
          api_key = api_key,
          cookies = {
            wr_vid = vid,
            wr_skey = skey,
            wr_ql = "0",
            wr_rt = refresh ~= "" and P.urlencode(refresh) or "",
          },
        }
        local ok, err = pcall(M.save_credentials, credentials)
        if not ok then
          finish(session, "凭据保存失败：" .. tostring(err), true)
          return
        end

        state.session = nil
        close_dialog(session)
        notify(string.format("登录成功，账号：%s", name ~= "" and name or "未知账号"))
      end)
    end
    fetch_key()
  end)
end

---Start the QR login flow. Safe to call again: any previous attempt is cancelled.
---(开始扫码登录；可重复调用，会取消上一次尝试)
---@param opts table|nil
function M.login(opts)
  opts = opts or {}
  M.cancel()

  local session = new_session()
  log.info("login started")

  session.dialog = nil
  local busy = vim.notify("正在获取登录二维码…")

  http.request({
    url = M.SKILLS_URL,
    accept = "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
    persist = true,
  }, function(page)
    if not is_current(session) then
      return
    end
    if page.code ~= 200 then
      finish(session, string.format("无法打开微信读书登录页（HTTP %s）", tostring(page.status)), true)
      return
    end

    http.request({
      url = M.LOGIN_UID_URL,
      referer = M.SKILLS_URL,
      persist = true,
    }, function(res)
      if not is_current(session) then
        return
      end
      local data, err = http.decode_json(res)
      if not data or type(data.uid) ~= "string" or data.uid == "" then
        finish(session, "微信读书未返回登录 UID" .. (err and ("（" .. err .. "）") or ""), true)
        return
      end
      session.uid = data.uid

      local payload = BASE .. "/web/confirm?uid=" .. P.urlencode(data.uid)
      -- Rendering the QR touches the terminal, snacks.image, qrencode and a
      -- float window; any of them can throw. Catch it here so a display
      -- problem becomes a readable message instead of a raw Lua error in a
      -- callback, which is how a dead image branch reached a user once.
      -- (二维码渲染要过终端、snacks.image、qrencode 与浮窗，任一环节都可能抛异；
      --  在这里接住，让显示问题变成可读提示，而不是回调里的裸 Lua 报错)
      local shown, dialog, dialog_err = pcall(qr.show, payload, {
        title = "微信读书 · 请用微信扫码" .. (M.is_logged_in() and "（将切换账号）" or ""),
        on_close = function()
          if is_current(session) and state.session == session then
            M.cancel()
            notify("已取消登录", vim.log.levels.WARN)
          end
        end,
      })
      if not shown then
        finish(session, "二维码显示失败：" .. tostring(dialog), true)
        return
      end
      if not dialog then
        finish(session, "二维码显示失败：" .. tostring(dialog_err), true)
        return
      end
      if busy then
        pcall(vim.notify, "正在获取登录二维码…", vim.log.levels.INFO, { id = "weread-login", replace = true })
      end
      session.dialog = dialog
      schedule_poll(session)
    end)
  end)

  return session
end

---Cancel an in-flight login attempt.
---(取消进行中的登录)
function M.cancel()
  state.generation = state.generation + 1
  local session = state.session
  state.session = nil
  if session then
    close_dialog(session)
  end
end

---Forget the stored account entirely.
---(完全清除本地账号数据)
function M.logout()
  M.cancel()
  http.clear_cookies()
  local path = M.credentials_path()
  if vim.fn.filereadable(path) == 1 then
    vim.uv.fs_unlink(path)
  end
  state.credentials = nil
  state.loaded = true
  notify_change()
  notify("已退出登录")
end

return M
