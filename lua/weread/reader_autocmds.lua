--[[
The reader's autocommands: position memory, resize handling, the reading shell.
(阅读器的自动命令：位置记忆、resize 处理、阅读外壳)

Split out of reader.lua. They used to be registered while `weread.reader` was
being required, and they still are: the facade calls `setup` as its last act, so
`:WeReadNext` (which requires the reader without ever calling `weread()`) gets
its autocmds exactly as before. `setup` is idempotent, the augroup clears
itself, and loading the facade twice (the specs do) never doubles a handler.
(它们原本在 require("weread.reader") 的过程中注册，现在依然如此：外壳在加载的最后一步调用
 `setup`，因此 `:WeReadNext`（不经过 weread() 就直接 require 阅读器）和以前一样拿到这些
 自动命令。`setup` 是幂等的，augroup 自己会清空，外壳被加载两次（spec 会这样做）也不会让
 处理函数翻倍)

Resize events arrive in bursts (dragging a window edge, or a terminal resize
that fires `VimResized` and `WinResized` together), so everything heavy hangs
off a debounce: one short one for re-measuring the page, one longer one for
laying the chapter out again at a new page width.
(resize 事件是成串到来的（拖窗口边缘，或者一次终端缩放同时触发 VimResized 与 WinResized），
 所以重的事都挂在防抖上：一个短的用来重新量页，一个长的用来按新版心宽度重排章节)
]]

local layout = require("weread.layout")
local log = require("weread.log")
local session = require("weread.session")
local timer = require("weread.timer")

local M = {}

---Wait after the last resize event before the page is re-measured, and before a
---chapter is laid out again for a new page width.
---(最后一个 resize 事件之后等多久才重新量页，以及等多久才为新版心宽度重排章节)
local REFRESH_MS = 100
local RELAYOUT_MS = 250

---The reader facade `setup` was given: where the calls that other modules and
---the specs replace are looked up.
---(setup 收到的阅读器外壳：别的模块和 spec 会替换的那些调用从这里找)
local host = nil

---@return table
local function reader()
  return host or require("weread.reader")
end

---Run `fn`; when it fails, say so in the log instead of swallowing the error.
---(执行 fn；失败了就写进日志，而不是把错误吞掉)
---@param label string
---@param fn function
---@return boolean ok
local function guarded(label, fn, ...)
  local ok, err = pcall(fn, ...)
  if not ok then
    log.warn("%s failed: %s", label, tostring(err))
  end
  return ok
end

---Did any ordinary (split) window change size? Floats do not count.
---(有没有普通（分屏）窗口变了尺寸？浮窗不算)
---@param windows integer[]|nil `v:event.windows` of WinResized
---@return boolean
function M.resized_split(windows)
  if type(windows) ~= "table" then
    return true
  end
  for _, win in ipairs(windows) do
    if vim.api.nvim_win_is_valid(win) and vim.api.nvim_win_get_config(win).relative == "" then
      return true
    end
  end
  return false
end

---Tables are folded to the window width, so a same-width resize that moved the
---margin still has to draw the current page's tables again.
---(表格按窗口宽度折单元格，所以版心宽度没变、但边距变了的 resize，仍要把当前页的表格重画)
local tables_dirty = false

---Re-measure the page of every chapter window, and redraw tables when asked to.
---One run per burst of resize events.
---(重新量所有章节窗口的页，需要时重画表格。一串 resize 事件只跑一次)
local refresh = timer.debounce(function()
  if tables_dirty then
    tables_dirty = false
    local win = vim.api.nvim_get_current_win()
    local buf = vim.api.nvim_win_get_buf(win)
    if session.buffer_info(buf) then
      pcall(function()
        require("weread.decorations").render(buf, win)
      end)
    end
  end
  -- a taller or shorter window holds a different page
  -- (窗口变高或变矮，一页能装的就不一样了)
  pcall(require("weread.pager").refresh_all)
end, REFRESH_MS)

