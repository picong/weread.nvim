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

describe("inline.render_headings", function()
  it("paints the whole heading line and hides the hash marks", function()
    local buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "# 小标题", "正文" })
    local drawn = inline.render_headings(buf, { { line = 0, level = 1 } })
    eq(drawn, 1)

    local marks = marks_of(buf)
    local span, conceal = nil, nil
    for _, mark in ipairs(marks) do
      if mark[4].hl_group == "WereadHeading1" then
        span = mark
      elseif mark[4].conceal ~= nil then
        conceal = mark
      end
    end

    truthy(span, "a heading span")
    eq(span[2], 0, "on the heading line")
    eq(span[3], 0, "covering from the first column")
    eq(span[4].end_col, #"# 小标题", "to the end of the line")
    -- (hl_mode/priority are render-time options and are not echoed back by
    --  nvim_buf_get_extmarks, so the group name is what we can assert here)
    -- (hl_mode/priority 是渲染期选项，nvim_buf_get_extmarks 不会回传，因此这里能断言的
    --  是组名)

    truthy(conceal, "the `#` are hidden")
    eq(conceal[3], 0)
    eq(conceal[4].end_col, 2, "`# ` is concealed")

    vim.api.nvim_buf_delete(buf, { force = true })
  end)

  it("handles deeper levels and ignores out-of-range lines", function()
    local buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "### 三级", "正文" })
    inline.render_headings(buf, {
      { line = 0, level = 3 },
      { line = 99, level = 1 },
    })
    local marks = marks_of(buf)
    local concealed_end = nil
    for _, mark in ipairs(marks) do
      if mark[4].conceal ~= nil then
        concealed_end = mark[4].end_col
      end
    end
    eq(concealed_end, 4, "`### ` is concealed")
    vim.api.nvim_buf_delete(buf, { force = true })
  end)

  it("survives missing arguments", function()
    local buf = vim.api.nvim_create_buf(false, true)
    eq(inline.render_headings(buf, nil), 0)
    eq(inline.attach(buf, nil, nil), 0)
    vim.api.nvim_buf_delete(buf, { force = true })
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

    -- The palette's own groups, not the built-in Bold/Italic: those carry no
    -- colour, so a colorscheme's syntax colours used to show through them.
    -- (用配色自己的组，而不是内置的 Bold/Italic：那两组没有颜色，配色方案的语法颜色会透出来)
    truthy(groups.WereadStrong, "bold span")
    truthy(groups.WereadItalic, "italic span")
    truthy(groups.WereadUnderline, "underline span")
    truthy(groups.WereadStrike, "strike span")

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

  it("paints headings when asked", function()
    local buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "## 标题", "正文" })
    inline.attach(buf, {}, { { line = 0, level = 2 } })
    local found = false
    for _, mark in ipairs(marks_of(buf)) do
      if mark[4].hl_group == "WereadHeading2" then
        found = true
      end
    end
    truthy(found, "the heading was painted")
    vim.api.nvim_buf_delete(buf, { force = true })
  end)

  it("does nothing without styles, or on an invalid buffer", function()
    local buf = styled_buffer()
    eq(inline.attach(buf, nil), 0)
    eq(inline.attach(buf, {}), 0)
    vim.api.nvim_buf_delete(buf, { force = true })
    eq(inline.attach(buf, CONVERTED.styles), 0, "a wiped buffer is not an error")
  end)

  it("dots CJK emphasis, skipping the punctuation", function()
    local buf = vim.api.nvim_create_buf(false, true)
    -- "**重要，必读**" : the bold span covers 重要，必读(粗体区间覆盖「重要，必读」)
    local text = "**重要，必读** and **bold**"
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { text })
    local cjk_from, cjk_to = 2, 2 + #"重要，必读"
    local latin_from = text:find("bold", 1, true) - 1
    inline.attach(buf, {
      { line = 0, col_from = cjk_from, col_to = cjk_to, kind = "bold", markers = 2 },
      { line = 0, col_from = latin_from, col_to = latin_from + 4, kind = "bold", markers = 2 },
    })
    local dots = {}
    for _, mark in ipairs(marks_of(buf)) do
      if mark[4].hl_group == "WereadEmphasisDots" then
        dots[#dots + 1] = text:sub(mark[3] + 1, mark[4].end_col)
      end
    end
    eq(dots, { "重要", "必读" }, "two runs, the comma left bare, nothing under Latin bold")
    vim.api.nvim_buf_delete(buf, { force = true })
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
      { line = 99, col_from = 0, col_to = 3, kind = "italic", markers = 2 },
      { line = 0, col_from = 2, col_to = 4, kind = "italic", markers = 2 },
    })
    eq(drawn, 1, "the out-of-range span is ignored")
    vim.api.nvim_buf_delete(buf, { force = true })
  end)
