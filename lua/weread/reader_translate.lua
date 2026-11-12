--[[
Full-text translation of the chapter on screen.
(屏幕上这一章的全文翻译)

The LLM translates first (`weread.llm_translate`, the Claude Code gateway): the
page shows its translations as they arrive, starting at the reader's place.
When the LLM is not configured, fails or leaves the chapter incomplete, the
service's own translation (the web reader's 译文 button) is asked for and shown
instead, and the reader is told it is the fallback.
(先由大模型翻译（weread.llm_translate，Claude Code 网关）：页面从读者所在的位置开始，边到边显示。
 大模型没配、失败或没译完时，改请服务端自己的译文（Web 阅读器的「译文」按钮）来显示，并告诉读者
 这是兜底)

Split out of reader.lua. The calls that open or fetch a chapter go through the
reader facade, resolved when they run: that is where the rest of the plugin (and
the specs) hook in, and this module is loaded by the facade, so it cannot require
it while loading.
(从 reader.lua 拆出。打开或抓取章节的调用都经过阅读器外壳、并在运行时才解析：插件的其余部分
 （以及 spec）都挂在那里，而本模块是外壳加载的，加载期间不能反过来 require 它)
]]

local cache = require("weread.cache")
local chapter_pipeline = require("weread.chapter_pipeline")
local log = require("weread.log")
local session = require("weread.session")

local M = {}

---@return table the reader facade, resolved lazily(阅读器外壳，延后解析)
local function reader()
  return require("weread.reader")
end

---Cached files of a chapter that a translation changes: the source and what is
---laid out from it.
---(译文会改变的章节缓存：源文以及据它排出的版面)
local TRANSLATED_KINDS = { "md", "map.json", "xhtml", "trans.xhtml" }

---@param book_id string
---@param chapter table
local function drop_translated_cache(book_id, chapter)
  chapter_pipeline.drop_cache(book_id, chapter, TRANSLATED_KINDS)
end

---@param book_id string
---@param chapter table
---@return boolean
local function has_translation(book_id, chapter)
  return vim.fn.filereadable(cache.chapter_file(book_id, chapter, "trans.xhtml")) == 1
end

---@param book_id string
---@param chapter table
---@return boolean
local function has_llm_translation(book_id, chapter)
  return require("weread.llm_translate").preferred(book_id, chapter)
end

---Should a model be asked to translate the open book's chapters? It is when
---the reader picked one for the book (or the config does), and there is an
---endpoint and a key (by default the Claude Code gateway).
---(该不该请大模型翻译这本书的章节：读者给这本书选了模型（或配置里定了），并且有地址和 key
--- （默认是 Claude Code 网关）)
---@return boolean
local function llm_enabled()
  local book = session.state.book
  return book ~= nil and require("weread.llm_translate").enabled(book.book_id)
end

---Does a chapter need no more translating? With the LLM: its translation is
---complete, or it gave up and the service's is there. Without: the service's
---is there. (`a and b or c` would not do: a false `b` falls through to `c`,
---and a chapter the LLM has half done passed for finished.)
---(某章是否不用再翻：用大模型时，它已译完，或者它放弃了而服务端译文在；不用大模型时，服务端
--- 译文在。不能写成 `a and b or c`：b 为假时会落到 c，翻了一半的章节就被当成译完了)
---@param book_id string
---@param chapter table
---@return boolean
local function translated(book_id, chapter)
  if not llm_enabled() then
    return has_translation(book_id, chapter)
  end
  if has_llm_translation(book_id, chapter) then
    return true
  end
  return require("weread.llm_translate").load(book_id, chapter).failed == true and has_translation(book_id, chapter)
end


---Chapters already translated automatically (or prepared ahead) this session,
---so a chapter the service will not translate is not asked about on every visit.
---(本会话已自动翻译（或预先备好）过的章节：服务端不肯翻的章节不会每次进入都再问一遍)
local auto_tried = {}
local ahead_tried = {}

---@param book_id string
---@param chapter table
---@return string
local function translation_key(book_id, chapter)
  return tostring(book_id) .. ":" .. cache.chapter_key(chapter)
