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
local cache = require("weread.cache")
local cookies = require("weread.cookies")
local config = require("weread.config")
local http = require("weread.http")
local log = require("weread.log")
local qr = require("weread.qr")

local M = {}

---Service root, read at call time.
---(服务根地址，调用时读取)
---
---It used to be a constant, which made every one of these URLs point at
---production even when the config (and therefore the test suite) said otherwise
---— the session renewal could not be tested at all, and a self-hosted or mocked
---origin was silently bypassed.
---(它原本是个常量，于是即使配置（以及测试）指向别处，这些 URL 依然打向正式环境——续期因此
--- 完全没法测试，被 mock 的来源也被静默绕过)
---@return string
local function base()
  return config.web_origin()
end

---@return string
function M.skills_url()
  return base() .. "/r/weread-skills"
end

---@return string
function M.login_uid_url()
  return base() .. "/api/auth/getLoginUid"
end

---@return string
function M.login_info_url()
  return base() .. "/api/auth/getLoginInfo"
end

---@return string
function M.user_info_url()
  return base() .. "/api/userInfo"
end

---@return string
function M.api_key_url()
  return base() .. "/api/skills/apikeyGet?only_show=1"
end

---@return string
function M.renewal_url()
  return base() .. "/web/login/renewal"
end

---Long poll budget in seconds. A curl timeout here is the normal idle state,
---not an error, which is why the poll runs without retries.
---(长轮询超时；curl 超时在这里代表“还没扫码”，是正常状态，因此轮询不做重试)
local POLL_TIMEOUT = 8
local POLL_INTERVAL_MS = 1500
local SESSION_TIMEOUT = 300
-- Consecutive failed polls that are not plain long-poll timeouts before the
-- dialog says the network looks broken.
-- (连续多少次非长轮询超时的失败后，对话框提示网络异常)
local NETWORK_FAILURES = 3
local CREDENTIAL_COOKIES = { "wr_vid", "wr_skey", "wr_ql", "wr_rt" }

local state = {
  generation = 0,
  session = nil,
  credentials = nil,
  loaded = false,
  -- Single-flight renewal: callbacks waiting on the renewal in progress, nil
  -- when none is running. (续期 single-flight：等待进行中那次续期的回调；没有续期时为 nil)
  renewing = nil,
  -- hrtime of the last successful renewal; http compares it with a request's
  -- send time. (上次成功续期的 hrtime；http 拿它与请求的发送时间比较)
  renewed_at = 0,
}

local function notify(message, level)
  vim.notify("weread: " .. message, level or vim.log.levels.INFO)
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
  local data, status, backup, backup_err = cache.load_json(M.credentials_path())
  if status == "corrupt" then
    -- cache.load_json already moved the file aside and logged it; tell the
    -- user once, because from here on they are logged out.
    -- (cache.load_json 已把文件改名保存并记了日志；这里提示用户一次，因为此后他们处于未登录状态)
    if backup then
      notify(
        string.format("登录文件损坏，已备份为 %s，请重新登录（:WeReadLogin）", vim.fs.basename(backup)),
        vim.log.levels.WARN
      )
    else
      notify(
        string.format("登录文件损坏且无法备份（%s），请重新登录（:WeReadLogin）", tostring(backup_err)),
        vim.log.levels.WARN
      )
    end
    return nil
  end
  if not data then
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

---Write the jar, whatever way the http layer reports a failure: a raised error,
---`nil, err` or `false, err`. A bare `nil` is success (older callers returned
---nothing).
---(写 jar，不管 http 层以哪种方式报告失败：抛异常、`nil, err` 或 `false, err`；单个 `nil`
--- 视为成功（旧调用方什么也不返回）)
---@param list table[]
---@return boolean ok
---@return string|nil err
local function store_cookies(list)
  local called, ok, err = pcall(http.set_cookies, list)
  if not called then
    return false, tostring(ok)
  end
  if ok == false or (ok == nil and err ~= nil) then
    return false, tostring(err or "could not write the cookie jar")
  end
  return true, nil
end

---Push the stored credentials into the curl cookie jar.
---(把存档中的凭据写回 curl cookie jar)
---@return boolean ok
---@return string|nil err
function M.apply_cookies()
  local credentials = M.load_credentials()
  if not credentials or type(credentials.cookies) ~= "table" then
    return false, nil
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
  return store_cookies(jar)
