--[[
Bookmarks (书签) and in-book search.
(书签与书内搜索)

Bookmarks are local. The service does keep the app's bookmarks, but no endpoint
we can reach returns them (/book/bookmarklist filters them out and only yields
highlights), so a bookmark set here lives in `books/<bookId>/bookmarks.json`.
Each one is stored by source rune offset, the coordinate highlights and
progress use, so it survives a re-render at another page width.
(书签存在本地。服务端确实保存着 App 的书签，但能访问到的接口都不返回它们——
 /book/bookmarklist 会把书签滤掉，只给划线——所以这里加的书签存在
 `books/<bookId>/bookmarks.json`。每条按源 rune 偏移存（与划线、进度同一套坐标），
 换了版心宽度重排也不会丢)

Search runs over the chapters already on disk. The full-text search the
gateway offers searches the whole store, not one book, and fetching every
chapter just to grep it would download the book behind the reader's back.
(搜索只在已下载到本地的章节里进行。网关提供的全文搜索是全书城的，不能限定在一本书；
 而为了搜索去下载所有章节，等于背着读者把整本书拉下来)
]]

local M = {}

local cache = require("weread.cache")
local log = require("weread.log")
local text_util = require("weread.text")

-- ------------------------------------------------------------------ storage

---@param book_id string
---@return string
local function path_of(book_id)
  return cache.book_file(book_id, "bookmarks.json")
end

---Paths whose last read found a file that exists but could not be read. Saving
---over such a file would destroy the only copy, so `save` refuses.
---(上一次读取时发现「文件在但读不了」的路径。覆盖这样的文件会毁掉仅存的一份，所以 `save` 拒绝写)
---@type table<string, boolean>
local unreadable = {}

