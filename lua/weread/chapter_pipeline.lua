--[[
From a catalog entry to a rendered chapter on disk.
(从目录条目到磁盘上渲染好的章节)

Split out of reader.lua. Given a chapter, this module makes sure
`<chapter>.md` and `<chapter>.map.json` exist and are current: it re-lays out the
cached source when it can, and fetches (reader page, shards, resource pack) when
it cannot. It never touches a window or a buffer; showing the result is
`reader_window`'s business.
(从 reader.lua 拆出。给定一章，本模块保证 `<章>.md` 与 `<章>.map.json` 存在且是最新的：
 能用缓存的源文重排就重排，不能才去抓取（阅读器页面、分片、资源包）。它从不碰窗口或 buffer，
 把结果显示出来是 reader_window 的事)
]]

local cache = require("weread.cache")
local config = require("weread.config")
local content = require("weread.content")
local log = require("weread.log")
local session = require("weread.session")
local timer = require("weread.timer")
local xhtml = require("weread.xhtml")

local M = {}

---Extensions an illustration can have on disk.
---(插图在磁盘上可能的扩展名)
local IMAGE_EXTS = { "png", "jpg", "jpeg", "gif", "webp", "bmp", "svg" }

---Resolve a cached image id to its file on disk, if it is there.
---(把缓存的图片 id 解析成磁盘文件)
---
---Two shapes count as cached: an entry unpacked from the chapter's resource pack
---(`<id>.<ext>`) and one the reader downloaded from a URL (`url-<id>.<ext>`).
---Extras the downloader leaves behind (`.headers`) are not illustrations.
---(两种都算已缓存：从章节资源包解出来的（`<id>.<ext>`），以及读者从 URL 下载的
--- （`url-<id>.<ext>`）。下载器留下的边角文件（`.headers`）不是插图)
---@param book_id string
---@param src string
---@return string|nil
local function cached_image_path(book_id, src)
  local id = content.image_id(src)
  local dir = cache.assets_dir(book_id)
  for _, ext in ipairs(IMAGE_EXTS) do
    for _, prefix in ipairs({ "", "url-" }) do
      local candidate = string.format("%s/%s%s.%s", dir, prefix, id, ext)
      if vim.fn.filereadable(candidate) == 1 then
        return candidate
      end
    end
  end
  return nil
end

