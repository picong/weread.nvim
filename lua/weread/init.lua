--[[
Public entry point: `require("weread").setup(opts)`.
(公开入口)
]]

local M = {}

local state = { setup = false }

---@param opts table|nil
function M.setup(opts)
  opts = opts or {}
  local config = require("weread.config")
  local resolved = config.setup(opts)
  config.ensure_dirs()

  require("weread.http").setup({
    jar = config.path("cookies.txt"),
    tmpdir = config.path("tmp"),
    proxy = resolved.proxy,
  })
  require("weread.log").setup({
    debug = opts.debug == true,
    path = config.path("weread.log"),
  })
  require("weread.auth").apply_cookies()
  require("weread.progress").setup()
  M.define_highlights()

  state.setup = true
  return M
end

---Highlight groups used by annotation markers. `default = true` keeps any
---user override intact.
---(划线标记使用的高亮组；default = true 保证用户自定义不会被覆盖)
function M.define_highlights()
  vim.api.nvim_set_hl(0, "WereadMineHighlight", { link = "DiagnosticInfo", default = true })
  vim.api.nvim_set_hl(0, "WereadPopularHighlight", { link = "Comment", default = true })
end

---@return boolean
function M.is_setup()
  return state.setup
end

---Run setup with defaults when the user never called it.
---(用户没显式 setup 时用默认配置兜底)
function M.ensure_setup()
  if not state.setup then
    M.setup({})
  end
end

function M.login(opts)
  M.ensure_setup()
  require("weread.auth").login(opts)
end

function M.logout()
  M.ensure_setup()
  require("weread.auth").logout()
end

return M
