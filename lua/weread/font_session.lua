--[[
The lifetime of the reading font: on while a chapter is on screen, off when the
reader goes back to the rest of the editor.
(阅读字体的生命周期：章节在屏幕上时开启，回到编辑器其它地方时关闭)

This is the part that makes "only in the plugin" true in practice. The terminal
font is global, so a font that is applied on `:WeReadOpen` and never removed is
the same as changing the terminal. Here the font follows the chapter buffer:
`BufEnter`/`WinEnter` apply it, leaving a chapter puts the original back after a
short grace period, and `VimLeavePre` restores synchronously so a crash-free
quit never leaves the terminal in a reading font.
(这正是让「只在插件里生效」落到实处的一层。终端字体是全局的，所以打开书时换上去、之后
 再也不恢复，等于改了终端。这里让字体跟着章节 buffer 走：BufEnter/WinEnter 应用，离开
 章节后经过一小段宽限期恢复，VimLeavePre 同步恢复，因此正常退出绝不会把终端留在阅读
 字体上)

Floats over a chapter (contents, thoughts, the dictionary) are part of reading:
while one is focused the font stays. Everything else — a code buffer, a picker
opened from the dashboard, the command line — counts as leaving.
(叠在章节上的浮窗（目录、想法、词典）属于阅读：它们拿到焦点时字体保持。其它情况——代码
 buffer、从首页打开的选择器、命令行——都算离开)
]]

local log = require("weread.log")
local timer = require("weread.timer")

local M = {}

---A chapter was the current buffer the last time we looked. It tells the leave
---path whether there is anything to undo without asking the kitty state, which
---is cheap but not free on every buffer enter.
---(上次看的时候当前 buffer 是不是章节。它让「离开」逻辑不必每次都去问 kitty 状态，
--- 从而在每次进 buffer 时省下一点开销)
local was_reading = false

---A real UI is attached. Headless runs (tests, scripts) have no terminal to
---switch and must not run `kitten`.
---(有真实界面。无界面运行（测试、脚本）没有终端可换，也不该去跑 kitten)
---@return boolean
local function interactive()
  return #vim.api.nvim_list_uis() > 0
end

---The font facade, loaded lazily: this module is installed at setup, and setup
---must stay cheap.
---(字体门面，延迟加载：本模块在 setup 时安装，而 setup 必须保持轻量)
---@return table
local function font()
  return require("weread.font")
end

---@return table
local function kitty()
  return require("weread.font_kitty")
end

---Is this buffer a chapter? The reader marks every chapter buffer this way.
---(这个 buffer 是章节吗？阅读器用这个标记每章节 buffer)
---@param buf integer|nil
---@return boolean
local function is_chapter(buf)
  buf = buf or vim.api.nvim_get_current_buf()
  return vim.b[buf].weread_book ~= nil
end

---@param win integer
---@return boolean
local function is_float(win)
  local config = vim.api.nvim_win_get_config(win)
  return config.relative ~= "" or config.external == true
end

---Should the reading font be on for what is on screen right now?
---(此刻屏幕上的东西该不该用阅读字体)
---@return boolean
function M.want()
  local win = vim.api.nvim_get_current_win()
  local buf = vim.api.nvim_win_get_buf(win)
  if is_chapter(buf) then
    return true
  end
  -- A float over a chapter is a piece of the reading UI. There is no cheap way
  -- to know what lies under an arbitrary float, so the current state decides:
  -- if the font is already on, a picker did not mean "stop reading".
  -- (章节上的浮窗是阅读界面的一部分。任意浮窗下面压着什么没有便宜的判断方式，所以看当前
  --  状态：字体已经开着，说明一个选择器并不代表「不读了」)
  if is_float(win) then
    return kitty().status().applied
  end
  return false
end

---Is a chapter being read right now? Used by `:WeReadFont` to decide whether a
---newly chosen font should be switched to immediately.
---(现在是不是正在读章节？`:WeReadFont` 用它决定新选的字体要不要立刻切换)
---@return boolean
function M.active()
  return M.want()
end

local leave = timer.debounce(function()
  if M.want() then
    return
  end
  local ok, err = pcall(font().deactivate)
  if not ok then
    log.warn("font deactivation failed: %s", tostring(err))
  end
end, 150)

