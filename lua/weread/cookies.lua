--[[
Netscape cookie jar handling (curl's `-b`/`-c` file format).
(Netscape cookie jar 读写，即 curl 的 -b/-c 文件格式)

Kept separate from the HTTP layer so the parsing rules can be unit tested
without touching the network.
(与 HTTP 层分离，便于脱离网络做单测)

Format, tab separated, one cookie per line:
(格式为制表符分隔，每行一个 cookie)

  domain  include_subdomains  path  secure  expires  name  value

`include_subdomains` and `secure` are the literal strings TRUE/FALSE.
`expires` is a unix timestamp, 0 meaning a session cookie.
httpOnly cookies are written with a `#HttpOnly_` prefix glued to the domain,
which is curl's convention for round-tripping the HttpOnly attribute through
the jar file.
(include_subdomains/secure 用字面量 TRUE/FALSE；expires 为 unix 时间戳，0 表示
 会话 cookie；httpOnly cookie 以 `#HttpOnly_` 前缀粘在 domain 前面，这是 curl
 在 jar 文件里回写 HttpOnly 属性的约定)
]]

local M = {}

local HEADER = "# Netscape HTTP Cookie File"

---Parse one jar line into a cookie record, or nil when the line is not a cookie.
---(解析一行；非 cookie 行返回 nil)
---@param line string
---@return table|nil
function M.parse_line(line)
  if type(line) ~= "string" or line == "" then
    return nil
  end

  local http_only = false
  local body = line
  if body:sub(1, 10) == "#HttpOnly_" then
    http_only = true
    body = body:sub(11)
  elseif body:sub(1, 1) == "#" then
    return nil
  end

  local fields = {}
  for field in (body .. "\t"):gmatch("([^\t]*)\t") do
    fields[#fields + 1] = field
  end
  if #fields < 7 then
    return nil
  end

  return {
    domain = fields[1],
    include_subdomains = fields[2]:upper() == "TRUE",
    path = fields[3],
    secure = fields[4]:upper() == "TRUE",
    expires = tonumber(fields[5]) or 0,
    name = fields[6],
    value = fields[7],
    http_only = http_only,
  }
end

---Parse a whole jar file body.
---(解析整个 jar 文件内容)
---@param text string
---@return table[]
function M.parse(text)
  local cookies = {}
  for line in (tostring(text or "") .. "\n"):gmatch("([^\n]*)\n") do
    line = line:gsub("\r$", "")
    local cookie = M.parse_line(line)
    if cookie then
      cookies[#cookies + 1] = cookie
    end
  end
  return cookies
end

---@param cookie table
---@return string
function M.format_line(cookie)
  local prefix = cookie.http_only and "#HttpOnly_" or ""
  return table.concat({
    prefix .. (cookie.domain or ".weread.qq.com"),
    cookie.include_subdomains and "TRUE" or "FALSE",
    cookie.path or "/",
    cookie.secure and "TRUE" or "FALSE",
    tostring(math.floor(tonumber(cookie.expires) or 0)),
    cookie.name or "",
    cookie.value or "",
  }, "\t")
end

---@param cookies table[]
---@return string
function M.serialize(cookies)
  local lines = { HEADER }
  for _, cookie in ipairs(cookies or {}) do
    lines[#lines + 1] = M.format_line(cookie)
  end
  return table.concat(lines, "\n") .. "\n"
end

---Find a cookie by name, preferring an exact domain match over a suffix match.
---(按名字查找 cookie，优先精确域名匹配)
---@param cookies table[]
---@param name string
---@param domain string|nil
---@return table|nil
function M.get(cookies, name, domain)
  local fallback = nil
  for _, cookie in ipairs(cookies or {}) do
    if cookie.name == name then
      if domain and cookie.domain == domain then
        return cookie
      end
      fallback = fallback or cookie
    end
  end
  return fallback
end

---Insert or replace a cookie identified by (name, domain, path).
---(按 name+domain+path 插入或替换 cookie)
---@param cookies table[]
---@param cookie table
---@return table[] cookies
function M.upsert(cookies, cookie)
  local replaced = false
  for index, existing in ipairs(cookies) do
    if
      existing.name == cookie.name
      and existing.domain == cookie.domain
      and (existing.path or "/") == (cookie.path or "/")
    then
      cookies[index] = cookie
      replaced = true
      break
    end
  end
  if not replaced then
    cookies[#cookies + 1] = cookie
  end
  return cookies
end

---Drop every cookie with the given name.
---(按名字删除所有同名 cookie)
---@param cookies table[]
---@param name string
---@return table[] cookies
function M.remove(cookies, name)
  local kept = {}
  for _, cookie in ipairs(cookies) do
    if cookie.name ~= name then
      kept[#kept + 1] = cookie
    end
  end
  return kept
end

---Render a Cookie request header value, dropping expired cookies.
---(渲染 Cookie 请求头，跳过已过期 cookie)
---@param cookies table[]
---@param now integer|nil
---@return string
function M.header(cookies, now)
  now = now or os.time()
  local parts = {}
  for _, cookie in ipairs(cookies or {}) do
    local expired = cookie.expires and cookie.expires > 0 and cookie.expires <= now
    if not expired and cookie.name ~= "" then
      parts[#parts + 1] = cookie.name .. "=" .. cookie.value
    end
  end
  return table.concat(parts, "; ")
end

---@param path string
---@return table[]
function M.load(path)
  local file = io.open(path, "rb")
  if not file then
    return {}
  end
  local text = file:read("*a") or ""
  file:close()
  return M.parse(text)
end

---@param path string
---@param cookies table[]
function M.save(path, cookies)
  local file = assert(io.open(path, "wb"))
  file:write(M.serialize(cookies))
  file:close()
  pcall(vim.uv.fs_chmod, path, 384) -- 0600, credentials must stay private(凭据文件必须保持私有)
end

return M
