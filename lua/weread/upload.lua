--[[
Import a book into the WeRead account, the way the web 传书 page does it, so
an exported EPUB lands on the phone's shelf without leaving the editor.
(像网页「传书」页那样把一本书导入微信读书账号：导出的 EPUB 不出编辑器就出现在手机书架上)

Reverse-engineered from the web reader's upload bundle (BookUpload, checked on
2026-10-26); none of it is documented. Four steps, all with the QR-login cookie:
(从网页阅读器的上传代码逆向得来（BookUpload，2026-10-26 核对），没有任何公开文档。四步，都用扫码登录的 cookie：)

1. `GET /mp/shelf/shelfFull`            refuse early when the shelf is full
                                        (书架满了就提前拒绝)
2. `POST /web/cos/receive`              { name, md5, signature, timestamp, random,
                                        bookId = "" }: a file the service already has
                                        (same MD5) is imported at once and answers
                                        with its bookInfo
                                        (服务端已有同 MD5 的文件时直接导入，回 bookInfo)
3. `GET /web/cos/getcredential?name=`   temporary COS keys, the object name and the
                                        bucket; the file is then PUT straight into
                                        Tencent COS, signed with those keys
                                        (COS 临时密钥、对象名与桶；随后用这组密钥签名，把文件直接 PUT 进腾讯云 COS)
4. `POST /web/cos/notify {path, name}`  polled every two seconds while the service
                                        parses the book: status 0 or 3 is done (with
                                        bookId), 2 is a refusal with errmsg, 1 is
                                        still working
                                        (服务端解析期间每两秒轮询：status 0 或 3 完成（带 bookId），2 为拒绝（带
                                         errmsg），1 为仍在处理)

The `signature` of step 2 is the bundle's `s(random, timestamp, md5)`: each
value through a byte substitution table, sorted, rotated, SHA-256 twice. It is
ported below and checked against the bundle's own code in the specs.
(第 2 步的 signature 就是网页代码里的 s(random, timestamp, md5)：每个值过一张字节替换表、排序、旋转、两次
 SHA-256。下面是它的移植，spec 里和网页代码自己的结果对拍)
]]

local cache = require("weread.cache")
local crypto = require("weread.crypto")
local log = require("weread.log")

local M = {}

---The bucket and region the bundle falls back on when the credential reply
---does not name them.
---(凭据回复里没有给出时，网页代码使用的桶与地域)
M.BUCKET = "weread-epub-1258476243"
M.REGION = "ap-shanghai"

---How often and how long the parse is polled. The web page gives up after
---three minutes.
---(解析状态的轮询间隔与总时长；网页三分钟后放弃)
M.POLL_MS = 2000
M.POLL_LIMIT_MS = 180000

---Where objects are PUT; nil is the bucket's own https host. Tests point it at
---the mock server.
---(对象 PUT 到哪里；nil 表示桶自己的 https 主机。测试会把它指向 mock 服务器)
---@type string|nil
M.COS_URL = nil

-- --------------------------------------------------------------- signature

