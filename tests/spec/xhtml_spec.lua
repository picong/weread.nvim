--[[
Tests for weread.xhtml: the markdown conversion and, more importantly, the
source-rune -> markdown offset map that annotations depend on.
(xhtml 单测：markdown 转换，以及划线定位所依赖的「源 rune → markdown 位置」映射)
]]

local xhtml = require("weread.xhtml")

local FIXTURES = vim.fn.getcwd() .. "/tests/fixtures"

local function fixture(name)
  return table.concat(vim.fn.readfile(FIXTURES .. "/" .. name), "\n")
end

-- The chapter body lives in the shard fixture (decoded by the python encoder
-- upstream), not in the reader page.
-- (章节正文在分片夹具里，不在阅读器页面里)
local CHAPTER = vim.json.decode(fixture("shards.json")).xhtml.plain

---Rune offset of a needle inside a source string, computed with nvim's own
---UTF machinery so it does not depend on the converter's counting.
---(用 nvim 自己的 UTF 工具计算子串的 rune 偏移，不依赖转换器的计数实现)
---@param source string
---@param needle string
---@return integer
local function rune_offset_of(source, needle)
  local byte_start = source:find(needle, 1, true)
  assert(byte_start, "needle not found: " .. needle)
  -- str_utfindex returns (utf32, utf16); underline ranges are code point
  -- based, so take the first one.
  -- (str_utfindex 返回 (utf32, utf16)；划线 range 基于码点，取第一个)
  return select(1, vim.str_utfindex(source, byte_start - 1))
end

describe("xhtml.count_runes", function()
  it("agrees with vim.str_utfindex", function()
    for _, sample in ipairs({
      "",
      "ascii only",
      "中文段落",
      "混合 mixed 中英 123",
      "emoji 🎉 and text",
      "　全角空格",
    }) do
      eq(xhtml.count_runes(sample), select(1, vim.str_utfindex(sample)), sample)
    end
  end)
end)

describe("xhtml.decode_entities", function()
  it("decodes named and numeric entities", function()
    eq(xhtml.decode_entities("a&nbsp;b"), "a b")
    eq(xhtml.decode_entities("&ldquo;不要回答！&rdquo;"), "“不要回答！”")
    eq(xhtml.decode_entities("&#8220;x&#8221;"), "“x”")
    eq(xhtml.decode_entities("&#x2014;"), "—")
    eq(xhtml.decode_entities("a &amp; b &lt;tag&gt;"), "a & b <tag>")
  end)

  it("leaves unknown entities and bare ampersands alone", function()
    eq(xhtml.decode_entities("AT&T"), "AT&T")
    eq(xhtml.decode_entities("&unknownentity;"), "&unknownentity;")
  end)
end)