---The map a chapter's cache carries beside its markdown.
---(章节缓存里与正文并列的那份 map)
---
---`lines` is keyed by line number in memory, and a chapter only needs attributes
---on the handful of lines that are centred, inset or coloured — the keys are
---therefore sparse, and `vim.json.encode` **refuses** a sparse array ("excessively
---sparse array"). It has to leave as an object, or the whole map fails to encode
---and the chapter loses its offset map, its styles and its headings.
---(内存里的 `lines` 以行号为键，而一章里只有少数几行需要居中/内缩/上色——于是键是稀疏的，而
--- `vim.json.encode` **拒绝**稀疏数组（"excessively sparse array"）。它必须以对象形式出去，
--- 否则整份 map 编码失败，这一章就会丢掉偏移表、样式与标题记录)
---@param converted table result of xhtml.convert
---@return table
local function map_payload(converted)
  return {
    map = converted.map,
    source_runes = converted.source_runes,
    images = converted.images,
    styles = converted.styles,
    headings = converted.headings,
    escapes = converted.escapes,
    lines = xhtml.json_lines(converted.lines),
    page_width = converted.page_width,
    footnotes = converted.footnotes,
    originals = converted.originals,
    tables = converted.tables,
    renderer = xhtml.VERSION,
    -- which translation the page shows under the original: "weread", "llm:N"
    -- (页面在原文下显示的是哪份译文："weread"、"llm:N")
    translated = converted.translated or nil,
  }
end

---Write a chapter's markdown and map, and say so when it does not work.
---(写入章节的正文与 map，写不成要说出来)
---
---Both writes used to be unchecked: the log said "re-rendered" while the map was
---never written, and the next open silently laid the chapter out again.
---(这两处写入原本都不检查结果：日志说「已重排」，而 map 其实从未写出，下次打开又静默重排一遍)
---@param book_id string
---@param chapter table
---@param converted table
---@return boolean ok
---@return string|nil err
local function write_chapter_cache(book_id, chapter, converted)
  -- The parsed map is dropped before anything is written, and again afterwards:
  -- a reader that looks in between must not keep what is about to be replaced.
  -- (写入之前丢一次已解析的 map，写完再丢一次：夹在中间读的人不能留住即将被替换的那份)
  session.invalidate_chapter_map(book_id, chapter)
  local ok, err = cache.write(cache.chapter_file(book_id, chapter, "md"), converted.text)
  if not ok then
    return false, tostring(err)
  end
  local wrote, write_err = cache.write_json(cache.chapter_file(book_id, chapter, "map.json"), map_payload(converted))
  session.invalidate_chapter_map(book_id, chapter)
  if not wrote then
    -- New text must never be paired with the previous render's offset map.
    -- (新正文绝不能配上上一版排版的偏移表)
    M.drop_cache(book_id, chapter, { "map.json" })
    return false, tostring(write_err)
  end
  return true, nil
end

---Options every render path shares, so a chapter rendered on the network path
---and one re-laid out from cache cannot disagree.
---(所有渲染路径共用的选项：走网络的章节与从缓存重排的章节因此不会给出不同结果)
---@param page_width integer
---@return table
local function render_options(page_width)
  local opts = config.get()
  return {
    page_width = page_width,
    gap = (opts.paragraph or {}).gap,
    auto_space = (opts.layout or {}).auto_space ~= false,
  }
end

---Delete cached files of a chapter, and forget the parsed map with them.
---(删掉章节的缓存文件，并把已解析的 map 一起忘掉)
---@param book_id string
---@param chapter table
---@param kinds string[] file kinds, as `cache.chapter_file` names them(文件种类，同 cache.chapter_file)
function M.drop_cache(book_id, chapter, kinds)
  for _, kind in ipairs(kinds) do
    local path = cache.chapter_file(book_id, chapter, kind)
    if vim.fn.filereadable(path) == 1 then
      vim.uv.fs_unlink(path)
    end
  end
  session.invalidate_chapter_map(book_id, chapter)
end

---Which translation the page of a chapter shows right now: nil (none),
---"weread" (the service's), or "llm:N" (the LLM's, N blocks of it so far).
---The LLM's comes first while it is complete or being made; the service's is
---the fallback.
---(这一章的页面此刻显示哪份译文：nil（不显示）、"weread"（服务端的）或 "llm:N"（大模型的，
--- 目前有 N 块）。大模型的译文完整或正在生成时优先；服务端的是兜底)
---@param book_id string
---@param chapter table
---@return string|nil
function M.translation_state(book_id, chapter)
  if not require("weread.translate").enabled(book_id) then
    return nil
  end
  local llm = require("weread.llm_translate")
  local has_weread = vim.fn.filereadable(cache.chapter_file(book_id, chapter, "trans.xhtml")) == 1
  if not llm.enabled(book_id) then
    return has_weread and "weread" or nil
  end
  -- With the LLM on, one source at a time: its own translations (complete,
  -- partial, or none yet, which is the plain original), and the service's only
  -- after the LLM gave up on the chapter.
  -- (开着大模型时只用一个来源：它自己的译文（完整的、部分的，或者还没有——那就是纯原文）；
  --  只有大模型放弃了这一章，才用服务端的)
  local data = llm.load(book_id, chapter)
  if data.failed and has_weread and not llm.running(book_id, chapter) then
    return "weread"
  end
  local count = llm.usable(book_id, chapter) and vim.tbl_count(data.items) or 0
  return count > 0 and ("llm:" .. count) or nil
end

---@param book_id string
---@param chapter table
---@return boolean
local function wants_translation(book_id, chapter)
  return M.translation_state(book_id, chapter) ~= nil
end

---Store a fetched chapter source: the book's own text where highlights and
---positions are read from, and the bilingual version beside it when the service
---sent one.
---(保存取到的章节源文：划线与位置都依据的原文，以及服务端给了时并列存放的双语版)
---@param book_id string
---@param chapter table
---@param source string
---@return string|nil original
---@return string|nil err
local function store_source(book_id, chapter, source)
  local original, bilingual = xhtml.split_translation(source)
  local wrote, err = cache.write(cache.chapter_file(book_id, chapter, "xhtml"), original)
  if not wrote then
    return nil, err
  end
  local trans_path = cache.chapter_file(book_id, chapter, "trans.xhtml")
  if bilingual then
    wrote, err = cache.write(trans_path, bilingual)
    if not wrote then
      return nil, err
    end
  elseif vim.fn.filereadable(trans_path) == 1 then
    vim.uv.fs_unlink(trans_path)
  end
  return original, nil
end

---The source a chapter is laid out from, and the translation blocks in it.
---(章节排版所用的源文，以及其中的译文块)
---@param book_id string
---@param chapter table
---@return string|nil source
---@return integer[][]|nil translations
local function render_source(book_id, chapter)
  -- A source that is not clean text was decoded from shards that did not fit
  -- together: drop it, so the chapter is fetched again instead of staying
  -- garbled for good.
  -- (源文不是干净文本，说明是由对不上的分片解出来的：丢掉它，让这一章重新抓取，
  --  而不是永远乱码下去)
  for _, kind in ipairs({ "xhtml", "trans.xhtml" }) do
    local path = cache.chapter_file(book_id, chapter, kind)
    local text = vim.fn.filereadable(path) == 1 and cache.read(path) or nil
    local bad = text and content.find_invalid_text(text, { xml = true })
    if bad then
      log.warn("dropping garbled cached %s of %s (bad byte at %d)", kind, tostring(chapter.title), bad)
      M.drop_cache(book_id, chapter, { "md", "map.json", "xhtml", "trans.xhtml" })
      return nil, nil
    end
  end
  local state = M.translation_state(book_id, chapter)
  if state and state:find("^llm:") then
    -- the LLM's translations, spliced into the original the way the service does it
    -- (大模型的译文，按服务端的方式拼进原文)
    local original = cache.read(cache.chapter_file(book_id, chapter, "xhtml"))
    if original and original ~= "" and not original:find("wr-translation", 1, true) then
      local llm = require("weread.llm_translate")
      local bilingual = llm.bilingual(original, llm.load(book_id, chapter).items)
      return bilingual, xhtml.translation_ranges(bilingual)
    end
  elseif state == "weread" then
    local bilingual = cache.read(cache.chapter_file(book_id, chapter, "trans.xhtml"))
    if bilingual and bilingual ~= "" then
      return bilingual, xhtml.translation_ranges(bilingual)
    end
  end
  local source = cache.read(cache.chapter_file(book_id, chapter, "xhtml"))
  if source and source:find("wr-translation", 1, true) then
    -- cached before translations were told apart: separate them now
    -- (区分译文之前缓存的：现在拆开)
    local stored, err = store_source(book_id, chapter, source)
    if not stored then
      error(err, 0)
    end
    source = stored
    if wants_translation(book_id, chapter) then
      return render_source(book_id, chapter)
    end
  end
  return source, nil
end

---Render a chapter from the cached source XHTML, without the network.
---(用缓存的源 XHTML 本地重排一章，不联网)
---@param book_id string
---@param chapter table
---@return boolean|nil ok nil when source must be fetched(源文需要下载时为 nil)
---@return string|nil err
local function render_from_cache(book_id, chapter)
  local source, translations = render_source(book_id, chapter)
  if not source or source == "" then
    return nil, "no cached source"
  end
  local converted = xhtml.convert(source, vim.tbl_extend("force", render_options(session.current_page_width()), {
    translations = translations,
    resolve_image = function(src)
      return cached_image_path(book_id, src)
    end,
    -- the book stylesheet is what turns `<span class="...">` back into bold
    -- (书里的样式表正是让 `<span class="...">` 恢复加粗的依据)
    css = cache.read(cache.chapter_file(book_id, chapter, "css")),
    skip_title = xhtml.repeats_title(source, chapter.title),
    title = chapter.title,
  }))
  converted.translated = translations and M.translation_state(book_id, chapter) or nil
  return write_chapter_cache(book_id, chapter, converted)
end

---Is the cached chapter rendered by the current renderer, at the page width
---the window wants right now?
---(缓存章节是否由当前渲染器产出，且符合窗口当前的版心宽度？)
---@param book_id string
---@param chapter table
---@param page_width integer|nil
---@return boolean
function M.chapter_cache_is_fresh(book_id, chapter, page_width)
  local md = cache.chapter_file(book_id, chapter, "md")
  if vim.fn.filereadable(md) ~= 1 then
    return false
  end
  -- a garbled page is laid out again, which also checks its source
  -- (乱码的页面要重排，重排时也会检查它的源文)
  if content.find_invalid_text(cache.read(md) or "") then
    return false
  end
  local meta = session.chapter_map(book_id, chapter)
  if meta == nil or meta.renderer ~= xhtml.VERSION then
    return false
  end
  -- A re-layout is cheap next to a download but not free (about 70 ms for a
  -- 103 KB chapter), while a chapter laid out for a different page width would
  -- leave the reader with truncated lines.
  -- (重排比下载便宜得多，但不是零成本（103KB 的章节约 70 毫秒）；而按别的版心宽度排出来的
  --  章节会让阅读器显示被截断的行)
  local wanted = page_width or session.current_page_width()
  -- `translated` was a boolean before the LLM's translations: true meant the service's
  -- (大模型译文之前 translated 是布尔值：true 就是服务端的)
  local shown = meta.translated == true and "weread" or meta.translated
  if shown ~= M.translation_state(book_id, chapter) then
    return false
  end
  return (tonumber(meta.page_width) or 0) == wanted
end

---Unpack the chapter's illustrations next to the book, and say which file each
---id became. A failure here must not lose the text.
---(把章节的插图解到书旁边，并说明每个 id 变成了哪个文件。这里失败不能连正文一起丢)
---@param book table
---@param chapter table
---@param assets_ok boolean
---@param assets table|string|nil
---@return table<string, string> id_to_path
local function store_images(book, chapter, assets_ok, assets)
  local id_to_path = {}
  if assets_ok and assets and assets.images then
    cache.ensure_book_dirs(book.book_id)
    for _, image in ipairs(assets.images) do
      local path = cache.assets_dir(book.book_id) .. "/" .. image.id .. "." .. image.ext
      local wrote = cache.write(path, image.data)
      if wrote then
        id_to_path[image.id] = path
      end
    end
  elseif not assets_ok then
    log.warn("asset fetch failed for %s: %s", chapter.title, tostring(assets))
    vim.notify("weread: 本章图片下载失败，正文仍可阅读", vim.log.levels.WARN)
  end
  return id_to_path
end

---Lay out a freshly fetched chapter and cache it.
---(给刚抓来的章节排版并缓存)
---@param book table
---@param chapter table
---@param result table decoded chapter: { xhtml, css }(解码后的章节)
---@param id_to_path table<string, string>
---@param page_width integer
---@return boolean ok
---@return string|nil err
local function render_fetched(book, chapter, result, id_to_path, page_width)
  -- a translated chapter comes back bilingual: the original is kept apart
  -- (翻译过的章节以双语返回：原文单独保存)
  local stored, err = store_source(book.book_id, chapter, result.xhtml)
  if not stored then
    return false, err
  end
  if result.css then
    local wrote, css_err = cache.write(cache.chapter_file(book.book_id, chapter, "css"), result.css)
    if not wrote then
      return false, css_err
    end
  end
  local source, translations = render_source(book.book_id, chapter)
  local converted = xhtml.convert(source, vim.tbl_extend("force", render_options(page_width), {
    translations = translations,
    resolve_image = function(src)
      return id_to_path[content.image_id(src)]
    end,
    css = result.css,
    skip_title = xhtml.repeats_title(source, chapter.title),
    title = chapter.title,
  }))
  converted.translated = translations and M.translation_state(book.book_id, chapter) or nil

  return write_chapter_cache(book.book_id, chapter, converted)
end

---Make sure a chapter is cached and laid out for the page width in use: from
---the cached source when there is one, from the network when there is not.
---(确保章节已缓存并按当前版心宽度排好：有缓存源文就本地重排，没有才联网)
---@param book table
---@param chapter table
---@param callback fun(ok: boolean, result: string|nil)
function M.ensure_cached(book, chapter, callback)
  local page_width = session.current_page_width()
  if M.chapter_cache_is_fresh(book.book_id, chapter, page_width) then
    callback(true, nil)
    return
  end

  -- The source XHTML is cached: re-render locally rather than re-downloading.
  -- This is what makes a typography change reach books that are already
  -- downloaded.
  -- (源 XHTML 已缓存，直接本地重排而不是重新下载——这正是让排版调整作用到已下载
  --  书籍的关键)
  local cache_ok, rendered, render_err = pcall(render_from_cache, book.book_id, chapter)
  if not cache_ok then
    rendered, render_err = false, rendered
  end
  if rendered ~= nil then
    if rendered then
      log.debug("re-rendered chapter %s from cache", chapter.title)
    else
      log.warn("could not render cached chapter %s: %s", tostring(chapter.title), tostring(render_err))
    end
    callback(rendered, render_err)
    return
  end
  log.debug("cache unusable for %s (%s); fetching", tostring(chapter.title), tostring(render_err))

  local inflight = session.state.inflight
  local key = tostring(book.book_id) .. ":" .. cache.chapter_key(chapter)
  if inflight[key] then
    table.insert(inflight[key], callback)
    return
  end
  -- This fetch answers its own waiters: a refresh may have replaced the list
  -- under `key` meanwhile, and the replaced one must still hear back.
  -- (这次下载只回应自己的等待者：期间刷新可能已经替换了 `key` 下的列表，被替换的那批也必须得到回应)
  local waiters = { callback }
  inflight[key] = waiters

  local finished = false
  local function finish(ok, result)
    if finished then
      return
    end
    finished = true
    if inflight[key] == waiters then
      inflight[key] = nil
    end
    for _, waiter in ipairs(waiters) do
      -- one waiter failing must not leave the others waiting forever
      -- (一个等待者出错不能让其他等待者永远等下去)
      local called, err = pcall(waiter, ok, result)
      if not called then
        log.error("chapter waiter failed: %s", tostring(err))
      end
    end
  end

  local function fail(message)
    log.warn("chapter fetch failed for %s/%s: %s", book.book_id, chapter.title, tostring(message))
    finish(false, message)
  end

  -- Refresh can replace this download at any asynchronous boundary.
  -- (刷新可能在任何异步边界替换本次下载)
  local function superseded()
    if inflight[key] ~= waiters then
      finish(false, "chapter request superseded")
      return true
    end
    return false
  end

  -- 1) fresh reader state; psvts is re-issued per chapter
  -- (每章重新取一次 psvts)
  content.fetch_reader_state(book.book_id, chapter.chapterUid, function(ok, reader_state)
    if superseded() then
      return
    end
    if not ok then
      fail(reader_state)
      return
    end
    book.psvts = reader_state.psvts
    book.pclts = reader_state.pclts
    book.token = reader_state.token
    if reader_state.title and reader_state.title ~= "" then
      book.title = reader_state.title
    end

    local shard_book = {
      book_id = book.book_id,
      chapter_uid = tostring(chapter.chapterUid),
      psvts = reader_state.psvts,
    }

    -- 2) decode the chapter body
    content.fetch_chapter(shard_book, function(chapter_ok, result)
      if superseded() then
        return
      end
      if not chapter_ok then
        fail(result)
        return
      end

      -- 3) images; a failure here must not lose the text
      -- (图片失败不能连正文一起丢)
      content.fetch_assets(shard_book, chapter, function(assets_ok, assets)
        if superseded() then
          return
        end
        -- a rendering error must still reach the waiters, or the reader is left
        -- looking at the loading book
        -- (排版出错也必须通知等待者，否则读者会一直看着加载中的书本)
        local called, rendered, err = pcall(function()
          local id_to_path = store_images(book, chapter, assets_ok, assets)
          return render_fetched(book, chapter, result, id_to_path, page_width)
        end)
        if called and rendered then
          finish(true, nil)
        else
          fail(called and err or rendered)
        end
      end)
    end)
  end)
