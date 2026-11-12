--[[
Book detail preview for the shelf picker: community rating, public reviews,
where the reader is, and the full chapter table of contents, fetched lazily from
the official Agent API.
(书架选择器的书籍详情预览：评分、公开点评、读到哪里与完整章节目录，需要时才从官方
Agent API 拉取)

A store book with reviews shows 评分 + 点评 + 目录. A book the reader uploaded
has neither rating nor reviews, so its preview is the 目录 alone.
(书城书有点评时显示 评分 + 点评 + 目录；自己上传的书没有评分与点评，预览就只有目录)

The preview function is called every time the highlighted row changes, so the
fetches are debounced (fast scrolling must not fire four requests per book),
deduplicated and cached in memory. The cache holds the fetched data, not the
rendered lines: the render depends on the preview window's width and on where
the reader is now, and both change between visits.
(高亮行每次变化都会调预览函数，因此拉取做了防抖——快速划过不发请求——以及去重与内存缓存。
 缓存的是拉到的数据而不是渲染好的行：渲染取决于预览窗口的宽度和读者此刻读到哪，两者每次
 来都可能不同)

The TOC is live: <CR> or a click on a chapter row closes the picker and opens
the book at that chapter.
(目录可以操作：在章节行上回车或单击，关闭选择器并直接打开到该章)
]]

local M = {}

local log = require("weread.log")
local text_util = require("weread.text")

---Seconds fetched data stays fresh.
---(拉到的数据保持新鲜的时间)
local TTL = 600
---Reviews rendered at most; a few carry the signal, the rest is scroll noise.
---(最多渲染的点评条数：几条就够传达质量，再多只是滚动噪音)
local MAX_REVIEWS = 3
---Render width in display cells when the preview window is unknown.
---(不知道预览窗口宽度时的渲染宽度，按显示单元格计)
local LINE_WIDTH = 64
---Narrowest width worth laying out for; below it lines simply clip.
---(值得排版的最窄宽度；再窄就让行自己被裁掉)
local MIN_WIDTH = 24
---Debounce before fetching for the highlighted book.
---(高亮停稳多久后才开始拉取)
local FETCH_DEBOUNCE_MS = 350
---Cached books kept at most; a shelf visit must not grow memory forever.
---(最多缓存的书数：逛一次书架不应让内存无限增长)
local CACHE_MAX = 300
---Left padding of every line, so the text does not touch the border.
---(每行的左侧留白，正文不贴着边框)
local PAD = " "

---Review filters, in the order Alt-r cycles them, with the gateway's
---reviewListType for each.
---(点评筛选，按 Alt-r 循环的顺序排列，附各自对应的网关 reviewListType)
M.REVIEW_FILTERS = {
  { name = "全部", type = 0 },
  { name = "推荐", type = 1 },
  { name = "一般", type = 4 },
  { name = "不行", type = 2 },
  { name = "最新", type = 3 },
}
---Index into REVIEW_FILTERS, shared by every book: a reader who wants the
---critical reviews wants them for the next book too.
---(当前筛选在 REVIEW_FILTERS 里的下标，所有书共用：想看差评的读者，下一本书也想看)
local review_filter = 1

---book_id -> { at = os.time(), data = table }
local cache = {}
---book_id -> { callbacks } while a fetch is in flight.
---(拉取进行中时按书记挂着的回调)
local pending = {}
---preview buf -> { picker, book, layout } for the TOC actions.
---(预览 buffer -> 目录跳转要用的 { picker, book, layout })
local targets = {}

-- ------------------------------------------------------------------ highlights

---The groups live in `text.lua` (shared with the other popups); re-exported so
---`require("weread.preview").define_highlights` keeps working.
---(高亮组定义在 `text.lua`（与其它弹窗共用）；这里 re-export，
--- `require("weread.preview").define_highlights` 照常可用)
M.define_highlights = text_util.define_highlights

-- ------------------------------------------------------------------ formatting

-- The text helpers moved to `text.lua`; kept here under the same names, both as
-- locals for this file and as fields for existing callers.
-- (文本工具搬到了 `text.lua`；这里保留同名：本文件用局部变量，已有调用方用字段)
local cells = text_util.cells
local ellipsize = text_util.ellipsize
local fit = text_util.fit
local wrap = text_util.wrap

M.cells = cells
M.fit = fit
M.wrap = wrap
M.ellipsize = ellipsize