describe("xhtml.convert", function()
  it("renders the chapter fixture as readable markdown", function()
    local result = xhtml.convert(CHAPTER)
    local text = result.text

    truthy(text:find("# 第 3 章 宇宙闪烁", 1, true), "heading")
    truthy(text:find("汪淼把车停在楼下，抬头看天。", 1, true), "paragraph text")
    truthy(text:find("*“不要回答！”*", 1, true), "emphasis")
    truthy(text:find("![](https://res.weread.qq.com/wrepub/epub_43208843_44)", 1, true), "image marker")
    falsy(text:find("<p>", 1, true), "no leftover tags")
    falsy(text:find("&nbsp;", 1, true), "entities decoded")
  end)

  it("reports the images it saw", function()
    local result = xhtml.convert(CHAPTER)
    eq(#result.images, 2)
    eq(result.images[1].src, "https://res.weread.qq.com/wrepub/epub_43208843_44")
    eq(result.images[1].resolved, result.images[1].src, "unresolved by default")
  end)

  it("rewrites image sources when asked", function()
    local result = xhtml.convert(CHAPTER, {
      resolve_image = function(src)
        return "/cache/assets/" .. src:match("([^/]+)$") .. ".png"
      end,
    })
    truthy(result.text:find("(/cache/assets/epub_43208843_44.png)", 1, true))
    eq(result.images[1].resolved, "/cache/assets/epub_43208843_44.png")
  end)

  it("drops a leading BOM the way underline ranges do", function()
    local result = xhtml.convert("\239\187\191<p>正文</p>")
    -- "<p>" is three runes, so the text run starts at 3 whether or not a BOM
    -- preceded it: underline ranges do not count the BOM either.
    -- ("<p>" 是三个 rune，因此无论前面有没有 BOM，文本段都从 3 开始：
    --  划线 range 同样不计算 BOM)
    eq(result.map[1].src_from, 3)
    eq(result.map[1].src_to, 5)
    -- <p> + 正文 + </p> + the BOM itself
    -- (<p> + 正文 + </p> + BOM 自身)
    eq(xhtml.count_runes("\239\187\191<p>正文</p>"), 10)
  end)

  it("skips script and style bodies without losing offset alignment", function()
    local source = '<style>p{color:red}</style><p>正文甲</p>'
    local result = xhtml.convert(source)
    falsy(result.text:find("color:red", 1, true), "css dropped")
    truthy(result.text:find("正文甲", 1, true))

    local offset = rune_offset_of(source, "正文甲")
    local start = xhtml.resolve(result, offset, offset + 3)
    truthy(start, "the offset still resolves after a skipped block")
    eq(vim.split(result.text, "\n", { plain = true })[start.line + 1], "　　正文甲")
  end)

  it("keeps counting runes across comments", function()
    local source = '<p>前<!-- 注释 -->后</p>'
    local result = xhtml.convert(source)
    eq(result.text, "　　前后", "the paragraph indent is applied")
    local offset = rune_offset_of(source, "后")
    local start = xhtml.resolve(result, offset, offset + 1)
    truthy(start)
    -- The counter must swallow the whole comment, otherwise every later range
    -- would be off by its length.
    -- (计数必须把整段注释吃掉，否则其后所有 range 都会整体偏移)
    eq(result.source_runes, xhtml.count_runes(source))
  end)
end)

describe("xhtml.resolve", function()
  local result = xhtml.convert(CHAPTER)

  ---@param needle string
  ---@return table
  local function resolve_text(needle)
    local offset = rune_offset_of(CHAPTER, needle)
    local start, finish = xhtml.resolve(result.map, offset, offset + xhtml.count_runes(needle))
    return { start = start, finish = finish }
  end

  it("maps highlighted text to the markdown line that holds it", function()
    local lines = vim.split(result.text, "\n", { plain = true })
    for _, needle in ipairs({
      "第 3 章",
      "汪淼把车停在楼下",
      "不要回答",
      "图 1-6",
    }) do
      local resolved = resolve_text(needle)
      truthy(resolved.start, "resolved " .. needle)
      local line = lines[resolved.start.line + 1]
      truthy(line, "line exists for " .. needle)
      truthy(
        line:find(vim.trim(needle), 1, true),
        string.format("%q should be on line %d, got %q", needle, resolved.start.line, line)
      )
    end
  end)

  it("is monotonic: a later range never resolves to an earlier line", function()
    local first = resolve_text("汪淼把车停在楼下")
    local second = resolve_text("图 1-6")
    truthy(second.start.line >= first.start.line)
  end)

  it("snaps a range that starts mid-run outward to the run", function()
    -- "把车停在" sits inside the paragraph's text run; the resolver clamps to
    -- that run instead of inventing a sub-character offset.
    -- (「把车停在」位于该段落的文本 run 内部；解析器收敛到该 run，而不是编造
    --  字符级偏移)
    local resolved = resolve_text("把车停在")
    local lines = vim.split(result.text, "\n", { plain = true })
    eq(lines[resolved.start.line + 1], "　　汪淼把车停在楼下，抬头看天。")
    eq(resolved.finish.line, resolved.start.line)
  end)

  it("returns nil for an offset past the end of the content", function()
    local start = xhtml.resolve(result, result.source_runes + 500, result.source_runes + 600)
    eq(start, nil)
  end)

  it("accepts a bare map as well as a conversion result", function()
    local offset = rune_offset_of(CHAPTER, "汪淼把车停在楼下")
    local via_result = xhtml.resolve(result, offset, offset + 8)
    local via_map = xhtml.resolve(result.map, offset, offset + 8)
    eq(via_map and via_map.line, via_result and via_result.line)
  end)

  it("survives an empty map", function()
    eq(xhtml.resolve({}, 0, 1), nil)
  end)
end)

describe("xhtml.convert edge cases", function()
  it("keeps a bold span opening with 《 intact", function()
    -- `[ 　]` is a byte class holding 0xE3 0x80, the lead bytes of 《 (E3 80 8A):
    -- the opening `**` used to land inside the character and garble it.
    -- (`[ 　]` 这个字节类含 0xE3 0x80，正是 《 的前导字节：开启的 `**` 曾插进字符中间造成乱码)
    for _, width in ipairs({ 0, 60 }) do
      local result = xhtml.convert("<p>甲<b>《人月神话》的观点</b></p>", { page_width = width })
      truthy(result.text:find("**《人月神话》的观点**", 1, true), result.text)
      truthy(vim.str_utfindex(result.text, "utf-32"), "valid UTF-8")
    end
  end)

  it("handles an empty chapter", function()
    local result = xhtml.convert("")
    eq(result.text, "")
    eq(#result.map, 0)
  end)

  it("handles text with no tags at all", function()
    local result = xhtml.convert("只有正文没有任何标签")
    eq(result.text, "只有正文没有任何标签")
    eq(result.map[1].src_from, 0)
    eq(result.map[1].src_to, 10)
  end)

  it("handles unclosed tags without crashing", function()
    local result = xhtml.convert("<p>第一段<p>第二段")
    truthy(result.text:find("第一段", 1, true))
    truthy(result.text:find("第二段", 1, true))
  end)

  it("handles a lone '<' without crashing", function()
    local result = xhtml.convert("<p>a < b</p>")
    truthy(result.text:find("a", 1, true))
  end)

  it("renders list items and blockquotes", function()
    local result = xhtml.convert("<ul><li>甲</li><li>乙</li></ul><blockquote>引用</blockquote>")
    truthy(result.text:find("- 甲", 1, true))
    truthy(result.text:find("- 乙", 1, true))
    truthy(result.text:find("> 　　引用", 1, true))
  end)

  local function lines_of(text)
    return vim.split(text, "\n", { plain = true })
  end

  it("writes standard markdown a renderer can draw", function()
    local function text(source, opts)
      return xhtml.convert(source, vim.tbl_extend("force", { paragraph = { indent = "　　" } }, opts or {})).text
    end
    -- a list item's text sits on its marker's line, even wrapped in a `<p>`
    -- (列表项的文字与标记同行，即使它包在 `<p>` 里)
    eq(text("<ul><li><p>甲</p></li><li><p>乙</p></li></ul><p>后</p>"), "- 甲\n- 乙\n\n　　后", "and a blank line ends the list")
    eq(text('<ol start="3"><li>甲</li><li>乙</li></ol>'), "3. 甲\n4. 乙", "ordered lists keep their numbers")
    eq(text("<ul><li>外<ul><li>内</li></ul></li></ul>"), "- 外\n  - 内", "a nested list sits under its parent's text")
    -- every line of a quote is quoted, and a blank line ends it
    -- (引文的每一行都带 `>`，空行结束引文)
    eq(text("<blockquote><p>甲</p><p>乙</p></blockquote><p>丙</p>"), "> 　　甲\n> 　　乙\n\n　　丙")
    eq(text("<blockquote><p>甲</p><blockquote><p>乙</p></blockquote></blockquote>"), "> 　　甲\n> > 　　乙")
    -- a wrapped quote and a wrapped list item keep their structure
    -- (折行的引文与列表项保持各自的结构)
    local quote = lines_of(text("<blockquote><p>" .. string.rep("字", 20) .. "</p></blockquote>", { page_width = 20 }))
    for _, line in ipairs(quote) do
      truthy(vim.startswith(line, "> "), "quoted: [" .. line .. "]")
    end
    local item = lines_of(text("<ul><li>" .. string.rep("字", 20) .. "</li></ul>", { page_width = 20 }))
    eq(item[1]:sub(1, 2), "- ")
    for index = 2, #item do
      truthy(vim.startswith(item[index], "  ") and not item[index]:find("^   "), "hangs under the text: [" .. item[index] .. "]")
    end
    -- `---` never sits under a line of text, which would make it a heading
    -- (`---` 绝不紧贴在一行文字下面，那会让那行文字变成标题)
    eq(text("<p>甲</p><hr/><p>乙</p>", { gap = "none" }), "　　甲\n\n---\n\n　　乙")
  end)

  it("keeps a wrapped heading a heading", function()
    local result = xhtml.convert("<h2>" .. string.rep("字", 16) .. "</h2><p>甲</p>", { page_width = 20, paragraph = { indent = "" } })
    local lines = lines_of(result.text)
    eq(lines[1]:sub(1, 3), "## ")
    eq(lines[2]:sub(1, 3), "## ", "the next line is a heading line too")
    eq(#result.headings, 2)
    eq(result.headings[2].line, 1)
    eq(result.headings[2].continued, true)
  end)

  it("keeps emphasis markers next to the text they mark", function()
    -- `* 1939*` is not emphasis, and at the start of a line it is a list item
    -- (`* 1939*` 不是强调；放在行首它还是列表项)
    local result = xhtml.convert("<p>甲，<em> 1939</em></p>", { paragraph = { indent = "" } })
    eq(result.text, "甲， *1939*")
    local wrapped = xhtml.convert("<p>" .. string.rep("字", 9) .. "，<em>" .. " 1939" .. "</em></p>", {
      page_width = 20,
      paragraph = { indent = "" },
    })
    for _, line in ipairs(lines_of(wrapped.text)) do
      falsy(line:find("^%* "), "no line opens with `* `: [" .. line .. "]")
    end
  end)

  it("escapes prose a wrap would turn into a block", function()
    local result = xhtml.convert("<p>" .. string.rep("字", 8) .. "，- 列表样的折行</p>", { page_width = 18, paragraph = { indent = "" } })
    local lines = lines_of(result.text)
    eq(lines[2], "\\- 列表样的折行")
    eq(result.escapes[1].line, 1)
    eq(result.escapes[1].col, 0)
    -- `<p>` is three runes, then eight characters and the comma: `-` is rune 12
    -- (`<p>` 占三个 rune，再加八个字与逗号：`-` 是第 12 个 rune)
    eq(xhtml.rune_at(result, 1, 1, lines[2]), 12, "the backslash is not part of the text")
  end)

  it("never emits two consecutive blank lines", function()
    local result = xhtml.convert("<div><p>a</p></div><div><p>b</p></div>")
    falsy(result.text:find("\n\n\n", 1, true), "got: " .. result.text:gsub("\n", "\\n"))
  end)
end)

describe("xhtml.normalize_text", function()
  it("drops the whitespace that pretty printing leaves between tags", function()
    -- Real chapters are indented with newlines; emitting those verbatim put
    -- blank lines inside paragraphs.
    -- (真实章节用换行做缩进；原样输出会在段落里插入空行)
    eq(xhtml.normalize_text("\n    ", "\n    "), nil)
    eq(xhtml.normalize_text("   ", "   "), nil)
    eq(xhtml.normalize_text("\n", "\n"), nil)
  end)

  it("collapses inner whitespace and keeps the words", function()
    eq(xhtml.normalize_text("\n    第一章 测试\n", "\n    第一章 测试\n"), " 第一章 测试 ")
    eq(xhtml.normalize_text("a\n\nb", "a\n\nb"), "a b")
    eq(xhtml.normalize_text("正文", "正文"), "正文")
  end)
end)

describe("xhtml.convert typesetting", function()
  ---@param count integer
  ---@return string
  local function paragraphs(count)
    local parts = {}
    for index = 1, count do
      parts[#parts + 1] = string.format("<p>第 %d 段的正文内容。</p>", index)
    end
    return table.concat(parts)
  end

  ---@param text string
  ---@return string[] lines
  local function lines_of(text)
    return vim.split(text, "\n", { plain = true })
  end

  it("spends one line per paragraph instead of two", function()
    -- The whole point: blank lines between paragraphs waste half of every
    -- screen, which is what made the reader hard to read.
    -- (重点在这里：段间空行浪费了每屏一半空间，这是阅读吃力的根源)
    local result = xhtml.convert(paragraphs(10), { paragraph = { compact = true, indent = "　　" } })
    local lines = lines_of(result.text)
    eq(#lines, 10, "ten paragraphs, ten lines")
    for _, line in ipairs(lines) do
      truthy(vim.startswith(line, "　　"), "every paragraph is indented: " .. line)
    end
  end)

  it("still separates paragraphs when compact mode is off", function()
    local result = xhtml.convert(paragraphs(3), { paragraph = { compact = false } })
    local lines = lines_of(result.text)
    eq(#lines, 5, "three paragraphs plus two blank lines")
    eq(lines[2], "")
    eq(lines[1], "第 1 段的正文内容。", "no indent in the classic layout")
  end)

  it("does not double an indent the source already carries", function()
    -- TXT books ship with a full-width space of their own.
    -- (TXT 型书籍自带全角缩进)
    local result = xhtml.convert("<p>　　许阳睁开眼睛。</p>", { paragraph = { compact = true, indent = "　　" } })
    eq(result.text, "　　许阳睁开眼睛。")
  end)

  it("keeps the indent for a paragraph that starts with emphasis", function()
    local result = xhtml.convert("<p><em>注意</em>后面的正文。</p>", { paragraph = { compact = true, indent = "　　" } })
    eq(result.text, "　　*注意*后面的正文。")
  end)

  it("records heading lines for the reader to paint", function()
    local result = xhtml.convert("<h1>一级</h1><p>正文</p><h3>三级</h3>")
    eq(#result.headings, 2)
    eq(result.headings[1].level, 1)
    eq(result.headings[2].level, 3)
    local lines = vim.split(result.text, "\n", { plain = true })
    eq(lines[result.headings[1].line + 1], "# 一级")
    eq(lines[result.headings[2].line + 1], "### 三级")
  end)

  it("does not record headings the winbar already shows", function()
    local result = xhtml.convert("<h1>第 1 章</h1><p>正文</p>", { skip_title = true })
    eq(#result.headings, 0)
  end)

  it("keeps a gap before a figure and lets the caption hug it", function()
    local result = xhtml.convert("<h1>标题</h1><p>甲</p><img src=\"/a.png\"/><p>乙</p>", {
      paragraph = { compact = true, indent = "　　" },
    })
    eq(lines_of(result.text), {
      "# 标题",
      "",
      "　　甲",
      "",
      "![](/a.png)",
      "　　乙",
    })
  end)

  it("can squeeze structural gaps out entirely", function()
    local result = xhtml.convert("<h1>标题</h1><p>甲</p><img src=\"/a.png\"/><p>乙</p>", {
      paragraph = { compact = true, indent = "　　", gap = "none" },
    })
    eq(lines_of(result.text), {
      "# 标题",
      "　　甲",
      "![](/a.png)",
      "　　乙",
    })
  end)

  it("leaves no stray markers when the dropped title was styled", function()
    -- The book stylesheet makes the title bold; dropping the heading text must
    -- drop its markers too.
    -- (书里的样式表把标题设成加粗；丢掉标题文字时也要把标记一起丢掉)
    local source = '<h1 class="title">第 3 章 宇宙闪烁</h1><p>正文。</p>'
    local result = xhtml.convert(source, {
      skip_title = true,
      css = "h1.title { font-weight: bold; }",
    })
    eq(lines_of(result.text), { "　　正文。" })
    eq(#result.styles, 0, "and no orphan style span")
  end)

  it("ignores the pretty printed layout of a real chapter", function()
    local source = table.concat({
      "<html><head>",
      "  <title>版权信息</title>",
      "  <style>.x { font-weight: bold }</style>",
      "</head><body>",
      '  <h1 class="x">版权信息</h1>',
      '  <p>书名：某本书</p>',
      '  <hr/>',
      '  <p>后记</p>',
      "</body></html>",
    }, "\n")

    local result = xhtml.convert(source)
    local lines = vim.split(result.text, "\n", { plain = true })

    -- no stray blanks, no <title> text, no stylesheet text
    -- (没有多余空行、没有 <title> 文本、没有样式表文本)
    for index, line in ipairs(lines) do
      falsy(line:find("font-weight", 1, true), "stylesheet text leaked at line " .. index)
    end
    eq(lines[1], "# 版权信息", "the heading survives, unemphasised")
    -- The `<title>` element repeats the same words; leaking it shows up as a
    -- second occurrence.
    -- (<title> 里是同样的文字；若漏出来就会出现第二次)
    eq(select(2, result.text:gsub("版权信息", "")), 1, "the <title> in <head> is skipped")
    -- compact layout: no blanks between paragraphs, but a gap around a heading
    -- and around a rule
    -- (紧凑版式：段间无空行，但标题与分隔线周围各留一行)
    eq(lines, {
      "# 版权信息",
      "",
      "　　书名：某本书",
      "",
      "---",
      "",
      "　　后记",
    })
  end)

  it("parses the chapter's own <style> block", function()
    -- Shape taken from a real chapter (a copyright page): the classes that
    -- matter are defined inline, and the external book sheet says nothing
    -- about them.
    -- (形状取自真实章节（版权页）：关键类定义在行内 style 里，外部书籍样式表没有它们)
    local source = table.concat({
      "<html><head><style type=\"text/css\">",
      ".newCopyRightTitle { font-weight: bold; text-align: center; }",
      ".newContentCR { text-indent: 0; }",
      "</style></head><body>",
      '<h1 class="newCopyRightTitle">版权信息</h1>',
      '<p class="newContentCR">书名：某本书</p>',
      '<p><em>斜体</em>与<strong>加粗</strong></p>',
      "</body></html>",
    }, "\n")

    local result = xhtml.convert(source, { skip_title = false })
    -- the heading stays a heading: markdown headings are already prominent, so
    -- the bold from `.newCopyRightTitle` is deliberately not re-applied
    -- (标题仍是标题：markdown 标题本就突出，因此不把 `.newCopyRightTitle` 的加粗
    --  再套一层)
    truthy(result.text:find("# 版权信息", 1, true), "got: " .. result.text)
    falsy(result.text:find("**版权信息**", 1, true))
    truthy(result.text:find("书名：某本书", 1, true))
    truthy(result.text:find("*斜体*", 1, true))
    truthy(result.text:find("**加粗**", 1, true))
    falsy(result.text:find("**>", 1, true), "no stray markers")

    eq(xhtml.inline_stylesheet(source):find("newCopyRightTitle", 1, true) ~= nil, true)
    eq(xhtml.inline_stylesheet("<p>没有样式块</p>"), "")
  end)

  it("merges the chapter stylesheet over the book stylesheet", function()
    -- Different properties combine, as they do in CSS: both rules apply.
    -- (不同属性会叠加，这与 CSS 一致：两条规则都生效)
    local source = '<style>.x { font-weight: bold }</style><p class="x">文字</p>'
    local result = xhtml.convert(source, { css = ".x { font-style: italic }" })
    truthy(result.text:find("**文字**", 1, true), "chapter rule applied")
    truthy(result.text:find("*文字*", 1, true), "and the book rule still applies")

    -- The same property resolves in the chapter's favour, because `normal`
    -- contributes nothing while `bold` does.
    -- (同一属性以章节为准：`normal` 不贡献任何东西，而 `bold` 会)
    local overridden = xhtml.convert(
      '<style>.y { font-weight: bold }</style><p class="y">文字</p>',
      { css = ".y { font-weight: normal }" }
    )
    truthy(overridden.text:find("**文字**", 1, true), "got: " .. overridden.text)
  end)

  it("drops a chapter title the winbar already shows", function()
    local source = "<h1 class=\"title\">第 3 章&nbsp;宇宙闪烁</h1><p>正文。</p>"
    truthy(xhtml.repeats_title(source, "第 3 章 宇宙闪烁"))
    falsy(xhtml.repeats_title(source, "完全不同的标题"))
    falsy(xhtml.repeats_title(source, nil))

    local skipped = xhtml.convert(source, { skip_title = true })
    eq(lines_of(skipped.text), { "　　正文。" }, "the title is gone")

    local kept = xhtml.convert(source, { skip_title = false })
    eq(lines_of(kept.text), { "# 第 3 章 宇宙闪烁", "", "　　正文。" }, "and kept when asked")

    -- dropping the title must not shift the annotation offsets
    -- (丢掉标题不能让划线偏移错位)
    local offset = rune_offset_of(source, "正文。")
    local resolved = xhtml.resolve(skipped, offset, offset + 3)
    truthy(resolved, "the body still resolves")
  end)

  it("lists items on their own line without indentation", function()
    local result = xhtml.convert("<ul><li>甲</li><li>乙</li></ul>", { paragraph = { compact = true, indent = "　　" } })
    eq(lines_of(result.text), { "- 甲", "- 乙" })
  end)

  it("uses the plugin defaults when no options are passed", function()
    local result = xhtml.convert(paragraphs(2))
    eq(lines_of(result.text), { "　　第 1 段的正文内容。", "　　第 2 段的正文内容。" })
  end)
end)

describe("xhtml.locate", function()
  it("says which character of a paragraph a rune is", function()
    -- Drawing an underline needs the character, not just the line: `resolve`
    -- stops at the paragraph.
    -- (画下划线需要精确到字符，而 resolve 只到段落)
    local source = "<p>" .. string.rep("字", 4) .. "目标" .. string.rep("字", 4) .. "</p>"
    local result = xhtml.convert(source, { paragraph = { indent = "" }, page_width = 20 })
    local located = xhtml.locate(result, rune_offset_of(source, "目标"))
    truthy(located, "the offset locates")
    eq(located.line, 0)
    eq(located.col, 0, "the segment starts the line")
    eq(located.runes, 4, "four characters into the paragraph")
  end)

  it("locates on the wrapped line the rune landed on", function()
    local source = "<p>" .. string.rep("字", 14) .. "目标</p>"
    local result = xhtml.convert(source, { paragraph = { indent = "" }, page_width = 20 })
    local located = xhtml.locate(result, rune_offset_of(source, "目标"))
    eq(located.line, 1, "ten characters per line")
    eq(located.runes, 4, "four characters into the second line")
  end)
end)

describe("xhtml.rune_at", function()
  ---Byte length of the character at `index`, for walking a string by character.
  ---(index 处字符占几个字节，用于按字符遍历字符串)
  local function char_length(text, index)
    local byte = text:byte(index) or 0
    if byte >= 0xF0 then
      return 4
    elseif byte >= 0xE0 then
      return 3
    elseif byte >= 0xC0 then
      return 2
    end
    return 1
  end

  it("is the inverse of locate across wraps and injected spaces", function()
    -- A paragraph with no inner markup: the k-th visible character of the
    -- rendered text is the k-th character of the paragraph, whatever the page
    -- width and the spaces auto spacing inserted.
    -- (没有内层标签的段落：渲染文本里第 k 个可见字符就是段落的第 k 个字符——不论版心多宽、
    --  自动留白插了多少空格)
    local paragraph = string.rep("字", 20) .. "写作O（1）时间"
    local source = "<p>" .. paragraph .. "</p>"
    local result = xhtml.convert(source, { auto_space = true, paragraph = { indent = "" }, page_width = 20 })
    local lines = vim.split(result.text, "\n", { plain = true })
    local offset = rune_offset_of(source, paragraph)
    local seen = 0

    for index, line in ipairs(lines) do
      local byte = 1
      while byte <= #line do
        local length = char_length(line, byte)
        local char = line:sub(byte, byte + length - 1)
        if char ~= " " then
          seen = seen + 1
          local rune = xhtml.rune_at(result, index - 1, byte - 1, line)
          truthy(rune, string.format("line %d col %d maps to a rune", index, byte - 1))
          eq(rune, offset + seen - 1, string.format("character %d of the page is character %d of the paragraph", seen, seen))
          eq(xhtml.locate(result, rune).line, index - 1, "and locate agrees on the line")
        end
        byte = byte + length
      end
    end

    eq(seen, vim.fn.strchars(paragraph), "every character of the paragraph was on the page exactly once")
  end)

  it("answers for the end of a line and refuses off-page columns", function()
    local source = "<p>甲乙丙丁</p>"
    local result = xhtml.convert(source, { paragraph = { indent = "" }, page_width = 20 })
    local line = vim.split(result.text, "\n", { plain = true })[1]
    eq(xhtml.rune_at(result, 0, 0, line), rune_offset_of(source, "甲"))
    eq(xhtml.rune_at(result, 0, #line, line), rune_offset_of(source, "丁") + 1, "one past the last character")
    eq(xhtml.rune_at(result, 9, 0, line), nil, "a line that is not on the page")
  end)
end)

describe("xhtml.convert tables and listings", function()
  ---@param text string
  ---@return string[]
  local function lines_of(text)
    return vim.split(text, "\n", { plain = true })
  end

  it("lays a table out as real lines, boxed, inside the page", function()
    -- A table used to be a markdown pipe table that render-markdown drew over: a
    -- row too wide for the window became virtual lines the cursor could not
    -- reach, and the table spread to the window edge whatever the page width.
    -- (表格原来是交给 render-markdown 盖画的 markdown 管道表格：窗口放不下的行变成光标够不着的
    --  虚拟行，而且不管版心多宽，表格都撑到窗口边上)
    local source = table.concat({
      "<table><thead>",
      "<tr><th><p>维度</p></th><th><p>用户界面</p></th></tr>",
      "</thead><tbody>",
      "<tr><td><p>交互模式</p></td><td><p>终端 TUI</p></td></tr>",
      "</tbody></table>",
    })
    local result = xhtml.convert(source, { page_width = 40, paragraph = { indent = "　　" }, gap = "compact" })
    local lines = lines_of(result.text)
    local body = {}
    for _, line in ipairs(lines) do
      if line:find("[│┌├└]") then
        body[#body + 1] = line
      end
    end
    eq(body, {
      "┌──────────┬──────────┐",
      "│ 维度     │ 用户界面 │",
      "├──────────┼──────────┤",
      "│ 交互模式 │ 终端 TUI │",
      "└──────────┴──────────┘",
    })
    falsy(result.text:find("| ---", 1, true), "no markdown pipe table left")
  end)

  it("folds a wide table into the page width, never past it", function()
    local cells = {}
    for i = 1, 6 do
      cells[i] = string.format("<td><p>单元格%d的内容比较长需要折行</p></td>", i)
    end
    local source = "<table><tbody><tr>" .. table.concat(cells) .. "</tr><tr>" .. table.concat(cells) .. "</tr></tbody></table>"
    for _, width in ipairs({ 40, 52, 80 }) do
      local lines = lines_of(xhtml.convert(source, { page_width = width, paragraph = { indent = "" } }).text)
      local rows = 0
      for _, line in ipairs(lines) do
        if line:find("[│┌├└]") then
          rows = rows + 1
          truthy(vim.api.nvim_strwidth(line) <= width, string.format("%d wide page: %q is %d", width, line, vim.api.nvim_strwidth(line)))
        end
      end
      truthy(rows > 5, "the rows fold over several lines")
    end
  end)

  it("maps every character of a cell back to its source rune", function()
    local source = table.concat({
      "<p>前文。</p>",
      "<table><tr><th>Category</th><th>Description</th></tr>",
      "<tr><td><p>Logs</p></td><td><p>Another type of monitoring data that comes from Kafka itself.</p></td></tr>",
      "<tr><td>中文</td><td><b>加粗</b>与普通的文字</td></tr></table>",
      "<p>后文。</p>",
    })
    local result = xhtml.convert(source, { page_width = 30, paragraph = { indent = "" } })
    local lines = lines_of(result.text)
    local runes = vim.fn.split(source, "\\zs")
    local seen = {}
    for _, segment in ipairs(result.map) do
      local text = lines[segment.line + 1]:sub(segment.col_from + 1, segment.col_to)
      eq(text, table.concat(runes, "", segment.src_from + 1, segment.src_to), "segment " .. segment.line)
      seen[text] = true
    end
    truthy(seen["Logs"], "cell text is in the offset map")
    -- a highlight across a folded cell resolves onto the cell's own lines
    -- (跨折行单元格的划线落在这一格自己的几行上)
    local from = vim.fn.strchars(source:sub(1, (source:find("Another", 1, true)) - 1))
    local start = xhtml.locate(result, from)
    truthy(start and lines[start.line + 1]:find("Another", 1, true), "Another is located on its line")
    -- the header text and the rules get their own styles
    -- (表头文字与边框线各有样式)
    local kinds = {}
    for _, style in ipairs(result.styles) do
      kinds[style.kind] = true
    end
    truthy(kinds.head and kinds.rule and kinds.bold, "head, rule and the cell's own bold")
  end)

  it("keeps a footnote mark inside a cell", function()
    local source = '<table><tr><td>说明<img class="qqreader-footnote" alt="注释内容" src="x.png"/></td><td>值</td></tr></table>'
    local result = xhtml.convert(source, { page_width = 40, paragraph = { indent = "" } })
    eq(#result.footnotes, 1)
    local note = result.footnotes[1]
    local line = lines_of(result.text)[note.line + 1]
    truthy(line:sub(note.col_from + 1, note.col_to):find("%[1%]") or line:sub(note.col_from + 1, note.col_to):find("①"), "the mark is where the footnote says")
    eq(note.text, "注释内容")
  end)

  it("squeezes many columns into a narrow page", function()
    local cells = {}
    for i = 1, 7 do
      cells[i] = "<td>abcd</td>"
    end
    local result = xhtml.convert("<table><tr>" .. table.concat(cells) .. "</tr></table>", { page_width = 20, paragraph = { indent = "" } })
    local lines = lines_of(result.text)
    for _, range in ipairs(result.tables) do
      for line = range[1], range[2] do
        truthy(vim.api.nvim_strwidth(lines[line + 1]) <= 20, lines[line + 1])
      end
    end
  end)

  it("puts cells under the right column across rowspan and colspan", function()
    local source = '<table><tr><td rowspan="2">R</td><td>x</td></tr><tr><td>y</td></tr><tr><td colspan="2">wide</td></tr></table>'
    local lines = lines_of(xhtml.convert(source, { page_width = 40, paragraph = { indent = "" } }).text)
    local rows = {}
    for _, line in ipairs(lines) do
      if line:find("^│") then
        rows[#rows + 1] = line
      end
    end
    matches(rows[2], "^│%s+│ y │$", "y in the second column, under x")
  end)

  it("records table lines, so a code listing drawing a tree is not one", function()
    local source = "<pre>project/\n├── .mcp.json   # MCP\n└── src</pre><table><tr><td>a</td></tr></table>"
    local result = xhtml.convert(source, { page_width = 40, paragraph = { indent = "" } })
    local lines = lines_of(result.text)
    local table_module = require("weread.xhtml_table")
    for index, line in ipairs(lines) do
      if line:find("mcp.json", 1, true) then
        falsy(table_module.is_line(result, index - 1), "the listing is not a table")
      end
      if line:find("│ a │", 1, true) then
        truthy(table_module.is_line(result, index - 1), "the table is")
      end
    end
    eq(require("weread.annotations_model").plain_text("├── .mcp.json   # MCP"), "├── .mcp.json   # MCP", "plain text keeps it")
  end)

  it("does not count the tags inside a translation block", function()
    -- the same translation without the tag inside it: offsets must not differ
    -- (同样的译文、里面不带那个标签：偏移不能有差别)
    local function bilingual(source)
      return xhtml.convert(source, { page_width = 40, translations = xhtml.translation_ranges(source) })
    end
    local plain = xhtml.convert("<p>One</p><p>Two</p>", { page_width = 40 })
    local translated = bilingual('<p>One</p>\n<p class="wr-translation">用<meta name="r" content="o"> 标签</p><p>Two</p>')
    local function rune_of(result, word)
      for _, segment in ipairs(result.map) do
        local line = lines_of(result.text)[segment.line + 1]
        if line:sub(segment.col_from + 1, segment.col_to):find(word, 1, true) then
          return segment.src_from
        end
      end
    end
    eq(rune_of(translated, "Two"), rune_of(plain, "Two"), "Two keeps its offset")
  end)

  it("reads the language of a listing off its text", function()
    -- A fence without a language gets no syntax highlighting, and books do not
    -- label their listings. The guess is timid on purpose: prose must stay
    -- monochrome rather than wear the colours of a language it is not.
    -- (没有语言的围栏不会得到语法高亮，而书里不标语言。判断刻意保守：散文必须保持单色，
    --  而不是穿上它并不属于的那种语言的颜色)
    local cases = {
      { "# 最基本的Headless模式调用\nclaude -p \"分析src/目录的安全漏洞\"\n", "bash" },
      { "$ runlevel\nN 3\n", "bash" },
      { "#!/bin/bash\nexport API_KEY=xxx\nnpm install --save-dev typescript\n", "bash" },
      { "def main():\n    import os\n    print(os.getcwd())\n\nclass Foo:\n    pass\n", "python" },
      { "local ok, err = pcall(function()\n  return require(\"weread.xhtml\")\nend)\n", "lua" },
      { 'const x = 1\nfunction go() {\n  return x => x + 1\n}\n', "javascript" },
      { '{ "model": "claude-sonnet-4-5", "max_tokens": 4096 }', "json" },
      { "# 项目说明\n## 技术栈\n- Vue 3\n- TypeScript\n", "markdown" },
      { "---\nname: api-doc-generator\ndescription: 生成 API 文档\n---\n", "yaml" },
      { "<div class=\"note\">\n  <p>hello</p>\n</div>\n", "html" },
      -- and the ones that must stay plain: a page of Chinese with YAML colours
      -- on it looks like a rendering bug
      -- (以及必须保持素净的：一整页中文套上 YAML 配色看起来就像渲染坏了)
      { "应该触发的测试用例：\n以及不应该触发的测试用例：\n", nil },
      { "api-doc-generator/             ← Skill 名称（kebab-case）\n├── SKILL.md\n└── scripts/\n", nil },
      { "[功能定义]（做什么）+[触发场景]（何时用）\n", nil },
      { "Bash(git:*)               # 允许所有以git开头的命令\n", nil },
    }
    for _, case in ipairs(cases) do
      eq(xhtml.language_of(case[1]), case[2], "listing " .. vim.inspect(case[1]:sub(1, 24)))
    end
  end)

  it("keeps a listing bare when its language is not knowable", function()
    -- (判断不出语言时围栏保持空白)
    local source = "<pre>应该触发的测试用例：\n以及不应该触发的测试用例：</pre>"
    local text = xhtml.convert(source, { paragraph = { indent = "" } }).text
    truthy(text:find("```\n", 1, true), "the fence is bare: " .. text)
    eq(text:find("```[%a]", 1), nil, "and carries no language")
  end)

  it("takes the language from the class attribute when the book writes one", function()
    -- (书里写了语言时以 class 为准)
    local source = '<pre class="language-python">print(1)</pre>'
    local result = xhtml.convert(source, { paragraph = { indent = "" } }).text
    truthy(result:find("```python", 1, true), "the class wins: " .. result)
  end)

  it("keeps the line breaks and indentation of a listing", function()
    -- A code listing is not prose: collapsing it into one line loses its meaning.
    -- (代码清单不是散文：压成一行会让它失去意义)
    local source = "<p>正文</p><pre>claude -p \"x\"\n  claude --print \"x\"</pre><p>后文</p>"
    local result = xhtml.convert(source, { paragraph = { indent = "　　" }, gap = "compact" })
    eq(lines_of(result.text), {
      "　　正文",
      "",
      -- the fence names the language it guessed, or nothing downstream colours it
      -- (围栏写出它猜到的语言，否则后续步骤不会给它上色)
      "```bash",
      'claude -p "x"',
      '  claude --print "x"',
      "```",
      "",
      "　　后文",
    })
  end)

  it("reads CRLF as a line ending, not as a character", function()
    -- Books ship listings with Windows line endings; a page full of `^M` is what
    -- that looks like when it is not normalised.
    -- (书里的清单用 Windows 换行；不归一化的话页面上全是 `^M`)
    local result = xhtml.convert("<pre>one\r\ntwo\r\n</pre>", { paragraph = { indent = "" } })
    eq(result.text, "```\none\ntwo\n```", "no carriage returns survive")
  end)

  it("keeps a code line whole across inline tags", function()
    -- the end of a text node is where a tag starts, not where a line ends
    -- (文本节点的结尾是标签开始的地方，不是一行结束的地方)
    local result = xhtml.convert("<pre>x = <b>1</b>\ny = 2</pre>", { paragraph = { indent = "" } })
    eq(vim.split(result.text, "\n", { plain = true }), { "```toml", "x = **1**", "y = 2", "```" })
  end)

  it("does not space out a listing the way it spaces out prose", function()
    -- The Chinese/Latin spacing rule must not touch code: `对10` is an identifier,
    -- not a sentence.
    -- (中西文留白规则不能碰代码：`对10` 是标识符，不是句子)
    local result = xhtml.convert("<pre>对10个</pre>", { auto_space = true, paragraph = { indent = "" } })
    eq(result.text, "```\n对10个\n```")
  end)
end)

describe("xhtml offset map with entities and CRLF", function()
  ---Every segment's characters are its source runes one for one, or a single
  ---character standing for an entity.
  ---(每个段落的字符与源 rune 一一对应，或是代表一个实体的单个字符)
  local function assert_segments(source, result)
    local lines = vim.split(result.text, "\n", { plain = true })
    local runes = vim.fn.split(source, "\\zs")
    for _, segment in ipairs(result.map) do
      local rendered = lines[segment.line + 1]:sub(segment.col_from + 1, segment.col_to)
      local slice = table.concat(runes, "", segment.src_from + 1, segment.src_to)
      if segment.atom then
        eq(xhtml.decode_entities(slice), rendered, "entity segment " .. slice)
      else
        eq(rendered, slice)
      end
    end
  end

  ---Select `needle` on the page, turn it into runes and back.
  ---(在页面上选中 needle，转成 rune 再转回来)
  local function round_trip(source, result, needle, expected_source)
    local lines = vim.split(result.text, "\n", { plain = true })
    for index, line in ipairs(lines) do
      local col = line:find(needle, 1, true)
      if col then
        local from = xhtml.rune_at(result, index - 1, col - 1, line)
        local to = xhtml.rune_at(result, index - 1, col - 1 + #needle, line)
        local runes = vim.fn.split(source, "\\zs")
        eq(table.concat(runes, "", from + 1, to), expected_source or needle, "the selection names its source")
        local start, finish = xhtml.resolve(result, from, to)
        eq(start.line, index - 1)
        eq(finish.line, index - 1)
        local located = xhtml.locate(result, from)
        eq(located.line, index - 1)
        local col_at = located.col
        for _ = 1, located.runes do
          col_at = col_at + #vim.fn.strcharpart(line:sub(col_at + 1), 0, 1)
        end
        eq(col_at, col - 1, "locate lands on the first selected character")
        return
      end
    end
    error("not on the page: " .. needle)
  end

  it("keeps runes aligned after an entity in body text", function()
    local source = "<p>非常感谢John Wiley &amp;amp; Sons出色的出版团队为本书做出的突出贡献。</p>"
    local result = xhtml.convert(source, { auto_space = true, paragraph = { indent = "" }, page_width = 30 })
    assert_segments(source, result)
    round_trip(source, result, "出版团队")
    round_trip(source, result, "Sons")
    round_trip(source, result, "&amp; Sons", "&amp;amp; Sons")
  end)

  it("keeps runes aligned after an entity in a listing", function()
    local source = "<pre>if a &lt; b &amp;&amp; c:\n    return done</pre>"
    local result = xhtml.convert(source, { paragraph = { indent = "" } })
    assert_segments(source, result)
    round_trip(source, result, "c:")
    round_trip(source, result, "return done")
  end)

  it("does not drift a rune per CRLF line in a listing", function()
    local source = "<pre>one\r\ntwo\r\nthree\r\nfour</pre>"
    local result = xhtml.convert(source, { paragraph = { indent = "" } })
    assert_segments(source, result)
    round_trip(source, result, "four")
    round_trip(source, result, "three")
  end)

  it("moves the source along with a stripped leading space", function()
    local source = "<p>  \n   正文开头</p>"
    local result = xhtml.convert(source, { paragraph = { indent = "" } })
    assert_segments(source, result)
    round_trip(source, result, "正文")
  end)
end)

describe("xhtml.convert page layout", function()
  ---@param text string
  ---@return string[] lines
  local function lines_of(text)
    return vim.split(text, "\n", { plain = true })
  end

  ---No indent, so a test only has to think about the page width.
  ---(去掉缩进，测试只需关心版心宽度)
  local function page(source, width)
    return xhtml.convert(source, { page_width = width, paragraph = { indent = "" } })
  end

  it("leaves long paragraphs on a single line until a page width is given", function()
    local source = "<p>" .. string.rep("字", 30) .. "</p>"
    eq(#lines_of(xhtml.convert(source).text), 1, "no width: one paragraph, one line")
    eq(#lines_of(page(source, 0).text), 1, "width 0 means the same thing")

    local wrapped = lines_of(page(source, 20).text)
    eq(#wrapped, 3, "30 full width characters at 20 cells are three lines")
    eq(wrapped[1], string.rep("字", 10))
    eq(wrapped[3], string.rep("字", 10))
    eq(wrapped[1] .. wrapped[2] .. wrapped[3], string.rep("字", 30), "nothing is lost or added")
  end)

  it("counts a full width character as two cells", function()
    local wrapped = lines_of(page("<p>" .. string.rep("字", 6) .. "ab</p>", 12).text)
    eq(wrapped, { string.rep("字", 6), "ab" })
  end)

  it("hangs closing punctuation rather than opening a line with it", function()
    -- 20 cells of text, then `。`: it is not allowed to start a line, so it
    -- sticks out instead of being pushed down.
    -- (20 单元格正文后跟 `。`：它不能起行，因此宁可由格也不下移)
    local wrapped = lines_of(page("<p>" .. string.rep("字", 10) .. "。</p>", 20).text)
    eq(wrapped, { string.rep("字", 10) .. "。" })
  end)

  it("carries an opening bracket onto the next line", function()
    local wrapped = lines_of(page("<p>" .. string.rep("字", 9) .. "（甲</p>", 20).text)
    eq(wrapped, { string.rep("字", 9), "（甲" })
  end)

  it("does not let concealed markers eat into the page width", function()
    -- `*` are hidden by the reader, so the line is still a full page wide
    -- (`*` 由阅读器隐藏，因此这一行依然占满整个版心)
    local wrapped = lines_of(page("<p><em>" .. string.rep("字", 10) .. "</em></p>", 20).text)
    eq(wrapped, { "*" .. string.rep("字", 10) .. "*" })
  end)

  it("splits a style that spans a wrap instead of dropping it", function()
    local wrapped = page("<p><b>" .. string.rep("字", 30) .. "</b></p>", 20)
    eq(lines_of(wrapped.text), {
      "**" .. string.rep("字", 10) .. "**",
      "**" .. string.rep("字", 10) .. "**",
      "**" .. string.rep("字", 10) .. "**",
    })
    eq(#wrapped.styles, 3, "one drawable span per line")
    eq(wrapped.styles[1].line, 0)
    eq(wrapped.styles[1].col_from, 2, "the span starts after its opening marker")
    eq(wrapped.styles[2].line, 1)
    eq(wrapped.styles[2].col_from, 2, "and so does a span reopened on a wrapped line")
    eq(wrapped.styles[3].line, 2)
  end)

  it("indents only the first line of a wrapped paragraph", function()
    -- The indent is two full width spaces, which is four cells of the page: the
    -- first line therefore holds two characters fewer than the rest.
    -- (缩进是两个全角空格，占版心四格：首行因此比其余行少放两个汉字)
    local wrapped = lines_of(
      xhtml.convert("<p>" .. string.rep("字", 14) .. "</p>", { page_width = 20, paragraph = { indent = "　　" } }).text
    )
    eq(wrapped[1], "　　" .. string.rep("字", 8), "the indent costs four cells")
    eq(wrapped[2], string.rep("字", 6), "the continuation starts flush with the margin")
  end)

  it("resolves a source offset onto the line it wrapped onto", function()
    local source = "<p>" .. string.rep("字", 11) .. "目标</p>"
    local wrapped = page(source, 20)
    local offset = rune_offset_of(source, "目标")
    local start = xhtml.resolve(wrapped, offset, offset + 2)
    truthy(start, "the offset resolves")
    eq(start.line, 1, "ten characters per line put it on the second one")
    eq(start.col, 0, "the segment starts where the eleventh character does")
  end)

  it("keeps the page width out of the way when it is not configured", function()
    -- The reader passes a width, everything else (fixtures, tests, other
    -- callers) must keep getting the paragraph-per-line output.
    -- (阅读器会传宽度，其它调用方（夹具、测试、别的调用）必须继续得到「一段一行」的输出)
    eq(xhtml.convert("<p>甲</p><p>乙</p>").page_width, 0)
    eq(page("<p>甲</p>", 20).page_width, 20)
  end)
end)

describe("xhtml.convert typesetting from the book stylesheet", function()
  ---@param text string
  ---@return string[] lines
  local function lines_of(text)
    return vim.split(text, "\n", { plain = true })
  end

  ---@param selector string
  ---@param declarations string
  ---@return weread.xhtml.Result
  local function with_class(selector, declarations, source)
    return xhtml.convert(source, { css = selector .. " { " .. declarations .. " }", paragraph = { indent = "　　" } })
  end

  it("centres a line the book centred, and reports how wide it is", function()
    local result = with_class(".content_center", "text-align: center", '<p class="content_center">甲</p>')
    local meta = result.lines[0]
    truthy(meta, "the line carries display attributes")
    eq(meta.align, "center")
    eq(meta.cells, 2, "one full width character is two cells")
    eq(result.lines[1], nil, "only lines that need padding are reported")
  end)

  it("centres the obsolete <center> tag too", function()
    local result = xhtml.convert("<center>甲</center>", { paragraph = { indent = "　　" } })
    eq(result.lines[0].align, "center")
  end)

  it("right aligns a line the book right aligned", function()
    local result = with_class(".content_right", "text-align: right", '<p class="content_right">甲</p>')
    eq(result.lines[0].align, "right")
  end)

  it("leaves justified and left aligned text alone", function()
    local result = with_class(".content", "text-align: justify", '<p class="content">甲</p>')
    eq(result.lines[0], nil, "justify is how a book sets its body text")
    local plain = with_class(".content_left", "text-align: left", '<p class="content_left">甲</p>')
    eq(plain.lines[0], nil)
  end)

  it("insets small print and marks it for the reader", function()
    local result = xhtml.convert("<p class=\"footnote\">甲甲乙乙</p>", {
      css = ".footnote { font-size: 0.75em }",
      paragraph = { indent = "　　", gap = "compact" },
      page_width = 20,
    })
    local lines = lines_of(result.text)
    eq(result.lines[0].small, true, "the reader dims it")
    eq(lines[1], "　　　甲甲乙乙", "inset by two cells, then the paragraph indent")
  end)

  it("keeps an inset block inset on every line", function()
    local result = xhtml.convert("<p class=\"quote\">" .. string.rep("字", 12) .. "</p>", {
      css = ".quote { padding-left: 2em; padding-right: 2em }",
      paragraph = { indent = "" },
      page_width = 20,
    })
    for _, line in ipairs(lines_of(result.text)) do
      truthy(vim.startswith(line, "　　"), "four cells of inset: [" .. line .. "]")
      falsy(line:find("^ "), "and no ASCII space, four of which make a code block")
      truthy(vim.fn.strdisplaywidth(line) <= 20, "and the page width still holds")
    end
  end)

  it("reads text-indent from the stylesheet", function()
    local none = with_class(".content_left", "text-indent: 0", '<p class="content_left">甲</p>')
    eq(none.text, "甲", "the book asked for no indent")

    local two_em = with_class(".content", "text-indent: 2em", '<p class="content">甲</p>')
    eq(two_em.text, "　　甲", "2em is one Chinese character per em")

    local one_em = with_class(".content", "text-indent: 1em", '<p class="content">甲</p>')
    eq(one_em.text, "　甲")
  end)

  it("inherits padding from the block around a paragraph", function()
    local result = xhtml.convert(
      '<div class="reference"><p class="content">甲甲乙乙</p></div>',
      {
        css = ".reference { padding-left: 2em; padding-right: 2em }",
        paragraph = { indent = "　　" },
        page_width = 24,
      }
    )
    local lines = lines_of(result.text)
    eq(lines[1], "　　　　甲甲乙乙", "the div's padding reaches the paragraph inside")
  end)

  it("marks a block the book painted in a real colour", function()
    local colored = with_class(".sect2", "color: #c36500", '<p class="sect2">甲</p>')
    eq(colored.lines[0].accent, true)

    local ink = with_class(".content", "color: #000000", '<p class="content">甲</p>')
    eq(ink.lines[0], nil, "black on paper is not a colour worth drawing")
  end)

  it("adds the space the app adds between Chinese and Latin", function()
    local spaced = xhtml.convert("<p>对10个数字</p>", { auto_space = true, paragraph = { indent = "" } })
    eq(spaced.text, "对 10 个数字")
  end)

  it("does not double a space the book already wrote", function()
    local result = xhtml.convert("<p>1，000 条记录</p>", { auto_space = true, paragraph = { indent = "" } })
    eq(result.text, "1，000 条记录")
  end)

  it("counts the automatic space when a Latin word decides whether it fits", function()
    -- 7 Chinese characters (14 cells) + space + `abcd` is 19 cells and fits in 22;
    -- with the indent it no longer does, and the word moves whole
    -- (7 个汉字 14 格 + 空格 + `abcd` 共 19 格，22 放得下；加上缩进就放不下，整词挪走)
    local fits = xhtml.convert("<p>中中中中中中中abcd</p>", { auto_space = true, paragraph = { indent = "" }, page_width = 22 })
    eq(fits.text, "中中中中中中中 abcd")
    local moves = xhtml.convert("<p>中中中中中中中abcd</p>", { auto_space = true, paragraph = { indent = "　　" }, page_width = 22 })
    eq(moves.text, "　　中中中中中中中\nabcd", "the word is not split as abc / d")
  end)

  it("leaves punctuation out of the Chinese/Latin rule", function()
    local result = xhtml.convert("<p>写作O（1）时间</p>", { auto_space = true, paragraph = { indent = "" } })
    eq(result.text, "写作 O（1）时间")
  end)

  it("keeps auto spacing off unless it is asked for", function()
    eq(xhtml.convert("<p>对10个数字</p>", { paragraph = { indent = "" } }).text, "对10个数字")
  end)

  it("carries a space across a style boundary", function()
    -- `*n*个` is Latin `n` next to Chinese `个`: the space goes after the closing
    -- marker, so the reader sees `n 个`(从 `*n*个` 到 `n 个`：空格落在闭合标记之后)
    local result = xhtml.convert("<p>对 <em>n</em>个</p>", { auto_space = true, paragraph = { indent = "" } })
    eq(result.text, "对 *n* 个")
  end)
end)

describe("xhtml.convert justification", function()
  ---@param text string
  ---@return string[]
  local function lines_of(text)
    return vim.split(text, "\n", { plain = true })
  end

  ---Character before / after a 0-based byte column of a line.
  ---(某行 0 基字节列前后的字符)
  local function around(line, col)
    local before = vim.fn.strcharpart(line:sub(1, col), vim.fn.strchars(line:sub(1, col)) - 1)
    local after = vim.fn.strcharpart(line:sub(col + 1), 0, 1)
    return before, after
  end

  local function convert(source, width, extra)
    return xhtml.convert(source, vim.tbl_extend("force", {
      page_width = width,
      auto_space = true,
      paragraph = { indent = "" },
    }, extra or {}))
  end

  it("fills a wrapped line to the page width, and only a wrapped line", function()
    -- eleven characters, then a Latin word too long to share the line: 4 cells left
    -- (十一个汉字之后是一个放不下的拉丁词：剩 4 格)
    local result = convert("<p>甲乙丙丁戊己庚辛壬癸子abcdefghijklmnop</p>", 26)
    local lines = lines_of(result.text)
    eq(lines[1], "甲乙丙丁戊己庚辛壬癸子", "the text itself is unchanged")
    local meta = result.lines[0]
    truthy(meta and meta.fill, "the wrapped line is justified")
    local total = 0
    for _, gap in ipairs(meta.fill) do
      eq(gap.cells, 1, "one cell per gap while there are gaps enough")
      total = total + gap.cells
    end
    eq(meta.cells + total, 26, "the line now reaches the margin")
    eq(result.lines[1], nil, "the last line of a paragraph stays ragged")
  end)

  it("leaves a line alone when it is at most one cell short", function()
    -- a 20 cell page of Chinese text is exactly full on every wrapped line
    -- (20 格的纯中文版心，每个折行都正好满)
    local result = convert("<p>" .. string.rep("字", 30) .. "</p>", 20)
    eq(next(result.lines), nil, "nothing to fill")
    local odd = convert("<p>" .. string.rep("字", 30) .. "</p>", 21)
    eq(next(odd.lines), nil, "one spare cell is not worth a gap")
  end)

  it("prefers spaces and mid-sentence punctuation, and respects kinsoku", function()
    local source = "<p>甲乙，丙丁（戊）己 x 庚辛。壬abcdefghijklmnopqrst</p>"
    local result = convert(source, 32)
    local line = lines_of(result.text)[1]
    local meta = result.lines[0]
    truthy(meta and meta.fill, "justified: " .. line)
    local cols = {}
    for _, gap in ipairs(meta.fill) do
      cols[gap.col] = true
      local before, after = around(line, gap.col)
      truthy(before ~= "（", "never after an opening bracket")
      truthy(after ~= "）" and after ~= "。" and after ~= "，", "never before closing punctuation")
      truthy(after ~= " ", "never before a space")
    end
    truthy(cols[#"甲乙，"], "after the comma")
    truthy(cols[#"甲乙，丙丁（戊）己 "], "after the space the book wrote")
  end)

  it("never opens a gap next to a concealed marker or inside the indent", function()
    local source = "<p>甲乙<b>丙丁</b>戊己庚辛壬abcdefghijklmnopqrst</p>"
    local result = xhtml.convert(source, { page_width = 28, auto_space = true, paragraph = { indent = "　　" } })
    local line = lines_of(result.text)[1]
    local meta = result.lines[0]
    truthy(meta and meta.fill, "justified: " .. line)
    for _, gap in ipairs(meta.fill) do
      truthy(gap.col > #"　　", "not inside the indent")
      local before, after = around(line, gap.col)
      truthy(before ~= "*" and after ~= "*", "not beside `**`: " .. gap.col)
    end
  end)

  it("does not move a single segment of the offset map", function()
    local source = "<p>甲乙，丙丁 x 戊己庚辛壬abcdefghijklmnopqrst后文</p><p>第二段</p>"
    local justified = convert(source, 30)
    local ragged = convert(source, 30, { justify = false })
    truthy(next(justified.lines), "something was justified")
    eq(next(ragged.lines), nil)
    eq(justified.text, ragged.text, "the text is identical")
    eq(justified.map, ragged.map, "and so is the map")
  end)

  it("serialises the fill with the rest of the line attributes", function()
    local result = convert("<p>甲乙丙丁戊己庚辛壬癸子abcdefghijklmnop</p>", 26)
    local decoded = vim.json.decode(vim.json.encode(xhtml.json_lines(result.lines)))
    eq(#decoded["0"].fill, #result.lines[0].fill)
    eq(decoded["0"].cells, result.lines[0].cells)
  end)
end)

describe("xhtml.convert chapter opening page", function()
  local source = "<h1>第一章</h1><p>甲乙丙丁戊己，庚辛壬癸。</p><p>子丑寅卯</p>"

  it("sets the title on a page of its own, outside the offset map", function()
    local result = xhtml.convert(source, { page_width = 20, title = "第一章", skip_title = true, paragraph = { indent = "" } })
    local lines = vim.split(result.text, "\n", { plain = true })
    eq(lines[1], "")
    eq(lines[2], "")
    eq(lines[3], "# 第一章")
    eq(lines[4], "")
    -- 庚辛壬 | 癸。 would leave 癸 alone: 壬 goes along(「癸。」会孤立，「壬」一起下去)
    eq(lines[5], "甲乙丙丁戊己，庚辛", "the book's own copy of the title is still dropped")
    eq(lines[6], "壬癸。", "and the last line is not a lone character")
    eq(result.headings[1], { line = 2, level = 1, title = true })
    eq(#result.headings, 1)
    eq(result.lines[2].align, "center")
    eq(result.lines[2].accent, true)
    for _, segment in ipairs(result.map) do
      truthy(segment.line > 3, "no segment points into the opening page")
    end
  end)

  it("shifts lines but resolves every offset to the same text", function()
    local plain = xhtml.convert(source, { page_width = 20, skip_title = true, paragraph = { indent = "" } })
    local titled = xhtml.convert(source, { page_width = 20, title = "第一章", skip_title = true, paragraph = { indent = "" } })
    local shift = 4
    eq(#titled.map, #plain.map)
    for index, segment in ipairs(plain.map) do
      local other = titled.map[index]
      eq(other.line, segment.line + shift)
      eq({ other.src_from, other.src_to, other.col_from, other.col_to }, { segment.src_from, segment.src_to, segment.col_from, segment.col_to })
    end
    local offset = rune_offset_of(source, "庚辛")
    local a = xhtml.resolve(plain, offset, offset + 2)
    local b = xhtml.resolve(titled, offset, offset + 2)
    eq(b.line, a.line + shift)
    eq(b.col, a.col)
    local plain_lines = vim.split(plain.text, "\n", { plain = true })
    local titled_lines = vim.split(titled.text, "\n", { plain = true })
    eq(xhtml.rune_at(titled, a.line + shift, 3, titled_lines[a.line + shift + 1]), xhtml.rune_at(plain, a.line, 3, plain_lines[a.line + 1]))
  end)

  it("adds nothing without a page width or a title", function()
    eq(xhtml.convert("<p>甲</p>", { title = "标题", paragraph = { indent = "" } }).text, "甲")
    eq(xhtml.convert("<p>甲</p>", { page_width = 20, title = "  ", paragraph = { indent = "" } }).text, "甲")
  end)

  it("centres a level one heading on the page", function()
    local result = xhtml.convert("<h1>标题</h1><h2>小节</h2><p>甲</p>", { page_width = 20, paragraph = { indent = "" } })
    local first, second = result.headings[1], result.headings[2]
    eq(result.lines[first.line].align, "center")
    eq(result.lines[first.line].cells, 4 + vim.fn.strdisplaywidth(xhtml.HEADING_ICONS[1]), "the concealed `# ` costs nothing, its icon does")
    eq(result.lines[second.line], nil, "a section heading stays flush left")
    local unpaged = xhtml.convert("<h1>标题</h1>", { paragraph = { indent = "" } })
    eq(unpaged.lines[0], nil, "no page, no centring")
  end)
end)

describe("xhtml.convert footnotes", function()
  local NOTE = '<img class="qqreader-footnote" src="../Images/note.png" alt="注释 &amp; 说明"/>'

  it("turns a footnote image into an inline mark, not a figure", function()
    local source = "<p>甲乙丙" .. NOTE .. "丁戊。</p>"
    local result = xhtml.convert(source, { page_width = 20, paragraph = { indent = "" } })
    eq(#result.images, 0, "a footnote is not a figure")
    eq(result.text, "甲乙丙[1]丁戊。", "the mark sits in the running text")
    eq(#result.footnotes, 1)
    local note = result.footnotes[1]
    eq(note.text, "注释 & 说明")
    eq(note.line, 0)
    eq(result.text:sub(note.col_from + 1, note.col_to), "[1]")
  end)

  it("keeps the surrounding text exactly where the map says it is", function()
    local source = "<p>甲乙丙" .. NOTE .. "丁戊。</p>"
    local result = xhtml.convert(source, { page_width = 20, paragraph = { indent = "" } })
    local line = vim.split(result.text, "\n", { plain = true })[1]
    eq(xhtml.rune_at(result, 0, 0, line), rune_offset_of(source, "甲"))
    eq(xhtml.rune_at(result, 0, #"甲乙丙[1]", line), rune_offset_of(source, "丁"), "the mark is skipped, not counted")
    local start = xhtml.resolve(result, rune_offset_of(source, "丁"), rune_offset_of(source, "丁") + 1)
    eq(start.col, #"甲乙丙[1]")
    for _, segment in ipairs(result.map) do
      local text = line:sub(segment.col_from + 1, segment.col_to)
      eq(text:find("[1]", 1, true), nil, "no segment contains the mark")
    end
  end)

  it("never starts a line with a mark", function()
    local source = "<p>" .. string.rep("字", 10) .. NOTE .. "后文</p>"
    local result = xhtml.convert(source, { page_width = 20, paragraph = { indent = "" } })
    local lines = vim.split(result.text, "\n", { plain = true })
    eq(lines[1], string.rep("字", 10) .. "[1]", "the mark hangs on the full line")
    local note = result.footnotes[1]
    eq(note.line, 0)
    eq(lines[1]:sub(note.col_from + 1, note.col_to), "[1]")
  end)

  it("numbers marks through the chapter", function()
    local result = xhtml.convert("<p>甲" .. NOTE .. "乙" .. NOTE .. "</p>", { paragraph = { indent = "" } })
    eq(result.text, "甲[1]乙[2]")
    eq(#result.footnotes, 2)
  end)

  it("resolves a footnote link by the id of its note", function()
    local source = table.concat({
      '<p>正文<a class="footnote_quote" href="#footnote_content_1" id="footnote_quote_1">[1]</a>后文</p>',
      '<p class="footnote_content" id="note-1"><a href="#footnote_quote_1" id="footnote_content_1">[1]</a>这是注释。</p>',
    })
    local result = xhtml.convert(source, { paragraph = { indent = "" } })
    eq(#result.footnotes, 1)
    local note = result.footnotes[1]
    eq(note.ref, "footnote_content_1")
    eq(note.text, "这是注释。", "the back-link number is not part of the note")
    local line = vim.split(result.text, "\n", { plain = true })[note.line + 1]
    eq(line:sub(note.col_from + 1, note.col_to), "[1]")
  end)

  it("finds the footnote under the cursor or nearest on the line", function()
    local notes = {
      { line = 0, col_from = 3, col_to = 6, text = "a" },
      { line = 0, col_from = 20, col_to = 23, text = "b" },
      { line = 2, col_from = 0, col_to = 3, text = "c" },
    }
    eq(xhtml.footnote_at(notes, 0, 4).text, "a")
    eq(xhtml.footnote_at(notes, 0, 18).text, "b", "nearest one")
    eq(xhtml.footnote_at(notes, 0, 0).text, "a")
    eq(xhtml.footnote_at(notes, 1, 0), nil, "nothing on that line")
    eq(xhtml.footnote_at(nil, 0, 0), nil)
  end)
end)

describe("xhtml.convert wrap fixes", function()
  local function lines_of(text)
    return vim.split(text, "\n", { plain = true })
  end
  local function page(source, width)
    return xhtml.convert(source, { page_width = width, paragraph = { indent = "" } })
  end

  ---Every segment's text is the source text it claims, rune for rune.
  ---(每个段落的文字都与它声称的源文字逐 rune 一致)
  local function assert_map_exact(source, result)
    local runes = vim.fn.split(source, "\\zs")
    local lines = lines_of(result.text)
    for _, segment in ipairs(result.map) do
      local line = lines[segment.line + 1]
      truthy(segment.col_to <= #line, "segment inside its line")
      eq(line:sub(segment.col_from + 1, segment.col_to), table.concat(runes, "", segment.src_from + 1, segment.src_to))
    end
    for _, style in ipairs(result.styles) do
      truthy(style.col_to <= #lines[style.line + 1], "style span inside its line")
    end
  end

  it("finds a footnote_quote note whose id sits on the inner anchor only", function()
    -- the shape real WeRead books use(真实微信读书书籍的写法)
    local source = table.concat({
      '<p class="content">正文<a id="footnote_quote_txt012_9" class="footnote_quote" href="part0018_split_005.html#footnote_content_txt012_9">[9]</a>后文</p>\n',
      '<hr class="calibre3"/>\n',
      '<p class="footnote_content"><a id="footnote_content_txt012_9" href="part0018_split_005.html#footnote_quote_txt012_9" class="calibre2">[9]</a>译注：注释<span class="b">正文</span>。</p>\n',
    })
    local result = xhtml.convert(source, { paragraph = { indent = "" } })
    eq(#result.footnotes, 1)
    eq(result.footnotes[1].ref, "footnote_content_txt012_9")
    eq(result.footnotes[1].text, "译注：注释正文。", "whole block, back-link stripped")
  end)

  it("leaves a note that lives in another file empty", function()
    local source = '<p>正文<a id="q1" class="footnote_quote" href="other.html#footnote_content_x">[1]</a></p>'
    local result = xhtml.convert(source, { paragraph = { indent = "" } })
    eq(result.footnotes[1].text, "")
  end)

  it("does not leave an opening marker dangling at the end of a line", function()
    for _, tag in ipairs({ "b", "code" }) do
      local marker = tag == "b" and "**" or "`"
      local source = "<p>" .. string.rep("字", 10) .. "<" .. tag .. ">粗体</" .. tag .. ">后</p>"
      local result = page(source, 20)
      local lines = lines_of(result.text)
      eq(lines[1], string.rep("字", 10), "nothing after the margin for " .. tag)
      eq(lines[2], marker .. "粗体" .. marker .. "后")
      eq(#result.styles, 1)
      eq(result.styles[1].line, 1)
      eq(result.styles[1].col_from, #marker)
      assert_map_exact(source, result)
    end
  end)

  it("closes a style before the bracket it carries to the next line", function()
    -- the page breaks while `<b>` is still open(版心折断时 `<b>` 仍然打开)
    local source = "<p><b>" .. string.rep("字", 9) .. "（甲</b>乙</p>"
    local result = page(source, 20)
    local lines = lines_of(result.text)
    eq(lines[1], "**" .. string.rep("字", 9) .. "**", "the bracket left with the line end")
    eq(lines[2], "**（甲**乙")
    eq(#result.styles, 2)
    for _, style in ipairs(result.styles) do
      local line = lines[style.line + 1]
      eq(line:sub(style.col_to + 1, style.col_to + 2), "**", "the span ends at its closing marker")
    end
    assert_map_exact(source, result)
  end)

  it("keeps a space trimmed at the wrap point out of the map and the styles", function()
    local source = "<p><b>" .. string.rep("a", 10) .. " " .. string.rep("b", 10) .. "</b></p>"
    local result = page(source, 10)
    eq(lines_of(result.text)[1], "**" .. string.rep("a", 10) .. "**")
    assert_map_exact(source, result)
    eq(result.map[1].src_to - result.map[1].src_from, 10, "the space is not on the line")
  end)

  it("never leaves one character alone on a paragraph's last line", function()
    -- 21 characters on a 20-cell (10 character) page: 10 + 10 + 1 would
    -- strand the last one(20 格=10 字的版心放 21 个字：10 + 10 + 1 会把最后一个字孤立)
    for _, tail in ipairs({ "", "。", "。”" }) do
      local source = "<p>" .. string.rep("字", 20) .. "尾" .. tail .. "</p>"
      local result = page(source, 20)
      local lines = lines_of(result.text)
      local last = lines[#lines]:gsub("[　 ]", "")
      truthy(vim.fn.strchars(last) >= 2 + vim.fn.strchars(tail), "the last line holds two characters: " .. lines[#lines])
      assert_map_exact(source, result)
    end
  end)

  it("never lets a footnote mark and hanging punctuation run past the hang budget", function()
    local NOTE = '<img class="qqreader-footnote" src="n.png" alt="注"/>'
    local width = 20
    local samples = {
      "<p>" .. string.rep("字", 10) .. "。”" .. NOTE .. "。后文</p>",
      "<p>" .. string.rep("字", 10) .. NOTE .. "。”）后文</p>",
      "<p>" .. string.rep("字", 9) .. "甲" .. NOTE .. NOTE .. "，后文</p>",
      "<p>" .. string.rep("字", 10) .. '<a class="footnote_quote" href="#n">[12]</a>……后文</p>',
    }
    for _, source in ipairs(samples) do
      local result = page(source, width)
      local lines = lines_of(result.text)
      for _, line in ipairs(lines) do
        truthy(vim.fn.strdisplaywidth(line) <= width + xhtml.HANG_BUDGET, "overflow within budget: " .. line)
        truthy(not line:match("^[。，”）…]"), "no line opens with closing punctuation: " .. line)
      end
      for _, footnote in ipairs(result.footnotes) do
        matches(lines[footnote.line + 1]:sub(footnote.col_from + 1, footnote.col_to), "^%[%d+%]$")
      end
      assert_map_exact(source, result)
    end
  end)
end)
