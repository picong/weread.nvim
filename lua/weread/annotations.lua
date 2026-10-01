--[[
Highlights and thoughts: line-end markers plus a popup with the thoughts under
a highlight.
(划线与想法：行尾标记 + 浮窗查看该划线下的想法)

Where the data comes from
(数据来源)

* `/book/bookmarklist`   my highlights for a whole book (one request, cached)
* `/book/bestbookmarks`  community highlights for one chapter, with a reader
                         count
* `/book/readreviews`    the thoughts attached to a set of ranges, batched

Position mapping is the interesting part: a highlight carries
`range = "383-415"` in *rune offsets over the raw chapter XHTML, tags
included*, so it can only be resolved through the offset map that
`weread.xhtml.convert` produced alongside the markdown. See xhtml.lua.
(位置映射是关键：划线的 range 是「原始 XHTML 的 rune 偏移，包含标签字符」，只能
 通过 xhtml.convert 生成的 offset map 定位。详见 xhtml.lua)

Rendering never blocks the chapter: cached annotations draw immediately, missing
ones are fetched in the background and drawn when they arrive.
(渲染从不阻塞正文：有缓存立即绘制，没有则后台拉取，回来后补画)
]]

local cache = require("weread.cache")
local gateway = require("weread.api_gateway")
local log = require("weread.log")
local xhtml = require("weread.xhtml")

local M = {}

local NAMESPACE = vim.api.nvim_create_namespace("weread.annotations")
local MAX_RANGES_PER_BATCH = 10

---@param book_id string
---@param chapter_key string
---@return string
local function annotations_path(book_id, chapter_key)
  return string.format("%s/%s.json", cache.annotations_dir(book_id), chapter_key)
end

---@param book_id string
---@param chapter_key string
---@return string
local function map_path(book_id, chapter_key)
  return string.format("%s/%s.map.json", cache.chapters_dir(book_id), chapter_key)
end

---@param range string|nil
---@return integer|nil from
---@return integer|nil to
function M.parse_range(range)
  if type(range) ~= "string" then
    return nil, nil
  end
  local from, to = range:match("^(%d+)%-(%d+)$")
  if not from then
    return nil, nil
  end
  return tonumber(from), tonumber(to)
end