end

---Persist the credentials atomically (0600) and push them into the cookie jar.
---Raises on failure, which every caller already expects.
---(原子落盘凭据（0600）并写入 cookie jar；失败时抛异常，现有调用方都已按此处理)
---@param credentials table
function M.save_credentials(credentials)
  config.ensure_dirs()
  local encoded, payload = pcall(vim.json.encode, credentials)
  if not encoded then
    error("could not encode credentials: " .. tostring(payload))
  end
  local ok, err = cache.atomic_write(M.credentials_path(), payload, 384) -- 0600(凭据文件权限)
  if not ok then
    error("could not write credentials: " .. tostring(err))
  end
  state.credentials = credentials
  state.loaded = true
  local applied, apply_err = M.apply_cookies()
  if not applied and apply_err then
    error("credentials saved but the cookie jar could not be written: " .. apply_err)
  end
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
function M.check(data, opts)
  local message = M.describe_error(data)
  if message then
    -- Background calls (a progress pull) fail softly: the reader opened a book
    -- and does not need a warning for something they did not ask for.
    -- (后台调用（进度拉取）安静地失败：读者只是在打开书，不需要为自己没要求的事
    --  收到一条警告)
    if not (opts and opts.silent) then
      notify(message, vim.log.levels.WARN)
    end
    return false
  end
  return true
end

---hrtime of the last successful renewal, 0 before any. http.lua compares it
---with a request's send time to tell "already renewed since" from "needs a
---renewal".
---(上次成功续期的 hrtime，从未续期则为 0。http.lua 拿它与请求的发送时间比较，
--- 区分“此后已续期”与“需要续期”)
---@return integer
function M.last_renewed_at()
  return state.renewed_at
end

---Do the renewal request itself and persist the result.
---(执行续期请求本身并落盘结果)
---@param done fun(ok: boolean, err: string|nil)
local function request_renewal(done)
  http.request({
    url = M.renewal_url(),
    method = "POST",
    json = true,
    body = { rq = "%2Fweb%2Fbook%2Fread", ql = false },
    timeout = 15,
    persist = true,
  }, function(res)
    local data = http.decode_json(res)
    if not data then
      done(false, "续期请求失败")
      return
    end
    if not P.is_success_response(data) then
      done(false, M.describe_error(data) or "会话续期失败")
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
    state.renewed_at = vim.uv.hrtime()
    done(true, nil)
  end)
end

---POST /web/login/renewal, refreshing and persisting the session cookies.
---(续期：刷新并落盘会话 cookie)
---
---Single-flight: while a renewal is running, further callers only queue their
---callback and all of them are answered together when it finishes. Two
---renewals racing would each rotate the refresh token and one of them would be
---left holding a token the server already retired.
---(single-flight：续期进行期间，后来的调用只排队回调，结束时统一回复。两次续期并发会各自轮换
--- refresh token，其中一次拿着的就是服务端已经作废的 token)
---@param callback fun(ok: boolean, err: string|nil)
function M.renew(callback)
  callback = callback or function() end
  if state.renewing then
    table.insert(state.renewing, callback)
    return
  end
  local waiters = { callback }
  state.renewing = waiters

  local function finish_renewal(ok, err)
    state.renewing = nil
    for _, waiter in ipairs(waiters) do
      -- One waiter raising must not strand the rest.
      -- (某个等待者抛错不能让其余等待者落空)
      local called, call_err = pcall(waiter, ok, err)
      if not called then
        log.warn("renewal callback failed: %s", tostring(call_err))
      end
    end
  end

  -- http.request can raise before it ever calls back; without this the flag
  -- would stay set and every later renewal would queue forever.
  -- (http.request 可能在回调之前就抛错；没有这层保护，标志位会一直为真，之后所有续期都会永远排队)
  local started, start_err = pcall(request_renewal, finish_renewal)
  if not started then
    finish_renewal(false, tostring(start_err))
  end
end

