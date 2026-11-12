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
---Block level properties. These carry *values* rather than flags, because the
---renderer needs the number, not only the fact that the property was set.
---(块级属性。这些带**值**而不是标志位，因为渲染器需要那个数字，而不只是「设置了」)
---@field align? string "left"|"center"|"right"|"justify"
---@field size? number relative font size, 1 = body text(相对字号，1 = 正文)
---@field color? string colour as written, normalized to lowercase(原样保留的颜色)
---@field indent? number text-indent in em(首行缩进的 em 值)
---@field padding_left? number
---@field padding_right? number

local WEIGHT_BOLD = { bold = true, bolder = true, ["600"] = true, ["700"] = true, ["800"] = true, ["900"] = true }

---Named sizes books use for footnotes, captions and quotes.
---(书里给小字（脚注、图注、引文）用的具名字号)
local NAMED_SMALL = { small = 0.8, smaller = 0.8, ["x-small"] = 0.8, ["xx-small"] = 0.8 }

---Class name fragments that imply block level layout even without a stylesheet.
---(没有样式表时也能从类名推断的块级排版，用于「类名自解释」的书)
local BLOCK_NAME_HINTS = {
  { pattern = "center", key = "align", value = "center" },
  { pattern = "centered", key = "align", value = "center" },
  { pattern = "text%-right", key = "align", value = "right" },
  { pattern = "footnote", key = "size", value = 0.8 },
  { pattern = "small", key = "size", value = 0.8 },
  { pattern = "caption", key = "size", value = 0.8 },
  -- `picture_figure_title` is the real WeRead name for a figure caption
  -- (picture_figure_title 是微信读书图注的真实类名)
  { pattern = "figure_title", key = "size", value = 0.8 },
}

---Values that mean "no colour" or a colour indistinguishable from ink.
---(表示「没有颜色」或者与墨色无异的颜色)
local NEUTRAL_COLORS = {
  transparent = true,
  inherit = true,
  initial = true,
  currentcolor = true,
  black = true,
  white = true,
  gray = true,
  grey = true,
  silver = true,
}

---Parse a CSS length into a relative number. `em`/`%` are the only units a book
---uses for indentation and relative font size; `px`/`pt` are dropped because
---they are meaningless without the base size.
---(把 CSS 长度解析成相对数值。书里表示缩进与相对字号的单位只有 em/%，px/pt 因为没有
--- 基数字号而被丢弃)
---@param value string|nil
---@return number|nil
local function relative_length(value)
  local text = tostring(value or ""):gsub("%s*!important%s*$", ""):gsub("^%s+", ""):gsub("%s+$", "")
  local percent = text:match("^(%-?%d*%.?%d+)%%$")
  if percent then
    return tonumber(percent) / 100
  end
  local em = text:match("^(%-?%d*%.?%d+)em$")
  if em then
    return tonumber(em)
  end
  local bare = text:match("^(%-?%d*%.?%d+)$")
  if bare then
    return tonumber(bare)
  end
  return nil
end

---Chroma of a colour: how far it is from grey. Anything below this is ink.
---(颜色的彩度：离灰有多远。低于这个值就当作墨色)
local CHROMA_THRESHOLD = 24

---@param value string|nil
---@return integer r, integer g, integer b
local function to_rgb(value)
  local text = tostring(value or ""):lower()
  local hex = text:match("^#(%x%x%x%x%x%x)$")
  if hex then
    return tonumber(hex:sub(1, 2), 16), tonumber(hex:sub(3, 4), 16), tonumber(hex:sub(5, 6), 16)
  end
  local short = text:match("^#(%x%x%x)$")
  if short then
    local r, g, b = short:sub(1, 1), short:sub(2, 2), short:sub(3, 3)
    return tonumber(r .. r, 16), tonumber(g .. g, 16), tonumber(b .. b, 16)
  end
  local r, g, b = text:match("^rgba?%(%s*(%d+)%s*,%s*(%d+)%s*,%s*(%d+)")
  if r then
    return tonumber(r), tonumber(g), tonumber(b)
  end
  return 0, 0, 0
end