end

---@param book table
---@param index integer
---@param callback fun(ok: boolean, result: string|nil)|nil
function M.prefetch(book, index, callback)
  local chapter = session.chapters()[index]
  if not chapter or not session.is_readable(chapter) then
    if callback then
      callback(true, nil)
    end
    return
  end
  M.ensure_cached(book, chapter, function(ok, result)
    if ok then
      log.debug("prefetched chapter %s", chapter.title)
    end
    if callback then
      callback(ok, result)
    end
  end)
end

---How long after opening a chapter the next one is prefetched, which is also how
---long the reader must have been quiet for it to go ahead. Fields rather than
---constants so a spec can shrink them.
---(打开一章之后多久预取下一章，同时也是读者要安静多久才放行。做成字段而不是常量，
--- spec 里才能把它缩短)
M.PREFETCH_DELAY_MS = 800

---How many times a prefetch gives way to a reader who is still turning pages
---before it is dropped. The next page turn schedules a new one anyway.
---(预取最多让路几次给还在翻页的读者，之后就放弃。下一次翻页本来就会再排一个)
M.PREFETCH_MAX_DEFERRALS = 5

---Has the reader stopped pressing keys for a moment? A prefetch lays a chapter
---out on the main loop (about 70 ms for a 103 KB one), which lands as a stall
---in the middle of a page turn.
---(读者是否已经停下按键一会儿？预取要在主循环上给整章排版（103KB 的章节约 70 毫秒），
--- 落在翻页途中就是一次卡顿)
---@return boolean
local function reader_is_idle()
  local ok, progress_state = pcall(require, "weread.progress_state")
  if not ok or type(progress_state) ~= "table" or type(progress_state.last_input) ~= "number" then
    return true
  end
  return vim.uv.now() - progress_state.last_input >= M.PREFETCH_DELAY_MS
