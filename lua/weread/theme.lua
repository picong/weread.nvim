--[[
Reading themes: make the chapter window look like a page of the WeRead app
instead of like an editor.
(阅读主题：让章节窗口看起来像微信读书的一页，而不是一个编辑器)

The app's look comes mostly from its paper background, its muted ink colour and
its colour for headings and quotes. None of that needs to leak into the rest of
the editor, so every palette is applied **per window** through `winhighlight`:
the chapter window gets the paper colours, your dashboard keeps your
colorscheme.
(App 的观感主要来自纸色底、柔和的墨色，以及标题与引用的颜色。这些都不必污染编辑器的
 其它部分，因此每套配色都通过 `winhighlight` **只作用于窗口**：章节窗口用纸色，
 其它窗口仍是你原来的配色)
]]

local M = {}

---Palettes, hand tuned to sit close to the app's own themes.
---(配色表，手调到接近 App 自带的几套主题)
M.palettes = {
  ---The app's default paper theme.
  ---(App 默认的纸色主题)
  paper = {
    bg = "#f6f1e4",
    fg = "#3c3733",
    muted = "#8a8071",
    accent = "#a0522d",
    mark = "#f0e3c2",
    link = "#7a6a4f",
  },
  ---A little warmer, easier on the eyes at night with the lights on.
  ---(更暖一点，开着灯读的夜里更舒服)
  sepia = {
    bg = "#efe3cd",
    fg = "#43382c",
    muted = "#8a7355",
    accent = "#8b4513",
    mark = "#e3d0a8",
    link = "#7a5c34",
  },
  ---Plain light: no paper tint, for people who dislike warm backgrounds.
  ---(素白：不加纸色，给不喜欢暖底的人)
  light = {
    bg = "#fbfbfb",
    fg = "#2f2f2f",
    muted = "#8a8a8a",
    accent = "#2f6f9f",
    mark = "#eef3d8",
    link = "#2f6f9f",
  },
  ---Night reading, low contrast on purpose.
  ---(夜间阅读，刻意压低对比度)
  night = {
    bg = "#1c1b19",
    fg = "#c8c3b8",
    muted = "#7c766a",
    accent = "#d0a878",
    mark = "#3a352a",
    link = "#b5a184",
  },
}

M.names = { "paper", "sepia", "light", "night" }

---@param name string|nil
---@return string
function M.normalize(name)
  if type(name) ~= "string" then
    return "paper"
  end
  local lowered = name:lower()
  if lowered == "plain" or lowered == "none" then
    return "none"
  end
  for _, candidate in ipairs(M.names) do
    if candidate == lowered then
      return candidate
    end
  end
  return "paper"
end

---The heading group drawn on heading lines by weread.inline.
---(由 weread.inline 画在标题行上的标题组)
---@param name string
function M.define_heading(name)
  if name == "none" then
    -- No palette: stay close to the colorscheme, minus any background.
    -- (不套配色：贴近配色方案，但去掉背景)
    local title = vim.api.nvim_get_hl(0, { name = "Title" })
    vim.api.nvim_set_hl(0, "WereadHeading", { fg = title.fg, bold = true })
    return
  end
  local palette = M.palettes[name]
  if palette then
    vim.api.nvim_set_hl(0, "WereadHeading", { fg = palette.fg, bg = palette.bg, bold = true })
  end
end

---Define the highlight groups a palette needs. Idempotent, so switching themes
---at runtime just rewrites them.
---(定义一套配色所需的高亮组。幂等，运行时切换主题就是重写它们)
---@param name string
function M.define(name)
  local palette = M.palettes[name]
  if not palette then
    return
  end
  local set = vim.api.nvim_set_hl
  set(0, "WereadPaperNormal", { fg = palette.fg, bg = palette.bg })
  set(0, "WereadPaperWinBar", { fg = palette.muted, bg = palette.bg, bold = false })
  set(0, "WereadPaperCursorLine", { bg = palette.mark })
  set(0, "WereadPaperMark", { fg = palette.fg, bg = palette.mark })
  set(0, "WereadPaperLink", { fg = palette.link, underline = true })
  set(0, "WereadPaperHeading", { fg = palette.accent, bold = true })
  set(0, "WereadPaperQuote", { fg = palette.muted, italic = true })
  set(0, "WereadPaperStrike", { fg = palette.muted, strikethrough = true })
  set(0, "WereadPaperSuperscript", { fg = palette.muted })

  -- Markdown decorations must not punch a coloured hole in the page. These are
  -- what other plugins paint their own headings, fences and tables with, and
  -- they all get the page background back.
  -- (markdown 装饰不能在纸页上打出彩色空洞。其它插件用它画标题、代码块、表格，
  --  这里统一把背景换回纸色)
  set(0, "WereadPaperHeading", { fg = palette.fg, bg = palette.bg, bold = true })
  set(0, "WereadPaperMuted", { fg = palette.muted, bg = palette.bg })
  set(0, "WereadPaperCode", { fg = palette.muted, bg = palette.bg })
  set(0, "WereadPaperLinkBg", { fg = palette.link, bg = palette.bg, underline = true })
  set(0, "WereadPaperStrong", { fg = palette.fg, bg = palette.bg, bold = true })
  set(0, "WereadPaperItalic", { fg = palette.fg, bg = palette.bg, italic = true })
  M.define_heading(name)
end