---Is this colour far enough from grey to be worth drawing?
---(这个颜色离灰足够远、值得画出来吗？)
---
---A book paints section titles orange and body text near black; only the
---former is a signal. Treating `#000` and `#c36500` alike is what used to make
---every title look like ordinary text.
---(书里把节标题染成橙色、正文接近黑色，只有前者是有效信号。把 `#000` 和 `#c36500`
--- 一视同仁，正是标题看起来和正文毫无区别的原因)
---@param value string|nil
---@return boolean
function M.is_neutral_color(value)
  local text = tostring(value or ""):lower():gsub("^%s+", ""):gsub("%s+$", "")
  if text == "" or NEUTRAL_COLORS[text] then
    return true
  end
  if not text:find("#", 1, true) and not text:find("rgb", 1, true) then
    -- a named colour we did not list: assume it is a real colour
    -- (没列出来的具名颜色：当作真彩色)
    return false
  end
  local r, g, b = to_rgb(text)
  local high, low = math.max(r, g, b), math.min(r, g, b)
  return (high - low) < CHROMA_THRESHOLD
end

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
    elseif property == "text-align" then
      -- `justify` is what a book sets on its body text; only the two that can
      -- actually move text in a terminal are kept.
      -- (书里正文普遍是 justify；只有终端真能移动文本的两种值得保留)
      local align = value:gsub("%s*!important%s*$", "")
      if align == "center" or align == "right" or align == "left" or align == "justify" then
        style.align = align
      end
    elseif property == "font-size" then
      local size = NAMED_SMALL[value] or relative_length(value)
      -- 1em is the body text: recording it would only add noise
      -- (1em 就是正文，记下来只会添噪音)
      if size and size ~= 1 then
        style.size = size
      end
    elseif property == "color" then
      local color = value:gsub("%s*!important%s*$", "")
      if color ~= "" and not NEUTRAL_COLORS[color] then
        style.color = color
      end
    elseif property == "text-indent" then
      local indent = relative_length(value)
      if indent then
        style.indent = indent
      end
    elseif property == "padding" then
      -- shorthand: 1 value = all sides, 2/3 = the second is horizontal, 4 = the
      -- fourth is left. Only the horizontal padding matters to typesetting.
      -- (简写：1 个值=四边，2/3 个值=第二个是水平方向，4 个值=第四个是左。排版只关心水平方向)
      local values = {}
      for piece in value:gmatch("[^%s]+") do
        values[#values + 1] = piece
      end
      local left = values[1]
      if #values >= 4 then
        left = values[4]
      elseif #values >= 2 then
        left = values[2]
      end
      local parsed = relative_length(left)
      if parsed then
        style.padding_left = parsed
        style.padding_right = parsed
      end
    elseif property == "padding-left" then
      local pad = relative_length(value)
      if pad then
        style.padding_left = pad
      end
    elseif property == "padding-right" then
      local pad = relative_length(value)
      if pad then
        style.padding_right = pad
      end
    end
  end
  return style
end

---Merge two styles; the second wins.
---(合并两个样式，后者优先)
---
---Values are copied as they are, not collapsed to `true`: `align = "center"`
---has to survive the merge, and it is consulted as a string further down.
---(值原样拷贝，不压成 `true`：`align = "center"` 必须活过合并，后续是按字符串用的)
---@param base weread.css.Style|nil
---@param extra weread.css.Style|nil
---@return weread.css.Style
function M.merge(base, extra)
  local merged = {}
  for _, source in ipairs({ base or {}, extra or {} }) do
    for key, value in pairs(source) do
      if value ~= nil and value ~= false then
        merged[key] = value
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
  local lowered = tostring(class or ""):lower()
  for token in lowered:gmatch("[%w_%-]+") do
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

  -- Block level layout by name, used only when the stylesheet says nothing
  -- about the class. `content_center` and `footnote_content` are real WeRead
  -- names; books without a stylesheet still get their centering and small print.
  -- (类名推断的块级排版，只在样式表没提到这个类时使用。content_center 与
  --  footnote_content 是微信读书真实用到的类名；没有样式表的书也能保住居中与小字)
  for _, rule in ipairs(BLOCK_NAME_HINTS) do
    if lowered:find(rule.pattern) then
      style[rule.key] = style[rule.key] or rule.value
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
