--[[
Account layer: QR login, credential storage, cookie renewal.
(账号层：扫码登录、凭据存储、cookie 续期)

Protocol notes, all of them verified against the live service:
(协议要点，均已对线上服务实测)

* `GET /r/weread-skills` bootstraps an anonymous session.
* `GET /api/auth/getLoginUid` returns `{uid}`; the QR payload is
  `https://weread.qq.com/web/confirm?uid=<uid>`.
* `GET /api/auth/getLoginInfo?uid=&otp=` long-polls (the web client holds it
  for 60s). It answers with `{succeed:true, webLoginVid, accessToken,
  refreshToken}` once the phone confirms, `{logicCode:"NEED_OTP"}` when the
  phone shows a four digit code, `OTP_NOT_MATCH` / `OTP_EXPIRED` /
  `LOGIN_TIMEOUT` for the other outcomes, and simply times out while nothing
  has happened yet. `succeed` has also been seen as a number, and a complete
  credential pair is treated as success even if the flag is missing.
* The login handshake runs in a private cookie jar; the account that is still
  logged in must not take part in confirming the new one.
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

---Path of the cookie jar used only by the QR login handshake. Keeping it
---separate from the shared jar means an account switch cannot be disturbed by
---the cookies of the account that is still logged in.
---(扫码登录握手专用的 cookie jar。它与共享 jar 分开，切换账号时不会被仍在登录的
--- 旧账号 cookie 干扰)
---@return string
function M.login_jar_path()
  return config.path("tmp/login-cookies.txt")
end

---Long poll budget in seconds. The web client holds this request for 60s, and a
---shorter abort can throw away a success or an OTP verification that arrived
---just as curl gave up. A timeout is still the normal idle state, so the poll
---runs without retries and simply starts another one.
---(长轮询超时。网页端会把这个请求挂 60 秒；中止得太早会在 curl 放弃的瞬间丢掉已经
--- 到达的成功或验证码校验结果。超时依然代表“还没扫码”，所以轮询不重试，直接再发一次)
local POLL_TIMEOUT = 60
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
---@param path string|nil defaults to the shared jar(默认共享 jar)
---@return boolean ok
---@return string|nil err
local function store_cookies(list, path)
  local called, ok, err = pcall(http.set_cookies, list, path)
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
    -- Monotonic deadline: a wall clock step (NTP, timezone change) must not make
    -- a fresh QR look expired. (单调时钟截止时间：系统时钟跳变不能把新二维码判成过期)
    deadline = nil,
    dialog = nil,
    uid = nil,
    payload = nil,
    timer = nil,
    ticker = nil,
    status = "等待扫码",
    expired = false,
    finished = false,
    failures = 0,
    -- The code the reader already typed, kept across long-poll retries. Dropping
    -- it made a delayed verification look like the phone had never answered.
    -- (读者已经输入的验证码；跨长轮询重试保留。丢掉它会让延迟的校验看起来像手机没应答)
    otp = nil,
    login_jar = nil,
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
  if not session.deadline then
    return SESSION_TIMEOUT
  end
  local left = math.floor((session.deadline - vim.uv.hrtime()) / 1e9)
  return math.max(0, left)
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
    -- The QR may be an image placement rather than the buffer text; closing the
    -- window alone can leave those pixels on screen until something redraws.
    -- (二维码可能是图片 placement 而不是 buffer 文本；只关窗口会让那些像素留在屏幕上，
    --  直到下一次重绘)
    if session.dialog.cleanup then
      pcall(session.dialog.cleanup)
    end
    if session.dialog.float and session.dialog.float:is_open() then
      session.dialog.float:close()
    end
    session.dialog = nil
  end
end

---Remove the private login jar once the attempt is over.
---(尝试结束后删掉私有登录 jar)
---@param session table
local function cleanup_login_jar(session)
  local path = session.login_jar
  session.login_jar = nil
  if path then
    pcall(vim.uv.fs_unlink, path)
  end
end

---@param session table
---@param message string
---@param is_error boolean|nil
---@param level integer|nil notification level for a successful finish(successful 时的通知级别)
local function finish(session, message, is_error, level)
  if session.generation ~= state.generation or session.finished then
    return
  end
  -- Detach first: closing the window fires on_close, which would otherwise
  -- report a user cancel on top of this message.
  -- (先解除关联：关窗会触发 on_close，否则会在本条消息之外再报一次“已取消”)
  session.finished = true
  state.session = nil
  close_dialog(session)
  cleanup_login_jar(session)
  if is_error then
    log.warn("login failed: %s", message)
    notify(message, level or vim.log.levels.ERROR)
  else
    log.info("login finished: %s", message)
    notify(message, level)
  end
end

local function is_current(session)
  return session.generation == state.generation and not session.finished
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
  session.otp = nil
  stop_timer(session)
  stop_ticker(session)
  -- A long poll still in flight must not report a result into a session that is
  -- already over, and its curl should not keep the request open for a minute.
  -- (已经过期的会话上还在跑的长轮询不能再把结果报进来，它的 curl 也不该继续挂一分钟)
  local poll = session.poll
  session.poll = nil
  if poll and type(poll.kill) == "function" then
    pcall(poll.kill)
  end
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
  session.otp = nil
  set_status(session, "已扫码，输入验证码")
  set_title(session, "请输入手机上的 4 位验证码")
  -- The app shows “scan succeeded” before we have a session; without this
  -- notice the reader can keep watching the QR code and never notice the prompt.
  -- (App 在我们拿到会话之前只显示“扫码成功”；不提示的话读者会一直盯着二维码，
  --  根本不知道要输入验证码)
  notify(
    message or "已扫码，请在手机上查看 4 位验证码并输入到 Neovim",
    vim.log.levels.WARN
  )
  local called, err = pcall(vim.ui.input, { prompt = "微信读书 4 位验证码: " }, function(input)
    if not is_current(session) or session.expired then
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
    session.otp = otp
    set_status(session, "正在验证验证码")
    set_title(session, "正在验证验证码…")
    M._poll(session)
  end)
  if not called then
    -- A broken UI must not leave the login stopped with a QR on screen.
    -- (UI 出错不能让登录停在“只剩二维码”的状态)
    finish(session, "无法打开验证码输入框：" .. tostring(err), true)
  end
end

---@param session table
---@param code string
local function handle_logic_code(session, code)
  if code == "NEED_OTP" then
    ask_otp(session)
  elseif code == "OTP_NOT_MATCH" then
    ask_otp(session, "验证码不正确，请重试")
  elseif code == "OTP_EXPIRED" then
    session.otp = nil
    finish(session, "验证码已过期，请重新执行 :WeReadLogin", true)
  elseif code == "LOGIN_TIMEOUT" then
    session.otp = nil
    expire(session)
  else
    session.otp = nil
    finish(session, "登录失败：" .. code, true)
  end
end

---Does this payload carry the credentials of a confirmed login?
---(这个响应是否带着已确认登录的凭据？)
---The service has returned `succeed` as a boolean and (on some backends) as a
---number; checking only `== true` silently ignores both the number and an
---otherwise complete payload. The web client only tests truthiness.
---(服务返回的 `succeed` 见过布尔值，也见过数字；只判断 `== true` 会静默忽略数字，
--- 以及一个字段已经齐全的响应。网页端只判断真值)
---@param data table
---@return boolean
local function login_succeeded(data)
  if type(data) ~= "table" then
    return false
  end
  local flag = data.succeed
  if flag == true or flag == 1 or flag == "1" or flag == "true" then
    return true
  end
  return type(data.webLoginVid) == "string"
    and data.webLoginVid ~= ""
    and type(data.accessToken) == "string"
    and data.accessToken ~= ""
end

---Poll the login state once. Exposed for tests and for the timer callback.
---(轮询一次登录状态；供定时器与测试调用)
---@param session table
---@param otp string|nil
function M._poll(session, otp)
  if not is_current(session) or session.expired or not session.uid then
    return
  end
  if otp ~= nil then
    session.otp = otp
  end
  if session.deadline and vim.uv.hrtime() >= session.deadline then
    expire(session)
    return
  end

  local url = M.login_info_url()
    .. "?uid="
    .. P.urlencode(session.uid)
    .. "&otp="
    .. P.urlencode(session.otp or "")
  local settled = false
  local poll
  poll = http.request({
    url = url,
    referer = M.skills_url(),
    timeout = POLL_TIMEOUT,
    retries = 0,
    persist = true,
    cookie_jar = session.login_jar,
  }, function(res)
    settled = true
    if session.poll == poll then
      session.poll = nil
    end
    if not is_current(session) or session.expired then
      return
    end
    local data = http.decode_json(res)
    if not data then
      -- A bare 401 has no JSON to inspect, but it still means the uid is gone.
      -- (裸 401 没有 JSON 可检查，但它同样说明 uid 已失效)
      if res.status == 401 then
        log.warn("login poll unauthorized (HTTP 401)")
        expire(session)
        return
      end
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
    if login_succeeded(data) then
      M._complete(session, data)
      return
    end
    -- Error payloads used to be ignored here: `-2013 鉴权失败` has no
    -- logicCode, so the poll kept spinning behind a QR that the service had
    -- already retired. Treat an invalidated login session as expired.
    -- (错误响应过去在这里被忽略：`-2013 鉴权失败` 没有 logicCode，轮询于是在一个
    --  服务端已经作废的二维码后面空转。把失效的登录会话当作过期处理)
    local detail = type(data.data) == "table" and data.data or data
    local errcode = tonumber(detail.errcode or detail.errCode)
    local errmsg = detail.errmsg or detail.errMsg or data.message
    local status_code = tonumber(res.status) or tonumber(data.statusCode)
    if errcode == -2012 or errcode == -2013 or status_code == 401 then
      log.warn("login poll rejected: %s", tostring(errmsg or errcode or status_code))
      expire(session)
      return
    end
    if errcode or (status_code and status_code >= 400) then
      log.warn("login poll failed: %s", tostring(errmsg or errcode or status_code))
      session.failures = session.failures + 1
      set_status(session, "登录服务异常，重试中")
      schedule_poll(session)
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

  -- Build the new jar from the login handshake, not from the account that may
  -- still be logged in: cookies from the old account must not leak into the new
  -- session. (用登录握手自己的 jar 构建新会话，而不是可能仍登录着的旧账号：旧账号的
  --  cookie 不能漏进新会话)
  local jar = http.load_cookies(session.login_jar)
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
  -- reason, rather than leave the dialog on "正在完成登录…" forever. The shared
  -- jar is replaced, not merged: cookies of the previous account must not
  -- survive an account switch.
  -- (jar 没写进去，后续请求都是匿名的。在这里带着原因失败，而不是让对话框永远停在
  --  “正在完成登录…”；共享 jar 整体替换而不是合并，旧账号的 cookie 不能在切换后残留)
  local private_stored, private_err = store_cookies(jar, session.login_jar)
  if not private_stored then
    finish(session, "登录凭据写入失败：" .. tostring(private_err), true)
    return
  end
  local stored, store_err = store_cookies(jar)
  if not stored then
    finish(session, "登录凭据写入失败：" .. tostring(store_err), true)
    return
  end

  local function api_headers()
    return { ["X-Vid"] = vid, ["X-Skey"] = skey }
  end

  ---Save the confirmed account and close the dialog. A missing API key is not a
  ---failed login: the cookie-authenticated reader works, and the shelf can be
  ---enabled later by opening the Skill in the app.
  ---(保存已确认账号并关闭对话框。缺少 API Key 不等于登录失败：cookie 鉴权的阅读器
  --- 仍可用，之后在 App 开通 Skill 即可恢复书架)
  ---@param name string
  ---@param api_key string
  local function save_and_finish(name, api_key)
    local credentials = {
      version = 1,
      login_method = "qr",
      login_time = os.time(),
      account = { name = name, user_vid = vid },
      api_key = api_key ~= "" and api_key or nil,
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
    local display = name ~= "" and name or "未知账号"
    if api_key ~= "" then
      finish(session, string.format("登录成功，账号：%s", display))
    else
      finish(
        session,
        string.format(
          "登录成功，账号：%s（未获取到官方 API Key，书架/搜索不可用；请在「微信读书 App → 我 → 设置 → 微信读书 Skill」中开通后重新执行 :WeReadLogin）",
          display
        ),
        false,
        vim.log.levels.WARN
      )
    end
  end

  -- 1) account name
  http.request({
    url = M.user_info_url() .. "?userVid=" .. P.urlencode(vid),
    referer = M.skills_url(),
    headers = api_headers(),
    persist = true,
    cookie_jar = session.login_jar,
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
    local previous = M.load_credentials()
    local function fetch_key()
      attempt = attempt + 1
      http.request({
        url = M.api_key_url(),
        referer = M.skills_url(),
        headers = api_headers(),
        persist = true,
        cookie_jar = session.login_jar,
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
          -- The same account may already have a key on disk; a transient
          -- failure of this endpoint must not throw it away. A different
          -- account must not inherit it.
          -- (同一个账号可能已有落盘的 key；这个接口临时失败不能把它丢掉。换账号则不能继承)
          if
            previous
            and previous.account
            and previous.account.user_vid == vid
            and type(previous.api_key) == "string"
            and previous.api_key ~= ""
          then
            api_key = previous.api_key
          end
        end
        save_and_finish(name, api_key)
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
  -- `:WeReadLogin!` starts from a clean slate: stale cookies are a documented
  -- cause of "登录超时", so the bang must actually clear them.
  -- (`:WeReadLogin!` 从干净状态开始：残留 cookie 是官方文档记录的「登录超时」成因，
  --  因此 bang 必须真的把它们清掉)
  if opts.force and M.is_logged_in() then
    -- The command layer may already have logged out when it saw the bang; only
    -- clear again if credentials are actually still there.
    -- (命令层看到 bang 时可能已经退出登录；只有凭据确实还在时才再清一次)
    M.logout()
  else
    M.cancel()
  end

  local session = new_session()
  log.info("login started")

  -- A private jar for the handshake: the old account's cookies must not take
  -- part in confirming the new one. (握手用私有 jar：旧账号的 cookie 不能参与新账号的确认)
  config.ensure_dirs()
  local login_jar = M.login_jar_path()
  session.login_jar = login_jar
  local cleared, clear_err = store_cookies({}, login_jar)
  if not cleared then
    finish(session, "无法创建登录会话：" .. tostring(clear_err), true)
    return session
  end

  session.dialog = nil
  notify("正在获取登录二维码…")

  http.request({
    url = M.skills_url(),
    accept = "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
    persist = true,
    cookie_jar = login_jar,
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
      cookie_jar = login_jar,
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
      session.deadline = vim.uv.hrtime() + SESSION_TIMEOUT * 1e9

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
    cleanup_login_jar(session)
  end
end

---Forget the stored account entirely.
---(完全清除本地账号数据)
function M.logout()
  M.cancel()
  pcall(vim.uv.fs_unlink, M.login_jar_path())
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