end

---The chapters to ask the service for: this one and the one after it, as the
---web reader does.
---(向服务端请求的章节：本章与下一章，与 Web 阅读器一致)
---@param index integer
---@return table[]
local function translation_request(index)
  local chapters = session.chapters()
  local wanted = { chapters[index] }
  local next_index = session.next_readable(index)
  if next_index ~= index and chapters[next_index] then
    wanted[2] = chapters[next_index]
  end
  return wanted
end

---Fetch a chapter again, bilingual, without showing it: waits for a fetch that
---is already under way, and only drops the cache when it came back without the
---translation.
---(在后台把一章重新取成双语版而不显示：先等已在进行的抓取，取回来仍没有译文才丢缓存重取)
---@param book table
---@param index integer
local function fetch_bilingual(book, index)
  local chapter = session.chapters()[index]
  if not chapter then
    return
  end
  reader().prefetch(book, index, function()
    if has_translation(book.book_id, chapter) then
      return
    end
    drop_translated_cache(book.book_id, chapter)
    reader().prefetch(book, index)
  end)
end

---Translate the chapter after `index` ahead of time, so turning the page lands
---on a translated chapter instead of waiting for one.
---(提前翻译 index 的下一章：翻页时直接落在译好的章节上，而不是再等一次翻译)
---@param index integer
local function translate_ahead(index)
  local state = session.state
  local book = state.book
  local translate = require("weread.translate")
  if not book or not translate.enabled(book.book_id) then
    return
  end
  if book.translatable == false and not llm_enabled() then
    return
  end
  local next_index = session.next_readable(index)
  local chapter = session.chapters()[next_index]
  if next_index == index or not chapter or not session.is_readable(chapter) then
    return
  end
  local key = translation_key(book.book_id, chapter)
  if has_llm_translation(book.book_id, chapter) or ahead_tried[key] then
    return
  end
  if llm_enabled() then
    ahead_tried[key] = true
    -- the LLM needs the original cached: fetch it, then translate it quietly
    -- (大模型需要缓存好的原文：先取回来，再安静地翻译)
    reader().prefetch(book, next_index, function(ok)
      if not ok or state.book ~= book or not translate.enabled(book.book_id) then
        return
      end
      require("weread.llm_translate").run(book.book_id, chapter, {
        owner = "reader",
        on_done = function(done, err)
          if not done then
            log.debug("llm translate ahead %s failed: %s", key, tostring(err))
          end
        end,
      })
    end)
    return
  end
  if has_translation(book.book_id, chapter) then
    return
  end
  ahead_tried[key] = true
  translate.ensure(book.book_id, translation_request(next_index), function(ok, result)
    if not ok then
      -- quiet: the turn into that chapter asks again, and says why if it fails
      -- (不出声：翻进那一章时会再请求一次，失败了那时再说原因)
      log.debug("translate ahead %s failed: %s", key, tostring(result))
      return
    end
    chapter.translateVersion = result
    if state.book ~= book or not translate.enabled(book.book_id) then
      return
    end
    fetch_bilingual(book, next_index)
  end)
end

---Lay the chapter on screen out again, keeping the sentence the reader is on.
---Only when it is still the chapter asked about.
---(重排屏幕上的这一章，停在读者所在的那句话上；仅当它仍是被问到的那一章)
---@param book_id string
---@param index integer
---@return boolean redrawn
local function redraw(book_id, index)
  local buf = vim.api.nvim_get_current_buf()
  local now = reader().buffer_info(buf)
  if not now or now.chapter_index ~= index or tostring(now.book_id) ~= tostring(book_id) then
    return false
  end
  local win = vim.api.nvim_get_current_win()
  local offset = reader().source_offset(buf, win)
  if not offset then
    -- no offset to come back to: laying the page out again would lose the place
    -- (没有可回到的偏移：重排会丢掉位置)
    return false
  end
  local chapter = session.chapters()[index]
  chapter_pipeline.drop_cache(book_id, chapter, { "md" })
  -- the offset, not the line: line numbers change with every batch of translations
  -- (用偏移而不是行号：每到一批译文，行号都会变)
  reader().open_index(index, { source_offset = offset })
  return true
