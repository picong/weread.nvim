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

local M = {}

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
local Buffer = {}
Buffer.__index = Buffer

function Buffer.new()
  return setmetatable({ lines = {}, current = {}, col = 0, map = {} }, Buffer)
end

function Buffer:append(text, src_from, src_to)
  if text == "" then
    return
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

---Append syntax that has no counterpart in the source (`# `, `- `, `*`, ...).
---Markers are deliberately kept out of the offset map: a zero-width segment
---could never contain a rune and would only bloat the map.
---(追加在源码中没有对应物的语法标记（`# `、`- `、`*` 等）。标记刻意不写入 offset
--- map：零宽段落永远不可能包含某个 rune，只会让 map 膨胀)
---@param text string
function Buffer:marker(text)
  if text == "" then
    return
  end
  self.current[#self.current + 1] = text
  self.col = self.col + #text
end

function Buffer:is_empty()
  return self.col == 0
end

---Trim trailing spaces, which markdown only sees as noise.
---(去掉行尾空格，markdown 里只会变成噪音)
function Buffer:flush()
  local line = table.concat(self.current)
  line = line:gsub("[ \t]+$", "")
  self.lines[#self.lines + 1] = line
  self.current = {}
  self.col = 0
end

function Buffer:newline()
  if self.col > 0 then
    self:flush()
  end
end

---End the current paragraph: flush and guarantee one blank line.
---(结束一个段落：落行并保证一个空行)
function Buffer:paragraph()
  self:newline()
  local lines = self.lines
  if #lines > 0 and lines[#lines] ~= "" then
    lines[#lines + 1] = ""
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

  local buffer = Buffer.new()
  local images = {}
  local rune = 0
  local pos = 1

  ---@param tag string
  local function handle_tag(tag)
    local close = tag:match("^%s*/") ~= nil
    local tag_name = (tag:match("^%s*/?%s*([%a][%w%-]*)")) or ""
    tag_name = tag_name:lower()
    if tag_name == "" then
      return
    end

    if close then
      if HEADINGS[tag_name] or BLOCK_TAGS[tag_name] then
        if tag_name ~= "br" then
          buffer:paragraph()
        end
      elseif tag_name == "em" or tag_name == "i" then
        buffer:marker("*")
      elseif tag_name == "strong" or tag_name == "b" then
        buffer:marker("**")
      elseif tag_name == "code" or tag_name == "tt" then
        buffer:marker("`")
      end
      return
    end

    if HEADINGS[tag_name] then
      buffer:paragraph()
      local level = math.min(6, math.max(1, HEADINGS[tag_name] + heading_offset))
      buffer:marker(string.rep("#", level) .. " ")
    elseif tag_name == "li" then
      buffer:newline()
      buffer:marker("- ")
    elseif tag_name == "blockquote" then
      buffer:newline()
      buffer:marker("> ")
    elseif tag_name == "br" then
      -- A hard break inside a paragraph reads better as a real line break in
      -- the editor, which is what plain markdown soft wrapping gives us.
      -- (段落内的换行在编辑器里就是真换行，也就是 markdown 的软换行)
      buffer:newline()
    elseif tag_name == "hr" then
      buffer:paragraph()
      buffer:marker("---")
      buffer:paragraph()
    elseif tag_name == "em" or tag_name == "i" then
      buffer:marker("*")
    elseif tag_name == "strong" or tag_name == "b" then
      buffer:marker("**")
    elseif tag_name == "code" or tag_name == "tt" then
      buffer:marker("`")
    elseif tag_name == "img" then
      local src = attr(tag, "src") or ""
      local alt = M.decode_entities(attr(tag, "alt") or "")
      local resolved = src
      if resolve_image then
        resolved = resolve_image(src) or src
      end
      images[#images + 1] = { src = src, resolved = resolved, alt = alt }
      buffer:paragraph()
      buffer:marker(string.format("![%s](%s)", alt, resolved))
      buffer:paragraph()
    elseif tag_name == "td" or tag_name == "th" then
      if not buffer:is_empty() then
        buffer:marker(" | ")
      end
    elseif BLOCK_TAGS[tag_name] then
      buffer:paragraph()
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
      local text = M.decode_entities(raw)
      buffer:append(text, rune, rune + count_runes(raw))
      rune = rune + count_runes(raw)
    end

    if source:sub(lt, lt + 3) == "<!--" then
      local close = source:find("-->", lt + 4, true)
      local stop = close and (close + 2) or #source
      rune = rune + count_runes(source:sub(lt, stop))
      pos = stop + 1
    elseif source:sub(lt + 1, lt + 5):lower() == "style" or source:sub(lt + 1, lt + 6):lower() == "script" then
      -- skip raw style/script bodies, but keep counting runes so offsets stay
      -- aligned with the source
      -- (跳过 style/script 正文，但仍计数 rune 以保持与源码的偏移对齐)
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
    buffer:append(M.decode_entities(raw), rune, rune + count_runes(raw))
    rune = rune + count_runes(raw)
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
