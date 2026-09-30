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
]]

local cache = require("weread.cache")
local config = require("weread.config")
local content = require("weread.content")
local log = require("weread.log")
local P = require("weread.protocol")
local ui = require("weread.ui")
local xhtml = require("weread.xhtml")

local M = {}

local state = {
  book = nil, -- { book_id, title, author, psvts, pclts, token }
  catalog = nil, -- { chapters = {...} }
  index = 0,
  inflight = {},
}

M.state = state

local function keymaps_enabled()
  return config.get().keymaps ~= false
end

---A chapter is readable when it carries text. WeRead lists cover and divider
---entries with `wordCount = 0`.
---(wordCount 为 0 的是封面/分页条目，不参与阅读)
---@param chapter table
---@return boolean
function M.is_readable(chapter)
  local words = tonumber(chapter.wordCount)
  if words == nil then
    return true
  end
  return words > 0
end

---@return integer[] indices of readable chapters
function M.readable_indices()
  local indices = {}
  for index, chapter in ipairs((state.catalog or {}).chapters or {}) do
    if M.is_readable(chapter) then
      indices[#indices + 1] = index
    end
  end
  return indices
end

---@param index integer
---@return integer next readable index, or the same index when there is none
function M.next_readable(index)
  local chapters = (state.catalog or {}).chapters or {}
  for candidate = index + 1, #chapters do
    if M.is_readable(chapters[candidate]) then
      return candidate
    end
  end
  return index
end

---@param index integer
---@return integer
function M.prev_readable(index)
  for candidate = index - 1, 1, -1 do
    if M.is_readable((state.catalog or {}).chapters[candidate]) then
      return candidate
    end
  end
  return index
end

---@param index integer
---@return integer position among readable chapters (1-based)
---@return integer total readable chapters
function M.position_of(index)
  local indices = M.readable_indices()
  for position, candidate in ipairs(indices) do
    if candidate == index then
      return position, #indices
    end
  end
  return 1, math.max(1, #indices)
end

-- ------------------------------------------------------------------ buffers

---@param buf integer
---@return table|nil
function M.buffer_info(buf)
  buf = buf or vim.api.nvim_get_current_buf()
  local ok, info = pcall(vim.api.nvim_buf_get_var, buf, "weread")
  if not ok or type(info) ~= "table" then
    return nil
  end
  return info
end

---@return table|nil
function M.current()
  local info = M.buffer_info()
  if not info or not state.book or state.book.book_id ~= info.book_id then
    return nil
  end
  return state
end

---@param book_id string
---@return integer|nil
function M.find_chapter_buffer(book_id, chapter_key)
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    local info = M.buffer_info(buf)
    if info and info.book_id == book_id and info.chapter_key == chapter_key then
      return buf
    end
  end
  return nil
end

local function set_winbar(win, book, chapter, index, total)
  if not vim.api.nvim_win_is_valid(win) then
    return
  end
  local position = select(1, M.position_of(index))
  local readable_total = total
  local title = string.format(
    " %s · %s  %d/%d  ]c 下一章  <leader>wt 目录 ",
    book.title or "微信读书",
    chapter.title or "",
    position,
    readable_total
  )
  vim.wo[win].winbar = title
end

---@param buf integer
---@param book table
---@param chapter table
---@param index integer
---@param path string
local function setup_chapter_buffer(buf, book, chapter, index, path)
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
  }

  if keymaps_enabled() then
    local function map(lhs, rhs, desc)
      vim.keymap.set("n", lhs, rhs, { buffer = buf, silent = true, nowait = true, desc = desc })
    end
    map("]c", function()
      M.next_chapter()
    end, "微信读书：下一章")
    map("[c", function()
      M.prev_chapter()
    end, "微信读书：上一章")
    map("<leader>wt", function()
      M.toc()
    end, "微信读书：目录")
    map("<leader>wr", function()
      M.reload()
    end, "微信读书：重新抓取本章")
    map("<leader>wo", function()
      local ok, image = pcall(require, "weread.image")
      if ok then
        image.hover_at_cursor()
      else
        vim.notify("weread: 图片模块未加载", vim.log.levels.WARN)
      end
    end, "微信读书：放大查看插图")
    map("K", function()
      local ok, annotations = pcall(require, "weread.annotations")
      if ok and annotations.show_thoughts_at_cursor then
        annotations.show_thoughts_at_cursor()
      else
        vim.notify("weread: 划线模块未加载", vim.log.levels.WARN)
      end
    end, "微信读书：查看该处想法")
    map("<leader>wa", function()
      local ok, annotations = pcall(require, "weread.annotations")
      if ok and annotations.show_chapter_summary then
        annotations.show_chapter_summary()
      end
    end, "微信读书：本章划线与想法")
    map("<leader>ws", function()
      local ok, progress = pcall(require, "weread.progress")
      if ok then
        progress.sync_now()
      end
    end, "微信读书：立即回传进度")
  end
end

---Apply reading-friendly window options.
---(应用适合阅读的窗口选项)
---@param win integer
local function setup_window(win)
  vim.wo[win].number = false
  vim.wo[win].relativenumber = false
  vim.wo[win].signcolumn = "no"
  vim.wo[win].foldcolumn = "0"
  vim.wo[win].wrap = true
  vim.wo[win].linebreak = true
  vim.wo[win].breakindent = true
  vim.wo[win].list = false
  vim.wo[win].spell = false
  vim.wo[win].cursorline = true
  vim.wo[win].conceallevel = 2
  vim.wo[win].concealcursor = "n"
  local width = tonumber(config.get().text_width) or 0
  if width > 0 and width < vim.o.columns then
    vim.wo[win].colorcolumn = tostring(width)
  end
end

---Show a chapter buffer.
---@param book table
---@param chapter table
---@param index integer
---@param opts table|nil { line = integer }
local function display_chapter(book, chapter, index, opts)
  opts = opts or {}
  local path = cache.chapter_file(book.book_id, chapter, "md")

  local buf = M.find_chapter_buffer(book.book_id, cache.chapter_key(chapter))
  local reuse = buf ~= nil and vim.api.nvim_buf_is_valid(buf)

  if reuse then
    vim.api.nvim_win_set_buf(0, buf)
  else
    buf = vim.fn.bufadd(path)
    vim.bo[buf].buflisted = true
    vim.fn.bufload(buf)
    vim.api.nvim_win_set_buf(0, buf)
    setup_chapter_buffer(buf, book, chapter, index, path)
  end

  local win = vim.api.nvim_get_current_win()
  setup_window(win)
  local _, total = M.position_of(index)
  set_winbar(win, book, chapter, index, total)

  state.index = index
  vim.b[buf].weread_positions = { index = index }

  local target = tonumber(opts.line)
  if opts.resume then
    local saved = cache.read_position(book.book_id)
    if saved and tostring(saved.chapter_key) == cache.chapter_key(chapter) then
      target = tonumber(saved.line)
    end
  end
  if target and target > 0 then
    local last = vim.api.nvim_buf_line_count(buf)
    vim.api.nvim_win_set_cursor(win, { math.min(target, last), 0 })
    vim.cmd("normal! zz")
  end

  local ok, annotations = pcall(require, "weread.annotations")
  if ok and annotations.attach then
    annotations.attach(buf)
  end

  local ok_image, image = pcall(require, "weread.image")
  if ok_image and image.attach then
    image.attach(buf)
  end
end

-- ------------------------------------------------------------------ fetching

---@param book table
---@param chapter table
---@param callback fun(ok: boolean, result: string|nil)
local function ensure_chapter_cached(book, chapter, callback)
  local md = cache.chapter_file(book.book_id, chapter, "md")
  local map = cache.chapter_file(book.book_id, chapter, "map.json")
  if vim.fn.filereadable(md) == 1 and vim.fn.filereadable(map) == 1 then
    callback(true, nil)
    return
  end

  local key = tostring(book.book_id) .. ":" .. cache.chapter_key(chapter)
  if state.inflight[key] then
    table.insert(state.inflight[key], callback)
    return
  end
  state.inflight[key] = { callback }

  local function finish(ok, result)
    local waiters = state.inflight[key] or {}
    state.inflight[key] = nil
    for _, waiter in ipairs(waiters) do
      waiter(ok, result)
    end
  end

  local function fail(message)
    log.warn("chapter fetch failed for %s/%s: %s", book.book_id, chapter.title, tostring(message))
    finish(false, message)
  end

  -- 1) fresh reader state; psvts is re-issued per chapter
  -- (每章重新取一次 psvts)
  content.fetch_reader_state(book.book_id, chapter.chapterUid, function(ok, reader_state)
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
      if not chapter_ok then
        fail(result)
        return
      end

      -- 3) images; a failure here must not lose the text
      -- (图片失败不能连正文一起丢)
      content.fetch_assets(shard_book, chapter, function(assets_ok, assets)
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

        local converted = xhtml.convert(result.xhtml, {
          resolve_image = function(src)
            return id_to_path[content.image_id(src)]
          end,
        })

        cache.write(cache.chapter_file(book.book_id, chapter, "xhtml"), result.xhtml)
        cache.write(cache.chapter_file(book.book_id, chapter, "md"), converted.text)
        cache.write_json(cache.chapter_file(book.book_id, chapter, "map.json"), {
          map = converted.map,
          source_runes = converted.source_runes,
          images = converted.images,
        })
        if result.css then
          cache.write(cache.chapter_file(book.book_id, chapter, "css"), result.css)
        end

        finish(true, nil)
      end)
    end)
  end)
