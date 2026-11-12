--[[
XHTML -> Markdown converter for WeRead chapters, plus the offset map that
makes annotation ranges resolvable.
(WeRead 章节的 XHTML → Markdown 转换器，以及让划线 range 可定位的 offset map)

Why an offset map instead of injecting markers into the source:
(为什么用 offset map 而不是往源码里插标记)

WeRead underline records carry `range` as a *rune (code point) index range over
the raw chapter HTML, tags included, 0-based*. Highlighting therefore needs a
translation from source rune offsets to positions in the rendered markdown.
Baking highlight spans into the markdown would mean re-converting the chapter
every time annotations change, so instead the conversion records where every
text run landed and annotations are drawn as extmarks on top.
(微信读书的划线 range 是「原始章节 HTML 字符（码点）索引范围，0 起算，且把标签
 字符也算进去」。因此需要把源 rune 偏移翻译成渲染后 markdown 中的位置。若把
 高亮直接烧进 markdown，每次划线变化都要重新转换章节；改为转换时记录每个文本
 段落落在哪，划线另以 extmark 绘制)

Precision note: resolution snaps outward to text-run boundaries. Ranges always
start and end on a text run in practice, and the UI marks whole lines anyway.
(精度说明：定位会向外取整到文本段落边界。实际数据里 range 总是落在文本段落上，
 且 UI 只做整行标记，因此足够)

Layout of the module: this file is the converter and the facade. The line buffer
and text primitives live in xhtml_buffer, the offset-map queries in xhtml_map and
the code-language sniffer in xhtml_code; everything callers used to find on
`weread.xhtml` is still exposed here.
(模块布局：本文件是转换器兼 facade。行缓冲与文本原语在 xhtml_buffer，offset map 查询在
 xhtml_map，代码语言嗅探在 xhtml_code；调用方原来在 `weread.xhtml` 上找得到的东西，这里
 仍然都有)
]]

local config = require("weread.config")
local css = require("weread.css")
local buffer_module = require("weread.xhtml_buffer")
local code_module = require("weread.xhtml_code")
local map_module = require("weread.xhtml_map")
local table_module = require("weread.xhtml_table")

local Buffer = buffer_module.Buffer
local count_runes = buffer_module.count_runes
local char_bytes = buffer_module.char_bytes
local display_width = buffer_module.display_width

local M = {}

---Bump whenever the rendered output changes shape (paragraph handling, indents,
---image syntax...). Chapters cached by an older renderer are re-rendered from
---the cached source XHTML locally, without touching the network, so a typography
---tweak reaches books that are already downloaded.
---(渲染结果形态变化时递增（段落处理、缩进、图片语法…）。旧渲染器缓存的章节会用
--- 已缓存的源 XHTML 在本地重排，不联网，因此排版调整能作用到已下载的书)
M.VERSION = 20

local BLOCK_TAGS = {
  p = true,
  div = true,
  center = true,
  section = true,
  article = true,
  header = true,
  footer = true,
  aside = true,
  blockquote = true,
  figure = true,
  figcaption = true,
  ul = true,
  ol = true,
  li = true,
  table = true,
  tr = true,
  td = true,
  th = true,
  dl = true,
  dt = true,
  dd = true,
  pre = true,
  hr = true,
  br = true,
}

local HEADINGS = { h1 = 1, h2 = 2, h3 = 3, h4 = 4, h5 = 5, h6 = 6 }

---Icons drawn in front of a heading, one per level, the ones render-markdown
---uses. Set `layout.heading_icons = false` to draw none.
---(画在标题前面的图标，每级一个，与 render-markdown 用的相同。设 `layout.heading_icons = false`
--- 则不画)
local HEADING_ICONS = { "󰲡 ", "󰲣 ", "󰲥 ", "󰲧 ", "󰲩 ", "󰲫 " }
M.HEADING_ICONS = HEADING_ICONS

---Block elements whose layout the buffer inherits: a `<div class="content_reference">`
---hands its padding down to the `<p>` inside it.
---(行缓冲会继承其排版的块级元素：`<div class="content_reference">` 把它自己的 padding
--- 传给里面的 `<p>`)
---
---Void elements are deliberately absent: they never close, so they would stay on
---the stack forever.
---(自闭合元素刻意不在其中：它们永远不会闭合，会永久留在栈上)
local LAYOUT_TAGS = {
  p = true,
  div = true,
  center = true,
  section = true,
  article = true,
  header = true,
  footer = true,
  aside = true,
  blockquote = true,
  figure = true,
  figcaption = true,
  li = true,
  dl = true,
  dt = true,
  dd = true,
  td = true,
  th = true,
  pre = true,
}

---Elements that never close, so they can never hold a note's text.
---(永不闭合的元素，因此不可能包着注释文字)
local VOID_TAGS = {
  img = true,
  br = true,
  hr = true,
  meta = true,
  link = true,
  input = true,
  col = true,
  source = true,
  wbr = true,
}

---Elements whose contents are metadata, never prose.
---(内容为元数据、绝非正文的元素)
local SKIP_BODIES = {
  style = true,
  script = true,
  head = true,
  title = true,
  meta = true,
  link = true,
}

---Inline elements whose meaning is fixed by the tag itself. `marker` is the
---markdown syntax written around the content (empty for styles markdown cannot
---express, which are rendered as extmarks instead).
---(语义由标签本身决定的元素。marker 是包裹内容的 markdown 语法；markdown 表达不了
--- 的样式留空，改用 extmark 呈现)
local INLINE_TAGS = {
  b = { kind = "bold", marker = "**" },
  strong = { kind = "bold", marker = "**" },
  em = { kind = "italic", marker = "*" },
  i = { kind = "italic", marker = "*" },
  cite = { kind = "italic", marker = "*" },
  code = { kind = "code", marker = "`" },
  tt = { kind = "code", marker = "`" },
  u = { kind = "underline" },
  ins = { kind = "underline" },
  del = { kind = "strike" },
  s = { kind = "strike" },
  strike = { kind = "strike" },
  mark = { kind = "mark" },
  sup = { kind = "sup" },
  sub = { kind = "sub" },
  small = { kind = "small" },
}

---Style kinds that come out of the stylesheet rather than the tag name.
---(来自样式表而非标签名的样式种类)
local STYLE_KINDS = {
  { key = "bold", kind = "bold", marker = "**" },
  { key = "italic", kind = "italic", marker = "*" },
  { key = "underline", kind = "underline" },
  { key = "strike", kind = "strike" },
  { key = "mark", kind = "mark" },
}

local ENTITIES = {
  amp = "&",
  lt = "<",
  gt = ">",
  quot = '"',
  apos = "'",
  nbsp = " ",
  ensp = " ",
  emsp = " ",
  ldquo = "“",
  rdquo = "”",
  lsquo = "‘",
  rsquo = "’",
  hellip = "…",
  mdash = "—",
  ndash = "–",
  middot = "·",
  laquo = "«",
  raquo = "»",
  times = "×",
  deg = "°",
  copy = "©",
  reg = "®",
  trade = "™",
}

---Count runes (UTF-8 code points) in a byte string by counting non-continuation
---bytes. Verified against `vim.str_utfindex` in the test suite.
---(通过统计非续字节来数 rune，测试中与 vim.str_utfindex 对齐验证)
---@param text string
---@return integer
---Normalise a text run that sits between tags.
---(规整位于标签之间的文本段)
---
---Real chapters are pretty printed: tags are separated by newlines and
---indentation, and emitting that verbatim produced stray blank lines inside
---paragraphs. Pure layout runs are dropped; runs with content have their
---whitespace collapsed to single spaces, and lose the leading part when they
---start a line.
---(真实章节是带缩进换行排版的：直接把标签间的换行当正文输出，会在段落里插入多余空行。
--- 纯排版用的空白段直接丢弃；含内容的段把空白折叠成单个空格，行首的空白则去掉)
---@param raw string source text before entity decoding(实体解码前的源文本)
---@param text string decoded text(解码后的文本)
---@return string|nil
function M.normalize_text(raw, text)
  if vim.trim(raw) == "" then
    return nil
  end
  text = text:gsub("[ \t\r\n]+", " ")
  if text == " " then
    return nil
  end
  return text
end

---Plain text of the first heading in a chapter, used to decide whether it is
---just a repeat of the chapter title the winbar already shows.
---(章节里第一个标题的纯文本，用于判断它是否只是 winbar 已显示的章节标题)
---@param xhtml string
---@return string|nil
function M.first_heading(xhtml)
  if type(xhtml) ~= "string" then
    return nil
  end
  local heading = xhtml:match("<h[1-6][^>]*>(.-)</h[1-6]>")
  if not heading then
    return nil
  end
  heading = heading:gsub("<[^>]*>", "")
  heading = M.decode_entities(heading)
  return vim.trim((heading:gsub("%s+", "")):gsub("　", ""))
end

