--[[
Marking the end of a chapter and the end of a book.
(为读完一章、读完一本书做个标记)

A chapter read to its last page gets a small stamp on the folio line, in the
quiet ink, gone at the next page: an acknowledgement, not a prize. The last
page of the book opens a card: the title, the days it was read here, the number
of highlights, and one of the reader's own highlights to take away. The card
can be saved as Markdown.
(读到最后一页的那一章，页脚行上会出现一个小印章，用淡墨，翻页就消失：是一声确认，不是奖品。
 读到全书最后一页时弹出一张卡片：书名、在这里读了哪些日子、划了多少条线，以及读者自己的一句划线
 带走。卡片可以存成 Markdown)

Both follow WeRead's own data and the local journal, never a count the reader
is asked to keep up.
(两者都只用微信读书自己的数据和本地日志，绝不是要读者去维持的某个计数)
]]

local fx = require("weread.fx")

local M = {}

---Stamps, one picked per chapter by its number, so the same chapter always
---gets the same one.
---(印章；按章节序号挑一个，所以同一章总是同一个)
M.STAMPS = { "【读毕】", "【已阅】", "【完】", "〔读过〕", "【合卷】" }

---@param index integer
---@return string
function M.stamp_text(index)
  return M.STAMPS[(math.floor(tonumber(index) or 1) - 1) % #M.STAMPS + 1]
end

---Put the stamp on the folio line of a window's cover; it stays until the page
---changes, which clears the cover's marks.
---(把印章盖在窗口遮罩的页脚行上；它一直留到翻页——翻页会清掉遮罩上的标记)
---@param win integer
---@param index integer chapter index(章节序号)
---@param page integer|nil
---@param total integer|nil
---@return boolean stamped
function M.stamp(win, index, page, total)
  if not fx.enabled("stamp") then
    return false
  end
  local pager = require("weread.pager")
  local cover = pager.cover_of(win)
  if not cover or not vim.api.nvim_win_is_valid(cover) then
    return false
  end
  local buf = vim.api.nvim_win_get_buf(cover)
  local row = vim.api.nvim_buf_line_count(buf) - 1
  local reader = require("weread.reader")
  local page_width = reader.page_width() or 0
  local width = vim.api.nvim_win_get_width(win)
  local column = page_width > 0 and math.min(page_width, width) or width
  local margin = require("weread.layout").margin_for(width, column)
  local text = M.stamp_text(index)
  -- only where it leaves the page number whole (只盖在不压住页码的地方)
  local center = string.format("%d / %d", page or 1, total or 1)
  local center_at = margin + math.max(0, math.floor((column - vim.fn.strdisplaywidth(center)) / 2))
  if vim.fn.strdisplaywidth(text) + 1 > center_at - margin then
    return false
  end
  vim.api.nvim_set_hl(0, "WereadStamp", { link = "WereadPaperAccent", default = true })
  local ns = vim.api.nvim_create_namespace("weread.pager")
  local ok = pcall(vim.api.nvim_buf_set_extmark, buf, ns, row, 0, {
    virt_text = { { text, "WereadStamp" } },
    virt_text_win_col = margin,
    hl_mode = "replace",
    -- over the progress bar, whose mark keeps the default priority
    -- (压在进度条上：进度条的标记用的是默认优先级)
    priority = 5000,
  })
  return ok
end

-- ------------------------------------------------------------------ the end of the book

---@param first string|nil "YYYY-MM-DD"
---@param last string|nil
---@return string
local function span(first, last)
  if not first then
    return "这一次"
  end
  local function days_between(a, b)
    local function at(key)
      local y, m, d = key:match("^(%d+)-(%d+)-(%d+)$")
      return y and os.time({ year = tonumber(y), month = tonumber(m), day = tonumber(d), hour = 12 }) or nil
    end
    local x, y = at(a), at(b)
    if not x or not y then
      return nil
    end
    return math.floor((y - x) / 86400 + 0.5) + 1
  end
  local days = days_between(first, last or first)
  if not days or days <= 1 then
    return first
  end
  return string.format("%s 至 %s · %d 天", first, last, days)
end

---My highlights of a book, from every chapter cached here and the local ones.
---(某本书我的划线：来自这里缓存的每一章，以及本地划线)
---@param book_id string
---@return string[] texts
function M.my_highlights(book_id)
  local cache = require("weread.cache")
  local store = require("weread.annotations_store")
  -- A highlight is one place in the book (chapter and range), whatever its
  -- text: a local copy joins wrapped lines with a space the account's copy
  -- does not have, and it must not be counted twice.
  -- (一条划线就是书里的一个位置（章节加区间），不管文字怎样：本地那份在折行处多了一个空格，
  --  账号那份没有，不能因此数成两条)
  local texts, seen_place, seen_text = {}, {}, {}
  local function take(chapter_key, annotation)
    local text = type(annotation) == "table" and annotation.text or nil
    if type(text) ~= "string" or text == "" then
      return
    end
    local place = tostring(chapter_key) .. ":" .. tostring(annotation.range)
    local clean = vim.trim((text:gsub("%s+", " ")))
    -- the same words with the wrapping spaces taken out (去掉折行空格之后的同一段文字)
    local bare = clean:gsub("%s", "")
    if seen_place[place] or seen_text[bare] then
      return
    end
    seen_place[place], seen_text[bare] = true, true
    texts[#texts + 1] = clean
  end
  local dir = cache.annotations_dir(book_id)
  for name, kind in vim.fs.dir(dir) do
    local chapter_key = kind == "file" and name:match("^(%d+)%.json$") or nil
    if chapter_key then
      local list = cache.read_json(dir .. "/" .. name)
      for _, annotation in ipairs(type(list) == "table" and list or {}) do
        if type(annotation) == "table" and annotation.mine then
          take(chapter_key, annotation)
        end
      end
    end
  end
  for chapter_key, list in pairs(store.local_store(book_id)) do
    for _, annotation in ipairs(type(list) == "table" and list or {}) do
      -- a record that only holds a thought on someone else's highlight is not
      -- a highlight of mine (只用来挂想法、划线却是别人的那种记录，不算我的划线)
      if type(annotation) == "table" and not (annotation.local_only and not annotation.bookmark_id) then
        take(chapter_key, annotation)
      end
    end
  end
  return texts
end

---The card's lines: what the book was, when it was read, and a line of the
---reader's own to keep.
---(卡片的行：哪本书、什么时候读的，以及读者自己留下的一句)
---@param book table { book_id, title, author }
---@param width integer
---@return string[] lines
---@return table[] marks { row, col, end_col, group } 0-based rows(行号从 0 起)
---@return string[] kinds per line: "title", "quote", "art", "hint" or "text"(每行的类型)
function M.card(book, width)
  local text_util = require("weread.text")
  local journal = require("weread.journal")
  local entry = journal.book(book.book_id) or {}
  local highlights = M.my_highlights(tostring(book.book_id))
  local lines, marks = {}, {}
  local room = width - 4
  local kinds = {}
  local function add(text, group, kind)
    local line = "  " .. text
    lines[#lines + 1] = line
    kinds[#lines] = kind or "text"
    if group then
      marks[#marks + 1] = { row = #lines - 1, col = 2, end_col = #line, group = group }
    end
  end
  -- a laurel of pixels over the title (书名上方的一圈像素桂冠)
  add(text_util.fit("⢀⣴⣦⡀  ⢀⣴⣦⡀  ⢀⣴⣦⡀", room), "WereadCardLaurel", "art")
  add("")
  add(text_util.fit("《" .. (book.title or "?") .. "》", room), "WereadCardTitle", "title")
  if book.author and book.author ~= "" then
    add(text_util.fit(book.author, room), "WereadCardDim")
  end
  add("")
  add(text_util.fit("读完了 · " .. span(entry.first, entry.last or journal.day()), room))
  if #highlights > 0 then
    add(text_util.fit(string.format("划了 %d 条线", #highlights), room), "WereadCardDim")
    -- the same line for the same book, so the card does not change each time
    -- (同一本书总是同一句，卡片不会每次都变)
    local pick = 0
    for i = 1, #tostring(book.book_id) do
      pick = pick + tostring(book.book_id):byte(i)
    end
    local quote = highlights[pick % #highlights + 1]
    add("")
    local wrapped = text_util.wrap("「" .. quote .. "」", room, 6)
    for _, line in ipairs(wrapped) do
      add(line, "WereadCardQuote", "quote")
    end
  end
  add("")
  add("s 存成 Markdown · q 关闭", "WereadCardDim", "hint")
  return lines, marks, kinds
end

function M.define_highlights()
  local function set(name, spec)
    spec.default = true
    vim.api.nvim_set_hl(0, name, spec)
  end
  set("WereadCardTitle", { link = "WereadPaperFloatTitle" })
  set("WereadCardLaurel", { link = "WereadPaperFloatAccent" })
  set("WereadCardDim", { link = "WereadPaperFloatMuted" })
  set("WereadCardQuote", { link = "WereadPaperFloat" })
  set("WereadStamp", { link = "WereadPaperAccent" })
end

---Where a book's card is saved.
---(某本书的卡片存在哪)
---@param book table
---@return string
function M.card_path(book)
  local name = (book.title or tostring(book.book_id)):gsub("[/\\:%*%?\"<>|%c]", "_")
  return require("weread.config").path("exports/" .. name .. ".读完.md")
end

---Write the card out as Markdown, each line by what it is.
---(把卡片写成 Markdown，每行按它是什么来写)
---@param book table
---@param lines string[]
---@param kinds string[]|nil from `card`(来自 card)
---@return string|nil path
function M.save_card(book, lines, kinds)
  local path = M.card_path(book)
  vim.fn.mkdir(vim.fs.dirname(path), "p")
  local out = {}
  for i, line in ipairs(lines) do
    local kind = kinds and kinds[i] or "text"
    local text = vim.trim(line)
    if kind == "title" then
      out[#out + 1] = "# " .. text
    elseif kind == "quote" then
      out[#out + 1] = "> " .. text
    elseif kind ~= "art" and kind ~= "hint" then
      out[#out + 1] = text
    end
  end
  if vim.fn.writefile(out, path) ~= 0 then
    return nil
  end
  return path
end

---Show the card for the open book, once per book.
---(为当前这本书显示卡片，每本书一次)
---A book still being written ends where its catalog ends today; when chapters
---are added and that end is reached again, the card shows again. The count of
---chapters at the finish is kept for that.
---(仍在连载的书，今天的目录在哪里结束，它就在哪里结束；之后增加了章节、又读到了末尾时，卡片会再出现
--- 一次。为此记下读完时的章节数)
---@param opts table|nil { force = boolean, book_id = string } force: show it even if it was shown before; book_id: the book the end was reached in(force：之前显示过也显示；book_id：在哪本书里读到了末尾)
---@return table|nil float
function M.trophy(opts)
  opts = opts or {}
  local reader = require("weread.reader")
  local book = reader.state.book
  if not book then
    return nil
  end
  if opts.book_id and tostring(opts.book_id) ~= tostring(book.book_id) then
    return nil
  end
  local chapters = #(((reader.state.catalog or {}).chapters) or {})
  if not opts.force and not fx.enabled("trophy") then
    return nil
  end
  local journal = require("weread.journal")
  local entry = journal.book(book.book_id, true)
  if entry and entry.finished and not opts.force and (tonumber(entry.chapters) or 0) >= chapters then
    return nil
  end
  -- A forced preview (:WeReadTrophy) must not mark the book finished.
  -- (强制预览（:WeReadTrophy）不能把书记成读完)
  if not opts.force then
    journal.finished(book.book_id, chapters)
  end
  M.define_highlights()
  local width = math.min(48, vim.o.columns - 4)
  local lines, marks, kinds = M.card(book, width)
  local view = require("weread.float").open({
    lines = lines,
    width = width,
    height = #lines,
    title = " 读完了 ",
    wrap = false,
  })
  if not view then
    return nil
  end
  local ns = vim.api.nvim_create_namespace("weread.card")
  for _, mark in ipairs(marks) do
    pcall(vim.api.nvim_buf_set_extmark, view.buf, ns, mark.row, mark.col, { end_col = mark.end_col, hl_group = mark.group })
  end
  vim.bo[view.buf].modifiable = false
  vim.keymap.set("n", "s", function()
    local path = M.save_card(book, lines, kinds)
    if path then
      vim.notify("weread: 卡片已存到 " .. path)
    else
      vim.notify("weread: 卡片保存失败", vim.log.levels.ERROR)
    end
  end, { buffer = view.buf, nowait = true, silent = true })
  return view
end

-- ------------------------------------------------------------------ wiring

---Listen for the end of a chapter and of the book.
---(监听读完一章与读完全书)
function M.setup()
  local group = vim.api.nvim_create_augroup("WereadMilestone", { clear = true })
  vim.api.nvim_create_autocmd("User", {
    group = group,
    pattern = "WereadBookEnd",
    callback = function(args)
      local data = args.data or {}
      vim.schedule(function()
        pcall(M.trophy, { book_id = data.book_id })
      end)
    end,
  })
  vim.api.nvim_create_autocmd("User", {
    group = group,
    pattern = "WereadChapterOpen",
    callback = function(args)
      local data = args.data or {}
      pcall(function()
        local book = require("weread.reader").state.book
        if book and data.book_id and tostring(book.book_id) == tostring(data.book_id) then
          require("weread.journal").opened(book.book_id, book.title)
        end
      end)
    end,
  })
end

---Stamp the chapter when its last page is reached: called after a page is
---shown, with the page number and the page count.
---(到达本章最后一页时盖章：每显示一页之后调用，带页码与总页数)
---@param win integer
---@param page integer
---@param total integer
function M.page_shown(win, page, total)
  if page < total or total < 2 then
    return
  end
  local info = require("weread.reader").buffer_info(vim.api.nvim_win_get_buf(win))
  if info then
    M.stamp(win, info.chapter_index or 1, page, total)
  end
end

return M
