--[[
Notes export (:WeReadExport): every highlight and thought of a book, as a
Markdown file or as a quickfix list to step through.
(笔记导出 :WeReadExport：一本书的全部划线与想法，导出为 Markdown 文件，或放进 quickfix
 逐条跳转)

Both come from the official Agent API: /book/bookmarklist gives my highlights
for the whole book with the chapter titles, /review/list/mine my thoughts with
the passage (`abstract`) each was written on. A thought whose range matches a
highlight is printed under it; one without a highlight stands on its own with
its passage quoted.
(两者都来自官方 Agent API：/book/bookmarklist 给出整本书我的划线和章节标题，
 /review/list/mine 给出我的想法以及各自所针对的原文（abstract）。range 与某条划线一致的
 想法排在那条划线下面；没有对应划线的想法单独成条，并引出它针对的原文)
]]

local M = {}

local cache = require("weread.cache")
local store = require("weread.annotations_store")

---Thoughts fetched per page.
---(每页拉取的想法数)
local PAGE = 100

---@param range string|nil
---@return integer
local function range_start(range)
  return tonumber(type(range) == "string" and range:match("^(%d+)") or "") or 0
end

-- ------------------------------------------------------------------ fetching

---All my thoughts on a book, following `hasMore`.
---(一本书里我的全部想法，按 hasMore 翻页)
---@param book_id string
---@param callback fun(ok: boolean, thoughts: table[]|string)
local function fetch_thoughts(book_id, callback)
  local gateway = require("weread.api_gateway")
  local thoughts = {}
  local function page(max_idx, guard)
    -- the gateway insists on the lower-case `bookid` for this one
    -- (这个接口只认小写的 `bookid`)
    gateway.call("/review/list/mine", {
      bookid = book_id,
      count = PAGE,
      maxIdx = max_idx,
      synckey = 0,
    }, { silent = true }, function(ok, data)
      if not ok then
        callback(false, data)
        return
      end
      local last = nil
      for _, entry in ipairs(data.reviews or {}) do
        local review = type(entry.review) == "table" and entry.review or {}
        if type(review.content) == "string" then
          thoughts[#thoughts + 1] = {
            id = review.reviewId or entry.reviewId,
            content = review.content,
            abstract = type(review.abstract) == "string" and review.abstract or "",
            range = review.range,
            chapter_uid = review.chapterUid and tostring(review.chapterUid) or nil,
            chapter_title = review.chapterTitle or review.chapterName,
            time = tonumber(review.createTime),
          }
        end
        last = tonumber(entry.idx) or tonumber(review.createTime) or last
      end
      if tonumber(data.hasMore) == 1 and last and guard < 50 then
        page(last, guard + 1)
        return
      end
      callback(true, thoughts)
    end)
  end
  page(0, 1)
end

---Fetch everything the export needs for one book.
---(拉取一本书导出所需的全部数据)
---@param book_id string
---@param callback fun(ok: boolean, notes: table|string)
function M.fetch(book_id, callback)
  local gateway = require("weread.api_gateway")
  gateway.call("/book/bookmarklist", { bookId = book_id }, function(ok, data)
    if not ok then
      callback(false, data)
      return
    end
    fetch_thoughts(book_id, function(thoughts_ok, thoughts)
      if not thoughts_ok then
        -- highlights alone are still worth exporting(只有划线也值得导出)
        require("weread.log").warn("export: /review/list/mine failed: %s", tostring(thoughts))
        thoughts = {}
      end
      callback(true, { bookmarks = data, thoughts = thoughts })
    end)
  end)
end

-- ------------------------------------------------------------------ grouping

