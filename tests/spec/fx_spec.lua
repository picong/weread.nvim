--[[
Tests for weread.fx and its effects: the frame loop, the switches that keep
effects off, and that no effect ever writes into a chapter or outlives a key.
(fx 及其效果的单测：帧循环、让效果保持关闭的开关，以及任何效果都不会写进章节、不会在按键之后继续)
]]

local fx = require("weread.fx")
local effects = require("weread.fx_effects")
local config = require("weread.config")

local tmpdir = "/tmp/weread-test-fx"
vim.fn.delete(tmpdir, "rf")
vim.fn.mkdir(tmpdir, "p")
config.setup({ data_dir = tmpdir })

---Play effects in this spec as if a UI were attached, one frame per call.
---(本 spec 里假装有界面，并同步逐帧播放)
local function forced(fn)
  fx._force, fx._sync = true, true
  local ok, err = pcall(fn)
  fx._force, fx._sync = false, false
  fx.stop_all()
  if not ok then
    error(err, 0)
  end
end

local function chapter_buffer(lines)
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.b[buf].weread = { book_id = "1", chapter_key = "0001", chapter_index = 1, chapter_uid = "1" }
  vim.bo[buf].modifiable = false
  vim.api.nvim_win_set_buf(0, buf)
  return buf
end

describe("fx switches", function()
  it("stays off without a UI", function()
    falsy(fx.enabled(), "headless: nothing plays")
    eq(effects.loading(vim.api.nvim_get_current_win()), nil)
  end)

  it("honours the config and the global switches", function()
    fx._force = true
    truthy(fx.enabled("loading"))
    falsy(fx.enabled("bookworm"), "the worm is opt-in")
    config.get().animations.loading = false
    falsy(fx.enabled("loading"))
    config.get().animations.loading = true
    vim.g.weread_animations = false
    falsy(fx.enabled("loading"))
    vim.g.weread_animations = nil
    vim.g.snacks_animate = false
    falsy(fx.enabled("loading"), "snacks' switch is respected")
    vim.g.snacks_animate = nil
    config.get().animations.enabled = false
    falsy(fx.enabled())
    config.get().animations.enabled = true
    fx._force = false
  end)
end)

