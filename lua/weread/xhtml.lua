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
]]

local config = require("weread.config")
local css = require("weread.css")

local M = {}

---Bump whenever the rendered output changes shape (paragraph handling, indents,
---image syntax...). Chapters cached by an older renderer are re-rendered from
---the cached source XHTML locally, without touching the network, so a typography
---tweak reaches books that are already downloaded.
---(渲染结果形态变化时递增（段落处理、缩进、图片语法…）。旧渲染器缓存的章节会用
--- 已缓存的源 XHTML 在本地重排，不联网，因此排版调整能作用到已下载的书)
M.VERSION = 4

local BLOCK_TAGS = {
  p = true,
  div = true,
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

local function count_runes(text)
  local count = 0
  for index = 1, #text do
    local byte = text:byte(index)
    if byte < 0x80 or byte >= 0xC0 then
      count = count + 1
    end
  end
  return count
end

M.count_runes = count_runes

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

---Line buffer that tracks byte columns so segments can record their position.
---(行缓冲：跟踪字节列号，以便段落记录自己的位置)
---
---Typesetting note: a Chinese book separates paragraphs by indentation, while
---markdown normally uses a blank line. With one blank line per paragraph, half
---of every screen is empty. Compact mode therefore emits a plain line break and
---queues a first-line indent instead.
---(排版说明：中文书靠首行缩进区分段落，而 markdown 惯例是空行。每段一个空行意味
--- 着每屏一半是空白，因此紧凑模式改为换行 + 首行缩进)
local Buffer = {}
Buffer.__index = Buffer

---@param opts table|nil { compact, indent }
function Buffer.new(opts)
  opts = opts or {}
  return setmetatable({
    lines = {},
    current = {},
    col = 0,
    map = {},
    compact = opts.compact ~= false,
    indent = opts.indent or "",
    no_gap = opts.no_gap == true,
    pending_indent = false,
  }, Buffer)
end

function Buffer:append(text, src_from, src_to)
  if text == "" then
    return
  end
  if self.pending_indent then
    -- TXT books already carry a full-width indent; adding another would double
    -- it. Same for text that starts with an ASCII space.
    -- (TXT 型书籍自带全角缩进，再加一次就重复了；以半角空格开头的同理)
    local head = text:sub(1, 3)
    if head == "　" or text:sub(1, 1) == " " then
      self.pending_indent = false
    else
      self:flush_indent()
    end
  end
  self.map[#self.map + 1] = {
    src_from = src_from,
    src_to = src_to,
    line = #self.lines,
    col_from = self.col,
    col_to = self.col + #text,
  }
  self.current[#self.current + 1] = text
  self.col = self.col + #text
end

---Append inline syntax with no counterpart in the source (`*`, `**`, `` ` ``).
---Markers are deliberately kept out of the offset map: a zero-width segment
---could never contain a rune and would only bloat the map. A queued indent
---survives, so a paragraph that opens with emphasis still gets indented.
---(追加源码中没有对应物的行内标记（`*`、`**`、反引号）。标记刻意不写入 offset
--- map：零宽段落永远不可能包含某个 rune，只会让 map 膨胀。排队的缩进会保留，
--- 因此以强调开头的段落仍然能正确缩进)
---@param text string
function Buffer:marker(text)
  -- Write a queued indent first: `*注意*...` must become `　　*注意*...`, not
  -- `*　　注意*...`.
  -- (先把排队的缩进落下去：`*注意*…` 应当是 `　　*注意*…`，不能变成 `*　　注意*…`)
  self:flush_indent()
  if text == "" then
    return
  end
  self.current[#self.current + 1] = text
  self.col = self.col + #text
end

---Write the queued paragraph indent, if any.
---(把排队的段落缩进写下去)
function Buffer:flush_indent()
  if not self.pending_indent then
    return
  end
  self.pending_indent = false
  if self.indent ~= "" then
    self.current[#self.current + 1] = self.indent
    self.col = self.col + #self.indent
  end
end

---Same, for markers that own a whole line (`# `, `- `, `> `, figures). These are
---structural, so a queued paragraph indent must be dropped.
---(同上，用于独占一行的标记（`# `、`- `、`> `、插图）。它们是结构性的，因此必须
--- 丢弃排队中的段落缩进)
---@param text string
function Buffer:block_marker(text)
  self.pending_indent = false
  self:marker(text)
end

function Buffer:is_empty()
  return self.col == 0
end

---Trim trailing spaces, which markdown only sees as noise.
---(去掉行尾空格，markdown 里只会变成噪音)
function Buffer:flush()
  local line = table.concat(self.current)
  -- Trailing whitespace is noise in markdown, full-width spaces included: a
  -- line holding nothing but a queued indent must disappear.
  -- (行尾空白在 markdown 里是噪音，全角空格同理：只有缩进的空行必须消失)
  line = line:gsub("[ \t]+$", ""):gsub("　+$", "")
  self.lines[#self.lines + 1] = line
  self.current = {}
  self.col = 0
end

function Buffer:newline()
  if self.col > 0 then
    self:flush()
  end
end

---Force a blank line: used around headings, figures and rules, where the extra
---breathing room is worth the vertical space.
---(强制空行：用于标题/插图/分隔线，这些地方留白值得)
function Buffer:gap()
  if self.no_gap then
    self:newline()
    return
  end
  self:newline()
  local lines = self.lines
  if #lines > 0 and lines[#lines] ~= "" then
    lines[#lines + 1] = ""
  end
end

---Separate the next paragraph from the current one.
---(分隔下一段：紧凑模式只换行并排队缩进，经典模式插入空行)
function Buffer:separate()
  self:newline()
  if self.compact then
    self.pending_indent = self.indent ~= ""
  else
    self:gap()
  end
end

---@return string
function Buffer:get()
  self:newline()
  while #self.lines > 0 and self.lines[#self.lines] == "" do
    table.remove(self.lines)
  end
  return table.concat(self.lines, "\n")
end

---@class weread.xhtml.Result
---@field text string markdown body
---@field map table[] source rune range -> markdown position
---@field source_runes integer rune length of the source XHTML
---@field images table[] image references found

---Convert chapter XHTML to markdown.
---(把章节 XHTML 转成 markdown)
---@param xhtml string
---@param opts table|nil
---   resolve_image fun(src: string): string|nil  rewrite image sources
---   heading_offset integer shift heading levels (default 0)
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
  local buffer = Buffer.new({
    compact = paragraph.compact,
    indent = paragraph.indent,
    no_gap = gap_mode == "none",
  })
  local images = {}
  local styles = {}
  local rune = 0
  local pos = 1
  -- The book stylesheet plus the chapter's own <style> block; the chapter wins,
  -- because that is what the markup next to it was written against.
  -- (书籍样式表 + 章节自带的 <style> 块；以章节为准，因为紧跟其后的标记就是照着它写的)
  local class_styles = opts.styles
    or css.merge_maps(css.parse(opts.css), css.parse(M.inline_stylesheet(source)))

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
  local headings_seen = 0

  ---@param tag_name string
  ---@param kind string
  ---@param marker string|nil markdown syntax to wrap the content with
  local function open_style(tag_name, kind, marker)
    -- Write any queued paragraph indent first: a style span must start at the
    -- content, not chew up the indentation.
    -- (先落下排队中的段落缩进：样式区间必须从内容开始，不能把缩进也吞进去)
    buffer:flush_indent()
    if marker then
      buffer:marker(marker)
    end
    local entry = {
      kind = kind,
      marker = marker,
      line = #buffer.lines,
      col_from = buffer.col,
    }
    local group = open_groups[#open_groups]
    if not group or group.tag ~= tag_name then
      group = { tag = tag_name, entries = {} }
      open_groups[#open_groups + 1] = group
    end
    group.entries[#group.entries + 1] = entry
  end

  ---@param tag_name string
  local function close_styles(tag_name)
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
    for index = #open_groups, found, -1 do
      local group = table.remove(open_groups)
      for entry_index = #group.entries, 1, -1 do
        local entry = group.entries[entry_index]
        if entry.line == #buffer.lines and buffer.col > entry.col_from then
          styles[#styles + 1] = {
            line = entry.line,
            col_from = entry.col_from,
            col_to = buffer.col,
            kind = entry.kind,
            markers = entry.marker and #entry.marker or 0,
          }
        end
        if entry.marker then
          buffer:marker(entry.marker)
        end
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

  ---@param tag string
  local function handle_tag(tag)
    local close = tag:match("^%s*/") ~= nil
    local tag_name = (tag:match("^%s*/?%s*([%a][%w%-]*)")) or ""
    tag_name = tag_name:lower()
    if tag_name == "" then
      return
    end

    if close then
      -- Close any styling this tag opened first, so the closing markers land
      -- before a block separator ends the line.
      -- (先闭合本标签打开的样式，让闭合标记落在段落分隔结束本行之前)
      close_styles(tag_name)
      if skip_heading then
        skip_heading = false
        in_heading = false
        return
      end

      -- Closing block tags otherwise do nothing: the *next* block's separator
      -- ends the line, which keeps adjacent paragraphs tight. Headings and
      -- blockquotes add their own breathing room.
      -- (除此之外闭合块标签不做处理：下一块开始时的分隔会结束本行，相邻段落因此紧凑；
      --  标题与引用会自己补留白)
      if HEADINGS[tag_name] then
        in_heading = false
        buffer:gap()
      elseif tag_name == "blockquote" then
        buffer:separate()
      end
      return
    end

    -- ---------------------------------------------------------------- structure
    if HEADINGS[tag_name] then
      headings_seen = headings_seen + 1
      -- The winbar already shows the book and chapter, so repeating the title
      -- as the first heading only costs two rows. Later headings carry real
      -- structure and stay.
      -- (winbar 已经显示书名与章节，正文里再重复一次标题只是白花两行；后面的标题承担
      --  真正的结构信息，保留)
      skip_heading = skip_title and headings_seen == 1
      if not skip_heading then
        buffer:gap()
        in_heading = true
        local level = math.min(6, math.max(1, HEADINGS[tag_name] + heading_offset))
        buffer:block_marker(string.rep("#", level) .. " ")
      end
    elseif tag_name == "li" then
      buffer:separate()
      buffer:block_marker("- ")
    elseif tag_name == "blockquote" then
      buffer:separate()
      buffer:block_marker("> ")
    elseif tag_name == "br" then
      -- A hard break inside a paragraph reads better as a real line break in
      -- the editor, which is what plain markdown soft wrapping gives us.
      -- (段落内的换行在编辑器里就是真换行，也就是 markdown 的软换行)
      buffer:newline()
    elseif tag_name == "hr" then
      buffer:gap()
      buffer:block_marker("---")
      buffer:gap()
    elseif tag_name == "img" then
      local src = attr(tag, "src") or ""
      local alt = M.decode_entities(attr(tag, "alt") or "")
      local resolved = src
      if resolve_image then
        resolved = resolve_image(src) or src
      end
      images[#images + 1] = { src = src, resolved = resolved, alt = alt }
      buffer:gap()
      buffer:block_marker(string.format("![%s](%s)", alt, resolved))
      -- No gap after: a caption belongs to its figure, and markdown still parses
      -- the image as its own paragraph.
      -- (后面不留空：图注属于插图，且 markdown 仍会把图片解析成独立段落)
      buffer:newline()
      return
    elseif tag_name == "td" or tag_name == "th" then
      if not buffer:is_empty() then
        buffer:block_marker(" | ")
      end
    elseif BLOCK_TAGS[tag_name] then
      buffer:separate()
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
      local resolved_style = css.resolve(attr(tag, "class"), attr(tag, "style"), class_styles, tag_name)
      if not css.is_empty(resolved_style) then
        open_from_style(resolved_style, tag_name)
      end
    end
  end

  while pos <= #source do
    local lt = source:find("<", pos, true)
    if not lt then
      break
    end

    -- text before the tag
    if lt > pos then
      local raw = source:sub(pos, lt - 1)
      rune = rune + count_runes(raw)
      -- A dropped chapter title must not emit its text either, but its runes
      -- still count so every later offset stays aligned with the source.
      -- (被丢弃的章节标题连文字一起丢掉，但 rune 仍要计数，保证后续偏移与源码对齐)
      if not skip_heading then
        local decoded = M.normalize_text(raw, M.decode_entities(raw))
        if decoded then
          if buffer:is_empty() then
            decoded = decoded:gsub("^ ", "")
          end
          if decoded ~= "" then
            buffer:append(decoded, rune - count_runes(raw), rune)
          end
        end
      end
    end

    if source:sub(lt, lt + 3) == "<!--" then
      local close = source:find("-->", lt + 4, true)
      local stop = close and (close + 2) or #source
      rune = rune + count_runes(source:sub(lt, stop))
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
      if close then
        local gt = source:find(">", close, true) or #source
        rune = rune + count_runes(source:sub(lt, gt))
        pos = gt + 1
      else
        local gt = source:find(">", lt, true) or #source
        rune = rune + count_runes(source:sub(lt, gt))
        pos = gt + 1
      end
    else
      local gt = source:find(">", lt, true)
      if not gt then
        break
      end
      local tag = source:sub(lt + 1, gt - 1)
      rune = rune + count_runes(source:sub(lt, gt))
      handle_tag(tag)
      pos = gt + 1
    end
  end

  -- trailing text
  if pos <= #source then
    local raw = source:sub(pos)
    rune = rune + count_runes(raw)
    local decoded = M.normalize_text(raw, M.decode_entities(raw))
    if decoded and not skip_heading then
      buffer:append(decoded, rune - count_runes(raw), rune)
    end
  end

  local text = buffer:get()
  local map = buffer.map

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
    -- Display-only styling: markdown cannot express underline, strike, marks
    -- or superscript, so those come back as positions the reader draws with
    -- extmarks. Bold/italic are also listed, so the reader can hide the `**`
    -- markers and apply a real bold/italic attribute instead of showing
    -- punctuation.
    -- (仅供显示的样式：markdown 表达不了下划线/删除线/高亮/上标，因此以位置形式返回，
    --  由阅读器用 extmark 绘制。粗体与斜体同样列出，这样阅读器可以隐藏 `**` 标记并
    --  改用真正的粗体/斜体属性，而不是把标点符号摆在那儿)
    styles = styles,
  }
end

---Find the segment containing a source rune offset.
---(找到包含某个源 rune 偏移的段落)
---Offsets that fall in the gaps between segments are inside markup (a tag or a
---comment); they snap forward to the next text run, and offsets past the last
---run snap back to it.
---(落在段落间隙中的偏移位于标签/注释内部，会向前收敛到下一段文本；超出最后一段的
--- 偏移则收敛回最后一段)
---@param map table[]
---@param rune integer
---@return table|nil segment
---@return integer index
local function find_segment(map, rune)
  local low, high = 1, #map
  local candidate = nil
  while low <= high do
    local mid = math.floor((low + high) / 2)
    local segment = map[mid]
    if rune < segment.src_from then
      high = mid - 1
    elseif rune >= segment.src_to then
      -- Keeps the *last* segment that starts at or before `rune`.
      -- (记录最后一个起点不大于 rune 的段落)
      candidate = mid
      low = mid + 1
    else
      return segment, mid
    end
  end
  if candidate then
    return map[candidate], candidate
  end
  -- Before the first text run: inside the leading markup.
  -- (位于首个文本段之前：处于开头标签内部)
  return map[1], 1
end

M.find_segment = find_segment

---Resolve a source rune range into markdown positions.
---(把源 rune 范围解析为 markdown 位置)
---Accepts either a conversion result or a bare map array. Ranges that start
---past the end of the content resolve to nothing, so callers can skip stale
---annotations instead of marking an unrelated line.
---(可传入转换结果或裸 map 数组。起点超出内容长度的 range 解析为空，让调用方跳过
--- 过期划线，而不是标错行)
---@param map_or_result table
---@param from_rune integer 0-based, inclusive
---@param to_rune integer 0-based, exclusive
---@return table|nil start { line, col } (0-based line, byte col)
---@return table|nil finish
function M.resolve(map_or_result, from_rune, to_rune)
  local map = map_or_result.map or map_or_result
  local source_runes = map_or_result.source_runes
  if type(map) ~= "table" or #map == 0 then
    return nil, nil
  end
  if source_runes and from_rune >= source_runes then
    return nil, nil
  end

  local start = find_segment(map, from_rune)
  -- The end offset is exclusive, so probe one rune before it.
  local finish = find_segment(map, math.max(from_rune, to_rune - 1))

  if not start and not finish then
    return nil, nil
  end
  start = start or finish
  finish = finish or start

  return {
    line = start.line,
    col = start.col_from,
  }, {
    line = finish.line,
    col = finish.col_to,
  }
end

return M
