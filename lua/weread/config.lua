--[[
Plugin configuration: defaults, validation and the on-disk layout.
(插件配置：默认值、校验与磁盘布局)
]]

local M = {}

M.defaults = {
  ---Root directory for credentials, caches and reading positions.
  ---(凭据、缓存与阅读位置的根目录)
  ---@type string|nil
  data_dir = nil,

  ---Rendered chapter width in characters. 0 keeps the window width.
  ---(正文渲染宽度，0 表示跟随窗口)
  ---@type integer
  text_width = 78,

  ---Upload the local position/reading time to WeRead every N seconds. 0 disables it.
  ---(每 N 秒把本地进度与阅读时长回传微信读书，0 表示关闭)
  ---@type integer
  sync_interval = 60,

  ---Upload progress when leaving a chapter buffer.
  ---(离开章节 buffer 时回传进度)
  ---@type boolean
  sync_on_leave = true,

  ---Inline image rendering limits, in terminal cells.
  ---(插图内联渲染上限，单位为终端单元格)
  ---@type table
  image = {
    max_width = 60,
    max_height = 30,
  },

  ---HTTP proxy mode: nil inherits the environment, "direct" bypasses every proxy.
  ---Set it to "direct" when the machine's proxy would route domestic traffic abroad.
  ---(代理模式：nil 沿用环境变量，"direct" 强制直连；当机器的代理会把国内流量
  --- 绕到境外时，建议设为 "direct")
  ---@type string|nil
  proxy = nil,

  ---Service root. Only changed by tests, which point it at a local mock server.
  ---(服务根地址；仅测试会改成本地 mock 服务器)
  ---@type string
  base_url = "https://weread.qq.com",

  ---Register the default buffer-local keymaps in chapter buffers.
  ---(在章节 buffer 注册默认快捷键)
  ---@type boolean
  keymaps = true,
}

local state = {
  opts = vim.deepcopy(M.defaults),
  configured = false,
}

---@param opts table|nil
function M.setup(opts)
  state.opts = vim.tbl_deep_extend("force", vim.deepcopy(M.defaults), opts or {})
  state.configured = true
  return state.opts
end

---@return table
function M.get()
  return state.opts
end

---@return boolean
function M.is_configured()
  return state.configured
end

---@return string
function M.data_dir()
  return state.opts.data_dir or (vim.fn.stdpath("data") .. "/weread")
end

---@param ... string
---@return string
function M.path(...)
  return table.concat({ M.data_dir(), ... }, "/")
end

---Create the directory tree the plugin writes into.
---(创建插件写入所需的目录树)
---@return string data_dir
function M.ensure_dirs()
  local root = M.data_dir()
  for _, dir in ipairs({ root, root .. "/books", root .. "/tmp" }) do
    vim.fn.mkdir(dir, "p")
  end
  return root
end

return M
