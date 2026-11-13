--[[
HTTP layer. Uses curl through `vim.system` instead of a hand written HTTP
client so that TLS, gzip, redirects and Set-Cookie handling stay as boring as
possible.
(HTTP 层：通过 vim.system 调用 curl，而不是自写 HTTP 客户端，让 TLS、gzip、
 重定向、Set-Cookie 这些细节都保持“无聊可靠”)

Two rules worth remembering:
(两条关键约束)

1. Response bodies are always read from a file with binary IO. `vim.system`
   normalizes `\r\n` to `\n` when `text = true`, which would corrupt binary
   payloads such as the chapter resource tarballs, and computing a shard MD5
   over a normalized body would be wrong.
   (响应体一律走文件 + 二进制读取：vim.system 在 text=true 时会规范化换行，
    会破坏 tar 这类二进制内容，也会让分片 MD5 校验失配)
2. Only requests that must persist cookies pass `persist = true`. Concurrent
   readers share the jar read-only so they cannot clobber each other's writes.
   (只有必须持久化 cookie 的请求才传 persist = true；并发读取共享 cookie jar
    只读，避免互相覆盖)
3. Secrets never go on the command line, where any local user can read them
   through `ps`. Credential headers are written to a 0600 file that curl reads
   with `--header @file`, and the file is removed when the request ends.
   (密钥不上命令行，否则本机任何用户都能经 `ps` 看到。凭据头写进 0600 临时文件，
    由 curl 用 `--header @file` 读取，请求结束即删除)
]]

local cache = require("weread.cache")
local cookies = require("weread.cookies")
local plugin_config = require("weread.config")

local M = {}

-- Download size cap and the age after which orphaned temp files are swept.
-- (下载体积上限，以及孤儿临时文件被清扫的年龄)
local DEFAULT_MAX_FILESIZE = 200 * 1024 * 1024
local TMP_MAX_AGE = 3600
local TMP_PREFIX = "wr-"

local config = {
  ua = table.concat({
    "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7)",
    "AppleWebKit/537.36 (KHTML, like Gecko)",
    "Chrome/135.0.0.0 Safari/537.36 Edg/135.0.0.0",
  }, " "),
  timeout = 20,
  retries = 2,
  jar = nil,
  tmpdir = nil,
  ---nil inherits the environment proxy, "direct" bypasses it, otherwise a proxy url.
  ---(nil 表示沿用环境变量里的代理，"direct" 强制直连，其余值当作代理地址)
  proxy = nil,
}

---Debug line for this layer. `weread.log` is loaded lazily: the http client is
---used by the login flow itself, which runs before logging is set up.
---(本层的调试输出。weread.log 延迟加载：登录流程本身就用 http，那时日志还没初始化)
---@param message string
local function log_line(message)
  local ok, log = pcall(require, "weread.log")
  if ok and log and log.debug then
    pcall(log.debug, "%s", message)
  end
end

---Warning line for this layer, loaded lazily for the same reason as log_line.
---(本层的警告输出，延迟加载，理由同 log_line)
---@param message string
local function warn_line(message)
  local ok, log = pcall(require, "weread.log")
  if ok and log and log.warn then
    pcall(log.warn, "%s", message)
  end
end

local counter = 0
local active = {}