---1234567 -> "123.5 万"；under a 万 the raw number reads fine.
---(过万才用「万」，不到万直接给数字)
---@param value any
---@return string|nil
local function human_count(value)
  local n = tonumber(value)
  if not n or n <= 0 then
    return nil
  end
  if n >= 100000000 then
    return string.format("%.1f 亿", n / 1e8)
  end
  if n >= 10000 then
    return string.format("%.1f 万", n / 1e4)
  end
  return tostring(math.floor(n))
end

---@param value any
---@return string|nil
local function format_words(value)
  if type(value) == "string" then
    return value ~= "" and value or nil
  end
  local count = human_count(value)
  if not count then
    return nil
  end
  if count:find("[万亿]") then
    return count .. "字"
  end
  return count .. " 字"
end

---Compact chapter length for the right edge of a TOC row: 1.2万 / 365.
---(目录行右侧的紧凑字数：1.2万 / 365)
---@param value any
---@return string|nil
local function chapter_words(value)
  local n = tonumber(value)
  if not n or n <= 0 then
    return nil
  end
  if n >= 10000 then
    return string.format("%.1f万", n / 1e4)
  end
  return tostring(math.floor(n))
end

---20=一星 .. 100=五星 -> ★★★★☆
---@param star any
---@return string
local function stars(star)
  local n = math.min(math.max(math.floor((tonumber(star) or 0) / 20), 0), 5)
  return string.rep("★", n) .. string.rep("☆", 5 - n)
end