---Merge highlights coming from different endpoints into one list keyed by range.
---(把不同接口来的划线按 range 归并成一个列表)
---@param annotations table[]
---@param entry table
local function upsert(annotations, entry)
  for _, existing in ipairs(annotations) do
    if existing.range == entry.range then
      existing.mine = existing.mine or entry.mine
      existing.popular = existing.popular or entry.popular
      existing.count = math.max(existing.count or 0, entry.count or 0)
      existing.text = existing.text ~= "" and existing.text or entry.text
      return existing
    end
  end
  entry.count = entry.count or 0
  annotations[#annotations + 1] = entry
  return entry
end

---Normalize a `/book/bookmarklist` response.
---(归一化我的划线)
---@param data table|nil
---@param chapter_uid string
---@return table[]
function M.from_bookmarklist(data, chapter_uid)
  local out = {}
  for _, item in ipairs((data or {}).updated or {}) do
    if tostring(item.chapterUid) == tostring(chapter_uid) and item.range then
      upsert(out, {
        range = item.range,
        text = item.markText or "",
        mine = true,
        popular = false,
        count = 0,
        thoughts = {},
      })
    end
  end
  return out
end

---Normalize a `/book/bestbookmarks` response.
---(归一化热门划线)
---@param data table|nil
---@param chapter_uid string
---@return table[]
function M.from_bestbookmarks(data, chapter_uid)
  local out = {}
  for _, item in ipairs((data or {}).items or {}) do
    if tostring(item.chapterUid) == tostring(chapter_uid) and item.range then
      upsert(out, {
        range = item.range,
        text = item.markText or "",
        mine = false,
        popular = true,
        count = tonumber(item.totalCount) or 0,
        thoughts = {},
      })
    end
  end
  return out
end

---Attach thoughts from a `/book/readreviews` response onto the annotations.
---(把想法挂到对应划线上)
---@param annotations table[]
---@param data table|nil
function M.attach_thoughts(annotations, data)
  for _, group in ipairs((data or {}).reviews or {}) do
    local range = group.range
    if range then
      for _, annotation in ipairs(annotations) do
        if annotation.range == range then
          for _, page in ipairs(group.pageReviews or {}) do
            local review = page.review or {}
            if review.content and review.content ~= "" then
              annotation.thoughts[#annotation.thoughts + 1] = {
                content = review.content,
                author = (review.author or {}).name,
                time = review.createTime,
              }
            end
          end
        end
      end
    end
  end
end

---Human readable marker for a highlight.
---(划线的可读标记)
---@param annotation table
---@return string label
---@return string highlight_group
function M.label(annotation)
  local thoughts = #(annotation.thoughts or {})
  if annotation.mine and annotation.popular then
    return string.format("▎我的划线 · %d人", annotation.count or 0), "WereadMineHighlight"
  end
  if annotation.mine then
    return thoughts > 0 and string.format("▎我的划线 · %d想法", thoughts) or "▎我的划线",
      "WereadMineHighlight"
  end
  if annotation.count and annotation.count > 0 then
    return string.format("▎%d人划线", annotation.count), "WereadPopularHighlight"
  end
  return "▎热门划线", "WereadPopularHighlight"
end

-- ------------------------------------------------------------------ fetching

---@param book_id string
---@param callback fun(ok: boolean, data: table|string)
local function fetch_book_highlights(book_id, callback)
  gateway.call("/book/bookmarklist", { bookId = book_id }, callback)
end

---@param book_id string
---@param chapter_uid string
---@param callback fun(ok: boolean, data: table|string)
local function fetch_chapter_popular(book_id, chapter_uid, callback)
  gateway.call("/book/bestbookmarks", {
    bookId = book_id,
    chapterUid = tonumber(chapter_uid) or 0,
    synckey = 0,
  }, callback)
end

---Fetch the thoughts under the given ranges, in batches the service accepts.
---(分批获取这些划线下的想法)
---@param book_id string
---@param chapter_uid string
---@param ranges string[]
---@param callback fun(ok: boolean, data: table[]|string)
local function fetch_thoughts(book_id, chapter_uid, ranges, callback)
  local batches = {}
  for index = 1, #ranges, MAX_RANGES_PER_BATCH do
    local batch = {}
    for offset = index, math.min(index + MAX_RANGES_PER_BATCH - 1, #ranges) do
      batch[#batch + 1] = { range = ranges[offset], maxIdx = 0, count = 20, synckey = 0 }
    end
    batches[#batches + 1] = batch
  end

  if #batches == 0 then
    callback(true, {})
    return
  end

  local responses = {}
  local pending = #batches
  local failed = nil

  for _, batch in ipairs(batches) do
    gateway.call("/book/readreviews", {
      bookId = book_id,
      chapterUid = tonumber(chapter_uid) or 0,
      reviews = batch,
    }, function(ok, data)
      if ok then
        responses[#responses + 1] = data
      elseif not failed then
        failed = data
      end
      pending = pending - 1
      if pending == 0 then
        if #responses == 0 and failed then
          callback(false, failed)
        else
          callback(true, responses)
        end
      end
    end)
  end
end

---Fetch every highlight and thought for one chapter and cache the result.
---(拉取一章的全部划线与想法并缓存)
---@param book_id string
---@param chapter table needs chapterUid
---@param chapter_key string
---@param callback fun(ok: boolean, result: table[]|string)
function M.load(book_id, chapter, chapter_key, callback)
  local chapter_uid = tostring(chapter.chapterUid)

  fetch_book_highlights(book_id, function(mine_ok, mine)
    if not mine_ok then
      log.warn("bookmarklist failed: %s", tostring(mine))
    end

    fetch_chapter_popular(book_id, chapter_uid, function(popular_ok, popular)
      if not popular_ok then
        log.warn("bestbookmarks failed: %s", tostring(popular))
      end

      local annotations = {}
      if mine_ok then
        for _, annotation in ipairs(M.from_bookmarklist(mine, chapter_uid)) do
          upsert(annotations, annotation)
        end
      end
      if popular_ok then
        for _, annotation in ipairs(M.from_bestbookmarks(popular, chapter_uid)) do
          upsert(annotations, annotation)
        end
      end

      if #annotations == 0 then
        table.sort(annotations, function(left, right)
          return (M.parse_range(left.range)) < (M.parse_range(right.range))
        end)
        cache.write_json(annotations_path(book_id, chapter_key), annotations)
        callback(true, annotations)
        return
      end

      local ranges = {}
      for _, annotation in ipairs(annotations) do
        ranges[#ranges + 1] = annotation.range
      end

      fetch_thoughts(book_id, chapter_uid, ranges, function(thoughts_ok, responses)
        if thoughts_ok then
          for _, response in ipairs(responses) do
            M.attach_thoughts(annotations, response)
          end
        else
          log.warn("readreviews failed: %s", tostring(responses))
        end

        -- Ordering matters for the summary popup and for the "closest marker"
        -- lookup, and rune order is the reading order.
        -- (顺序对汇总弹窗与「最近标记」查找都重要，rune 顺序即阅读顺序)
        table.sort(annotations, function(left, right)
          local left_from = M.parse_range(left.range)
          local right_from = M.parse_range(right.range)
          return (left_from or 0) < (right_from or 0)
        end)

        cache.write_json(annotations_path(book_id, chapter_key), annotations)
        callback(true, annotations)
      end)
    end)
  end)
end

-- ------------------------------------------------------------------ rendering

---@param book_id string
---@param chapter_key string
---@return table|nil map
---@return table|nil annotations
function M.cached(book_id, chapter_key)
  local map = cache.read_json(map_path(book_id, chapter_key))
  local annotations = cache.read_json(annotations_path(book_id, chapter_key))
  return map, annotations
end

---Draw the annotations of a buffer.
---(绘制 buffer 的划线标记)
---@param buf integer
---@param map table { map = table[], source_runes = integer }
---@param annotations table[]
---@return integer drawn
function M.render(buf, map, annotations)
  if not vim.api.nvim_buf_is_valid(buf) then
    return 0
  end
  vim.api.nvim_buf_clear_namespace(buf, NAMESPACE, 0, -1)

  local resolved = {}
  local lines = vim.api.nvim_buf_line_count(buf)
  local drawn = 0

  for _, annotation in ipairs(annotations or {}) do
    local from, to = M.parse_range(annotation.range)
    local start = from and xhtml.resolve(map, from, to) or nil
    if start then
      local label, highlight = M.label(annotation)
      local line = math.max(0, math.min(start.line, lines - 1))
      local ok = pcall(vim.api.nvim_buf_set_extmark, buf, NAMESPACE, line, 0, {
        virt_text = { { " " .. label, highlight } },
        virt_text_pos = "eol",
        hl_mode = "combine",
      })
      if ok then
        drawn = drawn + 1
        resolved[#resolved + 1] = {
          annotation = annotation,
          line = line,
        }
      end
    end
  end

  -- Buffer-local so `K` and the summary can work without refetching.
  -- (放进 buffer 局部变量，K 与汇总无需重新拉取)
  vim.b[buf].weread_annotations = resolved
  return drawn
end

---Attach annotations to a chapter buffer: cached ones now, fresh ones later.
---(把划线接到章节 buffer：有缓存立即画，没有就后台拉)
---@param buf integer
function M.attach(buf)
  local reader = require("weread.reader")
  local info = reader.buffer_info(buf)
  if not info then
    return
  end
  local chapter = ((reader.state.catalog or {}).chapters or {})[info.chapter_index]
  if not chapter then
    return
  end

  local map, annotations = M.cached(info.book_id, info.chapter_key)
  if map and annotations then
    M.render(buf, map, annotations)
    return
  end

  M.load(info.book_id, chapter, info.chapter_key, function(ok, result)
    if not ok then
      log.warn("annotation load failed: %s", tostring(result))
      return
    end
    local fresh_map = cache.read_json(map_path(info.book_id, info.chapter_key))
    if fresh_map and vim.api.nvim_buf_is_valid(buf) then
      M.render(buf, fresh_map, result)
    end
  end)
end

---Refetch and redraw the current chapter.
---(重新拉取并重绘当前章节)
---@param refresh boolean|nil
function M.refresh(refresh)
  local reader = require("weread.reader")
  local buf, info = M.chapter_buffer()
  if not buf or not info then
    vim.notify("weread: 当前不在章节 buffer 中", vim.log.levels.WARN)
    return
  end
  local chapter = ((reader.state.catalog or {}).chapters or {})[info.chapter_index]
  if not chapter then
    return
  end

  if refresh then
    vim.uv.fs_unlink(annotations_path(info.book_id, info.chapter_key))
  end

  M.load(info.book_id, chapter, info.chapter_key, function(ok, result)
    if not ok then
      vim.notify("weread: 划线拉取失败：" .. tostring(result), vim.log.levels.WARN)
      return
    end
    local map = cache.read_json(map_path(info.book_id, info.chapter_key))
    if map then
      local drawn = M.render(buf, map, result)
      if refresh then
        vim.notify(string.format("weread: 已刷新本章划线（%d 条）", drawn))
      end
    end
  end)
end

-- ------------------------------------------------------------------ popups

---Annotations on a given line (0-based), closest first.
---(某一行的划线，按距离排序)
---@param buf integer
---@param line integer 0-based
---@return table[]
function M.annotations_on_line(buf, line)
  local resolved = vim.b[buf].weread_annotations or {}
  local exact, nearby = {}, {}
  for _, entry in ipairs(resolved) do
    if entry.line == line then
      exact[#exact + 1] = entry
    elseif math.abs(entry.line - line) <= 1 then
      nearby[#nearby + 1] = entry
    end
  end
  if #exact > 0 then
    return exact
  end
  return nearby
end

---@param entry table
---@return string[]
local function thought_lines(entry)
  local annotation = entry.annotation
  local lines = {}
  lines[#lines + 1] = string.format("%s：%s", M.label(annotation), annotation.text or "")
  lines[#lines + 1] = ""

  local thoughts = annotation.thoughts or {}
  if #thoughts == 0 then
    lines[#lines + 1] = "（这条划线还没有想法）"
    return lines
  end

  for _, thought in ipairs(thoughts) do
    local author = thought.author or "匿名"
    lines[#lines + 1] = string.format("%s：", author)
    for _, wrapped in ipairs(vim.split(thought.content or "", "\n", { plain = true })) do
      lines[#lines + 1] = "  " .. wrapped
    end
    lines[#lines + 1] = ""
  end
  return lines
end

---Show the thoughts under the highlight at the cursor.
---(显示光标处划线下的想法)
function M.show_thoughts_at_cursor()
  local buf = vim.api.nvim_get_current_buf()
  if not require("weread.reader").buffer_info(buf) then
    vim.notify("weread: 请在章节 buffer 里用 K 查看划线处的想法", vim.log.levels.WARN)
    return
  end
  local line = vim.api.nvim_win_get_cursor(0)[1] - 1
  local found = M.annotations_on_line(buf, line)
  if #found == 0 then
    vim.notify("weread: 光标附近没有划线", vim.log.levels.INFO)
    return
  end

  local lines = {}
  for index, entry in ipairs(found) do
    if index > 1 then
      lines[#lines + 1] = ""
      lines[#lines + 1] = "────────────────"
    end
    vim.list_extend(lines, thought_lines(entry))
  end

  require("weread.float").open({
    title = "划线下的想法",
    width = math.min(84, vim.o.columns - 8),
    height = math.min(#lines + 1, vim.o.lines - 8),
    lines = lines,
    filetype = "markdown",
  })
end

---The chapter buffer to operate on.
---(要操作的章节 buffer)
---Popups steal the "current buffer", so a command that looks at the current
---buffer right after a popup opened would silently work on the wrong one.
---(弹窗会抢走「当前 buffer」，因此弹窗打开后再看当前 buffer 会静默作用于错误的 buffer)
---@return integer|nil buf
---@return table|nil info
function M.chapter_buffer()
  local reader = require("weread.reader")
  local current = vim.api.nvim_get_current_buf()
  local info = reader.buffer_info(current)
  if info then
    return current, info
  end

  local best, best_info, best_used = nil, nil, -1
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    local buf_info = reader.buffer_info(buf)
    if buf_info then
      local used = vim.fn.getbufinfo(buf)[1].lastused or 0
      if used > best_used then
        best, best_info, best_used = buf, buf_info, used
      end
    end
  end
  return best, best_info
end

---A popup listing every highlight of the chapter.
---(列出本章全部划线的弹窗)
function M.show_chapter_summary()
  local buf = M.chapter_buffer()
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

    lines[#lines + 1] = string.format("%s  %s", M.label(annotation), vim.trim(annotation.text or ""))

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
