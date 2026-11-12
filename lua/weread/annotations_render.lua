--[[
Drawing highlights into a chapter buffer, and looking them up again by line.
(把划线画进章节 buffer，以及按行把它们查回来)

The underline goes on the highlighted text itself, the way the app shows it,
instead of only on a marker at the end of the line: a highlight whose text is
not marked is impossible to find again while reading.
(下划线画在被划线的原文上，和 App 一样，而不是只挂在行尾做标记：原文没有被标记的
 划线，在读的时候根本找不到)

Depends on `annotations_model` and `annotations_store` only.
(只依赖 `annotations_model` 与 `annotations_store`)
]]

local model = require("weread.annotations_model")
local store = require("weread.annotations_store")
local xhtml = require("weread.xhtml")

local M = {}

local NAMESPACE = vim.api.nvim_create_namespace("weread.annotations")

---Are annotation labels (the marker at the end of a line) switched on?
---(是否开启划线行尾标记)
---@return boolean
function M.labels_enabled()
  return (require("weread.config").get().annotations or {}).label == true
end

---Byte column `runes` characters after `col`.
---(col 之后第 runes 个字符所在的字节列)
---@param text string rendered line(渲染出的那一行)
---@param col integer 0-based byte column(0 基字节列)
---@param runes integer
---@return integer
local function advance(text, col, runes)
  local index = col + 1
  for _ = 1, runes do
    if index > #text then
      return #text
    end
    local byte = text:byte(index) or 0
    local length = 1
    if byte >= 0xF0 then
      length = 4
    elseif byte >= 0xE0 then
      length = 3
    elseif byte >= 0xC0 then
      length = 2
    end
    index = index + length
  end
  return math.min(index - 1, #text)
end

local is_table_line = require("weread.xhtml_table").is_line

---The column ranges of a table line that hold runes `from`..`to`.
---(表格某一行里装着 rune from..to 的那几段列区间)
---@param map table[]
---@param text string
---@param line integer 0-based
---@param from integer
---@param to integer exclusive(右开)
---@return integer[][]
local function table_pieces(map, text, line, from, to)
  local pieces = {}
  for _, segment in ipairs(map) do
    if segment.line == line and segment.src_to > from and segment.src_from < to then
      local a, b = segment.col_from, segment.col_to
      if not segment.atom then
        if segment.src_from < from then
          a = advance(text, segment.col_from, from - segment.src_from)
        end
        if segment.src_to > to then
          b = advance(text, segment.col_from, to - segment.src_from)
        end
      end
      pieces[#pieces + 1] = { a, b }
    end
  end
  return pieces
end

---Draw the annotations of a buffer.
---(绘制 buffer 的划线)
---@param buf integer
---@param map table { map = table[], source_runes = integer }
---@param annotations table[]
---@return integer drawn
function M.render(buf, map, annotations)
  if not vim.api.nvim_buf_is_valid(buf) then
    return 0
  end
  vim.api.nvim_buf_clear_namespace(buf, NAMESPACE, 0, -1)

  local resolved = {}
  local texts = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  local hottest = 0
  for _, annotation in ipairs(annotations or {}) do
    hottest = math.max(hottest, tonumber(annotation.count) or 0)
  end
  local lines = #texts
  local drawn = 0

  ---@param line integer 0-based
  ---@return string
  local function text_of(line)
    return texts[line + 1] or ""
  end

  for _, annotation in ipairs(annotations or {}) do
    local from, to = model.parse_range(annotation.range)
    local start = from and xhtml.locate(map, from) or nil
    if start and start.line < lines then
      -- The end is exclusive: probe the last rune inside the range, so a range
      -- ending right at a segment boundary stays on its own line, and measure
      -- the end within that segment (it may differ from the start's segment on
      -- the same line, e.g. across bold or a link).
      -- (终点是右开的：探测范围内最后一个 rune，这样正好结束在段边界上的划线不会溢到下一行；
      --  终点在它自己的段里量（同一行里它可能和起点不在一段，比如跨过粗体或链接）)
      local finish = (to and to > from) and xhtml.find_segment(map.map or map, to - 1) or nil
      local finish_line = math.min(math.max(finish and finish.line or start.line, start.line), lines - 1)

      -- Both ends are resolved inside a paragraph-sized segment, so the exact
      -- character sits `runes` further along the rendered line.
      -- (两端都落在段落级的区间里，因此精确字符位置就是渲染行里再往后数 `runes` 个字符)
      local from_col = advance(text_of(start.line), start.col, start.runes)
      local to_col = from_col
      if finish then
        if finish.atom then
          to_col = finish.col_to
        else
          local runes = math.max(0, math.min(to, finish.src_to) - finish.src_from)
          to_col = math.min(advance(text_of(finish_line), finish.col_from, runes), finish.col_to)
        end
      end

      local _, highlight = model.label(annotation)
      if highlight == "WereadPopularHighlight" then
        highlight = model.heat_group(model.heat(annotation.count, hottest))
      end
      for line = start.line, finish_line do
        local text = text_of(line)
        local head = line == start.line and from_col or 0
        local tail = line == finish_line and to_col or #text
        local pieces = { { head, tail } }
        if is_table_line(map, line) then
          -- A table line holds several cells side by side: the rule goes under
          -- the passage's own characters only, segment by segment, not under the
          -- cells of the other columns that share the line.
          -- (表格的一行里并排着好几格：下划线只画在这段话自己的字下面，逐段来画，不画到同一行
          --  其他列的格子下面)
          pieces = table_pieces(map.map or map, text, line, from, to or (from + 1))
        end
        for _, piece in ipairs(pieces) do
          if piece[2] > piece[1] then
            local ok = pcall(vim.api.nvim_buf_set_extmark, buf, NAMESPACE, line, piece[1], {
              end_col = piece[2],
              hl_group = highlight,
              hl_mode = "combine",
              priority = 150,
            })
            if ok then
              drawn = drawn + 1
            end
          end
        end
      end

      -- The label is opt-in: the underline already says what is marked, and a
      -- marker at the end of a wrapped line lands in the middle of the page.
      -- (行尾标记是可选项：下划线本身已经说明被标记的位置，而折行后的行尾标记会落在
      --  页面中间)
      if M.labels_enabled() then
        local label = model.label(annotation)
        pcall(vim.api.nvim_buf_set_extmark, buf, NAMESPACE, start.line, 0, {
          virt_text = { { " " .. label, highlight } },
          virt_text_pos = "eol",
          hl_mode = "combine",
        })
      end

      resolved[#resolved + 1] = {
        annotation = annotation,
        line = start.line,
        finish_line = finish_line,
        from_col = from_col,
        to_col = to_col,
      }
    end
  end

  -- Buffer-local so `K` and the summary can work without refetching.
  -- (放进 buffer 局部变量，K 与汇总无需重新拉取)
  vim.b[buf].weread_annotations = resolved
  -- and the list they were resolved from, so thoughts that arrive later can be
  -- attached and redrawn without rebuilding it
  -- (以及它们解析来源的那份列表：后到的想法可以直接挂上去重画，不必重建)
  vim.b[buf].weread_merged = annotations
  return drawn
end

---Redraw a chapter buffer from the cached map, the account's list kept on the
---buffer and the local highlights.
---(用缓存的偏移表、挂在 buffer 上的账号列表与本地划线重画章节 buffer)
---@param buf integer
---@param book_id string
---@param chapter_key string
function M.redraw(buf, book_id, chapter_key)
  if not vim.api.nvim_buf_is_valid(buf) then
    return
  end
  local map = store.chapter_map(book_id, chapter_key)
  if map then
    M.render(buf, map, store.merged(book_id, chapter_key, vim.b[buf].weread_server_annotations))
  end
end

---Annotations on a given line (0-based), closest first.
---(某一行的划线，按距离排序)
---@param buf integer
---@param line integer 0-based
---@return table[]
function M.annotations_on_line(buf, line)
  local resolved = vim.b[buf].weread_annotations or {}
  local exact, nearby = {}, {}
  for _, entry in ipairs(resolved) do
    local finish = entry.finish_line or entry.line
    -- a highlight that spans a wrapped paragraph covers several lines, and the
    -- cursor can be on any of them
    -- (跨折行的划线会覆盖好几行，光标落在其中任意一行都算命中)
    if line >= entry.line and line <= finish then
      exact[#exact + 1] = entry
    elseif math.abs(entry.line - line) <= 1 then
      nearby[#nearby + 1] = entry
    end
  end
  if #exact > 0 then
    return exact
  end
  return nearby
end

---The highlight drawn over an exact position, if any. Unlike
---`annotations_on_line`, a highlight elsewhere on the line does not count: this
---is what decides whether `K` is pressed *on* a highlight.
---(精确覆盖某个位置的划线。与 annotations_on_line 不同，同一行别处的划线不算：K 是不是按在
--- 划线**上**，由它判断)
---@param buf integer
---@param line integer 0-based
---@param col integer 0-based byte column
---@return table|nil entry
function M.entry_covering(buf, line, col)
  for _, entry in ipairs(vim.b[buf].weread_annotations or {}) do
    local finish = entry.finish_line or entry.line
    if line >= entry.line and line <= finish then
      local from = line == entry.line and (entry.from_col or 0) or 0
      local to = line == finish and entry.to_col or math.huge
      if col >= from and (to == nil or col < to) then
        return entry
      end
    end
  end
  return nil
end

---The highlight under a line, if any, together with its resolved range.
---(某一行上的划线，连同它解析出的信息)
---@param buf integer
---@param line integer 0-based
---@return table|nil entry
function M.entry_at(buf, line)
  return M.annotations_on_line(buf, line)[1]
end

return M
