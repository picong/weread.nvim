--[[
Putting a chapter on screen: the buffer, the window around it, the winbar.
(把一章放到屏幕上：buffer、围着它的窗口、winbar)

Split out of reader.lua. Nothing here fetches anything: a chapter is already on
disk by the time `display_chapter` runs, and this module only turns the cached
files into what the reader sees.
(从 reader.lua 拆出。这里什么都不联网：`display_chapter` 运行时章节已经在磁盘上，
 本模块只负责把缓存文件变成读者看到的样子)
]]

local cache = require("weread.cache")
local config = require("weread.config")
local layout = require("weread.layout")
local log = require("weread.log")
local session = require("weread.session")
local xhtml = require("weread.xhtml")

local M = {}

---Window options the reader changes. They are only ever set locally, so the
---global values stay the user's and are what a non-chapter window goes back to.
---(阅读器改动的窗口选项。它们只按局部设置，全局值始终是用户自己的，非章节窗口就还原成它)
local READING_OPTIONS = {
  "number", "relativenumber", "signcolumn", "foldcolumn", "wrap", "linebreak",
  "breakindent", "list", "spell", "smoothscroll", "scrolloff", "cursorline",
  "cursorlineopt", "conceallevel", "concealcursor", "colorcolumn", "statusline",
  "statuscolumn", "winbar", "fillchars", "winhighlight",
}

---Set a window option for this window only: `vim.wo[win].x = v` sets the
---global value as well, which then leaks into every new window and buffer.
---(只给这个窗口设选项：`vim.wo[win].x = v` 连全局值一起设，之后会漏到每个新窗口和 buffer)
---@param win integer
---@param name string
---@param value any
local function set_local(win, name, value)
  vim.api.nvim_set_option_value(name, value, { scope = "local", win = win })
end

M.set_local = set_local

---The winbar is the book's header: title and chapter on the left, progress on
---the right, and nothing else. The key hints that used to sit here were 93 cells
---wide and made the page look like an editor again.
---(winbar 就是书页的页眉：左边书名与章节，右边进度，没有其它东西。以前放在这里的键位
--- 提示宽达 93 单元格，又把页面变回了编辑器的样子)
---@param win integer
---@param book table
---@param chapter table
---@param index integer
---@param total integer
function M.set_winbar(win, book, chapter, index, total)
  if not vim.api.nvim_win_is_valid(win) then
    return
  end
  local position = select(1, session.position_of(index))
  -- A literal `%` in a winbar must be escaped: Neovim reads it as the start of a
  -- statusline item and rejects the value otherwise.
  -- (winbar 里的字面 `%` 必须转义：Neovim 会把它当成状态栏语法的开头而整条拒绝)
  local function escape(text)
    return (text:gsub("%%", "%%%%"))
  end
  local left = escape(string.format(" %s · %s ", book.title or "微信读书", chapter.title or ""))
  -- With pages, the folio at the bottom says how far into the book; the header
  -- only says which chapter of how many.
  -- (分页时，读到全书哪里由底部页脚说；页眉只说是第几章、共几章)
  local right
  if require("weread.pager").enabled() then
    right = escape(string.format(" 第 %d / %d 章 ", position, total))
  else
    local percent = require("weread.shell").book_percent(index)
    right = escape(string.format(" %d/%d · %d%% ", position, total, percent))
  end
  local group = require("weread.theme").winbar_highlight()
  -- today's plant sits at the right end, quiet unless it is in flower
  -- (今天的植物在最右端，除非开了花，否则很安静)
  local plant = require("weread.garden").winbar_item()
  if plant ~= "" then
    plant = plant .. (group ~= "" and ("%#" .. group .. "#") or "%*")
  end
  local text = left .. "%=" .. right .. plant
  if group ~= "" then
    text = "%#" .. group .. "#" .. text
  end
  set_local(win, "winbar", text)
end

