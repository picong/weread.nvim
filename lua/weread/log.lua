--[[
Tiny logging helper. The WeRead content protocol is fragile and the failure
modes are silent (an empty response body, a wrong signature), so keeping a
file log of the exact requests and decoded lengths is worth the 60 lines.
(轻量日志：微信读书的正文协议很脆，失败还常常是静默的（空响应、签名错误），
 因此把请求与解码长度落一份文件日志很有价值)

Disabled by default; enable with `require("weread").setup({ debug = true })`.
(默认关闭，用 setup({ debug = true }) 打开)
]]

local M = {}

local state = {
  enabled = false,
  path = nil,
  ring = {},
  ring_size = 200,
}

local LEVELS = { debug = 10, info = 20, warn = 30, error = 40 }

local current_level = LEVELS.info

---@param opts table|nil
function M.setup(opts)
  opts = opts or {}
  state.enabled = opts.debug == true
  state.path = opts.path
  current_level = state.enabled and LEVELS.debug or LEVELS.info
  if state.enabled and state.path then
    vim.fn.mkdir(vim.fs.dirname(state.path), "p")
  end
end

---@return boolean
function M.enabled()
  return state.enabled
end

---@return string
function M.path()
  return state.path or ""
end

local function write(level, message)
  local line = string.format("%s [%s] %s", os.date("%Y-%m-%d %H:%M:%S"), level:upper(), message)
  table.insert(state.ring, line)
  while #state.ring > state.ring_size do
    table.remove(state.ring, 1)
  end
  if not state.enabled then
    return
  end
  if state.path then
    local file = io.open(state.path, "a")
    if file then
      file:write(line, "\n")
      file:close()
    end
  end
end

local function make(level, name)
  return function(fmt, ...)
    if LEVELS[level] < current_level and level ~= "error" then
      return
    end
    local ok, message = pcall(string.format, fmt, ...)
    write(level, ok and message or tostring(fmt))
  end
end

M.debug = make("debug", "debug")
M.info = make("info", "info")
M.warn = make("warn", "warn")
M.error = make("error", "error")

---@param count integer|nil
---@return string[]
function M.tail(count)
  count = count or 50
  local out = {}
  local from = math.max(1, #state.ring - count + 1)
  for index = from, #state.ring do
    out[#out + 1] = state.ring[index]
  end
  return out
end

function M.clear()
  state.ring = {}
end

return M