end)

describe("inline.conceal_structure", function()
  it("names the language of a listing on the fence line", function()
    -- render-markdown can name it too, but it puts the name on the empty line above
    -- the fence, and an `overlay` virt_text is not drawn on an empty line — verified
    -- against this neovim. So the page names it, on the fence's own line, which
    -- carries the text an overlay needs.
    -- (render-markdown 也会写语言名，但它把名字放在围栏上方的空行上，而 `overlay` 类虚拟文本
    --  在空行上不会被绘制——已在本机 neovim 上实测。因此由书页自己写，写在围栏自己那一行上，
    --  那一行带有叠加内容所需的文本)
    local buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "```bash", "claude -p x", "```" })
    inline.conceal_structure(buf)

    local marks = vim.api.nvim_buf_get_extmarks(buf, vim.api.nvim_create_namespace("weread.inline"), 0, -1, { details = true })
    local label = nil
    for _, mark in ipairs(marks) do
      local details = mark[4] or {}
      if details.virt_text and details.virt_text[1] then
        label = details.virt_text[1][1]
      end
    end
    eq(label, "bash", "the language is on the page")
    vim.api.nvim_buf_delete(buf, { force = true })
  end)

  it("hides code fences and table separator rows", function()
    -- Both carry no text: the fence says "listing" to another reader of the file,
    -- the separator is what makes the block a table. The page shows neither.
    -- (两者都不是内容：围栏是给别的读者/工具看的「这是清单」，分隔行是让整块成为表格的前提。
    --  页面上两者都不出现)
    local buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, {
      "正文",
      "```",
      "code()",
      "```",
      "| 维度| 用户界面|",
      "| --- | --- |",
      "| 交互模式| 终端 TUI|",
      "| 只是带竖线的正文|",
    })
    eq(inline.conceal_structure(buf), 3, "two fences and the separator row")
    local marks = marks_of(buf)
    local concealed = 0
    for _, mark in ipairs(marks) do
      if mark[4].conceal ~= nil then
        concealed = concealed + 1
      end
    end
    eq(concealed, 3, "each one is concealed")
    -- the prose line that merely contains a pipe is left alone
    -- (只是含竖线的正文不受影响)
    for _, mark in ipairs(marks) do
      truthy(mark[1] ~= 7, "the last line must not be touched")
      truthy(mark[1] ~= 0, "nor the first")
    end
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

describe("inline.render_lines", function()
  ---@param marks table[]
  ---@param line integer
  ---@return table|nil
  local function virt_text_on(marks, line)
    for _, mark in ipairs(marks) do
      local details = mark[4] or {}
      if mark[2] == line and details.virt_text then
        return details
      end
    end
    return nil
  end

  it("centers a line with padding that is not part of the buffer", function()
    local buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "居中标题", "左对齐正文" })
    local drawn = inline.render_lines(buf, { [0] = { align = "center", cells = 8 } }, 52, "WereadMargin")
    eq(drawn, 1, "only the centered line is padded")

    local details = virt_text_on(marks_of(buf), 0)
    truthy(details, "the line got virtual text")
    eq(details.virt_text_pos, "inline")
    eq(details.virt_text[1][1], string.rep(" ", 22), "(52 - 8) / 2")
    eq(virt_text_on(marks_of(buf), 1), nil, "the body text is left alone")

    -- and the buffer itself is untouched: highlights resolve to the same columns
    -- (buffer 本身不动：划线解析出的列号因此不受影响)
    eq(vim.api.nvim_buf_get_lines(buf, 0, 1, false)[1], "居中标题")
    vim.api.nvim_buf_delete(buf, { force = true })
  end)

  it("right aligns by padding to the margin", function()
    local buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "——孔子" })
    inline.render_lines(buf, { [0] = { align = "right", cells = 8 } }, 52, "WereadMargin")
    eq(virt_text_on(marks_of(buf), 0).virt_text[1][1], string.rep(" ", 44))
    vim.api.nvim_buf_delete(buf, { force = true })
  end)

  it("accepts the string keys a decoded map.json has", function()
    local buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "——孔子" })
    local drawn = inline.render_lines(buf, { ["0"] = { align = "right", cells = 6 } }, 40, "WereadMargin")
    eq(drawn, 1, "JSON object keys arrive as strings")
    vim.api.nvim_buf_delete(buf, { force = true })
  end)

  it("paints small print and the colour a book gave a block", function()
    local buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "脚注", "提示 64" })
    local drawn = inline.render_lines(buf, {
      [0] = { small = true, cells = 4 },
      [1] = { accent = true, cells = 7 },
    }, 0, "WereadMargin")
    eq(drawn, 2)
    local groups = {}
    for _, mark in ipairs(marks_of(buf)) do
      groups[mark[2]] = (mark[4] or {}).hl_group
    end
    eq(groups[0], "WereadSmall")
    eq(groups[1], "WereadHeading")
    vim.api.nvim_buf_delete(buf, { force = true })
  end)

  it("does not pad without a page width", function()
    local buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "标题" })
    eq(inline.render_lines(buf, { [0] = { align = "center", cells = 4 } }, 0), 0)
    vim.api.nvim_buf_delete(buf, { force = true })
  end)
