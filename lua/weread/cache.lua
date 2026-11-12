--[[
On-disk layout and file IO for the per-book cache.
(按书缓存的磁盘布局与文件读写)

    $data_dir/
    ├── credentials.json          0600
    ├── cookies.txt               0600
    ├── positions.json
    └── books/<bookId>/
        ├── meta.json             title/author/format/cover
        ├── catalog.json
        ├── assets/               images unpacked from the chapter tar
        ├── chapters/003.xhtml    raw source, the basis for offset mapping
        ├── chapters/003.md       rendered markdown
        ├── chapters/003.map.json source rune offset -> markdown position
        └── annotations/003.json

Writes go through a temp file plus rename so an interrupted fetch cannot leave
a half-written chapter behind. Credentials pass mode 0600, which is applied when
the temp file is created, so the secret is never readable by others, not even
for an instant.
(写入走临时文件 + rename，避免中断留下半个章节。凭据类传 0600，权限在临时文件创建时
 就生效，密钥不会有哪怕一瞬间对其他用户可读)
]]

local config = require("weread.config")
local log = require("weread.log")

local M = {}

---@param book_id string|number
---@return string
function M.book_dir(book_id)
  return config.path("books", tostring(book_id))
end

---Stable file stem for a chapter, based on chapterIdx so that files sort the
---same way the book does.
---(章节文件名基：基于 chapterIdx，保证目录里的顺序与书一致)
---@param chapter table
---@return string
function M.chapter_key(chapter)
  local index = tonumber(chapter.chapterIdx) or tonumber(chapter.chapterUid) or 0
  return string.format("%04d", index)
end

---@param book_id string|number
---@return string
function M.chapters_dir(book_id)
  return M.book_dir(book_id) .. "/chapters"
end

---@param book_id string|number
---@return string
function M.assets_dir(book_id)
  return M.book_dir(book_id) .. "/assets"
end

---@param book_id string|number
---@return string
function M.annotations_dir(book_id)
  return M.book_dir(book_id) .. "/annotations"
end

---@param book_id string|number
---@param name string
---@return string
function M.book_file(book_id, name)
  return M.book_dir(book_id) .. "/" .. name
end

---@param book_id string|number
---@param chapter table
---@param kind string
---@return string
function M.chapter_file(book_id, chapter, kind)
  return string.format("%s/%s.%s", M.chapters_dir(book_id), M.chapter_key(chapter), kind)
end

---@param book_id string|number
function M.ensure_book_dirs(book_id)
  for _, dir in ipairs({
    M.book_dir(book_id),
    M.chapters_dir(book_id),
    M.assets_dir(book_id),
    M.annotations_dir(book_id),
  }) do
    vim.fn.mkdir(dir, "p")
  end
end

---@param path string
---@return string|nil
function M.read(path)
  local file = io.open(path, "rb")
  if not file then
    return nil
  end
  local data = file:read("*a")
  file:close()
  return data
end

-- File modes as decimals: LuaJIT has no 0o literals. (文件权限用十进制：LuaJIT 没有 0o 字面量)
local MODE_PRIVATE = 384 -- 0600
local MODE_DEFAULT = 438 -- 0666, narrowed by the umask like io.open did(与 io.open 一样受 umask 约束)

local tmp_counter = 0

---Unique sibling name for a temp file: pid plus a counter, so two nvim
---instances (or two writes in one) never share a temp file.
---(同目录下的唯一临时名：pid + 计数器，多个 nvim 实例或同一进程的多次写入不会共用临时文件)
---@param path string
---@return string
local function unique_tmp(path)
  tmp_counter = tmp_counter + 1
  return string.format("%s.tmp-%d-%d", path, vim.uv.os_getpid(), tmp_counter)
end

---Create a new file exclusively with `mode` and write `data` into it. Any
---failure removes the file again.
---(以 `mode` 独占创建新文件并写入 data；任一步失败都会删掉该文件)
---@param path string
---@param data string
---@param mode integer
---@param durable boolean fsync before closing(关闭前 fsync)
---@return boolean|nil ok
---@return string|nil err
local function write_exclusive(path, data, mode, durable)
  local fd, open_err = vim.uv.fs_open(path, "wx", mode)
  if not fd then
    return nil, open_err
  end
  local function fail(step, err)
    if fd then
      vim.uv.fs_close(fd)
      fd = nil
    end
    vim.uv.fs_unlink(path)
    return nil, string.format("%s failed: %s", step, tostring(err))
  end

  -- fs_write may write less than asked; keep going until all bytes are out.
  -- (fs_write 可能只写了一部分，循环直到写完)
  local offset = 0
  while offset < #data do
    local written, write_err = vim.uv.fs_write(fd, data:sub(offset + 1), offset)
    if not written then
      return fail("write", write_err)
    end
    if written <= 0 then
      return fail("write", "wrote 0 bytes")
    end
    offset = offset + written
  end
  if durable then
    local synced, sync_err = vim.uv.fs_fsync(fd)
    if not synced then
      return fail("fsync", sync_err)
    end
  end
  local closed, close_err = vim.uv.fs_close(fd)
  fd = nil
  if not closed then
    vim.uv.fs_unlink(path)
    return nil, "close failed: " .. tostring(close_err)
  end
  return true, nil