---Remove our own stale temp files: bodies and header files left behind when a
---process was killed mid-request. Only regular files carrying our prefix are
---touched, because the temp directory may be shared with other things (it falls
---back to the jar's directory, which also holds credentials.json).
---(清掉自己留下的过期临时文件：进程在请求中途被杀时遗留的响应体与头文件。只动带我们前缀的
--- 普通文件，因为 tmp 目录可能与别的东西共用（它会回退到 jar 所在目录，那里还有 credentials.json）)
---@param dir string
---@param max_age integer seconds(秒)
---@return integer removed
local function sweep_tmp(dir, max_age)
  local removed = 0
  local now = os.time()
  for name, kind in vim.fs.dir(dir) do
    if kind == "file" and name:sub(1, #TMP_PREFIX) == TMP_PREFIX then
      local path = dir .. "/" .. name
      local stat = vim.uv.fs_lstat(path)
      if stat and stat.type == "file" and now - stat.mtime.sec > max_age then
        if vim.uv.fs_unlink(path) then
          removed = removed + 1
        end
      end
    end
  end
  return removed
end

---@param max_age integer|nil defaults to one hour(默认一小时)
---@return integer removed
function M.sweep_tmp(max_age)
  if not config.tmpdir then
    return 0
  end
  return sweep_tmp(config.tmpdir, max_age or TMP_MAX_AGE)
end

---@param opts table|nil
function M.setup(opts)
  for key, value in pairs(opts or {}) do
    config[key] = value
  end
  config.tmpdir = config.tmpdir or (config.jar and vim.fs.dirname(config.jar)) or vim.fn.stdpath("run")
  vim.fn.mkdir(config.tmpdir, "p")
  M.ensure_jar()
  pcall(M.sweep_tmp)

  -- A request still running at exit must not outlive the editor. Its own
  -- autocmd group, cleared on every setup, so re-running setup never stacks
  -- handlers.
  -- (退出时仍在跑的请求不该比编辑器活得更久。独立 augroup，每次 setup 都清掉重建，
  --  重复 setup 不会叠加处理器)
  local group = vim.api.nvim_create_augroup("WereadHttp", { clear = true })
  vim.api.nvim_create_autocmd("VimLeavePre", {
    group = group,
    callback = function()
      M.kill_all()
    end,
  })
end

---@return string
function M.jar_path()
  if not config.jar then
    error("weread.http.setup() must be called before any request")
  end
  return config.jar
end

---@return string
function M.user_agent()
  return config.ua
end

---Create an empty jar on first use so curl never complains about a missing
---file. `path` lets the login handshake create its private jar too. A failure
---is logged and returned, not raised: this runs on every request, and curl
---copes with a missing jar anyway.
---(首次使用时创建空 jar，避免 curl 报文件不存在。`path` 让登录握手也能创建自己的
--- 私有 jar。失败时记日志并返回，不抛异常：每次请求都会走到这里，而 curl 本身能容忍
--- jar 不存在)
---@param path string|nil defaults to the shared jar(默认共享 jar)
---@return boolean|nil ok
---@return string|nil err
function M.ensure_jar(path)
  path = path or M.jar_path()
  if vim.uv.fs_stat(path) then
    return true, nil
  end
  pcall(vim.fn.mkdir, vim.fs.dirname(path), "p")
  local ok, err = cookies.save(path, {})
  if not ok then
    warn_line("could not create the cookie jar: " .. tostring(err))
  end
  return ok, err
end

---@param path string|nil defaults to the shared jar(默认共享 jar)
---@return table[]
function M.load_cookies(path)
  path = path or M.jar_path()
  M.ensure_jar(path)
  return cookies.load(path)
end

---Replace the whole jar. Used by the login flow, which swaps accounts and must
---not inherit cookies from the previous one. Returns the write outcome so the
---caller can fail the login instead of carrying on with a stale jar.
---(整体替换 jar；登录流程会切换账号，不能继承上一个账号的 cookie。返回写入结果，
--- 调用方才能让登录失败，而不是带着过期的 jar 继续)
---@param list table[]
---@param path string|nil defaults to the shared jar(默认共享 jar)
---@return boolean|nil ok
---@return string|nil err
function M.set_cookies(list, path)
  return cookies.save(path or M.jar_path(), list)
end

---@param path string|nil defaults to the shared jar(默认共享 jar)
---@return boolean|nil ok
---@return string|nil err
function M.clear_cookies(path)
  return M.set_cookies({}, path)
end

---@return string
function M.cookie_header()
  return cookies.header(M.load_cookies())
end

local merge_jar

---Key of a cookie in a jar: the same cookie is the same name, domain and path.
---(cookie 在 jar 里的键：名字、域、路径都相同才是同一个 cookie)
---@param cookie table
---@return string
local function cookie_key(cookie)
  return table.concat({ cookie.name or "", cookie.domain or "", cookie.path or "/" }, "\t")
end

---Merge what one request's response changed into the shared jar: the cookies
---it set or replaced, and the ones it expired. Everything else in the shared
---jar is newer than this request's view of it and stays.
---(把一次请求的响应改动的部分合并进共享 jar：它设置或替换的 cookie，以及它让过期的 cookie。
--- 共享 jar 里其余的内容都比这个请求看到的更新，原样保留)
---@param before table[] the jar when the request started(请求开始时的 jar)
---@param out_path string the jar curl wrote for this request(curl 为这次请求写出的 jar)
---@param target string|nil jar to merge into, defaults to the shared jar(合并目标 jar，默认共享 jar)
merge_jar = function(before, out_path, target)
  target = target or M.jar_path()
  local file = io.open(out_path, "rb")
  if not file then
    return
  end
  local after = cookies.parse(file:read("*a") or "")
  file:close()
  os.remove(out_path)
  local old, new = {}, {}
  for _, cookie in ipairs(before or {}) do
    old[cookie_key(cookie)] = cookie.value
  end
  for _, cookie in ipairs(after) do
    new[cookie_key(cookie)] = cookie
  end
  local changed = false
  local jar = cookies.load(target)
  for key, cookie in pairs(new) do
    if old[key] ~= cookie.value then
      cookies.upsert(jar, cookie)
      changed = true
    end
  end
  for key in pairs(old) do
    if not new[key] then
      local kept = {}
      for _, cookie in ipairs(jar) do
        if cookie_key(cookie) ~= key then
          kept[#kept + 1] = cookie
        end
      end
      changed = changed or #kept ~= #jar
      jar = kept
    end
  end
  if changed then
    local ok, err = cookies.save(target, jar)
    if not ok then
      warn_line("could not merge cookies into the jar: " .. tostring(err))
    end
  end
end

local function next_tmp(tag)
  counter = counter + 1
  return string.format("%s/wr-%d-%d-%s", config.tmpdir, vim.uv.os_getpid(), counter, tag or "body")
end

local function read_file(path)
  local file = io.open(path, "rb")
  if not file then
    return nil
  end
  local data = file:read("*a")
  file:close()
  return data
end

---@param res table
---@param opts table
local function should_retry(res, opts)
  if res.fatal or res.cancelled then
    return false -- retrying cannot help: curl never started, or the caller gave up(重试无济于事：curl 没跑起来，或调用方已放弃)
  end
  if opts.write then
    -- A write the service may already have applied must not be sent again: only
    -- a request that never reached it (no DNS, no connection) is retried.
    -- (服务端可能已经执行过的写请求不能再发一遍：只重试根本没到达服务端的请求（DNS 失败、连不上）)
    return res.code == 0 and (res.exit == 6 or res.exit == 7)
  end
  if res.code == 0 then
    return true -- transport failure(传输层失败)
  end
  if res.code >= 500 then
    return true
  end
  if res.code == 429 then
    return true
  end
  if opts.retry_on then
    return opts.retry_on(res) and true or false
  end
  return false
end

-- Header names whose values are credentials. They go to a 0600 file, never argv.
-- (值属于凭据的头名称；它们进 0600 文件，绝不进 argv)
local SECRET_HEADERS = {
  ["authorization"] = true,
  ["proxy-authorization"] = true,
  ["cookie"] = true,
  ["x-skey"] = true,
  ["x-vid"] = true,
  ["x-api-key"] = true,
}

---@param name string
---@return boolean
local function is_secret_header(name)
  return SECRET_HEADERS[name:lower()] == true
end

---Build the argv for one curl invocation.
---(构造一次 curl 调用的参数)
---
---Returns the argv and the credential header lines that must be handed to curl
---through a file; the caller owns writing and deleting that file.
---(返回 argv，以及必须经文件交给 curl 的凭据头行；文件的写入与删除由调用方负责)
---@param opts table
---@param body_path string
---@return string[] argv
---@return string[] secrets "Name: value" lines
local function build_argv(opts, body_path)
  if type(opts.url) ~= "string" or opts.url == "" then
    error("weread.http: request without a url")
  end

  local secrets = {}
  local argv = {
    "curl",
    "--silent",
    "--show-error",
    "--location",
    -- Follow redirects to web pages only, never to file://, ftp:// and friends.
    -- (只跟随到网页协议的重定向，绝不跟到 file://、ftp:// 之类)
    "--proto",
    "=http,https",
    "--proto-redir",
    "=http,https",
    "--compressed",
    "--max-time",
    tostring(math.max(1, math.floor(opts.timeout or config.timeout))),
    "--dump-header",
    body_path .. ".headers",
    "--output",
    body_path,
    "--write-out",
    "%{http_code}",
    "--user-agent",
    config.ua,
    "--header",
    "Accept: " .. (opts.accept or "application/json, text/plain, */*"),
  }

  -- Origin and Referer follow the configured service root, read per call so a
  -- re-run setup (or a test pointing at a mock) takes effect.
  -- (Origin 与 Referer 跟随配置的服务根地址，每次调用时读取，重新 setup 或测试指向 mock 都会生效)
  if opts.referer ~= false then
    argv[#argv + 1] = "--referer"
    argv[#argv + 1] = opts.referer or (plugin_config.web_origin() .. "/")
  end

  local proxy = opts.proxy
  if proxy == nil then
    proxy = config.proxy
  end
  if proxy == "direct" then
    argv[#argv + 1] = "--noproxy"
    argv[#argv + 1] = "*"
  elseif type(proxy) == "string" and proxy ~= "" and proxy ~= "env" then
    argv[#argv + 1] = "--proxy"
    argv[#argv + 1] = proxy
  end
  if opts.origin ~= false then
    argv[#argv + 1] = "--header"
    argv[#argv + 1] = "Origin: " .. (opts.origin or plugin_config.web_origin())
  end
  if opts.no_cookies then
    argv[#argv + 1] = "--header"
    argv[#argv + 1] = "Cookie: "
  else
    local jar = opts.cookie_jar or M.jar_path()
    M.ensure_jar(jar)
    argv[#argv + 1] = "--cookie"
    argv[#argv + 1] = jar
    if opts.persist then
      -- curl rewrites the whole jar it read at start, so two requests writing
      -- the same jar lose each other's cookies (a renewal undone by a page
      -- fetch that started before it). Each one writes a private jar, and only
      -- what its response changed is merged back.
      -- (curl 会把启动时读到的整份 jar 重写回去，两个请求同写同一个 jar 会互相丢掉对方的 cookie
      --  （比如一次续期被它之前发出的页面请求覆盖）。每个请求写自己的 jar，只把它的响应改动的部分合并回去)
      opts._jar_before = cookies.load(jar)
      opts._jar_out = next_tmp("jar")
      opts._jar_target = jar
      argv[#argv + 1] = "--cookie-jar"
      argv[#argv + 1] = opts._jar_out
    end
  end
  for name, value in pairs(opts.headers or {}) do
    local line = name .. ": " .. value
    if is_secret_header(name) then
      -- A CR/LF in a value would smuggle in an extra header line.
      -- (值里的 CR/LF 会夹带出额外的头行)
      if line:find("[\r\n]") then
        error("weread.http: header " .. name .. " contains a line break")
      end
      secrets[#secrets + 1] = line
    else
      argv[#argv + 1] = "--header"
      argv[#argv + 1] = line
    end
  end
  if opts.method and opts.method ~= "GET" then
    argv[#argv + 1] = "--request"
    argv[#argv + 1] = opts.method
  end
  if opts.json then
    argv[#argv + 1] = "--header"
    argv[#argv + 1] = "Content-Type: application/json;charset=UTF-8"
  end
  -- Only downloads are capped: an API reply is small, a hostile or broken
  -- server streaming into a file is not.
  -- (只给下载设上限：API 响应本来就小，而恶意或出故障的服务器往文件里灌数据则不然)
  local max_filesize = opts.max_filesize or (opts.out and DEFAULT_MAX_FILESIZE or nil)
  if max_filesize then
    argv[#argv + 1] = "--max-filesize"
    argv[#argv + 1] = tostring(math.floor(max_filesize))
  end
  argv[#argv + 1] = "--url"
  argv[#argv + 1] = opts.url
  return argv, secrets
end

local function parse_headers(path)
  local text = read_file(path)
  if not text then
    return {}
  end
  local out = {}
  for line in text:gmatch("[^\n]+") do
    local name, value = line:match("^([%w%-]+):%s*(.*)$")
    if name then
      name = name:lower()
      out[name] = out[name] and (out[name] .. ", " .. value) or value
    elseif line:match("^HTTP/") then
      out = {} -- a redirect chain restarts the header block(重定向链会重置 header 块)
    end
  end
  return out
end

---Perform one attempt. The callback always fires exactly once, including when
---curl cannot even be started (not installed, bad body): a caller waiting on
---it (image.lua's in-flight bookkeeping, a login dialog) would otherwise hang
---forever.
---(执行一次尝试。回调必定恰好触发一次，包括 curl 根本启动不了（没装、请求体有问题）的情况：
--- 否则等着它的调用方（image.lua 的在途记录、登录对话框）会永远挂住)
---@param opts table
---@param handle table request handle, see run_with_retries(请求句柄，见 run_with_retries)
---@param callback fun(res: table)
local function attempt(opts, handle, callback)
  local body_path = opts.out or next_tmp("body")
  local secret_path = nil
  -- A partial download must not be mistaken for a finished file later; but a
  -- file that was already there is not ours to delete.
  -- (残缺的下载不能被误当成完整文件；但原本就在那里的文件不归我们删)
  local existed = opts.out ~= nil and vim.uv.fs_stat(opts.out) ~= nil

  local function cleanup()
    if secret_path then
      os.remove(secret_path)
      secret_path = nil
    end
    os.remove(body_path .. ".headers")
    if not opts.out then
      os.remove(body_path)
    end
  end

  -- Failure before curl ran: the same result shape a transport error has,
  -- flagged `fatal` so the retry loop does not try again.
  -- (curl 运行之前的失败：与传输错误同样的结果形状，标记 fatal 以免重试循环再试一遍)
  local function fail(message)
    cleanup()
    local res = { code = 0, headers = {}, stderr = "", error = message, fatal = true }
    vim.schedule(function()
      callback(res)
    end)
  end

  if handle.cancelled then
    return fail("request cancelled")
  end

  local built, argv, secrets = pcall(build_argv, opts, body_path)
  if not built then
    return fail(tostring(argv))
  end

  local stdin = opts.body
  if type(stdin) == "table" then
    local encoded, payload = pcall(vim.json.encode, stdin)
    if not encoded then
      return fail("could not encode the request body: " .. tostring(payload))
    end
    stdin = payload
  end
  if type(stdin) == "string" then
    argv[#argv + 1] = "--data-binary"
    argv[#argv + 1] = "@-"
  end

  if #secrets > 0 then
    local path = next_tmp("hdr")
    local written, write_err = cache.write_new(path, table.concat(secrets, "\n") .. "\n", 384)
    if not written then
      return fail("could not stage the credential headers: " .. tostring(write_err))
    end
    secret_path = path
    argv[#argv + 1] = "--header"
    argv[#argv + 1] = "@" .. path
  end

  -- The spawn timeout must stay strictly larger than curl's own `--max-time`,
  -- otherwise vim.system kills curl first and its useful timeout diagnostics
  -- are lost. (Parentheses matter here: `a or b + 5` parses as `a or (b + 5)`.)
  -- (进程超时必须比 curl 自身的 --max-time 宽松，否则会被 vim.system 先杀掉，
  --  丢掉 curl 的超时诊断；注意括号：`a or b + 5` 会解析成 `a or (b + 5)`)
  local spawn_opts = { text = true, timeout = ((opts.timeout or config.timeout) + 5) * 1000 }
  if stdin then
    spawn_opts.stdin = stdin
  end

  -- `done` covers a spawn whose exit callback fires before `vim.system` has
  -- returned the job (a stub does that), so the job is never registered after
  -- it already finished.
  -- (`done` 处理“退出回调先于 vim.system 返回 job 触发”的情况（桩会这么做），
  --  避免 job 已经结束还被登记进 active)
  local job = nil
  local done = false
  local spawned, spawn_result = pcall(vim.system, argv, spawn_opts, function(completed)
    done = true
    if job then
      active[job] = nil
      handle.job = nil
    end

    local res = {
      code = 0,
      status = nil,
      body = nil,
      headers = parse_headers(body_path .. ".headers"),
      stderr = completed.stderr or "",
      path = opts.out and body_path or nil,
      exit = completed.code,
    }

    local status_text = (completed.stdout or ""):match("(%d%d%d)%s*$")
    if completed.code == 0 and status_text then
      res.status = tonumber(status_text)
      res.code = res.status
    else
      res.code = 0
      res.error = res.stderr ~= "" and vim.trim(res.stderr) or ("curl exited with code " .. tostring(completed.code))
      if handle.cancelled then
        res.cancelled = true
        res.error = "request cancelled"
      elseif completed.code == 63 then
        res.fatal = true -- over --max-filesize; asking again gets the same answer(超过 --max-filesize，再问也是同样的结果)
      end
      -- Our own partial download, not a pre-existing file.
      -- (这是我们自己下到一半的文件，不是原本就有的)
      if opts.out and not existed then
        os.remove(body_path)
      end
    end

    if not opts.out then
      res.body = read_file(body_path)
      if not res.body and not res.error then
        res.error = "empty response body"
      end
    end

    cleanup()

    -- `vim.system` callbacks run in a fast event context, where vimscript
    -- functions such as `vim.fn.mkdir` raise E5560. Every caller of this
    -- module expects a plain main-loop callback, so hop back before handing
    -- the response over.
    -- (vim.system 的回调运行在 fast event context，其中 vim.fn.mkdir 之类的
    --  vimscript 函数会报 E5560；本模块的调用方都假定自己在主循环里，
    --  因此先切回主循环再交付响应)
    vim.schedule(function()
      if opts._jar_out then
        merge_jar(opts._jar_before, opts._jar_out, opts._jar_target)
        opts._jar_before, opts._jar_out, opts._jar_target = nil, nil, nil
      end
      callback(res)
    end)
  end)

  if not spawned then
    -- ENOENT when curl is not on PATH, among others. The exit callback never
    -- runs in this case, so report here.
    -- (curl 不在 PATH 里时会抛 ENOENT 等错误；此时退出回调不会运行，所以在这里报告)
    return fail("could not start curl: " .. tostring(spawn_result))
  end

  job = spawn_result
  if not done and job then
    active[job] = handle
    handle.job = job
  end
end

---Does this response say the session expired?
---(这个响应是否表示会话过期了？)
---
---WeRead answers an expired session with `-2012` / `登录超时`, sometimes as HTTP
---401 and sometimes as a 200 carrying an error object.
---(微信读书对过期会话回 `-2012` / `登录超时`，有时是 HTTP 401，有时是 200 里带错误对象)
---@param res table
---@return boolean
local function session_expired(res)
  if not res or type(res.body) ~= "string" then
    return false
  end
  return res.body:find('"[Ee]rr[Cc]ode"%s*:%s*%-2012') ~= nil
end

---Endpoints that must not trigger a renewal of the session themselves.
---(本身不能触发续期的端点，避免自我循环)
---@param url string
---@return boolean
local function renews_session(url)
  return url:find("/login", 1, true) ~= nil
end

---@class weread.http.Handle
---@field cancelled boolean
---@field job table|nil the curl process of the attempt in flight(在途那次尝试的 curl 进程)
---@field kill fun() abort the request; its callback still fires, flagged `cancelled`(中止请求；回调仍会触发，带 `cancelled` 标记)

---Run a request with retries and session renewal.
---(带重试与会话续期地执行请求)
---
---When several requests hit `-2012` at once only the first one renews: auth
---queues the others on the same renewal, and a request that was sent before the
---last successful renewal skips renewing and simply goes again with the fresh
---cookies, so a burst never turns into a burst of renewals.
---(多个请求同时撞上 `-2012` 时只有第一个真正续期：auth 把其余的排到同一次续期上，而发起时间早于
--- 上次成功续期的请求不再续期，直接带着新 cookie 重发，一阵并发不会变成一阵续期)
---@param opts table
---@param callback fun(res: table)
---@return weread.http.Handle
local function run_with_retries(opts, callback)
  local attempts = math.max(1, (opts.retries or config.retries) + 1)
  local index = 0
  local renewed = false

  local handle = { cancelled = false, job = nil }
  function handle.kill()
    handle.cancelled = true
    local job = handle.job
    if job then
      pcall(job.kill, job, 15)
    end
  end

  local function step()
    index = index + 1
    local sent_at = vim.uv.hrtime()
    attempt(opts, handle, function(res)
      if handle.cancelled then
        callback(res)
        return
      end
      if not renewed and not renews_session(opts.url or "") and session_expired(res) then
        renewed = true
        local ok, auth = pcall(require, "weread.auth")
        if ok then
          local last = type(auth.last_renewed_at) == "function" and auth.last_renewed_at() or 0
          if last > sent_at then
            log_line("session was renewed after this request was sent; retrying with the new cookies")
            index = 0
            step()
            return
          end
          log_line("session expired; renewing and retrying once")
          auth.renew(function(renewed_ok)
            if not renewed_ok then
              callback(res)
              return
            end
            index = 0
            step()
          end)
          return
        end
      end
      if index < attempts and should_retry(res, opts) then
        vim.defer_fn(step, 250 * index)
        return
      end
      callback(res)
    end)
  end

  step()
  return handle
end

---Run a request asynchronously. The returned handle can abort it. A request
---that changes something on the service passes `write = true`, so a timeout
---after the service took it is not sent again.
---(异步发起请求；返回的句柄可用来中止它。会改动服务端数据的请求传 `write = true`，
--- 服务端已收下但超时的请求就不会被再发一遍)
---@param opts table
---@param callback fun(res: table)
---@return weread.http.Handle
function M.request(opts, callback)
  if type(opts) == "string" then
    opts = { url = opts }
  end
  return run_with_retries(opts, callback)
end

---Run a request synchronously. Handy for one-shot commands and tests.
---(同步发起请求，用于一次性命令与测试)
---@param opts table
---@param timeout_ms integer|nil
---@return table
function M.request_sync(opts, timeout_ms)
  local done = false
  local result = nil
  M.request(opts, function(res)
    result = res
    done = true
  end)
  local budget = timeout_ms or ((opts.timeout or config.timeout) + 5) * 1000 * ((opts.retries or config.retries) + 1)
  vim.wait(budget, function()
    return done
  end, 20)
  if not result then
    return { code = 0, error = "request timed out locally" }
  end
  return result
end

---Download a URL straight into a file, bypassing Lua strings entirely.
---(直接把响应写入文件，不经 Lua 字符串，二进制安全)
---@param url string
---@param dest string
---@param opts table|nil
---@param callback fun(res: table)
---@return weread.http.Handle
function M.download(url, dest, opts, callback)
  opts = vim.tbl_extend("force", opts or {}, {
    url = url,
    out = dest,
    method = "GET",
    accept = "*/*",
  })
  pcall(vim.fn.mkdir, vim.fs.dirname(dest), "p")
  return run_with_retries(opts, callback)
end

---Decode a JSON response body, tolerating transport failures.
---(解码 JSON 响应体，容忍传输失败)
---@param res table
---@return table|nil data
---@return string|nil error
function M.decode_json(res)
  if not res or res.code == 0 then
    return nil, (res and res.error) or "request failed"
  end
  if not res.body or res.body == "" then
    return nil, string.format("empty response (HTTP %s)", tostring(res.status))
  end
  local ok, data = pcall(vim.json.decode, res.body)
  if not ok then
    return nil, "invalid JSON response"
  end
  -- `null` decodes to vim.NIL, which is truthy: every caller indexes the result
  -- (`null` 解码成 vim.NIL，它是真值：而每个调用方都会对结果取字段)
  if type(data) ~= "table" then
    return nil, "unexpected JSON response"
  end
  return data, nil
end

---Kill every in-flight request. Used when the plugin shuts down or a login
---dialog is cancelled.
---(终止所有在途请求；插件退出或取消登录时使用)
function M.kill_all()
  local handles = active
  active = {}
  for _, handle in pairs(handles) do
    -- Through the handle, so the retry loop sees a cancel and does not respawn
    -- the process it just lost.
    -- (经由句柄中止，重试循环才知道是被取消而不会把刚没的进程再拉起来)
    handle.kill()
  end
end

---Number of requests currently in flight. For tests.
---(当前在途请求数；供测试使用)
---@return integer
function M._active_count()
  local count = 0
  for _ in pairs(active) do
    count = count + 1
  end
  return count
end

return M