end)

describe("inline justification and footnotes", function()
  it("draws the fill so a wrapped line reaches the page width on screen", function()
    local result = xhtml.convert("<p>甲乙丙丁戊己庚辛壬癸子abcdefghijklmnop</p>", {
      page_width = 26,
      auto_space = true,
      paragraph = { indent = "" },
    })
    truthy(result.lines[0] and result.lines[0].fill, "the first line is justified")

    vim.o.columns = 80
    local buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_set_current_buf(buf)
    vim.wo.number = false
    vim.wo.wrap = false
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, vim.split(result.text, "\n", { plain = true }))
    inline.render_lines(buf, vim.json.decode(vim.json.encode(xhtml.json_lines(result.lines))), 26, "WereadMargin")
    vim.cmd("redraw!")

    ---Cells row `row` spans on screen, from its first to its last character.
    ---Measured from the text itself: whatever column gutter the window carries
    ---comes before it.
    ---(第 row 行在屏幕上从第一个到最后一个字符占多少格。从文本本身量起：窗口带的任何
    --- 侧栏都在它之前)
    local function row_width(row)
      local first, last = nil, 0
      for col = 1, vim.o.columns do
        local cell = vim.fn.screenstring(row, col)
        if cell ~= " " and cell ~= "" then
          first = first or col
          last = col + vim.fn.strdisplaywidth(cell) - 1
        end
      end
      return first and (last - first + 1) or 0
    end
    eq(row_width(1), 26, "the justified row ends at the margin")
    eq(row_width(2), 16, "the paragraph's last line is left ragged")
    eq(vim.api.nvim_buf_get_lines(buf, 0, 1, false)[1], "甲乙丙丁戊己庚辛壬癸子", "the buffer text is untouched")
    vim.api.nvim_buf_delete(buf, { force = true })
  end)

  it("paints footnote marks", function()
    local buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "正文[1]后文" })
    local notes = { { line = 0, col_from = 6, col_to = 9, text = "注" }, { line = 5, col_from = 0, col_to = 3 } }
    eq(inline.render_footnotes(buf, notes), 1, "the off-buffer entry is skipped")
    local mark = marks_of(buf)[1]
    eq(mark[4].hl_group, "WereadFootnote")
    eq(mark[3], 6)
    eq(mark[4].end_col, 9)

    inline.attach(buf, {}, nil, nil, 0, notes)
    local found = false
    for _, each in ipairs(marks_of(buf)) do
      found = found or each[4].hl_group == "WereadFootnote"
    end
    truthy(found, "attach draws them too")
    vim.api.nvim_buf_delete(buf, { force = true })
  end)

  it("picks the heading group by level", function()
    eq(inline.heading_group(1), "WereadHeading1")
    eq(inline.heading_group(2), "WereadHeading2")
    eq(inline.heading_group(3), "WereadHeading3")
    eq(inline.heading_group(6), "WereadHeading3")
    eq(inline.heading_group(nil), "WereadHeading1")
  end)
end)

describe("weread.inline markdown structure", function()
  it("draws a heading's icon, and blank room on the lines it wrapped onto", function()
    local buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "## 甲甲", "## 乙乙", "正文" })
    inline.render_headings(buf, { { line = 0, level = 2 }, { line = 1, level = 2, continued = true } })
    local ns = vim.api.nvim_create_namespace("weread.inline")
    local icons = {}
    for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(buf, ns, 0, -1, { details = true })) do
      local virt = mark[4].virt_text
      if virt then
        icons[mark[2]] = virt[1][1]
      end
    end
    eq(icons[0], inline.heading_icon(2), "the level's icon")
    eq(vim.trim(icons[1]), "", "a continuation line keeps its text under the first")
    eq(vim.fn.strdisplaywidth(icons[1]), vim.fn.strdisplaywidth(icons[0]))
    vim.api.nvim_buf_delete(buf, { force = true })
  end)

  it("conceals the backslash of an escaped line start", function()
    local buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "甲", "\\- 乙" })
    eq(inline.render_escapes(buf, { { line = 1, col = 0 } }), 1)
    eq(inline.render_escapes(buf, { { line = 0, col = 0 } }), 0, "only where a backslash is")
    vim.api.nvim_buf_delete(buf, { force = true })
  end)
end)