---The bundle's substitution table, byte for byte.
---(网页代码里的替换表，逐字节照抄)
local SUBST = {
  0x34, 0xca, 0x55, 0x40, 0x1d, 0xb6, 0x93, 0xc6, 0x31, 0x30, 0x29, 0x35, 0x32, 0xa7, 0xb8, 0x11,
  0xc2, 0xb5, 0x16, 0xfa, 0x8b, 0xb1, 0x24, 0xa4, 0x10, 0x90, 0x04, 0xe9, 0x08, 0xf8, 0x3b, 0x8a,
  0x9c, 0x8c, 0x44, 0xf9, 0xbc, 0x5c, 0x69, 0xe2, 0xa1, 0xda, 0xd2, 0xd3, 0x75, 0x89, 0xf7, 0x1e,
  0x2d, 0x50, 0x56, 0xd7, 0x72, 0x53, 0xbf, 0x22, 0xfb, 0x20, 0x0f, 0x01, 0x2e, 0x45, 0x87, 0x6e,
  0x66, 0x48, 0xf2, 0xe0, 0xcd, 0xfe, 0x67, 0xa9, 0x43, 0xf4, 0x94, 0x51, 0xce, 0xa5, 0x4a, 0xee,
  0x13, 0x26, 0x8e, 0xcc, 0xaa, 0x33, 0x14, 0x5d, 0x0e, 0x39, 0xbb, 0xcf, 0x91, 0x2b, 0x81, 0x4d,
  0xea, 0x99, 0xec, 0x1a, 0x2c, 0x85, 0xc5, 0xd9, 0x36, 0x74, 0x4b, 0x18, 0xe1, 0xf1, 0x3d, 0x9d,
  0x41, 0x9f, 0xb4, 0x17, 0x0d, 0xd6, 0x4c, 0xbe, 0xdc, 0xaf, 0x97, 0x28, 0x77, 0xf0, 0x62, 0xff,
  0x71, 0xc1, 0xc8, 0x27, 0x8f, 0x6c, 0x68, 0xa8, 0x9b, 0xe6, 0x59, 0x1c, 0x1b, 0x12, 0x09, 0x98,
  0x4e, 0x3f, 0x06, 0x37, 0x00, 0xba, 0x1f, 0x0a, 0x19, 0x2f, 0xc9, 0xd5, 0xd0, 0x57, 0x49, 0x6f,
  0xfd, 0x25, 0xe4, 0x61, 0x0c, 0x42, 0xcb, 0x96, 0x64, 0x5f, 0xdb, 0xad, 0x60, 0x23, 0x8d, 0x9a,
  0x6d, 0xc3, 0xc4, 0x5e, 0x3e, 0xb9, 0x92, 0x6a, 0xbd, 0x5b, 0x07, 0x7f, 0x76, 0x95, 0xed, 0x4f,
  0xab, 0x84, 0x7a, 0x80, 0xe7, 0x78, 0xc7, 0xe5, 0xeb, 0x73, 0x83, 0x6b, 0xfc, 0x38, 0x46, 0x7d,
  0x47, 0x65, 0xb3, 0x52, 0x63, 0x3a, 0x05, 0xd1, 0xef, 0xa3, 0xa6, 0xde, 0x9e, 0x3c, 0x02, 0xae,
  0xb2, 0x7b, 0xa0, 0xf6, 0xf3, 0x2a, 0xc0, 0xac, 0x86, 0x03, 0x5a, 0x54, 0x0b, 0xf5, 0x82, 0xd4,
  0x7e, 0xe3, 0xdf, 0xb0, 0xd8, 0xdd, 0x21, 0xe8, 0x7c, 0x88, 0xa2, 0x79, 0x58, 0x70, 0xb7, 0x15,
}

---Each character of an ASCII string through the table. The result holds code
---points 0-255, kept here as single bytes, which is what the bundle hashes.
---(ASCII 字符串的每个字符过一遍替换表。结果是 0–255 的码位，这里存成单字节，正是网页代码拿去哈希的东西)
---@param text string
---@return string
local function substitute(text)
  local out = {}
  for index = 1, #text do
    out[index] = string.char(SUBST[text:byte(index) + 1])
  end
  return table.concat(out)
end

---@param text string
---@return integer
local function xor_mod(text)
  local value = 0
  for index = 1, #text do
    value = bit.bxor(value, text:byte(index))
  end
  return value % 11
end

---Move every character `by` places to the right, wrapping around.
---(每个字符右移 by 位，绕回开头)
---@param text string
---@param by integer
---@return string
local function rotate(text, by)
  local length = #text
  if length == 0 then
    return text
  end
  by = by % length
  return text:sub(length - by + 1) .. text:sub(1, length - by)
end

---The upload signature: the bundle's `s(random, timestamp, md5)`.
---(上传签名：即网页代码的 s(random, timestamp, md5))
---@param random integer
---@param timestamp integer
---@param md5 string lower-case hex(小写十六进制)
---@return string
function M.signature(random, timestamp, md5)
  local parts = {
    substitute(tostring(timestamp)),
    substitute(tostring(random)),
    substitute(md5),
    substitute("5ecdcfd7f"),
    "5a6f1",
  }
  -- JavaScript sorts strings by UTF-16 code unit; every character here is one
  -- byte, so a byte comparison is the same order
  -- (JavaScript 按 UTF-16 码元排序字符串；这里每个字符都是一个字节，所以按字节比较顺序相同)
  table.sort(parts)
  local joined = table.concat(parts)
  local first = crypto.sha256_hex(rotate(joined, xor_mod(joined)))
  return crypto.sha256_hex(rotate(first, xor_mod(first)))
end

-- ------------------------------------------------------------- COS signing

---@param key string
---@param message string
---@return string hex
local function hmac_sha1(key, message)
  local result = vim.system({ "openssl", "dgst", "-sha1", "-hmac", key, "-r" }, { stdin = message, text = true }):wait()
  if result.code ~= 0 then
    error("openssl failed: " .. tostring(result.stderr))
  end
  return (result.stdout:match("^(%x+)"))
end

---@param message string
---@return string hex
local function sha1(message)
  local result = vim.system({ "openssl", "dgst", "-sha1", "-r" }, { stdin = message, text = true }):wait()
  if result.code ~= 0 then
    error("openssl failed: " .. tostring(result.stderr))
  end
  return (result.stdout:match("^(%x+)"))
