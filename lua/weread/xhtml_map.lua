--[[
Offset-map queries for converted chapters: which markdown position a source
rune landed on, and the other way round.
(转换结果的 offset map 查询：源 rune 落在 markdown 的哪个位置，以及反过来)

Split out of xhtml.lua, unchanged. These are pure functions over the `map`,
`footnotes` and `lines` that `xhtml.convert` returns, so annotations, the pager
and the cache can use them without pulling in the converter itself.
(从 xhtml.lua 原样拆出。它们是对 `xhtml.convert` 返回的 `map`、`footnotes`、`lines`
 的纯函数，划线、分页、缓存可以用它们而不必加载转换器本身)
]]

local count_runes = require("weread.xhtml_buffer").count_runes

local M = {}

---The footnote under a cursor, or the nearest one on the same line.
---(光标下的脚注；没有则取同一行上最近的那个)
---@param footnotes table[]|nil entries { line, col_from, col_to, text }
---@param line integer 0-based(0 基)
---@param col integer 0-based byte column(0 基字节列)
---@return table|nil
function M.footnote_at(footnotes, line, col)
  if type(footnotes) ~= "table" then
    return nil
  end
  local best, best_distance = nil, math.huge
  for _, footnote in ipairs(footnotes) do
    if tonumber(footnote.line) == line then
      local from, to = tonumber(footnote.col_from) or 0, tonumber(footnote.col_to) or 0
      local distance = 0
      if col < from then
        distance = from - col
      elseif col >= to then
        distance = col - to + 1
      end
      if distance < best_distance then
        best, best_distance = footnote, distance
      end
    end
  end
  return best
end

---Source rune a rendered line and column came from — the inverse of `locate`.
---(渲染出的行与列对应的源 rune——locate 的逆运算)
---
---The rendered line is needed because a segment's characters map to runes one
---for one, and counting them requires the text. Markers and injected spaces sit
---outside every segment, so they are skipped rather than counted.
---(需要传渲染出的那一行：段落里的字符与 rune 一一对应，而数它们得看文本。标记与注入的
--- 空格不在任何段落里，因此被跳过而不是被计数)
---@param map_or_result table
---@param line integer 0-based(0 基)
---@param col integer 0-based byte column(0 基字节列)
---@param text string|nil the rendered line(渲染出的那一行)
---@return integer|nil rune
function M.rune_at(map_or_result, line, col, text)
  local map = map_or_result.map or map_or_result
  if type(map) ~= "table" or #map == 0 then
    return nil
  end
  -- the last segment on this line that starts at or before the column
  -- (这一行上最后一个起点不晚于该列的段落)
  local segment = nil
  for _, candidate in ipairs(map) do
    if candidate.line == line and candidate.col_from <= col then
      if not segment or candidate.col_from > segment.col_from then
        segment = candidate
      end
    end
  end
  if not segment then
    return nil
  end
  local clamped = math.max(segment.col_from, math.min(col, segment.col_to))
  if segment.atom then
    -- one character for several runes: either before it or past all of them
    -- (一个字符代表多个 rune：要么在它之前，要么越过全部)
    return clamped > segment.col_from and segment.src_to or segment.src_from
  end
  local prefix = (text or ""):sub(segment.col_from + 1, clamped)
  return segment.src_from + count_runes(prefix)
end

---Turn per-line display attributes into something JSON can carry.
---(把逐行显示属性转成 JSON 搬得动的形式)
---
---The keys are line numbers, and only the few lines that need padding or colour
---are present, so they are sparse. `vim.json.encode` reads a table whose keys are
---all ≥ 1 as an *array*, and then refuses it outright ("excessively sparse
---array") — which silently cost whole chapters their offset map. String keys make
---it a JSON object, which is what it is.
---(键是行号，而只有少数需要补白或上色的行存在，因此是稀疏的。`vim.json.encode` 会把键全 ≥1
--- 的表当成**数组**，随即直接拒绝（"excessively sparse array"）——整整几章因此静默丢掉了偏移表。
--- 改成字符串键就是 JSON 对象，而它本来就是对象)
---@param lines table<integer, table>|nil
---@return table<string, table>
function M.json_lines(lines)
  local out = {}
  for line, info in pairs(lines or {}) do
    out[tostring(line)] = info
  end
  return out
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

---Locate a source rune precisely: the line, the byte column a segment starts
---at, and how many characters into that segment the rune is.
---(精确定位一个源 rune：所在行、所属段落的起始字节列，以及它是该段落里的第几个字符)
---
---`resolve` is enough to find the *line* a highlight is on, but drawing the
---underline itself needs character precision, and a paragraph is one segment:
---the caller advances `runes` characters from `col` in the rendered line.
---(只用 resolve 足以找到划线的**行**，但要画下划线本身就需要字符级精度，而一个段落
--- 往往就是一个段落而已：调用方从渲染行的 `col` 往后数 `runes` 个字符即可)
---@param map_or_result table
---@param rune integer 0-based(0 基)
---@return table|nil { line, col, runes }
function M.locate(map_or_result, rune)
  local map = map_or_result.map or map_or_result
  if type(map) ~= "table" or #map == 0 then
    return nil
  end
  local segment = find_segment(map, rune)
  if not segment then
    return nil
  end
  local clamped = math.max(segment.src_from, math.min(rune, segment.src_to))
  local runes = clamped - segment.src_from
  if segment.atom then
    -- `&amp;` is one character on the page: a rune past its start is past it
    -- (`&amp;` 在页面上只有一个字符：越过它起点的 rune 就是越过了它)
    runes = runes > 0 and 1 or 0
  end
  return {
    line = segment.line,
    col = segment.col_from,
    runes = runes,
  }
end


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
