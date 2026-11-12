--[[
Reader: one buffer per chapter, backed by the on-disk cache.
(阅读器：一章一个 buffer，内容来自磁盘缓存)

Buffer model
(缓冲区模型)

* A chapter is rendered once into `<data>/books/<id>/chapters/003.md` together
  with `003.map.json` (the offset map) and `003.xhtml` (the raw source).
* The buffer is that markdown file, made `nomodifiable` so reading never turns
  into editing. The winbar carries the book/chapter context instead of the file
  path.
* Opening a chapter that is already cached costs one file read; a fresh chapter
  costs one reader-page request, four shard requests and one tarball.
  (已缓存的章节只需一次文件读取；新章节需要一次阅读器页面请求、四次分片请求和
   一次资源包下载)

Layout of the reader
(阅读器的分工)

This file is the facade the rest of the plugin (and the specs) talk to: opening
books and chapters, following another device, hiding, the pickers. The work it
used to do itself lives next door:

* `session`          state, catalog helpers, offset maps, the position record
* `chapter_pipeline` catalog entry -> rendered chapter on disk
* `reader_window`    chapter -> buffer and window
* `reader_keymaps`   keys and footnotes
* `reader_translate` full-text translation
* `reader_autocmds`  position memory, resize, the reading shell

Every public name stays here, re-exported, so callers did not have to change.
`reader.state` is `session.state` itself, not a copy.
(本文件是插件其余部分（以及 spec）对话的外壳：打开书与章节、跟随其它设备、速隐、选择器。
 以前它自己做的事现在放在隔壁的模块里。每个公开名字都还在这里，以再导出的方式保留，调用方
 不必改动。`reader.state` 就是 `session.state` 本身，不是副本)
]]

local cache = require("weread.cache")
local chapter_pipeline = require("weread.chapter_pipeline")
local config = require("weread.config")
local content = require("weread.content")
local layout = require("weread.layout")
local log = require("weread.log")
local P = require("weread.protocol")
local reader_autocmds = require("weread.reader_autocmds")
local reader_keymaps = require("weread.reader_keymaps")
local reader_translate = require("weread.reader_translate")
local reader_window = require("weread.reader_window")
local session = require("weread.session")
local ui = require("weread.ui")

local M = {}

local state = session.state

-- ------------------------------------------------------------------ re-exports

M.state = state

M.is_readable = session.is_readable
M.readable_indices = session.readable_indices
M.next_readable = session.next_readable
M.prev_readable = session.prev_readable
M.position_of = session.position_of

M.source_offset = session.source_offset
M.line_source = session.line_source
M.line_of_source = session.line_of_source
M.footnotes = session.footnotes
M.buffer_info = session.buffer_info
M.current = session.current
M.find_chapter_buffer = session.find_chapter_buffer
M.page_width = session.page_width
M.set_page_width = session.set_page_width

M.show_footnote = reader_keymaps.show_footnote
M.jump_footnote = reader_keymaps.jump_footnote
M.hover = reader_keymaps.hover
M.claim_hover = reader_keymaps.claim_hover
M.install_keymaps = reader_keymaps.install_keymaps

M.prefetch = chapter_pipeline.prefetch
M.auto_translate = reader_translate.auto_translate
M.toggle_translation = reader_translate.toggle_translation
M.toggle_translation_only = reader_translate.toggle_translation_only
M.resized_split = reader_autocmds.resized_split

-- ------------------------------------------------------------------ scrolling

---Lines one wheel notch scrolls, from `layout.mousescroll`.
---(滚轮一格滚动几行，取自 layout.mousescroll)
---
---The config always carries a value (its defaults are merged in), so there is
---no second default spelled out here.
---(配置里一定有这个值（默认值已合并进去），所以这里不再写第二份默认)
---@return integer
function M.wheel_lines()
  local spec = tostring((config.get().layout or {}).mousescroll)
  return math.max(1, tonumber(spec:match("ver%s*:%s*(%d+)")) or 1)
end

---Run a scroll motion, and turn the page when it could not move.
---(执行一次滚动动作；动不了就翻页)
---
---The movement test is what tells a page edge from an ordinary scroll: the
---cursor and the top line are both checked, so motions that move only the view
---(`<C-e>`) or only the cursor (`gj`) are recognised as movement.
---(「有没有动」是区分页边与普通滚动的依据：光标与首行都检查，因此只移视图（`<C-e>`）
--- 或只移光标（`gj`）都算动过)
---@param key string motion to run when it can move(能移动时执行的动作)
---@param forward boolean
---@param count integer|nil defaults to the count the key was pressed with
---@return boolean moved_or_turned
function M.scroll_or_turn(key, forward, count)
  count = math.max(1, tonumber(count) or tonumber(vim.v.count1) or 1)
  local before_line, before_top = vim.fn.line("."), vim.fn.line("w0")
  if key == "gj" or key == "gk" then
    -- past lines that take no rows (hidden originals, wrapped table rows)
    -- (跨过不占屏行的行：藏起的原文、折行的表格行)
    require("weread.pager").step(vim.api.nvim_get_current_win(), key == "gj", count)
  else
    vim.cmd("normal! " .. tostring(count) .. key)
  end
  local moved = vim.fn.line(".") ~= before_line or vim.fn.line("w0") ~= before_top
  if moved then
    return true
  end
  if not M.auto_next() then
    return false
  end
  return M.turn(forward)