---@return table|nil
local function new_session()
  state.generation = state.generation + 1
  local session = {
    generation = state.generation,
    started = os.time(),
    dialog = nil,
    uid = nil,
    payload = nil,
    timer = nil,
    ticker = nil,
    status = "等待扫码",
    expired = false,
    failures = 0,
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

local function stop_ticker(session)
  require("weread.timer").stop(session.ticker)
  session.ticker = nil
end

---@param session table
---@return integer seconds left before the QR code expires
local function remaining(session)
  return math.max(0, SESSION_TIMEOUT - (os.time() - session.started))
end

---Redraw the dialog footer: status, countdown and the keys, dropping the key
---hints when the window is too narrow for them.
---(重画对话框页脚：状态、倒计时与按键提示；窗口太窄时省掉按键提示)
---@param session table
local function update_footer(session)
  local dialog = session.dialog
  if not (dialog and dialog.float and dialog.float:is_open() and dialog.float.set_footer) then
    return
  end
  local parts
  if session.expired then
    parts = { "二维码已过期", "r 刷新  q 关闭" }
  else
    local left = remaining(session)
    parts = {
      string.format("%s %d:%02d", session.status, math.floor(left / 60), left % 60),
      "r 刷新  y 复制链接  q 取消",
    }
  end
  local footer = " " .. table.concat(parts, " · ") .. " "
  local width = dialog.float.width or vim.api.nvim_win_get_width(dialog.float:get_win())
  if vim.api.nvim_strwidth(footer) > width then
    footer = " " .. parts[1] .. " "
  end
  dialog.float:set_footer(footer)
end

---@param session table
---@param status string
local function set_status(session, status)
  if session.status ~= status then
    session.status = status
    update_footer(session)
  end
end

local function close_dialog(session)
  stop_timer(session)
  stop_ticker(session)
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
  -- Detach first: closing the window fires on_close, which would otherwise
  -- report a user cancel on top of this message.
  -- (先解除关联：关窗会触发 on_close，否则会在本条消息之外再报一次“已取消”)
  state.session = nil
  close_dialog(session)
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

---The QR code ran out. The dialog stays open on purpose so `r` can fetch a
---fresh one in place; closing it ends the attempt quietly.
---(二维码过期。对话框故意保持打开，让 `r` 原地换新码；关掉它则安静结束这次尝试)
---@param session table
local function expire(session)
  if not is_current(session) or session.expired then
    return
  end
  session.expired = true
  stop_timer(session)
  stop_ticker(session)
  log.info("login QR expired")
  if session.dialog and session.dialog.float and session.dialog.float:is_open() then
    set_title(session, "二维码已过期 · 按 r 刷新")
    update_footer(session)
    notify("二维码已过期，按 r 刷新或重新执行 :WeReadLogin", vim.log.levels.WARN)
  else
    finish(session, "二维码已过期，请重新执行 :WeReadLogin", true)
  end
end

---Once a second: redraw the countdown and expire the code on time, even while
---a long poll is still in flight.
---(每秒一次：刷新倒计时，并在到点时让二维码过期，即使长轮询仍在进行中)
---@param session table
local function start_ticker(session)
  stop_ticker(session)
  session.ticker = require("weread.timer").every(function()
    if not is_current(session) or session.expired then
      stop_ticker(session)
      return
    end
    if remaining(session) <= 0 then
      expire(session)
      return
    end
    update_footer(session)
  end, 1000)
end

---@param session table
local function schedule_poll(session)
  if not is_current(session) or session.expired then
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
  set_status(session, "已扫码，输入验证码")
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
    expire(session)
  else
    finish(session, "登录失败：" .. code, true)
  end
end

---Poll the login state once. Exposed for tests and for the timer callback.
---(轮询一次登录状态；供定时器与测试调用)
---@param session table
---@param otp string|nil
function M._poll(session, otp)
  if not is_current(session) or session.expired then
    return
  end
  if os.time() - session.started > SESSION_TIMEOUT then
    expire(session)
    return
  end

  local url = M.login_info_url() .. "?uid=" .. P.urlencode(session.uid) .. "&otp=" .. P.urlencode(otp or "")
  local settled = false
  local poll
  poll = http.request({
    url = url,
    referer = M.skills_url(),
    timeout = POLL_TIMEOUT,
    retries = 0,
    persist = true,
  }, function(res)
    settled = true
    if session.poll == poll then
      session.poll = nil
    end
    if not is_current(session) then
      return
    end
    local data = http.decode_json(res)
    if not data then
      -- Nothing happened yet: curl gives up on the long poll and we try again.
      -- (还没有人扫码：curl 结束长轮询后重新发起)
      log.debug("login poll pending (%s)", tostring(res.error or res.status))
      -- A curl timeout (28) is the idle state; anything else (DNS, refused,
      -- HTTP errors) counted in a row means the network is the problem.
      -- (curl 超时 (28) 是空闲常态；其他失败（DNS、连接被拒、HTTP 错误）连续出现，
      --  说明是网络的问题)
      local reason = tostring(res.error or "")
      local idle = res.code == 0 and (reason:find("(28)", 1, true) ~= nil or reason:find("code 28$") ~= nil)
      session.failures = idle and 0 or session.failures + 1
      if session.failures >= NETWORK_FAILURES then
        set_status(session, "网络异常，重试中")
      elseif idle and session.status == "网络异常，重试中" then
        set_status(session, "等待扫码")
      end
      schedule_poll(session)
      return
    end
    session.failures = 0
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
  -- Keep the handle so cancel can abort the long poll instead of leaving curl
  -- running for the rest of its timeout. A callback that already fired
  -- (synchronous stubs) has nothing left to abort.
  -- (保存句柄，让 cancel 能中止长轮询，而不是让 curl 把剩下的超时跑完；回调已触发
  --  （同步桩）则没有可中止的了)
  if not settled and type(poll) == "table" then
    session.poll = poll
  end
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

  stop_ticker(session)
  set_status(session, "已确认")
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
  -- Without the jar the follow-up requests are anonymous. Fail here, with the
  -- reason, rather than leave the dialog on "正在完成登录…" forever.
  -- (jar 没写进去，后续请求都是匿名的。在这里带着原因失败，而不是让对话框永远停在“正在完成登录…”)
  local stored, store_err = store_cookies(jar)
  if not stored then
    finish(session, "登录凭据写入失败：" .. tostring(store_err), true)
    return
  end

  local function api_headers()
    return { ["X-Vid"] = vid, ["X-Skey"] = skey }
  end

  -- 1) account name
  http.request({
    url = M.user_info_url() .. "?userVid=" .. P.urlencode(vid),
    referer = M.skills_url(),
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
        url = M.api_key_url(),
        referer = M.skills_url(),
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
          -- The jar already holds the new account; put the saved one back, or
          -- page requests and the shelf would go to different accounts.
          -- (jar 里已经是新账号了；换回已保存的那个，否则正文请求和书架会走两个不同的账号)
          pcall(M.apply_cookies)
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
          pcall(M.apply_cookies)
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
  notify("正在获取登录二维码…")

  http.request({
    url = M.skills_url(),
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
      url = M.login_uid_url(),
      referer = M.skills_url(),
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
      -- The budget starts when the code is on screen, not when the bootstrap
      -- requests went out.
      -- (有效期从二维码上屏开始算，而不是从引导请求发出时算)
      session.started = os.time()

      local payload = base() .. "/web/confirm?uid=" .. P.urlencode(data.uid)
      session.payload = payload
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
            local quiet = session.expired
            M.cancel()
            if not quiet then
              notify("已取消登录", vim.log.levels.WARN)
            end
          end
        end,
        actions = {
          -- r: a new code in place of this one (换一张新二维码)
          r = function()
            M.login(opts)
          end,
          -- y: the confirm link, for opening it inside WeChat on the phone
          -- (复制确认链接，可发到手机在微信里打开)
          y = function()
            vim.fn.setreg('"', payload)
            pcall(vim.fn.setreg, "+", payload)
            notify("已复制登录链接，可发到手机在微信内打开")
          end,
        },
      })
      if not shown then
        finish(session, "二维码显示失败：" .. tostring(dialog), true)
        return
      end
      if not dialog then
        finish(session, "二维码显示失败：" .. tostring(dialog_err), true)
        return
      end
      session.dialog = dialog
      update_footer(session)
      start_ticker(session)
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
    local poll = session.poll
    session.poll = nil
    if poll and type(poll.kill) == "function" then
      pcall(poll.kill)
    end
    close_dialog(session)
  end
end

---Forget the stored account entirely.
---(完全清除本地账号数据)
function M.logout()
  M.cancel()
  local cleared, clear_err = store_cookies({})
  if not cleared then
    log.warn("logout: could not empty the cookie jar: %s", tostring(clear_err))
  end
  local path = M.credentials_path()
  if vim.fn.filereadable(path) == 1 then
    vim.uv.fs_unlink(path)
  end
  state.credentials = nil
  state.loaded = true
  notify("已退出登录")
end

return M
