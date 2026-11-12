--[[
Small key/value store for choices the user makes at runtime (reading theme,
font) so they survive a restart without editing the config.
(存放用户在运行时做出的选择（阅读主题、字体），让它们在重启后仍然生效，而不必改配置)

The file is read once and kept in memory; `set` writes through. Nothing watches
the file, so an edit made behind the plugin's back shows up after a restart.
The memory copy is tied to the path it was read from, so pointing the data
directory somewhere else (tests do) starts from that directory's file.
(文件只读一次、之后留在内存里；set 写穿到磁盘。不监听文件变化，绕过插件手改文件要重启才生效。
 内存副本与读取它的路径绑定，因此把数据目录指向别处（测试会这么做）会从那里的文件重新开始)
]]

local M = {}

local memory = { path = nil, data = nil }

---@return string
local function path()
  return require("weread.config").path("preferences.json")
end

---The cached table for the current data directory, loading it on first use.
---A corrupt file is moved aside by cache.read_json and treated as empty.
---(当前数据目录对应的缓存表，首次使用时加载；损坏的文件会被 cache.read_json 改名保存，并按空处理)
---@return table
local function current()
  local file = path()
  if memory.data == nil or memory.path ~= file then
    memory.path = file
    memory.data = require("weread.cache").read_json(file) or {}
  end
  return memory.data
end

---Forget the in-memory copy so the next call reads the file again. For tests.
---(丢弃内存副本，下次调用重新读文件；供测试使用)
function M._reset()
  memory.path = nil
  memory.data = nil
end

---@return table copy, so callers cannot edit the cache by accident(返回副本，调用方改不到缓存)
function M.all()
  return vim.deepcopy(current())
end

---@param key string
---@return any
function M.get(key)
  return vim.deepcopy(current()[key])
end

---@param key string
---@param value any nil removes the key(nil 表示删除该键)
---@return boolean ok
---@return string|nil err
function M.set(key, value)
  local prefs = current()
  prefs[key] = value
  return require("weread.cache").write_json(path(), prefs)
end

function M.clear()
  local file = path()
  if vim.fn.filereadable(file) == 1 then
    vim.uv.fs_unlink(file)
  end
  M._reset()
end

return M