---@param buf integer
---@param book table
---@param chapter table
---@param index integer
---@param path string
function M.setup_chapter_buffer(buf, book, chapter, index, path)
  vim.bo[buf].buftype = ""
  vim.bo[buf].swapfile = false
  vim.bo[buf].filetype = "markdown"
  vim.bo[buf].modifiable = false
  vim.bo[buf].modified = false

  vim.b[buf].weread = {
    book_id = book.book_id,
    chapter_uid = tostring(chapter.chapterUid),
    chapter_index = index,
    chapter_key = cache.chapter_key(chapter),
    title = book.title,
    chapter_title = chapter.title,
    path = path,
    -- render fingerprint, so a re-render can be told apart from the buffer's
    -- current contents
    -- (渲染指纹：用来分辨 buffer 里装的是哪一版渲染)
    renderer = xhtml.VERSION,
    page_width = session.page_width(),
    translated = (session.chapter_map(book.book_id, chapter) or {}).translated,
  }

  -- keymaps go through the same installer the autocmd uses, so a buffer opened
  -- before an update still gets the keymaps an update added
  -- (键位走与 autocmd 相同的安装函数，因此更新前就打开的 buffer 也能拿到新增键位)
  require("weread.reader").install_keymaps(buf)
end

---Hand the page to the decoration plugins: quiet the ones that must not draw,
---and draw the tables and code blocks of this page.
---(把这一页交给装饰插件：压住不该画的，并画出这一页的表格与代码块)
---
---Chapter buffers are markdown, so other markdown decoration plugins try to
---draw in them: heading borders, icons and background bands are exactly what a
---page must not have.
---(章节 buffer 是 markdown，其它 markdown 装饰插件会来画东西：标题边框、图标、底色带
--- 正是书页不该有的)
---@param win integer
local function decorate(win)
  pcall(function()
    local decorations = require("weread.decorations")
    local buf = vim.api.nvim_win_get_buf(win)
    decorations.guard()
    decorations.quiet(buf)
    -- Draw the page's tables and code blocks. Deferred: the window is being set
    -- up right now, and the plugin needs the buffer on screen with a settled
    -- width before it can fold a table's cells into it.
    -- (画出这一页的表格与代码块。延后一步：此刻窗口还在装配，而插件需要 buffer 已在屏幕上、
    --  宽度已定，才能把表格的单元格折进去)
    vim.defer_fn(function()
      -- the window may show another buffer by now: never give it the page's
      -- render-markdown config (窗口此时可能已换成别的 buffer：绝不能把阅读页的配置给它)
      if vim.api.nvim_win_is_valid(win) and vim.api.nvim_win_get_buf(win) == buf and session.buffer_info(buf) then
        decorations.render(buf, win)
      end
    end, 30)
  end)
end


---Give every window that read a chapter but now shows something else the
---user's own window options back.
---(把读过章节、现在显示别的内容的窗口的选项还给用户)
---@return integer restored
function M.restore_stale()
  local restored = 0
  for _, win in ipairs(vim.api.nvim_list_wins()) do
    if vim.w[win].weread_window and not session.buffer_info(vim.api.nvim_win_get_buf(win)) then
      for _, name in ipairs(READING_OPTIONS) do
        pcall(function()
          set_local(win, name, vim.api.nvim_get_option_value(name, { scope = "global", win = win }))
        end)
      end
      vim.w[win].weread_window = nil
      restored = restored + 1
    end
  end
  return restored
end