end

---The mouse wheel: scroll a few screen lines, and turn the page when the wheel
---keeps turning at either end.
---(鼠标滚轮：滚动几行；在两端继续滚就翻页)
---
---Scrolling is judged by what is *visible*, not by whether the cursor moved:
---`<C-e>` can keep scrolling past the last line, filling the window with empty
---space that no reader asked for. Once the end of the chapter is on screen,
---another notch down is a request for the next chapter.
---(滚动按「屏幕上还能不能露出新内容」判断，而不是看光标有没有动：`<C-e>` 可以一直滚过
--- 最后一行，把窗口填满没人要的空白。章末已经在屏幕上之后，再往下一格就是要下一章)
---@param forward boolean
---@param count integer|nil
---@return boolean
function M.wheel_or_turn(forward, count)
  count = math.max(1, tonumber(count) or M.wheel_lines())
  if forward and vim.fn.line("w$") >= vim.api.nvim_buf_line_count(0) and M.auto_next() then
    return M.turn(true)
  end
  if not forward and vim.fn.line("w0") <= 1 and M.auto_next() then
    return M.turn(false)
  end
  return M.scroll_or_turn(forward and "\5" or "\25", forward, count)
end

-- ------------------------------------------------------------------ api

---Remote position waiting for the reader to come back to the book.
---(等读者回到书里再跳的远端位置)
local pending_remote = nil

---Tell the progress module that a remote jump will not land, so it stops
---holding back this book's reports.
---(告诉进度模块这次远端跳转落不了地，让它不再扣住这本书的上报)
---@param remote table|nil
local function release_remote(remote)
  if not remote then
    return
  end
  local ok_progress, progress = pcall(require, "weread.progress")
  if ok_progress and progress.undefer then
    progress.undefer(remote)
  end
end

---Does the window still show the book a pending chapter belongs to?
---(窗口里显示的还是不是这个待显示章节所属的书？)
---@param win integer
---@param book_id string
---@return boolean
local function window_shows_book(win, book_id)
  local showing = vim.api.nvim_win_is_valid(win) and session.buffer_info(vim.api.nvim_win_get_buf(win))
  return showing and tostring(showing.book_id) == tostring(book_id) or false
end

---Open a chapter by catalog index.
---(按目录序号打开一章)
---
---The window is fixed when the call is made: the chapter may have to be
---downloaded first, and by the time it arrives "the current window" can be a
---different one (or none: a picker that closed, a split that was dropped).
---(窗口在调用的那一刻就定下来：章节可能要先下载，等它到了，「当前窗口」可能已经是另一个
--- （甚至没有了：关掉的选择器、被关掉的分屏）)
---The loading book playing over each window, so a second open replaces it.
---(每个窗口上正在播放的加载书本，第二次打开会替换它)
---@type table<integer, table>
local loading_books = {}