describe("fx frame loop", function()
  it("plays every frame and cleans up", function()
    forced(function()
      local seen, cleaned = {}, false
      fx.play({
        frames = 4,
        draw = function(i)
          seen[#seen + 1] = i
        end,
        cleanup = function()
          cleaned = true
        end,
      })
      eq(seen, { 1, 2, 3, 4 })
      truthy(cleaned)
      eq(fx.count(), 0, "nothing left playing")
    end)
  end)

  it("ends early when a frame says so, or fails", function()
    forced(function()
      local frames = 0
      fx.play({
        frames = 10,
        draw = function(i)
          frames = i
          return i < 3
        end,
      })
      eq(frames, 3)
      local cleaned = false
      fx.play({
        frames = 10,
        draw = function()
          error("boom")
        end,
        cleanup = function()
          cleaned = true
        end,
      })
      truthy(cleaned, "a failing frame still cleans up")
    end)
  end)

  it("stops on any key, except effects that ignore keys", function()
    fx._force = true
    local stopped = {}
    local a = fx.play({ draw = function() end, cleanup = function()
      stopped.a = true
    end })
    local b = fx.play({ stop_on_key = false, draw = function() end, cleanup = function()
      stopped.b = true
    end })
    eq(fx.count(), 2)
    fx.stop_all({ keyed = true })
    truthy(stopped.a, "a key stops it")
    falsy(stopped.b, "the loading book keeps going while the old page is read")
    fx.stop(b)
    truthy(stopped.b)
    fx.stop(a)
    eq(fx.count(), 0)
    fx._force = false
  end)

  it("stops through a real key press", function()
    fx._force = true
    local stopped = false
    fx.play({ draw = function() end, cleanup = function()
      stopped = true
    end })
    vim.api.nvim_feedkeys(vim.keycode("<Ignore>"), "xt", false)
    vim.wait(200, function()
      return stopped
    end)
    truthy(stopped, "on_key stopped it")
    fx._force = false
  end)

  it("never runs past max_ms", function()
    forced(function()
      local frames = 0
      fx.play({ interval = 100, max_ms = 500, draw = function(i)
        frames = i
      end })
      eq(frames, 5)
    end)
  end)
end)

describe("fx pixels", function()
  it("pairs rows into half blocks with a top and a bottom colour", function()
    local lines, marks = fx.pixels({ "a.", ".a" }, { a = "#112233" }, "#ffffff")
    eq(#lines, 1)
    eq(lines[1], "▀▀")
    local first = vim.api.nvim_get_hl(0, { name = marks[1].group })
    eq(first.fg, 0x112233, "top pixel is the foreground")
    eq(first.bg, 0xffffff, "bottom pixel is the background")
    local second = vim.api.nvim_get_hl(0, { name = marks[2].group })
    eq(second.fg, 0xffffff)
    eq(second.bg, 0x112233)
  end)

  it("leaves blank paper as spaces", function()
    local lines = fx.pixels({ "..", ".." }, {}, "#ffffff")
    eq(lines[1], "  ")
  end)

  it("draws the book with a leaf moving across the spine", function()
    local frames = {}
    for pose = 1, 4 do
      frames[pose] = table.concat(effects.book_frame(pose), "\n")
    end
    falsy(frames[1]:find("f"), "the first pose has no leaf in the air")
    truthy(frames[2]:find("f") and frames[3]:find("f") and frames[4]:find("f"))
    truthy(frames[2] ~= frames[3] and frames[3] ~= frames[4], "the leaf moves")
    eq(#effects.book_frame(1), 8, "eight pixel rows, four lines")
  end)

  it("cuts a swallowtail into the end of the ribbon", function()
    local grid = effects.ribbon_grid(5)
    eq(grid[4], "rrr")
    eq(grid[5], "r.r")
    eq(grid[6], "...")
  end)
end)

describe("fx effects on a chapter", function()
  it("plays the loading book in a float of its own and closes it", function()
    -- the loading book has no frame count, so it runs on the real clock here
    -- (加载书本没有帧数上限，所以这里用真实时钟播放)
    local saved_delay = effects.LOADING_DELAY
    effects.LOADING_DELAY = 0
    fx._force = true
    local ok, err = pcall(function()
      local buf = chapter_buffer({ "　　正文" })
      local before = #vim.api.nvim_list_wins()
      local floats = {}
      local open = vim.api.nvim_open_win
      vim.api.nvim_open_win = function(b, enter, cfg)
        local win = open(b, enter, cfg)
        floats[#floats + 1] = { win = win, cfg = cfg, enter = enter }
        return win
      end
      local handle = effects.loading(vim.api.nvim_get_current_win(), "测试")
      vim.api.nvim_open_win = open
      truthy(handle)
      eq(#floats, 1)
      falsy(floats[1].enter, "never takes the focus")
      eq(floats[1].cfg.focusable, false)
      eq(floats[1].cfg.noautocmd, true)
      local text = table.concat(vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(floats[1].win), 0, -1, false), "\n")
      truthy(text:find("▀", 1, true), "pixels drawn")
      truthy(text:find("测试", 1, true), "with the label")
      fx.stop(handle)
      eq(#vim.api.nvim_list_wins(), before, "the float is gone")
      eq(vim.api.nvim_buf_get_lines(buf, 0, -1, false), { "　　正文" }, "the chapter is untouched")
      vim.api.nvim_buf_delete(buf, { force = true })
    end)
    fx._force = false
    effects.LOADING_DELAY = saved_delay
    fx.stop_all()
    if not ok then
      error(err, 0)
    end
  end)

  it("spreads ink over a passage and clears it, without touching the text", function()
    forced(function()
      local buf = chapter_buffer({ "　　过去几十年的大型系统开发", "就犹如这样一个焦油坑" })
      local ns = vim.api.nvim_create_namespace("weread.fx.ink")
      local seen = 0
      local set = vim.api.nvim_buf_set_extmark
      vim.api.nvim_buf_set_extmark = function(b, n, row, col, opts)
        if n == ns then
          seen = seen + 1
          eq(opts.virt_lines, nil, "no virtual lines: pages would change")
          eq(opts.virt_text, nil)
        end
        return set(b, n, row, col, opts)
      end
      effects.ink(buf, { 1, 6 }, { 2, 9 })
      vim.api.nvim_buf_set_extmark = set
      truthy(seen > 0, "ink was drawn")
      eq(#vim.api.nvim_buf_get_extmarks(buf, ns, 0, -1, {}), 0, "and cleared at the end")
      eq(vim.bo[buf].modifiable, false)
      vim.api.nvim_buf_delete(buf, { force = true })
    end)
  end)

  it("lists the characters a passage covers, whitespace left out", function()
    local buf = chapter_buffer({ "ab cd", "ef" })
    local chars = effects.passage_chars(buf, { 1, 1 }, { 2, 1 })
    local picked = {}
    for _, c in ipairs(chars) do
      picked[#picked + 1] = vim.api.nvim_buf_get_text(buf, c[1], c[2], c[1], c[3], {})[1]
    end
    eq(picked, { "b", "c", "d", "e" })
    vim.api.nvim_buf_delete(buf, { force = true })
  end)

  it("drops the ribbon and takes it away again", function()
    forced(function()
      local buf = chapter_buffer({ "　　正文" })
      local before = #vim.api.nvim_list_wins()
      local handle = effects.ribbon(vim.api.nvim_get_current_win(), true)
      truthy(handle)
      eq(#vim.api.nvim_list_wins(), before, "gone once it played")
      vim.api.nvim_buf_delete(buf, { force = true })
    end)
  end)
end)

describe("fx events", function()
  it("announces page turns as User autocommands", function()
    local got = nil
    local id = vim.api.nvim_create_autocmd("User", {
      pattern = "WereadPageTurn",
      callback = function(args)
        got = args.data
      end,
    })
    fx.emit("WereadPageTurn", { forward = true })
    vim.api.nvim_del_autocmd(id)
    eq(got and got.forward, true)
  end)
end)

describe("folio progress bar", function()
  local shell = require("weread.shell")

  it("fills dots in half cells and raises chapter ticks", function()
    local empty = shell.progress_cells(8, 0, nil)
    eq(#empty, 8)
    eq(empty[1][1], "⣀")
    eq(empty[1][2], "WereadPaperBarTodo")
    local half = shell.progress_cells(8, 1 / 16, nil)
    eq(half[1][1], "⡀", "half a cell is one dot")
    eq(half[1][2], "WereadPaperBarDone")
    local full = shell.progress_cells(8, 1, nil)
    eq(full[8][2], "WereadPaperBarDone")
    local ticked = shell.progress_cells(9, 0, { 0.5 })
    eq(ticked[5][1], "⡇", "a tick at the middle")
    eq(ticked[5][2], "WereadPaperBarTick")
    local crowded = shell.progress_cells(6, 0, { 0.1, 0.2, 0.3, 0.4, 0.5 })
    for _, cell in ipairs(crowded) do
      eq(cell[1], "⣀", "too many ticks to tell apart: none")
    end
  end)

  it("measures the book by words and finds top level chapter starts", function()
    local reader = require("weread.reader")
    local saved = reader.state.catalog
    reader.state.catalog = {
      chapters = {
        { level = 1, wordCount = 100 },
        { level = 2, wordCount = 100 },
        { level = 1, wordCount = 200 },
      },
    }
    eq(shell.book_fraction(3, 0), 0.5)
    eq(shell.book_fraction(2, 0.5), 0.375)
    eq(shell.chapter_ticks(), { 0.5 }, "only the second top level chapter")
    reader.state.catalog = saved
  end)
end)

describe("fx review fixes", function()
  it("lets a key start a new effect while an old one is stopped", function()
    fx._force = true
    local stopped = {}
    fx.play({ draw = function() end, cleanup = function()
      stopped.old = true
    end })
    vim.keymap.set("n", "<F13>", function()
      fx.play({ draw = function() end, cleanup = function()
        stopped.new = true
      end })
    end)
    vim.api.nvim_feedkeys(vim.keycode("<F13>"), "xt", false)
    vim.wait(100, function()
      return stopped.old
    end)
    truthy(stopped.old, "the effect playing when the key came stops")
    falsy(stopped.new, "the one the key started keeps playing")
    fx.stop_all()
    vim.keymap.del("n", "<F13>")
    fx._force = false
  end)

  it("redefines a pixel group a colorscheme wiped", function()
    local group = fx.pixel_group("#123456", "#654321")
    vim.cmd("highlight clear")
    eq(next(vim.api.nvim_get_hl(0, { name = group })), nil)
    eq(fx.pixel_group("#123456", "#654321"), group)
    eq(vim.api.nvim_get_hl(0, { name = group }).fg, 0x123456, "set again")
    require("weread.theme").redefine()
  end)

  it("answers the waiters of a fetch a refresh replaced", function()
    local pipeline = require("weread.chapter_pipeline")
    local content = require("weread.content")
    local session = require("weread.session")
    local saved_state, saved_fresh = content.fetch_reader_state, pipeline.chapter_cache_is_fresh
    local pending = {}
    content.fetch_reader_state = function(_, _, callback)
      pending[#pending + 1] = callback
    end
    local book = { book_id = "PIPE" }
    local chapter = { chapterUid = 7, chapterIdx = 7, title = "x" }
    local answered = 0
    pipeline.ensure_cached(book, chapter, function()
      answered = answered + 1
    end)
    -- a refresh drops the in-flight entry and asks again (刷新丢掉在路上的条目，再问一次)
    session.state.inflight["PIPE:" .. require("weread.cache").chapter_key(chapter)] = nil
    pipeline.ensure_cached(book, chapter, function()
      answered = answered + 1
    end)
    eq(#pending, 2)
    pending[1](false, "boom")
    pending[2](false, "boom")
    eq(answered, 2, "both reloads heard back")
    content.fetch_reader_state, pipeline.chapter_cache_is_fresh = saved_state, saved_fresh
  end)
end)