end

local pending_prefetch = nil

---Cancel the delayed prefetch when the reader chooses another chapter.
---(读者选择另一章时取消延迟预取)
function M.cancel_prefetch()
  timer.stop(pending_prefetch)
  pending_prefetch = nil
end

---Prefetch a chapter once the reader has settled: not while keys are still
---arriving, and not at all for a book that has been swapped out meanwhile.
---(等读者安顿下来再预取：按键还在来的时候不做；期间书被换掉了就干脆不做)
---
---The book is remembered by id, not by table: the prefetch used to read
---`state.book` when its timer fired, so a book opened within the delay got the
---previous book's catalog index applied to it.
---(书按 id 记，而不是按表：预取原本在定时器触发时才去读 state.book，于是延迟期间打开的
--- 另一本书会被套上上一本书的目录序号)
---@param book table
---@param index integer
function M.schedule_prefetch(book, index)
  M.cancel_prefetch()
  local book_id = tostring(book.book_id)
  local deferrals = 0
  local function attempt()
    pending_prefetch = nil
    local current = session.state.book
    if not current or tostring(current.book_id) ~= book_id then
      return
    end
    if not reader_is_idle() then
      deferrals = deferrals + 1
      if deferrals > M.PREFETCH_MAX_DEFERRALS then
        log.debug("prefetch of chapter %d given up: the reader keeps turning pages", index)
        return
      end
      pending_prefetch = timer.defer(attempt, M.PREFETCH_DELAY_MS)
      return
    end
    M.prefetch(current, index)
  end
  pending_prefetch = timer.defer(attempt, M.PREFETCH_DELAY_MS)
end

M.cached_image_path = cached_image_path

return M