end

---@param book table
---@param index integer
---@param callback fun(ok: boolean, result: string|nil)
function M.prefetch(book, index, callback)
  local chapter = ((state.catalog or {}).chapters or {})[index]
  if not chapter or not M.is_readable(chapter) then
    if callback then
      callback(true, nil)
    end
    return
  end
  ensure_chapter_cached(book, chapter, function(ok, result)
    if ok then
      log.debug("prefetched chapter %s", chapter.title)
    end
    if callback then
      callback(ok, result)
    end
  end)
end

-- ------------------------------------------------------------------ api

---Open a chapter by catalog index.
---@param index integer
---@param opts table|nil { resume = boolean, refresh = boolean }
function M.open_index(index, opts)
  opts = opts or {}
  local chapters = (state.catalog or {}).chapters or {}
  local chapter = chapters[index]
  if not chapter then
    vim.notify("weread: 章节不存在", vim.log.levels.WARN)
    return
  end
  if not M.is_readable(chapter) then
    vim.notify("weread: 该条目没有正文（多为封面或分页）", vim.log.levels.WARN)
    return
  end

  if opts.refresh then
    local key = tostring(state.book.book_id) .. ":" .. cache.chapter_key(chapter)
    for _, kind in ipairs({ "md", "map.json", "xhtml" }) do
      local path = cache.chapter_file(state.book.book_id, chapter, kind)
      if vim.fn.filereadable(path) == 1 then
        vim.uv.fs_unlink(path)
      end
    end
    state.inflight[key] = nil
  end

  ensure_chapter_cached(state.book, chapter, function(ok, result)
    if not ok then
      vim.notify("weread: " .. tostring(result), vim.log.levels.ERROR)
      return
    end
    display_chapter(state.book, chapter, index, opts)

    local next_index = M.next_readable(index)
    if next_index ~= index then
      vim.defer_fn(function()
        M.prefetch(state.book, next_index)
      end, 800)
    end
  end)
