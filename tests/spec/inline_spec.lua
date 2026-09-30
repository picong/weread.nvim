--[[
Tests for weread.inline: rendering the style spans as real attributes instead of
visible markdown punctuation.
(inline 单测：把样式区间渲染成真实属性，而不是把 markdown 标点摆在读者面前)

The fixture chapter carries one of each: `<strong>`, a stylesheet-driven
`<span class="wr-bold">`, an inline-styled span, `<u>`, `<s>` and `<sup>`.
(夹具章节每种各有一个：`<strong>`、样式表驱动的 `<span class="wr-bold">`、
 行内 style 的 span、`<u>`、`<s>` 与 `<sup>`)
]]

local inline = require("weread.inline")
local xhtml = require("weread.xhtml")

local FIXTURES = vim.fn.getcwd() .. "/tests/fixtures"

local function fixture(name)
  return table.concat(vim.fn.readfile(FIXTURES .. "/" .. name), "\n")
end

local shards = vim.json.decode(fixture("shards.json"))
local CONVERTED = xhtml.convert(shards.xhtml.plain, { css = shards.css.plain })

---@param kind string
---@return table|nil style
local function style_of(kind)
  for _, style in ipairs(CONVERTED.styles) do
    if style.kind == kind then
      return style
    end
  end
  return nil
end

---@param buf integer
---@return table[]
local function marks_of(buf)
  return vim.api.nvim_buf_get_extmarks(
    buf,
    vim.api.nvim_create_namespace("weread.inline"),
    0,
    -1,
    { details = true }
  )
end