---Apply or restore the font for the current window. Safe to call often.
---(按当前窗口应用或恢复字体；可以频繁调用)
function M.check()
  if M.want() then
    was_reading = true
    local ok, err = pcall(font().activate)
    if not ok then
      log.warn("font activation failed: %s", tostring(err))
    end
    return
  end
  -- Nothing was switched on: do not create a timer on every buffer enter just
  -- to decide there is nothing to switch off.
  -- (没有换过字体：不要每进一个 buffer 都建一个定时器，只为了决定没有东西要恢复)
  if was_reading then
    was_reading = false
    leave.call()
  end
end

---Re-check after the choice changed. A picker can temporarily replace a chapter
---with its own window, so its caller preserves the source chapter buffer. Do not
---apply after the reader has navigated somewhere else while that picker was open.
---(选择变了之后重新检查。选择器会暂时用自己的窗口替换章节窗口，所以调用方保留发起选择的
---章节 buffer；若选择器开着时已经去了别处，就不要再应用)
---@param from_chapter integer|boolean|nil source chapter buffer; true keeps legacy callers(发起选择的章节 buffer；true 兼容旧调用方)
function M.refresh(from_chapter)
  if type(from_chapter) == "number" then
    if vim.api.nvim_get_current_buf() ~= from_chapter or not is_chapter(from_chapter) then
      M.check()
      return
    end
  end
  if from_chapter then
    local ok, err = pcall(font().activate)
    if not ok then
      log.warn("font activation failed: %s", tostring(err))
    end
    return
  end
  M.check()
end

local installed = false

---Install the autocmds once. Called from `weread.setup()`.
---(只安装一次自动命令；由 weread.setup() 调用)
function M.setup()
  if installed then
    return
  end
  installed = true
  local group = vim.api.nvim_create_augroup("weread_font_session", { clear = true })

  vim.api.nvim_create_autocmd({ "BufEnter", "BufWinEnter", "WinEnter", "TabEnter" }, {
    group = group,
    callback = function()
      if interactive() then
        M.check()
      end
    end,
  })
  vim.api.nvim_create_autocmd({ "BufLeave", "WinLeave", "TabLeave", "WinClosed" }, {
    group = group,
    callback = function()
      -- No chapter has been on screen: nothing to restore, and no timer to
      -- create on every buffer switch.
      -- (屏幕上还没有过章节：没有东西要恢复，也不用每次切 buffer 都建定时器)
      if was_reading and interactive() then
        leave.call()
      end
    end,
  })
  -- A session restored by a session manager may already have a chapter on
  -- screen when the plugin is set up; the event above has already fired.
  -- (会话管理器恢复出来的 nvim 可能在插件 setup 时就已经显示着章节；上面的 BufEnter 已经
  --  过去了)
  vim.api.nvim_create_autocmd("VimEnter", {
    group = group,
    callback = function()
      timer.defer(function()
        if interactive() then
          M.check()
        end
      end, 250)
    end,
  })
  vim.api.nvim_create_autocmd("VimResume", {
    group = group,
    callback = function()
      timer.defer(function()
        if interactive() then
          M.check()
        end
      end, 100)
    end,
  })
  -- Suspending hands the terminal back to the shell; the shell must not come
  -- back to a reading font.
  -- (挂起会把终端交回 shell；shell 不该看到阅读字体)
  vim.api.nvim_create_autocmd("VimSuspend", {
    group = group,
    callback = function()
      pcall(kitty().restore_sync)
    end,
  })
  -- On the way out, an async restore would be killed with the process.
  -- (退出时异步恢复会随进程一起被杀掉)
  vim.api.nvim_create_autocmd("VimLeavePre", {
    group = group,
    callback = function()
      local ok, restored = pcall(kitty().restore_sync)
      if not ok or not restored then
        log.warn("could not restore the terminal font on exit")
      end
    end,
  })
  -- Setup can run after a chapter is already on screen (a session manager, or
  -- a user who called setup late); look once, outside the current callback.
  -- (setup 可能在章节已经在屏幕上之后才跑（会话管理器，或者用户很晚才调 setup）；在
  --  当前回调之外看一次)
  vim.schedule(function()
    if interactive() then
      M.check()
    end
  end)
end

return M