---Bookmarks of a book, oldest first.
---(一本书的书签，按添加先后)
---
---Entries that are not tables are dropped (everything downstream indexes them),
---after the original file is copied aside. A file that exists but cannot be read
---gives an empty list and blocks saving until it can be read.
---(不是 table 的条目会被丢掉——下游都会对它们取字段——丢之前先把原文件复制留底。文件在但
--- 读不了时返回空列表，并在能读之前禁止保存)
---@param book_id string|number
---@return table[] { chapter_uid, chapter_key, chapter_title, offset, line, excerpt, created_at }
function M.list(book_id)
  local path = path_of(tostring(book_id))
  unreadable[path] = nil
  local data = cache.read_json(path)
  if type(data) ~= "table" then
    local stat = vim.uv.fs_stat(path)
    if stat and stat.size > 0 then
      unreadable[path] = true
      log.warn("%s exists but could not be read; bookmarks are not saved until it can", path)
    end
    return {}
  end
  if type(data.bookmarks) ~= "table" then
    return {}
  end
  local kept, dropped = {}, 0
  for _, mark in ipairs(data.bookmarks) do
    if type(mark) == "table" then
      kept[#kept + 1] = mark
    else
      dropped = dropped + 1
    end
  end
  if dropped > 0 then
    local raw = cache.read(path)
    local backup = string.format("%s.corrupt-%s", path, os.date("%Y%m%d-%H%M%S"))
    if raw and cache.write(backup, raw) then
      log.warn("%s: dropped %d malformed bookmarks (original kept at %s)", path, dropped, backup)
    else
      log.warn("%s: dropped %d malformed bookmarks (could not keep a copy)", path, dropped)
    end
  end
  return kept
end

---@param book_id string
---@param list table[]
---@return boolean
local function save(book_id, list)
  local path = path_of(book_id)
  if unreadable[path] then
    log.warn("not saving %s: its current content could not be read", path)
    return false
  end
  cache.ensure_book_dirs(book_id)
  return cache.write_json(path, { version = 1, bookmarks = list }) ~= false
end

---Excerpt of a line for the bookmark list: the text without markdown markers.
---(书签列表里的一行摘录：去掉 markdown 标记的文字)
---@param text string
---@return string
function M.excerpt(text)
  text = text:gsub("^#+%s+", ""):gsub("%*%*", ""):gsub("__", ""):gsub("`", ""):gsub("!%[[^%]]*%]%([^%)]*%)", "〔插图〕")
  text = vim.trim(text)
  while text:sub(1, 3) == "　" do
    text = text:sub(4)
  end
  return text_util.fit(text, 40)
end

---The bookmark under a chapter line, if any: same chapter, and the line's
---source span holds the bookmark's offset (or, without an offset, the line).
---(某章节行上的书签：同一章，且该行的源区间包含书签偏移（没有偏移时比较行号）)
---@param list table[]
---@param chapter_uid string
---@param line integer
---@param offset integer|nil source offset of the line start(该行起点的源偏移)
---@param next_offset integer|nil source offset of the next line(下一行的源偏移)
---@return integer|nil index
local function find(list, chapter_uid, line, offset, next_offset)
  for index, mark in ipairs(list) do
    if tostring(mark.chapter_uid) == tostring(chapter_uid) then
      local at = tonumber(mark.offset)
      if at and offset then
        if at >= offset and (not next_offset or at < next_offset) then
          return index
        end
      elseif tonumber(mark.line) == line then
        return index
      end
    end
  end
  return nil
end

-- ------------------------------------------------------------------ chapter buffer

local NS = vim.api.nvim_create_namespace("weread.bookmarks")

---The mark at the end of a bookmarked line: a ribbon's swallowtail in one cell,
---where the emoji took two and drew in its own colours on every page palette.
---(书签行末尾的标记：一个字符格里的缎带燕尾；原来的 emoji 占两格，并且在每套纸页配色上都用
--- 它自己的颜色)
M.SIGN = "▚"

vim.api.nvim_set_hl(0, "WereadBookmark", { link = "DiagnosticWarn", default = true })

---Where the cursor line starts and where the next one starts, in source runes.
---(光标行与下一行的起点，按源 rune 计)
---@param buf integer
---@param line integer
---@return integer|nil
---@return integer|nil
local function line_span(buf, line)
  local reader = require("weread.reader")
  local here = reader.line_source(buf, line)
  local after = nil
  local last = vim.api.nvim_buf_line_count(buf)
  -- the next line that starts somewhere else in the source: blank lines and
  -- figures resolve to the following sentence, which is not "after" yet
  -- (源文里起点不同的下一行：空行与插图会解析到后面那句，还算不上「之后」)
  for next_line = line + 1, math.min(last, line + 40) do
    local at = reader.line_source(buf, next_line)
    if at and here and at > here then
      after = at
      break
    end
  end
  return here, after
end

---Draw the bookmark signs of a chapter buffer.
---(画出章节 buffer 里的书签标记)
---@param buf integer|nil
function M.render(buf)
  buf = buf or vim.api.nvim_get_current_buf()
  local reader = require("weread.reader")
  local info = reader.buffer_info(buf)
  if not info or not vim.api.nvim_buf_is_valid(buf) then
    return
  end
  vim.api.nvim_buf_clear_namespace(buf, NS, 0, -1)
  local chapter = ((reader.state.catalog or {}).chapters or {})[info.chapter_index]
  for _, mark in ipairs(M.list(info.book_id)) do
    if tostring(mark.chapter_uid) == tostring(info.chapter_uid) then
      local line = nil
      if mark.offset and chapter then
        line = reader.line_of_source(info.book_id, chapter, tonumber(mark.offset))
      end
      line = line or tonumber(mark.line)
      if line and line >= 1 and line <= vim.api.nvim_buf_line_count(buf) then
        pcall(vim.api.nvim_buf_set_extmark, buf, NS, line - 1, 0, {
          virt_text = { { " " .. M.SIGN, "WereadBookmark" } },
          virt_text_pos = "eol",
          hl_mode = "combine",
        })
      end
    end
  end
end

---Add a bookmark on the cursor line, or remove the one already there.
---(在光标行加书签；那里已有书签就删掉)
---@param buf integer|nil
---@return string|nil action "added" | "removed"
function M.toggle(buf)
  buf = buf or vim.api.nvim_get_current_buf()
  local reader = require("weread.reader")
  local info = reader.buffer_info(buf)
  if not info then
    vim.notify("weread: 只能在章节里加书签", vim.log.levels.WARN)
    return nil
  end
  local win = vim.fn.bufwinid(buf)
  local line = win ~= -1 and vim.api.nvim_win_get_cursor(win)[1] or 1
  local offset, next_offset = line_span(buf, line)
  local book_id = tostring(info.book_id)
  local list = M.list(book_id)
  local found = find(list, info.chapter_uid, line, offset, next_offset)
  local action
  if found then
    table.remove(list, found)
    action = "removed"
  else
    local text = vim.api.nvim_buf_get_lines(buf, line - 1, line, false)[1] or ""
    list[#list + 1] = {
      chapter_uid = tostring(info.chapter_uid),
      chapter_key = info.chapter_key,
      chapter_title = info.chapter_title,
      offset = offset,
      line = line,
      excerpt = M.excerpt(text),
      created_at = os.time(),
    }
    action = "added"
  end
  if not save(book_id, list) then
    vim.notify("weread: 书签保存失败", vim.log.levels.ERROR)
    return nil
  end
  M.render(buf)
  if win ~= -1 then
    pcall(function()
      require("weread.fx_effects").ribbon(win, action == "added")
    end)
  end
  -- routine: the mark at the end of the line already says it
  -- (例行消息：行尾的标记已经说明了)
  require("weread.ui").notify(action == "added" and "weread: 已加书签" or "weread: 已删除书签", vim.log.levels.INFO, { routine = true })
  return action
end

---Jump to a bookmark: open its chapter at its offset.
---(跳到某条书签：打开它所在的章节并定位到偏移)
---@param mark table
function M.jump(mark)
  local reader = require("weread.reader")
  local chapters = (reader.state.catalog or {}).chapters or {}
  for index, chapter in ipairs(chapters) do
    if tostring(chapter.chapterUid) == tostring(mark.chapter_uid) then
      reader.open_index(index, { source_offset = tonumber(mark.offset), line = tonumber(mark.line) })
      return true
    end
  end
  vim.notify("weread: 书签所在的章节不在目录里了", vim.log.levels.WARN)
  return false
end

---Picker over the open book's bookmarks.
---(当前这本书的书签选择器)
function M.pick()
  local reader = require("weread.reader")
  local book = reader.state.book
  if not book then
    vim.notify("weread: 还没有打开任何书", vim.log.levels.WARN)
    return
  end
  local list = M.list(book.book_id)
  if #list == 0 then
    vim.notify("weread: 这本书还没有书签（章节里按 <leader>wm 添加）", vim.log.levels.INFO)
    return
  end
  -- book order: by chapter, then by place in the chapter
  -- (按书里的顺序：先按章，再按章内位置)
  local order = {}
  for index, chapter in ipairs((reader.state.catalog or {}).chapters or {}) do
    order[tostring(chapter.chapterUid)] = index
  end
  local sorted = vim.deepcopy(list)
  table.sort(sorted, function(left, right)
    local a, b = order[tostring(left.chapter_uid)] or 0, order[tostring(right.chapter_uid)] or 0
    if a ~= b then
      return a < b
    end
    return (tonumber(left.offset) or tonumber(left.line) or 0) < (tonumber(right.offset) or tonumber(right.line) or 0)
  end)
  text_util.define_highlights()
  local items = {}
  for _, mark in ipairs(sorted) do
    items[#items + 1] = {
      text = (mark.chapter_title or "") .. " " .. (mark.excerpt or ""),
      label = string.format("%s · %s", mark.chapter_title or "?", mark.excerpt or ""),
      mark = mark,
    }
  end
  require("weread.ui").select({
    title = string.format("《%s》书签 · %d 条", book.title or "?", #items),
    items = items,
    format = function(item)
      return {
        { M.SIGN .. " ", "WereadBookmark" },
        { text_util.fit(item.mark.chapter_title or "?", 24), "WereadPreviewPart" },
        { "  " },
        { item.mark.excerpt or "" },
        {
          col = 0,
          virt_text = { { os.date("%m-%d", tonumber(item.mark.created_at) or 0) .. " ", "WereadPreviewDim" } },
          virt_text_pos = "right_align",
          hl_mode = "combine",
        },
      }
    end,
    on_choice = function(item)
      M.jump(item.mark)
    end,
  })
end

-- ------------------------------------------------------------------ search

---Matches of a query in the cached chapters of a book.
---(在一本书已缓存的章节里查找关键词)
---@param book_id string
---@param chapters table[] catalog chapters
---@param query string plain text, case-insensitive for Latin letters(纯文本；拉丁字母不区分大小写)
---@param opts table|nil { limit = integer }
---@return table[] matches { index, chapter, line, text, col }
---@return integer searched chapters searched(搜过的章节数)
---@return integer missing readable chapters not on disk(不在本地的可读章节数)
function M.search(book_id, chapters, query, opts)
  opts = opts or {}
  local limit = opts.limit or 500
  local needle = vim.trim(query or ""):lower()
  local matches = {}
  local searched, missing = 0, 0
  if needle == "" then
    return matches, 0, 0
  end
  for index, chapter in ipairs(chapters) do
    local words = tonumber(chapter.wordCount)
    if words == nil or words > 0 then
      local text = cache.read(cache.chapter_file(book_id, chapter, "md"))
      if text then
        searched = searched + 1
        local line_number = 0
        for line in (text .. "\n"):gmatch("([^\n]*)\n") do
          line_number = line_number + 1
          local col = line:lower():find(needle, 1, true)
          if col then
            matches[#matches + 1] = {
              index = index,
              chapter = chapter,
              line = line_number,
              text = line,
              col = col - 1,
            }
            if #matches >= limit then
              return matches, searched, missing
            end
          end
        end
      else
        missing = missing + 1
      end
    end
  end
  return matches, searched, missing
end

---Ask for a query and show the matches in the open book.
---(询问关键词并列出当前这本书里的匹配)
---@param query string|nil
function M.search_pick(query)
  local reader = require("weread.reader")
  local book = reader.state.book
  if not book then
    vim.notify("weread: 还没有打开任何书", vim.log.levels.WARN)
    return
  end
  local function run(input)
    input = vim.trim(input or "")
    if input == "" then
      return
    end
    local chapters = (reader.state.catalog or {}).chapters or {}
    local matches, searched, missing = M.search(book.book_id, chapters, input)
    -- the magnifier sweeps once over the page: found, or not
    -- (放大镜在书页上扫一遍：找到了，或者没找到)
    require("weread.sprites").moment("magnifier", #matches > 0 and string.format("找到 %d 处", #matches) or "没找到")
    local note = missing > 0 and string.format("（%d 章未下载，未搜）", missing) or ""
    if #matches == 0 then
      vim.notify(string.format("weread: 已下载的 %d 章里没有「%s」%s", searched, input, note), vim.log.levels.INFO)
      return
    end
    text_util.define_highlights()
    local items = {}
    for _, match in ipairs(matches) do
      local excerpt = M.excerpt(match.text)
      items[#items + 1] = {
        text = excerpt,
        label = string.format("%s · %s", match.chapter.title or "?", excerpt),
        match = match,
        excerpt = excerpt,
      }
    end
    require("weread.ui").select({
      title = string.format("《%s》搜索「%s」· %d 处%s", book.title or "?", input, #matches, note),
      items = items,
      format = function(item)
        local segments = { { text_util.fit(item.match.chapter.title or "?", 20), "WereadPreviewDim" }, { "  " } }
        -- highlight the query inside the excerpt(在摘录里高亮关键词)
        local text = item.excerpt
        local from = text:lower():find(input:lower(), 1, true)
        if from then
          segments[#segments + 1] = { text:sub(1, from - 1) }
          segments[#segments + 1] = { text:sub(from, from + #input - 1), "Search" }
          segments[#segments + 1] = { text:sub(from + #input) }
        else
          segments[#segments + 1] = { text }
        end
        return segments
      end,
      on_choice = function(item)
        reader.open_index(item.match.index, { line = item.match.line })
      end,
    })
  end
  if query and vim.trim(query) ~= "" then
    run(query)
    return
  end
  vim.ui.input({ prompt = "书内搜索：" }, run)
end

return M
