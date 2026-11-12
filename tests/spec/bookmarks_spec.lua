--[[
Tests for weread.bookmarks: adding and removing a bookmark, that it persists, and
that a damaged `bookmarks.json` is never silently replaced by a fresh list.
(书签的测试：增删、持久化，以及损坏的 `bookmarks.json` 不会被一份新列表悄悄覆盖)

The chapter is faked (a buffer carrying `vim.b.weread` plus stubbed source
offsets): what is under test is the storage and the toggle logic, not the reader.
(章节是伪造的——一个带 `vim.b.weread` 的 buffer，加上打桩的源偏移：被测的是存储与切换逻辑，
 不是阅读器)
]]

local tmpdir = vim.fn.tempname()
vim.fn.mkdir(tmpdir, "p")
require("weread.config").setup({ data_dir = tmpdir })

local cache = require("weread.cache")
local reader = require("weread.reader")
local bookmarks = require("weread.bookmarks")

-- one source offset per hundred per line, so line N sits at offset N * 100
-- (每行一百个偏移：第 N 行在偏移 N * 100)
local saved_line_source = reader.line_source
local saved_line_of_source = reader.line_of_source
reader.line_source = function(_, line)
  return line * 100
end
reader.line_of_source = function(_, _, offset)
  return math.floor(offset / 100)
end

local counter = 0

---A chapter buffer of a fresh book, shown in the current window.
---(一本新书的章节 buffer，显示在当前窗口里)
---@return integer buf
---@return string book_id
local function chapter_buffer()
  counter = counter + 1
  local book_id = "bm-spec-" .. counter
  local buf = vim.api.nvim_create_buf(true, false)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "第一行", "**第二行** 的文字", "第三行" })
  vim.b[buf].weread = {
    book_id = book_id,
    chapter_uid = "7",
    chapter_key = "0007",
    chapter_title = "第七章",
    chapter_index = 1,
  }
  vim.api.nvim_set_current_buf(buf)
  return buf, book_id
end

local function bookmarks_file(book_id)
  return cache.book_file(book_id, "bookmarks.json")
end

---Files next to `path` whose name starts with `path .. ".corrupt-"`.
---(与 `path` 同目录、名字以 `path .. ".corrupt-"` 开头的文件)
local function backups_of(path)
  return vim.fn.glob(path .. ".corrupt-*", false, true)
end

describe("bookmarks.list", function()
  it("is empty for a book with no bookmarks file", function()
    eq(bookmarks.list("bm-spec-none"), {})
  end)
end)

