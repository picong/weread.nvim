--[==[
The thought panel: everything other readers wrote under one highlight.
(想法面板：其他读者在一条划线下写的全部想法)

`K` used to print the twenty thoughts the chapter load happened to fetch into a
plain popup. A hot passage has hundreds, and a popup that only grows downwards
reads like a log. The panel instead:
(K 以前把加载章节时顺带取到的 20 条想法塞进一个普通弹窗。热门段落有上百条，而只会
 往下长的弹窗读起来像日志。面板改为：)

* opens at once with what is cached, then pages through `/book/readreviews`
  until it has every thought, and remembers them for the session;
  (先用缓存立即打开，再翻页取完 `/book/readreviews` 的全部想法，并在本次会话里记住)
* lays each thought out as a card: author, likes and age on one line, the full
  text wrapped under it, mine marked as mine;
  (每条想法排成一张卡片：作者、点赞、时间在一行，下面是折行后的全文；我的想法单独标出)
* sorts by likes (the ones worth reading first) or by time, `s` toggles;
  (按点赞（值得先读的在前）或按时间排序，`s` 切换)
* cycles with `<Tab>` when the cursor line holds more than one highlight, and
  jumps between cards with `]]` / `[[`.
  (光标行上有多条划线时 `<Tab>` 切换，`]]` / `[[` 在卡片间跳转)
]==]

local chapter = require("weread.annotations_chapter")
local fetch = require("weread.annotations_fetch")
local log = require("weread.log")
local model = require("weread.annotations_model")
local render = require("weread.annotations_render")
local store = require("weread.annotations_store")
local sync = require("weread.annotations_sync")
local text_util = require("weread.text")

local M = {}

local NAMESPACE = vim.api.nvim_create_namespace("weread.thoughts")

---Fetched thought lists, keyed by `book:range`, so a second `K` is instant.
---(已取回的想法列表，按 `书:range` 记住，第二次 K 立刻就有)
---@type table<string, { thoughts: table[], total: integer|nil, at: integer }>
local fetched = {}

---How long a fetched list stays fresh.
---(取回的列表多久内算新鲜)
local FRESH_SECONDS = 600

---@param book_id string
---@param range string
---@return string
local function key_of(book_id, range)
  return tostring(book_id) .. ":" .. tostring(range)
end

---Forget every fetched list. For tests and after writing a thought.
---(清空已取回的列表；供测试与写完想法后使用)
function M.reset()
  fetched = {}
end

---@param book_id string
---@param range string
function M.invalidate(book_id, range)
  fetched[key_of(book_id, range)] = nil
end

function M.define_highlights()
  local function set(name, spec)
    spec.default = true
    vim.api.nvim_set_hl(0, name, spec)
  end
  set("WereadThoughtQuote", { link = "WereadPreviewPart" })
  set("WereadThoughtQuoteBar", { link = "WereadMineHighlight" })
  set("WereadThoughtAuthor", { link = "Title" })
  set("WereadThoughtMine", { link = "DiagnosticOk" })
  set("WereadThoughtMeta", { link = "Comment" })
  set("WereadThoughtLikes", { link = "DiagnosticWarn" })
  set("WereadThoughtRule", { link = "FloatBorder" })
  set("WereadThoughtHeader", { link = "Function" })
end

