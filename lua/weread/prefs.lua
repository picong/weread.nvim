--[[
Small key/value store for choices the user makes at runtime (reading theme,
font) so they survive a restart without editing the config.
(存放用户在运行时做出的选择（阅读主题、字体），让它们在重启后仍然生效，而不必改配置)
]]

local M = {}

---@return string
local function path()
  return require("weread.config").path("preferences.json")
end

---@return table
function M.all()
  return require("weread.cache").read_json(path()) or {}
end

---@param key string
---@return any
function M.get(key)
  return M.all()[key]
end

---@param key string
---@param value any
function M.set(key, value)
  local prefs = M.all()
  prefs[key] = value
  require("weread.cache").write_json(path(), prefs)
end

function M.clear()
  local file = path()
  if vim.fn.filereadable(file) == 1 then
    vim.uv.fs_unlink(file)
  end
end

return M
