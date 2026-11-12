--[[
Keymaps and footnotes of a chapter page.
(章节页面的键位与脚注)

Split out of reader.lua. Every key resolves what it calls through
`require("weread.reader")` at the moment it is pressed, never when the keymap
is registered: the reader facade is where other modules (and the specs) swap a
function out, and a keymap that captured the original would silently ignore it.
(从 reader.lua 拆出。每个键都在**按下的那一刻**才通过 require("weread.reader") 找到要调用的
 函数，而不是在注册键位时：阅读器外壳是别的模块（以及 spec）替换函数的地方，键位若抓住了
 原函数，就会悄悄无视这种替换)
]]

local config = require("weread.config")
local session = require("weread.session")
local xhtml = require("weread.xhtml")

local M = {}

---@return table the reader facade, resolved lazily(阅读器外壳，延后解析)
local function reader()
  return require("weread.reader")
end

local function keymaps_enabled()
  return config.get().keymaps ~= false
end

---Open the footnote on the cursor line in a float.
---(在浮窗里打开光标行上的脚注)
---@return boolean shown
function M.show_footnote()
  local cursor = vim.api.nvim_win_get_cursor(0)
  local footnote = xhtml.footnote_at(session.footnotes(), cursor[1] - 1, cursor[2])
  if not footnote or not footnote.text or footnote.text == "" then
    return false
  end
  local width = math.min(56, math.max(20, vim.o.columns - 8))
  local lines = {}
  for _, paragraph in ipairs(vim.split(footnote.text, "\n", { plain = true })) do
    -- fold by display width: the float does not wrap, and a note reads as prose
    -- (按显示宽度折行：浮窗不折行，而注释读起来就是一段文字)
    local line, cells = {}, 0
    for _, char in ipairs(vim.fn.split(paragraph, "\\zs")) do
      local char_cells = vim.fn.strdisplaywidth(char)
      if cells + char_cells > width - 2 and cells > 0 then
        lines[#lines + 1] = table.concat(line)
        line, cells = {}, 0
      end
      line[#line + 1] = char
      cells = cells + char_cells
    end
    lines[#lines + 1] = table.concat(line)
  end
  local float = require("weread.float").open({
    lines = lines,
    width = width,
    title = "注",
  })
  return float ~= nil
end

---Move the cursor to the next or previous footnote marker.
---(把光标移到下一个/上一个脚注标记)
---@param forward boolean
---@return boolean moved
function M.jump_footnote(forward)
  local cursor = vim.api.nvim_win_get_cursor(0)
  local here = { cursor[1] - 1, cursor[2] }
  local best = nil
  for _, footnote in ipairs(session.footnotes()) do
    local at = { tonumber(footnote.line) or 0, tonumber(footnote.col_from) or 0 }
    local after = at[1] > here[1] or (at[1] == here[1] and at[2] > here[2])
    local before = at[1] < here[1] or (at[1] == here[1] and at[2] < here[2])
    if forward and after and (not best or at[1] < best[1] or (at[1] == best[1] and at[2] < best[2])) then
      best = at
    elseif not forward and before and (not best or at[1] > best[1] or (at[1] == best[1] and at[2] > best[2])) then
      best = at
    end
  end
  if not best then
    require("weread.ui").notify("weread: 本章没有更多脚注", vim.log.levels.INFO, { routine = true })
    return false
  end
  vim.api.nvim_win_set_cursor(0, { best[1] + 1, best[2] })
  return true
end

local HOVER_DESC = "微信读书：翻译光标处外文 / 查看划线想法"

---What `K` does on a page: see `weread.reader_lookup.hover`.
---(书页上 K 的行为：见 weread.reader_lookup.hover)
function M.hover()
  require("weread.reader_lookup").hover()
end

---Map `K` in a chapter buffer unless it already is ours.
---(在章节 buffer 里映射 K，已经是我们的就不动)
---
---A language server attached to the page (render-markdown ships one) makes
---LazyVim/snacks map a buffer-local `K` to LSP hover *after* the attach, which
---silently replaced this one: pressing K showed nothing, and the log said
---`textDocument/hover is not supported`. So the mapping is claimed again after
---every attach and on every visit.
---(挂在书页上的语言服务器（render-markdown 自带一个）会让 LazyVim/snacks 在 attach
--- **之后**把 buffer 级的 K 映射成 LSP hover，于是这里的 K 被悄悄替换：按 K 什么都不
--- 出，日志里写着 `textDocument/hover is not supported`。因此每次 attach 之后、每次进入
--- buffer 时都重新认领这个映射)
---@param buf integer
---@return boolean claimed
function M.claim_hover(buf)
  if not keymaps_enabled() or not vim.api.nvim_buf_is_valid(buf) or not session.buffer_info(buf) then
    return false
  end
  local current = vim.api.nvim_buf_call(buf, function()
    return vim.fn.maparg("K", "n", false, true)
  end)
  if type(current) == "table" and current.buffer == 1 and current.desc == HOVER_DESC then
    return false
  end
  -- looked up when pressed, so a replaced `hover` is the one that runs
  -- (按下时才去找，被替换过的 hover 才是真正执行的那个)
  vim.keymap.set("n", "K", function()
    reader().hover()
  end, { buffer = buf, silent = true, nowait = true, desc = HOVER_DESC })
  return true
end

---Visual selection as two normalized positions.
---(把可视选区整理成两个有先后顺序的位置)
---@return integer[]|nil head
---@return integer[]|nil tail
local function selection()
  local from, to = vim.fn.getpos("v"), vim.fn.getpos(".")
  if from[2] == 0 then
    return nil, nil
  end
  local first = { from[2], from[3] - 1 }
  local last = { to[2], to[3] - 1 }
  if first[1] > last[1] or (first[1] == last[1] and first[2] > last[2]) then
    first, last = last, first
  end
  vim.cmd("normal! \27")
  return first, last
end

---Visual-mode keys: `<leader>wh` highlights what is selected, `<leader>wd`
---removes the local highlights a selection touches, `<leader>wc` writes a
---thought on it.
---(可视模式：`<leader>wh` 给选中文字划线，`<leader>wd` 删掉与选区重叠的、在这里画的划线，
--- `<leader>wc` 给这段写想法)
---@param buf integer
local function map_visual(buf)
  vim.keymap.set("x", "K", function()
    require("weread.reader_lookup").hover_selection()
  end, { buffer = buf, silent = true, desc = "微信读书：翻译选中的文字" })
  vim.keymap.set("x", "<leader>wh", function()
    local ok, annotations = pcall(require, "weread.annotations")
    if not ok then
      return
    end
    local current = vim.api.nvim_get_current_buf()
    local head, tail = selection()
    if not head then
      return
    end
    local good, message = annotations.highlight(current, head, tail)
    vim.notify(message, good and vim.log.levels.INFO or vim.log.levels.WARN)
  end, { buffer = buf, silent = true, desc = "微信读书：给选中文字划线" })
  vim.keymap.set("x", "<leader>wd", function()
    local ok, annotations = pcall(require, "weread.annotations")
    if not ok then
      return
    end
    local current = vim.api.nvim_get_current_buf()
    local head, tail = selection()
    if not head then
      return
    end
    local removed = annotations.unhighlight_range(current, head, tail)
    vim.notify(
      removed > 0 and string.format("已取消 %d 条划线", removed)
        or "选区里没有在这里画的划线（App 里画的请把光标放上去按 <leader>wd）",
      removed > 0 and vim.log.levels.INFO or vim.log.levels.WARN
    )
  end, { buffer = buf, silent = true, desc = "微信读书：取消选区内在这里画的划线" })
  vim.keymap.set("x", "<leader>wc", function()
    local ok, annotations = pcall(require, "weread.annotations")
    if not ok then
      return
    end
    local current = vim.api.nvim_get_current_buf()
    local head, tail = selection()
    if not head then
      return
    end
    local range = annotations.range_of_positions(current, head, tail)
    if not range then
      vim.notify("weread: 选区里没有正文", vim.log.levels.WARN)
      return
    end
    local text = require("weread.annotations_edit").passage_text(current, head, tail)
    local context = annotations.write_context(current)
    -- A selection that carries no highlight yet becomes one: a thought needs a
    -- passage to hang on, and the service reads thoughts back by range.
    -- (选区还没有划线就先划一条——想法需要有挂靠的段落，服务端也是按 range 读回来的)
    if context then
      annotations.add_local(context.book_id, context.chapter_key, range, annotations.plain_text(text))
      annotations.sync_local(current)
    end
    annotations.compose_thought(current, range, annotations.plain_text(text))
  end, { buffer = buf, silent = true, desc = "微信读书：给选中文字写想法" })
end

---Keys of a book read a page at a time. `j`/`k` still move a line, and walking
---off either end of the page turns it.
---(一页一页读的书的键位。`j`/`k` 仍然按行移动，走出页面任何一端就翻页)
---@param map fun(lhs: string, rhs: function, desc: string)
local function map_paged(map)
  local pager = require("weread.pager")
  for _, key in ipairs({ "<Right>", "<PageDown>", "<C-f>", "<C-d>", "<C-j>" }) do
    map(key, function()
      pager.next()
    end, "微信读书：下一页（章末进入下一章）")
  end
  for _, key in ipairs({ "<Left>", "<PageUp>", "<C-b>", "<C-u>", "<C-k>", "<S-Space>" }) do
    map(key, function()
      pager.prev()
    end, "微信读书：上一页（章首回到上一章）")
  end
  -- <Space> turns the page only when it is not the leader key: with a space
  -- leader, a buffer-local nowait <Space> would swallow every <leader> map.
  -- (只有空格不是 leader 时才让 <Space> 翻页：leader 是空格时，buffer 级的 nowait <Space>
  --  会吞掉所有 <leader> 键位)
  if vim.g.mapleader ~= " " then
    map("<Space>", function()
      pager.next()
    end, "微信读书：下一页")
  end
  local function line_or_page(forward)
    local win = vim.api.nvim_get_current_win()
    local line = vim.api.nvim_win_get_cursor(win)[1]
    if forward then
      local bottom = pager.bottom(win)
      local last = vim.api.nvim_buf_line_count(0)
      if line >= bottom or line >= last then
        pager.next()
        return
      end
      pager.step(win, true, vim.v.count1)
      if vim.api.nvim_win_get_cursor(win)[1] > bottom then
        -- stepped over hidden lines past the page: the next page
        -- (跨过藏起的行走出了这一页：下一页)
        pager.follow_cursor(win)
      end
    else
      if line <= vim.fn.line("w0", win) then
        pager.prev({ at_bottom = true })
        return
      end
      pager.step(win, false, vim.v.count1)
    end
  end
  for _, key in ipairs({ "j", "<Down>", "<C-e>" }) do
    map(key, function()
      line_or_page(true)
    end, "微信读书：下一行（页底翻页）")
  end
  for _, key in ipairs({ "k", "<Up>", "<C-y>" }) do
    map(key, function()
      line_or_page(false)
    end, "微信读书：上一行（页顶翻页）")
  end
  for _, key in ipairs({ "<ScrollWheelDown>", "<ScrollWheelRight>" }) do
    map(key, function()
      pager.wheel(true)
    end, "微信读书：下一页")
  end
  for _, key in ipairs({ "<ScrollWheelUp>", "<ScrollWheelLeft>" }) do
    map(key, function()
      pager.wheel(false)
    end, "微信读书：上一页")
  end
end

---Keys of a book scrolled like any other buffer, turning the page at the ends.
---Scrolling and page turning live in `scroll_or_turn`/`wheel_or_turn`: keeping
---them out of the keymap closures is what makes them testable, because mouse
---events cannot be injected into a headless session.
---(像普通 buffer 一样滚动、在两端翻页的键位。滚动与翻页在 scroll_or_turn / wheel_or_turn
--- 里：把它们放在键位闭包之外才能在测试里直接调用——鼠标事件无法注入到无界面会话)
---@param map fun(lhs: string, rhs: function, desc: string)
local function map_scrolling(map)
  local function scroll(key, forward)
    return function()
      reader().scroll_or_turn(key, forward)
    end
  end
  map("j", scroll("gj", true), "微信读书：下一行（章末翻页）")
  map("k", scroll("gk", false), "微信读书：上一行（章首翻页）")
  map("<Down>", scroll("gj", true), "微信读书：下一行")
  map("<Up>", scroll("gk", false), "微信读书：上一行")
  map("<C-f>", scroll("\6", true), "微信读书：下一屏（章末翻页）")
  map("<C-b>", scroll("\2", false), "微信读书：上一屏（章首翻页）")
  map("<C-j>", scroll("\6", true), "微信读书：下一屏（章末翻页）")
  map("<C-k>", scroll("\2", false), "微信读书：上一屏（章首翻页）")
  map("<C-d>", scroll("\4", true), "微信读书：下半屏")
  map("<C-u>", scroll("\21", false), "微信读书：上半屏")
  map("<C-e>", scroll("\5", true), "微信读书：向下一行（章末翻页）")
  map("<C-y>", scroll("\25", false), "微信读书：向上一行（章首翻页）")
  for _, key in ipairs({ "<ScrollWheelDown>", "<ScrollWheelRight>" }) do
    map(key, function()
      reader().wheel_or_turn(true)
    end, "微信读书：向下滚动（章末翻页）")
  end
  for _, key in ipairs({ "<ScrollWheelUp>", "<ScrollWheelLeft>" }) do
    map(key, function()
      reader().wheel_or_turn(false)
    end, "微信读书：向上滚动（章首翻页）")
  end
end

---Annotation keys: highlight, unhighlight and thought on the cursor line.
---(划线类键位：给光标行划线、取消划线、写想法)
---@param map fun(lhs: string, rhs: function, desc: string)
local function map_annotations(map)
  map("<leader>wa", function()
    local ok, annotations = pcall(require, "weread.annotations")
    if ok and annotations.show_chapter_summary then
      annotations.show_chapter_summary()
    end
  end, "微信读书：本章划线与想法")
  map("<leader>wh", function()
    -- no selection: the whole line under the cursor
    -- (没有选区时：光标所在的整行)
    local ok, annotations = pcall(require, "weread.annotations")
    if ok then
      local current = vim.api.nvim_get_current_buf()
      local good, message = annotations.highlight_line(current, vim.fn.line("."))
      vim.notify(message, good and vim.log.levels.INFO or vim.log.levels.WARN)
    end
  end, "微信读书：给这一行划线")
  map("<leader>wd", function()
    local ok, annotations = pcall(require, "weread.annotations")
    if ok then
      local good, message = annotations.unhighlight(vim.api.nvim_get_current_buf(), vim.fn.line(".") - 1)
      vim.notify(message, good and vim.log.levels.INFO or vim.log.levels.WARN)
    end
  end, "微信读书：取消这条划线")
  map("<leader>wc", function()
    local ok, annotations = pcall(require, "weread.annotations")
    if not ok then
      return
    end
    local current = vim.api.nvim_get_current_buf()
    local entry = annotations.entry_at(current, vim.fn.line(".") - 1)
    if not entry then
      vim.notify("weread: 光标处没有划线，先用 <leader>wh 划一条", vim.log.levels.WARN)
      return
    end
    annotations.compose_thought(current, entry.annotation.range, entry.annotation.text or "")
  end, "微信读书：给这条划线写想法")
end

---Keys for the tools around the page: contents, reload, images, translation,
---progress sync, bookmarks, search and the boss key.
---(书页周边工具的键位：目录、重抓、插图、译文、进度回传、书签、书内搜索、老板键)
---@param map fun(lhs: string, rhs: function, desc: string)
local function map_tools(map)
  map("<leader>wt", function()
    reader().toc()
  end, "微信读书：目录")
  map("<leader>wr", function()
    reader().reload()
  end, "微信读书：重新抓取本章")
  -- the line length, a step at a time; the chapter is laid out again around the
  -- cursor (行宽，一次一档；本章围绕光标重新排版)
  map("+", function()
    reader().set_page_chars(nil, require("weread.layout").STEP * vim.v.count1)
  end, "微信读书：加宽一行")
  map("-", function()
    reader().set_page_chars(nil, -require("weread.layout").STEP * vim.v.count1)
  end, "微信读书：收窄一行")
  map("<leader>wo", function()
    local ok, image = pcall(require, "weread.image")
    if ok then
      image.hover_at_cursor()
    else
      vim.notify("weread: 图片模块未加载", vim.log.levels.WARN)
    end
  end, "微信读书：放大查看插图")
end

---@param map fun(lhs: string, rhs: function, desc: string)
---@param buf integer
local function map_session(map, buf)
  map("<leader>wy", function()
    reader().toggle_translation()
  end, "微信读书：译文（全文翻译开关）")
  map("<leader>wY", function()
    reader().toggle_translation_only()
  end, "微信读书：只看译文 / 只看原文")
  map("<leader>ws", function()
    local ok, progress = pcall(require, "weread.progress")
    if ok then
      progress.sync_now()
    end
  end, "微信读书：立即回传进度")
  map("<leader>wm", function()
    require("weread.bookmarks").toggle(buf)
  end, "微信读书：加书签 / 删书签")
  map("<leader>wk", function()
    require("weread.bookmarks").pick()
  end, "微信读书：书签列表")
  map("<leader>wf", function()
    require("weread.bookmarks").search_pick()
  end, "微信读书：书内搜索")
  map("<leader>wx", function()
    reader().hide()
  end, "微信读书：速隐（切回别的 buffer，再按 :WeReadHide 回来）")
end

---Register the chapter keymaps in a buffer.
---(在 buffer 里注册章节键位)
---
---Only once per buffer, but *not* only at creation: the installer runs again
---whenever a chapter buffer appears on screen, which is what lets a running session
---pick up keymaps added by an update.
---(每个 buffer 只注册一次，但不限于创建时：章节 buffer 每次出现在屏幕上都会再调用一次，
--- 这才让运行中的会话拿到更新里新增的键位)
---@param buf integer
---@return boolean installed
function M.install_keymaps(buf)
  buf = buf or vim.api.nvim_get_current_buf()
  if not keymaps_enabled() or not vim.api.nvim_buf_is_valid(buf) then
    return false
  end
  if vim.b[buf].weread_keymaps then
    return false
  end
  vim.b[buf].weread_keymaps = true
  local function map(lhs, rhs, desc)
    vim.keymap.set("n", lhs, rhs, { buffer = buf, silent = true, nowait = true, desc = desc })
  end
  map_visual(buf)
  -- `zz` centres the cursor line, as it does everywhere else. In page mode the
  -- window's own `zz` is undone by the pager, so the page is laid out around it.
  -- (`zz` 和别处一样让光标行居中。分页模式下窗口自带的 `zz` 会被分页器撤销，因此改为围绕光标行排这一页)
  map("zz", function()
    local pager = require("weread.pager")
    -- `{count}zz` centres line {count}, as in nvim
    -- (`{count}zz` 让第 {count} 行居中，与 nvim 一致)
    local count = vim.v.count
    if not pager.enabled() then
      vim.cmd("normal! " .. (count > 0 and tostring(count) or "") .. "zz")
      return
    end
    local win = vim.api.nvim_get_current_win()
    if count > 0 then
      local last = vim.api.nvim_buf_line_count(vim.api.nvim_win_get_buf(win))
      vim.api.nvim_win_set_cursor(win, { math.min(count, last), 0 })
    end
    pager.center(win)
  end, "微信读书：光标行居中")
  -- reading themes, lightest to darkest (阅读主题，由亮到暗)
  map("]t", function()
    require("weread.theme").cycle(vim.v.count1)
  end, "微信读书：下一个阅读主题（更暗）")
  map("[t", function()
    require("weread.theme").cycle(-vim.v.count1)
  end, "微信读书：上一个阅读主题（更亮）")
  map("]c", function()
    reader().next_chapter()
  end, "微信读书：下一章")
  map("[c", function()
    reader().prev_chapter()
  end, "微信读书：上一章")
  if require("weread.pager").enabled() then
    map_paged(map)
  else
    map_scrolling(map)
  end
  map("]f", function()
    M.jump_footnote(true)
  end, "微信读书：下一个脚注")
  map("[f", function()
    M.jump_footnote(false)
  end, "微信读书：上一个脚注")
  map_tools(map)
  M.claim_hover(buf)
  map_annotations(map)
  map_session(map, buf)
  return true
end

return M