describe("xhtml.convert styling", function()
  it("keeps every kind of emphasis in the markdown", function()
    truthy(CONVERTED.text:find("**这是加粗的文字**", 1, true), "strong")
    truthy(CONVERTED.text:find("*“不要回答！”*", 1, true), "em")
    truthy(CONVERTED.text:find("**类驱动加粗**", 1, true), "stylesheet class")
    truthy(CONVERTED.text:find("*行内斜体*", 1, true), "inline style attribute")
  end)

  it("records a style span for both markdown and drawn styles", function()
    eq(#CONVERTED.styles >= 6, true, "one per styled run: " .. #CONVERTED.styles)
    for _, kind in ipairs({ "bold", "italic", "underline", "strike", "sup" }) do
      truthy(style_of(kind), "a span for " .. kind)
    end
  end)

  it("points the span at the content, not at the markers", function()
    local bold = style_of("bold")
    eq(bold.markers, 2)
    local line = vim.split(CONVERTED.text, "\n", { plain = true })[bold.line + 1]
    local content = line:sub(bold.col_from + 1, bold.col_to)
    eq(content, "这是加粗的文字")
    eq(line:sub(bold.col_from - 1, bold.col_from), "**")
    eq(line:sub(bold.col_to + 1, bold.col_to + 2), "**")
  end)

  it("marks spans that have no markdown syntax", function()
    local underline = style_of("underline")
    eq(underline.markers, 0)
    local line = vim.split(CONVERTED.text, "\n", { plain = true })[underline.line + 1]
    eq(line:sub(underline.col_from + 1, underline.col_to), "下划线文字")

    local strike = style_of("strike")
    eq(strike.markers, 0)
    local strike_line = vim.split(CONVERTED.text, "\n", { plain = true })[strike.line + 1]
    eq(strike_line:sub(strike.col_from + 1, strike.col_to), "删除线文字")
  end)

  it("resolves nesting without losing a level", function()
    local result = xhtml.convert([[<p><strong>粗<em>且斜</em></strong></p>]])
    truthy(result.text:find("**粗*且斜***", 1, true), "got: " .. result.text)
    eq(#result.styles, 2)

    -- spans are recorded when their closing tag is met, so the inner one comes
    -- first; look them up by kind instead of by order
    -- (样式在遇到闭合标签时记录，因此内层先出现；按 kind 查找而不是按下标)
    local by_kind = {}
    for _, style in ipairs(result.styles) do
      by_kind[style.kind] = style
    end
    truthy(by_kind.bold and by_kind.italic, "both levels recorded")
    truthy(by_kind.italic.col_from > by_kind.bold.col_from, "the inner span starts later")
    truthy(by_kind.italic.col_to < by_kind.bold.col_to, "and ends earlier")
  end)

  it("drops a style that would span a line break", function()
    local result = xhtml.convert("<p><strong>上<br/>下</strong></p>")
    eq(#result.styles, 0, "an unrepresentable span is dropped, not misreported")
    eq(result.text, "　　**上\n下**")
  end)

  it("ignores spans with nothing to say", function()
    local result = xhtml.convert('<p><span class="calibre3" style="font-size:1.2em">普通文字</span></p>')
    eq(result.text, "　　普通文字")
    eq(#result.styles, 0)
  end)
end)

describe("inline.attach", function()
  ---@return integer buf
  local function styled_buffer()
    local buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, vim.split(CONVERTED.text, "\n", { plain = true }))
    return buf
  end

  it("applies an attribute and hides the markers", function()
    local buf = styled_buffer()
    local drawn = inline.attach(buf, CONVERTED.styles)
    eq(drawn >= 6, true, "every span was drawn: " .. drawn)

    local namespace = vim.api.nvim_create_namespace("weread.inline")
    local marks = vim.api.nvim_buf_get_extmarks(buf, namespace, 0, -1, { details = true })

    local groups = {}
    for _, mark in ipairs(marks) do
      local details = mark[4]
      if details.hl_group then
        groups[details.hl_group] = groups[details.hl_group] or {}
        table.insert(groups[details.hl_group], mark)
      end
    end

    truthy(groups.Bold, "bold span")
    truthy(groups.Italic, "italic span")
    truthy(groups.Underline, "underline span")
    truthy(groups.Strikethrough, "strike span")

    -- every drawn span must line up with a recorded span
    -- (每个画出来的区间都要与记录的样式吻合)
    for _, mark in ipairs(marks) do
      local details = mark[4]
      if details.hl_group then
        local matched = false
        for _, style in ipairs(CONVERTED.styles) do
          if
            style.line == mark[2]
            and style.col_from == mark[3]
            and style.col_to == details.end_col
          then
            matched = true
            break
          end
        end
        truthy(matched, string.format("mark %s at %d:%d has no matching span", details.hl_group, mark[2], mark[3]))
      end
    end

    -- and its markers are concealed
    local concealed = 0
    for _, mark in ipairs(marks) do
      if mark[4].conceal ~= nil then
        concealed = concealed + 1
      end
    end
    local expected_conceals = 0
    for _, style in ipairs(CONVERTED.styles) do
      if (style.markers or 0) > 0 then
        expected_conceals = expected_conceals + 2
      end
    end
    eq(concealed, expected_conceals, "two markers per markdown style")

    vim.api.nvim_buf_delete(buf, { force = true })
  end)

  it("leaves the paragraph indent outside the span", function()
    -- The span must start at the content: swallowing the indent would underline
    -- the leading gap too.
    -- (区间必须从内容开始：把缩进吞进去会给行首空白也画上下划线)
    local underline = style_of("underline")
    local line = vim.split(CONVERTED.text, "\n", { plain = true })[underline.line + 1]
    eq(line:sub(1, 6), "　　", "the line is indented")
    eq(line:sub(underline.col_from + 1, underline.col_to), "下划线文字")
  end)

  it("does nothing without styles, or on an invalid buffer", function()
    local buf = styled_buffer()
    eq(inline.attach(buf, nil), 0)
    eq(inline.attach(buf, {}), 0)
    vim.api.nvim_buf_delete(buf, { force = true })
    eq(inline.attach(buf, CONVERTED.styles), 0, "a wiped buffer is not an error")
  end)

  it("clears previous marks so a re-render cannot stack them", function()
    local buf = styled_buffer()
    inline.attach(buf, CONVERTED.styles)
    local first = #marks_of(buf)
    inline.attach(buf, CONVERTED.styles)
    eq(#marks_of(buf), first, "same count after a second attach")
    vim.api.nvim_buf_delete(buf, { force = true })
  end)

  it("skips spans that point outside the buffer", function()
    local buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "只有一行" })
    local drawn = inline.attach(buf, {
      { line = 99, col_from = 0, col_to = 3, kind = "bold", markers = 2 },
      { line = 0, col_from = 2, col_to = 4, kind = "bold", markers = 2 },
    })
    eq(drawn, 1, "the out-of-range span is ignored")
    vim.api.nvim_buf_delete(buf, { force = true })
  end)
end)

describe("inline.from_meta", function()
  it("reads the spans stored beside the offset map", function()
    eq(#inline.from_meta({ styles = CONVERTED.styles }), #CONVERTED.styles)
    eq(inline.from_meta(nil), {})
    eq(inline.from_meta({}), {})
    eq(inline.from_meta({ styles = "nonsense" }), {})
  end)
end)