---Thoughts newest first or most liked first. Ties on likes fall back to time.
---(按最新或按点赞排序；点赞相同时再按时间)
---@param thoughts table[]
---@param order "likes"|"time"
---@return table[]
function M.sorted(thoughts, order)
  local list = vim.list_slice(thoughts, 1, #thoughts)
  table.sort(list, function(left, right)
    local left_time, right_time = tonumber(left.time) or 0, tonumber(right.time) or 0
    if order == "likes" then
      local left_likes, right_likes = tonumber(left.likes) or 0, tonumber(right.likes) or 0
      if left_likes ~= right_likes then
        return left_likes > right_likes
      end
    end
    return left_time > right_time
  end)
  return list
end

---Lines and highlights of the panel for one highlight.
---(一条划线在面板里的行与高亮)
---@param view table panel state
---@param width integer text width(正文宽度)
---@return string[] lines
---@return table[] marks `{ row, col, end_col, group }`, 0-based
---@return integer[] cards first row of every card, 0-based(每张卡片的首行，0 基)
function M.layout(view, width)
  local entry = view.entries[view.index]
  local annotation = entry.annotation
  local lines, marks, cards = {}, {}, {}

  ---@param segments table[] `{ text, group }`
  local function add(segments)
    local row, col, parts = #lines, 1, { " " }
    for _, segment in ipairs(segments or {}) do
      local text = segment[1] or ""
      if segment[2] and text ~= "" then
        marks[#marks + 1] = { row, col, col + #text, segment[2] }
      end
      parts[#parts + 1] = text
      col = col + #text
    end
    lines[#lines + 1] = #(segments or {}) == 0 and "" or table.concat(parts)
  end

  ---Left text plus right-aligned meta on one line.
  ---(左侧文字，右侧对齐的元信息)
  local function spread(left, right)
    local used = 0
    for _, segment in ipairs(left) do
      used = used + text_util.cells(segment[1] or "")
    end
    for _, segment in ipairs(right) do
      used = used + text_util.cells(segment[1] or "")
    end
    local segments = vim.list_extend(vim.list_slice(left, 1, #left), { { string.rep(" ", math.max(2, width - used)) } })
    add(vim.list_extend(segments, right))
  end

  -- the passage, as a quote (划线原文，作为引文)
  for _, line in ipairs(text_util.wrap(annotation.text or "", width - 2, 8)) do
    add({ { "┃ ", "WereadThoughtQuoteBar" }, { line, "WereadThoughtQuote" } })
  end

  local thoughts = view.thoughts or {}
  local facts = {}
  if (tonumber(annotation.count) or 0) > 0 then
    facts[#facts + 1] = string.format("%d 人划线", annotation.count)
  elseif annotation.mine then
    facts[#facts + 1] = "我的划线"
  end
  local total = math.max(#thoughts, tonumber(view.total) or 0)
  if total > 0 then
    facts[#facts + 1] = string.format("%d 条想法", total)
  end
  if #thoughts > 1 then
    facts[#facts + 1] = view.order == "likes" and "按点赞" or "按时间"
  end
  add({})
  add({ { table.concat(facts, " · "), "WereadThoughtHeader" } })
  add({ { string.rep("─", width), "WereadThoughtRule" } })

  if annotation.note and annotation.note ~= "" then
    cards[#cards + 1] = #lines
    -- Say whether the copy is already on the server: "本地" after a successful
    -- post made readers think the thought had not been synced.
    -- (说清这份副本是否已经在服务端：发表成功后仍写「本地」，会让读者以为没同步上去)
    local note_label = annotation.note_synced and "我的想法（已同步）" or "我的想法（本地）"
    add({ { note_label, "WereadThoughtMine" } })
    for _, line in ipairs(text_util.wrap(annotation.note, width - 2, 200)) do
      add({ { "  " .. line } })
    end
    add({})
  end

  if #thoughts == 0 then
    if view.uploaded then
      add({ { "自己上传的书只有你自己，没有其他读者的想法", "WereadThoughtMeta" } })
    elseif view.loading then
      add({ { "正在加载想法…", "WereadThoughtMeta" } })
    elseif view.error then
      add({ { "想法加载失败：" .. tostring(view.error), "WereadThoughtMeta" } })
    else
      add({ { "这条划线还没有想法，按 c 写下第一条", "WereadThoughtMeta" } })
    end
    return lines, marks, cards
  end

  local mine = M.my_thought({ thoughts = thoughts })
  local ui = require("weread.ui")
  for index, thought in ipairs(M.sorted(thoughts, view.order)) do
    if index > 1 then
      add({ { string.rep("┄", width), "WereadThoughtRule" } })
    end
    cards[#cards + 1] = #lines
    local is_mine = mine ~= nil and thought.id == mine.id
    local meta = {}
    if (tonumber(thought.likes) or 0) > 0 then
      meta[#meta + 1] = { "♥ " .. thought.likes, "WereadThoughtLikes" }
      meta[#meta + 1] = { "  " }
    end
    if tonumber(thought.time) then
      meta[#meta + 1] = { ui.relative_time(tonumber(thought.time)), "WereadThoughtMeta" }
    end
    local name = is_mine and "我" or text_util.fit(thought.author or "匿名", math.max(8, width - 20))
    spread({ { name, is_mine and "WereadThoughtMine" or "WereadThoughtAuthor" } }, meta)
    for _, line in ipairs(text_util.wrap(thought.content or "", width - 2, 400)) do
      add({ { "  " .. line } })
    end
  end
  return lines, marks, cards
end

---@param view table
local function footer_of(view)
  local parts = {}
  if view.loading then
    parts[#parts + 1] = "加载中…"
  end
  if #view.entries > 1 then
    parts[#parts + 1] = string.format("<Tab> 下一条划线 %d/%d", view.index, #view.entries)
  end
  if #(view.thoughts or {}) > 1 then
    parts[#parts + 1] = "s 排序"
    parts[#parts + 1] = "]] [[ 跳转"
  end
  parts[#parts + 1] = "c 写想法"
  parts[#parts + 1] = "d 删想法"
  parts[#parts + 1] = "q 关闭"
  return " " .. table.concat(parts, " · ") .. " "
end

---Draw the panel for the current highlight.
---(为当前划线绘制面板)
---@param view table
local function paint(view)
  local float = view.float
  if not float or not float:is_open() then
    return
  end
  local lines, marks, cards = M.layout(view, view.width - 2)
  view.cards = cards
  float:set_lines(lines)
  vim.api.nvim_buf_clear_namespace(float.buf, NAMESPACE, 0, -1)
  for _, mark in ipairs(marks) do
    pcall(vim.api.nvim_buf_set_extmark, float.buf, NAMESPACE, mark[1], mark[2], {
      end_col = mark[3],
      hl_group = mark[4],
    })
  end
  local height = math.max(3, math.min(#lines, view.max_height))
  pcall(vim.api.nvim_win_set_height, float.win, height)
  local title = #view.entries > 1 and string.format(" 划线下的想法 %d/%d ", view.index, #view.entries) or " 划线下的想法 "
  float:set_title(title)
  -- a shorter footer when the long one does not fit (放不下时换短页脚)
  local footer = footer_of(view)
  if vim.api.nvim_strwidth(footer) > view.width then
    footer = " q 关闭 "
  end
  float:set_footer(footer)
end

---Fetch every thought of the current highlight unless a fresh copy is cached.
---(取当前划线的全部想法，除非已有新鲜的缓存)
---@param view table
local function load(view)
  local annotation = view.entries[view.index].annotation
  local key = key_of(view.book_id, annotation.range)
  local cached = fetched[key]
  view.error = nil
  if cached then
    view.thoughts, view.total = cached.thoughts, cached.total
    view.loading = false
    if os.time() - cached.at < FRESH_SECONDS then
      return
    end
  else
    view.thoughts = vim.deepcopy(annotation.thoughts or {})
    view.total = annotation.thought_total
  end
  if view.uploaded or not view.chapter_uid then
    view.loading = false
    return
  end

  view.loading = true
  local index = view.index
  fetch.fetch_all_thoughts(view.book_id, view.chapter_uid, annotation.range, function(ok, thoughts, total)
    vim.schedule(function()
      if ok then
        fetched[key] = { thoughts = thoughts, total = total, at = os.time() }
      else
        log.warn("thoughts fetch failed: %s", tostring(thoughts))
      end
      -- the reader may have moved on to another highlight meanwhile
      -- (这期间读者可能已经切到了别的划线)
      if view.index ~= index then
        return
      end
      view.loading = false
      if ok then
        view.thoughts, view.total = thoughts, total
      elseif #(view.thoughts or {}) == 0 then
        view.error = thoughts
      end
      paint(view)
    end)
  end)
end

---Move the cursor to the next or previous card.
---(把光标移到下一张/上一张卡片)
---@param view table
---@param forward boolean
local function jump(view, forward)
  local row = vim.api.nvim_win_get_cursor(view.float.win)[1] - 1
  local target = nil
  for _, start in ipairs(view.cards or {}) do
    if forward and start > row then
      target = start
      break
    elseif not forward and start < row then
      target = start
    end
  end
  if target then
    vim.api.nvim_win_set_cursor(view.float.win, { target + 1, 0 })
    -- keep the card's head at the top, so as much of it shows as possible
    -- (让卡片的开头贴着窗口顶部，尽可能多地露出它)
    vim.api.nvim_win_call(view.float.win, function()
      vim.cmd("normal! zt")
    end)
  end
end

---Open the panel.
---(打开面板)
---@param opts table { buf, book_id, chapter_uid, entries }
---@return table|nil view
function M.open(opts)
  text_util.define_highlights()
  M.define_highlights()

  local width = math.max(30, math.min(78, vim.o.columns - 8))
  local view = {
    buf = opts.buf,
    book_id = opts.book_id,
    chapter_uid = opts.chapter_uid,
    entries = opts.entries,
    index = 1,
    order = "likes",
    width = width,
    max_height = math.max(5, math.floor(vim.o.lines * 0.8)),
    uploaded = model.is_uploaded(opts.book_id),
  }

  view.float = require("weread.float").open({
    title = " 划线下的想法 ",
    width = width,
    height = 3,
    wrap = false,
    filetype = "weread-thoughts",
    keymaps = false,
  })
  if not view.float then
    return nil
  end
  vim.wo[view.float.win].cursorline = false
  vim.wo[view.float.win].scrolloff = 0

  local function map(lhs, fn, desc)
    vim.keymap.set("n", lhs, fn, { buffer = view.float.buf, nowait = true, silent = true, desc = desc })
  end
  for _, key in ipairs({ "q", "<Esc>", "<C-c>", "K" }) do
    map(key, function()
      view.float:close()
    end, "关闭")
  end
  map("s", function()
    view.order = view.order == "likes" and "time" or "likes"
    paint(view)
    vim.api.nvim_win_set_cursor(view.float.win, { 1, 0 })
  end, "切换排序")
  map("]]", function()
    jump(view, true)
  end, "下一条想法")
  map("[[", function()
    jump(view, false)
  end, "上一条想法")
  local function cycle(step)
    if #view.entries < 2 then
      return
    end
    view.index = (view.index - 1 + step) % #view.entries + 1
    load(view)
    paint(view)
    vim.api.nvim_win_set_cursor(view.float.win, { 1, 0 })
  end
  map("<Tab>", function()
    cycle(1)
  end, "下一条划线")
  map("<S-Tab>", function()
    cycle(-1)
  end, "上一条划线")
  map("c", function()
    local annotation = view.entries[view.index].annotation
    view.float:close()
    if vim.api.nvim_buf_is_valid(view.buf) then
      M.invalidate(view.book_id, annotation.range)
      M.compose_thought(view.buf, annotation.range, annotation.text or "")
    end
  end, "写想法")
  map("d", function()
    local annotation = view.entries[view.index].annotation
    local mine = M.my_thought_for(view.buf, annotation.range)
    if not mine then
      -- The panel fetches more pages than the chapter load; my thought may sit
      -- in one of them without being in the chapter's own list.
      -- (面板取的分页比加载章节时多；我的想法可能在里面，却不在本章那份列表里)
      local card = M.my_thought({ thoughts = view.thoughts or {} })
      if card and card.id then
        mine = { id = card.id, content = card.content or "", local_only = false }
      end
    end
    if not mine then
      vim.notify("weread: 这条划线下没有我写的想法", vim.log.levels.WARN)
      return
    end
    vim.ui.input({
      prompt = string.format("删掉这条想法？「%s」(y/N) ", vim.fn.strcharpart(mine.content or "", 0, 20)),
    }, function(answer)
      if not answer or answer:lower() ~= "y" then
        return
      end
      M.delete_thought_at(view.buf, annotation.range, function(ok, message)
        vim.notify(message, ok and vim.log.levels.INFO or vim.log.levels.WARN)
        if not ok then
          return
        end
        -- Drop the local-note block and the card here, without refetching: a
        -- fetch right after a delete can still return it for a moment.
        -- (去掉本地备注块和这张卡片，不重新拉取：删除刚刚成功时重新拉取可能还会返回它)
        annotation.note = nil
        annotation.note_synced = nil
        annotation.note_review_id = nil
        if mine.id then
          local kept = {}
          for _, thought in ipairs(view.thoughts or {}) do
            if thought.id ~= mine.id then
              kept[#kept + 1] = thought
            end
          end
          view.thoughts = kept
          if tonumber(view.total) and view.total > 0 then
            view.total = view.total - 1
          end
        end
        if view.float:is_open() then
          paint(view)
        end
      end, mine.id)
    end)
  end, "删除我的想法")

  load(view)
  paint(view)
  return view
end

-- ------------------------------------------------------------------ my thoughts

---Reading account vid, to tell my thoughts from other people's.
---(账号的 vid，用来区分我自己的想法与别人的)
---@return string
local function my_vid()
  local ok, auth = pcall(require, "weread.auth")
  if not ok then
    return ""
  end
  local credentials = auth.load_credentials()
  return tostring((credentials and credentials.account or {}).user_vid or "")
end

---My own thought under a highlight, if I wrote one.
---(我在某条划线下写的想法)
---@param annotation table
---@return table|nil
function M.my_thought(annotation)
  return model.find_mine(annotation.thoughts, my_vid())
end

---My thought on one range, from the loaded server list or the local record.
---The local record keeps the review id returned when it was posted, so deletion
---works before the next `/book/readreviews` refetch.
---(某条划线下我的想法，来自已加载的服务端列表或本地记录。本地记录带着发表时返回的
--- review id，所以下次 /book/readreviews 重新拉取之前也能删除)
---@param buf integer
---@param range string
---@return table|nil thought `{ id, content, local_only, synced }`
function M.my_thought_for(buf, range)
  local info = require("weread.reader").buffer_info(buf)
  if not info then
    return nil
  end
  local local_entry = nil
  for _, entry in ipairs(store.local_for(info.book_id, info.chapter_key)) do
    if entry.range == range then
      local_entry = entry
    end
  end
  if local_entry and local_entry.note_review_id then
    return { id = local_entry.note_review_id, content = local_entry.note or "", local_only = false }
  end
  for _, annotation in ipairs(vim.b[buf].weread_server_annotations or {}) do
    if annotation.range == range then
      local thought = M.my_thought(annotation)
      if thought and thought.id then
        return { id = thought.id, content = thought.content or "", local_only = false }
      end
    end
  end
  if local_entry and local_entry.note ~= nil then
    return {
      content = local_entry.note,
      local_only = true,
      -- Notes written before the review id (or the flag itself) was stored are
      -- ambiguous: delete looks the id up unless the note says it never synced.
      -- (在开始存 review id（甚至同步标志）之前写的备注是不确定的：除非明确写着
      --  没同步，删除时都先去查一下 id)
      synced = local_entry.note_synced,
    }
  end
  return nil
end

---Attach a note to the local record of a highlight, and redraw.
---(把一段备注挂到划线的本地记录上，并重画)
---@param buf integer
---@param range string
---@param content string
---@param text string|nil the passage, when the range has no local record yet
---@param synced boolean|nil the service accepted it (服务端已接受)
---@param review_id string|nil the service's id for it, needed to delete it (服务端 id，删除时要用)
function M.remember_note(buf, range, content, text, synced, review_id)
  local info = require("weread.reader").buffer_info(buf)
  if not info then
    return
  end
  store.set_note(info.book_id, info.chapter_key, range, content, text, synced, review_id)
  render.redraw(buf, info.book_id, info.chapter_key)
end

---Write a thought on a range, then refresh the chapter.
---(给某个 range 写想法，然后刷新本章)
---@param buf integer
---@param range string
---@param abstract string
---@param content string
function M.write_thought(buf, range, abstract, content)
  local context = store.write_context(buf)
  if not context then
    vim.notify("weread: 只在微信读书章节里写想法", vim.log.levels.WARN)
    return
  end
  -- The service files a thought by the passage it hangs on; take that passage
  -- from the cached source so layout spaces and markdown never leak into it.
  -- (服务端按想法挂靠的原文归档；从缓存源文取这段原文，避免排版空格与 markdown 混进去)
  local passage = store.source_text(context.book_id, context.chapter_key, range) or abstract
  sync.post_thought({
    book_id = context.book_id,
    chapter_uid = context.chapter_uid,
    chapter_idx = context.chapter_idx,
    range = range,
    content = content,
    abstract = passage,
    is_private = false,
    -- Same version the highlight sync sends: a write without it can be filed
    -- against an older revision of the book.
    -- (与划线同步带上同一个版本号：缺了它，写请求可能被记到旧版书上)
    book_version = context.book.version,
  }, function(ok, result)
    -- The reply can land after the chapter buffer is gone (closed, or replaced
    -- by another chapter). What was written must still be kept, so the note is
    -- stored from the ids captured above; only the redraw needs the buffer.
    -- (回复到来时章节 buffer 可能已经没了（关了，或换成了别的章节）。写下的内容仍要保住，
    --  所以用上面取好的 id 落盘；只有重绘才需要 buffer)
    local buffer_alive = vim.api.nvim_buf_is_valid(buf)
    local function keep(synced, review_id)
      if buffer_alive then
        M.remember_note(buf, range, content, passage, synced, review_id)
      else
        store.set_note(context.book_id, context.chapter_key, range, content, passage, synced, review_id)
      end
    end
    if not ok then
      -- Never lose what someone wrote: keep it locally if the service refuses.
      -- (绝不丢掉写下的内容：服务端拒绝时就存在本地)
      keep(false, nil)
      vim.notify(tostring(result) .. "（已存在本地，K 里能看）", vim.log.levels.WARN)
      return
    end
    -- Keep a local copy even though the service has it: `K` then shows the
    -- thought immediately, without waiting for a refetch.
    -- (即使服务端已经有了也留一份本地副本：这样 K 立刻就能看到，不必等重新拉取)
    local review_id = result and result.reviewId ~= nil and tostring(result.reviewId) or nil
    keep(true, review_id)
    -- The panel may still hold the list it fetched before this thought existed.
    -- (面板里可能还留着写这条想法之前取回的列表)
    M.invalidate(context.book_id, range)
    vim.notify("weread: 想法已发表", vim.log.levels.INFO)
    pcall(function()
      require("weread.sprites").moment("bubble", "想法已发表", { win = vim.fn.bufwinid(buf) ~= -1 and vim.fn.bufwinid(buf) or nil })
    end)
    if buffer_alive then
      chapter.refresh_after_write(buf, context)
    end
  end)
end

---Delete my thought under a range, local copy included.
---(删除某条划线下我写的想法，本地副本一并删掉)
---
---The review id is taken from the local record first (it is saved when the
---thought is posted), so a freshly written thought can be deleted without
---waiting for `/book/readreviews` to return it.
---(先取本地记录里的 review id（发表时就存下了），因此刚写完的想法不用等
--- /book/readreviews 返回就能删)
---@param buf integer
---@param range string
---@param callback fun(ok: boolean, message: string)|nil
---@param review_id string|nil known id, when the caller already found the card(已知 id：调用方已经找到那张卡片时)
function M.delete_thought_at(buf, range, callback, review_id)
  callback = callback or function(ok, message)
    vim.notify(message, ok and vim.log.levels.INFO or vim.log.levels.WARN)
  end
  local info = require("weread.reader").buffer_info(buf)
  if not info then
    callback(false, "只在微信读书章节里删除想法")
    return
  end
  local context = store.write_context(buf)
  local thought = nil
  if review_id ~= nil then
    thought = { id = tostring(review_id), content = "", local_only = false }
  else
    thought = M.my_thought_for(buf, range)
  end
  if not thought then
    callback(false, "这条划线下没有我写的想法")
    return
  end

  ---@param deleted_id string|nil id of the thought that is gone(已删掉的想法 id)
  local function drop_local(deleted_id)
    local records = store.local_store(info.book_id)
    local kept = {}
    for _, entry in ipairs(records[info.chapter_key] or {}) do
      if entry.range == range then
        entry.note = nil
        entry.note_synced = nil
        entry.note_review_id = nil
        entry.note_at = nil
        -- a record created only to hold the note goes with it
        -- (只为挂备注而建的记录，随备注一起删掉)
        if not (entry.local_only and not entry.bookmark_id) then
          kept[#kept + 1] = entry
        end
      else
        kept[#kept + 1] = entry
      end
    end
    records[info.chapter_key] = kept
    store.save_local(info.book_id, records)
    -- Remove it from the chapter's copy of the account list too, so the
    -- redraw does not bring it back before the next fetch.
    -- (也从本章那份账号列表里删掉，重画时它才不会又冒出来)
    store.forget_thought(buf, info.book_id, info.chapter_key, range, deleted_id or thought.id)
    M.invalidate(info.book_id, range)
    render.redraw(buf, info.book_id, info.chapter_key)
  end

  local function delete_on_server(target)
    sync.delete_thought(target.id, {
      book_id = context and context.book_id or info.book_id,
      chapter_uid = context and context.chapter_uid or nil,
      range = range,
      book_version = context and context.book.version or nil,
    }, function(ok, result)
      if not ok then
        callback(false, tostring(result))
        return
      end
      drop_local(target.id)
      callback(true, "想法已删除（微信读书里同步删除）")
    end)
  end

  if thought.id and not thought.local_only then
    delete_on_server(thought)
    return
  end

  -- A note written before the review id was stored: ask the web reader's own
  -- "my notes" list which thought is mine under this range, then delete it.
  -- That list also works for uploaded books, where the Agent API says -2020.
  -- (在开始存 review id 之前写的备注：向 Web 阅读器自己的「我的想法」列表确认这条
  --  划线下哪条是我的，再删。上传的书也能用——Agent API 对它们回 -2020)
  if thought.local_only and thought.synced ~= false then
    local chapter_uid = context and context.chapter_uid or nil
    sync.find_my_thought_web(info.book_id, chapter_uid, range, function(ok, found, err)
      if not ok then
        callback(false, "无法确认云端那条想法：" .. tostring(err) .. "（本地副本先留着，稍后再试）")
        return
      end
      if found and found.id then
        thought = found
        delete_on_server(found)
        return
      end
      drop_local()
      callback(true, "已删除本地想法（云端已经没有了）")
    end)
    return
  end

  drop_local()
  callback(true, "已删除本地想法（它没有同步到云端）")
end

---Composer: a small floating buffer. `<CR>` or `<C-s>` posts, `<Esc>` cancels,
---and `<S-CR>` / `<C-j>` starts a new line.
---(输入框：小浮窗。`<CR>` 或 `<C-s>` 发表，`<Esc>` 取消，`<S-CR>` / `<C-j>` 换行)
---@param buf integer chapter buffer(章节 buffer)
---@param range string
---@param abstract string the passage the thought hangs on(想法挂靠的原文)
function M.compose_thought(buf, range, abstract)
  local float = require("weread.float").open({
    title = "写想法 · " .. vim.fn.strcharpart(model.plain_text(abstract), 0, 16),
    width = math.min(72, vim.o.columns - 8),
    height = 9,
    lines = { "" },
    -- A private filetype keeps markdown plugins (bullets, render-markdown) from
    -- claiming <CR> or concealing the text before it is posted.
    -- (专用的 filetype，免得 markdown 插件抢走 <CR>，或在发表前把文字隐藏掉)
    filetype = "weread-thought",
    -- The composer owns its close keys: closing must not discard unsent text
    -- without asking.
    -- (输入框自己管理关闭键：关闭时不能问都不问就把没发表的内容丢掉)
    close_keys = {},
  })
  if not float then
    return
  end
  vim.bo[float.buf].modifiable = true
  float:set_footer(" <CR> 发表 · <C-j> 换行 · <Esc> 取消 ")

  local submitted = false

  ---What the reader typed, trimmed.
  ---(读者输入的内容，去掉首尾空白)
  ---@return string
  local function content()
    if not vim.api.nvim_buf_is_valid(float.buf) then
      return ""
    end
    return vim.trim(table.concat(vim.api.nvim_buf_get_lines(float.buf, 0, -1, false), "\n"))
  end

  local function submit()
    if submitted then
      return
    end
    local text = content()
    if text == "" then
      vim.notify("weread: 还没有写内容", vim.log.levels.INFO)
      return
    end
    submitted = true
    float:close()
    vim.schedule(function()
      if vim.api.nvim_buf_is_valid(buf) then
        M.write_thought(buf, range, abstract, text)
      end
    end)
  end

  ---Close without posting; ask first when there is something to lose.
  ---(不发表直接关闭；有内容时先问一句)
  local function discard()
    if content() ~= "" then
      local choice = vim.fn.confirm("这条想法还没发表，怎么处理？", "&继续编辑\n&放弃", 1, "Question")
      if choice ~= 2 then
        return
      end
    end
    float:close()
  end

  -- Enter is what a reader presses after writing: in this buffer it posts
  -- instead of adding a newline, because a lost thought is worse than a
  -- missing paragraph break. The newline keys remain for multi-paragraph text.
  -- (写完按回车是读者的本能：这个 buffer 里的 <CR> 用来发表而不是换行，因为丢掉一条
  --  想法比少一个分段更糟。确实要分段时用换行键)
  for _, mode in ipairs({ "n", "i" }) do
    vim.keymap.set(mode, "<CR>", submit, { buffer = float.buf, nowait = true, silent = true, desc = "发表想法" })
    vim.keymap.set(mode, "<C-s>", submit, { buffer = float.buf, nowait = true, silent = true, desc = "发表想法" })
    vim.keymap.set(mode, "<Esc>", discard, { buffer = float.buf, nowait = true, silent = true, desc = "取消写想法" })
    vim.keymap.set(mode, "<C-c>", discard, { buffer = float.buf, nowait = true, silent = true, desc = "取消写想法" })
  end
  for _, key in ipairs({ "<S-CR>", "<C-CR>", "<C-j>" }) do
    -- noremap: the RHS is a literal newline, not another trip through <CR>
    -- (noremap：右侧是字面换行，不会再走进 <CR> 的映射)
    vim.keymap.set("i", key, "<CR>", { buffer = float.buf, nowait = true, silent = true, desc = "换行（不发表）" })
  end
  vim.api.nvim_win_set_cursor(float.win, { 1, 0 })
  vim.cmd("startinsert")
end

-- ------------------------------------------------------------------ popups

---Show every thought under the highlight at the cursor.
---(显示光标处划线下的全部想法)
---@param buf integer|nil
---@param line integer|nil 0-based line, defaults to the cursor line
function M.show_thoughts_at_cursor(buf, line)
  buf = buf or vim.api.nvim_get_current_buf()
  local reader = require("weread.reader")
  local info = reader.buffer_info(buf)
  if not info then
    vim.notify("weread: 请在章节 buffer 里用 K 查看划线处的想法", vim.log.levels.WARN)
    return
  end
  line = line or (vim.api.nvim_win_get_cursor(0)[1] - 1)
  local found = render.annotations_on_line(buf, line)
  if #found == 0 then
    vim.notify("weread: 光标附近没有划线", vim.log.levels.INFO)
    return
  end
  local current = ((reader.state.catalog or {}).chapters or {})[info.chapter_index]
  return M.open({
    buf = buf,
    book_id = info.book_id,
    chapter_uid = current and tostring(current.chapterUid) or nil,
    entries = found,
  })
end

---A popup listing every highlight of the chapter.
---(列出本章全部划线的弹窗)
function M.show_chapter_summary()
  local buf = store.chapter_buffer()
  if not buf then
    vim.notify("weread: 当前不在章节 buffer 中", vim.log.levels.WARN)
    return
  end
  local resolved = vim.b[buf].weread_annotations
  if not resolved then
    vim.notify("weread: 本章划线尚未加载", vim.log.levels.INFO)
    return
  end
  if #resolved == 0 then
    vim.notify("weread: 本章没有划线与想法", vim.log.levels.INFO)
    return
  end

  local lines = {}
  local mine, popular, thoughts_total = 0, 0, 0
  for _, entry in ipairs(resolved) do
    local annotation = entry.annotation
    if annotation.mine then
      mine = mine + 1
    end
    if annotation.popular then
      popular = popular + 1
    end
    thoughts_total = thoughts_total + #(annotation.thoughts or {})

    lines[#lines + 1] = string.format("%s  %s", model.label(annotation), vim.trim(annotation.text or ""))

    local thoughts = annotation.thoughts or {}
    local limit = tonumber(require("weread.config").get().summary_thoughts) or 3
    local leftover = #thoughts - limit
    for index = 1, math.min(limit, #thoughts) do
      local thought = thoughts[index]
      -- Thoughts are multi paragraph often enough that they must be laid out
      -- as such; the float splits them, this indents the continuation lines.
      -- (想法经常是好几个自然段，必须按段落铺开：float 负责拆行，这里给续行加缩进)
      local body = vim.split(tostring(thought.content or ""), "\n", { plain = true })
      lines[#lines + 1] = string.format("    %s：%s", thought.author or "匿名", vim.trim(body[1] or ""))
      for body_index = 2, #body do
        if vim.trim(body[body_index]) ~= "" then
          lines[#lines + 1] = "        " .. vim.trim(body[body_index])
        end
      end
    end
    if leftover > 0 then
      lines[#lines + 1] = string.format("    …另有 %d 条想法（在这条划线处按 K 查看）", leftover)
    end
    lines[#lines + 1] = ""
  end

  table.insert(lines, 1, string.format("共 %d 条（我的 %d，热门 %d，想法 %d）", #resolved, mine, popular, thoughts_total))
  table.insert(lines, 2, "")

  require("weread.float").open({
    title = "本章划线与想法",
    width = math.min(100, vim.o.columns - 8),
    height = math.min(#lines, vim.o.lines - 8),
    lines = lines,
    filetype = "markdown",
  })
end

return M