end

---@param text string
---@return string
local function url_encode(text)
  return (text:gsub("[^%w%-%._~]", function(char)
    return string.format("%%%02X", char:byte())
  end))
end

---The `Authorization` header of a COS request (COS signature v5, q-sign-algorithm
---sha1), for a PUT of `key` with the given headers signed.
---(一次 COS 请求的 Authorization 头（COS v5 签名，q-sign-algorithm=sha1）：对 key 的 PUT，签入给定的头)
---@param secret_id string
---@param secret_key string
---@param method string
---@param key string object path, starting with "/"(对象路径，以 "/" 开头)
---@param headers table<string, string>
---@param from integer
---@param to integer
---@return string
function M.cos_authorization(secret_id, secret_key, method, key, headers, from, to)
  local key_time = string.format("%d;%d", from, to)
  local sign_key = hmac_sha1(secret_key, key_time)
  local names = {}
  for name in pairs(headers) do
    names[#names + 1] = name:lower()
  end
  table.sort(names)
  local lower = {}
  for name, value in pairs(headers) do
    lower[name:lower()] = value
  end
  local pairs_list = {}
  for _, name in ipairs(names) do
    pairs_list[#pairs_list + 1] = url_encode(name) .. "=" .. url_encode(lower[name])
  end
  local http_string = table.concat({ method:lower(), key, "", table.concat(pairs_list, "&"), "" }, "\n")
  local string_to_sign = table.concat({ "sha1", key_time, sha1(http_string), "" }, "\n")
  local signature = hmac_sha1(sign_key, string_to_sign)
  return table.concat({
    "q-sign-algorithm=sha1",
    "q-ak=" .. secret_id,
    "q-sign-time=" .. key_time,
    "q-key-time=" .. key_time,
    "q-header-list=" .. table.concat(names, ";"),
    "q-url-param-list=",
    "q-signature=" .. signature,
  }, "&")
end

---Host of a bucket in a region; "accelerate" is the global acceleration domain.
---(某个桶在某个地域的主机名；"accelerate" 是全球加速域名)
---@param bucket string
---@param region string
---@return string
function M.cos_host(bucket, region)
  return string.format("%s.cos.%s.myqcloud.com", bucket, region)
end

-- ------------------------------------------------------------------ steps

---@param path string
---@param params table|nil query(查询参数)
---@param body table|nil JSON body: a POST(JSON 请求体：POST)
---@param callback fun(ok: boolean, data: table|string)
local function call(path, params, body, callback)
  local http = require("weread.http")
  local origin = require("weread.config").web_origin()
  local query = {}
  for name, value in pairs(params or {}) do
    query[#query + 1] = url_encode(name) .. "=" .. url_encode(tostring(value))
  end
  table.sort(query)
  http.request({
    url = origin .. path .. (#query > 0 and ("?" .. table.concat(query, "&")) or ""),
    method = body and "POST" or "GET",
    json = body ~= nil,
    body = body,
    referer = origin .. "/web/upload",
    timeout = 30,
  }, function(res)
    local data, err = http.decode_json(res)
    if type(data) ~= "table" then
      callback(false, tostring(err or ("HTTP " .. tostring(res and res.status))))
      return
    end
    local code = tonumber(data.errCode or data.errcode)
    if code and code ~= 0 then
      callback(false, tostring(data.errMsg or data.errmsg or code))
      return
    end
    callback(true, data)
  end)
end

---PUT the file into COS with curl reading it from disk.
---(用 curl 从磁盘读取文件，PUT 进 COS)
---@param path string
---@param credential table the getcredential reply(getcredential 的回复)
---@param callback fun(ok: boolean, err: string|nil)
local function put_object(path, credential, callback)
  local keys = credential.Response.Credentials
  local key = credential.ObjectName
  if key:sub(1, 1) ~= "/" then
    key = "/" .. key
  end
  local host = M.cos_host(credential.bucket or M.BUCKET, credential.region or M.REGION)
  local size = vim.uv.fs_stat(path).size
  local now = tonumber(credential.ServerTime) or os.time()
  local expires = tonumber(credential.Response.ExpiredTime) or (now + 1800)
  local signed = { host = host, ["content-length"] = tostring(size) }
  local ok, authorization = pcall(M.cos_authorization, keys.TmpSecretId, keys.TmpSecretKey, "PUT", key, signed, now - 60, expires)
  if not ok then
    callback(false, tostring(authorization))
    return
  end
  -- The credentials go through a header file, never the argv another process
  -- could read.
  -- (凭据经头文件交给 curl，绝不放进别的进程读得到的 argv)
  local header_file = vim.fn.tempname()
  local wrote = cache.write_new(header_file, table.concat({
    "Authorization: " .. authorization,
    "x-cos-security-token: " .. keys.Token,
    "Content-Type: application/epub+zip",
    "",
  }, "\n"), 384)
  if not wrote then
    callback(false, "写不进临时文件")
    return
  end
  local argv = {
    "curl",
    "--silent",
    "--show-error",
    "--max-time",
    "600",
    "--write-out",
    "%{http_code}",
    "--output",
    "/dev/null",
    "--header",
    "@" .. header_file,
    "--upload-file",
    path,
    (M.COS_URL or ("https://" .. host)) .. key,
  }
  vim.system(argv, { text = true }, function(result)
    os.remove(header_file)
    local status = tonumber((result.stdout or ""):match("(%d%d%d)%s*$"))
    vim.schedule(function()
      if result.code == 0 and status and status >= 200 and status < 300 then
        callback(true, nil)
      else
        callback(false, string.format("上传到 COS 失败（HTTP %s）%s", tostring(status), vim.trim(result.stderr or "")))
      end
    end)
  end)
end

---Poll the service until it has parsed the uploaded book.
---(轮询服务端，直到它解析完上传的书)
---@param object string
---@param name string
---@param callback fun(ok: boolean, result: string)
local function wait_for_parse(object, name, callback)
  local started = vim.uv.now()
  local function poll()
    call("/web/cos/notify", nil, { path = object, name = name }, function(ok, data)
      if not ok then
        callback(false, "查询解析状态失败：" .. tostring(data))
        return
      end
      local inner = type(data.data) == "table" and data.data or data
      local status = tonumber(inner.status)
      if status == 0 or status == 3 then
        callback(true, tostring(inner.bookId or ""))
      elseif status == 2 then
        callback(false, "微信读书拒绝了这本书：" .. tostring(inner.errmsg or inner.errMsg or "?"))
      elseif status == 1 and vim.uv.now() - started < M.POLL_LIMIT_MS then
        require("weread.timer").defer(poll, M.POLL_MS)
      elseif status == 1 then
        callback(false, "微信读书三分钟内没解析完这本书，稍后到书架上看看")
      else
        callback(false, "解析状态未知：" .. tostring(status))
      end
    end)
  end
  poll()
end

---Import a file into the account's shelf.
---(把一个文件导入账号书架)
---@param path string
---@param callback fun(ok: boolean, result: string) bookId, or why not(bookId，或者失败原因)
---@param on_step fun(message: string)|nil
function M.import(path, callback, on_step)
  local stat = vim.uv.fs_stat(path)
  if not stat then
    callback(false, "找不到文件：" .. path)
    return
  end
  local data = cache.read(path)
  if not data then
    callback(false, "读不了文件：" .. path)
    return
  end
  local name = vim.fs.basename(path)
  local md5 = crypto.md5_hex(data)
  local step = on_step or function() end
  call("/mp/shelf/shelfFull", nil, nil, function(ok, full)
    if ok and full.isShelfFull then
      callback(false, "书架已满")
      return
    end
    local timestamp = os.time()
    local random = math.random(0, 99999)
    call("/web/cos/receive", nil, {
      name = name,
      md5 = md5,
      signature = M.signature(random, timestamp, md5),
      timestamp = timestamp,
      random = random,
      bookId = "",
    }, function(received, reply)
      local info = received and type(reply.data) == "table" and reply.data.bookInfo
      if type(info) == "table" and info.bookId then
        -- the service already has this very file: imported on the spot
        -- (服务端已经有一模一样的文件：当场导入)
        callback(true, tostring(info.bookId))
        return
      end
      if not received then
        log.debug("upload: receive answered %s, uploading the file", tostring(reply))
      end
      step("正在上传 " .. name .. "…")
      call("/web/cos/getcredential", { name = name }, nil, function(got, credential)
        local keys = got and type(credential.Response) == "table" and credential.Response.Credentials or nil
        if
          type(keys) ~= "table"
          or type(credential.ObjectName) ~= "string"
          or type(keys.Token) ~= "string"
          or type(keys.TmpSecretId) ~= "string"
          or type(keys.TmpSecretKey) ~= "string"
        then
          callback(false, "拿不到上传凭据：" .. tostring(got and "回复里没有 Credentials" or credential))
          return
        end
        put_object(path, credential, function(put, err)
          if not put then
            call("/web/cos/notify", nil, { path = credential.ObjectName, name = name, cancel = 1 }, function() end)
            callback(false, err)
            return
          end
          step("已上传，等微信读书解析…")
          wait_for_parse(credential.ObjectName, name, callback)
        end)
      end)
    end)
  end)
end

return M