describe("bookmarks.toggle", function()
  it("adds a bookmark by source offset and removes it on the second call", function()
    local buf, book_id = chapter_buffer()
    vim.api.nvim_win_set_cursor(0, { 2, 0 })

    eq(bookmarks.toggle(buf), "added")
    local list = bookmarks.list(book_id)
    eq(#list, 1)
    eq(list[1].chapter_uid, "7")
    eq(list[1].chapter_key, "0007")
    eq(list[1].chapter_title, "第七章")
    eq(list[1].offset, 200, "stored by source offset, not by line")
    eq(list[1].line, 2)
    eq(list[1].excerpt, "第二行 的文字", "markdown markers are stripped from the excerpt")
    truthy(list[1].created_at)

    eq(bookmarks.toggle(buf), "removed")
    eq(bookmarks.list(book_id), {})
  end)

  it("keeps bookmarks on different lines apart", function()
    local buf, book_id = chapter_buffer()
    vim.api.nvim_win_set_cursor(0, { 1, 0 })
    eq(bookmarks.toggle(buf), "added")
    vim.api.nvim_win_set_cursor(0, { 3, 0 })
    eq(bookmarks.toggle(buf), "added")
    eq(#bookmarks.list(book_id), 2)

    vim.api.nvim_win_set_cursor(0, { 1, 0 })
    eq(bookmarks.toggle(buf), "removed")
    local left = bookmarks.list(book_id)
    eq(#left, 1)
    eq(left[1].line, 3, "only the bookmark under the cursor went")
  end)

  it("persists to books/<id>/bookmarks.json and reads back from disk", function()
    local buf, book_id = chapter_buffer()
    vim.api.nvim_win_set_cursor(0, { 2, 0 })
    bookmarks.toggle(buf)

    local raw = assert(cache.read(bookmarks_file(book_id)), "the file was written")
    local decoded = vim.json.decode(raw)
    eq(decoded.version, 1)
    eq(#decoded.bookmarks, 1)
    eq(decoded.bookmarks[1].offset, 200)
  end)

  it("draws a sign on the bookmarked line and clears it again", function()
    local buf = chapter_buffer()
    local namespace = vim.api.nvim_create_namespace("weread.bookmarks")
    vim.api.nvim_win_set_cursor(0, { 2, 0 })
    bookmarks.toggle(buf)
    local marks = vim.api.nvim_buf_get_extmarks(buf, namespace, 0, -1, {})
    eq(#marks, 1)
    eq(marks[1][2], 1, "0-based row of line 2")
    bookmarks.toggle(buf)
    eq(#vim.api.nvim_buf_get_extmarks(buf, namespace, 0, -1, {}), 0)
  end)

  it("refuses outside a chapter buffer", function()
    local buf = vim.api.nvim_create_buf(true, false)
    vim.api.nvim_set_current_buf(buf)
    local told = nil
    local notify = vim.notify
    vim.notify = function(message)
      told = message
    end
    local action = bookmarks.toggle(buf)
    vim.notify = notify
    eq(action, nil)
    matches(told, "只能在章节里加书签")
  end)
end)

describe("bookmarks with a damaged file", function()
  it("moves invalid JSON aside, then starts a fresh list that saves", function()
    local buf, book_id = chapter_buffer()
    local path = bookmarks_file(book_id)
    cache.ensure_book_dirs(book_id)
    assert(cache.write(path, "{ this is not json"))

    eq(bookmarks.list(book_id), {})
    eq(#backups_of(path), 1, "the broken file was kept, not overwritten")
    eq(cache.read(backups_of(path)[1]), "{ this is not json")

    vim.api.nvim_win_set_cursor(0, { 2, 0 })
    eq(bookmarks.toggle(buf), "added", "a new bookmark can be saved afterwards")
    eq(#bookmarks.list(book_id), 1)
    eq(#backups_of(path), 1, "the backup is still there")
  end)

  it("treats valid JSON that is not an object as damaged too", function()
    local _, book_id = chapter_buffer()
    local path = bookmarks_file(book_id)
    cache.ensure_book_dirs(book_id)
    assert(cache.write(path, "null"))

    eq(bookmarks.list(book_id), {})
    eq(#backups_of(path), 1)
  end)

  it("drops entries that are not tables but keeps the rest and a copy of the file", function()
    local _, book_id = chapter_buffer()
    local path = bookmarks_file(book_id)
    cache.ensure_book_dirs(book_id)
    local original = vim.json.encode({
      version = 1,
      bookmarks = { "stray", { chapter_uid = "7", offset = 300, line = 3 }, 42 },
    })
    assert(cache.write(path, original))

    local list = bookmarks.list(book_id)
    eq(#list, 1)
    eq(list[1].offset, 300)
    local backups = backups_of(path)
    eq(#backups, 1, "a copy of the original was kept before entries were dropped")
    eq(cache.read(backups[1]), original)
  end)

  it("does not overwrite a bookmarks file that exists but cannot be read", function()
    local buf, book_id = chapter_buffer()
    local path = bookmarks_file(book_id)
    cache.ensure_book_dirs(book_id)
    -- A directory in the file's place: it exists, and reading it fails. (Not
    -- chmod: that proves nothing when the suite runs as root.)
    -- (在文件的位置放一个目录：它存在，读它会失败。不用 chmod：以 root 跑测试时那证明不了什么)
    vim.fn.mkdir(path, "p")

    local errors = {}
    local notify = vim.notify
    vim.notify = function(message, level)
      errors[#errors + 1] = { message = message, level = level }
    end
    vim.api.nvim_win_set_cursor(0, { 2, 0 })
    local action = bookmarks.toggle(buf)
    vim.notify = notify

    eq(action, nil, "toggle reports that nothing was saved")
    eq(vim.fn.isdirectory(path), 1, "what was there is untouched")
    eq(#errors, 1)
    matches(errors[1].message, "书签保存失败")
    eq(errors[1].level, vim.log.levels.ERROR)

    vim.fn.delete(path, "rf")
  end)

  it("saves again once the file can be read", function()
    local buf, book_id = chapter_buffer()
    local path = bookmarks_file(book_id)
    cache.ensure_book_dirs(book_id)
    vim.fn.mkdir(path, "p")
    local notify = vim.notify
    vim.notify = function() end
    vim.api.nvim_win_set_cursor(0, { 2, 0 })
    bookmarks.toggle(buf)
    vim.notify = notify

    vim.fn.delete(path, "rf")
    eq(bookmarks.toggle(buf), "added", "the guard is lifted by a successful read")
    eq(#bookmarks.list(book_id), 1)
  end)
end)

-- put the reader back as the other specs expect it
-- (把阅读器还原成其它 spec 期待的样子)
reader.line_source = saved_line_source
reader.line_of_source = saved_line_of_source