end

---Create a brand new file (exclusive, so an existing one is never touched)
---with the given mode and content. For short-lived secrets such as request
---header files, where a rename and an fsync would be wasted.
---(独占创建带指定权限的新文件，已存在则失败；用于请求头文件这类短命密钥文件，不需要 rename 与 fsync)
---@param path string
---@param data string
---@param mode integer|nil defaults to 0600(默认 0600)
---@return boolean|nil ok
---@return string|nil err
function M.write_new(path, data, mode)
  local ok, err = write_exclusive(path, data, mode or MODE_PRIVATE, false)
  if not ok then
    return nil, "could not create " .. path .. ": " .. tostring(err)
  end
  return true, nil
end

---Atomically replace `path` with `data`: temp file created with `mode` (0600 by
---default), every write checked, fsync, close, then rename. Any failure removes
---the temp file and leaves the previous content untouched. The parent directory
---must exist.
---(原子替换 path：以 mode（默认 0600）创建临时文件，逐步检查写入、fsync、close，最后 rename；
--- 任一步失败都会删掉临时文件、原内容原封不动。父目录必须已存在)
---@param path string
---@param data string
---@param mode integer|nil
---@return boolean|nil ok
---@return string|nil err
function M.atomic_write(path, data, mode)
  if type(data) ~= "string" then
    return nil, "refusing to write a " .. type(data) .. " to " .. tostring(path)
  end
  mode = mode or MODE_PRIVATE

  -- A leftover temp name from a dead process with the same pid is rare but
  -- possible; "wx" refuses to reuse it, so take the next name.
  -- (同 pid 的已死进程可能留下同名临时文件；"wx" 拒绝复用，换下一个名字)
  local tmp, ok, err
  for _ = 1, 5 do
    tmp = unique_tmp(path)
    ok, err = write_exclusive(tmp, data, mode, true)
    if ok or not tostring(err):find("EEXIST", 1, true) then
      break
    end
  end
  if not ok then
    return nil, "could not write " .. tostring(tmp) .. ": " .. tostring(err)
  end

  local renamed, rename_err = vim.uv.fs_rename(tmp, path)
  if not renamed then
    vim.uv.fs_unlink(tmp)
    return nil, "could not rename onto " .. path .. ": " .. tostring(rename_err)
  end
  return true, nil
end

---Write a file atomically, creating the parent directory first.
---(原子写入文件，先创建父目录)
---@param path string
---@param data string
---@param mode integer|nil defaults to the umask-narrowed 0666 like before; pass 384 (0600) for secrets(默认与此前一致，凭据类传 384 即 0600)
---@return boolean ok
---@return string|nil err
function M.write(path, data, mode)
  -- See qr.encode: vim.fn.mkdir raises rather than reporting failure.
  -- (同 qr.encode：vim.fn.mkdir 失败时会抛异常)
  local made, mkdir_err = pcall(vim.fn.mkdir, vim.fs.dirname(path), "p")
  if not made then
    return false, "could not create " .. vim.fs.dirname(path) .. ": " .. tostring(mkdir_err)
  end
  local ok, err = M.atomic_write(path, data, mode or MODE_DEFAULT)
  if not ok then
    return false, err
  end
  return true, nil
end

---@param path string
---@param data string
---@return boolean ok
---@return string|nil err
function M.append(path, data)
  local made, mkdir_err = pcall(vim.fn.mkdir, vim.fs.dirname(path), "p")
  if not made then
    return false, "could not create " .. vim.fs.dirname(path) .. ": " .. tostring(mkdir_err)
  end
  local file = io.open(path, "ab")
  if not file then
    return false, "could not append to " .. path
  end
  file:write(data)
  file:close()
  return true, nil
end

