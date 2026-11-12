--[[
Public entry point: `require("weread").setup(opts)`.
(公开入口)
]]

local M = {}

local state = { setup = false, curl_warned = false }

---Every request goes through curl, so a missing binary breaks the whole plugin.
---Say so once, at setup, instead of at the first failed request.
---(所有请求都走 curl，缺失会让整个插件失效；在 setup 时说一次，而不是等到第一次请求失败)
local function warn_missing_curl()
  if state.curl_warned or vim.fn.executable("curl") == 1 then
    return
  end
  state.curl_warned = true
  vim.notify("weread: 找不到 curl，插件的所有网络请求都依赖它，请先安装 curl", vim.log.levels.WARN)
end

---@param opts table|nil
function M.setup(opts)
  local config = require("weread.config")
  local resolved = config.setup(opts)
  config.ensure_dirs()
  warn_missing_curl()

  require("weread.http").setup({
    jar = config.path("cookies.txt"),
    tmpdir = config.path("tmp"),
    proxy = resolved.proxy,
  })
  require("weread.log").setup({
    debug = resolved.debug == true,
    path = config.path("weread.log"),
  })
  -- A theme written in setup() wins; the one remembered from :WeReadTheme only
  -- fills in when the config says nothing. Otherwise a theme tried once months
  -- ago silently overrides the config forever.
  -- (setup() 里写的主题优先；:WeReadTheme 记住的主题只在配置没写时补位。否则很久以前
  --  试过一次的主题会永远悄悄压过配置)
  -- Custom palettes first: a remembered theme may be one of them, and one the
  -- config no longer lists is ignored rather than turning the page plain.
  -- (先注册自定义配色：记住的主题可能就是其中之一；配置里已经没有的那个被忽略，而不是让书页
  --  变回素色)
  local theme = require("weread.theme")
  theme.register(resolved.palettes)
  if not config.theme_pinned() then
    local remembered_theme = require("weread.prefs").get("theme")
    if remembered_theme and theme.known(remembered_theme) then
      resolved.theme = remembered_theme
    end
  end

  -- the same rule for the line length chosen with `+`/`-` or :WeReadWidth
  -- (用 `+`/`-` 或 :WeReadWidth 选的行宽，规则相同)
  if not config.pinned("layout.page_chars") and not config.pinned("layout.adaptive") then
    local remembered_width = tonumber(require("weread.prefs").get("page_chars"))
    if remembered_width then
      resolved.layout.page_chars = remembered_width
    end
  end

  require("weread.auth").apply_cookies()
  require("weread.progress").setup()
  M.define_highlights()
  require("weread.shell").define_highlights()
  theme.define(theme.normalize(resolved.theme))
  theme.watch_background()
  require("weread.milestone").setup()
  require("weread.zone").watch_idle()
  -- The reading font follows chapter buffers for the whole session. This only
  -- installs autocmds; nothing touches the terminal until a chapter is entered.
  -- (阅读字体在整个会话里跟着章节 buffer 走。这里只安装自动命令；进章节之前不碰终端)
  require("weread.font_session").setup()

  state.setup = true
  return M
end

---Highlight groups used by annotation markers. `default = true` keeps any
---user override intact.
---(划线标记使用的高亮组；default = true 保证用户自定义不会被覆盖)
function M.define_highlights()
  vim.api.nvim_set_hl(0, "WereadMineHighlight", { link = "DiagnosticInfo", default = true })
  vim.api.nvim_set_hl(0, "WereadPopularHighlight", { link = "Comment", default = true })
  -- popular highlights by heat: more readers, a stronger rule
  -- (热门划线按热度分档：划的人越多，线越重)
  vim.api.nvim_set_hl(0, "WereadPopularWarm", { undercurl = true, sp = "#c49a6c", default = true })
  vim.api.nvim_set_hl(0, "WereadPopularHot", { underline = true, bold = true, sp = "#d07a3c", default = true })
  -- inline styling: markdown cannot express these, so they are drawn
  -- (行内样式：markdown 表达不了，因此用绘制的方式呈现)
  vim.api.nvim_set_hl(0, "WereadMark", { link = "Search", default = true })
  vim.api.nvim_set_hl(0, "WereadSuperscript", { link = "Number", default = true })
  vim.api.nvim_set_hl(0, "WereadSubscript", { link = "Number", default = true })
  vim.api.nvim_set_hl(0, "WereadSmall", { link = "Comment", default = true })
  vim.api.nvim_set_hl(0, "WereadTranslation", { link = "Comment", default = true })
  vim.api.nvim_set_hl(0, "WereadCode", { link = "Special", default = true })
  -- a table's header row and its box rules (表格的表头行与边框线)
  vim.api.nvim_set_hl(0, "WereadTableHead", { bold = true, default = true })
  vim.api.nvim_set_hl(0, "WereadTableRule", { link = "NonText", default = true })
  -- 着重号 under CJK emphasis: only the rule, so the ink underneath shows
  -- (中文强调下的着重号：只有点线，下面的墨色照常显示)
  vim.api.nvim_set_hl(0, "WereadEmphasisDots", { underdotted = true, default = true })
  -- Padding that places a line on the page (centering, right alignment) and the
  -- margin the page is inset by; the reading palette overrides both per window.
  -- (把行摆到页面上的补白（居中、右对齐）以及页边距；阅读配色会按窗口覆盖它们)
  vim.api.nvim_set_hl(0, "WereadMargin", { link = "Normal", default = true })
  -- Drawn on heading lines by weread.inline; the theme overrides it with the
  -- page colours when a reading palette is active.
  -- (由 weread.inline 画在标题行上；启用阅读配色时主题会用纸页颜色覆盖它)
  vim.api.nvim_set_hl(0, "WereadHeading", { bold = true, default = true })
  -- bold/italic/underline/strikethrough are built in, but make sure they carry
  -- an attribute even under a colorscheme that leaves them plain
  -- (粗斜体等下划线是内置组，但有些配色把它们留空，这里确保带上属性)
  -- Inline emphasis groups. With a reading palette they are repainted in the
  -- page's ink; without one they are the built-ins, so `theme = "none"` looks
  -- exactly like the colorscheme.
  -- (行内强调组。有阅读配色时会被刷成纸页的墨色；没有时就等于内置组，因此
  --  `theme = "none"` 与配色方案完全一致)
  vim.api.nvim_set_hl(0, "WereadStrong", { link = "Bold", default = true })
  vim.api.nvim_set_hl(0, "WereadItalic", { link = "Italic", default = true })
  vim.api.nvim_set_hl(0, "WereadUnderline", { link = "Underline", default = true })
  vim.api.nvim_set_hl(0, "WereadStrike", { link = "Strikethrough", default = true })
  vim.api.nvim_set_hl(0, "Bold", { bold = true, default = true })
  vim.api.nvim_set_hl(0, "Italic", { italic = true, default = true })
  vim.api.nvim_set_hl(0, "Underline", { underline = true, default = true })
  vim.api.nvim_set_hl(0, "Strikethrough", { strikethrough = true, default = true })
  -- Defined here rather than through reader_lookup, which would load the whole
  -- rendering chain at setup. (直接在这里定义，经 reader_lookup 会在 setup 时拉起整条渲染链)
  vim.api.nvim_set_hl(0, "WereadLookupWord", { link = "Title", default = true })
  vim.api.nvim_set_hl(0, "WereadLookupPhonetic", { link = "Comment", default = true })
  vim.api.nvim_set_hl(0, "WereadLookupSource", { link = "Comment", default = true })
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
