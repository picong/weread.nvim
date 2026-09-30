--[[
Minimal POSIX tar reader for WeRead chapter resource packages.

`chapterInfos` returns a `tar` URL per chapter whose response is an
uncompressed POSIX tar holding image files whose names carry no extension and
whose content type has to be sniffed from magic bytes.
(WeRead 章节资源包的极简 POSIX tar 读取器：tar 包内的图片文件没有扩展名，
 需要靠 magic bytes 判断类型)

Supported: regular files, GNU long names (`L`) and pax `path=` records (`x`).
Directories and links are skipped.
(支持普通文件、GNU 长文件名(L) 与 pax 的 path= 记录(x)；目录与链接跳过)
]]

local M = {}

local BLOCK = 512

---@param str string
---@return integer|nil
local function octal(str)
  if not str or str == "" then
    return nil
  end
  local digits = str:match("^%s*([0-7]+)")
  if not digits then
    return nil
  end
  return tonumber(digits, 8)
end

---@param block string
---@return boolean
local function is_zero_block(block)
  return block == string.rep("\0", BLOCK)
end

---@param block string
---@return string
local function field(block, from, to)
  return (block:sub(from, to):gsub("%z.*$", ""))
end

---Parse pax extended header records looking for `path=`.
---(解析 pax 扩展头里的 path= 记录)
---@param data string
---@return string|nil
local function pax_path(data)
  local path = nil
  for record in data:gmatch("(%d+ [^\n]*\n)") do
    local length, body = record:match("^(%d+) (.*)\n$")
    if length and body then
      local key, value = body:match("^([%w%.]+)=(.*)$")
      if key == "path" and value then
        path = value
      end
    end
  end
  return path
end

---Parse a tar archive.
---(解析 tar 归档)
---@param data string
---@param opts table|nil { files_only = true }
---@return table[] entries { name, size, data }
function M.parse(data, opts)
  opts = opts or {}
  local files_only = opts.files_only ~= false
  local entries = {}
  local offset = 1
  local pending_name = nil
  local total = #data

  while offset + BLOCK - 1 <= total do
    local header = data:sub(offset, offset + BLOCK - 1)
    if is_zero_block(header) then
      break
    end

    local name = pending_name or field(header, 1, 100)
    pending_name = nil
    -- ustar ``prefix`` occupies bytes 346..500 in 1-based Lua indexing (0-based
    -- 345..499). Off-by-one here silently mangles every nested path.
    -- (ustar 的 prefix 字段在 1-based 下标下是 346..500；这里差一个字节会静默
    --  弄坏所有嵌套路径)
    local prefix = field(header, 346, 500)
    if prefix ~= "" and not name:find("/", 1, true) then
      name = prefix .. "/" .. name
    end
    -- size is 0-based 124..135, i.e. 1-based 125..136.
    -- (size 字段 0-based 为 124..135，即 1-based 的 125..136)
    local size = octal(field(header, 125, 136)) or 0
    local typeflag = header:sub(157, 157)

    local payload_start = offset + BLOCK
    local payload = data:sub(payload_start, payload_start + size - 1)

    if typeflag == "L" then
      pending_name = (payload:gsub("%z.*$", ""))
    elseif typeflag == "x" then
      pending_name = pax_path(payload) or pending_name
    elseif typeflag == "\0" or typeflag == "0" or typeflag == "" then
      if name ~= "" then
        entries[#entries + 1] = { name = name, size = size, data = payload }
      end
    elseif not files_only then
      -- Opt-in mode: directories, links and other types come through too, with
      -- their typeflag, so callers can inspect the archive.
      -- (可选模式：目录、链接等其他类型也返回，并带上 typeflag)
      entries[#entries + 1] = { name = name, size = size, data = payload, type = typeflag }
    end

    local padded = math.ceil(size / BLOCK) * BLOCK
    offset = payload_start + padded
  end

  return entries
end

---Sniff an image type from file content.
---(根据内容嗅探图片类型)
---@param data string
---@return string|nil extension
---@return string|nil media_type
function M.detect_type(data)
  if #data >= 8 and data:sub(1, 8) == "\137PNG\r\n\26\n" then
    return "png", "image/png"
  end
  if #data >= 3 and data:sub(1, 3) == "\255\216\255" then
    return "jpg", "image/jpeg"
  end
  if #data >= 6 and (data:sub(1, 6) == "GIF87a" or data:sub(1, 6) == "GIF89a") then
    return "gif", "image/gif"
  end
  if #data >= 12 and data:sub(1, 4) == "RIFF" and data:sub(9, 12) == "WEBP" then
    return "webp", "image/webp"
  end
  if #data >= 2 and data:sub(1, 2) == "BM" then
    return "bmp", "image/bmp"
  end
  local head = data:sub(1, 300)
  if head:find("<svg", 1, true) or (head:find("<?xml", 1, true) and head:find("<svg", 1, true)) then
    return "svg", "image/svg+xml"
  end
  return nil, nil
end

---@param path string
---@return string|nil
function M.read_file(path)
  local file = io.open(path, "rb")
  if not file then
    return nil
  end
  local data = file:read("*a")
  file:close()
  return data
end

return M
