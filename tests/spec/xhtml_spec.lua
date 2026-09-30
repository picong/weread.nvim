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
    eq(vim.split(result.text, "\n", { plain = true })[start.line + 1], "正文甲")
  end)

  it("keeps counting runes across comments", function()
    local source = '<p>前<!-- 注释 -->后</p>'
    local result = xhtml.convert(source)
    eq(result.text, "前后")
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
    eq(lines[resolved.start.line + 1], "汪淼把车停在楼下，抬头看天。")
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
    truthy(result.text:find("> 引用", 1, true))
  end)

  it("never emits two consecutive blank lines", function()
    local result = xhtml.convert("<div><p>a</p></div><div><p>b</p></div>")
    falsy(result.text:find("\n\n\n", 1, true), "got: " .. result.text:gsub("\n", "\\n"))
  end)
end)
