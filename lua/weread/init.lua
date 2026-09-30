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
  -- A choice made at runtime (:WeReadTheme / :WeReadFont) wins over the config,
  -- because it was made later and more deliberately.
  -- (运行时做出的选择（:WeReadTheme / :WeReadFont）优先于配置：它更晚、也更明确)
  local prefs = require("weread.prefs")
  local remembered_theme = prefs.get("theme")
  if remembered_theme then
    resolved.theme = remembered_theme
  end

  require("weread.auth").apply_cookies()
  require("weread.progress").setup()
  M.define_highlights()
  require("weread.theme").define(require("weread.theme").normalize(resolved.theme))

  state.setup = true
  return M
end

---Highlight groups used by annotation markers. `default = true` keeps any
---user override intact.
---(划线标记使用的高亮组；default = true 保证用户自定义不会被覆盖)
function M.define_highlights()
  vim.api.nvim_set_hl(0, "WereadMineHighlight", { link = "DiagnosticInfo", default = true })
  vim.api.nvim_set_hl(0, "WereadPopularHighlight", { link = "Comment", default = true })
  -- inline styling: markdown cannot express these, so they are drawn
  -- (行内样式：markdown 表达不了，因此用绘制的方式呈现)
  vim.api.nvim_set_hl(0, "WereadMark", { link = "Search", default = true })
  vim.api.nvim_set_hl(0, "WereadSuperscript", { link = "Number", default = true })
  vim.api.nvim_set_hl(0, "WereadSubscript", { link = "Number", default = true })
  vim.api.nvim_set_hl(0, "WereadSmall", { link = "Comment", default = true })
  vim.api.nvim_set_hl(0, "WereadCode", { link = "Special", default = true })
  -- bold/italic/underline/strikethrough are built in, but make sure they carry
  -- an attribute even under a colorscheme that leaves them plain
  -- (粗斜体等下划线是内置组，但有些配色把它们留空，这里确保带上属性)
  vim.api.nvim_set_hl(0, "Bold", { bold = true, default = true })
  vim.api.nvim_set_hl(0, "Italic", { italic = true, default = true })
  vim.api.nvim_set_hl(0, "Underline", { underline = true, default = true })
  vim.api.nvim_set_hl(0, "Strikethrough", { strikethrough = true, default = true })
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