---Apply reading-friendly window options.
---(应用适合阅读的窗口选项)
---@param win integer
function M.setup_window(win)
  vim.w[win].weread_window = true
  set_local(win, "number", false)
  set_local(win, "relativenumber", false)
  set_local(win, "signcolumn", "no")
  set_local(win, "foldcolumn", "0")
  set_local(win, "wrap", true)
  set_local(win, "linebreak", true)
  set_local(win, "breakindent", true)
  set_local(win, "list", false)
  set_local(win, "spell", false)
  -- Long lines scroll by the screen line instead of jumping a whole paragraph.
  -- (遇到长行时按屏行滚动，而不是整段跳)
  set_local(win, "smoothscroll", true)
  -- Pages are whole screens: a scroll margin would pull the next page's first
  -- lines onto this one. The `~` past the chapter's end is not part of a page.
  -- (页就是整屏：滚动边距会把下一页的头几行拉到这一页上。章末之后的 `~` 也不属于书页)
  if require("weread.pager").enabled() then
    set_local(win, "scrolloff", 0)
  end
  vim.api.nvim_win_call(win, function()
    vim.opt_local.fillchars:append({ eob = " " })
  end)
  local opts = config.get()
  -- A highlighted line across a wrapped Chinese paragraph is heavy; the winbar
  -- plus the line number already tell you where you are.
  -- (整行高亮压在折行的中文段落上很重；位置由 winbar 与行号就能看出来)
  -- "screen" marks only the row being read, which is light enough to follow
  -- (“screen” 只标出正在读的那一行，轻到可以跟着读)
  set_local(win, "cursorline", opts.cursorline == true or opts.cursorline == "screen")
  set_local(win, "cursorlineopt", opts.cursorline == "screen" and "screenline" or "both")
  set_local(win, "conceallevel", 2)
  set_local(win, "concealcursor", "n")
  -- Book page geometry: a text column with margins on both sides. The buffer is
  -- rendered to this width, so the margin is what puts the page in the middle.
  -- (书页几何：两侧留白的正文列。buffer 就是按这个宽度排的，边距负责把页放在中间)
  layout.apply(win, session.page_width())
  -- Off by default: a colorcolumn line running through the text is the opposite
  -- of a book page.
  -- (默认关闭：一条穿过正文的竖线和书页的观感相反)
  local width = tonumber(opts.text_width) or 0
  set_local(win, "colorcolumn", (width > 0 and width < vim.o.columns) and tostring(width) or "")
  decorate(win)
  -- The reading shell: fits the window out for a book page, and puts the
  -- editor's chrome back when the chapter leaves the screen.
  -- (阅读外壳：把窗口装成书页，章节离开屏幕时再把编辑器的外观放回去)
  local ok_shell, shell = pcall(require, "weread.shell")
  if ok_shell then
    if (opts.layout or {}).statusline == "window" then
      set_local(win, "statusline", shell.statusline())
    end
    shell.enter()
  end
end

---Pull a freshly rendered chapter file back into a buffer that already holds
---the previous render. Neovim will not re-read a file behind its own back, so
---`:edit!` is what actually does it — after a re-render at a new page width, and
---after `:WeReadRefresh`.
---(把重新渲染过的章节文件拉回已经有上一版内容的 buffer。Neovim 不会自己重读文件，
--- 真正做这件事的是 `:edit!`——换版心宽度重排之后、以及 `:WeReadRefresh` 之后都需要)
---@param buf integer
---@param info table buffer marker to update(要更新的 buffer 标记)
---@param book_id string
---@param chapter table
---@param force boolean|nil
function M.reload_if_stale(buf, info, book_id, chapter, force)
  local meta = session.chapter_map(book_id, chapter)
  if not meta then
    return
  end
  local same_render = info.renderer == meta.renderer
    and (tonumber(info.page_width) or 0) == (tonumber(meta.page_width) or 0)
    and info.translated == meta.translated
  if same_render and not force then
    return
  end
  local ok = pcall(vim.api.nvim_buf_call, buf, function()
    vim.cmd("silent! keepalt edit!")
  end)
  if ok then
    log.debug("reloaded chapter %s after a re-render", tostring(chapter.title))
  end
end