---Lay the chapter on screen out again at the page width the session now has.
---Nothing is rendered for widths the user is only passing through while
---dragging a window edge.
---(按会话现在的版心宽度重排屏幕上的章节。拖动窗口边缘时只是路过的那些宽度，一版都不排)
local relayout_win = nil
local relayout = timer.debounce(function()
  local win = relayout_win
  relayout_win = nil
  if not win or not vim.api.nvim_win_is_valid(win) then
    return
  end
  local buf = vim.api.nvim_win_get_buf(win)
  local current = session.buffer_info(buf)
  if not current then
    return
  end
  vim.api.nvim_win_call(win, function()
    -- The buffer still holds the old layout, so its map turns the cursor into
    -- a source offset that survives the new line breaks; a bare line number
    -- would land in another paragraph.
    -- (buffer 里还是旧排版，它的 map 能把光标换成在新断行下依然成立的源偏移；只传行号会落到
    --  别的段落)
    local offset = session.source_offset(buf, win)
    reader().open_index(current.chapter_index, { line = vim.fn.line("."), source_offset = offset })
  end)
end, RELAYOUT_MS)

---The chapter window a resize is about: the current one, or else the first
---chapter window on screen, so dragging a split from the sidebar re-lays the
---page out too.
---(这次尺寸变化关心的章节窗口：当前窗口，否则屏幕上第一个章节窗口，这样在侧边栏里拖分屏时页面也会重排)
---@return integer|nil win
local function chapter_window()
  local current = vim.api.nvim_get_current_win()
  if session.buffer_info(vim.api.nvim_win_get_buf(current)) then
    return current
  end
  for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    if vim.api.nvim_win_get_config(win).relative == "" and session.buffer_info(vim.api.nvim_win_get_buf(win)) then
      return win
    end
  end
  return nil
end

---Re-lay out the current chapter when its window changes width. The page width
---is baked into the rendered lines, so a stale render is either truncated or
---leaves a hole where the margin should be.
---(章节所在窗口宽度变化时重排版面。版心宽度已经写进了渲染出的行里，过期的渲染要么被
--- 截断，要么在该有边距的地方留出空洞)
local function on_resize()
  local win = chapter_window()
  if not win then
    return
  end
  local info = session.buffer_info(vim.api.nvim_win_get_buf(win))
  local width = layout.page_width(win)
  -- The margin follows the window even when the page width does not change:
  -- a narrower window means narrower margins, not a page stuck to the left.
  -- (即使版心宽度不变，边距也要跟着窗口走：窗口变窄意味着边距变小，而不是页贴在左边)
  layout.apply(win, width)
  if width == session.page_width() then
    -- The page width is unchanged, but the margin that puts it in the middle is
    -- not: a table folds its cells into the window width, and that budget just
    -- changed, so the page's tables have to be drawn again.
    -- (版心宽度没变，但把它放在中间的边距变了：表格是按窗口宽度折单元格的，而那份预算刚刚
    --  变了，因此这一页的表格要重画一次)
    tables_dirty = true
    return
  end
  session.set_page_width(width)
  relayout_win = win
  relayout.call()
  log.debug("page width -> %d, re-laying out chapter %d", width, info.chapter_index)
end

