--[[
Tiny CSS reader for the book stylesheet WeRead ships alongside the chapters.

Why this exists: emphasis in a book is often not `<b>` but a class the
stylesheet styles (`<span class="calibre3">` with `.calibre3{font-weight:700}`)
or an inline `style=` attribute. Without reading the CSS those spans lose their
styling entirely, which is what made bold text show up as plain text.
(为什么要它：书里的强调往往不是 `<b>`，而是由样式表定义的类
 （`<span class="calibre3">` + `.calibre3{font-weight:700}`）或行内 `style=`。
 不读 CSS 就会把这类 span 的样式整个丢掉——加粗文字因此显示成普通文字)

Deliberately narrow: only the inline-level properties that can be represented in
a terminal are extracted, and everything else is ignored.
(刻意做窄：只提取终端能表达的那几个行内属性，其余一律忽略)
]]

local M = {}

---@class weread.css.Style
---@field bold? boolean
---@field italic? boolean
---@field underline? boolean
---@field strike? boolean
---@field mark? boolean

local WEIGHT_BOLD = { bold = true, bolder = true, ["600"] = true, ["700"] = true, ["800"] = true, ["900"] = true }

---Names that imply styling even without a stylesheet, which covers books whose
---classes are self documenting (`bold`, `italic`, `fw-bold`, `u`, ...).
---(即使没有样式表也能从类名推断，覆盖那些类名自解释的书籍)
local NAME_HINTS = {
  bold = "bold",
  strong = "bold",
  heavy = "bold",
  italic = "italic",
  oblique = "italic",
  emph = "italic",
  underline = "underline",
  underlined = "underline",
  strike = "strike",
  strikethrough = "strike",
  delete = "strike",
  mark = "mark",
  highlight = "mark",
}

---@param declarations string
---@return weread.css.Style
function M.from_declarations(declarations)
  local style = {}
  for property, value in tostring(declarations or ""):gmatch("([%w%-]+)%s*:%s*([^;]+)") do
    property = property:lower():gsub("^%s+", ""):gsub("%s+$", "")
    value = value:lower():gsub("%s+$", "")

    if property == "font-weight" then
      if WEIGHT_BOLD[value] then
        style.bold = true
      end
    elseif property == "font-style" then
      if value:find("italic", 1, true) or value:find("oblique", 1, true) then
        style.italic = true
      end
    elseif property == "text-decoration" or property == "text-decoration-line" then
      if value:find("underline", 1, true) then
        style.underline = true
      end
      if value:find("line-through", 1, true) then
        style.strike = true
      end
    elseif property == "background-color" or property == "background" then
      -- `transparent`, `none`, and fully transparent rgba() colours all mean
      -- "no highlight"; anything else paints a background.
      -- (transparent、none 以及 alpha 为 0 的 rgba 都表示没有高亮，其余都算有底色)
      local significant = value ~= "" and value ~= "transparent" and value ~= "none"
      local rgba = value:match("^rgba%b()")
      local alpha = rgba and tonumber(rgba:match("([%d%.]+)%s*%)$"))
      if significant and alpha ~= 0 then
        style.mark = true
      end
    end
  end
  return style
end

---Merge two styles; the second wins.
---(合并两个样式，后者优先)
---@param base weread.css.Style|nil
---@param extra weread.css.Style|nil
---@return weread.css.Style
function M.merge(base, extra)
  local merged = {}
  for _, source in ipairs({ base or {}, extra or {} }) do
    for key, value in pairs(source) do
      if value then
        merged[key] = true
      end
    end
  end
  return merged
end

---@param style weread.css.Style|nil
---@return boolean
function M.is_empty(style)
  return style == nil or next(style) == nil
end

---Guess styling from a class name.
---(从类名猜测样式)
---@param class string
---@return weread.css.Style
function M.from_class_name(class)
  local style = {}
  for token in tostring(class or ""):lower():gmatch("[%w_%-]+") do
    local hint = NAME_HINTS[token]
    if not hint then
      -- also match `fw-bold`, `text-italic`, ... but not `bolder-texture`
      -- (也匹配 fw-bold / text-italic 这类写法)
      for name, kind in pairs(NAME_HINTS) do
        if token == ("text-%s"):format(name) or token == ("fw-%s"):format(name) then
          hint = kind
          break
        end
      end
    end
    if hint then
      style[hint] = true
    end
  end
  return style