---Make the current window show the chapter's buffer, creating it from the cached
---markdown file the first time.
---(让当前窗口显示这一章的 buffer；第一次时由缓存的 markdown 文件建出来)
---@param book table
---@param chapter table
---@param index integer
---@param refresh boolean|nil
---@return integer buf
local function show_buffer(book, chapter, index, refresh)
  local path = cache.chapter_file(book.book_id, chapter, "md")
  local buf = session.find_chapter_buffer(book.book_id, cache.chapter_key(chapter))

  if buf ~= nil and vim.api.nvim_buf_is_valid(buf) then
    local info = session.buffer_info(buf)
    M.reload_if_stale(buf, info, book.book_id, chapter, refresh)
    local meta = session.chapter_map(book.book_id, chapter) or {}
    info.renderer = meta.renderer
    info.page_width = meta.page_width
    info.translated = meta.translated
    vim.b[buf].weread = info
    vim.api.nvim_win_set_buf(0, buf)
    return buf
  end

  buf = vim.fn.bufadd(path)
  vim.bo[buf].buflisted = true
  -- Marked *before* the file is read: reading it fires FileType, and that is the
  -- moment a markdown decoration plugin attaches — attaching is also when it
  -- registers per-buffer autocmds on CursorMoved/WinScrolled, whose callbacks no
  -- longer consult its `ignore`. Set the flag afterwards and the plugin renders
  -- on every cursor move for the rest of the chapter's life.
  -- (在读取文件**之前**就打标记：读文件会触发 FileType，而那正是 markdown 装饰插件 attach
  --  的时刻——attach 同时也是它注册 CursorMoved/WinScrolled 这类 buffer 级自动命令的时刻，
  --  而那些回调不再询问它的 `ignore`。事后再打标记，它就会在这一章的余生里每次移动光标都重画)
  vim.b[buf].weread_book = true
  pcall(function()
    local decorations = require("weread.decorations")
    decorations.quiet(buf)
    -- render-markdown draws the tables and code blocks of a page; it has to be
    -- told what it may draw before the file is read, because reading it is what
    -- makes the plugin build its per-buffer config.
    -- (表格与代码块由 render-markdown 绘制；必须在读文件之前告诉它能画什么，因为读文件正是
    --  它构建 buffer 级配置的时刻)
    decorations.prettify(buf)
  end)
  vim.fn.bufload(buf)
  vim.api.nvim_win_set_buf(0, buf)
  M.setup_chapter_buffer(buf, book, chapter, index, path)
  return buf
end

---The line a chapter should open on, from the options of the call.
---(这一章应当停在哪一行，依据调用的选项)
---@param book table
---@param chapter table
---@param buf integer
---@param opts table
---@return integer|nil
local function target_line(book, chapter, buf, opts)
  local target = tonumber(opts.line)
  if opts.at_end then
    -- arriving from below: the reader wants this chapter's last line
    -- (从下方回来：读者要的是这一章的最后一行)
    target = vim.api.nvim_buf_line_count(buf)
  end
  -- Prefer the source offset over the line number: a chapter re-rendered at a
  -- new page width has different line numbers, but the same sentences.
  -- (优先用源偏移而不是行号：换了版心宽度重排之后行号变了，句子没变)
  if opts.resume then
    local saved = cache.read_position(book.book_id)
    if saved and tostring(saved.chapter_key) == cache.chapter_key(chapter) then
      local meta = session.chapter_map(book.book_id, chapter)
      local resolved = nil
      if saved.src_from and meta then
        local remapped = xhtml.resolve(meta, saved.src_from, saved.src_from + 1)
        resolved = remapped and remapped.line and (remapped.line + 1) or nil
      end
      target = resolved or tonumber(saved.line)
    end
  end
  -- A position pulled from the service, in the source-rune coordinate the apps
  -- report: this is how a phone's reading place lands in this window.
  -- (从服务端拉来的位置，用的正是各端上报的源 rune 坐标：手机上的阅读位置就是这样
  --  落到这个窗口里的)
  if opts.source_offset then
    target = session.line_of_source(book.book_id, chapter, opts.source_offset) or target
  end
  return target
end

---Attach everything drawn over the text: highlights, bookmarks, illustrations
---and inline emphasis.
---(接上画在正文之上的所有东西：划线、书签、插图、行内强调)
---@param buf integer
---@param book table
---@param chapter table
local function attach_layers(buf, book, chapter)
  local ok, annotations = pcall(require, "weread.annotations")
  if ok and annotations.attach then
    annotations.attach(buf)
  end

  pcall(function()
    require("weread.bookmarks").render(buf)
  end)

  local ok_image, image = pcall(require, "weread.image")
  if ok_image and image.attach then
    image.attach(buf)
  end

  -- emphasis comes back as real bold/italic instead of visible `**`
  -- (强调以真正的粗体/斜体呈现，而不是把 `**` 摆在读者眼前)
  local ok_inline, inline = pcall(require, "weread.inline")
  if ok_inline and inline.attach then
    local meta = session.chapter_map(book.book_id, chapter)
    inline.attach(buf, inline.from_meta(meta), meta and meta.headings, meta and meta.lines, meta and meta.page_width, meta and meta.footnotes)
    if inline.render_escapes then
      inline.render_escapes(buf, meta and meta.escapes)
    end
  end