end

---Redraws while batches arrive come at most this often, so a page being read
---is not laid out again every second.
---(批次陆续到达时最多这么久重排一次，正在读的页面不会每秒都重排)
M.REDRAW_INTERVAL_MS = 1500

local weread_chapter

---Translate a chapter with the LLM, showing its translations as they arrive;
---on failure, fall back to the service's translation.
---(用大模型翻译一章，译文边到边显示；失败时回退到服务端的译文)
---@param index integer
---@param opts table|nil { manual = boolean }
local function llm_chapter(index, opts)
  opts = opts or {}
  local state = session.state
  local book = state.book
  local chapter = session.chapters()[index]
  if not book or not chapter then
    return
  end
  local book_id = tostring(book.book_id)
  local translate = require("weread.translate")
  local llm = require("weread.llm_translate")
  auto_tried[translation_key(book_id, chapter)] = true
  local model = llm.model(book_id) or "大模型"
  vim.notify("weread: 正在用 " .. model .. " 翻译本章…", vim.log.levels.INFO)
  -- a quill writing in the corner until the chapter is done; the page stays
  -- readable meanwhile (角落里一支羽毛笔一直写到这一章译完；这期间书页照常可读)
  local fx = require("weread.fx")
  local quill = require("weread.sprites").wait("quill", "翻译中…", { switch = "translating" })
  -- Where the screen starts, read now, before anything re-renders the chapter:
  -- the prefetch below may lay it out again behind the buffer. The top of the
  -- page, not the cursor: the paragraphs above the cursor are on screen too.
  -- (这一屏从哪开始，现在就读，赶在任何重排之前：下面的预取可能在 buffer 背后重排本章。取页顶
  --  而不是光标：光标上面的段落也在屏幕上)
  local from_rune = nil
  local buf = vim.api.nvim_get_current_buf()
  local here = reader().buffer_info(buf)
  if here and here.chapter_index == index then
    from_rune = session.line_source(buf, vim.fn.line("w0")) or reader().source_offset()
  end
  local last_redraw = 0
  local pending = nil
  local function still_wanted()
    return state.book == book and translate.enabled(book_id)
  end
  local function show_progress()
    pending = nil
    last_redraw = vim.uv.now()
    if still_wanted() then
      redraw(book_id, index)
    end
  end
  reader().prefetch(book, index, function(ok, err)
    if not ok then
      fx.stop(quill)
      vim.notify("weread: 取不到本章原文：" .. tostring(err), vim.log.levels.WARN)
      return
    end
    llm.run(book_id, chapter, {
      owner = "reader",
      from_rune = from_rune,
      on_progress = function()
        if not still_wanted() or pending then
          return
        end
        local wait = math.max(0, M.REDRAW_INTERVAL_MS - (vim.uv.now() - last_redraw))
        pending = require("weread.timer").defer(show_progress, wait)
      end,
      on_done = function(done, reason, stats)
        fx.stop(quill)
        -- a uv timer, not a timer id: vim.fn.timer_stop cannot stop it
        -- (这是 uv 定时器而不是定时器 id：vim.fn.timer_stop 停不了它)
        require("weread.timer").stop(pending)
        pending = nil
        if not still_wanted() or reason == llm.CANCELLED then
          return
        end
        if done then
          redraw(book_id, index)
          vim.notify(string.format("weread: %s 已译完本章（%d 段，%.1f 秒）", model, stats.total or 0, (stats.ms or 0) / 1000), vim.log.levels.INFO)
          return
        end
        -- the LLM left the chapter unfinished: the service's translation instead
        -- (大模型没译完这一章：改用服务端的译文)
        log.warn("llm chapter translation failed: %s", tostring(reason))
        vim.notify(string.format("weread: %s 翻译失败（%s），改用微信读书译文", model, tostring(reason)), vim.log.levels.WARN)
        llm.discard(book_id, chapter)
        weread_chapter(index, vim.tbl_extend("force", opts, { fallback = true }))
      end,
    })
  end)
end

