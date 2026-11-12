--[[
Making and removing highlights from the editor: buffer positions -> a source
rune range, the highlight commands, and their undo.
(在编辑器里画线与取消划线：buffer 位置 → 源 rune 区间、划线命令及其撤销)

A highlight is stored locally first (so it shows at once and survives offline),
then uploaded by `annotations_sync`.
(划线先存本地——立刻可见，离线也不丢——再由 `annotations_sync` 上传)
]]

local model = require("weread.annotations_model")
local render = require("weread.annotations_render")
local store = require("weread.annotations_store")
local sync = require("weread.annotations_sync")
local xhtml = require("weread.xhtml")

local M = {}

---Positions in a chapter buffer -> a source rune range.
---(章节 buffer 里的位置 → 源 rune 区间)
---@param buf integer
---@param from integer[] { line, col } 1-based line, 0-based byte col
---@param to integer[] same shape, exclusive(同形，右开)
---@return string|nil range
---@return string|nil error
function M.range_of_positions(buf, from, to)
  local reader = require("weread.reader")
  local info = reader.buffer_info(buf)
  if not info then
    return nil, "当前 buffer 不是微信读书章节"
  end
  if from[1] > to[1] or (from[1] == to[1] and from[2] > to[2]) then
    from, to = to, from
  end
  local map = store.chapter_map(info.book_id, info.chapter_key)
  if not map then
    return nil, "本章还没有排版信息，重新打开本章再试"
  end
  local first_line = vim.api.nvim_buf_get_lines(buf, from[1] - 1, from[1], false)[1] or ""
  local last_line = vim.api.nvim_buf_get_lines(buf, to[1] - 1, to[1], false)[1] or ""
  local from_rune = xhtml.rune_at(map, from[1] - 1, from[2], first_line)
  local to_rune = xhtml.rune_at(map, to[1] - 1, to[2], last_line)
  if not from_rune or not to_rune or to_rune <= from_rune then
    return nil, "没有选中正文"
  end
  return string.format("%d-%d", from_rune, to_rune)
end

