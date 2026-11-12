--[[
Tiny logging helper. The WeRead content protocol is fragile and the failure
modes are silent (an empty response body, a wrong signature), so keeping a
file log of the exact requests and decoded lengths is worth the 60 lines.
(轻量日志：微信读书的正文协议很脆，失败还常常是静默的（空响应、签名错误），
 因此把请求与解码长度落一份文件日志很有价值)

Warnings and errors always reach the log file: they are the trail a user needs
after something went wrong, long after anyone thought to switch debug on. Debug
and info lines are written only with `require("weread").setup({ debug = true })`.
The file is created 0600 and rolled to `<name>.1` once it passes 1 MB.
(warn/error 始终写入日志文件：出问题之后用户需要的就是这条线索，而那时早已没人想起去开 debug。
 debug/info 仅在 setup({ debug = true }) 时写入。文件以 0600 创建，超过 1MB 时滚动成 `<name>.1`)
]]

local M = {}

local state = {
  enabled = false,
  path = nil,
  ring = {},
  ring_size = 200,
}

local LEVELS = { debug = 10, info = 20, warn = 30, error = 40 }

-- 0600 and the roll-over threshold. (0600 与滚动阈值)
local FILE_MODE = 384
local MAX_BYTES = 1024 * 1024

local current_level = LEVELS.info

---@param opts table|nil
function M.setup(opts)
  opts = opts or {}
  state.enabled = opts.debug == true
  state.path = opts.path
  state.size = nil
  current_level = state.enabled and LEVELS.debug or LEVELS.info
  if state.path then
    pcall(vim.fn.mkdir, vim.fs.dirname(state.path), "p")
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

---Roll the log over once it is too big: `<name>.1` replaces the previous roll.
---(日志过大时滚动：`<name>.1` 覆盖上一份旧日志)
---@param incoming integer bytes about to be appended(即将追加的字节数)
local function roll_if_needed(incoming)
  if not state.size then
    local stat = vim.uv.fs_stat(state.path)
    state.size = stat and stat.size or 0
  end
  if state.size + incoming > MAX_BYTES then
    vim.uv.fs_rename(state.path, state.path .. ".1")
    state.size = 0
  end
end

---Append one line to the file. Logging must never raise, so every failure
---(missing directory, full disk) is swallowed.
---(把一行追加到文件。日志绝不能抛错，因此缺目录、磁盘满之类的失败一律吞掉)
---@param line string
local function append(line)
  pcall(function()
    roll_if_needed(#line + 1)
    local fd = vim.uv.fs_open(state.path, "a", FILE_MODE)
    if not fd then
      return
    end
    local written = vim.uv.fs_write(fd, line .. "\n", -1)
    vim.uv.fs_close(fd)
    state.size = state.size + (written or 0)
  end)
end

local function write(level, message)
  local line = string.format("%s [%s] %s", os.date("%Y-%m-%d %H:%M:%S"), level:upper(), message)
  table.insert(state.ring, line)
  while #state.ring > state.ring_size do
    table.remove(state.ring, 1)
  end
  if not state.path then
    return
  end
  if state.enabled or LEVELS[level] >= LEVELS.warn then
    append(line)
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
