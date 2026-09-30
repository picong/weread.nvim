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
a half-written chapter behind.
(写入走临时文件 + rename，避免中断留下半个章节)
]]

local config = require("weread.config")

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

---Atomically write a file.
---(原子写入)
---@param path string
---@param data string
---@return boolean ok
---@return string|nil err
function M.write(path, data)
  vim.fn.mkdir(vim.fs.dirname(path), "p")
  local tmp = path .. ".part"
  local file, open_err = io.open(tmp, "wb")
  if not file then
    return false, "could not open " .. tmp .. ": " .. tostring(open_err)
  end
  file:write(data)
  file:close()
  local ok, err = vim.uv.fs_rename(tmp, path)
  if not ok then
    os.remove(tmp)
    return false, tostring(err)
  end
  return true, nil
end

---@param path string
---@param data string
---@return boolean ok
---@return string|nil err
function M.append(path, data)
  vim.fn.mkdir(vim.fs.dirname(path), "p")
  local file = io.open(path, "ab")
  if not file then
    return false, "could not append to " .. path
  end
  file:write(data)
  file:close()
  return true, nil
end

---@param path string
---@return table|nil
function M.read_json(path)
  local text = M.read(path)
  if not text or text == "" then
    return nil
  end
  local ok, data = pcall(vim.json.decode, text)
  if not ok then
    return nil
  end
  return data
end

---@param path string
---@param data table
---@return boolean
function M.write_json(path, data)
  local ok, encoded = pcall(vim.json.encode, data)
  if not ok then
    return false
  end
  return (M.write(path, encoded))
end

---@param book_id string|number
---@return table|nil
function M.read_meta(book_id)
  return M.read_json(M.book_file(book_id, "meta.json"))
end

---@param book_id string|number
---@param meta table
function M.write_meta(book_id, meta)
  M.write_json(M.book_file(book_id, "meta.json"), meta)
end

---@param book_id string|number
---@return table|nil
function M.read_catalog(book_id)
  return M.read_json(M.book_file(book_id, "catalog.json"))
end

---@param book_id string|number
---@param catalog table
function M.write_catalog(book_id, catalog)
  M.write_json(M.book_file(book_id, "catalog.json"), catalog)
end

---@return table
function M.read_positions()
  return M.read_json(config.path("positions.json")) or {}
end

---@param book_id string|number
---@param position table
function M.write_position(book_id, position)
  local positions = M.read_positions()
  positions[tostring(book_id)] = position
  M.write_json(config.path("positions.json"), positions)
end

---@param book_id string|number
---@return table|nil
function M.read_position(book_id)
  return M.read_positions()[tostring(book_id)]
end

---Delete everything cached for a book.
---(清除某本书的全部缓存)
---@param book_id string|number
---@return boolean
function M.clear_book(book_id)
  local dir = M.book_dir(book_id)
  if vim.fn.isdirectory(dir) == 0 then
    return true
  end
  local ok = vim.fn.delete(dir, "rf") == 0
  return ok
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
