--[[
Inline styling for chapter buffers.

Markdown punctuation stays in the cached file — that is what makes it greppable
and portable — but nobody wants to read `**加粗**`. This module turns the style
spans recorded by `weread.xhtml.convert` into extmarks: the markers get
concealed and the content gets the real attribute (bold, italic, underline,
strikethrough, highlight), so a bold phrase simply looks bold.
(章节 buffer 的行内样式：markdown 标点留在缓存文件里（便于 grep 与移植），但没人想
 读 `**加粗**`。本模块把 xhtml.convert 记录的样式区间变成 extmark：隐藏标记，给内容
 加上真实属性（粗体/斜体/下划线/删除线/高亮），于是加粗的句子就是加粗的样子)

Note that render-markdown.nvim deliberately does not handle emphasis (its inline
handler covers code spans, links, images and ==highlight== only), so there is no
double work happening here.
(注意 render-markdown.nvim 有意不处理强调——它的行内 handler 只管 code span、链接、
 图片与 ==高亮==——所以这里不存在重复处理)
]]

local M = {}

local NAMESPACE = "weread.inline"

---Style kind -> highlight group.
---(样式种类 → 高亮组)
local GROUPS = {
  bold = "Bold",
  italic = "Italic",
  underline = "Underline",
  strike = "Strikethrough",
  mark = "WereadMark",
  sup = "WereadSuperscript",
  sub = "WereadSubscript",
  small = "WereadSmall",
  code = "WereadCode",
}

---@param kind string
---@return string
function M.group_for(kind)
  return GROUPS[kind] or "Normal"
end

---@param buf integer
function M.clear(buf)
  if not vim.api.nvim_buf_is_valid(buf) then
    return
  end
  vim.api.nvim_buf_clear_namespace(buf, vim.api.nvim_create_namespace(NAMESPACE), 0, -1)
end

---Draw the style spans on a chapter buffer.
---(在章节 buffer 上绘制样式区间)
---Paint heading lines in the reading colours and hide their `#` marks.
---(用阅读配色绘制标题行，并隐藏 `#` 标记)
---
---Doing it here instead of trusting the syntax highlighter is deliberate: a
---colorscheme gives `@markup.heading.*` its own foreground *and* background, and
---that band is exactly what breaks the paper look. An extmark with a higher
---priority wins over the syntax highlight.
---(在这里做、而不是信任语法高亮，是有意的：配色方案会给 `@markup.heading.*` 配前景
--- **和背景**，那条色带正是破坏纸页观感的元凶。优先级更高的 extmark 会压过语法高亮)
---@param buf integer
---@param headings table[]|nil entries { line, level }
---@return integer drawn
function M.render_headings(buf, headings)
  if not vim.api.nvim_buf_is_valid(buf) or type(headings) ~= "table" then
    return 0
  end
  local namespace = vim.api.nvim_create_namespace(NAMESPACE)
  local line_count = vim.api.nvim_buf_line_count(buf)
  local drawn = 0

  for _, heading in ipairs(headings) do
    local line = tonumber(heading.line)
    local level = tonumber(heading.level) or 1
    if line and line >= 0 and line < line_count then
      local text = vim.api.nvim_buf_get_lines(buf, line, line + 1, false)[1] or ""
      local ok = pcall(vim.api.nvim_buf_set_extmark, buf, namespace, line, 0, {
        end_col = #text,
        hl_group = "WereadHeading",
        hl_mode = "replace",
        priority = 250,
      })
      if ok then
        drawn = drawn + 1
      end
      -- hide the `#` marks: the app shows a heading, not a hash
      -- (隐藏 `#` 标记：App 显示的是标题，不是井号)
      local marks = 0
      while text:sub(marks + 1, marks + 1) == "#" and marks < 12 do
        marks = marks + 1
      end
      if marks > 0 then
        pcall(vim.api.nvim_buf_set_extmark, buf, namespace, line, 0, {
          end_col = math.min(#text, marks + 1),
          conceal = "",
          priority = 260,
        })
      end
    end
  end
  return drawn
end

---@param buf integer
---@param styles table[]|nil entries { line, col_from, col_to, kind, markers }
---@param headings table[]|nil entries { line, level }
---@return integer drawn
function M.attach(buf, styles, headings)
  M.clear(buf)
  if not vim.api.nvim_buf_is_valid(buf) then
    return 0
  end
  M.render_headings(buf, headings)
  if type(styles) ~= "table" then
    return 0
  end

  local namespace = vim.api.nvim_create_namespace(NAMESPACE)
  local line_count = vim.api.nvim_buf_line_count(buf)
  local drawn = 0

  for _, style in ipairs(styles) do
    local line = tonumber(style.line)
    local from = tonumber(style.col_from)
    local to = tonumber(style.col_to)
    local kind = style.kind
    local markers = tonumber(style.markers) or 0

    if line and from and to and to > from and line >= 0 and line < line_count then
      -- the attribute itself
      local ok = pcall(vim.api.nvim_buf_set_extmark, buf, namespace, line, from, {
        end_col = to,
        hl_group = M.group_for(kind),
        hl_mode = "combine",
        priority = 200,
      })
      if ok then
        drawn = drawn + 1
      end

      -- and hide the markdown markers around it
      if markers > 0 then
        pcall(vim.api.nvim_buf_set_extmark, buf, namespace, line, math.max(0, from - markers), {
          end_col = from,
          conceal = "",
        })
        pcall(vim.api.nvim_buf_set_extmark, buf, namespace, line, to, {
          end_col = to + markers,
          conceal = "",
        })
      end
    end
  end

  return drawn
end

---Read the style spans recorded next to a chapter's offset map.
---(读取与章节 offset map 一起记录的样式区间)
---@param meta table|nil the parsed map.json
---@return table[]
function M.from_meta(meta)
  if type(meta) ~= "table" or type(meta.styles) ~= "table" then
    return {}
  end
  return meta.styles
end

return M