---Translate a chapter and show it bilingual once the service is done; a reader
---who has moved on finds it translated when they come back.
---(翻译一章，服务端完成后以双语显示；读者已经翻走的话，回来时它已经译好了)
---@param index integer
---@param opts table|nil { manual = boolean, fallback = boolean } manual: the 译文 key, turned off again on failure; fallback: after the LLM failed(manual：手动按键，失败时关回去；fallback：大模型失败之后)
weread_chapter = function(index, opts)
  opts = opts or {}
  local state = session.state
  local book = state.book
  local chapter = session.chapters()[index]
  if not book or not chapter then
    return
  end
  local translate = require("weread.translate")
  local book_id = tostring(book.book_id)
  auto_tried[translation_key(book_id, chapter)] = true
  if book.translatable == false then
    if opts.manual or opts.fallback then
      translate.set_enabled(book_id, false)
    end
    vim.notify("weread: 这本书没有微信读书译文，无法兜底", vim.log.levels.WARN)
    return
  end
  if has_translation(book_id, chapter) then
    redraw(book_id, index)
    if opts.fallback then
      vim.notify("weread: 已显示微信读书译文（兜底）", vim.log.levels.INFO)
    end
    return
  end
  vim.notify(opts.fallback and "weread: 正在请微信读书翻译本章（兜底）…" or "weread: 正在翻译本章…", vim.log.levels.INFO)
  local quill = require("weread.sprites").wait("quill", "翻译中…", { switch = "translating" })
  translate.ensure(book_id, translation_request(index), function(ok, result)
    require("weread.fx").stop(quill)
    if not ok then
      if opts.manual then
        translate.set_enabled(book_id, false)
      end
      vim.notify("weread: 翻译失败：" .. tostring(result), vim.log.levels.WARN)
      return
    end
    chapter.translateVersion = result
    if state.book ~= book or not translate.enabled(book_id) then
      return
    end
    -- the reader may have moved on: only redraw the chapter still on screen
    -- (读者可能已经翻走了：只重画仍在屏幕上的那一章)
    local buf = vim.api.nvim_get_current_buf()
    local now = reader().buffer_info(buf)
    if not now or now.chapter_index ~= index or tostring(now.book_id) ~= book_id then
      fetch_bilingual(book, index)
      return
    end
    local win = vim.api.nvim_get_current_win()
    local line = vim.api.nvim_win_get_cursor(win)[1]
    local offset = reader().source_offset(buf, win)
    -- the cached source predates the translation: fetch it again, bilingual
    -- (缓存的源文早于译文：重新取一次，这次是双语的)
    drop_translated_cache(book_id, chapter)
    reader().open_index(index, { line = line, source_offset = offset })
    vim.notify(opts.fallback and "weread: 已显示微信读书译文（兜底）" or "weread: 已显示译文", vim.log.levels.INFO)
  end)
end

---Translate a chapter: the LLM when it is configured, the service otherwise.
---(翻译一章：配了大模型就用大模型，否则用服务端)
---@param index integer
---@param opts table|nil
local function translate_chapter(index, opts)
  if llm_enabled() then
    llm_chapter(index, opts)
  else
    weread_chapter(index, opts)
  end
end

---With the book's translation on, every chapter opened is shown translated:
---one the service has not translated yet is translated now, and the next one is
---prepared while this one is read.
---(书的译文开着时，打开的每一章都显示译文：服务端还没译的现在就译，并在读这一章时备好下一章)
---@param index integer
function M.auto_translate(index)
  local book = session.state.book
  local translate = require("weread.translate")
  if not book or not translate.enabled(book.book_id) then
    return
  end
  if book.translatable == false and not llm_enabled() then
    return
  end
  local chapter = session.chapters()[index]
  if not chapter then
    return
  end
  if translated(book.book_id, chapter) then
    translate_ahead(index)
    return
  end
  if auto_tried[translation_key(book.book_id, chapter)] then
    return
  end
  translate_chapter(index)
end