end

---Reload the chapter in the current buffer.
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
    vim.notify("weread: 已经是最后一章", vim.log.levels.INFO)
    return
  end
  local chapters = (state.catalog or {}).chapters or {}
  if not chapters[next_index] then
    return
  end
  M.open_index(next_index)
end

function M.prev_chapter()
  local info = M.buffer_info()
  local index = info and info.chapter_index or state.index
  local prev_index = M.prev_readable(index)
  if prev_index == index then
    vim.notify("weread: 已经是第一章", vim.log.levels.INFO)
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
function M.toc()
  local chapters = (state.catalog or {}).chapters or {}
  if #chapters == 0 then
    vim.notify("weread: 目录为空", vim.log.levels.WARN)
    return
  end

  local items = {}
  local current = state.index
  local indices = M.readable_indices()
  local order = {}
  for position, chapter_index in ipairs(indices) do
    order[chapter_index] = position
  end

  for index, chapter in ipairs(chapters) do
    if M.is_readable(chapter) then
      local marker = index == current and "▶" or " "
      items[#items + 1] = {
        text = string.format("%s %s", marker, chapter.title or "(无标题)"),
        index = index,
        position = order[index],
      }
    end
  end

  ui.select({
    title = string.format("%s · 目录（%d 章）", state.book and state.book.title or "微信读书", #items),
    items = items,
    format = "text",
    on_choice = function(item)
      M.open_index(item.index)
    end,
  })
end

-- ------------------------------------------------------------------ loading

---Load a book's metadata and catalog, using the cache when possible.
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
  local chapters = (state.catalog or {}).chapters or {}

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

---Open a book: load it, then either show the TOC or jump straight in.
---(打开一本书：先加载，然后进目录或直接续读)
---@param book_id string|number
---@param opts table|nil { toc = boolean, refresh = boolean, index = integer }
function M.open_book(book_id, opts)
  opts = opts or {}
  M.load_book(book_id, { refresh = opts.refresh }, function(ok, book)
    if not ok then
      vim.notify("weread: " .. tostring(book), vim.log.levels.ERROR)
      return
    end
    vim.notify(
      string.format("weread: 已加载《%s》(%s)", book.title or "?", book.author or "未知作者"),
      vim.log.levels.INFO
    )
    if opts.toc then
      M.toc()
      return
    end
    local index = opts.index or M.start_index()
    M.open_index(index, { resume = true })
  end)
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
      vim.notify("weread: 书架为空", vim.log.levels.INFO)
      return
    end

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

    ui.select({
      title = "微信读书 · 书架（" .. #items .. " 本，按最近阅读排序）",
      items = items,
      on_choice = function(item)
        M.open_book(item.book.book_id, { toc = true })
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
        M.open_book(item.book.book_id, { toc = true })
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
    M.open_book(query, { toc = true })
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

-- ------------------------------------------------------------------ autocmds

---Persist the reading position when a chapter buffer loses focus.
---(章节 buffer 失焦时保存阅读位置)
local function save_position()
  local buf = vim.api.nvim_get_current_buf()
  local info = M.buffer_info(buf)
  if not info then
    return
  end
  pcall(cache.write_position, info.book_id, {
    chapter_key = info.chapter_key,
    chapter_index = info.chapter_index,
    chapter_uid = info.chapter_uid,
    line = vim.fn.line("."),
    total_lines = vim.api.nvim_buf_line_count(buf),
    updated_at = os.time(),
  })
end

local group = vim.api.nvim_create_augroup("weread_reader", { clear = true })
vim.api.nvim_create_autocmd({ "BufLeave", "WinLeave", "VimLeavePre" }, {
  group = group,
  callback = save_position,
})

return M