---Notes in book order: chapters in catalog order, entries by position.
---(按书中顺序排好的笔记：章节按目录顺序，条目按章内位置)
---@param notes table { bookmarks = /book/bookmarklist payload, thoughts = table[] }
---@param catalog table[]|nil catalog chapters, for the order(目录章节，用来定顺序)
---@return table[] chapters { uid, title, entries = { kind, text, range, thoughts, time } }
function M.group(notes, catalog)
  local data = notes.bookmarks or {}
  local titles, order = {}, {}
  for index, chapter in ipairs(catalog or {}) do
    titles[tostring(chapter.chapterUid)] = chapter.title
    order[tostring(chapter.chapterUid)] = index
  end
  for _, chapter in ipairs(data.chapters or {}) do
    local uid = tostring(chapter.chapterUid)
    titles[uid] = titles[uid] or chapter.title
    order[uid] = order[uid] or tonumber(chapter.chapterIdx) or 0
  end

  local chapters, by_uid = {}, {}
  local function chapter_of(uid, title)
    uid = tostring(uid or "?")
    if not by_uid[uid] then
      by_uid[uid] = { uid = uid, title = titles[uid] or title or "（未知章节）", entries = {} }
      chapters[#chapters + 1] = by_uid[uid]
    end
    return by_uid[uid]
  end

  local by_range = {}
  for _, item in ipairs(data.updated or {}) do
    -- type 1 is a highlight; bookmarks (type 0) never come back here
    -- (type 1 是划线；书签（type 0）从不在这里返回)
    if item.range and type(item.markText) == "string" then
      local entry = {
        kind = "highlight",
        text = item.markText,
        range = item.range,
        thoughts = {},
        time = tonumber(item.createTime),
      }
      local chapter = chapter_of(item.chapterUid)
      chapter.entries[#chapter.entries + 1] = entry
      by_range[tostring(item.chapterUid) .. ":" .. item.range] = entry
    end
  end
  for _, thought in ipairs(notes.thoughts or {}) do
    local key = tostring(thought.chapter_uid) .. ":" .. tostring(thought.range)
    local host = by_range[key]
    if host then
      host.thoughts[#host.thoughts + 1] = thought
    else
      local chapter = chapter_of(thought.chapter_uid, thought.chapter_title)
      chapter.entries[#chapter.entries + 1] = {
        kind = "thought",
        text = thought.abstract,
        range = thought.range,
        thoughts = { thought },
        time = thought.time,
      }
    end
  end

  table.sort(chapters, function(left, right)
    return (order[left.uid] or math.huge) < (order[right.uid] or math.huge)
  end)
  for _, chapter in ipairs(chapters) do
    table.sort(chapter.entries, function(left, right)
      return range_start(left.range) < range_start(right.range)
    end)
  end
  return chapters
end

-- ------------------------------------------------------------------ markdown

---Quote a possibly multi-line passage.
---(把可能多行的原文写成引用)
---@param text string
---@return string[]
local function quote(text)
  local lines = {}
  for line in (vim.trim(text or "") .. "\n"):gmatch("([^\n]*)\n") do
    lines[#lines + 1] = "> " .. vim.trim(line)
  end
  return lines
end

---Render the notes as Markdown.
---(把笔记渲染成 Markdown)
---@param book table { title, author, book_id }
---@param chapters table[] from M.group
---@return string[] lines
function M.markdown(book, chapters)
  local highlights, thoughts = 0, 0
  for _, chapter in ipairs(chapters) do
    for _, entry in ipairs(chapter.entries) do
      if entry.kind == "highlight" then
        highlights = highlights + 1
      end
      thoughts = thoughts + #entry.thoughts
    end
  end
  local lines = {
    "# " .. (book.title or "未知书名"),
    "",
  }
  if book.author and book.author ~= "" then
    lines[#lines + 1] = "- 作者：" .. book.author
  end
  lines[#lines + 1] = string.format("- 划线 %d 条，想法 %d 条", highlights, thoughts)
  lines[#lines + 1] = "- 导出时间：" .. os.date("%Y-%m-%d %H:%M")
  if book.book_id then
    lines[#lines + 1] = "- bookId：`" .. tostring(book.book_id) .. "`"
  end
  for _, chapter in ipairs(chapters) do
    lines[#lines + 1] = ""
    lines[#lines + 1] = "## " .. chapter.title
    for _, entry in ipairs(chapter.entries) do
      lines[#lines + 1] = ""
      if entry.text and vim.trim(entry.text) ~= "" then
        vim.list_extend(lines, quote(entry.text))
      end
      for _, thought in ipairs(entry.thoughts) do
        lines[#lines + 1] = ""
        local when = thought.time and os.date("%Y-%m-%d", thought.time) or nil
        local body = vim.split(vim.trim(thought.content or ""), "\n", { plain = true })
        lines[#lines + 1] = "💭 " .. (body[1] or "") .. (when and #body == 1 and ("  _" .. when .. "_") or "")
        for index = 2, #body do
          lines[#lines + 1] = "   " .. body[index]
        end
        if when and #body > 1 then
          lines[#lines + 1] = "   _" .. when .. "_"
        end
      end
    end
  end
  lines[#lines + 1] = ""
  return lines
end

-- ------------------------------------------------------------------ quickfix

---Quickfix items: one per highlight or thought, pointing at the cached
---chapter file and line when the chapter is on disk.
---(quickfix 条目：每条划线或想法一条；章节已在本地时，指向缓存章节文件的对应行)
---@param book_id string
---@param chapters table[] from M.group
---@param catalog table[] catalog chapters
---@return table[] items
function M.quickfix_items(book_id, chapters, catalog)
  local xhtml = require("weread.xhtml")
  local by_uid = {}
  for index, chapter in ipairs(catalog or {}) do
    by_uid[tostring(chapter.chapterUid)] = { chapter = chapter, index = index }
  end
  local items = {}
  for _, group in ipairs(chapters) do
    local found = by_uid[group.uid]
    local path, meta = nil, nil
    if found then
      path = cache.chapter_file(book_id, found.chapter, "md")
      if vim.fn.filereadable(path) == 1 then
        meta = store.chapter_map(book_id, cache.chapter_key(found.chapter))
      else
        path = nil
      end
    end
    for _, entry in ipairs(group.entries) do
      local line = 1
      if meta and entry.range then
        local located = xhtml.locate(meta, range_start(entry.range))
        line = located and located.line and (located.line + 1) or 1
      end
      local text = vim.trim((entry.text or ""):gsub("%s+", " "))
      local first = entry.thoughts[1]
      if first then
        text = text .. "  💭 " .. vim.trim((first.content or ""):gsub("%s+", " "))
      end
      items[#items + 1] = {
        filename = path,
        lnum = line,
        text = string.format("[%s] %s", group.title, text),
        user_data = { chapter_index = found and found.index or nil, offset = range_start(entry.range) },
        valid = path ~= nil,
      }
    end
  end
  return items
end

-- ------------------------------------------------------------------ entry

---Export the open book's notes.
---(导出当前这本书的笔记)
---@param target string|nil "qf" for the quickfix list, else a file path (default: data_dir/exports/<title>.md)
function M.run(target)
  local reader = require("weread.reader")
  local book = reader.state.book
  if not book then
    vim.notify("weread: 还没有打开任何书", vim.log.levels.WARN)
    return
  end
  local book_id = tostring(book.book_id)
  local catalog = (reader.state.catalog or {}).chapters or {}
  require("weread.ui").notify("weread: 正在导出笔记…", vim.log.levels.INFO, { routine = true })
  M.fetch(book_id, function(ok, notes)
    if not ok then
      vim.notify("weread: 导出失败：" .. tostring(notes), vim.log.levels.ERROR)
      return
    end
    local chapters = M.group(notes, catalog)
    if #chapters == 0 then
      vim.notify("weread: 这本书还没有划线和想法", vim.log.levels.INFO)
      return
    end
    if target == "qf" then
      local items = M.quickfix_items(book_id, chapters, catalog)
      vim.fn.setqflist({}, " ", { title = "微信读书笔记 · " .. (book.title or book_id), items = items })
      vim.cmd("copen")
      -- <CR> opens the chapter in the reader instead of the raw cache file, so
      -- a chapter not downloaded yet works too, and the page is a real page
      -- (<CR> 用阅读器打开章节而不是缓存文件本身：没下载的章节也能跳，而且看到的是真正的书页)
      local qf = vim.api.nvim_get_current_buf()
      vim.keymap.set("n", "<CR>", function()
        local index = vim.fn.line(".")
        local entry = vim.fn.getqflist({ items = 0 }).items[index]
        local data = entry and entry.user_data
        if type(data) ~= "table" or not data.chapter_index then
          vim.cmd("cc " .. index)
          return
        end
        vim.cmd("wincmd p")
        reader.open_index(data.chapter_index, { source_offset = data.offset })
      end, { buffer = qf, desc = "weread: 打开这条笔记所在的章节" })
      return
    end
    local path = target and target ~= "" and vim.fn.expand(target) or nil
    if not path then
      local name = (book.title or book_id):gsub("[/\\:%*%?\"<>|]", "_")
      path = require("weread.config").path("exports/" .. name .. ".md")
    end
    vim.fn.mkdir(vim.fn.fnamemodify(path, ":h"), "p")
    if not cache.write(path, table.concat(M.markdown(book, chapters), "\n")) then
      vim.notify("weread: 写入失败：" .. path, vim.log.levels.ERROR)
      return
    end
    vim.notify("weread: 笔记已导出到 " .. vim.fn.fnamemodify(path, ":~"), vim.log.levels.INFO)
    vim.cmd("edit " .. vim.fn.fnameescape(path))
  end)
end

return M