---The text a pair of positions covers, columns included.
---(两个位置之间覆盖的文字，列也算在内)
---@param buf integer
---@param from integer[]
---@param to integer[]
---@return string
function M.selection_text(buf, from, to)
  if from[1] > to[1] or (from[1] == to[1] and from[2] > to[2]) then
    from, to = to, from
  end
  local function line_at(number)
    return vim.api.nvim_buf_get_lines(buf, number - 1, number, false)[1] or ""
  end
  if from[1] == to[1] then
    return line_at(from[1]):sub(from[2] + 1, to[2])
  end
  local parts = { line_at(from[1]):sub(from[2] + 1) }
  for number = from[1] + 1, to[1] - 1 do
    parts[#parts + 1] = line_at(number)
  end
  parts[#parts + 1] = line_at(to[1]):sub(1, to[2])
  return table.concat(parts, " ")
end

---The words a selection stands for. In a table a selection over several lines
---also crosses the other columns' cells on those lines, so the passage is read
---from the book itself, by the range it covers.
---(选区代表的文字。在表格里，跨几行的选区也会扫过这几行上其他列的格子，所以按它覆盖的区间从书里
--- 读出这段话)
---@param buf integer
---@param from integer[]
---@param to integer[]
---@return string
function M.passage_text(buf, from, to)
  local first, last = math.min(from[1], to[1]), math.max(from[1], to[1])
  local table_module = require("weread.xhtml_table")
  local reader = require("weread.reader")
  local info = reader.buffer_info(buf)
  local meta = info and store.chapter_map(info.book_id, info.chapter_key)
  local in_table = false
  for line = first, last do
    if table_module.is_line(meta, line - 1) then
      in_table = true
      break
    end
  end
  if in_table and first ~= last then
    local range = info and M.range_of_positions(buf, from, to)
    local source = range and store.source_text(info.book_id, info.chapter_key, range)
    if source then
      return source
    end
  end
  local text = M.selection_text(buf, from, to)
  if in_table then
    -- one line of a table: the box rules between its cells are not the passage
    -- (表格里的一行：格与格之间的边框线不是这段话)
    text = vim.trim(table_module.strip(text))
  end
  return text
end

---Highlight a range of the buffer (the selection, or one line).
---(给 buffer 里的一段文字画线：选区，或者一整行)
---@param buf integer
---@param from integer[]
---@param to integer[]
---@return boolean ok
---@return string message
function M.highlight(buf, from, to)
  local reader = require("weread.reader")
  local info = reader.buffer_info(buf)
  if not info then
    return false, "只在微信读书章节里画线"
  end
  local range, err = M.range_of_positions(buf, from, to)
  if not range then
    return false, err or "无法定位划线范围"
  end
  -- Already highlighted in the account? Then this is not a new highlight, and
  -- pretending it were a local one would leave a mark the reader cannot remove
  -- here. Say so instead.
  -- (账号里已经划过这段？那它就不是一条新划线；假装它是本地划线只会留下一条在这里删不掉
  --  的记号。如实说明)
  for _, existing in ipairs(vim.b[buf].weread_server_annotations or {}) do
    if existing.range == range then
      return false, "这段文字已经划过了（微信读书里的划线）"
    end
  end
  local text = M.passage_text(buf, from, to)
  store.add_local(info.book_id, info.chapter_key, range, model.plain_text(text))

  -- draw it right away: the chapter's annotations are already on screen
  -- (立刻画出来：本章的划线本来就在屏幕上)
  render.redraw(buf, info.book_id, info.chapter_key)
  -- the ink spreads from the middle of the passage, over the drawn rule
  -- (墨从这段的中间洇开，叠在画好的划线上)
  pcall(function()
    require("weread.fx_effects").ink(buf, from, to)
  end)
  -- and into the account, so the phone shows it too
  -- (同时传进账号，手机上也能看到)
  sync.sync_local(buf)
  return true, string.format("已划线：%s", text)
end

---Highlight the whole line the cursor is on.
---(给光标所在的整行画线)
---@param buf integer
---@param line integer 1-based
---@return boolean ok
---@return string message
function M.highlight_line(buf, line)
  buf = buf or vim.api.nvim_get_current_buf()
  line = math.max(1, math.min(tonumber(line) or vim.fn.line("."), vim.api.nvim_buf_line_count(buf)))
  local text = vim.api.nvim_buf_get_lines(buf, line - 1, line, false)[1] or ""
  local from = model.first_text_byte(text)
  if not from then
    return false, "这一行没有正文"
  end
  -- trailing whitespace is not part of the sentence either
  -- (行尾空白也不属于这句话)
  local trimmed = text:gsub("[ \t]+$", "")
  return M.highlight(buf, { line, from - 1 }, { line, #trimmed })
end

---Remove every local highlight overlapping a range.
---(删掉与某区间重叠的所有本地划线)
---@param buf integer
---@param from integer[] { line, col } 1-based line, 0-based col
---@param to integer[]
---@return integer removed
function M.unhighlight_range(buf, from, to)
  local info = require("weread.reader").buffer_info(buf)
  if not info then
    return 0
  end
  local wanted, err = M.range_of_positions(buf, from, to)
  if not wanted then
    vim.notify("weread: " .. tostring(err), vim.log.levels.WARN)
    return 0
  end
  local wanted_from, wanted_to = model.parse_range(wanted)
  local removed = 0
  for _, entry in ipairs(store.local_for(info.book_id, info.chapter_key)) do
    local entry_from, entry_to = model.parse_range(entry.range)
    if entry_from and entry_to and entry_from < wanted_to and entry_to > wanted_from then
      removed = removed + 1
      sync.remove_highlight(buf, { range = entry.range, bookmark_id = entry.bookmark_id }, function(ok, message)
        if not ok then
          vim.notify("weread: " .. message, vim.log.levels.WARN)
        end
      end)
    end
  end
  return removed
end

---Forget every local highlight of a chapter.
---(清空某一章的所有本地划线)
---@param buf integer
---@return integer removed
function M.clear_local(buf)
  local info = require("weread.reader").buffer_info(buf)
  if not info then
    return 0
  end
  local local_store = store.local_store(info.book_id)
  local entries = local_store[info.chapter_key] or {}
  -- the ones that reached the account go from there too: otherwise they would
  -- come straight back as highlights that can no longer be removed here
  -- (已经进了账号的也从账号里删：否则它们马上会作为「这里删不掉的划线」回来)
  for _, entry in ipairs(entries) do
    if entry.bookmark_id then
      sync.delete_highlight(entry.bookmark_id, function(ok, err)
        if not ok then
          vim.notify("weread: " .. tostring(err), vim.log.levels.WARN)
        end
      end)
      store.forget_server(buf, info.book_id, info.chapter_key, entry.range)
    end
  end
  local_store[info.chapter_key] = {}
  store.save_local(info.book_id, local_store)
  render.redraw(buf, info.book_id, info.chapter_key)
  return #entries
end

---Remove the local highlight under the cursor, if there is one.
---(取消光标处的本地划线（如果有）)
---@param buf integer
---@param line integer 0-based
---@param callback fun(ok: boolean, message: string)|nil told how a removal in the account ended(账号里的删除结束后通知)
---@return boolean ok
---@return string message
function M.unhighlight(buf, line, callback)
  local info = require("weread.reader").buffer_info(buf)
  if not info then
    return false, "只在微信读书章节里取消划线"
  end
  local found = render.annotations_on_line(buf, line)
  -- Mine only: a highlight made here (synced or not) or one of the account's,
  -- which carries the id the delete endpoint needs. Popular ones are other
  -- people's.
  -- (只删我的：在这里画的（不论是否已同步），或账号里那些带着删除接口所需 id 的。热门划线
  --  是别人的)
  for _, entry in ipairs(found) do
    local annotation = entry.annotation
    if annotation.unsynced or (annotation.mine and annotation.bookmark_id) then
      if annotation.bookmark_id then
        sync.remove_highlight(buf, annotation, callback)
        return true, "正在从微信读书里取消这条划线…"
      end
      sync.remove_highlight(buf, annotation, function() end)
      return true, "已取消这条本地划线"
    end
  end
  if #found > 0 then
    return false, "这条是别人的热门划线，不能取消"
  end
  return false, "光标处没有划线"
end

return M