---The recommend percent from /book/info's `newRating`. The live gateway rates
---on a per-mille integer scale (862 = 86.2%, the same encoding as the review
---payload's deepVRecommendValue), so anything over 100 is ten times a percent.
---(推荐值换算：线上 /book/info 的 newRating 是千分制整数（862 = 86.2%，与点评负载里
---  deepVRecommendValue 同一套编码），大于 100 的值都是百分数乘了 10)
---@param value any
---@return number|nil
local function rating_percent(value)
  local rating = tonumber(value)
  if not rating or rating <= 0 then
    return nil
  end
  if rating > 100 then
    rating = rating / 10
  end
  return rating
end

---Ten-cell bar for a percent: ███████▌░░ reads faster than the number.
---(百分比的十格条：比数字更快看懂)
---@param percent number
---@return string filled
---@return string empty
local function rating_bar(percent)
  local filled = math.min(math.max(math.floor(percent / 10 + 0.5), 0), 10)
  return string.rep("█", filled), string.rep("░", 10 - filled)
end

---The publish year out of "2022-06-01 00:00:00".
---(从「2022-06-01 00:00:00」里取出版年份)
---@param value any
---@return string|nil
local function publish_year(value)
  local year = type(value) == "string" and value:match("^(%d%d%d%d)") or nil
  return year
end

-- ------------------------------------------------------------------ rendering

---Is a chapter worth opening? Covers and dividers carry no words.
---(章节值不值得打开？封面与分页条目没有字数)
---@param chapter table
---@return boolean
local function readable(chapter)
  local words = tonumber(chapter.word_count)
  return words == nil or words > 0
end

---Where the reader is in this book: the newer of the service's progress and
---this machine's position file.
---(读者在这本书里读到哪：服务端进度与本机位置记录里更新的那个)
---@param data table
---@param local_position table|nil from weread.cache.read_position
---@return table|nil { chapter_uid, percent }
local function reading_position(data, local_position)
  local remote = type(data.progress) == "table" and data.progress or nil
  local remote_time = remote and tonumber(remote.update_time) or -1
  local local_uid = local_position and local_position.chapter_uid
  local local_time = local_position and tonumber(local_position.updated_at) or -1
  if local_uid and local_time >= remote_time then
    -- the service's percent is still the best guess for the whole book
    -- (全书百分比仍以服务端的为准)
    return { chapter_uid = tostring(local_uid), percent = remote and remote.percent }
  end
  if remote and remote.chapter_uid then
    return { chapter_uid = tostring(remote.chapter_uid), percent = remote.percent }
  end
  return nil
end

---Render the preview for one book from whatever the fetches brought back.
---(用手头拉到的数据渲染一本书的预览：缺哪块就跳过哪块)
---@param book table needs title, author
---@param data table { info, info_err, reviews, reviews_err, chapters, chapters_err, progress }
---@param opts table|nil { width = integer, position = table } width in cells; position from weread.cache.read_position
---@return string[] lines
---@return table[] highlights { row, col, end_col, group } rows 1-based, columns 0-based bytes
---@return table<integer, table> toc row -> chapter, for the rows that open a chapter
function M.build_lines(book, data, opts)
  data = data or {}
  opts = opts or {}
  local width = math.max(math.floor(tonumber(opts.width) or LINE_WIDTH), MIN_WIDTH)
  -- room for the text: the left pad, and one cell kept free on the right
  -- (正文可用宽度：去掉左侧留白，右侧再空一格)
  local room = width - cells(PAD) - 1
  local lines = {}
  local highlights = {}
  local toc = {}

  ---Append one line made of { text, group } segments.
  ---(追加一行，由 { 文本, 高亮组 } 片段组成)
  local function add(segments)
    local parts = { PAD }
    local col = #PAD
    local row = #lines + 1
    for _, segment in ipairs(segments) do
      local text = segment[1] or ""
      if segment[2] and text ~= "" then
        highlights[#highlights + 1] = { row = row, col = col, end_col = col + #text, group = segment[2] }
      end
      parts[#parts + 1] = text
      col = col + #text
    end
    lines[row] = #segments == 0 and "" or table.concat(parts)
    return row
  end

  local function blank()
    if #lines > 0 and lines[#lines] ~= "" then
      add({})
    end
  end

  ---A section header: a coloured bar, the name, a dim count.
  ---(分区标题：色块、名称、暗色计数)
  local function section(name, extra)
    blank()
    local tail = extra and ellipsize("  " .. extra, room - cells("▎" .. name)) or ""
    add({ { "▎", "WereadPreviewSection" }, { name, "WereadPreviewSection" }, { tail, "WereadPreviewDim" } })
  end

  local info = data.info
  local reviews = data.reviews
  local chapters = data.chapters
  local ok_count = (info and 1 or 0) + (reviews and 1 or 0) + (chapters and 1 or 0)
  local errors = {}

  -- header: never missing — the shelf row already knows title and author
  -- (表头永远有：书架行本来就带着书名与作者)
  add({ { fit(book.title or (info and info.title) or "(无标题)", room), "WereadPreviewTitle" } })
  local byline = {}
  local author = (book.author and book.author ~= "") and book.author or (info and info.author) or ""
  if type(author) == "string" and author ~= "" then
    byline[#byline + 1] = vim.trim((author:gsub("%s+", " ")))
  end
  if info and type(info.translator) == "string" and info.translator ~= "" then
    byline[#byline + 1] = "译 " .. info.translator
  end
  if #byline > 0 then
    add({ { fit(table.concat(byline, " · "), room), "WereadPreviewDim" } })
  end
  add({ { string.rep("─", room), "WereadPreviewRule" } })

  -- store metadata: rating first — it is what the reader scans for
  -- (书城信息：评分放最前——这是读者扫一眼就想看的)
  if info then
    local rating = rating_percent(info.newRating)
    if rating then
      local filled, empty = rating_bar(rating)
      local count = human_count(info.newRatingCount)
      add({
        { "推荐值 " },
        { filled, "WereadPreviewStar" },
        { empty, "WereadPreviewDim" },
        { string.format(" %.1f%%", rating), "WereadPreviewStar" },
        { count and ("  " .. count .. "人点评") or "", "WereadPreviewDim" },
      })
    end
    local facts = {}
    local category = type(info.category) == "string" and info.category ~= "" and info.category or book.category
    if category and category ~= "" then
      facts[#facts + 1] = category
    end
    local words = format_words(info.wordCount)
    if words then
      facts[#facts + 1] = words
    end
    if type(info.publisher) == "string" and info.publisher ~= "" then
      facts[#facts + 1] = info.publisher
    end
    local year = publish_year(info.publishTime)
    if year then
      facts[#facts + 1] = year
    end
    if #facts > 0 then
      add({ { fit(table.concat(facts, " · "), room), "WereadPreviewDim" } })
    end
  elseif data.info_err then
    errors[#errors + 1] = "书籍信息：" .. data.info_err
  end

  -- An uploaded book has no store life at all: say why the rating and the
  -- reviews are missing instead of leaving the reader to guess.
  -- (自己上传的书在书城里不存在：把「为什么没有评分点评」说明白，而不是让读者自己猜)
  local ratingless = info ~= nil and (tonumber(info.newRating) or 0) <= 0
  local has_reviews = reviews and #(reviews.reviews or {}) > 0
  if ratingless and not has_reviews then
    add({ { "自己上传的书 · 无书城评分与点评", "WereadPreviewDim" } })
  end

  -- where the reader is, resolved against the TOC below
  -- (读者读到哪，对照下面的目录解析)
  local position = reading_position(data, opts.position)
  local current_uid = nil
  if position and chapters then
    for index, chapter in ipairs(chapters.chapters or {}) do
      if tostring(chapter.uid) == position.chapter_uid then
        current_uid = position.chapter_uid
        local title = chapter.title ~= "" and chapter.title or ("第 " .. tostring(chapter.idx or index) .. " 章")
        local percent = tonumber(position.percent)
        local tail = percent and percent > 0 and string.format(" · 全书 %d%%", percent) or ""
        add({
          { "▶ 读到 ", "WereadPreviewCurrent" },
          { fit(title, room - cells("▶ 读到 ") - cells(tail)), "WereadPreviewCurrent" },
          { tail, "WereadPreviewDim" },
        })
        break
      end
    end
  end

  if info and type(info.intro) == "string" and vim.trim(info.intro) ~= "" then
    section("简介")
    for _, line in ipairs(wrap(info.intro, room - 2, 6)) do
      add({ { "  " .. line } })
    end
  end

  if reviews then
    local list = reviews.reviews or {}
    if #list > 0 then
      local filter = M.REVIEW_FILTERS[reviews.filter or 1] or M.REVIEW_FILTERS[1]
      section(
        filter.type == 0 and "热门点评" or ("点评 · " .. filter.name),
        "共 " .. (human_count(reviews.total) or tostring(#list)) .. " 条 · Alt-r 切换"
      )
      for index, review in ipairs(list) do
        if index > MAX_REVIEWS then
          break
        end
        if index > 1 then
          add({})
        end
        local tail = {}
        if review.is_finish then
          tail[#tail + 1] = "读完"
        end
        if review.create_time and review.create_time > 0 then
          tail[#tail + 1] = require("weread.ui").relative_time(review.create_time)
        end
        local tail_text = #tail > 0 and ("  " .. table.concat(tail, " · ")) or ""
        local star_text = stars(review.star)
        add({
          { "  " .. star_text .. " ", "WereadPreviewStar" },
          { fit(review.name or "匿名", room - 3 - cells(star_text) - cells(tail_text)) },
          { tail_text, "WereadPreviewDim" },
        })
        for _, line in ipairs(wrap(review.content, room - 4, 3)) do
          add({ { "    " .. line } })
        end
      end
    end
    if #list == 0 and (reviews.filter or 1) > 1 then
      local filter = M.REVIEW_FILTERS[reviews.filter] or M.REVIEW_FILTERS[1]
      section("点评 · " .. filter.name, "Alt-r 切换")
      add({ { "  这一类还没有点评", "WereadPreviewDim" } })
    end
  elseif data.reviews_err then
    if ratingless then
      -- The review endpoint rejects ids that are not store books (uploads
      -- among them); the "uploaded" note above already explains the empty
      -- reviews, so keep the rejection in the log only.
      -- (点评接口会拒绝非书城的 id（上传的书在内）；上面的「自己上传的书」已经说明了
      --  点评为什么是空的，拒绝原因只进日志)
      log.warn("preview: reviews rejected for ratingless book %s: %s", tostring(book.book_id), data.reviews_err)
    else
      errors[#errors + 1] = "点评：" .. data.reviews_err
    end
  end

  if chapters and #(chapters.chapters or {}) > 0 then
    local list = chapters.chapters
    section("目录", string.format("共 %d 章 · 单击，或 Alt-w 进来回车", #list))
    -- Parts (a level-1 entry followed by deeper ones) are set in bold so the
    -- structure reads at a glance; a flat TOC stays plain.
    -- (「部」——后面跟着更深层级的一级条目——加粗，结构一眼可见；扁平目录保持原样)
    local min_level = math.huge
    for _, chapter in ipairs(list) do
      min_level = math.min(min_level, math.max(math.floor(tonumber(chapter.level) or 1), 1))
    end
    for index, chapter in ipairs(list) do
      local level = math.max(math.floor(tonumber(chapter.level) or 1), 1)
      local depth = math.min(level - min_level, 3)
      local nxt = list[index + 1]
      local is_part = nxt ~= nil and (tonumber(nxt.level) or 1) > level
      local is_current = current_uid ~= nil and tostring(chapter.uid) == current_uid
      local can_open = readable(chapter)

      local marker = is_current and "▶ " or "  "
      local indent = string.rep("  ", depth)
      local words = chapter_words(chapter.word_count) or ""
      local title = chapter.title ~= "" and chapter.title or ("第 " .. tostring(chapter.idx or index) .. " 章")
      local title_room = room - cells(marker) - cells(indent) - (words ~= "" and cells(words) + 2 or 0)
      title = fit(title, title_room)
      local gap = string.rep(" ", math.max(room - cells(marker) - cells(indent) - cells(title) - cells(words), words ~= "" and 2 or 0))

      local title_group = nil
      if is_current then
        title_group = "WereadPreviewCurrent"
      elseif not can_open then
        title_group = "WereadPreviewDim"
      elseif is_part then
        title_group = "WereadPreviewPart"
      end
      local row = add({
        { marker, is_current and "WereadPreviewCurrent" or nil },
        { indent },
        { title, title_group },
        { words ~= "" and gap or "" },
        { words, "WereadPreviewDim" },
      })
      if can_open then
        toc[row] = chapter
      end
    end
  elseif data.chapters_err then
    errors[#errors + 1] = "目录：" .. data.chapters_err
  end

  -- Nothing came back at all: one honest line instead of a silent stub.
  -- (什么都没拉到：一句实话，而不是一个空壳)
  if #errors > 0 and ok_count == 0 then
    blank()
    for _, line in ipairs(wrap("详情加载失败（" .. table.concat(errors, "；") .. "）", room, 4)) do
      add({ { line, "WereadPreviewDim" } })
    end
  elseif #errors > 0 then
    blank()
    for _, err in ipairs(errors) do
      add({ { fit("（" .. err .. "）", room), "WereadPreviewDim" } })
    end
  end

  return lines, highlights, toc
end

-- ------------------------------------------------------------------ fetching

---Fetched data for a book, if fresh.
---(命中新鲜缓存时直接给拉到的数据)
---@param book_id string|number
---@return table|nil
function M.cached(book_id)
  local hit = cache[tostring(book_id)]
  if hit and os.time() - hit.at < TTL then
    return hit.data
  end
  return nil
end

---Drop every cached preview (tests, or a manual :WeReadRefresh for pickers).
---(清空预览缓存——测试用，或以后给选择器接手动刷新)
function M.invalidate()
  cache = {}
end

---@param book_id string
---@param data table
local function remember(book_id, data)
  -- Evict the oldest entries once the cache outgrows its bound.
  -- (缓存超出上限时逐出最旧的条目)
  local count = 0
  for _ in pairs(cache) do
    count = count + 1
  end
  if count >= CACHE_MAX then
    local oldest = {}
    for id, hit in pairs(cache) do
      oldest[#oldest + 1] = { id = id, at = hit.at }
    end
    table.sort(oldest, function(left, right)
      return left.at < right.at
    end)
    for index = 1, count - CACHE_MAX + 1 do
      cache[oldest[index].id] = nil
    end
  end
  cache[book_id] = { at = os.time(), data = data }
end

---Fetch one page of reviews under a filter.
---(按某个筛选拉一页点评)
---@param book_id string
---@param filter integer index into REVIEW_FILTERS
---@param callback fun(reviews: table|nil, err: string|nil)
function M.fetch_reviews(book_id, filter, callback)
  local spec = M.REVIEW_FILTERS[filter] or M.REVIEW_FILTERS[1]
  require("weread.api_gateway").review_list(book_id, { count = 5, list_type = spec.type }, function(ok, result)
    if ok then
      result.filter = filter
      callback(result, nil)
    else
      log.warn("preview: /review/list failed for %s: %s", book_id, tostring(result))
      callback(nil, tostring(result))
    end
  end)
end

---Fetch info, reviews, chapters and progress for one book, then cache.
---Everything that fails is reported into the data instead of aborting.
---(拉齐一本书的详情/点评/目录/进度并缓存；失败的块记进数据而不是中断)
---@param book table needs book_id
---@param callback fun(data: table)
function M.fetch(book, callback)
  local book_id = tostring(book.book_id)
  local hit = M.cached(book_id)
  if hit and hit.reviews and (hit.reviews.filter or 1) ~= review_filter then
    -- the reader switched the filter since: only the reviews are stale
    -- (读者之后换过筛选：过期的只有点评)
    M.fetch_reviews(book_id, review_filter, function(reviews, err)
      if reviews or not hit.reviews then
        hit.reviews, hit.reviews_err = reviews, err
      end
      callback(hit)
    end)
    return
  end
  if hit then
    callback(hit)
    return
  end
  if pending[book_id] then
    pending[book_id][#pending[book_id] + 1] = callback
    return
  end
  pending[book_id] = { callback }

  local data = {}
  local remaining = 4
  local gateway = require("weread.api_gateway")

  local function done()
    -- Keep failures out of the cache: a transient network error must not
    -- stick around for the whole TTL.
    -- (失败的结果不进缓存：一次网络抖动不该把错误顶住整个 TTL)
    if data.info or data.reviews or data.chapters then
      remember(book_id, data)
    end
    local waiters = pending[book_id] or {}
    pending[book_id] = nil
    for _, cb in ipairs(waiters) do
      cb(data)
    end
  end

  local function step()
    remaining = remaining - 1
    if remaining == 0 then
      done()
    end
  end

  gateway.book_info(book_id, function(ok, result)
    if ok then
      data.info = result
    else
      data.info_err = tostring(result)
      log.warn("preview: /book/info failed for %s: %s", book_id, data.info_err)
    end
    step()
  end)
  M.fetch_reviews(book_id, review_filter, function(reviews, err)
    data.reviews, data.reviews_err = reviews, err
    step()
  end)
  -- Progress only marks the chapter the reader is in; a failure costs the
  -- marker, nothing else, so it is neither rendered nor counted.
  -- (进度只用来标出读到哪一章；失败只是少个标记，既不渲染也不计数)
  gateway.progress(book_id, { timeout = 4, retries = 0, silent = true }, function(ok, result)
    local remote = ok and type(result) == "table" and result.book or nil
    if type(remote) == "table" and remote.chapterUid ~= nil then
      data.progress = {
        chapter_uid = tostring(remote.chapterUid),
        percent = tonumber(remote.progress),
        update_time = tonumber(remote.updateTime) or 0,
      }
    end
    step()
  end)
  gateway.chapter_info(book_id, function(ok, result)
    if ok then
      data.chapters = result
      step()
      return
    end
    -- The Agent API refuses some shelf ids (uploaded books among them); the web
    -- catalog pipeline still knows them — fall back before giving up.
    -- (Agent API 会拒绝一些书架上的 id（上传的书也在内）；网页目录链路仍然认识它们——
    --  放弃前先回退到网页目录)
    data.chapters_err = tostring(result)
    log.warn("preview: /book/chapterinfo failed for %s: %s; trying the web catalog", book_id, data.chapters_err)
    require("weread.content").fetch_catalog(book_id, function(catalog_ok, catalog)
      if catalog_ok and type(catalog) == "table" and #(catalog.chapters or {}) > 0 then
        local chapters = {}
        for _, chapter in ipairs(catalog.chapters) do
          chapters[#chapters + 1] = {
            uid = chapter.chapterUid,
            idx = tonumber(chapter.chapterIdx),
            title = type(chapter.title) == "string" and chapter.title or "",
            level = tonumber(chapter.level) or 1,
            word_count = tonumber(chapter.wordCount),
          }
        end
        data.chapters = { chapters = chapters }
        data.chapters_err = nil
      else
        log.warn("preview: web catalog fallback failed for %s: %s", book_id, tostring(catalog))
      end
      step()
    end)
  end)
end

---Fetch, then render for a width.
---(拉取后按宽度渲染)
---@param book table needs book_id
---@param opts table|nil build_lines opts; position defaults to this machine's record(position 默认取本机记录)
---@param callback fun(lines: string[], highlights: table[], toc: table)
function M.load(book, opts, callback)
  if type(opts) == "function" then
    callback = opts
    opts = nil
  end
  opts = vim.deepcopy(opts or {})
  M.fetch(book, function(data)
    if opts.position == nil then
      opts.position = require("weread.cache").read_position(book.book_id)
    end
    callback(M.build_lines(book, data, opts))
  end)
end

-- ------------------------------------------------------------------ snacks

---Paint the highlight segments over the rendered lines.
---(把高亮片段画到渲染好的行上)
---@param ctx table snacks preview ctx
---@param buf integer
---@param highlights table[]|nil
local function decorate(ctx, buf, highlights)
  local ok, ns = pcall(function()
    return ctx.preview:ns()
  end)
  if not ok or type(ns) ~= "number" then
    return
  end
  vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
  for _, mark in ipairs(highlights or {}) do
    pcall(vim.api.nvim_buf_set_extmark, buf, ns, mark.row - 1, mark.col, {
      end_col = mark.end_col,
      hl_group = mark.group,
    })
  end
end

-- Text width of the preview window, gutter excluded (moved to `text.lua`).
-- (预览窗口的正文宽度，不含行号等边栏；实现搬到了 `text.lua`)
local text_width = text_util.text_width
M.text_width = text_width

---Open the book at the chapter on the cursor row of a preview buffer.
---(在预览 buffer 光标所在行的章节处打开这本书)
---@param buf integer
---@param row integer|nil 1-based; defaults to the cursor row(默认光标所在行)
---@return boolean opened
function M.open_row(buf, row)
  local target = targets[buf]
  if not target then
    return false
  end
  if not row then
    local win = vim.fn.bufwinid(buf)
    if win == -1 then
      return false
    end
    row = vim.api.nvim_win_get_cursor(win)[1]
  end
  local chapter = target.toc[row]
  if not chapter then
    return false
  end
  local book_id = target.book.book_id
  if target.picker and target.picker.close then
    local ok, err = pcall(target.picker.close, target.picker)
    if not ok then
      log.warn("preview: closing the picker failed: %s", tostring(err))
    end
  end
  -- After the picker is gone, so the chapter lands in the reader's window
  -- and not in a float that is being torn down.
  -- (等选择器关掉以后再开，章节才会落进读者的窗口，而不是正在拆掉的浮窗)
  vim.schedule(function()
    require("weread.reader").open_book(book_id, { chapter_uid = chapter.uid })
  end)
  return true
end

---Row to rest the cursor on when the preview gets focus: the current chapter,
---else the first chapter that opens.
---(预览获得焦点时光标停在哪：当前章节，否则第一个能打开的章节)
---@param target table
---@return integer|nil
local function landing_row(target)
  if target.current_row then
    return target.current_row
  end
  local first = nil
  for row in pairs(target.toc) do
    if not first or row < first then
      first = row
    end
  end
  return first
end

---Buffer-local maps and autocmds, installed once per preview buffer.
---(buffer 局部映射与自动命令，每个预览 buffer 只装一次)
---@param buf integer
local function install(buf)
  if vim.b[buf].weread_preview_maps then
    return
  end
  vim.b[buf].weread_preview_maps = true
  local function open_cursor()
    if not M.open_row(buf) then
      -- not a chapter row: fall through to the usual <CR>
      -- (不是章节行：交还给普通的 <CR>)
      vim.api.nvim_feedkeys(vim.keycode("<CR>"), "n", false)
    end
  end
  vim.keymap.set("n", "<CR>", open_cursor, { buffer = buf, nowait = true, desc = "weread: 打开该章" })
  vim.keymap.set("n", "o", open_cursor, { buffer = buf, nowait = true, desc = "weread: 打开该章" })
  vim.keymap.set("n", "<M-r>", function()
    M.cycle_reviews(buf)
  end, { buffer = buf, nowait = true, desc = "weread: 切换点评筛选" })
  -- The click lands first (moving the cursor into the preview); the release
  -- is then looked up in this buffer, on the row that was clicked.
  -- (单击先落地——光标移进预览——松开时才在本 buffer 里查映射，此时光标就在被点的行上)
  -- Insert mode too: the picker's input is in insert mode, and a click into
  -- another window keeps it.
  -- (插入模式也要：选择器的输入框处于插入模式，点进别的窗口时模式不变)
  vim.keymap.set({ "n", "i" }, "<LeftRelease>", function()
    local mouse = vim.fn.getmousepos()
    if mouse.winid == vim.fn.bufwinid(buf) and mouse.line > 0 and targets[buf] and targets[buf].toc[mouse.line] then
      vim.cmd.stopinsert()
      M.open_row(buf, mouse.line)
    end
  end, { buffer = buf, desc = "weread: 打开该章" })

  local group = vim.api.nvim_create_augroup("weread_preview_" .. buf, { clear = true })
  vim.api.nvim_create_autocmd("BufEnter", {
    group = group,
    buffer = buf,
    callback = function()
      local win = vim.api.nvim_get_current_win()
      vim.wo[win].cursorline = true
      -- Scheduled: a click enters the window before it moves the cursor, and
      -- scrolling now would put a different chapter under the release. Only a
      -- keyboard entry (cursor still on the top row) is moved.
      -- (延后执行：单击是先进窗口再挪光标，此时滚动会让松开时指针下换成另一章。
      --  只有键盘切进来——光标仍在首行——才挪)
      vim.schedule(function()
        local target = targets[buf]
        if not target or not vim.api.nvim_win_is_valid(win) or vim.api.nvim_get_current_win() ~= win then
          return
        end
        if vim.api.nvim_win_get_cursor(win)[1] ~= 1 then
          return
        end
        local land = landing_row(target)
        if land then
          pcall(vim.api.nvim_win_set_cursor, win, { land, 0 })
          vim.api.nvim_win_call(win, function()
            vim.cmd("normal! zz")
          end)
        end
      end)
    end,
  })
  vim.api.nvim_create_autocmd("BufLeave", {
    group = group,
    buffer = buf,
    callback = function()
      local win = vim.api.nvim_get_current_win()
      if vim.api.nvim_win_is_valid(win) then
        vim.wo[win].cursorline = false
      end
    end,
  })
  vim.api.nvim_create_autocmd("BufWipeout", {
    group = group,
    buffer = buf,
    callback = function()
      targets[buf] = nil
      pcall(vim.api.nvim_del_augroup_by_id, group)
    end,
  })
end

---Step to the next review filter and repaint the preview showing `buf`.
---(切到下一个点评筛选，并重画显示在 `buf` 里的预览)
---@param buf integer|nil preview buffer; nil = whichever preview is on screen(预览 buffer；nil 表示屏幕上那个)
function M.cycle_reviews(buf)
  review_filter = review_filter % #M.REVIEW_FILTERS + 1
  local target = buf and targets[buf] or nil
  if not target then
    for candidate, value in pairs(targets) do
      if vim.api.nvim_buf_is_valid(candidate) and vim.fn.bufwinid(candidate) ~= -1 then
        buf, target = candidate, value
        break
      end
    end
  end
  if target and target.repaint then
    target.repaint()
  end
end

---Show a render in the preview buffer and arm its TOC.
---(把渲染结果放进预览 buffer，并让目录可以点)
---@param ctx table
---@param book table
---@param lines string[]
---@param highlights table[]
---@param toc table
local function show(ctx, book, lines, highlights, toc)
  local buf = ctx.buf
  ctx.preview:set_lines(lines)
  decorate(ctx, buf, highlights)
  local current_row = nil
  for _, mark in ipairs(highlights) do
    if mark.group == "WereadPreviewCurrent" and toc[mark.row] then
      current_row = mark.row
      break
    end
  end
  local repaint = targets[buf] and targets[buf].repaint
  targets[buf] = { picker = ctx.picker, book = book, toc = toc, current_row = current_row, repaint = repaint }
  install(buf)
end
M._show = show

---snacks.picker preview: the detail of the highlighted shelf book.
---(snacks.picker 预览：高亮书架条目的书籍详情)
---@param ctx table snacks.picker.preview.ctx
function M.snacks(ctx)
  local item = ctx.item or {}
  local book = item.book
  local preview = ctx.preview
  preview:reset()
  M.define_highlights()
  if type(book) ~= "table" or not book.book_id then
    -- A row without a book (should not happen on the shelf) still deserves
    -- its one line, not an empty pane.
    -- (没有书的行——书架里本不该有——也给出那一行，而不是一块空白)
    preview:set_lines({ item.text or "" })
    return
  end
  -- no line numbers: they eat width and number nothing here
  -- (不要行号：占宽度，这里也没什么可编号的)
  if preview.minimal then
    local ok, err = pcall(preview.minimal, preview)
    if not ok then
      log.warn("preview: preview.minimal failed: %s", tostring(err))
    end
  end

  local book_id = tostring(book.book_id)
  local buf = ctx.buf
  -- The marker says which book this preview buffer is showing right now; late
  -- fetches for other books must not paint over it.
  -- (标记说明这个预览 buffer 当前显示哪本书；别的书晚到的拉取不许盖上来)
  vim.b[buf].weread_preview_book = book_id
  targets[buf] = nil
  preview:set_title(book.title or item.text)

  local function render(data)
    local opts = {
      width = text_width(ctx.win),
      position = require("weread.cache").read_position(book_id),
    }
    show(ctx, book, M.build_lines(book, data, opts))
  end

  local function refetch()
    M.fetch(book, function(fetched)
      if not vim.api.nvim_buf_is_valid(buf) or vim.b[buf].weread_preview_book ~= book_id then
        return
      end
      render(fetched)
      if targets[buf] then
        targets[buf].repaint = refetch
      end
    end)
  end

  local data = M.cached(book_id)
  if data and (not data.reviews or (data.reviews.filter or 1) == review_filter) then
    render(data)
    targets[buf].repaint = refetch
    return
  end

  preview:set_lines({ "", PAD .. "正在加载：评分 · 点评 · 目录 …" })
  vim.defer_fn(function()
    -- The reader moved on before the debounce fired: this book is not on
    -- screen any more, so stay quiet and fetch nothing.
    -- (防抖到点前读者已经划走：这本书已不在屏幕上，那就安静地不拉)
    if not vim.api.nvim_buf_is_valid(buf) or vim.b[buf].weread_preview_book ~= book_id then
      return
    end
    refetch()
  end, FETCH_DEBOUNCE_MS)
end

return M
