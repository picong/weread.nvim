--[[
Tests for weread.shell: the global options a chapter takes over (laststatus,
guicursor, mousescroll, ruler), and that leaving puts every one of them back.
(shell 单测：章节接管的全局选项——laststatus、guicursor、mousescroll、ruler——
 以及离开时是否把它们一个不落地放回去)
]]

local config = require("weread.config")
local shell = require("weread.shell")

local tmpdir = vim.fn.tempname()
vim.fn.mkdir(tmpdir, "p")

---Options the shell touches, as they are right now.
---(外壳会动的选项，此刻的值)
---@return table
local function snapshot()
  return {
    laststatus = vim.o.laststatus,
    guicursor = vim.o.guicursor,
    mousescroll = vim.o.mousescroll,
    ruler = vim.o.ruler,
  }
end

---Set the user's options to known values, and apply `layout` on top of the
---defaults.
---(把用户的选项设成已知值，并在默认配置上施加 `layout`)
---@param layout table|nil
local function setup(layout)
  config.setup({ data_dir = tmpdir, keymaps = false, sync_interval = 0, layout = layout })
end

---A buffer that passes for a chapter, shown in the current window.
---(一个能冒充章节的 buffer，显示在当前窗口)
---@return integer buf
local function chapter()
  local buf = vim.api.nvim_create_buf(true, false)
  vim.b[buf].weread = { book_id = "B", chapter_index = 1, chapter_key = "0001", chapter_uid = "1" }
  vim.api.nvim_win_set_buf(0, buf)
  return buf
end

---Run `fn` with the user's options at fixed values, and put them back after.
---(把用户选项设成固定值来跑 fn，跑完恢复)
---@param fn fun(before: table)
local function with_user_options(fn)
  local original = snapshot()
  shell.leave()
  vim.o.laststatus = 2
  vim.o.guicursor = "n-v-c:block,i-ci-ve:ver25"
  vim.o.mousescroll = "ver:3,hor:6"
  vim.o.ruler = true
  local before = snapshot()
  local ok, err = pcall(fn, before)
  shell.leave()
  vim.o.laststatus = original.laststatus
  vim.o.guicursor = original.guicursor
  vim.o.mousescroll = original.mousescroll
  vim.o.ruler = original.ruler
  if not ok then
    error(err, 0)
  end
end

describe("weread.shell", function()
  it("keeps its fallback scroll step in line with the config default", function()
    -- reader.lua reads the same setting; a drifting fallback would make the wheel
    -- step depend on whether setup ran
    -- (reader.lua 读的是同一个设置；回退值一旦漂移，滚轮步长就取决于 setup 有没有跑过)
    local default = config.defaults.layout.mousescroll
    eq(default, "ver:1,hor:1")
    with_user_options(function()
      local buf = chapter()
      config.setup({ data_dir = tmpdir, keymaps = false, sync_interval = 0 })
      config.get().layout.mousescroll = nil
      shell.enter()
      eq(vim.o.mousescroll, default, "no setting falls back to the default")
      vim.api.nvim_buf_delete(buf, { force = true })
    end)
  end)

  it("does nothing outside a chapter", function()
    with_user_options(function(before)
      setup()
      vim.api.nvim_win_set_buf(0, vim.api.nvim_create_buf(false, true))
      shell.enter()
      falsy(shell.active(), "nothing was taken over")
      eq(snapshot(), before, "and no option moved")
    end)
  end)

  it("hides the statusline, the ruler and slows the wheel on entering a chapter", function()
    with_user_options(function(before)
      setup()
      local buf = chapter()
      shell.enter()
      truthy(shell.active())
      eq(vim.o.laststatus, 0, "no statusline")
      eq(vim.o.ruler, false, "and no ruler to take its place on the message line")
      eq(vim.o.mousescroll, "ver:1,hor:1", "the wheel moves one line a notch")
      eq(
        vim.o.guicursor,
        before.guicursor .. ",n:block-WereadCursor",
        "the normal-mode cursor is the accent block, the other modes keep theirs"
      )
      vim.api.nvim_buf_delete(buf, { force = true })
    end)
  end)

  it("puts every option back on leaving", function()
    with_user_options(function(before)
      setup()
      local buf = chapter()
      shell.enter()
      shell.leave()
      falsy(shell.active())
      eq(snapshot(), before, "all four are back to what the user had")
      vim.api.nvim_buf_delete(buf, { force = true })
    end)
  end)

  it("leaving twice is harmless", function()
    with_user_options(function(before)
      setup()
      local buf = chapter()
      shell.enter()
      shell.leave()
      -- the user changes something while away; a second leave must not undo it
      -- (用户在外面改了点什么；第二次 leave 不能把它撤销)
      vim.o.laststatus = 3
      shell.leave()
      eq(vim.o.laststatus, 3, "the second leave leaves the user's own change alone")
      eq(vim.o.ruler, before.ruler)
      vim.api.nvim_buf_delete(buf, { force = true })
    end)
  end)

  it("saves the user's values once, however often it enters", function()
    with_user_options(function(before)
      setup()
      local buf = chapter()
      shell.enter()
      shell.enter()
      shell.enter()
      shell.leave()
      eq(snapshot(), before, "entering again never saved the shell's own values as the originals")
      vim.api.nvim_buf_delete(buf, { force = true })
    end)
  end)

  it("applies a changed config on the next enter, without closing the book", function()
    with_user_options(function(before)
      setup()
      local buf = chapter()
      shell.enter()
      eq(vim.o.laststatus, 0)
      setup({ statusline = "window", cursor = "hidden", mousescroll = "ver:2,hor:2" })
      shell.enter()
      eq(vim.o.laststatus, 2, "a statusline of each window's own needs a non-global one")
      eq(vim.o.ruler, before.ruler, "and the ruler is the user's again")
      eq(vim.o.guicursor, "a:block-WereadCursorHidden", "the cursor is hidden")
      eq(vim.o.mousescroll, "ver:2,hor:2")
      shell.leave()
      eq(snapshot(), before, "and everything still goes back to the first values")
      vim.api.nvim_buf_delete(buf, { force = true })
    end)
  end)

  it("leaves the statusline and the cursor alone under keep and normal", function()
    with_user_options(function(before)
      setup({ statusline = "keep", cursor = "normal" })
      local buf = chapter()
      shell.enter()
      eq(vim.o.laststatus, before.laststatus)
      eq(vim.o.ruler, before.ruler)
      eq(vim.o.guicursor, before.guicursor)
      eq(vim.o.mousescroll, "ver:1,hor:1", "the wheel is still the shell's")
      shell.leave()
      eq(snapshot(), before)
      vim.api.nvim_buf_delete(buf, { force = true })
    end)
  end)

  it("draws a thin bar in normal mode under cursor = bar", function()
    with_user_options(function(before)
      setup({ cursor = "bar" })
      local buf = chapter()
      shell.enter()
      eq(vim.o.guicursor, before.guicursor .. ",n:ver25", "later entries win, so visual and insert keep their shapes")
      vim.api.nvim_buf_delete(buf, { force = true })
    end)
  end)

  it("starts the cursor spec afresh when the user had none", function()
    with_user_options(function()
      setup()
      vim.o.guicursor = ""
      local buf = chapter()
      shell.enter()
      eq(vim.o.guicursor, "n:block-WereadCursor", "no leading comma")
      shell.leave()
      eq(vim.o.guicursor, "", "and the empty value comes back")
      vim.api.nvim_buf_delete(buf, { force = true })
    end)
  end)
end)
