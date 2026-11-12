--[[
Tests for weread.decorations: what other markdown decoration plugins may draw on a
reading buffer.
(decorations 单测：其它 markdown 装饰插件可以在阅读 buffer 上画什么)

render-markdown.nvim draws a full width border, a background band and an icon on
every heading — on a white page that is a black box around the heading — so it is
kept away by chaining the reading buffer into its `ignore(buf)`. Two of the things
it draws are wanted, though, and markdown cannot express either by itself: pipe
tables and fenced code blocks. Those are drawn on request, with a buffer-local
config that switches everything else off.
(render-markdown.nvim 会给每个标题画整行边框、底色带和图标——在纯白页面上就是标题外面套了个
 黑框——因此把阅读 buffer 接进它的 `ignore(buf)` 把它挡在外面。但它画的两样东西是想要的，而且
 markdown 自己表达不了：管道表格与围栏代码块。这两样按需绘制，用的是其余全关的 buffer 级配置)
]]

local config = require("weread.config")
config.setup({ data_dir = vim.fn.tempname() })

local decorations = require("weread.decorations")

---Install a stand-in for render-markdown's shared state.
---(装一个 render-markdown 共享状态的替身)
---@param ignore fun(buf: integer): boolean|nil the user's own ignore(用户自己的 ignore)
---@return table state
local function fake_render_markdown(ignore, setup)
  local module = {
    ignore = ignore,
    configs = {},
    rendered = {},
  }
  -- `state.config` is what the plugin's own setup() writes; the reader's seeding
  -- is a no-op until it exists, so `nil` models a plugin that is not set up yet.
  -- (`state.config` 是插件自己 setup() 写入的；在它存在之前阅读器的种配置是空操作，因此用
  --  nil 表示「插件还没 setup」)
  if setup ~= false then
    module.config = {}
  end
  ---stand-in for `state.get(buf, config)`: remembers what was seeded
  ---(state.get(buf, config) 的替身：记住被种下的配置)
  function module.get(buf, config)
    module.configs[buf] = config or module.configs[buf] or {}
    return module.configs[buf]
  end
  package.loaded["render-markdown.state"] = module
  package.loaded["render-markdown.api"] = {
    render = function(ctx)
      module.rendered[#module.rendered + 1] = ctx
      return true
    end,
  }
  return module
end

describe("weread.decorations", function()
  it("chains the reading buffer into render-markdown's own ignore", function()
    local state = fake_render_markdown(nil)
    local chapter = vim.api.nvim_create_buf(false, true)
    local other = vim.api.nvim_create_buf(false, true)
    vim.b[chapter].weread_book = true

    eq(decorations.guard(), true, "the guard was installed")
    eq(state.ignore(chapter), true, "a chapter buffer is skipped")
    eq(state.ignore(other), false, "and nothing else is")
    eq(decorations.guard(), false, "installing it twice does nothing")
    vim.api.nvim_buf_delete(chapter, { force = true })
    vim.api.nvim_buf_delete(other, { force = true })
  end)

  it("still honours the user's own ignore", function()
    local asked = {}
    local state = fake_render_markdown(function(buf)
      asked[#asked + 1] = buf
      return false
    end)
    local chapter = vim.api.nvim_create_buf(false, true)
    local other = vim.api.nvim_create_buf(false, true)
    vim.b[chapter].weread_book = true

    decorations.guard()
    eq(state.ignore(chapter), true, "the chapter is skipped")
    eq(state.ignore(other), false, "the user's answer survives")
    eq(#asked, 1, "and the user's function was asked exactly once")
    vim.api.nvim_buf_delete(chapter, { force = true })
    vim.api.nvim_buf_delete(other, { force = true })
  end)

  it("recognises a chapter buffer before the image module marked it", function()
    -- The buffer variable is set by another module, and decoration plugins can ask
    -- before it lands: the reader itself is then the source of truth.
    -- (那个 buffer 变量由别的模块设置，而装饰插件可能在它落地之前就问：此时以阅读器为准)
    local state = fake_render_markdown(nil)
    local buf = vim.api.nvim_create_buf(false, true)
    vim.bo[buf].filetype = "markdown"
    vim.b[buf].weread = { book_id = "1", chapter_key = "0001" }
    eq(decorations.reading(buf), true, "the reader marker is enough")
    decorations.guard()
    eq(state.ignore(buf), true, "so it is skipped too")
    vim.b[buf].weread = nil
    eq(decorations.reading(buf), false, "and an ordinary markdown buffer is not")
    vim.api.nvim_buf_delete(buf, { force = true })
  end)

  it("hands render-markdown a config that draws the page's markdown", function()
    -- The chapter is standard markdown, so headings, bullets, quotes and rules are
    -- drawn the way the plugin draws any markdown file; the borders above and
    -- below a heading and the indent guides stay off, and the heading icon is
    -- the page's own.
    -- (章节是标准 markdown，因此标题、列表、引文、分隔线都像插件画任何 markdown 文件那样画出；
    --  标题上下的边框与缩进参考线仍然关闭，标题图标由书页自己画)
    local state = fake_render_markdown(nil)
    local buf = vim.api.nvim_create_buf(false, true)
    eq(decorations.prettify(buf), true, "the config was seeded")

    local config = state.configs[buf]
    eq(config.heading.enabled, true, "headings get their band")
    eq(config.heading.border, false, "but no border above and below")
    eq(#config.heading.icons, 0, "and no icon of the plugin's: the page draws it")
    eq(config.heading.sign, false)
    eq(config.bullet.enabled, true, "bullets are drawn")
    eq(config.quote.enabled, true, "quotes get their bar")
    eq(config.dash.enabled, true, "rules are drawn")
    eq(config.dash.width({ width = 300 }) <= 300, true, "no wider than the window")
    eq(config.indent.enabled, false, "no indent guides")
    eq(config.sign.enabled, false, "no signs")
    eq(config.pipe_table.enabled, true, "tables are drawn")
    eq(config.pipe_table.wrap, true, "and their cells fold to the window")
    eq(config.pipe_table.border_enabled, false, "without virtual top and bottom rules")
    eq(config.pipe_table.head, "WereadPaperTableHead", "in the reading palette")
    eq(config.pipe_table.row, "WereadPaperTableRow", "for both parts of a table")
    eq(config.code.enabled, true, "code blocks are drawn")
    eq(config.code.disable_background, true, "with syntax highlighting showing through")
    -- the language *is* named, but by the page (`weread.inline`): the plugin puts
    -- its name on the empty line above the fence, and an overlay virt_text is not
    -- drawn on an empty line
    -- (语言确实会写出来，但由书页自己写（`weread.inline`）：插件把名字放在围栏上方的空行上，
    --  而 overlay 类虚拟文本在空行上不会被绘制)
    eq(config.code.language, false, "the plugin's own label is off")
    eq(config.code.border, "none", "and so is its border, which is drawn on empty lines too")

    -- presets are expanded by the plugin for the *global* config only, so a
    -- buffer-local config has to carry the expanded keys itself
    -- (预设只由插件为**全局**配置展开，因此 buffer 级配置必须自己带上展开后的键)
    eq(config.pipe_table.style, nil, "no style preset name that would be ignored")
    eq(config.code.style, nil, "for either of them")

    vim.api.nvim_buf_delete(buf, { force = true })
  end)

  it("draws a chapter on request, not on its own", function()
    -- Attaching is what the guard prevents in chapter buffers, and attaching is
    -- also what registers the plugin's update autocmds; so the drawing is asked
    -- for explicitly, which is also what lets a resize re-fold a table.
    -- (守卫在章节 buffer 里阻止的正是 attach，而 attach 同时也是插件注册更新自动命令的时刻；
    --  因此绘制是显式请求的，这也让窗口尺寸变化后能重折表格)
    local state = fake_render_markdown(nil)
    local buf = vim.api.nvim_create_buf(true, false)
    vim.api.nvim_set_current_buf(buf)
    local win = vim.api.nvim_get_current_win()
    eq(decorations.render(buf, win), true, "the page was drawn")
    eq(#state.rendered, 1, "once")
    eq(state.rendered[1].buf, buf, "for this buffer")
    eq(state.rendered[1].win, win, "and this window")
    vim.api.nvim_buf_delete(buf, { force = true })
  end)

  it("draws through the plugin's own updater, past its debounce", function()
    -- `api.render` only schedules a render, and the plugin's debounce drops every
    -- request inside its window; a page turn's burst of resizes lost the one that
    -- mattered, and the table stayed raw `| cell |` text.
    -- (`api.render` 只是排期，插件的防抖会丢掉窗口期内的每个请求；翻页连发的 resize 把真正
    --  要紧的那次弄丢了，表格就停在 `| 格 |` 原文)
    local state = fake_render_markdown(nil)
    state.attach = function() end
    local buf = vim.api.nvim_create_buf(true, false)
    vim.api.nvim_set_current_buf(buf)
    local win = vim.api.nvim_get_current_win()
    local runs = {}
    package.loaded["render-markdown.core.ui"] = {
      updater = {
        new = function(target, window, force)
          return {
            run = function()
              runs[#runs + 1] = { target, window, force }
            end,
          }
        end,
      },
    }

    eq(decorations.render(buf, win), true)
    eq(#runs, 1, "drawn right away")
    eq(runs[1][1], buf)
    eq(runs[1][2], win)
    eq(runs[1][3], true, "forced, so the marks are parsed again")
    eq(#state.rendered, 0, "the debounced api was not needed")

    package.loaded["render-markdown.core.ui"] = nil
    vim.api.nvim_buf_delete(buf, { force = true })
  end)

  it("draws what scrolls into view, without forcing a parse", function()
    -- the plugin only lays out the rows on screen, and its own scroll autocmds
    -- are never registered in a chapter buffer
    -- (插件只排屏幕上的行，而章节 buffer 里它自己的滚动自动命令从未注册)
    local state = fake_render_markdown(nil)
    state.cache = {}
    local buf = vim.api.nvim_create_buf(true, false)
    vim.api.nvim_set_current_buf(buf)
    local win = vim.api.nvim_get_current_win()
    local runs = {}
    package.loaded["render-markdown.core.ui"] = {
      updater = {
        new = function(target, window, force)
          return {
            run = function()
              runs[#runs + 1] = { target, window, force }
            end,
          }
        end,
      },
    }

    eq(decorations.follow(buf, win), false, "a buffer the plugin never drew is left to render")
    state.cache[buf] = {}
    eq(decorations.follow(buf, win), true)
    eq(#runs, 1)
    eq(runs[1][3], false, "the plugin decides whether the view needs a parse")

    package.loaded["render-markdown.core.ui"] = nil
    vim.api.nvim_buf_delete(buf, { force = true })
  end)

  it("keeps a wrapped table row drawn under the cursor in a chapter only", function()
    -- the pager keeps the cursor on the page's top line, and the plugin drops a
    -- row's replacement whenever the cursor is on it
    -- (分页器把光标放在页面顶行，而插件只要光标在某行就撤掉那一行的替换)
    local chapter = vim.api.nvim_create_buf(false, true)
    local other = vim.api.nvim_create_buf(false, true)
    vim.b[chapter].weread_book = true
    local seen = {}
    local updater = {
      hide = function(self, extmark)
        local mark = extmark:get()
        seen[#seen + 1] = mark.replace ~= nil
        return mark.replace ~= nil
      end,
    }
    package.loaded["render-markdown.core.ui"] = { updater = updater }
    local mark = { replace = { "row" } }
    local extmark = {
      get = function()
        return mark
      end,
    }

    eq(decorations.keep_rows(), true)
    eq(decorations.keep_rows(), false, "patched once")
    eq(updater.hide({ buf = chapter }, extmark, nil), false, "a chapter keeps the row drawn")
    eq(mark.replace[1], "row", "and the mark is left as it was")
    eq(updater.hide({ buf = other }, extmark, nil), true, "any other buffer is untouched")

    package.loaded["render-markdown.core.ui"] = nil
    vim.api.nvim_buf_delete(chapter, { force = true })
    vim.api.nvim_buf_delete(other, { force = true })
  end)

  it("waits for render-markdown to be set up before seeding", function()
    -- LazyVim loads the plugin on `FileType markdown`, and the reader seeds before
    -- the file is even read: on a cold start there is nothing to seed into, and
    -- saying so is better than erroring inside the plugin.
    -- (LazyVim 在 `FileType markdown` 时才加载插件，而阅读器在文件被读入之前就种配置：冷启动时
    --  还没有可种的地方，这时如实返回失败，好过在插件里出错)
    local state = fake_render_markdown(nil, false)
    local buf = vim.api.nvim_create_buf(false, true)
    eq(decorations.prettify(buf), false, "not seeded before setup")
    eq(state.configs[buf], nil, "and nothing was cached")

    -- once it is set up, the same call seeds the config
    -- (它 setup 之后，同一个调用就会种下配置)
    state.config = {}
    eq(decorations.prettify(buf), true, "seeded after setup")
    eq(state.configs[buf].heading.border, false, "with the same config as before")
    vim.api.nvim_buf_delete(buf, { force = true })
  end)

  it("waits until the page margin shows up in the window width", function()
    -- The margin is a `statuscolumn`, and nvim only counts it into the window's
    -- text width once the screen is redrawn. A table folds its cells into that
    -- width, so drawing too early lays the table out for a window 29 columns
    -- wider than the page and the last columns fall off the right edge.
    -- (边距是一个 `statuscolumn`，而 nvim 要等屏幕重绘后才把它算进窗口文本宽度。表格正是按那个
    --  宽度折单元格的，画得太早会按比版心宽 29 列的窗口排版，最后几列会掉出右边界)
    fake_render_markdown(nil)
    local buf = vim.api.nvim_create_buf(true, false)
    vim.api.nvim_set_current_buf(buf)
    vim.b[buf].weread_book = true
    local win = vim.api.nvim_get_current_win()
    local saved = vim.wo[win].statuscolumn
    vim.wo[win].statuscolumn = "%#WereadMargin#" .. string.rep(" ", 29)

    eq(vim.fn.getwininfo(win)[1].textoff, 0, "the width is not there yet in a headless window")
    eq(decorations.render(buf, win), false, "so nothing is drawn")
    eq(decorations.retries(buf, win).width, 1, "and a retry is queued instead")

    -- a buffer that is not a reading buffer is never held back
    -- (不是阅读 buffer 就不会被拦住)
    vim.b[buf].weread_book = nil
    eq(decorations.render(buf, win), true, "an ordinary buffer draws straight away")
    eq(decorations.retries(buf, win).width, 0, "and the new request starts from zero")
    vim.wo[win].statuscolumn = saved
    vim.api.nvim_buf_delete(buf, { force = true })
  end)

  describe("retries while waiting", function()
    ---Replace `vim.defer_fn` with a queue the test runs by hand.
    ---(把 vim.defer_fn 换成由测试手动触发的队列)
    ---@return { total: integer, pending: function[] } queue
    ---@return fun() restore
    local function hold_timers()
      local queue = { total = 0, pending = {} }
      local original = vim.defer_fn
      vim.defer_fn = function(fn)
        queue.total = queue.total + 1
        queue.pending[#queue.pending + 1] = fn
      end
      return queue, function()
        vim.defer_fn = original
      end
    end

    ---Run every timer that is due, including the ones they arm in turn.
    ---(跑完所有到点的定时器，包括它们接着设下的)
    ---@param queue table
    local function drain(queue)
      while #queue.pending > 0 do
        table.remove(queue.pending, 1)()
      end
    end

    ---@param fn fun(queue: table)
    local function with_timers(fn)
      local queue, restore = hold_timers()
      local ok, err = pcall(fn, queue)
      restore()
      if not ok then
        error(err, 0)
      end
    end

    it("gives up after a bounded number of tries, and a new request starts over", function()
      fake_render_markdown(nil, false)
      local buf = vim.api.nvim_create_buf(false, true)
      with_timers(function(queue)
        eq(decorations.render(buf, nil), false)
        drain(queue)
        eq(queue.total, 8, "the cold start waits eight times")
        eq(decorations.retries(buf).render, 8)

        -- Used to be a module-wide counter: once it ran out, every later render
        -- gave up at once, whatever the buffer.
        -- (过去是模块级计数：用光之后，不管哪个 buffer，之后的渲染都立刻放弃)
        eq(decorations.render(buf, nil), false)
        eq(queue.total, 9, "a later render waits again")
        eq(decorations.retries(buf).render, 1, "with its own count")
        drain(queue)
        eq(queue.total, 16, "and gets the full allowance")
      end)
      vim.api.nvim_buf_delete(buf, { force = true })
    end)

    it("counts per buffer: one running out leaves the other alone", function()
      fake_render_markdown(nil, false)
      local first = vim.api.nvim_create_buf(false, true)
      local second = vim.api.nvim_create_buf(false, true)
      with_timers(function(queue)
        decorations.render(first, nil)
        drain(queue)
        eq(decorations.retries(first).render, 8, "the first one used everything")
        decorations.render(second, nil)
        eq(decorations.retries(second).render, 1, "the second one starts with its own count")
        eq(#queue.pending, 1, "and still waits")
        drain(queue)
        eq(decorations.retries(second).render, 8)
      end)
      vim.api.nvim_buf_delete(first, { force = true })
      vim.api.nvim_buf_delete(second, { force = true })
    end)

    it("counts per window: two windows on a buffer do not share an allowance", function()
      fake_render_markdown(nil)
      local buf = vim.api.nvim_create_buf(true, false)
      vim.api.nvim_set_current_buf(buf)
      vim.b[buf].weread_book = true
      local first = vim.api.nvim_get_current_win()
      vim.cmd("split")
      local second = vim.api.nvim_get_current_win()
      vim.wo[first].statuscolumn = string.rep(" ", 29)
      vim.wo[second].statuscolumn = string.rep(" ", 29)
      with_timers(function(queue)
        decorations.render(buf, first)
        decorations.render(buf, second)
        eq(decorations.retries(buf, first).width, 1)
        eq(decorations.retries(buf, second).width, 1)
        truthy(decorations.retries(buf, first) ~= decorations.retries(buf, second), "separate requests")
        drain(queue)
        eq(queue.total, 24, "twelve tries each, not twelve between them")
        eq(decorations.retries(buf, first).width, 12)
        eq(decorations.retries(buf, second).width, 12)

        -- the margin shows up: the request that was waiting draws and resets
        -- (边距出现了：在等的那个请求会画出来并复位)
        vim.b[buf].weread_book = nil
        eq(decorations.render(buf, first), true)
        eq(decorations.retries(buf, first).width, 0)
      end)
      vim.api.nvim_win_close(second, true)
      vim.wo[first].statuscolumn = ""
      vim.api.nvim_buf_delete(buf, { force = true })
    end)

    it("stops a request that a newer render has replaced", function()
      fake_render_markdown(nil, false)
      local buf = vim.api.nvim_create_buf(false, true)
      with_timers(function(queue)
        decorations.render(buf, nil)
        local stale = queue.pending[1]
        decorations.render(buf, nil)
        eq(#queue.pending, 2, "both armed a timer")
        stale()
        eq(queue.total, 2, "the replaced one fires and arms nothing more")
        eq(decorations.retries(buf).render, 1, "and does not touch the newer count")
      end)
      vim.api.nvim_buf_delete(buf, { force = true })
    end)

    it("forgets a buffer's retries when it is wiped out", function()
      fake_render_markdown(nil, false)
      local buf = vim.api.nvim_create_buf(false, true)
      with_timers(function(queue)
        decorations.render(buf, nil)
        truthy(decorations.retries(buf), "tracked while the buffer lives")
        vim.api.nvim_buf_delete(buf, { force = true })
        eq(decorations.retries(buf), nil, "gone with the buffer")
        drain(queue)
        eq(queue.total, 1, "and the timer it left behind arms nothing")
      end)
    end)
  end)

  it("says so when render-markdown cannot draw", function()
    package.loaded["render-markdown.state"] = nil
    package.loaded["render-markdown.api"] = nil
    eq(decorations.available(), false, "the plugin is not there")
    eq(decorations.prettify(0), false, "so nothing is seeded")
    eq(decorations.render(0, nil), false, "and nothing is drawn")
  end)

  it("silences the decoration plugins that draw inside the page", function()
    -- Coloured indent guides down a book page are the most visible way a
    -- reading buffer stops looking like paper.
    -- (书页左边一道彩色缩进竖线，是阅读 buffer 最显眼的「不像纸」之处)
    local buf = vim.api.nvim_create_buf(false, true)
    eq(decorations.quiet(buf) >= 1, true, "the switches were set")
    eq(vim.b[buf].snacks_indent, false, "indent guides are off")
    eq(vim.b[buf].snacks_scroll, false, "and so is the scrollbar")
    eq(decorations.quiet(buf) >= 1, true, "running it again is harmless")
    vim.api.nvim_buf_delete(buf, { force = true })
  end)

  it("does nothing when render-markdown is not installed", function()
    package.loaded["render-markdown.state"] = nil
    eq(decorations.guard(), false)
    eq(decorations.applied(), false)
  end)
end)
