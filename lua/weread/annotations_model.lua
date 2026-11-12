--[[
The data model of highlights and thoughts: pure functions only, no IO, no
buffers, no other weread module. Everything else in the annotations family
(store, fetch, render, sync, edit, chapter) builds on this leaf, which is what
keeps the family free of load-time cycles.
(划线与想法的数据模型：只有纯函数，没有 IO、没有 buffer、不依赖任何其它 weread 模块。
 annotations 这一族的其余模块（store、fetch、render、sync、edit、chapter）都建立在这片叶子上，
 加载期没有环就靠它)

A highlight carries `range = "383-415"` in rune offsets over the raw chapter
XHTML, tags included; see xhtml.lua for how that maps onto the markdown.
(划线的 range 形如 "383-415"，是原始章节 XHTML 上的 rune 偏移，含标签字符；
 如何映射到 markdown 见 xhtml.lua)
]]

local M = {}

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
---@return table merged the entry now in the list(现在在列表里的那条)
function M.upsert(annotations, entry)
  for _, existing in ipairs(annotations) do
    if existing.range == entry.range then
      existing.mine = existing.mine or entry.mine
      existing.popular = existing.popular or entry.popular
      existing.count = math.max(existing.count or 0, entry.count or 0)
      existing.text = existing.text ~= "" and existing.text or entry.text
      existing.bookmark_id = existing.bookmark_id or entry.bookmark_id
      -- once the account has it, it is no longer only a local highlight
      -- (账号里有了它，它就不再只是一条本地划线)
      if entry.mine and not entry.unsynced then
        existing.unsynced = nil
      end
      -- a note written here survives the merge into the account's own highlight
      -- (在这里写的备注不会因为并进账号里那条划线而消失)
      if existing.note == nil then
        existing.note = entry.note
      end
      if entry.note_synced ~= nil then
        existing.note_synced = entry.note_synced
      end
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
      M.upsert(out, {
        range = item.range,
        text = item.markText or "",
        mine = true,
        popular = false,
        count = 0,
        thoughts = {},
        -- what `/web/book/removeBookmark` needs to take it off the account
        -- (从账号里删掉它时 `/web/book/removeBookmark` 要用的 id)
        bookmark_id = item.bookmarkId,
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
      M.upsert(out, {
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

---One entry of a `/book/readreviews` `pageReviews` list as a thought.
---(把 `/book/readreviews` 的 pageReviews 条目转成一条想法)
---@param page table
---@return table|nil
function M.thought_of(page)
  local review = (page or {}).review or {}
  if not review.content or review.content == "" then
    return nil
  end
  -- Zero-width characters pasted along with the text show up as `<200b>`.
  -- (随文字粘进来的零宽字符会显示成 `<200b>`)
  local content = review.content:gsub("\226\128[\139-\141]", ""):gsub("\239\187\191", "")
  local review_id = review.reviewId or page.reviewId
  return {
    content = content,
    author = (review.author or {}).name,
    -- kept so a thought of mine can be found again and deleted
    -- (留着以便再次找到我自己的想法并删除)
    id = review_id and tostring(review_id) or nil,
    author_vid = tostring((review.author or {}).userVid or ""),
    time = review.createTime,
    is_private = review.isPrivate,
    likes = tonumber(page.likesCount) or 0,
  }
end

---Attach thoughts from a `/book/readreviews` response onto the annotations.
---A thought already attached (same review id) is not added twice.
---(把想法挂到对应划线上；已挂过的（同一 review id）不重复添加)
---@param annotations table[]
---@param data table|nil
function M.attach_thoughts(annotations, data)
  for _, group in ipairs((data or {}).reviews or {}) do
    local range = group.range
    if range then
      for _, annotation in ipairs(annotations) do
        if annotation.range == range then
          local seen = {}
          for _, thought in ipairs(annotation.thoughts) do
            if thought.id then
              seen[thought.id] = true
            end
          end
          for _, page in ipairs(group.pageReviews or {}) do
            local thought = M.thought_of(page)
            if thought and not (thought.id and seen[thought.id]) then
              annotation.thoughts[#annotation.thoughts + 1] = thought
              if thought.id then
                seen[thought.id] = true
              end
            end
          end
          annotation.thought_total = tonumber(group.totalCount) or annotation.thought_total
        end
      end
    end
  end
end

---Is this a book the reader uploaded? Those have no store life: the service
---answers `-2020` for their thoughts, and no other reader can write any.
---(是不是自己上传的书？这类书不在书城里：服务端对它们的想法请求回 `-2020`，也不会有别的
--- 读者在上面写想法)
---@param book_id string|nil
---@return boolean
function M.is_uploaded(book_id)
  return tostring(book_id or ""):match("^CB_") ~= nil
end

---Heat tier of a popular highlight against the hottest one in its chapter:
---1 cool, 2 warm, 3 hot. Relative, not absolute: 30 readers is a lot for a
---niche book and nothing for a bestseller.
---(热门划线相对本章最热那条的热度档：1 冷、2 温、3 热。用相对值而不是绝对值：
--- 30 个人划过，对小众书是很多，对畅销书什么都不算)
---@param count integer|nil
---@param max integer|nil
---@return integer
function M.heat(count, max)
  count, max = tonumber(count) or 0, tonumber(max) or 0
  if count <= 0 or max <= 0 then
    return 1
  end
  local share = count / max
  if share >= 0.66 then
    return 3
  elseif share >= 0.33 then
    return 2
  end
  return 1
end

---Popular highlight group for a heat tier.
---(某个热度档的热门划线高亮组)
---@param tier integer
---@return string
function M.heat_group(tier)
  if tier >= 3 then
    return "WereadPopularHot"
  elseif tier == 2 then
    return "WereadPopularWarm"
  end
  return "WereadPopularHighlight"
end

---Human readable marker for a highlight.
---(划线的可读标记)
---@param annotation table
---@return string label
---@return string highlight_group
function M.label(annotation)
  local thoughts = #(annotation.thoughts or {})
  if annotation.unsynced and not annotation.bookmark_id then
    -- made here, not synced: say so rather than pretending it came from the app
    -- (在本地画的、没有同步：如实说明，而不是假装它来自 App)
    return thoughts > 0 and string.format("▎我的划线（本地）· %d想法", thoughts) or "▎我的划线（本地）",
      "WereadMineHighlight"
  end
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

---Byte offset of the first character that is neither an ASCII space nor a
---full-width one.
---(第一个既不是半角空格也不是全角空格的字符的字节偏移)
---
---Two traps in one: `　` is *not* ASCII whitespace (so `\S` matches it), and a
---Lua pattern would happily match in the middle of its bytes.
---(两个坑叠在一起：`　` 不是 ASCII 空白（`\S` 会匹配它），而 Lua 模式会钻进它的字节中间)
---@param text string
---@return integer|nil 1-based byte offset(1 基字节偏移)
function M.first_text_byte(text)
  local index = 1
  while index <= #text do
    local byte = text:byte(index)
    if byte == 32 or byte == 9 then
      index = index + 1
    elseif byte == 0xE3 and text:sub(index, index + 2) == "　" then
      index = index + 3
    else
      return index
    end
  end
  return nil
end

---Markdown punctuation is not part of the book's text, so it is not part of a
---highlight either.
---(markdown 标点不属于书里的原文，也就不属于划线文本)
---@param text string
---@return string
function M.plain_text(text)
  local cleaned = text:gsub("!%[([^%]]*)%]%([^%)]*%)", "%1")
  cleaned = cleaned:gsub("^#+%s*", ""):gsub("^[*%-]%s*", ""):gsub("[*`]", "")
  -- the paragraph indent is layout, not text: `　` is not ASCII whitespace, so
  -- `vim.trim` would leave it in
  -- (段落缩进是排版而不是文字：`　` 不是 ASCII 空白，vim.trim 不会去掉它)
  local start = M.first_text_byte(cleaned)
  if not start then
    return ""
  end
  return vim.trim(cleaned:sub(start))
end

---Is this thought mine? Matched by account vid, or by the `<vid>_` prefix every
---review id of the account carries.
---(这条想法是不是我的？按账号 vid 匹配，或按账号所有 review id 都带的 `<vid>_` 前缀匹配)
---@param thoughts table[]|nil
---@param vid string
---@return table|nil
function M.find_mine(thoughts, vid)
  for _, thought in ipairs(thoughts or {}) do
    if (vid ~= "" and thought.author_vid == vid) or (thought.id and thought.id:find("^" .. vid .. "_")) then
      return thought
    end
  end
  return nil
end

---Sort annotations into reading order (rune order).
---(把划线按阅读顺序（rune 顺序）排好)
---@param annotations table[]
function M.sort(annotations)
  table.sort(annotations, function(left, right)
    return (M.parse_range(left.range) or 0) < (M.parse_range(right.range) or 0)
  end)
end

return M