---@param index integer
---@param opts table|nil { resume = boolean, refresh = boolean, win = integer, remote = table }
function M.open_index(index, opts)
  opts = opts or {}
  -- A session that never went through load_book (a restored buffer, a command
  -- run in a fresh editor) still needs a page width before anything is rendered.
  -- (没走过 load_book 的情况——恢复的 buffer、在新编辑器里直接跑命令——在渲染之前
  --  同样需要先定下版心宽度)
  if not session.page_width() then
    session.set_page_width(layout.page_width(vim.api.nvim_get_current_win()))
  end
  local chapter = session.chapters()[index]
  if not chapter then
    vim.notify("weread: 章节不存在", vim.log.levels.WARN)
    return
  end
  if not session.is_readable(chapter) then
    vim.notify("weread: 该条目没有正文（多为封面或分页）", vim.log.levels.WARN)
    return
  end

  local book = state.book
  local win = opts.win or vim.api.nvim_get_current_win()
  if not book or not vim.api.nvim_win_is_valid(win) then
    release_remote(opts.remote)
    return
  end
  local origin_buf = vim.api.nvim_win_get_buf(win)
  -- Window-local generations let only the latest choice display its result.
  -- (窗口局部代次保证只有最后一次选择能显示结果)
  local request = (vim.w[win].weread_request or 0) + 1
  vim.w[win].weread_request = request
  chapter_pipeline.cancel_prefetch()

  if opts.refresh then
    local key = tostring(book.book_id) .. ":" .. cache.chapter_key(chapter)
    chapter_pipeline.drop_cache(book.book_id, chapter, { "md", "map.json", "xhtml", "trans.xhtml", "css" })
    state.inflight[key] = nil
  end

  -- A pixel book while the chapter is fetched. It waits a moment before showing,
  -- so a chapter from the cache never flashes it.
  -- (下载章节时的像素书本。它会先等一会儿再出现，所以缓存里的章节不会闪出它)
  local fx = require("weread.fx")
  fx.stop(loading_books[win])
  local loading = require("weread.fx_effects").loading(win)
  loading_books[win] = loading
  local function stop_loading()
    fx.stop(loading)
    if loading_books[win] == loading then
      loading_books[win] = nil
    end
  end
  local called, call_err = pcall(chapter_pipeline.ensure_cached, book, chapter, function(ok, result)
    stop_loading()
    if not vim.api.nvim_win_is_valid(win) or vim.w[win].weread_request ~= request then
      release_remote(opts.remote)
      return
    end
    if not ok then
      vim.notify("weread: " .. tostring(result), vim.log.levels.ERROR)
      -- a jump that cannot land must not keep holding this book's reports
      -- (落不了地的跳转，不能一直按住这本书的上报)
      release_remote(opts.remote)
      if opts.on_fail then
        pcall(opts.on_fail, result)
      end
      return
    end
    -- The chapter is cached now. Whether it is also shown depends on what the
    -- reader did meanwhile: another book, a window that is gone, a window that
    -- moved on to something else. In each case the work is kept and the reader
    -- is left alone.
    -- (章节此刻已经缓存好了。要不要显示取决于读者这段时间做了什么：换了一本书、窗口没了、
    --  窗口换成了别的东西。无论哪种，成果留着，读者的屏幕不去打扰)
    local current = state.book
    local same_book = current ~= nil and tostring(current.book_id) == tostring(book.book_id)
    local usable = same_book and vim.api.nvim_win_get_buf(win) == origin_buf
      and (not opts.win or window_shows_book(win, current.book_id))
    if not usable then
      -- wait for the reader to come back
      -- (等读者回来)
      if opts.remote then
        pending_remote = opts.remote
      end
      return
    end
    vim.api.nvim_win_call(win, function()
      reader_window.display_chapter(current, chapter, index, opts)
    end)
    if opts.remote then
      local ok_progress, progress = pcall(require, "weread.progress")
      if ok_progress and progress.adopted then
        progress.adopted(opts.remote)
      end
    end

    local next_index = M.next_readable(index)
    if next_index ~= index then
      chapter_pipeline.schedule_prefetch(current, next_index)
    end
    -- the book's translation is on: this chapter is shown translated too
    -- (这本书开着译文：这一章也以译文显示)
    M.auto_translate(index)
  end)
  if not called then
    stop_loading()
    error(call_err, 0)
  end
end

---Reload the chapter in the current buffer.
---(重新抓取当前 buffer 里的章节)
function M.reload()
  local info = M.buffer_info()
  if not info then
    return
  end
  M.open_index(info.chapter_index, { refresh = true, line = vim.fn.line(".") })
end

function M.next_chapter()
  local info = M.buffer_info()
  local index = info and info.chapter_index or state.index
  local next_index = M.next_readable(index)
  if next_index == index then
    ui.notify("weread: 已经是最后一章", vim.log.levels.INFO, { routine = true })
    return
  end
  if not session.chapters()[next_index] then
    return
  end
  M.open_index(next_index)
end

---Is walking past the end of a chapter supposed to turn the page?
---(走到章末之外是否应该翻页)
---@return boolean
function M.auto_next()
  return (config.get().layout or {}).auto_next ~= false
end