end

---Strip CSS comments without touching the surrounding text.
---(去掉 CSS 注释)
---@param css string
---@return string
local function strip_comments(css)
  return (css:gsub("/%*.-%*/", ""))
end

---Parse a stylesheet into a selector -> style map.
---(把样式表解析成 选择器 → 样式 的映射)

---Keys are the *rightmost* compound selector, which is the element the
---declarations actually apply to:
---(键取**最右复合选择器**，也就是声明真正作用的那个元素：)
---
---    `.bold`                  -> ".bold"      (any tag)
---    `h1.title { }`           -> "h1.title"   (only an h1)
---    `.chapter h1.title { }`  -> "h1.title"   (still only the h1)
---    `p { }`                  -> skipped      (no class, nothing to match)
---
---Attributing a descendant rule to its first class was a real bug: a
---`.chapter h1.title { font-weight: bold }` rule bolded the entire chapter.
---(把后代规则归给第一个类是真的踩过坑的 bug：一条
--- `.chapter h1.title { font-weight: bold }` 会把整章加粗)
---@param css string
---@return table<string, weread.css.Style>
function M.parse(css)
  local selectors_map = {}
  if type(css) ~= "string" or css == "" then
    return selectors_map
  end

  for selector_list, block in strip_comments(css):gmatch("([^{}]+){([^{}]*)}") do
    local style = M.from_declarations(block)
    if not M.is_empty(style) then
      for selector in selector_list:gmatch("[^,]+") do
        -- the rightmost compound: everything after the last combinator
        local compound = selector:match("([^%s>+~]+)%s*$")
        if compound then
          local tag = compound:match("^([%a][%w%-]*)")
          local matched_class = false
          for class in compound:gmatch("%.([%w_%-]+)") do
            matched_class = true
            local key = tag and (tag .. "." .. class) or ("." .. class)
            selectors_map[key] = M.merge(selectors_map[key], style)
          end
          -- a bare tag selector says nothing about emphasis worth trusting
          -- (裸标签选择器不携带可信的强调信息)
          if not matched_class then
            -- nothing to do(无需处理)
          end
        end
      end
    end
  end
  return selectors_map
end

---Full style for one element: class list from the stylesheet plus any inline
---declarations, with a name based fallback for classes the stylesheet does not
---mention (or when there is no stylesheet at all).
---(单个元素的完整样式：样式表里的类 + 行内声明；样式表没提到的类（或压根没有样式表
--- 时）用类名兜底)
---Merge two parsed maps; the second wins for the same selector.
---(合并两张解析后的映射；同一选择器以第二张为准)
---@param base table<string, weread.css.Style>|nil
---@param extra table<string, weread.css.Style>|nil
---@return table<string, weread.css.Style>
function M.merge_maps(base, extra)
  local merged = {}
  for key, style in pairs(base or {}) do
    merged[key] = style
  end
  for key, style in pairs(extra or {}) do
    merged[key] = M.merge(merged[key], style)
  end
  return merged
end

---@param class string|nil space separated class attribute
---@param style_attr string|nil inline style attribute
---@param classes table<string, weread.css.Style>|nil parsed stylesheet
---@param tag string|nil element name, for tag qualified rules like `h1.title`
---@return weread.css.Style
function M.resolve(class, style_attr, classes, tag)
  local style = {}
  tag = tag and tag:lower()
  for name in tostring(class or ""):gmatch("[%w_%-]+") do
    local from_sheet = classes and ((tag and classes[tag .. "." .. name]) or classes["." .. name])
    if not from_sheet and classes then
      from_sheet = classes["." .. name]
    end
    if from_sheet then
      style = M.merge(style, from_sheet)
    else
      style = M.merge(style, M.from_class_name(name))
    end
  end
  if style_attr and style_attr ~= "" then
    style = M.merge(style, M.from_declarations(style_attr))
  end
  return style
end

return M