---What can translate a book's chapters, the reader's last pick first: every
---model of `lookup.chapter_models` when the LLM is set up, and WeRead's own
---translation when the book has one.
---(能翻译这本书章节的选项，读者上次选的排第一：配好大模型时是 lookup.chapter_models 里的每个模型，
--- 书有译文时再加上微信读书自己的译文)
---@param book table
---@return table[] items { text, engine }
function M.engines(book)
  local items = {}
  if require("weread.lookup").llm_available() then
    local models = (require("weread.config").get().lookup or {}).chapter_models or {}
    for _, model in ipairs(models) do
      if type(model) == "string" and model ~= "" then
        items[#items + 1] = { text = "大模型 " .. model, engine = model }
      end
    end
  end
  if book.translatable ~= false then
    items[#items + 1] = { text = "微信读书译文", engine = "weread" }
  end
  local last = require("weread.translate").engine(book.book_id)
  for index, item in ipairs(items) do
    if item.engine == last then
      item.text = item.text .. "（上次）"
      table.insert(items, 1, table.remove(items, index))
      break
    end
  end
  return items
end

---Ask the reader who translates the book, then call back with the pick. With a
---single choice there is nothing to ask.
---(问读者这本书由谁来译，选好后回调。只有一个选项时不必问)
---@param book table
---@param on_pick fun(engine: string)
local function pick_engine(book, on_pick)
  local items = M.engines(book)
  if #items == 0 then
    vim.notify("weread: 这本书没有译文（微信读书只为外文书提供全文翻译），也没有配好大模型", vim.log.levels.WARN)
    return
  end
  if #items == 1 then
    on_pick(items[1].engine)
    return
  end
  require("weread.ui").select({
    title = "用什么翻译本书",
    items = items,
    on_choice = function(item)
      on_pick(item.engine)
    end,
  })
end

---Show the translation under the original, or hide it: the 译文 button.
---(在原文下显示译文，或者收起：就是「译文」按钮)
---
---The first time a chapter is shown translated, the service is asked to
---translate it (and the next one) and polled until it is done; the chapter is
---then fetched again, bilingual. While it stays on, every chapter opened is
---translated the same way (see `auto_translate`). Turning it off needs no
---network: the original is always cached on its own.
---(某章第一次以译文显示时，先请服务端翻译它（以及下一章）并轮询到完成，再重新取一次本章——
--- 这次是双语的。开着期间，打开的每一章都这样翻译（见 auto_translate）。关闭不需要联网：原文始终单独缓存着)
---
---Turning it on first asks who translates: one of the models or WeRead's own
---translation (see `engines`); the pick is remembered for the book's later
---chapters.
---(打开时先问由谁来译：某个模型，或者微信读书自己的译文（见 engines）；选中的会用于这本书后面的章节)
---@param on boolean|nil nil flips the current state(nil 表示切换)
---@param opts table|nil { only = boolean, engine = string } only: show the translation alone, the original hidden; engine: who translates, without asking(only：只显示译文，藏起原文；engine：由谁来译，不再询问)
function M.toggle_translation(on, opts)
  opts = opts or {}
  local state = session.state
  local buf, info = nil, nil
  local current = vim.api.nvim_get_current_buf()
  if reader().buffer_info(current) then
    buf, info = current, reader().buffer_info(current)
  end
  if not info or not state.book or tostring(state.book.book_id) ~= tostring(info.book_id) then
    vim.notify("weread: 请在章节里切换译文", vim.log.levels.WARN)
    return
  end
  local translate = require("weread.translate")
  local book_id = tostring(info.book_id)
  if on == nil then
    on = not translate.enabled(book_id)
  end
  local chapter = session.chapters()[info.chapter_index]
  if not chapter then
    return
  end
  if on and not opts.engine then
    pick_engine(state.book, function(engine)
      if vim.api.nvim_get_current_buf() ~= buf then
        return
      end
      M.toggle_translation(true, vim.tbl_extend("force", opts, { engine = engine }))
    end)
    return
  end
  if on then
    translate.set_engine(book_id, opts.engine)
  end
  local win = vim.api.nvim_get_current_win()
  local line = vim.api.nvim_win_get_cursor(win)[1]
  local offset = reader().source_offset(buf, win)

  ---Lay the chapter out again for the new choice, keeping the sentence on screen.
  ---(按新的选择重排本章，停在同一句话上)
  local function show()
    chapter_pipeline.drop_cache(book_id, chapter, { "md" })
    reader().open_index(info.chapter_index, { line = line, source_offset = offset })
  end

  translate.set_enabled(book_id, on)
  translate.set_only(book_id, on and opts.only == true)
  translate.toggle_remote(book_id, on, function(ok, err)
    if not ok then
      log.warn("toggleTranslate failed: %s", tostring(err))
    end
  end)
  if not on then
    -- only what the page asked for, and only for this book: an export of this
    -- or another book goes on
    -- (只停页面为这本书发起的翻译：这本书或别的书的导出照常进行)
    require("weread.llm_translate").cancel({ owner = "reader", book_id = book_id })
    show()
    vim.notify("weread: 已收起译文", vim.log.levels.INFO)
    return
  end
  if state.book.translatable == false and not llm_enabled() then
    vim.notify("weread: 这本书没有译文（微信读书只为外文书提供全文翻译）", vim.log.levels.WARN)
    translate.set_enabled(book_id, false)
    return
  end
  -- a fresh start: chapters the service turned down before are asked again
  -- (重新开始：之前被服务端拒绝的章节再问一次)
  auto_tried, ahead_tried = {}, {}
  if translated(book_id, chapter) then
    show()
    vim.notify("weread: 已显示译文", vim.log.levels.INFO)
    translate_ahead(info.chapter_index)
    return
  end
  translate_chapter(info.chapter_index, { manual = true })
end

---Hide or show the originals in every window of the book on screen, without
---laying anything out again; the cursor leaves a line that is hidden.
---(在屏幕上这本书的每个窗口里藏起或显示原文，不重排；光标离开被藏起的行)
---@param book table
local function refresh_originals(book)
  local window = require("weread.reader_window")
  local inline = require("weread.inline")
  local done = {}
  for _, win in ipairs(vim.api.nvim_list_wins()) do
    local buf = vim.api.nvim_win_get_buf(win)
    local info = reader().buffer_info(buf)
    local chapter = info and tostring(info.book_id) == tostring(book.book_id) and session.chapters()[info.chapter_index]
    if chapter then
      if not done[buf] then
        window.apply_originals(buf, book, chapter)
        done[buf] = true
      end
      local cursor = vim.api.nvim_win_get_cursor(win)
      local line = inline.shown_line(buf, cursor[1])
      if line ~= cursor[1] then
        vim.api.nvim_win_set_cursor(win, { line, 0 })
      end
      pcall(require("weread.pager").refresh, win)
    end
  end
end

---Read the translation alone, or the original alone: the first press hides the
---original under the translation (translating the chapter first when it is
---not), the second turns the translation off and the original is back.
---(只看译文，或只看原文：第一次按把译文上方的原文藏起来（还没译就先译），再按一次关掉译文、
--- 回到原文)
---
---The original is hidden, not removed: the page is the same buffer, so the
---highlights, the reading position and the progress reported keep using the
---original's offsets.
---(原文是藏起来而不是删掉：页面还是同一个 buffer，划线、阅读位置与上报的进度照旧使用原文的偏移)
function M.toggle_translation_only()
  local state = session.state
  local info = reader().buffer_info(vim.api.nvim_get_current_buf())
  if not info or not state.book or tostring(state.book.book_id) ~= tostring(info.book_id) then
    vim.notify("weread: 请在章节里切换译文", vim.log.levels.WARN)
    return
  end
  local translate = require("weread.translate")
  local book_id = tostring(info.book_id)
  if translate.enabled(book_id) and translate.only(book_id) then
    M.toggle_translation(false)
    return
  end
  if not translate.enabled(book_id) then
    M.toggle_translation(true, { only = true })
    return
  end
  -- already bilingual: only the originals change
  -- (已经是双语：只有原文要变)
  translate.set_only(book_id, true)
  refresh_originals(state.book)
  vim.notify("weread: 只显示译文（再按一次回到原文）", vim.log.levels.INFO)
end

return M