---Turn the page into the neighbouring chapter.
---(翻页进入相邻章节)
---
---Forward opens the chapter at the top; backward opens it at the end, which is
---where a reader arriving from the top of the next chapter wants to be.
---(往后翻从章首开始；往前翻从章末开始——从下一章章首往回走的读者就在那里)
---@param forward boolean
---@return boolean turned
function M.turn(forward)
  local info = M.buffer_info()
  local index = info and info.chapter_index or state.index
  local target = forward and M.next_readable(index) or M.prev_readable(index)
  if target == index then
    -- the end of the book, or the very first chapter: stay where you are
    -- (书的末尾或第一章：就停在这里)
    -- The end of the book only when the catalog searched is this buffer's own:
    -- with two books open, `state.catalog` is the one opened last.
    -- (只有查找用的目录确实是这个 buffer 自己那本书的，才算读到书末：同时开着两本书时，
    --  `state.catalog` 是最后打开的那本)
    local own = info and state.book and tostring(info.book_id) == tostring(state.book.book_id)
    if forward and own then
      require("weread.fx").emit("WereadBookEnd", { book_id = info.book_id, index = index, chapters = #session.chapters() })
    end
    return false
  end
  M.open_index(target, { at_end = not forward })
  return true
end

function M.prev_chapter()
  local info = M.buffer_info()
  local index = info and info.chapter_index or state.index
  local prev_index = M.prev_readable(index)
  if prev_index == index then
    ui.notify("weread: 已经是第一章", vim.log.levels.INFO, { routine = true })
    return
  end
  M.open_index(prev_index)
end

---@param position integer 1-based position among readable chapters
function M.goto_readable_position(position)
  local indices = M.readable_indices()
  local index = indices[position]
  if not index then
    vim.notify("weread: 没有第 " .. tostring(position) .. " 章", vim.log.levels.WARN)
    return
  end
  M.open_index(index)
end

---Table of contents picker.
---(目录选择器)
function M.toc()
  require("weread.toc").open()
end

-- ------------------------------------------------------------------ loading

---Load a book's metadata and catalog, using the cache when possible.
---(加载书的元数据与目录，尽量用缓存)
---@param book_id string|number
---@param opts table|nil { refresh = boolean }
---@param callback fun(ok: boolean, book: table|string)
function M.load_book(book_id, opts, callback)
  if type(opts) == "function" then
    callback = opts
    opts = nil
  end
  opts = opts or {}
  book_id = tostring(book_id)

  local meta = cache.read_meta(book_id)
  local catalog = cache.read_catalog(book_id)
  -- The page width is decided once per session, from the window the chapter is
  -- about to be shown in. Every chapter of the book is laid out for it, so one
  -- reading session never mixes two page widths.
  -- (版心宽度每个会话定一次，取自即将显示章节的那个窗口。整本书都按它排版，因此同一个
  --  会话里读的书不会混用两种版心宽度)
  session.set_page_width(layout.page_width(vim.api.nvim_get_current_win()))
  if meta and catalog and not opts.refresh and (catalog.chapters and #catalog.chapters > 0) then
    state.book = meta
    state.catalog = catalog
    callback(true, meta)
    return
  end

  content.fetch_reader_state(book_id, nil, function(state_ok, reader_state)
    if not state_ok then
      callback(false, reader_state)
      return
    end
    content.fetch_catalog(book_id, function(catalog_ok, record)
      if not catalog_ok then
        callback(false, record)
        return
      end

      local book = vim.tbl_extend("force", meta or {}, {
        book_id = book_id,
        title = reader_state.title or (record.title or ""),
        author = reader_state.author or (record.author or ""),
        format = record.format,
        synckey = record.synckey,
        psvts = reader_state.psvts,
        pclts = reader_state.pclts,
        token = reader_state.token,
        progress = (reader_state.progress or {}).progress,
        remote_chapter_uid = (reader_state.progress or {}).chapterUid,
        translatable = reader_state.translatable,
        updated_at = os.time(),
      })

      state.book = book
      state.catalog = { chapters = record.chapters, synckey = record.synckey }
      cache.ensure_book_dirs(book_id)
      cache.write_meta(book_id, book)
      cache.write_catalog(book_id, state.catalog)

      callback(true, book)
    end)
  end)
end

---Index of the chapter to start from: local position, then remote progress.
---(起始章节：先看本地位置，再看远端进度)
---@return integer
function M.start_index()
  local book = state.book
  if not book then
    return 1
  end
  local chapters = session.chapters()

  local saved = cache.read_position(book.book_id)
  if saved and saved.chapter_key then
    for index, chapter in ipairs(chapters) do
      if cache.chapter_key(chapter) == saved.chapter_key and M.is_readable(chapter) then
        return index
      end
    end
  end

  local remote_uid = book.remote_chapter_uid
  if remote_uid then
    for index, chapter in ipairs(chapters) do
      if tostring(chapter.chapterUid) == tostring(remote_uid) and M.is_readable(chapter) then
        return index
      end
    end
  end

  for index, chapter in ipairs(chapters) do
    if M.is_readable(chapter) then
      return index
    end
  end
  return 1
end

---Where the reader left off, from the local record.
---(本地记录里读到哪了)
---@param book_id string
---@return integer|nil index
---@return table|nil chapter
function M.saved_position(book_id)
  local saved = cache.read_position(tostring(book_id))
  if not saved then
    return nil, nil
  end
  local chapters = session.chapters()
  local chapter = chapters[tonumber(saved.chapter_index)]
  if not chapter or not M.is_readable(chapter) then
    -- The catalog may have changed under us; fall back to matching the key.
    -- (目录可能变过，退化为按 key 匹配)
    for index, candidate in ipairs(chapters) do
      if cache.chapter_key(candidate) == saved.chapter_key and M.is_readable(candidate) then
        return index, candidate
      end
    end
    return nil, nil
  end
  return tonumber(saved.chapter_index), chapter
end

---Open the chapter a reader picked in the shelf preview's contents.
---(打开读者在书架预览目录里点中的那一章)
---@param book_id string
---@param chapter_uid string|number
---@return boolean opened false when the catalog does not know the chapter(目录里没有这一章时为 false)
local function open_picked_chapter(book_id, chapter_uid)
  for index, chapter in ipairs(session.chapters()) do
    if tostring(chapter.chapterUid) == tostring(chapter_uid) then
      M.open_index(index, {})
      return true
    end
  end
  log.warn("chapter %s not in the catalog of %s; resuming instead", tostring(chapter_uid), book_id)
  return false
end

---Where this machine says the book should resume, falling back to the service's
---position when nothing was read here.
---(本机认为这本书该从哪里续读；本机没读过时退到服务端报告的位置)
---@param book_id string
---@param book table
---@return integer|nil index
---@return table|nil chapter
---@return boolean resuming
local function resume_point(book_id, book)
  local index, chapter = M.saved_position(book_id)
  local resuming = index ~= nil

  if not index and book.remote_chapter_uid then
    -- Nothing read on this machine, but the service reports a position. That
    -- only counts as history when it is actually *past* the opening chapter:
    -- a book you have never opened still reports chapter 1.
    -- (本机没读过，但服务端报告了位置。只有确实读过了才算历史——从未打开过的书
    --  也会报告第一章)
    -- readable_indices() returns an array: indexing it is not the same as
    -- taking its first return value.
    -- (readable_indices() 返回的是数组，取下标和取「第一个返回值」不是一回事)
    local first_readable = M.readable_indices()[1] or 1
    local remote_index = M.start_index()
    if remote_index ~= first_readable then
      index = remote_index
      chapter = session.chapters()[index]
      resuming = true
    end
  end
  return index, chapter, resuming
end

---Open a book. Resumes where the reader left off, and only shows the table of
---contents when there is nothing to resume (or when asked explicitly).
---(打开一本书：优先续读到上次位置；只有没得续或明确要求时才显示目录)
---@param book_id string|number
---@param opts table|nil { toc = boolean, refresh = boolean, chapter_uid = string|number }
function M.open_book(book_id, opts)
  opts = opts or {}
  book_id = tostring(book_id)
  M.load_book(book_id, { refresh = opts.refresh }, function(ok, book)
    if not ok then
      vim.notify("weread: " .. tostring(book), vim.log.levels.ERROR)
      return
    end

    if opts.toc then
      M.toc()
      return
    end

    -- A chapter picked from the shelf preview's TOC: the reader said where to
    -- go, so neither the local record nor the service gets a say.
    -- (从书架预览目录里点的章节：读者已经说了去哪，本机记录和服务端都不再参与)
    if opts.chapter_uid ~= nil and open_picked_chapter(book_id, opts.chapter_uid) then
      return
    end

    local index, chapter, resuming = resume_point(book_id, book)

    local function open_local()
      if not resuming then
        ui.notify(
          string.format("weread: 《%s》还没有阅读记录，先看目录", book.title or "?"),
          vim.log.levels.INFO,
          { routine = true }
        )
        M.toc()
        return
      end

      index = index or M.start_index()
      chapter = chapter or session.chapters()[index]
      -- Routine: the reader can see which chapter they are in from the winbar, and
      -- this would pop up on every page turn.
      -- (例行消息：章节名在 winbar 上就有，而这条会在每次翻页时弹出)
      ui.notify(
        string.format(
          "weread: 续读《%s》· %s",
          book.title or "?",
          (chapter and chapter.title) or ("第 " .. tostring(index) .. " 章")
        ),
        vim.log.levels.INFO,
        { routine = true }
      )
      M.open_index(index, { resume = true })
    end

    -- Ask the service where this book was left before showing anything: a
    -- position from the phone must win over this machine's older one, and the
    -- enter-report below must not fire first and bury it.
    -- (显示之前先问服务端这本书读到了哪：手机上的位置要赢过本机更旧的记录，
    --  而且不能让下面 enter 上报先发出去把它埋掉)
    local ok_progress, progress = pcall(require, "weread.progress")
    if not ok_progress or config.get().sync_pull == false then
      open_local()
      return
    end
    pending_remote = nil
    progress.pull(book_id, function(remote)
      if not state.book or tostring(state.book.book_id) ~= book_id then
        -- another book was opened while this one was being asked about
        -- (问这本书的时候，读者已经打开了另一本)
        return
      end
      -- a remote chapter this catalog does not know is no reason to open nothing
      -- (目录里没有的远端章节，不能成为什么都不打开的理由)
      if remote and M.jump_to_remote(remote, { notify = true, on_fail = open_local }) then
        return
      end
      open_local()
    end)
  end)
end

---Follow a newer position from another device — but only in the window that is
---showing this book right now. Anywhere else (a code buffer, the shelf), the
---jump waits until a chapter of the book is on screen again: replacing someone's
---source file with a chapter is not a sync, it is a hijack.
---(跟随另一端更新的位置——但只在此刻正显示这本书的窗口里跳。在别处（代码 buffer、书架），
--- 跳转会等到这本书的章节再次出现在屏幕上：把别人的源文件换成章节不叫同步，叫劫持)
---@param remote table from weread.progress.pull
---@return boolean jumped
function M.follow_remote(remote)
  if remote.book_id and state.book and tostring(state.book.book_id) ~= tostring(remote.book_id) then
    -- another book's answer, arriving late
    -- (另一本书的回答，来晚了)
    return false
  end
  if not M.current() then
    pending_remote = remote
    return false
  end
  pending_remote = nil
  return M.jump_to_remote(remote, { notify = true })
end

---Apply a remote position that arrived while the reader was elsewhere.
---(读者在别处时到达的远端位置，现在补上)
---@return boolean
function M.apply_pending_remote()
  if not pending_remote or not M.current() then
    return false
  end
  local remote = pending_remote
  pending_remote = nil
  if remote.book_id and tostring(remote.book_id) ~= tostring(state.book.book_id) then
    return false
  end
  local ok, progress = pcall(require, "weread.progress")
  if ok and not progress.remote_is_newer(tostring(state.book.book_id), remote) then
    return false
  end
  return M.jump_to_remote(remote, { notify = true })
end

---Open the chapter and offset a remote device left the book at.
---(打开其他端留下进度的那一章、那一句)
---
---`notify` announces the jump (the resume path); background jumps stay quiet
---but still show in the winbar.
---(`notify` 会宣布跳转（续读路径）；后台跳转保持安静，winbar 上自然可见)
---@param remote table from weread.progress.pull
---@param opts table|nil { notify = boolean }
function M.jump_to_remote(remote, opts)
  opts = opts or {}
  if remote.book_id and (not state.book or tostring(state.book.book_id) ~= tostring(remote.book_id)) then
    return false
  end
  local chapters = session.chapters()
  local index = nil
  for position, chapter in ipairs(chapters) do
    if tostring(chapter.chapterUid) == tostring(remote.chapter_uid) and M.is_readable(chapter) then
      index = position
      break
    end
  end
  if not index then
    log.warn("remote chapter %s not in catalog; falling back to the local position", tostring(remote.chapter_uid))
    return false
  end
  local chapter = chapters[index]
  local ok, progress = pcall(require, "weread.progress")
  if ok and progress.cancel_debounce then
    progress.cancel_debounce()
  end
  -- The chapter may have to be downloaded first; by then the reader may be in
  -- another window, so the jump is bound to the one it was meant for.
  -- (章节可能要先下载；那时读者也许已经在别的窗口里了，因此跳转绑定在本来要跳的那个窗口)
  local win = M.current() and vim.api.nvim_get_current_win() or nil
  -- Held until the chapter is actually on screen: a download that fails or a
  -- window that moved on must not count as "the reader is there now".
  -- (扣到章节真的出现在屏幕上为止：下载失败、窗口换走了，都不能算「读者已经在那里了」)
  if ok and progress.defer then
    progress.defer(remote)
  end
  M.open_index(index, { source_offset = remote.chapter_offset, win = win, remote = remote, on_fail = opts.on_fail })
  -- the phone's place arrives at the book (手机上的位置来到书上)
  vim.schedule(function()
    require("weread.sprites").moment("phone", "跟上了其他端的进度", { win = win })
  end)
  if opts.notify then
    -- cut by characters: a byte cut splits a Chinese character in half
    -- (按字符截断：按字节截会把汉字切成两半)
    local summary = vim.fn.strcharpart(vim.trim(tostring(remote.summary or "")), 0, 12)
    ui.notify(
      string.format("weread: 已跳到其他端进度 · %s%s", chapter.title or "", summary ~= "" and (" · " .. summary) or ""),
      vim.log.levels.INFO
    )
  end
  return true
end

---Close every chapter buffer of the current book.
---(关闭当前书的全部章节 buffer)
function M.close()
  if not state.book then
    return
  end
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    local info = M.buffer_info(buf)
    if info and info.book_id == state.book.book_id then
      pcall(vim.api.nvim_buf_delete, buf, { force = true })
    end
  end
end

-- ------------------------------------------------------------------ quick hide

---Chapter buffer and window hidden by M.hide, for the way back.
---(被 M.hide 藏起来的章节 buffer 与窗口，回来时用)
local hidden = nil

---A buffer to show instead of a chapter: the alternate buffer when it is an
---ordinary one, else the most recently used ordinary buffer, else a new empty
---one.
---(用来顶替章节的 buffer：交替 buffer 是普通 buffer 就用它，否则用最近用过的普通 buffer，
--- 再没有就开一个空 buffer)
---@return integer
local function cover_buffer()
  local function ordinary(buf)
    return buf > 0
      and vim.api.nvim_buf_is_valid(buf)
      and vim.bo[buf].buflisted
      and vim.bo[buf].buftype == ""
      and not M.buffer_info(buf)
  end
  local alternate = vim.fn.bufnr("#")
  if ordinary(alternate) then
    return alternate
  end
  local best, best_used = nil, -1
  for _, info in ipairs(vim.fn.getbufinfo({ buflisted = 1 })) do
    if ordinary(info.bufnr) and info.lastused > best_used then
      best, best_used = info.bufnr, info.lastused
    end
  end
  if best then
    return best
  end
  return vim.api.nvim_create_buf(true, false)
end

---Hide the book at once (老板键): the chapter window shows an ordinary buffer,
---the reading shell steps back, and reading time stops counting. Called again
---(or :WeReadHide) away from the book, it brings the chapter back.
---(一键速隐（老板键）：章节窗口换成普通 buffer，阅读外壳退场，阅读时长停止计数。
--- 离开书时再调一次（或 :WeReadHide）就把章节换回来)
---@return boolean hid true when the book was hidden, false when it was restored(藏起时为 true，恢复时为 false)
function M.hide()
  local win = vim.api.nvim_get_current_win()
  local buf = vim.api.nvim_get_current_buf()
  if M.buffer_info(buf) then
    hidden = { buf = buf, win = win }
    -- BufLeave settles the reading time and saves the place, as for any
    -- chapter switch
    -- (BufLeave 会像任何一次切章那样结算阅读时长并保存位置)
    vim.api.nvim_win_set_buf(win, cover_buffer())
    vim.cmd("redraw")
    return true
  end
  if hidden and vim.api.nvim_buf_is_valid(hidden.buf) then
    local target = vim.api.nvim_win_is_valid(hidden.win) and hidden.win or win
    vim.api.nvim_set_current_win(target)
    vim.api.nvim_win_set_buf(target, hidden.buf)
    hidden = nil
    return false
  end
  hidden = nil
  M.resume()
  return false
end

-- ------------------------------------------------------------------ entry points

---Most recently read book id, from the local position file.
---(本地记录里最近读过的书)
---@return string|nil
function M.last_book_id()
  local positions = cache.read_positions()
  local best_id, best_time = nil, -1
  for book_id, position in pairs(positions) do
    local updated = tonumber(position.updated_at) or 0
    if updated > best_time then
      best_id, best_time = book_id, updated
    end
  end
  return best_id
end

---Resume the most recently read book.
---(继续读最近那本书)
function M.resume()
  local book_id = M.last_book_id()
  if not book_id then
    vim.notify("weread: 还没有阅读记录，用 :WeRead 打开书架", vim.log.levels.INFO)
    return
  end
  M.open_book(book_id, { resume = true })
end

---Picker items for the shelf, newest read first.
---(书架选择器的条目，最近读过的在前)
---@param books table[]
---@return table[]
local function shelf_items(books)
  local positions = cache.read_positions()
  local items = {}
  for _, book in ipairs(books) do
    -- The shelf payload carries no percentage, so show what is already known
    -- locally plus the shelf's own badges instead of firing one progress
    -- request per book.
    -- (书架响应里没有百分比；改为展示本地已知位置与书架自带标记，避免对每本书
    --  都发一次进度请求)
    local position = positions[book.book_id]
    local badges = {}
    if book.finish_reading then
      badges[#badges + 1] = "已读完"
    end
    if position and position.chapter_index then
      badges[#badges + 1] = "本地读到第 " .. tostring(position.chapter_index) .. " 章"
    end
    if #badges == 0 then
      badges[#badges + 1] = "最近 " .. ui.relative_time(book.read_update_time)
    end

    items[#items + 1] = {
      text = string.format("%s · %s  [%s]", book.title, book.author ~= "" and book.author or "未知作者", table.concat(badges, ", ")),
      book = book,
    }
  end

  table.sort(items, function(left, right)
    return (left.book.read_update_time or 0) > (right.book.read_update_time or 0)
  end)
  return items
end

---Shelf picker.
---(书架选择器)
function M.pick_book()
  local gateway = require("weread.api_gateway")
  gateway.shelf(function(ok, books)
    if not ok then
      vim.notify("weread: " .. tostring(books), vim.log.levels.ERROR)
      return
    end
    if #books == 0 then
      -- An empty shelf should not be a dead end.
      -- (书架为空时不应该走进死胡同)
      vim.ui.input({ prompt = "书架为空，搜索书城：" }, function(input)
        if input and vim.trim(input) ~= "" then
          M.search_book(vim.trim(input))
        end
      end)
      return
    end

    local items = shelf_items(books)
    ui.select({
      title = "微信读书 · 书架（" .. #items .. " 本，按最近阅读排序）",
      items = items,
      -- Detail preview for the highlighted book: rating, reviews and the
      -- table of contents; uploaded books (no store life) get the TOC alone.
      -- (高亮书籍的详情预览：评分、点评与目录；自己上传的书——书城无记载——只给目录)
      preview = function(ctx)
        require("weread.preview").snacks(ctx)
      end,
      -- Alt-r cycles the review filter from the list too, without leaving it
      -- (在列表里按 Alt-r 也能切换点评筛选，不用离开列表)
      snacks = {
        actions = {
          weread_cycle_reviews = function()
            require("weread.preview").cycle_reviews()
          end,
        },
        win = {
          input = { keys = { ["<M-r>"] = { "weread_cycle_reviews", mode = { "n", "i" } } } },
          list = { keys = { ["<M-r>"] = "weread_cycle_reviews" } },
        },
      },
      on_choice = function(item)
        M.open_book(item.book.book_id, {})
      end,
    })
  end)
end

---Store search picker.
---(书城搜索选择器)
---@param keyword string
function M.search_book(keyword)
  local gateway = require("weread.api_gateway")
  gateway.search(keyword, function(ok, books)
    if not ok then
      vim.notify("weread: " .. tostring(books), vim.log.levels.ERROR)
      return
    end
    if #books == 0 then
      vim.notify("weread: 没有搜到「" .. keyword .. "」", vim.log.levels.INFO)
      return
    end
    local items = {}
    for _, book in ipairs(books) do
      items[#items + 1] = {
        text = string.format("%s · %s%s", book.title, book.author ~= "" and book.author or "未知作者", book.rating and ("  " .. book.rating) or ""),
        book = book,
      }
    end
    ui.select({
      title = "微信读书 · 搜索「" .. keyword .. "」（" .. #items .. " 条）",
      items = items,
      on_choice = function(item)
        M.open_book(item.book.book_id, {})
      end,
    })
  end)
end

---Resolve a user supplied book reference: a numeric id, an MP book id or a title.
---(解析用户传入的书籍引用：数字 id、MP 书号或书名)
---@param query string
function M.open_query(query)
  query = vim.trim(query or "")
  if query == "" then
    M.resume()
    return
  end
  if query:match("^%d+$") or P.is_mp_book(query) then
    M.open_book(query, {})
    return
  end
  if query:match("^https?://") then
    local book_id = query:match("/web/reader/([%w_-]+)") or query:match("bookId=([%w_-]+)")
    if book_id then
      M.open_query(book_id)
      return
    end
  end
  M.search_book(query)
end

---Change the line length while reading and lay the chapter out again around the
---sentence the cursor is on. The choice is remembered unless the config names a
---line length itself.
---(阅读中改行宽，并围绕光标所在的句子重排本章。除非配置里自己写了行宽，这个选择会被记住)
---@param chars integer|nil new line length in characters; nil keeps the current one(新行宽（汉字数）；nil 表示不变)
---@param delta integer|nil change relative to the current line length(相对当前行宽的增减)
---@return integer|nil chars applied(实际施加的行宽)
function M.set_page_chars(chars, delta)
  local opts = config.get().layout
  local current = tonumber(opts.page_chars) or layout.defaults.page_chars
  local win = vim.api.nvim_get_current_win()
  if opts.adaptive or current <= 0 then
    -- start from what is on screen, not from a number the reader never saw
    -- (从屏幕上实际的宽度开始，而不是读者没见过的那个数)
    current = math.floor((session.page_width() or layout.page_width(win)) / 2)
  end
  if current <= 0 then
    -- a full-width page has no line length to step from (满宽页面没有可以步进的行宽)
    current = layout.defaults.page_chars
  end
  local wanted = layout.clamp_chars((chars or current) + (delta or 0))
  opts.page_chars = wanted
  opts.adaptive = false
  require("weread.prefs").set("page_chars", wanted)
  local width = layout.page_width(win)
  local info = M.buffer_info()
  if info and width ~= session.page_width() then
    local offset = M.source_offset(vim.api.nvim_get_current_buf(), win)
    session.set_page_width(width)
    layout.apply(win, width)
    M.open_index(info.chapter_index, { line = vim.fn.line("."), source_offset = offset })
  end
  local message = string.format("weread: 每行 %d 字", wanted)
  if width > 0 and math.floor(width / 2) < wanted then
    message = message .. string.format("（窗口只放得下 %d 字）", math.floor(width / 2))
  end
  if config.pinned("layout.page_chars") then
    message = message .. "（setup 里配置了 page_chars，重启后以配置为准）"
  end
  vim.notify(message)
  return wanted
end

---Repaint a chapter window's winbar and statusline, e.g. after a theme change
---swapped the highlight groups they refer to.
---(重画章节窗口的 winbar 与状态栏，例如主题换掉了它们引用的高亮组之后)
---@param win integer|nil
function M.repaint(win)
  win = win or vim.api.nvim_get_current_win()
  if not vim.api.nvim_win_is_valid(win) then
    return
  end
  local info = M.buffer_info(vim.api.nvim_win_get_buf(win))
  if not info or not state.book then
    return
  end
  local chapter = session.chapters()[info.chapter_index]
  if not chapter then
    return
  end
  local _, total = M.position_of(info.chapter_index)
  reader_window.set_winbar(win, state.book, chapter, info.chapter_index, total)
  local shell = require("weread.shell")
  if (config.get().layout or {}).statusline == "window" then
    vim.api.nvim_set_option_value("statusline", shell.statusline(), { scope = "local", win = win })
  end
end

-- Registered while the module loads, exactly as before the split: commands such
-- as :WeReadNext require the reader without ever calling `weread()`.
-- (和拆分之前一样在模块加载时注册：:WeReadNext 这类命令不经过 weread() 就直接 require 阅读器)
reader_autocmds.setup(M)

return M
