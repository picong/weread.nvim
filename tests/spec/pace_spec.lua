--[[
Tests for weread.pace (the reader's pace and the time left in a chapter), the
folio that shows it, and the line length chosen at runtime.
(pace 单测：读者的阅读速度与本章剩余时间、显示它的页脚，以及运行时选择的行宽)
]]

local config = require("weread.config")
local pace = require("weread.pace")
local prefs = require("weread.prefs")

local tmpdir = vim.fn.tempname()
vim.fn.mkdir(tmpdir, "p")

local function fresh()
  config.setup({ data_dir = tmpdir, keymaps = false, sync_interval = 0 })
  prefs.clear()
  pace._reset()
end

describe("pace", function()
  it("starts from the default pace", function()
    fresh()
    eq(pace.cells_per_minute(), pace.DEFAULT_CELLS_PER_MINUTE)
    eq(pace.minutes(pace.DEFAULT_CELLS_PER_MINUTE * 3), 3)
    eq(pace.minutes(0), 0)
  end)

  it("learns from pages that were read and ignores the rest", function()
    fresh()
    falsy(pace.sample(1000, 1), "a page turned at once was skipped")
    falsy(pace.sample(1000, 3600), "a page left open for an hour was not read")
    falsy(pace.sample(100, 100), "60 cells a minute is someone looking away")
    falsy(pace.sample(0, 30), "an empty page says nothing")
    eq(pace.cells_per_minute(), pace.DEFAULT_CELLS_PER_MINUTE, "none of those moved the pace")
    for _ = 1, 30 do
      truthy(pace.sample(400, 60), "400 cells in a minute")
    end
    local learned = pace.cells_per_minute()
    truthy(math.abs(learned - 400) < 5, "the pace converges on the reader's: " .. learned)
  end)

  it("times the page a forward turn leaves, not one shown again or turned back", function()
    fresh()
    local win, buf = 1000, 1
    pace.page_shown(win, buf, 1, 500, 0)
    pace.page_shown(win, buf, 1, 500, 30) -- a re-measure (重新量页)
    pace.page_shown(win, buf, 20, 500, 60) -- forward after 60 seconds (60 秒后往后翻)
    truthy(math.abs(pace.cells_per_minute() - 500) < 1, "the first sample replaces the default")
    pace.page_shown(win, buf, 1, 500, 61) -- back (往回翻)
    pace.page_shown(win, buf, 20, 500, 62) -- forward again, too fast (又往后翻，太快)
    truthy(math.abs(pace.cells_per_minute() - 500) < 1, "going back and forth taught nothing")
  end)

  it("keeps the pace for the next session", function()
    fresh()
    for _ = 1, 5 do
      pace.sample(900, 60)
    end
    pace.flush()
    local saved = prefs.get("pace")
    truthy(saved and saved.cells_per_minute, "written to the preferences")
    local learned = pace.cells_per_minute()
    pace._reset()
    eq(pace.cells_per_minute(), learned, "and read back")
  end)

  it("labels short and long stretches", function()
    fresh()
    local rate = pace.DEFAULT_CELLS_PER_MINUTE
    eq(pace.label(10), "不到 1 分钟")
    eq(pace.label(rate * 5), "约 5 分钟")
    eq(pace.label(rate * 60), "约 1 小时")
    eq(pace.label(rate * 80), "约 1 小时 20 分")
  end)

  it("counts text, not the markup of an illustration", function()
    local lines = { "　　汉字", "", "![图 1](/very/long/cache/path/epub_x.png)", "abc" }
    eq(pace.cells_of(lines, 1, 4), 8 + 0 + 3)
  end)
end)

describe("pager folio with time left", function()
  local pager = require("weread.pager")
  local reader = require("weread.reader")

  it("shows the time left when there is room, and drops it first when there is not", function()
    fresh()
    vim.o.lines = 24
    vim.o.columns = 80
    local buf = vim.api.nvim_create_buf(true, false)
    local lines = {}
    for index = 1, 200 do
      lines[index] = "　　" .. string.rep("字", 20) .. index
    end
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
    vim.b[buf].weread = { book_id = "B", chapter_index = 1, chapter_key = "0001", chapter_uid = "1" }
    vim.api.nvim_win_set_buf(0, buf)
    local win = vim.api.nvim_get_current_win()
    reader.set_page_width(nil)

    local wide = pager.folio(win, 1, 9, pace.DEFAULT_CELLS_PER_MINUTE * 7)
    matches(wide, "本章剩 8 页 · 约 7 分钟")
    local last = pager.folio(win, 9, 9, 100)
    falsy(last:find("分钟", 1, true), "on the last page there is no time to show")
    matches(last, "本章完")

    pager.show(win, 1)
    local cover = pager.cover_of(win)
    truthy(cover)
    local folio = vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(cover), -2, -1, false)[1]
    matches(folio, "分钟")

    vim.cmd("vsplit")
    local narrow = vim.api.nvim_get_current_win()
    vim.api.nvim_win_set_width(narrow, 30)
    local squeezed = pager.folio(narrow, 1, 9, pace.DEFAULT_CELLS_PER_MINUTE * 7)
    falsy(squeezed:find("分钟", 1, true), "a narrow window loses the time first")
    matches(squeezed, "1 / 9")
    vim.cmd("close")
    pager.prune()
    vim.api.nvim_win_set_buf(win, vim.api.nvim_create_buf(true, true))
    pager.prune()
    pcall(vim.api.nvim_buf_delete, buf, { force = true })
  end)
end)

describe("line length chosen at runtime", function()
  local layout = require("weread.layout")

  it("clamps what the reader asks for", function()
    eq(layout.clamp_chars(2), layout.CHOSEN_MIN)
    eq(layout.clamp_chars(999), layout.CHOSEN_MAX)
    eq(layout.clamp_chars(31), 31)
  end)

  it("remembers the choice unless the config names a line length", function()
    local weread = require("weread")
    prefs.clear()
    prefs.set("page_chars", 32)
    weread.setup({ data_dir = tmpdir, keymaps = false, sync_interval = 0 })
    eq(config.get().layout.page_chars, 32, "the remembered line length fills in")
    falsy(config.pinned("layout.page_chars"))

    weread.setup({ data_dir = tmpdir, keymaps = false, sync_interval = 0, layout = { page_chars = 24 } })
    eq(config.get().layout.page_chars, 24, "a configured one wins")
    truthy(config.pinned("layout.page_chars"))
    prefs.clear()
    config.setup({ data_dir = tmpdir, keymaps = false, sync_interval = 0 })
  end)

  it("steps from the current width and stores it", function()
    config.setup({ data_dir = tmpdir, keymaps = false, sync_interval = 0 })
    prefs.clear()
    local reader = require("weread.reader")
    local seen = {}
    local notify = vim.notify
    vim.notify = function(message)
      seen[#seen + 1] = message
    end
    local ok, err = pcall(function()
      eq(reader.set_page_chars(nil, 2), 28, "26 + 2")
      eq(reader.set_page_chars(nil, -4), 24)
      eq(reader.set_page_chars(100), layout.CHOSEN_MAX, "clamped")
    end)
    vim.notify = notify
    if not ok then
      error(err, 0)
    end
    eq(prefs.get("page_chars"), layout.CHOSEN_MAX)
    eq(config.get().layout.adaptive, false)
    matches(seen[1], "每行 28 字")
    prefs.clear()
    config.setup({ data_dir = tmpdir, keymaps = false, sync_interval = 0 })
  end)
end)