---The `<style>` blocks a chapter carries. Real chapters ship a couple of
---kilobytes of chapter-specific CSS this way (the copyright page, poem pages,
---figure wrappers...), and those classes are the only definition they get.
---(章节自带的 `<style>` 块。真实章节会这样带上几 KB 的章节专有 CSS（版权页、诗歌页、
--- 插图容器…），而这些类名的定义只存在于这里)
---@param source string
---@return string
function M.inline_stylesheet(source)
  local blocks = {}
  for block in tostring(source or ""):gmatch("<style[^>]*>(.-)</style>") do
    blocks[#blocks + 1] = block
  end
  return table.concat(blocks, "\n")
end

---Does the first heading merely repeat the chapter title?
---(第一个标题是否只是章节标题的重复)
---@param xhtml string
---@param chapter_title string|nil
---@return boolean
function M.repeats_title(xhtml, chapter_title)
  local heading = M.first_heading(xhtml)
  if not heading or not chapter_title or chapter_title == "" then
    return false
  end
  local title = vim.trim((chapter_title:gsub("%s+", "")):gsub("　", ""))
  if title == "" then
    return false
  end
  return heading == title or heading:find(title, 1, true) == 1 or title:find(heading, 1, true) == 1
end

---Decode the HTML entities that appear in book text.
---(解码书里出现的 HTML 实体)
---@param text string
---@return string
function M.decode_entities(text)
  if not text:find("&", 1, true) then
    return text
  end
  text = text:gsub("&#x(%x+);", function(code)
    local value = tonumber(code, 16)
    return value and vim.fn.nr2char(value) or ""
  end)
  text = text:gsub("&#(%d+);", function(code)
    local value = tonumber(code)
    return value and vim.fn.nr2char(value) or ""
  end)
  return (text:gsub("&(%a+);", function(name)
    return ENTITIES[name] or ("&" .. name .. ";")
  end))
end

---@param tag string
---@param name string
---@return string|nil
local function attr(tag, name)
  local value = tag:match(name .. '%s*=%s*"([^"]*)"')
  if value == nil then
    value = tag:match(name .. "%s*=%s*'([^']*)'")
  end
  if value == nil then
    value = tag:match(name .. "%s*=%s*([^%s>]+)")
  end
  return value
end

---Decode the entities of a source text run, keeping track of where every
---character came from.
---(解码一段源文本里的实体，同时记下每个字符来自哪里)
---
---The map promises that a segment's characters are its source runes one for
---one, and decoding breaks that promise: `&amp;` is one character on the page
---but five runes in the source. Each character therefore carries its own source
---span, and the caller ends a segment wherever the spans stop being one rune
---each and back to back.
---(map 承诺段落里的字符与源 rune 一一对应，而解码打破了这一点：`&amp;` 在页面上是一个
--- 字符，在源码里却是五个 rune。因此每个字符都带着自己的源跨度，调用方在跨度不再是
--- 「各占一个且首尾相接」的地方把段落断开)
---@param raw string source text, entities and all(含实体的源文本)
---@param from integer rune offset of `raw` in the source(raw 在源码里的 rune 偏移)
---@return table[] items { char, from, to } one per decoded character(每个解码后的字符一项)
local function decode_spans(raw, from)
  local items = {}
  local rune = from
  local index = 1
  while index <= #raw do
    local decoded, consumed = nil, nil
    if raw:byte(index) == 38 then -- "&"
      local hex = raw:match("^&#x(%x+);", index)
      local dec = not hex and raw:match("^&#(%d+);", index)
      local name = not hex and not dec and raw:match("^&(%a+);", index)
      if hex then
        decoded, consumed = vim.fn.nr2char(tonumber(hex, 16)), #hex + 4
      elseif dec then
        decoded, consumed = vim.fn.nr2char(tonumber(dec)), #dec + 3
      elseif name and ENTITIES[name] then
        decoded, consumed = ENTITIES[name], #name + 2
      end
    end
    if decoded then
      -- the entity's runes are all ASCII, one byte each(实体的 rune 全是 ASCII，一个字节一个)
      -- the rare entity that decodes to more than one character keeps all its
      -- runes on the first(极少数解码成多个字符的实体，把全部 rune 记在第一个字符上)
      local position, first = 1, rune
      while position <= #decoded do
        local length = char_bytes(decoded, position)
        items[#items + 1] = { char = decoded:sub(position, position + length - 1), from = first, to = rune + consumed }
        first = rune + consumed
        position = position + length
      end
      rune = rune + consumed
      index = index + consumed
    else
      local length = char_bytes(raw, index)
      items[#items + 1] = { char = raw:sub(index, index + length - 1), from = rune, to = rune + 1 }
      rune = rune + 1
      index = index + length
    end
  end
  return items
end

---Text and flat source spans of a list of decoded characters.
---(一组解码后字符的文本与扁平的源跨度)
---@param items table[] { char, from, to }
---@param first integer|nil
---@param last integer|nil
---@return string text
---@return integer[] spans
local function join_spans(items, first, last)
  local chars, spans = {}, {}
  for index = first or 1, last or #items do
    local item = items[index]
    chars[#chars + 1] = item.char
    spans[#spans + 1] = item.from
    spans[#spans + 1] = item.to
  end
  return table.concat(chars), spans
end

---Decode and normalise a prose text run the way `normalize_text` does, with the
---source span of every character kept: a collapsed run of whitespace becomes one
---space that stands for all of its runes.
---(像 normalize_text 那样解码并规整一段散文文本，同时保留每个字符的源跨度：折叠后的
--- 一串空白变成一个空格，代表它的全部 rune)
---@param raw string
---@param from integer
---@return table[]|nil items
local function prose_spans(raw, from)
  if vim.trim(raw) == "" then
    return nil
  end
  local items = {}
  for _, item in ipairs(decode_spans(raw, from)) do
    local white = item.char == " " or item.char == "\t" or item.char == "\r" or item.char == "\n"
    local last = items[#items]
    if white and last and last.white then
      last.to = item.to
    else
      items[#items + 1] = { char = white and " " or item.char, from = item.from, to = item.to, white = white }
    end
  end
  if #items == 1 and items[1].white then
    return nil
  end
  return items
end

-- ------------------------------------------------------------- translation

---Markup the service adds to a chapter it has translated, besides the
---translations themselves: a stylesheet and a meta line in <head>, and a number
---on every list item. None of it is in the book, and all of it counts runes.
---(服务端给翻译过的章节额外加的标记——除了译文本身：<head> 里的一张样式表与一行 meta，以及每个
--- 列表项上的序号。它们都不是书里的东西，却都占 rune)
local TRANSLATION_HEAD = {
  '\n<link href="wereadstyle/wrtranslation%.css"[^>]*>',
  '\n<meta content="text/html; charset=utf%-8" http%-equiv="content%-type"/>',
}

---Byte ranges of the translation blocks in a chapter, outermost only: from the
---line break the service put before each one through its closing tag.
---(章节里译文块的字节区间，只取最外层：从服务端放在每块前面的换行到它的闭合标签)
---@param source string
---@return integer[][] ranges { from, to } inclusive, in order
local function translation_ranges(source)
  local ranges = {}
  local pos = 1
  while true do
    local start, finish, tag = source:find('<(%w+)[^>]-class="wr%-translation[^"]*"[^>]*>', pos)
    if not start then
      break
    end
    local depth, cursor, close_end = 1, finish + 1, nil
    if source:sub(finish - 1, finish) == "/>" then
      depth, close_end = 0, finish
    end
    while depth > 0 do
      local open_at, open_end, slash = source:find("<(/?)" .. tag .. "[%s>/]", cursor)
      if not open_at then
        break
      end
      depth = depth + (slash == "/" and -1 or 1)
      cursor = open_end + 1
      if depth == 0 then
        close_end = source:find(">", open_at, true)
      end
    end
    if not close_end then
      break
    end
    local from = start
    if source:sub(start - 1, start - 1) == "\n" then
      from = start - 1
    end
    ranges[#ranges + 1] = { from, close_end }
    pos = close_end + 1
  end
  return ranges
end

---Separate a chapter the service translated into the book's own text and the
---bilingual version.
---(把服务端翻译过的章节拆成书的原文与双语版)
---
---Once a chapter is translated, the service returns it with a translated block
---after every block of the original — whether the reader asked for the
---translation or not. Taking the translations and the markup that came with them
---back out gives the original byte for byte (checked against a copy fetched
---before translation), which is what keeps highlight ranges and reading
---positions in the coordinate every device uses.
---(章节一旦翻译过，服务端返回的内容就在原文每个块后面跟一个译文块——不管读者有没有要翻译。把
--- 译文与随之加入的标记拿掉，就逐字节回到原文（已与翻译前取得的副本核对），划线 range 与阅读位置
--- 因此仍落在各端共用的坐标里)
---@param source string
---@return string original the chapter without translations(不含译文的章节)
---@return string|nil bilingual the chapter with them, nil when it has none(含译文的章节；没有译文时为 nil)
---@return integer[][] ranges translation blocks in `bilingual`(`bilingual` 里的译文块)
function M.split_translation(source)
  if not source or not source:find("wr-translation", 1, true) then
    return source, nil, {}
  end
  local bilingual = source
  for _, pattern in ipairs(TRANSLATION_HEAD) do
    bilingual = bilingual:gsub(pattern, "")
  end
  bilingual = bilingual:gsub('(<li)%s+value="%d+"', "%1")
  local ranges = translation_ranges(bilingual)
  if #ranges == 0 then
    return bilingual, nil, {}
  end
  local parts, pos = {}, 1
  for _, range in ipairs(ranges) do
    parts[#parts + 1] = bilingual:sub(pos, range[1] - 1)
    pos = range[2] + 1
  end
  parts[#parts + 1] = bilingual:sub(pos)
  return table.concat(parts), bilingual, ranges
end

M.translation_ranges = translation_ranges

---@class weread.xhtml.Result
---@field text string markdown body
---@field map table[] source rune range -> markdown position
---@field source_runes integer rune length of the source XHTML
---@field images table[] image references found
---@field headings table[] { line, level, title? } 0-based lines(0 基行号)
---@field page_width integer
---@field lines table<integer, table> { align, small, accent, cells, fill? } keyed by 0-based line
---@field styles table[]
---@field footnotes table[] { line, col_from, col_to, text, ref? } 0-based line, byte cols
---@field originals integer[] 0-based lines of the original a translation follows(后面跟着译文的原文行，0 基)

---Convert chapter XHTML to markdown.
---(把章节 XHTML 转成 markdown)
---@param xhtml string
---@param opts table|nil
---   resolve_image fun(src: string): string|nil  rewrite image sources
---   heading_offset integer shift heading levels (default 0)
---   title string|nil chapter title, set on its own opening page(章节标题，单独排在章首)
---   justify boolean|nil false keeps wrapped lines ragged (default true)(false 时折行不做两端对齐)
---   translations integer[][]|nil byte ranges of translation blocks: drawn under
---     their original, outside the offset map(译文块的字节区间：画在原文下面，不进 offset map)
---@return weread.xhtml.Result
function M.convert(xhtml, opts)
  opts = opts or {}
  local resolve_image = opts.resolve_image
  local heading_offset = opts.heading_offset or 0

  -- WeRead underline ranges do not count a leading BOM, so drop it and let the
  -- rune counter start at 0 for the first real character.
  -- (划线 range 不计算开头的 BOM，故先去掉 BOM，让第一个真实字符对应 rune 0)
  local source = xhtml
  if source:sub(1, 3) == "\239\187\191" then
    source = source:sub(4)
  end

  local paragraph = opts.paragraph
  if paragraph == nil then
    paragraph = config.get().paragraph
  end
  -- How much air to leave around structural elements. The app has none between
  -- paragraphs and only a little around figures, so "compact" is the default
  -- and "none" squeezes even that out.
  -- (结构元素周围留多少白。App 里段间不留白、插图周围只留一点，因此默认 compact，
  --  想要更紧可以设 none)
  local gap_mode = opts.gap or paragraph.gap or "compact"
  local skip_title = opts.skip_title == true
  local page_width = math.max(0, tonumber(opts.page_width) or 0)
  local buffer = Buffer.new({
    compact = paragraph.compact,
    indent = paragraph.indent,
    no_gap = gap_mode == "none",
    width = page_width,
    auto_space = opts.auto_space == true,
    justify = opts.justify,
  })
  local images = {}
  local styles = {}
  -- Footnotes: the inline marks a book uses (a `qqreader-footnote` image whose
  -- alt is the note, or a `footnote_quote` link to a note further down) and
  -- where they landed on the page.
  -- (脚注：书里的行内脚注标记（alt 即注释内容的 `qqreader-footnote` 图片，或者指向下文
  --  注释的 `footnote_quote` 链接）及其在页面上的位置)
  local footnotes = {}
  local open_quote = nil
  -- Plain text of every element that carries an `id`, so a link to a note can be
  -- answered with the note itself once the whole chapter has been read.
  -- (每个带 `id` 的元素的纯文本：整章读完之后，指向注释的链接就能拿到注释本身)
  local captures = {}
  local id_text = {}
  local id_alias = {}
  -- Heading lines are recorded so the reader can paint them itself: syntax
  -- highlighters give headings their own colour *and* background, which breaks
  -- the illusion of a paper page.
  -- (记录标题行，让阅读器自己上色：语法高亮给标题配了各自的颜色**和背景**，会破坏
  --  纸页的观感)
  local headings = {}
  local rune = 0
  local pos = 1
  -- Translation blocks are on the page but not in the book: their characters are
  -- written without a source offset and their runes are not counted, so every
  -- offset still matches the original a highlight was made on.
  -- (译文块在页面上，却不在书里：它们的字符不带源偏移地写出，rune 也不计数，因此每个偏移
  --  仍对得上划线所依据的原文)
  local translations = opts.translations or {}
  local translation_index = 1
  local translating = false
  -- Lines of the original that a translation follows, so the reader can show the
  -- translation alone: the first line of the block being read, figures on it
  -- excepted (a translation leaves those out).
  -- (后面跟着译文的原文行，让阅读器能只显示译文：记下正在读的块从哪一行开始；块里的插图除外
  --  （译文不带插图）)
  local originals = {}
  local original_from = nil
  local figure_lines = {}
  ---@param byte integer
  ---@return integer[]|nil range the translation block holding `byte`(包含该字节的译文块)
  ---@return integer[]|nil next the first one starting after it(其后第一个译文块)
  local function translation_at(byte)
    while translations[translation_index] and translations[translation_index][2] < byte do
      translation_index = translation_index + 1
    end
    local range = translations[translation_index]
    if range and range[1] <= byte then
      return range, nil
    end
    return nil, range
  end

  -- The opening page of a chapter: the title on a line of its own, centred, with
  -- room above it, the way the app opens every chapter. It is not source text,
  -- so it stays out of the offset map entirely.
  -- (章首页：标题独占一行、居中、上方留白，App 每一章都是这样开头的。它不是源文，因此完全
  --  不进入 offset map)
  local title = type(opts.title) == "string" and vim.trim(opts.title) or ""
  if title ~= "" and page_width > 0 then
    buffer.lines[1] = ""
    buffer.lines[2] = ""
    buffer:set_layout({ align = "center", accent = true })
    buffer:block_marker("# ", 0)
    headings[#headings + 1] = { line = #buffer.lines, level = 1, title = true }
    buffer:flow(title)
    buffer:newline()
    buffer.lines[#buffer.lines + 1] = ""
    buffer:set_layout({})
  end
  -- The book stylesheet plus the chapter's own <style> block; the chapter wins,
  -- because that is what the markup next to it was written against.
  -- (书籍样式表 + 章节自带的 <style> 块；以章节为准，因为紧跟其后的标记就是照着它写的)
  local class_styles = opts.styles
    or css.merge_maps(css.parse(opts.css), css.parse(M.inline_stylesheet(source)))

  -- Layout inherited from the enclosing elements, innermost last. Each entry
  -- keeps the resolved style of one open block; the innermost value of each key
  -- is what the buffer gets.
  -- (从外层元素继承下来的排版，最内层在最后。每项保存一个已打开块的解析样式；每个键
  --  取最内层的值交给行缓冲)
  local layout_stack = {}

  -- Open style groups, innermost last. Each entry records where its content
  -- starts so the closing tag can turn it into a style span over the rendered
  -- text. Styles cannot span a line break, so those are dropped on close.
  -- (打开中的样式组，最内层在最后。每项记录内容起点，闭合标签据此生成覆盖渲染文本的
  --  样式区间。样式不能跨行，因此跨行的会被丢弃)
  local open_groups = {}
  -- Headings are already prominent in markdown; wrapping them in `**` only adds
  -- markers to hide. Styling inside a heading is therefore skipped.
  -- (markdown 里标题本身就很突出，再包 `**` 只是徒增待隐藏的标记，因此标题内的样式
  --  一律跳过)
  local in_heading = false
  local skip_heading = false
  local skipped_original = false
  local headings_seen = 0
  -- The table being read. Its cells are collected, not written: a table is laid
  -- out whole once it closes (`weread.xhtml_table`), because the width of every
  -- column depends on every row. A block inside a cell (its `<p>`, a `<br>`) is a
  -- line break inside that cell, never the end of the row.
  -- (正在读的表格。单元格先收集、不写出：表格要等闭合之后整体排版（`weread.xhtml_table`），因为
  --  每一列多宽取决于每一行。单元格里的块（它的 `<p>`、`<br>`）是这一格里的换行，绝不结束这一行)
  ---@type table|nil { rows, row, cell, depth, in_head }
  local tbl = nil
  local saved_table_layout = nil
  local cell_text, close_table
  -- 0-based lines the tables took, so the reader knows which lines are a table
  -- without guessing from box characters a code listing may also draw
  -- (表格占用的行（0 基）：阅读器据此知道哪些行是表格，而不必从制表符去猜——代码清单里也可能画着它们)
  local table_lines = {}
  -- Open lists, innermost last: { ordered, next, hang }. A list item's marker is
  -- `- ` or `3. `, and its continuation lines hang under the text, past the marker.
  -- (打开中的列表，最内层在最后。列表项标记是 `- ` 或 `3. `，续行悬挂在文字下方、标记之后)
  local lists = {}
  -- Nested `<blockquote>`s: every line inside one starts with one `> ` per level.
  -- (嵌套的 `<blockquote>`：其中每一行都以每层一个 `> ` 开头)
  local quote_depth = 0
  -- Heading being written: its marker repeats on every line a wrap starts, so
  -- each of them stays part of the heading.
  -- (正在写的标题：折行开出的每一行都重复它的标记，让它们都仍属于标题)
  local open_heading = nil
  local heading_icons = (config.get().layout or {}).heading_icons
  if heading_icons == nil then
    heading_icons = HEADING_ICONS
  end
  ---Cells the reader draws in front of a heading line: its icon, the `#` marks
  ---themselves being concealed.
  ---(阅读器画在标题行前面的宽度：图标；`#` 本身被隐藏)
  ---@param level integer
  ---@return integer
  local function heading_cells(level)
    if type(heading_icons) ~= "table" or #heading_icons == 0 then
      return 0
    end
    return display_width(heading_icons[math.min(level, #heading_icons)] or "")
  end

  ---Text written at the start of every line inside the open quotes.
  ---(打开中的引文里每一行开头都要写的文本)
  local function quote_lead()
    return string.rep("> ", quote_depth)
  end

  ---@param tag_name string
  ---@param kind string
  ---@param marker string|nil markdown syntax to wrap the content with
  local function open_style(tag_name, kind, marker)
    if tbl and tbl.cell then
      -- inside a cell: a span over the cell's own items, no marker at all
      -- (单元格里：只在这一格自己的项上记一个区间，不写任何标记)
      local cell = tbl.cell
      cell.open[#cell.open + 1] = { tag = tag_name, kind = kind, from = #cell.items + 1 }
      return
    end
    -- Write any queued paragraph indent first: a style span must start at the
    -- content, not chew up the indentation.
    -- (先落下排队中的段落缩进：样式区间必须从内容开始，不能把缩进也吞进去)
    buffer:flush_indent()
    -- The opening marker waits for the first content character (see
    -- `Buffer:open_pending`); zero cells, because the reader conceals it.
    -- (开启标记等到第一个内容字符才写（见 `Buffer:open_pending`）；占 0 单元格，因为阅读器会隐藏它)
    local entry = { kind = kind, marker = marker, opened = false }
    buffer.pending[#buffer.pending + 1] = entry
    local group = open_groups[#open_groups]
    if not group or group.tag ~= tag_name then
      group = { tag = tag_name, entries = {} }
      open_groups[#open_groups + 1] = group
    end
    group.entries[#group.entries + 1] = entry
  end

  ---Record the span of an open entry up to the current column.
  ---(把一个打开中的样式项记录为截至当前列的样式区间)
  local function record_span(entry)
    if entry.opened and entry.line == #buffer.lines and buffer.col > entry.col_from then
      styles[#styles + 1] = {
        line = entry.line,
        col_from = entry.col_from,
        col_to = buffer.col,
        kind = entry.kind,
        markers = entry.marker and #entry.marker or 0,
      }
    end
  end

  ---@param tag_name string
  local function close_styles(tag_name)
    if tbl and tbl.cell then
      local cell = tbl.cell
      local closed = false
      for index = #cell.open, 1, -1 do
        local entry = cell.open[index]
        if entry.tag == tag_name then
          table.remove(cell.open, index)
          if #cell.items >= entry.from then
            cell.styles[#cell.styles + 1] = { kind = entry.kind, from = entry.from, to = #cell.items }
          end
          closed = true
        end
      end
      if closed then
        return
      end
    end
    local found = nil
    for index = #open_groups, 1, -1 do
      if open_groups[index].tag == tag_name then
        found = index
        break
      end
    end
    if not found then
      return -- stray closing tag(游离的闭合标签)
    end
    -- Close everything above the match too, so a mismatched document cannot
    -- leave markers unclosed.
    -- (连上面的一起闭合，避免标签错配留下未闭合的标记)
    for _ = #open_groups, found, -1 do
      local group = table.remove(open_groups)
      for entry_index = #group.entries, 1, -1 do
        local entry = group.entries[entry_index]
        if entry.opened then
          record_span(entry)
          if entry.marker then
            buffer:marker(entry.marker, 0)
          end
        else
          -- never opened: no content, so no markers either (no stray `****`)
          -- (从未打开：没有内容，因此也不留标记（不会出现游离的 `****`）)
          for index = #buffer.pending, 1, -1 do
            if buffer.pending[index] == entry then
              table.remove(buffer.pending, index)
            end
          end
        end
      end
    end
  end

  -- Style cannot survive a line break on its own: the closing tag turns a group
  -- into a span over *one* line, and a span that crosses a wrap would be dropped
  -- entirely. Closing the markers before the page edge and reopening them on the
  -- next line turns one long span into one span per line, all of them drawn.
  -- (样式自己无法跨行存活：闭合标签只能把一组变成**一行**上的样式区间，跨折行的样式会
  --  被整个丢弃。在页边前闭合标记、下一行重新打开，就把一个长样式变成每行一个、各自成立)
  buffer.styles = styles
  buffer.before_wrap = function(self)
    for index = #open_groups, 1, -1 do
      local group = open_groups[index]
      for entry_index = #group.entries, 1, -1 do
        local entry = group.entries[entry_index]
        if entry.opened then
          if entry.line == #self.lines and self.col > entry.col_from then
            record_span(entry)
            if entry.marker then
              self:marker(entry.marker, 0)
            end
          elseif entry.marker then
            -- opened at the very end of the line with nothing after it: take
            -- the marker back instead of leaving it unmatched at the margin
            -- (在行尾刚打开、后面什么都没有：收回标记，而不是让它孤零零地留在页边)
            self:unmark(entry.marker)
          end
        end
      end
    end
  end

  buffer.after_wrap = function(self)
    if open_heading then
      -- the heading goes on: its next line is a heading line too
      -- (标题还没完：它的下一行同样是标题行)
      -- A centred heading centres each line on its own, so a continuation has no
      -- icon room to keep; a flush left one keeps its text under the first line's.
      -- (居中标题每行各自居中，续行不必留图标位置；左对齐的标题让续行文字对齐首行)
      local centred = self.layout.align == "center"
      self:block_marker(open_heading.marker, centred and 0 or heading_cells(open_heading.level))
      headings[#headings + 1] = { line = #self.lines, level = open_heading.level, continued = true, bare = centred or nil }
    end
    -- Every open style waits for the next content character again, so its
    -- marker lands after the inset and right before the content — the span then
    -- starts at the *content*, exactly as it does when the style is opened
    -- normally.
    -- (每个打开中的样式重新等待下一个内容字符：标记落在内缩之后、内容之前——样式区间从
    --  **内容**开始，与正常打开样式时一致)
    local pending = {}
    for _, group in ipairs(open_groups) do
      for _, entry in ipairs(group.entries) do
        entry.opened = false
        pending[#pending + 1] = entry
      end
    end
    self.pending = pending
  end

  -- Footnote marks move with a wrap that carries them along.
  -- (被折行带走的脚注标记，记录跟着走)
  buffer.mark_start = function(line, col)
    for index = #footnotes, 1, -1 do
      local footnote = footnotes[index]
      if footnote.line == line and footnote.col_to == col then
        return footnote.col_from
      end
    end
    return nil
  end
  buffer.on_carry = function(old_line, cut_col, new_line, new_col)
    for _, footnote in ipairs(footnotes) do
      if footnote.line == old_line and footnote.col_from >= cut_col then
        footnote.line = new_line
        footnote.col_from = new_col + footnote.col_from - cut_col
        footnote.col_to = new_col + footnote.col_to - cut_col
      end
    end
  end

  ---@param style weread.css.Style
  ---@param tag_name string
  local function open_from_style(style, tag_name)
    for _, spec in ipairs(STYLE_KINDS) do
      if style[spec.key] then
        open_style(tag_name, spec.kind, spec.marker)
      end
    end
  end

  ---Cells for a CSS length in em. One em is one Chinese character, i.e. two
  ---cells, which is the unit a book measures indentation and padding in.
  ---(把 em 单位的 CSS 长度换成单元格：1em 等于一个汉字即两格，书就是用这个单位量缩进
  --- 与内边距的)
  ---@param em number|nil
  ---@return integer
  local function em_cells(em)
    if not em or em <= 0 then
      return 0
    end
    return math.floor(em * 2 + 0.5)
  end

  ---The text a first-line indent of `em` should be made of, so a wrapped line
  ---still lines up on the page's cell grid.
  ---(em 值对应的首行缩进文本，让折行后仍然对齐在版心的单元格网格上)
  ---@param em number|nil
  ---@return string
  local function indent_text(em)
    local cells = em_cells(em)
    if cells <= 0 then
      return ""
    end
    return string.rep("　", math.floor(cells / 2)) .. string.rep(" ", cells % 2)
  end

  ---Layout of the innermost enclosing block, key by key.
  ---(最内层块级排版，逐键取最内层的值)
  ---@return weread.css.Style
  local function effective_layout()
    local merged = {}
    for index = #layout_stack, 1, -1 do
      for key, value in pairs(layout_stack[index].style or {}) do
        if merged[key] == nil then
          merged[key] = value
        end
      end
    end
    return merged
  end

  ---Hand the resolved CSS of a block to the line buffer.
  ---(把某个块解析出的 CSS 交给行缓冲)
  ---@param style weread.css.Style
  local function apply_block_layout(style)
    local align = style.align
    if align == "justify" or align == "left" then
      align = nil
    end
    local small = style.size ~= nil and style.size < 0.95
    local pad_left = em_cells(style.padding_left)
    local pad_right = em_cells(style.padding_right)
    if small then
      -- A terminal cannot shrink a glyph, so small print is inset and dimmed
      -- instead: it reads as a footnote rather than as body text. A block that
      -- already carries padding (a quote) is inset enough as it is.
      -- (终端改不了字形大小，小字改用内缩加淡色表达：读起来像脚注而不是正文。已经自带
      --  padding 的块（引文）就不必再加)
      if pad_left == 0 then
        pad_left = 2
      end
      if pad_right == 0 then
        pad_right = 2
      end
    end
    buffer:set_layout({
      align = align,
      small = small,
      translation = translating,
      accent = style.color ~= nil and not css.is_neutral_color(style.color),
      indent = (#lists > 0 and "") or (style.indent ~= nil and indent_text(style.indent)) or nil,
      pad_left = pad_left,
      pad_right = pad_right,
      lead = quote_lead(),
      hang = #lists > 0 and lists[#lists].hang or "",
    })
  end

  ---Add characters to the cell being read: items from the source keep their
  ---runes; text the book does not have (an image's alt) has none.
  ---(往正在读的单元格里加字符：来自源文的项保留各自的 rune；书里没有的文字（插图的替代文字）没有)
  ---@param text string|nil plain text, unmapped(不映射的纯文本)
  ---@param items table[]|nil prose items { char, from, to, white }
  ---@param mapped boolean|nil the items come from the book(这些项来自书里)
  function cell_text(text, items, mapped)
    local cell = tbl and tbl.cell
    if not cell then
      return
    end
    if not items then
      items = {}
      for _, char in ipairs(vim.fn.split(text or "", "\\zs")) do
        items[#items + 1] = { char = char, white = char == " " }
      end
    end
    for _, item in ipairs(items) do
      if item.white and (#cell.items == 0 or cell.pending_break or (cell.items[#cell.items] or {}).white) then
        -- no space at the start of a cell's line, nor two in a row
        -- (单元格的行首不留空格，也不连着两个)
      else
        if cell.pending_break and #cell.items > 0 then
          cell.items[#cell.items + 1] = { char = "", brk = true }
        end
        cell.pending_break = false
        cell.items[#cell.items + 1] = {
          char = item.char,
          from = mapped and item.from or nil,
          to = mapped and item.to or nil,
          white = item.white or nil,
        }
      end
    end
  end

  ---Lay out the table just read and write it to the page.
  ---(把刚读完的表格排好、写到页面上)
  function close_table()
    local done = tbl
    tbl = nil
    if not done then
      return
    end
    -- trailing spaces of a cell are not content (单元格末尾的空格不是内容)
    for _, row in ipairs(done.rows) do
      for _, cell in ipairs(row.cells) do
        while #cell.items > 0 and (cell.items[#cell.items].white or cell.items[#cell.items].brk) do
          table.remove(cell.items)
        end
        for index = #cell.open, 1, -1 do
          local entry = cell.open[index]
          if #cell.items >= entry.from then
            cell.styles[#cell.styles + 1] = { kind = entry.kind, from = entry.from, to = #cell.items }
          end
        end
        cell.open = {}
      end
    end
    buffer:set_layout({ indent = "", lead = quote_lead() })
    local first_line = #buffer.lines
    table_module.emit(buffer, done, { page_width = page_width, styles = styles })
    table_lines[#table_lines + 1] = { first_line, #buffer.lines - 1 }
    -- the footnote marks inside cells now know where they are
    -- (单元格里的脚注标记此刻知道自己在哪了)
    for _, row in ipairs(done.rows) do
      for _, cell in ipairs(row.cells) do
        for _, item in ipairs(cell.items) do
          if item.token and footnotes[item.token] and item.line then
            local note = footnotes[item.token]
            note.line, note.col_from, note.col_to = item.line, item.col_from, item.col_to
          end
        end
        for _, quote in ipairs(cell.quotes or {}) do
          local first, last = cell.items[quote.from], cell.items[quote.to]
          if first and last and first.line and first.line == last.line then
            footnotes[#footnotes + 1] = { line = first.line, col_from = first.col_from, col_to = last.col_to, text = "", ref = quote.ref }
          end
        end
      end
    end
    if saved_table_layout then
      buffer:set_layout(saved_table_layout)
      saved_table_layout = nil
    end
    buffer:gap()
  end

  ---@param tag string
  ---@param after integer|nil source offset just past the tag(标签之后的源码偏移)
  local function handle_tag(tag, after)
    local close = tag:match("^%s*/") ~= nil
    local tag_name = (tag:match("^%s*/?%s*([%a][%w%-]*)")) or ""
    tag_name = tag_name:lower()
    if tag_name == "" then
      return
    end

    -- Resolved once: the block layout and the inline styling both want it, and
    -- it is a pure function of the tag's attributes.
    -- (只解析一次：块级排版与行内样式都要用它，而它只是标签属性的纯函数)
    local resolved_style = css.resolve(attr(tag, "class"), attr(tag, "style"), class_styles, tag_name)
    if not close and tag_name == "center" then
      -- the obsolete tag books still use; treat it as CSS would
      -- (书里仍在用的旧标签，按 CSS 的语义处理)
      resolved_style = css.merge(resolved_style, { align = "center" })
    end
    local is_block = LAYOUT_TAGS[tag_name] == true or HEADINGS[tag_name] ~= nil
    if not close and is_block then
      layout_stack[#layout_stack + 1] = { tag = tag_name, style = resolved_style }
    end

    -- Notes are found by id: remember the text of every element that has one.
    -- An anchor with an id inside a note (`footnote_content_1`) stands for the
    -- whole note, so it is an alias of the element around it.
    -- (注释靠 id 找：记下每个带 id 的元素的文字。注释里带 id 的锚点（`footnote_content_1`）
    --  代表整条注释，因此作为外层元素的别名)
    --
    -- Real books often put the id on the anchor alone:
    -- `<p class="footnote_content"><a id="footnote_content_9">[9]</a>注释</p>`.
    -- Such an anchor holds nothing but the back-link number, so its capture stays
    -- open until the block around it closes, and it gets the whole note.
    -- (真实书籍常常只在锚点上写 id：`<p class="footnote_content"><a id="footnote_content_9">[9]</a>注释</p>`。
    --  这种锚点里只有回链序号，因此它的捕获一直保持到外层块闭合，拿到整条注释)
    if close then
      for index = #captures, 1, -1 do
        local capture = captures[index]
        if capture.tag == tag_name and not capture.block then
          for _ = #captures, index, -1 do
            local closed = table.remove(captures)
            id_text[closed.id] = table.concat(closed.parts)
          end
          break
        end
      end
    elseif not translating and not VOID_TAGS[tag_name] and not tag:match("/%s*$") then
      -- a translation repeats its original's id: the note is the original's
      -- (译文会重复原文的 id：注释以原文为准)
      local id = attr(tag, "id")
      if id and id ~= "" then
        if tag_name == "a" and #captures > 0 then
          id_alias[id] = captures[1].id
        end
        local block = nil
        if tag_name == "a" and #layout_stack > 0 and not (attr(tag, "class") or ""):find("footnote_quote") then
          block = #layout_stack
        end
        captures[#captures + 1] = { tag = tag_name, id = id, parts = {}, block = block }
      end
    end

    -- A link to a note: the link text is the mark, the note is found later by id.
    -- (指向注释的链接：链接文字就是标记，注释稍后按 id 找到)
    if tag_name == "a" and tbl and tbl.cell then
      -- a link to a note inside a cell: its items become the mark once the table
      -- is laid out (单元格里指向注释的链接：表格排好之后，它的那些项就是标记)
      local cell = tbl.cell
      if close and cell.quote then
        if #cell.items >= cell.quote.from then
          cell.quotes[#cell.quotes + 1] = { from = cell.quote.from, to = #cell.items, ref = cell.quote.ref }
        end
        cell.quote = nil
      elseif not close and (attr(tag, "class") or ""):find("footnote_quote") then
        local href = attr(tag, "href") or ""
        cell.quote = { from = #cell.items + 1, ref = href:match("#(.+)$") or href }
      end
    elseif tag_name == "a" then
      if close and open_quote then
        if not skip_heading then
          local line, col_from = open_quote.line, open_quote.col_from
          if line ~= #buffer.lines then
            -- the page broke inside (or right before) the mark, `[` being carried
            -- along: the mark is what sits at the start of the new line
            -- (版心在标记内部或紧挨着它之前折断，`[` 也被带走了：标记就是新行开头那一段)
            line, col_from = #buffer.lines, #buffer.layout.rest
          end
          if buffer.col > col_from then
            footnotes[#footnotes + 1] = {
              line = line,
              col_from = col_from,
              col_to = buffer.col,
              text = "",
              ref = open_quote.ref,
            }
          end
        end
        open_quote = nil
      elseif not close and (attr(tag, "class") or ""):find("footnote_quote") then
        buffer:flush_indent()
        local href = attr(tag, "href") or ""
        open_quote = {
          line = #buffer.lines,
          col_from = buffer.col,
          ref = href:match("#(.+)$") or href,
        }
      end
    end

    if close then
      -- Close any styling this tag opened first, so the closing markers land
      -- before a block separator ends the line.
      -- (先闭合本标签打开的样式，让闭合标记落在段落分隔结束本行之前)
      close_styles(tag_name)
      for index = #layout_stack, 1, -1 do
        if layout_stack[index].tag == tag_name then
          -- leaving a block restores the layout of the block around it
          -- (离开一个块，就回到外层的排版)
          table.remove(layout_stack, index)
          break
        end
      end
      -- anchors held open for the block that just closed end with it
      -- (为刚闭合的块而保持打开的锚点随之结束)
      for index = #captures, 1, -1 do
        local capture = captures[index]
        if capture.block and capture.block > #layout_stack then
          table.remove(captures, index)
          id_text[capture.id] = table.concat(capture.parts)
        end
      end
      if skip_heading then
        skip_heading = false
        in_heading = false
        open_heading = nil
        return
      end

      -- Closing block tags otherwise do nothing: the *next* block's separator
      -- ends the line, which keeps adjacent paragraphs tight. Headings and
      -- blockquotes add their own breathing room.
      -- (除此之外闭合块标签不做处理：下一块开始时的分隔会结束本行，相邻段落因此紧凑；
      --  标题与引用会自己补留白)
      if tbl then
        if tag_name == "table" then
          tbl.depth = tbl.depth - 1
          if tbl.depth == 0 then
            close_table()
          end
        elseif tbl.depth == 1 and (tag_name == "td" or tag_name == "th") then
          tbl.cell = nil
        elseif tbl.depth == 1 and tag_name == "tr" then
          tbl.row = nil
          tbl.cell = nil
        elseif tbl.depth == 1 and tag_name == "thead" then
          tbl.in_head = false
        elseif tbl.depth == 1 and tag_name == "caption" then
          tbl.caption = false
          buffer:newline()
        elseif tbl.cell and (LAYOUT_TAGS[tag_name] or HEADINGS[tag_name]) then
          -- the end of a paragraph inside a cell: the next one starts a new
          -- line of the cell (单元格里一段结束：下一段从这一格的新一行开始)
          tbl.cell.pending_break = true
        end
        return
      end
      if HEADINGS[tag_name] then
        in_heading = false
        open_heading = nil
        buffer:gap()
      elseif tag_name == "blockquote" then
        -- A blank line ends the quote: without one, the next paragraph would be
        -- read as a lazy continuation of the quote's last line.
        -- (空行结束引文：没有它，下一段会被当作引文最后一行的惰性续行)
        buffer:newline()
        quote_depth = math.max(0, quote_depth - 1)
        apply_block_layout(effective_layout())
        buffer:blank()
        buffer:separate()
      elseif tag_name == "ul" or tag_name == "ol" then
        -- the same for a list, or the next paragraph joins its last item
        -- (列表同理，否则下一段会并入最后一项)
        buffer.awaiting_item = false
        buffer:newline()
        table.remove(lists)
        apply_block_layout(effective_layout())
        if #lists == 0 then
          buffer:blank()
        end
        buffer:separate()
      elseif tag_name == "pre" then
        buffer.verbatim = false
        -- the last code line has no line break of its own, and the fence must not
        -- end up on it(最后一行代码自己没有换行，围栏不能落到它上面)
        buffer:newline()
        buffer:block_marker("```")
        buffer:gap()
      end
      return
    end

    -- ---------------------------------------------------------------- structure
    if tbl then
      if tag_name == "table" then
        -- a table inside a cell is read as more text of that cell
        -- (单元格里的表格当作这一格的更多文字来读)
        tbl.depth = tbl.depth + 1
        if tbl.cell and #tbl.cell.items > 0 then
          tbl.cell.pending_break = true
        end
      elseif tbl.depth == 1 and tag_name == "caption" then
        tbl.caption = true
        buffer:newline()
        buffer:set_layout({ indent = "", small = true, lead = quote_lead() })
      elseif tbl.depth == 1 and tag_name == "thead" then
        tbl.in_head = true
      elseif tbl.depth == 1 and tag_name == "tr" then
        tbl.row = { cells = {}, header = tbl.in_head }
        tbl.rows[#tbl.rows + 1] = tbl.row
        tbl.cell = nil
      elseif tbl.depth == 1 and (tag_name == "td" or tag_name == "th") then
        if not tbl.row then
          tbl.row = { cells = {}, header = tbl.in_head }
          tbl.rows[#tbl.rows + 1] = tbl.row
        end
        tbl.cell = {
          items = {},
          styles = {},
          open = {},
          quotes = {},
          header = tag_name == "th",
          rowspan = math.max(1, math.min(50, tonumber(attr(tag, "rowspan") or "") or 1)),
          colspan = math.max(1, math.min(20, tonumber(attr(tag, "colspan") or "") or 1)),
        }
        tbl.row.cells[#tbl.row.cells + 1] = tbl.cell
      elseif tbl.cell and (tag_name == "br" or LAYOUT_TAGS[tag_name] or HEADINGS[tag_name]) then
        if #tbl.cell.items > 0 then
          tbl.cell.pending_break = true
        end
      elseif tbl.cell and tag_name == "img" and (attr(tag, "class") or ""):find("qqreader%-footnote") then
        -- a footnote mark in a cell: a token now, a footnote once it has a place
        -- (单元格里的脚注标记：先是一个记号，有了位置之后才是脚注)
        if not skip_heading then
          local number = #footnotes + 1
          local mark = string.format("[%d]", number)
          if vim.o.ambiwidth == "double" and number <= 20 then
            mark = vim.fn.nr2char(0x2460 + number - 1)
          end
          footnotes[number] = { line = 0, col_from = 0, col_to = 0, text = vim.trim(M.decode_entities(attr(tag, "alt") or "")) }
          tbl.cell.items[#tbl.cell.items + 1] = { char = mark, token = number }
        end
      elseif tbl.cell and tag_name == "img" then
        -- a figure in a cell is its alt text (单元格里的插图写成它的替代文字)
        local alt = vim.trim(M.decode_entities(attr(tag, "alt") or ""))
        if alt ~= "" then
          cell_text("〔" .. alt .. "〕")
        end
      end
      -- inline styling inside a cell still opens (below); nothing else does
      -- (单元格里的行内样式照常打开（见下文）；其余一概不做)
      if tbl.cell and not (attr(tag, "class") or ""):find("qqreader%-footnote") then
        local tag_style = INLINE_TAGS[tag_name]
        if tag_style then
          open_style(tag_name, tag_style.kind, tag_style.marker)
        end
        if not css.is_empty(resolved_style) then
          open_from_style(resolved_style, tag_name)
        end
      end
      return
    end
    if tag_name == "pre" then
      -- A code listing is not prose: its line breaks and indentation are the
      -- point, while the prose layout would collapse all of it into one line.
      -- (代码清单不是散文：它的换行与缩进就是要表达的内容，而散文排版会把它压成一行)
      buffer:gap()
      -- The fence has to name a language or nothing downstream will highlight a
      -- line of it. Books do not name one, so it is read off the listing: the
      -- body is looked up in the source, ahead of where the scan has got to.
      -- (围栏必须写出语言，否则后面一步都不会给它上色。书里不写，因此从清单内容读：正文直接
      --  在源码里向前找，位置超前于扫描进度)
      local fence = "```"
      if after then
        local close = source:find("</pre>", after, true)
        if close then
          local body = M.decode_entities(source:sub(after, close - 1):gsub("<[^>]*>", ""))
          -- `%-` and not `-`: a bare hyphen is the lazy repetition modifier in a
          -- Lua pattern, and `language-` would be read as `languag` + `e-`.
          -- (要用 `%-` 而不是 `-`：在 Lua 模式里裸连字符是懒惰重复修饰符，`language-` 会被读成
          --  `languag` 加 `e-`)
          local language = attr(tag, "class") and attr(tag, "class"):match("language%%-([%w][%w%-+]*)")
            or M.language_of(body)
          if language then
            fence = "```" .. language
          end
        end
      end
      buffer:block_marker(fence)
      buffer:newline()
      buffer.verbatim = true
    elseif HEADINGS[tag_name] then
      if translating then
        -- a heading's translation follows its original, dropped or not
        -- (标题的译文跟着原标题走：原标题被丢掉，译文也丢掉)
        skip_heading = skipped_original
        skipped_original = false
      else
        headings_seen = headings_seen + 1
        -- The winbar already shows the book and chapter, so repeating the title
        -- as the first heading only costs two rows. Later headings carry real
        -- structure and stay.
        -- (winbar 已经显示书名与章节，正文里再重复一次标题只是白花两行；后面的标题承担
        --  真正的结构信息，保留)
        skip_heading = skip_title and headings_seen == 1
        skipped_original = skip_heading
      end
      if not skip_heading then
        buffer:gap()
        local level = math.min(6, math.max(1, HEADINGS[tag_name] + heading_offset))
        local style = effective_layout()
        if level == 1 and page_width > 0 and not tbl and style.align ~= "right" then
          -- a chapter-level heading is centred, as the app sets it
          -- (章级标题居中，和 App 一致)
          style = css.merge(style, { align = "center" })
        end
        apply_block_layout(style)
        in_heading = true
        -- `# ` is concealed by the reader, so it costs no width on the page
        -- (`# ` 由阅读器隐藏，因此在页面上不占宽度)
        buffer:block_marker(string.rep("#", level) .. " ", heading_cells(level))
        headings[#headings + 1] = { line = #buffer.lines, level = level }
        open_heading = { level = level, marker = string.rep("#", level) .. " " }
      end
    elseif (tag_name == "ul" or tag_name == "ol") and not tbl then
      buffer.awaiting_item = false
      buffer:newline()
      local parent = lists[#lists]
      if not parent then
        -- a list sets itself off from the paragraph before it, as it does after
        -- (列表与前一段之间空一行，与它和后一段之间一样)
        buffer:blank()
      end
      lists[#lists + 1] = {
        ordered = tag_name == "ol",
        next = tonumber(attr(tag, "start") or "") or 1,
        -- a nested list starts under its parent item's text
        -- (嵌套列表从父列表项的文字下方开始)
        base = parent and parent.hang or "",
        hang = parent and parent.hang or "",
      }
    elseif tag_name == "li" and not tbl then
      buffer.awaiting_item = false
      buffer:newline()
      local list = lists[#lists]
      if not list then
        -- an item outside any list: a bullet all the same
        -- (不在任何列表里的列表项：照样当作无序项)
        list = { ordered = false, next = 1, base = "", hang = "" }
        lists[#lists + 1] = list
      end
      local marker = "- "
      if list.ordered then
        marker = string.format("%d. ", list.next)
        list.next = list.next + 1
      end
      list.hang = list.base .. string.rep(" ", #marker)
      apply_block_layout(effective_layout())
      buffer:block_marker(list.base .. marker)
      -- the item's text, often wrapped in a `<p>`, goes on the marker's line
      -- (列表项的文字常常包在 `<p>` 里，它要写在标记那一行)
      buffer.awaiting_item = true
    elseif tag_name == "blockquote" then
      buffer:separate()
      quote_depth = quote_depth + 1
      apply_block_layout(effective_layout())
    elseif tag_name == "br" then
      -- A hard break inside a paragraph reads better as a real line break in
      -- the editor, which is what plain markdown soft wrapping gives us.
      -- (段落内的换行在编辑器里就是真换行，也就是 markdown 的软换行)
      buffer:newline()
    elseif tag_name == "hr" then
      -- blank lines on both sides whatever the gap mode: `---` right under a line of
      -- text turns that text into a heading
      -- (不论留白模式，两侧都要空行：紧贴在一行文字下面的 `---` 会把那行文字变成标题)
      buffer:newline()
      buffer:blank()
      buffer:block_marker("---")
      buffer:newline()
      buffer:blank()
    elseif translating and tag_name == "img" then
      -- the original already carries the figure or the footnote mark
      -- (插图与脚注标记原文里已经有了)
      return
    elseif tag_name == "img" and (attr(tag, "class") or ""):find("qqreader%-footnote") then
      -- A footnote is a mark in the running text, not a figure: it must not
      -- break the line, and its note is its alt text.
      -- (脚注是正文里的一个标记而不是插图：它不能断行，注释内容就是它的 alt)
      if skip_heading then
        return
      end
      local number = #footnotes + 1
      local mark = string.format("[%d]", number)
      if vim.o.ambiwidth == "double" and number <= 20 then
        mark = vim.fn.nr2char(0x2460 + number - 1)
      end
      local line, col_from, col_to = buffer:token(mark)
      footnotes[number] = {
        line = line,
        col_from = col_from,
        col_to = col_to,
        text = vim.trim(M.decode_entities(attr(tag, "alt") or "")),
      }
      return
    elseif tag_name == "img" then
      local src = attr(tag, "src") or ""
      local alt = M.decode_entities(attr(tag, "alt") or "")
      local resolved = src
      if resolve_image then
        resolved = resolve_image(src) or src
      end
      images[#images + 1] = { src = src, resolved = resolved, alt = alt }
      buffer:gap()
      -- On screen this line becomes `<icon> <alt>`: the reader conceals `![` into
      -- the icon and `](path)` into nothing, so that is the width to reserve.
      -- (这一行在屏幕上会变成 `<图标> <alt>`：阅读器把 `![` 隐藏成图标、把 `](路径)` 隐藏成
      --  空，因此要按那个宽度占位)
      local icon_cells = display_width((config.get().image or {}).icon or "⧉")
      figure_lines[#buffer.lines] = true
      buffer:block_marker(string.format("![%s](%s)", alt, resolved), icon_cells + 1 + display_width(alt))
      -- No gap after: a caption belongs to its figure, and markdown still parses
      -- the image as its own paragraph.
      -- (后面不留空：图注属于插图，且 markdown 仍会把图片解析成独立段落)
      buffer:newline()
      return
    elseif tag_name == "table" then
      buffer:gap()
      saved_table_layout = buffer.layout
      tbl = { rows = {}, row = nil, cell = nil, depth = 1, in_head = false }
    elseif BLOCK_TAGS[tag_name] then
      buffer:separate()
      apply_block_layout(effective_layout())
    end
    -- the block of the original starts here, on its own line now; not in a
    -- table, whose cells share a line
    -- (原文的块从这里开始，此时已经另起一行；表格里不记：表格按格排在一行上)
    if not translating then
      if tbl then
        original_from = nil
      elseif is_block then
        original_from = #buffer.lines
      end
    end

    -- ---------------------------------------------------------------- styling
    -- Emphasis is often expressed as a stylesheet class or an inline style
    -- rather than `<b>`; resolving both is what keeps bold text bold.
    -- (强调常常由样式表类或行内 style 表达而不是 `<b>`；两者都解析才能保住加粗)
    -- A dropped title must not leave its emphasis markers behind either: a
    -- styled `<h1 class="title">` used to emit a stray `****` on an otherwise
    -- empty line.
    -- (被丢弃的标题也不能留下强调标记：带样式的 `<h1 class="title">` 曾经在一行空白上
    --  留下 `****`)
    if not in_heading and not skip_heading then
      local tag_style = INLINE_TAGS[tag_name]
      if tag_style then
        open_style(tag_name, tag_style.kind, tag_style.marker)
      end
      if not css.is_empty(resolved_style) then
        open_from_style(resolved_style, tag_name)
      end
    end
  end

  while pos <= #source do
    local inside, upcoming = translation_at(pos)
    translating = inside ~= nil
    local lt = source:find("<", pos, true)
    if not lt then
      break
    end
    -- A translation block starts with the line break in front of it: the text
    -- before that break is the original's, the break itself is not.
    -- (译文块从它前面的换行开始：换行之前的文字属于原文，换行本身不属于)
    local text_end = lt - 1
    if not inside and upcoming and upcoming[1] <= text_end then
      text_end = upcoming[1] - 1
    end

    if tbl and tbl.cell and lt > pos and (translating or text_end >= pos) then
      -- text inside a table cell: kept with the cell until the table is laid out;
      -- a translation of it is the cell's next line, outside the offset map
      -- (表格单元格里的文字：先跟着这一格，等表格排版；它的译文是这一格的下一行，不进偏移表)
      local stop = translating and (lt - 1) or text_end
      local raw = source:sub(pos, stop)
      if not translating then
        rune = rune + count_runes(raw)
      end
      local items = prose_spans(raw, rune - count_runes(raw))
      if items then
        if translating and #tbl.cell.items > 0 and not tbl.cell.translated then
          tbl.cell.pending_break = true
          tbl.cell.translated = true
        end
        local decoded = join_spans(items)
        for _, capture in ipairs(captures) do
          capture.parts[#capture.parts + 1] = decoded
        end
        cell_text(nil, items, not translating)
      end
    elseif tbl and not tbl.cell and text_end >= pos and not translating then
      -- between the cells (the white space around `<tr>`), or a caption: a
      -- caption is set as a line above the table, the rest only counts runes
      -- (单元格之间（`<tr>` 周围的空白）或者表题：表题排在表格上方一行，其余只计 rune)
      local raw = source:sub(pos, text_end)
      rune = rune + count_runes(raw)
      local items = prose_spans(raw, rune - count_runes(raw))
      if items and tbl.caption then
        local first = (buffer:is_empty() and items[1].white) and 2 or 1
        if first <= #items then
          local text, spans = join_spans(items, first)
          buffer:append(text, spans[1], spans[#spans], spans)
        end
      end
    elseif tbl and not tbl.cell and translating then
      -- a translated caption goes under the caption (表题的译文排在表题下面)
      local items = tbl.caption and prose_spans(source:sub(pos, lt - 1), 0)
      if items then
        buffer:newline()
        local first = items[1].white and 2 or 1
        if first <= #items then
          buffer:append((join_spans(items, first)))
        end
      end
    elseif translating and lt > pos then
      -- translated text: on the page, outside the offset map
      -- (译文文字：在页面上，但不进 offset map)
      local items = not skip_heading and prose_spans(source:sub(pos, lt - 1), 0)
      if items then
        local first = (buffer:is_empty() and items[1].white) and 2 or 1
        if first <= #items then
          -- The translation opened on a line of its own, so every line of its
          -- original is written by now, with the blank line a heading leaves
          -- before its translation. Marked on the first text actually shown: a
          -- translation that is dropped hides nothing.
          -- (译文另起一行开始，它的原文此时已全部写下，连同标题与其译文之间的空行。在第一段真正
          --  显示的译文处标记：被丢掉的译文不隐藏任何东西)
          if original_from then
            for line = original_from, #buffer.lines - 1 do
              local meta = buffer.lines_meta[line]
              if not (meta and meta.translation) and not figure_lines[line] then
                originals[#originals + 1] = line
              end
            end
            original_from = nil
          end
          buffer:append((join_spans(items, first)))
        end
      end
    elseif text_end >= pos then
      local raw = source:sub(pos, text_end)
      rune = rune + count_runes(raw)
      -- A dropped chapter title must not emit its text either, but its runes
      -- still count so every later offset stays aligned with the source.
      -- (被丢弃的章节标题连文字一起丢掉，但 rune 仍要计数，保证后续偏移与源码对齐)
      if not skip_heading then
        if buffer.verbatim then
          -- Verbatim: every source line is a line, indentation included, and the
          -- code fence is what keeps the layout when the file is read elsewhere.
          -- (逐字：源码里的每一行就是一行（含缩进），而代码围栏保证别处打开时布局还在)
          -- CRLF is a line ending, not a character: a listing full of `^M` is
          -- what it looks like when it is not normalised.
          -- (CRLF 是行尾而不是字符：不归一化的话清单里会全是 `^M`)
          -- The split is done on the source characters, not on decoded text, so
          -- every character keeps its own runes: an entity is several, and the
          -- `\r` of a CRLF is one more that never reaches the page.
          -- (按源字符而不是解码后的文本切行，每个字符因此保有自己的 rune：实体占多个，而 CRLF
          --  里的 `\r` 是一个永远不上页面的 rune)
          local items = decode_spans(raw, rune - count_runes(raw))
          local pieces, first = {}, 1
          for index, item in ipairs(items) do
            if item.char == "\n" or item.char == "\r" then
              if not (item.char == "\n" and index > 1 and items[index - 1].char == "\r") then
                pieces[#pieces + 1] = { first, index - 1 }
              end
              first = index + 1
            end
          end
          pieces[#pieces + 1] = { first, #items }
          for index, bounds in ipairs(pieces) do
            local piece, spans = join_spans(items, bounds[1], bounds[2])
            if piece ~= "" or not buffer:is_empty() then
              buffer:append(piece, spans[1] or 0, spans[#spans], spans)
            end
            -- Only a line break in the source ends a line: the end of a text node
            -- is merely where a tag starts, and `x = <b>1</b>` is one line.
            -- (只有源码里的换行才结束一行：文本节点的结尾只是标签开始的地方，`x = <b>1</b>`
            --  是同一行)
            if index < #pieces then
              buffer:newline()
            end
          end
        else
          local items = prose_spans(raw, rune - count_runes(raw))
          if items then
            local decoded = join_spans(items)
            for _, capture in ipairs(captures) do
              capture.parts[#capture.parts + 1] = decoded
            end
            -- the stripped space takes its runes along: the text starts after it
            -- (被去掉的空格带走它的 rune：正文从它后面开始)
            local first = (buffer:is_empty() and items[1].white) and 2 or 1
            if first <= #items then
              local text, spans = join_spans(items, first)
              buffer:append(text, spans[1], spans[#spans], spans)
            end
          end
        end
      end
    end

    if text_end < lt - 1 and not translating then
      -- stopped short at a translation block: go on from its line break
      -- (停在译文块前面：从它的换行处接着读)
      pos = text_end + 1
    elseif source:sub(lt, lt + 3) == "<!--" then
      local close = source:find("-->", lt + 4, true)
      local stop = close and (close + 2) or #source
      if not translating then
        rune = rune + count_runes(source:sub(lt, stop))
      end
      pos = stop + 1
    elseif SKIP_BODIES[source:sub(lt + 1, lt + 6):lower():match("^(%a+)") or ""] then
      -- Skip bodies that are not prose: stylesheets, scripts and everything in
      -- <head>. A real chapter ships `<title>` and a `<style>` block, and both
      -- used to leak into the text.
      -- (跳过非正文的元素：样式表、脚本，以及 <head> 里的一切。真实章节带 `<title>`
      --  与 `<style>`，它们原本都会漏进正文)
      -- Runes are still counted so offsets stay aligned with the source.
      -- (rune 仍计数，保证偏移与源码对齐)
      local tag_name = source:sub(lt + 1, lt + 6):lower():match("^(%a+)")
      local close = source:lower():find("</" .. tag_name, lt, true)
      -- inside a translation block nothing counts: it is not in the book
      -- (译文块里的东西都不计数：它不在书里)
      if close then
        local gt = source:find(">", close, true) or #source
        if not translating then
          rune = rune + count_runes(source:sub(lt, gt))
        end
        pos = gt + 1
      else
        local gt = source:find(">", lt, true) or #source
        if not translating then
          rune = rune + count_runes(source:sub(lt, gt))
        end
        pos = gt + 1
      end
    else
      local gt = source:find(">", lt, true)
      if not gt then
        break
      end
      local tag = source:sub(lt + 1, gt - 1)
      if not translating then
        rune = rune + count_runes(source:sub(lt, gt))
      end
      handle_tag(tag, gt + 1)
      pos = gt + 1
    end
  end

  -- trailing text
  if pos <= #source then
    local raw = source:sub(pos)
    rune = rune + count_runes(raw)
    local items = prose_spans(raw, rune - count_runes(raw))
    if items and not skip_heading then
      local text, spans = join_spans(items)
      buffer:append(text, spans[1], spans[#spans], spans)
    end
  end

  -- a chapter that ends inside a note still has the note
  -- (章节在注释内部结束时，注释照样保留)
  for _, capture in ipairs(captures) do
    if id_text[capture.id] == nil then
      id_text[capture.id] = table.concat(capture.parts)
    end
  end

  local text = buffer:get()
  local map = buffer.map

  -- Notes referred to by id, now that every one of them has been read.
  -- (按 id 引用的注释：此时每一条都已经读到了)
  for id, alias in pairs(id_alias) do
    if id_text[alias] then
      id_text[id] = id_text[alias]
    end
  end
  for _, footnote in ipairs(footnotes) do
    if footnote.ref and footnote.text == "" then
      local note = vim.trim((id_text[footnote.ref] or ""):gsub("%s+", " "))
      -- the note usually opens with its own back-link number: `[1] 注释`
      -- (注释开头通常带着自己的回链序号：`[1] 注释`)
      -- one pattern per bracket pair: a byte class cannot hold multibyte brackets
      -- (每种括号一个模式：字节类装不下多字节括号)
      for _, pattern in ipairs({ "^%[%s*%d+%s*%]%s*", "^〔%s*%d+%s*〕%s*", "^【%s*%d+%s*】%s*" }) do
        note = note:gsub(pattern, "")
      end
      footnote.text = note
    end
  end

  -- Prefer emitting a trailing newline structure-free body: the reader buffer
  -- adds its own padding.
  -- (正文尾部不额外补空行，由阅读器 buffer 自行留白)
  local lines = vim.split(text, "\n", { plain = true })
  for _, segment in ipairs(map) do
    -- Segments past the trimmed tail would point at dropped blank lines; clamp
    -- them into range so lookups never index outside the buffer.
    -- (尾部空白行被裁掉后，指向它们的段落要夹回合法范围，避免查找越界)
    if segment.line >= #lines then
      segment.line = math.max(0, #lines - 1)
    end
  end

  return {
    text = text,
    map = map,
    source_runes = rune,
    images = images,
    headings = headings,
    escapes = buffer.escapes,
    -- Page width used for this render, so the reader can tell whether a cached
    -- chapter still matches the window it is about to be shown in.
    -- (本次排版的版心宽度：阅读器据此判断缓存章节是否仍然匹配它要显示的窗口)
    page_width = page_width,
    -- How the reader must pad and colour individual lines: centered titles,
    -- figure captions, small print, blocks the book painted in a colour.
    -- (阅读器要逐行处理的排版：居中标题、图注、小字、书里上了颜色的块)
    lines = buffer.lines_meta,
    -- Display-only styling: markdown cannot express underline, strike, marks
    -- or superscript, so those come back as positions the reader draws with
    -- extmarks. Bold/italic are also listed, so the reader can hide the `**`
    -- markers and apply a real bold/italic attribute instead of showing
    -- punctuation.
    -- (仅供显示的样式：markdown 表达不了下划线/删除线/高亮/上标，因此以位置形式返回，
    --  由阅读器用 extmark 绘制。粗体与斜体同样列出，这样阅读器可以隐藏 `**` 标记并
    --  改用真正的粗体/斜体属性，而不是把标点符号摆在那儿)
    styles = styles,
    -- Footnote marks on the page and the note each one stands for.
    -- (页面上的脚注标记，以及每个标记对应的注释)
    footnotes = footnotes,
    -- 0-based lines of the original that have a translation under them: hidden
    -- when the reader wants the translation alone.
    -- (下方带译文的原文行，0 基：读者只看译文时隐藏)
    originals = originals,
    -- { first, last } 0-based line ranges laid out as tables
    -- ({ 起, 止 }，0 基：排成表格的行区间)
    tables = table_lines,
  }
end

M.HANG_BUDGET = buffer_module.HANG_BUDGET
M.count_runes = count_runes
M.leading_white = buffer_module.leading_white
M.footnote_at = map_module.footnote_at
M.rune_at = map_module.rune_at
M.json_lines = map_module.json_lines
M.find_segment = map_module.find_segment
M.locate = map_module.locate
M.resolve = map_module.resolve
M.language_of = code_module.language_of

return M