end

---Hide the originals of a translated chapter when the book is read as the
---translation alone, or show them again.
---(这本书只看译文时，藏起译过章节的原文；否则让它们重新显示)
---@param buf integer
---@param book table
---@param chapter table
---@return integer hidden
function M.apply_originals(buf, book, chapter)
  local translate = require("weread.translate")
  local hide = translate.enabled(book.book_id) and translate.only(book.book_id)
  local meta = session.chapter_map(book.book_id, chapter)
  return require("weread.inline").render_originals(buf, meta and meta.originals, hide)
end

---Show a chapter buffer in the current window.
---(在当前窗口显示一个章节 buffer)
---
---Runs in the window the caller picked (`reader.open_index` wraps it in
---`nvim_win_call`), so "current" here is never an accident of timing.
---(在调用方挑好的窗口里运行（reader.open_index 用 nvim_win_call 包着它），所以这里的
--- 「当前」绝不是时机造成的巧合)
---@param book table
---@param chapter table
---@param index integer
---@param opts table|nil { line = integer, at_end = boolean, resume = boolean, source_offset = integer }
function M.display_chapter(book, chapter, index, opts)
  opts = opts or {}
  local buf = show_buffer(book, chapter, index, opts.refresh)

  local win = vim.api.nvim_get_current_win()
  M.setup_window(win)
  -- repaint this window in the reading palette (chapter only, editor untouched)
  -- (把该窗口刷成阅读配色：只影响章节窗口，编辑器不受影响)
  pcall(function()
    require("weread.theme").apply(win)
  end)
  local _, total = session.position_of(index)
  M.set_winbar(win, book, chapter, index, total)

  session.state.index = index
  vim.b[buf].weread_positions = { index = index }

  -- the originals hidden before the cursor is placed: it must land on a line
  -- the page shows
  -- (先藏好原文再放光标：光标必须落在页面显示的行上)
  M.apply_originals(buf, book, chapter)
  local target = target_line(book, chapter, buf, opts)
  if target and target > 0 then
    target = require("weread.inline").shown_line(buf, math.min(target, vim.api.nvim_buf_line_count(buf)))
  end
  local paged = require("weread.pager").enabled()
  if target and target > 0 then
    local last = vim.api.nvim_buf_line_count(buf)
    vim.api.nvim_win_set_cursor(win, { math.min(target, last), 0 })
    if not paged then
      vim.cmd("normal! zz")
    end
  end

  -- Record the destination right away. `nvim_win_set_buf` above already fired
  -- BufLeave for the chapter being left, and a book keeps a single position
  -- record — last writer wins. Without this line, switching chapters stores the
  -- *previous* chapter, which is exactly the "it forgot where I was" symptom.
  -- (立刻记录目标章节：上面的 nvim_win_set_buf 已经为离开的章节触发过 BufLeave，
  --  而每本书只存一条位置记录，后写者胜。少了这一行，切章后留下的是上一章，
  --  正是「记不住我读到哪」的成因)
  session.save_position()

  attach_layers(buf, book, chapter)

  -- The page is laid out only now: the padding, illustrations and decorations
  -- attached above all change how tall a line is. Measured once more after the
  -- deferred table rendering settles, unless the reader has moved on by then.
  -- (到这里才排页：上面接上的补白、插图与装饰都会改变行高。等延后的表格渲染落定之后再量一次，
  --  除非读者那时已经翻走了)
  if paged then
    local pager = require("weread.pager")
    local line = vim.api.nvim_win_get_cursor(win)[1]
    pager.show_line(win, line, { at_end = opts.at_end })
    local top = vim.fn.line("w0", win)
    local cursor = vim.api.nvim_win_get_cursor(win)[1]
    vim.defer_fn(function()
      pager.resnap(win, buf, top, cursor, opts.at_end)
    end, 80)
  end

  local ok_progress, progress = pcall(require, "weread.progress")
  if ok_progress then
    progress.enter(require("weread.reader"))
  end
  require("weread.fx").emit("WereadChapterOpen", { buf = buf, win = win, index = index, book_id = book.book_id })
end

return M
