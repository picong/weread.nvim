--[[
Tests for the things that grow and play around reading: the zone scenes, the
local journal, the plant and the garden, and the chapter and book milestones.
(随阅读生长、在阅读周围玩耍的东西的单测：发呆场景、本地日志、植物与花园、读完一章与一本书)
]]

local config = require("weread.config")
local tmpdir = "/tmp/weread-test-zone"
vim.fn.delete(tmpdir, "rf")
vim.fn.mkdir(tmpdir, "p")
config.setup({ data_dir = tmpdir })

local zone = require("weread.zone")
local journal = require("weread.journal")
local garden = require("weread.garden")
local milestone = require("weread.milestone")
local fx = require("weread.fx")

local function chapter_buffer(lines)
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.b[buf].weread = { book_id = "Z1", chapter_key = "0001", chapter_index = 1, chapter_uid = "1" }
  vim.bo[buf].modifiable = false
  vim.api.nvim_win_set_buf(0, buf)
  return buf
end

describe("zone scenes", function()
  it("grabs the page as cells, wide characters taking two", function()
    local buf = chapter_buffer({ "中a", "" })
    local rows = zone.grab(vim.api.nvim_get_current_win())
    eq(rows[1][1][1], "中")
    eq(rows[1][1][2], 2)
    eq(rows[1][2][2], 0, "the second half of the wide character")
    eq(rows[1][3][1], "a")
    eq(zone.join({ rows[1][1], rows[1][2], rows[1][3] }), "中a")
    eq(zone.join({ rows[1][2], rows[1][3] }), " a", "half a wide character is a space")
    vim.api.nvim_buf_delete(buf, { force = true })
  end)

  it("lets the letters fall until the page is empty", function()
    local rows = {
      { { "a", 1 }, { "b", 1 }, { " ", 1 } },
      { { " ", 1 }, { " ", 1 }, { " ", 1 } },
    }
    local state = zone.rain_state(rows)
    eq(#state.glyphs, 2)
    local steps = 0
    while zone.rain_step(state, 1) and steps < 200 do
      steps = steps + 1
    end
    truthy(steps < 200, "it ends")
    eq(zone.rain_lines(state), { "   ", "   " }, "nothing left")
  end)

  it("plays the game of life by its rules", function()
    -- a blinker: three in a row turn into three in a column
    -- (闪烁子：横着的三个变成竖着的三个)
    local blank = { " ", 1 }
    local ink = { "x", 1 }
    local rows = {}
    for y = 1, 5 do
      rows[y] = {}
      for x = 1, 5 do
        rows[y][x] = (y == 3 and x >= 2 and x <= 4) and ink or blank
      end
    end
    local state = zone.life_state(rows)
    truthy(zone.life_step(state))
    local lines = zone.life_lines(state)
    eq(lines[2], "  █  ")
    eq(lines[3], "  █  ")
    eq(lines[4], "  █  ")
    zone.life_step(state)
    eq(zone.life_lines(state)[3], " ███ ", "and back")
  end)

  it("keeps the fire hottest at the base", function()
    local state = zone.fire_state(10, 8)
    for _ = 1, 20 do
      zone.fire_step(state, 3)
    end
    local function row_heat(y)
      local sum = 0
      for x = 1, 10 do
        sum = sum + state.heat[y][x]
      end
      return sum
    end
    truthy(row_heat(8) > row_heat(1), "bottom hotter than top")
    local ramp = zone.fire_ramp({ bg = "#ede4d3", accent = "#7d5038", fg = "#4a4036" })
    eq(ramp[0], "#ede4d3", "cold is the page")
  end)

  it("draws over the chapter in a float, swallows the key that ends it, and leaves the text alone", function()
    local buf = chapter_buffer({ "　　史前史中，没有别的场景", "比巨兽在焦油坑中垂死挣扎" })
    local before = #vim.api.nvim_list_wins()
    fx._force = true
    truthy(zone.play("life"))
    truthy(zone.playing())
    eq(#vim.api.nvim_list_wins(), before + 1, "one float")
    vim.wait(50)
    zone.stop()
    fx._force = false
    falsy(zone.playing())
    eq(#vim.api.nvim_list_wins(), before, "and it is gone")
    eq(vim.api.nvim_buf_get_lines(buf, 0, -1, false)[1], "　　史前史中，没有别的场景")
    vim.api.nvim_buf_delete(buf, { force = true })
  end)

  it("refuses outside a chapter and unknown scenes", function()
    local notify = vim.notify
    local said = {}
    vim.notify = function(message)
      said[#said + 1] = message
    end
    local plain = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_win_set_buf(0, plain)
    falsy(zone.play("rain"))
    local buf = chapter_buffer({ "x" })
    falsy(zone.play("snow"))
    vim.notify = notify
    eq(#said, 2)
    vim.api.nvim_buf_delete(buf, { force = true })
    vim.api.nvim_buf_delete(plain, { force = true })
  end)
end)

describe("journal", function()
  it("adds up today's reading and keeps it across a reload", function()
    journal._reset()
    local now = os.time({ year = 2026, month = 10, day = 28, hour = 20 })
    journal.add(90, now)
    journal.add(30, now)
    eq(journal.seconds("2026-10-28"), 120)
    truthy(journal.save())
    journal._reset()
    eq(journal.seconds("2026-10-28"), 120, "read back from the file")
  end)

  it("counts reading weeks in a row, a missed day costing nothing", function()
    journal._reset()
    vim.fn.delete(config.path("journal.json"))
    journal._reset()
    -- Wednesday 2026-10-28; reading on one day of each of the last three weeks
    -- (2026-10-28 是周三；过去三周每周有一天读过)
    for _, day in ipairs({ "2026-10-26", "2026-10-21", "2026-10-13" }) do
      local y, m, d = day:match("(%d+)-(%d+)-(%d+)")
      journal.add(600, os.time({ year = tonumber(y), month = tonumber(m), day = tonumber(d), hour = 12 }))
    end
    local now = os.time({ year = 2026, month = 10, day = 28, hour = 12 })
    eq(journal.week_streak(now), 3)
    -- a week with nothing breaks the run (整周没读才会断)
    journal.add(600, os.time({ year = 2026, month = 9, day = 29, hour = 12 }))
    eq(journal.week_streak(now), 3, "the gap week before it ends the count")
  end)

  it("remembers when a book was first and last read, and that it was finished", function()
    journal._reset()
    journal.opened("B9", "测试书")
    local entry = journal.book("B9")
    eq(entry.first, journal.day())
    eq(entry.title, "测试书")
    journal.finished("B9")
    eq(journal.book("B9").finished, journal.day())
  end)

  it("counts only pages the pace module accepted as reading", function()
    journal._reset()
    vim.fn.delete(config.path("journal.json"))
    journal._reset()
    local pace = require("weread.pace")
    pace._reset()
    local buf = vim.api.nvim_create_buf(false, true)
    pace.page_shown(1000, buf, 1, 400, 0)
    pace.page_shown(1000, buf, 20, 400, 30)
    eq(journal.seconds(), 30, "a page read for 30 seconds")
    pace.page_shown(1000, buf, 40, 400, 30 + 3600)
    eq(journal.seconds(), 30, "a page left open for an hour counts for nothing")
    pace._reset()
    vim.api.nvim_buf_delete(buf, { force = true })
  end)
end)

describe("garden", function()
  it("grows through its stages with today's minutes", function()
    eq(garden.stage(0), 1)
    eq(garden.stage(5 * 60), 2)
    eq(garden.stage(16 * 60), 3)
    eq(garden.stage(45 * 60), 4)
    eq(garden.stage(3 * 3600), 5)
    eq(#garden.GLYPHS, #garden.STAGES)
    for _, glyph in ipairs(garden.GLYPHS) do
      eq(vim.fn.strdisplaywidth(glyph), 1, "one cell, so the winbar does not shift")
    end
  end)

  it("puts the plant on the winbar unless it is off", function()
    matches(garden.winbar_item(), "^%%#Weread")
    config.get().animations.plant = false
    eq(garden.winbar_item(), "")
    config.get().animations.plant = true
  end)

  it("lays a month out as a garden, empty ground for days not read", function()
    journal._reset()
    vim.fn.delete(config.path("journal.json"))
    journal._reset()
    journal.add(40 * 60, os.time({ year = 2026, month = 10, day = 5, hour = 12 }))
    local rows = garden.month(2026, 10, { [6] = 120 })
    eq(#rows, 6, "header plus five weeks")
    local text = {}
    for _, row in ipairs(rows) do
      local parts = {}
      for _, segment in ipairs(row) do
        parts[#parts + 1] = segment[1]
      end
      text[#text + 1] = table.concat(parts)
    end
    local all = table.concat(text, "\n")
    truthy(all:find(" 5⣴⣦", 1, true), "a day read for 40 minutes is in flower: " .. all)
    truthy(all:find(" 6⡀", 1, true), "WeRead's own total fills in a day the journal missed")
    truthy(all:find(" 7⠂⠂", 1, true), "a day not read is empty ground")
    falsy(all:find("✗", 1, true))
    for _, line in ipairs(text) do
      truthy(vim.api.nvim_strwidth(line) <= 40, "fits: " .. line)
    end
  end)
end)

describe("milestones", function()
  it("picks the same stamp for the same chapter", function()
    eq(milestone.stamp_text(1), milestone.stamp_text(1 + #milestone.STAMPS))
    truthy(milestone.stamp_text(1) ~= milestone.stamp_text(2))
  end)

  it("stamps the folio on a chapter's last page and the next page clears it", function()
    local pager = require("weread.pager")
    local lines = {}
    for i = 1, 120 do
      lines[i] = "　　正文" .. i
    end
    local buf = chapter_buffer(lines)
    local win = vim.api.nvim_get_current_win()
    fx._force = true
    local starts = pager.pages(win)
    pager.show(win, starts[#starts])
    local cover = pager.cover_of(win)
    truthy(cover, "the page has a cover")
    local ns = vim.api.nvim_create_namespace("weread.pager")
    local function stamped()
      for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(vim.api.nvim_win_get_buf(cover), ns, 0, -1, { details = true })) do
        for _, chunk in ipairs(mark[4].virt_text or {}) do
          if chunk[1]:find("【", 1, true) or chunk[1]:find("〔", 1, true) then
            return true
          end
        end
      end
      return false
    end
    truthy(stamped(), "the last page is stamped")
    pager.show(win, starts[1])
    falsy(stamped(), "an earlier page is not")
    fx._force = false
    pager.prune()
    vim.api.nvim_win_set_buf(win, vim.api.nvim_create_buf(true, true))
    pager.prune()
    vim.api.nvim_buf_delete(buf, { force = true })
  end)

  it("makes a card from the book, the journal and my highlights, and saves it", function()
    local store = require("weread.annotations_store")
    store.add_local("C1", "0001", "10-20", "我们都是焦油坑里的巨兽")
    journal.opened("C1", "人月神话")
    local lines, _, kinds = milestone.card({ book_id = "C1", title = "人月神话", author = "布鲁克斯" }, 44)
    local text = table.concat(lines, "\n")
    matches(text, "《人月神话》")
    matches(text, "划了 1 条线")
    matches(text, "焦油坑里的巨兽")
    for _, line in ipairs(lines) do
      truthy(vim.api.nvim_strwidth(line) <= 44, "fits: " .. line)
    end
    local path = milestone.save_card({ book_id = "C1", title = "人月神话" }, lines, kinds)
    truthy(path)
    local saved = table.concat(vim.fn.readfile(path), "\n")
    matches(saved, "# 《人月神话》")
    matches(saved, "> 「我们都是")
    falsy(saved:find("s 存成", 1, true), "the key hint is not saved")
  end)

  it("shows the card once per book when the last page is passed", function()
    local reader = require("weread.reader")
    local saved_book = reader.state.book
    reader.state.book = { book_id = "C2", title = "测试" }
    fx._force = true
    local first = milestone.trophy()
    truthy(first, "the card opens")
    first:close()
    eq(milestone.trophy(), nil, "and not again")
    local again = milestone.trophy({ force = true })
    truthy(again, ":WeReadTrophy shows it on request")
    again:close()
    fx._force = false
    reader.state.book = saved_book
  end)
end)

describe("journal shared by two editors", function()
  it("adds both editors' minutes and keeps a book either one finished", function()
    journal._reset()
    vim.fn.delete(config.path("journal.json"))
    journal._reset()
    local day = os.time({ year = 2026, month = 10, day = 20, hour = 12 })
    journal.add(100, day)
    truthy(journal.save())
    -- another editor writes behind our back (另一个编辑器在背后写了文件)
    local cache = require("weread.cache")
    local disk = cache.read_json(config.path("journal.json"))
    disk.days["2026-10-20"] = disk.days["2026-10-20"] + 50
    disk.books.OTHER = { first = "2026-10-01", finished = "2026-10-19", chapters = 9 }
    cache.write_json(config.path("journal.json"), disk)
    journal.add(30, day)
    truthy(journal.save())
    eq(journal.seconds("2026-10-20"), 180, "100 + 50 from the other editor + 30")
    eq(journal.book("OTHER").finished, "2026-10-19", "their finished book survives")
  end)
end)

describe("zone and milestone review fixes", function()
  it("does not swallow a key for a scene that ended on its first frame", function()
    local buf = chapter_buffer({ "", "" })
    fx._force = true
    zone.play("rain")
    vim.wait(30)
    falsy(zone.playing(), "an empty page has nothing to rain")
    fx._force = false
    vim.api.nvim_buf_delete(buf, { force = true })
  end)

  it("lights the idle fire once per absence", function()
    local timer = require("weread.timer")
    local every = timer.every
    local tick
    timer.every = function(fn)
      tick = fn
      return nil
    end
    config.get().animations.idle_minutes = 1
    zone.watch_idle()
    timer.every = every
    local state = require("weread.progress_state")
    local saved_input = state.last_input
    state.last_input = vim.uv.now() - 5 * 60 * 1000
    local buf = chapter_buffer({ "　　正文" })
    fx._force = true
    tick()
    truthy(zone.playing(), "lit")
    zone.stop()
    tick()
    falsy(zone.playing(), "burned out at its cap: not lit again until the reader is back")
    state.last_input = vim.uv.now() - 2 * 60 * 1000
    tick()
    truthy(zone.playing(), "a new absence lights it again")
    zone.stop()
    fx._force = false
    state.last_input = saved_input
    config.get().animations.idle_minutes = nil
    zone.watch_idle()
    vim.api.nvim_buf_delete(buf, { force = true })
  end)

  it("draws the stamp over the progress bar", function()
    local pager = require("weread.pager")
    local lines = {}
    for i = 1, 120 do
      lines[i] = "　　正文" .. i
    end
    local buf = chapter_buffer(lines)
    local win = vim.api.nvim_get_current_win()
    fx._force = true
    local starts = pager.pages(win)
    pager.show(win, starts[#starts])
    local cover = vim.api.nvim_win_get_buf(pager.cover_of(win))
    local ns = vim.api.nvim_create_namespace("weread.pager")
    local stamp_priority, bar_priority
    for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(cover, ns, 0, -1, { details = true })) do
      local first = ((mark[4].virt_text or {})[1] or {})[1] or ""
      if first:find("【", 1, true) or first:find("〔", 1, true) then
        stamp_priority = mark[4].priority
      elseif first:find("[⣀⡀⡇⣇▀]") then
        bar_priority = mark[4].priority
      end
    end
    fx._force = false
    truthy(stamp_priority and bar_priority, "both drawn")
    truthy(stamp_priority > bar_priority, "the stamp is on top")
    pager.prune()
    vim.api.nvim_win_set_buf(win, vim.api.nvim_create_buf(true, true))
    pager.prune()
    vim.api.nvim_buf_delete(buf, { force = true })
  end)

  it("hands the plant and card groups back to the colorscheme under none", function()
    local theme = require("weread.theme")
    theme.define("jade")
    theme.define_heading("none")
    eq(vim.api.nvim_get_hl(0, { name = "WereadPaperWinBar" }).link, "WinBar")
    eq(vim.api.nvim_get_hl(0, { name = "WereadPaperFloat" }).link, "NormalFloat")
    theme.redefine()
  end)

  it("shows the card only for the book the end was reached in", function()
    local reader = require("weread.reader")
    local saved = reader.state.book
    reader.state.book = { book_id = "OPEN" }
    fx._force = true
    eq(milestone.trophy({ book_id = "OTHER" }), nil, "another book's end is not this one's")
    fx._force = false
    reader.state.book = saved
  end)

  it("shows the card again when a serial book grew and was finished again", function()
    local reader = require("weread.reader")
    local saved_book, saved_catalog = reader.state.book, reader.state.catalog
    reader.state.book = { book_id = "SERIAL", title = "连载" }
    reader.state.catalog = { chapters = { {}, {} } }
    fx._force = true
    local first = milestone.trophy()
    truthy(first)
    first:close()
    eq(milestone.trophy(), nil, "same catalog: once")
    reader.state.catalog = { chapters = { {}, {}, {} } }
    local again = milestone.trophy()
    truthy(again, "new chapters, finished again")
    again:close()
    fx._force = false
    reader.state.book, reader.state.catalog = saved_book, saved_catalog
  end)

  it("counts a synced highlight once, and not a thought on someone else's", function()
    local cache = require("weread.cache")
    local store = require("weread.annotations_store")
    vim.fn.mkdir(cache.annotations_dir("H1"), "p")
    cache.write_json(cache.annotations_dir("H1") .. "/0001.json", {
      { range = "1-9", text = "他走进了房间", mine = true },
      { range = "20-30", text = "别人的热门划线", mine = false, popular = true },
    })
    store.add_local("H1", "0001", "1-9", "他走进了 房间")
    local local_store = store.local_store("H1")
    local_store["0001"][#local_store["0001"] + 1] = { range = "20-30", text = "别人的热门划线", local_only = true }
    store.save_local("H1", local_store)
    eq(milestone.my_highlights("H1"), { "他走进了房间" })
  end)
end)
