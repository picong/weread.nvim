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
]]

local cookies = require("weread.cookies")

local M = {}

local config = {
  ua = table.concat({
    "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7)",
    "AppleWebKit/537.36 (KHTML, like Gecko)",
    "Chrome/135.0.0.0 Safari/537.36 Edg/135.0.0.0",
  }, " "),
  origin = "https://weread.qq.com",
  referer = "https://weread.qq.com/",
  timeout = 20,
  retries = 2,
  jar = nil,
  tmpdir = nil,
  ---nil inherits the environment proxy, "direct" bypasses it, otherwise a proxy url.
  ---(nil 表示沿用环境变量里的代理，"direct" 强制直连，其余值当作代理地址)
  proxy = nil,
}

local counter = 0
local active = {}

---@param opts table|nil
function M.setup(opts)
  for key, value in pairs(opts or {}) do
    config[key] = value
  end
  config.tmpdir = config.tmpdir or (config.jar and vim.fs.dirname(config.jar)) or vim.fn.stdpath("run")
  vim.fn.mkdir(config.tmpdir, "p")
  M.ensure_jar()
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

---Create an empty jar on first use so curl never complains about a missing file.
---(首次使用时创建空 jar，避免 curl 报文件不存在)
function M.ensure_jar()
  local path = M.jar_path()
  if vim.fn.filereadable(path) == 0 then
    vim.fn.mkdir(vim.fs.dirname(path), "p")
    local file = assert(io.open(path, "wb"))
    file:write("# Netscape HTTP Cookie File\n")
    file:close()
    pcall(vim.uv.fs_chmod, path, 384)
  end
end

---@return table[]
function M.load_cookies()
  M.ensure_jar()
  return cookies.load(M.jar_path())
end

---Replace the whole jar. Used by the login flow, which swaps accounts and must
---not inherit cookies from the previous one.
---(整体替换 jar；登录流程会切换账号，不能继承上一个账号的 cookie)
---@param list table[]
function M.set_cookies(list)
  cookies.save(M.jar_path(), list)
end

---@param list table[]
function M.add_cookies(list)
  local jar = M.load_cookies()
  for _, cookie in ipairs(list) do
    cookies.upsert(jar, cookie)
  end
  M.set_cookies(jar)
end

---@param name string
function M.remove_cookies(name)
  local jar = M.load_cookies()
  jar = cookies.remove(jar, name)
  M.set_cookies(jar)
end

function M.clear_cookies()
  M.set_cookies({})
end

---@return string
function M.cookie_header()
  return cookies.header(M.load_cookies())
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

---Build the argv for one curl invocation.
---(构造一次 curl 调用的参数)
local function build_argv(opts, body_path)
  if type(opts.url) ~= "string" or opts.url == "" then
    error("weread.http: request without a url")
  end

  local argv = {
    "curl",
    "--silent",
    "--show-error",
    "--location",
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

  if opts.referer ~= false then
    argv[#argv + 1] = "--referer"
    argv[#argv + 1] = opts.referer or config.referer
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
    argv[#argv + 1] = "Origin: " .. (opts.origin or config.origin)
  end
  if opts.no_cookies then
    argv[#argv + 1] = "--header"
    argv[#argv + 1] = "Cookie: "
  else
    M.ensure_jar()
    argv[#argv + 1] = "--cookie"
    argv[#argv + 1] = M.jar_path()
    if opts.persist then
      argv[#argv + 1] = "--cookie-jar"
      argv[#argv + 1] = M.jar_path()
    end
  end
  for name, value in pairs(opts.headers or {}) do
    argv[#argv + 1] = "--header"
    argv[#argv + 1] = name .. ": " .. value
  end
  if opts.method and opts.method ~= "GET" then
    argv[#argv + 1] = "--request"
    argv[#argv + 1] = opts.method
  end
  if opts.json then
    argv[#argv + 1] = "--header"
    argv[#argv + 1] = "Content-Type: application/json;charset=UTF-8"
  end
  argv[#argv + 1] = "--url"
  argv[#argv + 1] = opts.url
  return argv
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

---Perform one attempt.
---(执行一次尝试)
local function attempt(opts, callback)
  local body_path = opts.out or next_tmp("body")
  local argv = build_argv(opts, body_path)
  local stdin = opts.body
  if type(stdin) == "table" then
    stdin = vim.json.encode(stdin)
    argv[#argv + 1] = "--data-binary"
    argv[#argv + 1] = "@-"
  elseif type(stdin) == "string" then
    argv[#argv + 1] = "--data-binary"
    argv[#argv + 1] = "@-"
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

  local job = vim.system(argv, spawn_opts, function(completed)
    local res = {
      code = 0,
      status = nil,
      body = nil,
      headers = parse_headers(body_path .. ".headers"),
      stderr = completed.stderr or "",
      path = opts.out and body_path or nil,
    }

    local status_text = (completed.stdout or ""):match("(%d%d%d)%s*$")
    if completed.code == 0 and status_text then
      res.status = tonumber(status_text)
      res.code = res.status
    else
      res.code = 0
      res.error = res.stderr ~= "" and vim.trim(res.stderr) or ("curl exited with code " .. tostring(completed.code))
    end

    if not opts.out then
      res.body = read_file(body_path)
      if not res.body and not res.error then
        res.error = "empty response body"
      end
    end

    if not opts.out then
      os.remove(body_path)
      os.remove(body_path .. ".headers")
    end

    -- `vim.system` callbacks run in a fast event context, where vimscript
    -- functions such as `vim.fn.mkdir` raise E5560. Every caller of this
    -- module expects a plain main-loop callback, so hop back before handing
    -- the response over.
    -- (vim.system 的回调运行在 fast event context，其中 vim.fn.mkdir 之类的
    --  vimscript 函数会报 E5560；本模块的调用方都假定自己在主循环里，
    --  因此先切回主循环再交付响应)
    vim.schedule(function()
      callback(res)
    end)
  end)

  active[job] = true
end

local function run_with_retries(opts, callback)
  local attempts = math.max(1, (opts.retries or config.retries) + 1)
  local index = 0

  local function step()
    index = index + 1
    attempt(opts, function(res)
      if index < attempts and should_retry(res, opts) then
        vim.defer_fn(step, 250 * index)
        return
      end
      callback(res)
    end)
  end

  step()
end

---Run a request asynchronously.
---(异步发起请求)
---@param opts table
---@param callback fun(res: table)
function M.request(opts, callback)
  if type(opts) == "string" then
    opts = { url = opts }
  end
  run_with_retries(opts, callback)
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
function M.download(url, dest, opts, callback)
  opts = vim.tbl_extend("force", opts or {}, {
    url = url,
    out = dest,
    method = "GET",
    accept = "*/*",
  })
  vim.fn.mkdir(vim.fs.dirname(dest), "p")
  run_with_retries(opts, callback)
end

---@param opts table|nil
---@return table
function M.get_json(url, opts)
  opts = vim.tbl_extend("force", opts or {}, { url = url, method = "GET" })
  return M.request_sync(opts)
end

---@param url string
---@param body table|string
---@param opts table|nil
---@return table
function M.post_json(url, body, opts)
  opts = vim.tbl_extend("force", opts or {}, { url = url, method = "POST", json = true, body = body })
  return M.request_sync(opts)
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
  return data, nil
end

---Kill every in-flight request. Used when the plugin shuts down or a login
---dialog is cancelled.
---(终止所有在途请求；插件退出或取消登录时使用)
function M.kill_all()
  for job in pairs(active) do
    pcall(function()
      job:kill(15)
    end)
  end
  active = {}
end

return M