---Groups that colour markdown syntax, from either a renderer plugin or the
---treesitter queries themselves.
---(给 markdown 语法上色的高亮组，可能来自渲染插件，也可能来自 treesitter 查询本身)
---
---Both matter: the visible band behind a heading came from the *colorscheme's*
---`@markup.heading.1.markdown` (which ships a background), and render-markdown
---adds its own `RenderMarkdownH*Bg` on top.
---(两者都要管：标题行那条色带来自**配色方案**的 `@markup.heading.1.markdown`
---（自带背景色），render-markdown 又在上面叠了自己的 `RenderMarkdownH*Bg`)
-- patterns are matched against the lowercased group name, so they are lowercase
-- (模式针对小写化的组名匹配，因此这里全部小写)
local SUBSTITUTIONS = {
  { match = "^@markup%.heading", group = "WereadPaperHeading" },
  { match = "^rendermarkdownh%d", group = "WereadPaperHeading" },
  { match = "heading", group = "WereadPaperHeading" },
  { match = "strong", group = "WereadPaperStrong" },
  { match = "bold", group = "WereadPaperStrong" },
  { match = "italic", group = "WereadPaperItalic" },
  { match = "strikethrough", group = "WereadPaperStrike" },
  { match = "quote", group = "WereadPaperQuote" },
  { match = "raw", group = "WereadPaperCode" },
  { match = "^rendermarkdowncode", group = "WereadPaperCode" },
  { match = "link", group = "WereadPaperLinkBg" },
  { match = "list", group = "WereadPaperMuted" },
}

---Highlight groups that other markdown renderers define for themselves.
---(其它 markdown 渲染器自定义的高亮组)
---Enumerated at apply time rather than hardcoded: the set grows with plugin
---releases (`H1`..`H7`, `Bg` variants, `Code*`, `Quote1..8`, ...).
---(在应用时枚举而不是写死：这套组会随插件版本增长（H1..H7、Bg 变体、Code*、
--- Quote1..8……）)
---@return string[]
function M.foreign_groups()
  local groups = {}
  local ok, all = pcall(vim.api.nvim_get_hl, 0, {})
  if not ok or type(all) ~= "table" then
    return groups
  end
  for name in pairs(all) do
    if name:find("^RenderMarkdown") or (name:find("^@markup%.") and name:find("%.markdown$")) then
      groups[#groups + 1] = name
    end
  end
  table.sort(groups)
  return groups
end

---Which paper group should stand in for a foreign one.
---(某个外部组应当换成哪个纸色组)
---@param group string
---@return string
function M.substitute(group)
  local lowered = group:lower()
  for _, rule in ipairs(SUBSTITUTIONS) do
    if lowered:find(rule.match) then
      return rule.group
    end
  end
  if lowered:find("info") or lowered:find("hint") or lowered:find("success") then
    return "WereadPaperLinkBg"
  end
  return "WereadPaperMuted"
end

---`winhighlight` value that repaints a window in the given palette.
---(把某个窗口刷成指定配色的 winhighlight 值)
---@param name string
---@return string
function M.winhighlight(name)
  if name == "none" then
    return ""
  end
  M.define(name)

  local pairs_list = {
    "Normal:WereadPaperNormal",
    "EndOfBuffer:WereadPaperNormal",
    "WinBar:WereadPaperWinBar",
    "WinBarNC:WereadPaperWinBar",
    "CursorLine:WereadPaperCursorLine",
    "WereadMark:WereadPaperMark",
    "WereadCode:WereadPaperLink",
    "WereadSuperscript:WereadPaperSuperscript",
    "WereadSubscript:WereadPaperSuperscript",
    "WereadSmall:WereadPaperQuote",
    "Strikethrough:WereadPaperStrike",
  }

  -- Third party markdown decorations: same page background, palette foreground.
  -- (第三方 markdown 装饰：同样的纸色底，前景取自配色)
  for _, group in ipairs(M.foreign_groups()) do
    pairs_list[#pairs_list + 1] = group .. ":" .. M.substitute(group)
  end

  return table.concat(pairs_list, ",")
end

---Current theme name from the config.
---(从配置取当前主题名)
---@return string
function M.current()
  return M.normalize(require("weread.config").get().theme)
end

---Apply a theme to a reading window.
---(把主题应用到阅读窗口)
---@param win integer
---@param name string|nil
function M.apply(win, name)
  if not vim.api.nvim_win_is_valid(win) then
    return
  end
  name = M.normalize(name or M.current())
  vim.wo[win].winhighlight = M.winhighlight(name)
end

---Apply to every open chapter window, e.g. after switching themes.
---(应用到所有已打开的章节窗口，例如切换主题之后)
---@param name string|nil
function M.apply_all(name)
  local reader = require("weread.reader")
  for _, win in ipairs(vim.api.nvim_list_wins()) do
    local buf = vim.api.nvim_win_get_buf(win)
    if reader.buffer_info(buf) then
      M.apply(win, name)
    end
  end
end

---Interactive switch, also remembered for the next session.
---(交互式切换，并记住以便下次启动沿用)
---@param name string|nil
function M.set(name)
  name = M.normalize(name)
  local config = require("weread.config")
  local opts = config.get()
  opts.theme = name
  require("weread.prefs").set("theme", name)
  M.apply_all(name)
  vim.notify("weread: 阅读主题 → " .. (name == "none" and "跟随配色方案" or name))
end

---@return table[] items for a picker(选择器条目)
function M.items()
  local items = {}
  for _, name in ipairs(M.names) do
    local palette = M.palettes[name]
    items[#items + 1] = {
      text = string.format("%-6s 底 %s 字 %s", name, palette.bg, palette.fg),
      name = name,
    }
  end
  items[#items + 1] = { text = "none   跟随当前配色方案（不改窗口）", name = "none" }
  return items
end

function M.picker()
  local current = M.current()
  local items = M.items()
  for _, item in ipairs(items) do
    item.text = (item.name == current and "▶ " or "  ") .. item.text
  end
  require("weread.ui").select({
    title = "微信读书 · 阅读主题",
    items = items,
    on_choice = function(item)
      M.set(item.name)
    end,
  })
end

return M