---Handler of `VimResized` and `WinResized`.
---(VimResized 与 WinResized 的处理函数)
local function on_resized()
  -- Floats resizing (the page's own cover, a notification sliding in) say
  -- nothing about the chapter window, and re-laying the page out for them
  -- snapped a `zz` page back and forth. `VimResized` carries no window list, so
  -- it always counts: a terminal resize changes the splits.
  -- (浮窗变尺寸——页面自己的遮罩、滑入的通知——与章节窗口无关；为它们重排会把 `zz` 居中的
  --  页来回弹。VimResized 不带窗口列表，所以一律算数：终端缩放必然改变分屏)
  if not M.resized_split(vim.v.event.windows) then
    return
  end
  -- A split or a resized neighbour changes chapter windows that are not the
  -- current one: each keeps its page centred and re-measures its pages.
  -- (分屏或旁边的窗口变了尺寸，会改变那些不是当前窗口的章节窗口：每个都要保持页面居中、
  --  重新量页)
  local page_width = session.page_width()
  for _, win in ipairs(vim.api.nvim_list_wins()) do
    if vim.api.nvim_win_get_config(win).relative == "" and session.buffer_info(vim.api.nvim_win_get_buf(win)) then
      if win ~= vim.api.nvim_get_current_win() and page_width then
        layout.apply(win, math.min(page_width, layout.page_width(win)))
      end
    end
  end
  on_resize()
  refresh.call()
end

---Leaving a chapter: remember the place and settle the reading time. Kept
---separate from `save_position` because opening a chapter records its own
---position too, and that must not flush progress.
---(离开章节：记住位置并结算阅读时长。与 save_position 分开，因为打开章节时也会记录
--- 位置，而那次不应触发进度结算)
local function on_buf_leave()
  session.save_position()
  local ok, progress = pcall(require, "weread.progress")
  if ok then
    guarded("settling reading time", progress.leave, reader())
  end
end

---The reading shell is global state (statusline, cursor, mouse wheel), so it has
---to follow the buffer that is actually on screen — including the pickers and
---floats the reader opens on top of a chapter.
---(阅读外壳是全局状态（状态栏、光标、滚轮），因此要跟着真正显示在屏幕上的 buffer 走
--- ——也包括叠在章节之上的选择器与浮窗)
local function sync_shell()
  local ok, shell = pcall(require, "weread.shell")
  if not ok then
    return
  end
  if reader().buffer_info() then
    shell.enter()
    return
  end
  shell.leave()
  -- Hand every other window its colorscheme back: a window that was reading keeps
  -- the paper palette, including the generic captures the palette took over,
  -- until something takes it away.
  -- (并把其它窗口的配色还回去：读过书的窗口会一直留着纸色——包括被接管的通用捕获——
  --  直到有人把它取走)
  pcall(function()
    require("weread.theme").clear_stale()
  end)
  pcall(function()
    require("weread.reader_window").restore_stale()
  end)
end

---The chapter window the reader was in last, for the exit report.
---(读者最后待过的章节窗口，供退出时上报)
local last_chapter_win = nil

---Back in the book: a position that arrived while the reader was in another
---window lands now, and the phone gets asked again.
---(回到书里：读者在别的窗口时到达的远端位置现在落地，并再问一次手机)
local function on_enter_chapter()
  last_chapter_win = vim.api.nvim_get_current_win()
  pcall(reader().install_keymaps, vim.api.nvim_get_current_buf())
  pcall(reader().claim_hover, vim.api.nvim_get_current_buf())
  vim.schedule(function()
    if reader().apply_pending_remote() then
      return
    end
    local ok, progress = pcall(require, "weread.progress")
    if ok and reader().current() then
      progress.poll()
    end
  end)
end

---The chapter's position has to be banked before the process disappears with
---it. A regular async report would be killed mid-flight by the exit.
---(章节的位置必须赶在进程消失之前落袋。普通异步上报会在退出途中被杀掉)
local function on_exit()
  local ok, shell = pcall(require, "weread.shell")
  if ok then
    -- never leave the editor with laststatus = 0 after a session
    -- (绝不能让编辑器在退出时还留在 laststatus = 0)
    pcall(shell.leave)
  end
  -- the pace learned since the last write is kept for the next session
  -- (上次写盘之后学到的阅读速度，留给下一次会话)
  pcall(function()
    require("weread.pace").flush()
  end)
  -- and the minutes read today (以及今天读了几分钟)
  pcall(function()
    require("weread.journal").flush()
  end)
  -- translations looked up since the last write (上次写盘之后查到的译文)
  pcall(function()
    require("weread.lookup").flush()
  end)
  -- `:qa` typed in a sidebar still leaves a book open next to it: report the
  -- chapter window that was read last, not just the current one.
  -- (在侧边栏里敲的 `:qa` 旁边仍开着书：上报最后读过的章节窗口，而不只是当前窗口)
  local win = last_chapter_win
  if session.buffer_info() then
    win = vim.api.nvim_get_current_win()
  end
  if win and vim.api.nvim_win_is_valid(win) and session.buffer_info(vim.api.nvim_win_get_buf(win)) then
    local buf = vim.api.nvim_win_get_buf(win)
    guarded("saving the reading position", session.save_position, buf)
    local ok_progress, progress = pcall(require, "weread.progress")
    if ok_progress then
      guarded("the final progress report", progress.flush_sync, { buf = buf, win = win })
    end
  end
end

---Autocmds that react to the cursor and the view moving in a chapter.
---(章节里光标与视图移动时的自动命令)
---@param group integer
local function register_movement(group)
  -- A settled cursor reports its position: another device should not sit a whole
  -- reading-time interval behind.
  -- (光标停稳就上报位置：另一端不该落后整整一个阅读时长间隔)
  vim.api.nvim_create_autocmd({ "CursorMoved", "WinScrolled" }, {
    group = group,
    callback = function(args)
      if session.buffer_info(args.buf) then
        local ok, progress = pcall(require, "weread.progress")
        if ok then
          pcall(progress.moved)
        end
        -- a search or `G` that leaves the page shows the page it lands on
        -- (搜索或 `G` 离开了这一页，就显示它落到的那一页)
        if args.event == "CursorMoved" then
          pcall(require("weread.pager").follow_cursor)
        end
      end
      -- WinScrolled names the window that scrolled, which need not be the
      -- current one
      -- (WinScrolled 给出的是滚动了的窗口，不一定是当前窗口)
      if args.event == "WinScrolled" then
        local win = tonumber(args.match)
        if win and vim.api.nvim_win_is_valid(win) and session.buffer_info(vim.api.nvim_win_get_buf(win)) then
          -- `zt`, a mouse drag or an illustration that finished loading moved
          -- the view: put the page back together
          -- (`zt`、鼠标拖动或刚加载完的插图挪动了视图：把这一页重新拼好)
          pcall(require("weread.pager").on_scrolled, win)
          -- the tables and code blocks of the page that came into view
          -- (刚进入视野的那一页的表格与代码块)
          vim.schedule(function()
            if vim.api.nvim_win_is_valid(win) then
              pcall(require("weread.decorations").follow, vim.api.nvim_win_get_buf(win), win)
            end
          end)
        end
      end
    end,
  })
  -- Covers belong to chapter windows; a window that closed or moved on to
  -- another buffer must not keep one floating over it.
  -- (遮罩属于章节窗口；窗口关掉了、或换成了别的 buffer，就不能再留一块浮在上面)
  vim.api.nvim_create_autocmd({ "BufWinEnter", "WinClosed", "BufEnter" }, {
    group = group,
    callback = function()
      vim.schedule(function()
        pcall(require("weread.pager").prune)
      end)
    end,
  })
end

---Autocmds that keep the reading shell in step with what is on screen.
---(让阅读外壳跟着屏幕上的内容走的自动命令)
---@param group integer
local function register_shell(group)
  vim.api.nvim_create_autocmd({ "BufEnter", "WinEnter" }, {
    group = group,
    callback = function()
      sync_shell()
      if reader().buffer_info() then
        on_enter_chapter()
      end
    end,
  })
  -- The reading shell owns global options that other plugins also set: lualine
  -- turns `laststatus` back into a global statusline when it loads, which happens
  -- after a chapter opened from a startup command may already be on screen. Every
  -- other reading window switch fixes it; these cover the first one.
  -- (阅读外壳接管的全局选项别的插件也会设：lualine 加载时会把 `laststatus` 设回全局状态栏，
  --  而那时启动命令打开的章节可能已经在屏幕上了。之后任何窗口切换都会修好它，这几个事件覆盖
  --  第一次)
  vim.api.nvim_create_autocmd("User", {
    group = group,
    pattern = "VeryLazy",
    callback = sync_shell,
  })
  vim.api.nvim_create_autocmd("VimEnter", {
    group = group,
    callback = function()
      vim.defer_fn(sync_shell, 200)
    end,
  })
  vim.api.nvim_create_autocmd("ColorScheme", {
    group = group,
    callback = function()
      sync_shell()
      -- `:colorscheme` clears every highlight group, the page's own included
      -- (`:colorscheme` 会清掉所有高亮组，包括书页自己的)
      pcall(function()
        require("weread.theme").redefine()
      end)
      -- The window mapping is rebuilt too: it lists the colorscheme's own groups
      -- (`@markup.*`, render-markdown's), and the new scheme may have others.
      -- `apply_all` repaints the pager as well.
      -- (窗口映射也要重建：它列出了配色方案自己的组（`@markup.*`、render-markdown 的），
      --  新配色方案可能有别的组。`apply_all` 也会重画翻页器)
      pcall(function()
        require("weread.theme").apply_all()
      end)
    end,
  })
  -- LSP keymaps land a scheduled, debounced moment after the attach, so claim `K`
  -- back a little later, and once more in case the server was slow.
  -- (LSP 键位在 attach 之后经 schedule + 防抖才落下，所以稍后再认领一次 K，并为慢的
  --  服务器多补一次)
  vim.api.nvim_create_autocmd("LspAttach", {
    group = group,
    callback = function(event)
      if not session.buffer_info(event.buf) then
        return
      end
      for _, delay in ipairs({ 300, 1500 }) do
        timer.defer(function()
          pcall(reader().claim_hover, event.buf)
        end, delay)
      end
    end,
  })
end

---Autocmds that bank the reading position and progress.
---(落袋阅读位置与进度的自动命令)
---@param group integer
local function register_saving(group)
  vim.api.nvim_create_autocmd("BufLeave", {
    group = group,
    callback = on_buf_leave,
  })
  -- One handler for leaving the editor: it covers the current chapter and the
  -- one read last, so a second `VimLeavePre` saving the same buffer again is
  -- not needed (and what is unchanged would not be written anyway).
  -- (离开编辑器只留一个处理函数：它既管当前章节也管最后读过的那个，因此不需要第二个
  --  VimLeavePre 再存一遍同一个 buffer（没变化的位置本来也不会重复写盘）)
  vim.api.nvim_create_autocmd("VimLeavePre", {
    group = group,
    callback = on_exit,
  })
  -- Coming back to the terminal: the reader may have continued on the phone in
  -- the meantime, and that place belongs in this window too.
  -- (回到终端：读者可能刚才在手机上读了下去，那个位置也该进这个窗口)
  vim.api.nvim_create_autocmd("FocusGained", {
    group = group,
    callback = function()
      local ok, progress = pcall(require, "weread.progress")
      if ok and reader().current() then
        progress.poll({ force = true })
      end
    end,
  })
  -- Losing the terminal focus is the reader walking away: the place is reported
  -- immediately instead of waiting for the interval, so a phone opened a minute
  -- later knows where this session got to.
  -- (终端失焦即读者离开：位置立刻上报而不是等间隔，一分钟后拿起手机就能接着读)
  vim.api.nvim_create_autocmd("FocusLost", {
    group = group,
    callback = function()
      if session.buffer_info() then
        session.save_position()
        local ok, progress = pcall(require, "weread.progress")
        if ok then
          guarded("flushing progress", progress.flush)
        end
      end
    end,
  })
  -- Also checkpoint while reading, throttled: saving a JSON file on every cursor
  -- hold would be wasteful, but only saving on leave loses the place on a crash.
  -- (阅读中也定期存一次；每次 CursorHold 都写 JSON 太浪费，但只在离开时存又会在
  --  崩溃时丢掉位置)
  local last_checkpoint = 0
  vim.api.nvim_create_autocmd({ "CursorHold", "CursorHoldI" }, {
    group = group,
    callback = function()
      local now = os.time()
      if now - last_checkpoint < 5 then
        return
      end
      last_checkpoint = now
      session.save_position()
    end,
  })
  vim.api.nvim_create_autocmd("WinLeave", {
    group = group,
    callback = function()
      local buf = vim.api.nvim_get_current_buf()
      if session.buffer_info(buf) then
        session.save_position(buf)
      end
    end,
  })
end

---Register every reader autocmd. Safe to call again: the augroup clears itself.
---(注册阅读器的全部自动命令。可以重复调用：augroup 会自己清空)
---@param facade table the reader module, for the calls others replace(阅读器模块本身，供那些会被别人替换的调用使用)
function M.setup(facade)
  host = facade
  local group = vim.api.nvim_create_augroup("weread_reader", { clear = true })
  register_saving(group)
  register_movement(group)
  register_shell(group)
  vim.api.nvim_create_autocmd({ "VimResized", "WinResized" }, {
    group = group,
    callback = on_resized,
  })
  -- Any key counts as a sign of life: reading time and the "is someone here"
  -- question both hang on it. A fixed namespace makes a second `setup` replace
  -- the listener instead of stacking another one.
  -- (任何按键都算有人在：阅读时长与「有没有人在」都靠它。命名空间固定，第二次 setup 是
  --  替换监听器，而不是再叠一个)
  vim.on_key(function()
    local ok, progress = pcall(require, "weread.progress")
    if ok and progress.touch then
      progress.touch()
    end
  end, vim.api.nvim_create_namespace("weread.activity"))
end

return M