---Move an unreadable file out of the way instead of leaving it to be silently
---overwritten by the next read-modify-write.
---(把读不了的文件挪到一边，免得被下一次读-改-写悄悄覆盖)
---@param path string
---@return string|nil backup
---@return string|nil err
local function quarantine(path)
  local stamp = os.date("%Y%m%d-%H%M%S")
  local backup = string.format("%s.corrupt-%s", path, stamp)
  local suffix = 0
  while vim.uv.fs_stat(backup) do
    suffix = suffix + 1
    backup = string.format("%s.corrupt-%s-%d", path, stamp, suffix)
  end
  local ok, err = vim.uv.fs_rename(path, backup)
  if not ok then
    return nil, tostring(err)
  end
  return backup, nil
end

---Read and decode a JSON object/array file, telling "not there" from "broken".
---(读取并解码 JSON 文件，区分「不存在」与「损坏」)
---
---status is "ok", "missing" (no file, or an empty one) or "corrupt": invalid
---JSON, or valid JSON that is not a table (`null`, a number, a string). A
---corrupt file is renamed to `<name>.corrupt-<timestamp>` and logged, because
---returning nil for it would let the caller's read-modify-write replace the
---only copy of whatever was left in it.
---(status 取 "ok"、"missing"（无文件或空文件）或 "corrupt"：JSON 非法，或合法但不是 table
--- （`null`、数字、字符串）。损坏的文件会被改名为 `<原名>.corrupt-<时间戳>` 并记日志：
--- 若直接返回 nil，调用方的读-改-写会把仅存的那份残留覆盖掉)
---@param path string
---@return table|nil data
---@return string status
---@return string|nil backup path of the quarantined file(被隔离文件的路径)
---@return string|nil err why the quarantine rename failed(隔离改名失败的原因)
function M.load_json(path)
  local text = M.read(path)
  if not text or text == "" then
    return nil, "missing"
  end
  local ok, data = pcall(vim.json.decode, text)
  if ok and type(data) == "table" then
    return data, "ok"
  end
  local backup, err = quarantine(path)
  if backup then
    log.warn("%s is not valid JSON; moved it to %s", path, backup)
  else
    log.warn("%s is not valid JSON and could not be moved aside: %s", path, tostring(err))
  end
  return nil, "corrupt", backup, err
end

---@param path string
---@return table|nil
function M.read_json(path)
  return (M.load_json(path))
end

---@param path string
---@param data table
---@param mode integer|nil see M.write(见 M.write)
---@return boolean ok
---@return string|nil err
function M.write_json(path, data, mode)
  local ok, encoded = pcall(vim.json.encode, data)
  if not ok then
    -- Say why: a bare `false` here is how a map that could not be encoded
    -- disappeared silently, taking every highlight offset with it.
    -- (要说清原因：这里只回一个 `false`，正是一份编码不出来的 map 悄悄消失、连划线偏移一起
    --  丢掉的原因)
    return false, "could not encode JSON for " .. tostring(path) .. ": " .. tostring(encoded)
  end
  return M.write(path, encoded, mode)
end

---@param book_id string|number
---@return table|nil
function M.read_meta(book_id)
  return M.read_json(M.book_file(book_id, "meta.json"))
end

---@param book_id string|number
---@param meta table
---@return boolean ok
---@return string|nil err
function M.write_meta(book_id, meta)
  return M.write_json(M.book_file(book_id, "meta.json"), meta)
end

---@param book_id string|number
---@return table|nil
function M.read_catalog(book_id)
  return M.read_json(M.book_file(book_id, "catalog.json"))
end

---@param book_id string|number
---@param catalog table
---@return boolean ok
---@return string|nil err
function M.write_catalog(book_id, catalog)
  return M.write_json(M.book_file(book_id, "catalog.json"), catalog)
end

---@return table
function M.read_positions()
  return M.read_json(config.path("positions.json")) or {}
end

---@param book_id string|number
---@param position table
---@return boolean ok
---@return string|nil err
function M.write_position(book_id, position)
  local positions = M.read_positions()
  positions[tostring(book_id)] = position
  return M.write_json(config.path("positions.json"), positions)
end

---@param book_id string|number
---@return table|nil
function M.read_position(book_id)
  return M.read_positions()[tostring(book_id)]
end

---@return integer bytes
function M.book_cache_size(book_id)
  local dir = M.book_dir(book_id)
  if vim.fn.isdirectory(dir) == 0 then
    return 0
  end
  local total = 0
  for name, kind in vim.fs.dir(dir, { recurse = true }) do
    if kind == "file" then
      total = total + (vim.uv.fs_stat(dir .. "/" .. name) or {}).size
    end
  end
  return total
end

return M
