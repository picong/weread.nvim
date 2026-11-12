--[[
The chapter table of contents of the open book (`<leader>wt`, :WeReadToc).
(当前这本书的章节目录：`<leader>wt`、:WeReadToc)

Each row is one chapter, indented by its level, with its length on the right;
the chapter being read is marked and the cursor starts on it, chapters before
it are dimmed as read. The preview says what the highlighted chapter is — where
it sits in the book, how long it takes — and shows its opening text when the
chapter is already on disk. Nothing is fetched for the preview: a TOC that
downloads every chapter it scrolls past would cost requests the reader never
asked for.
(每行一章，按层级缩进，右侧是字数；正在读的那章有标记，光标一打开就停在它上面，之前的章节
 按「已读」调暗。预览说明高亮的这一章是什么——在全书哪里、要读多久——章节已在本地时再给出
 开头的正文。预览不联网：划过哪章就下载哪章的目录，会花掉读者从没要过的请求)
]]

local M = {}

local log = require("weread.log")
local text_util = require("weread.text")

---Reading speed for the time estimate, characters per minute.
---(估算阅读时长用的速度：每分钟字数)
local CHARS_PER_MINUTE = 400

-- ------------------------------------------------------------------ items

---@param chapter table
---@param position integer
---@return string
local function chapter_title(chapter, position)
  local title = type(chapter.title) == "string" and vim.trim(chapter.title) or ""
  return title ~= "" and title or ("第 " .. tostring(position) .. " 章")
end

---@param value any
---@return string|nil
local function short_words(value)
  local n = tonumber(value)
  if not n or n <= 0 then
    return nil
  end
  if n >= 10000 then
    return string.format("%.1f万字", n / 1e4)
  end
  return tostring(math.floor(n)) .. "字"
end

---Picker items for a catalog: readable chapters only, each knowing its depth,
---whether it heads deeper entries, and whether it was read already.
---(把目录变成选择器条目：只要有正文的章节；每条知道自己的层级、是否带着更深的子条目、
--- 是否已经读过)
---@param chapters table[] catalog chapters
---@param current integer|nil catalog index being read(正在读的目录下标)
---@param is_readable fun(chapter: table): boolean
---@return table[] items
---@return integer|nil current_item position of the current chapter among the items
function M.items(chapters, current, is_readable)
  local min_level = math.huge
  for _, chapter in ipairs(chapters) do
    min_level = math.min(min_level, math.max(math.floor(tonumber(chapter.level) or 1), 1))
  end
  local items = {}
  local current_item = nil
  for index, chapter in ipairs(chapters) do
    if is_readable(chapter) then
      local level = math.max(math.floor(tonumber(chapter.level) or 1), 1)
      local nxt = chapters[index + 1]
      local title = chapter_title(chapter, #items + 1)
      items[#items + 1] = {
        -- what the filter matches on: the title alone, not the decorations
        -- (筛选匹配的对象：只有标题，不含装饰)
        text = title,
        title = title,
        index = index,
        position = #items + 1,
        depth = math.min(level - min_level, 3),
        part = nxt ~= nil and (tonumber(nxt.level) or 1) > level,
        current = index == current,
        read = current ~= nil and index < current,
        words = tonumber(chapter.wordCount),
        chapter = chapter,
      }
      if index == current then
        current_item = #items
      end
    end
  end
  return items, current_item
end

---Picker row: marker, indent, title, and the length right-aligned.
---(选择器的一行：标记、缩进、标题，字数靠右)
---@param item table
---@return table[] snacks highlight segments
function M.format(item)
  local title_group = nil
  if item.current then
    title_group = "WereadPreviewCurrent"
  elseif item.read then
    title_group = "WereadPreviewDim"
  elseif item.part then
    title_group = "WereadPreviewPart"
  end
  local segments = {
    { item.current and "▶ " or "  ", "WereadPreviewCurrent" },
    { string.rep("  ", item.depth or 0) },
    { item.title, title_group },
  }
  local words = short_words(item.words)
  if words then
    segments[#segments + 1] = {
      col = 0,
      virt_text = { { words .. " ", "WereadPreviewDim" } },
      virt_text_pos = "right_align",
      hl_mode = "combine",
    }
  end
  return segments
end

-- ------------------------------------------------------------------ excerpt

---Plain text out of one cached markdown line: markers off, links and images
---reduced to what a reader sees.
---(把缓存 markdown 的一行还原成纯文本：去掉标记，链接与图片只留读者看到的部分)
---@param line string
---@return string
local function plain(line)
  line = line:gsub("!%[[^%]]*%]%([^%)]*%)", "〔插图〕")
  line = line:gsub("%[%^[^%]]*%]", "")
  line = line:gsub("%[([^%]]*)%]%([^%)]*%)", "%1")
  line = line:gsub("%*%*", ""):gsub("__", ""):gsub("==", ""):gsub("~~", ""):gsub("`", "")
  line = line:gsub("\\([%p])", "%1")
  return line
end

---Join a hard-wrapped line onto the paragraph so far: Latin words lost their
---space at the break, CJK text never had one.
---(把硬换行的一行接回段落：西文在断行处丢了空格，要补回；中文本来就没有空格)
---@param paragraph string
---@param line string
---@return string
local function join(paragraph, line)
  if paragraph == "" then
    return line
  end
  local last = paragraph:sub(-1)
  local first = line:sub(1, 1)
  if last:match("[%w%p]") and first:match("[%w%p]") then
    return paragraph .. " " .. line
  end
  return paragraph .. line
end

---Paragraphs of a cached chapter, reflowed: the file is laid out for the page
---width, the preview is narrower or wider.
---(缓存章节的段落，重新拼接：文件按版心宽度排好，预览的宽度不同)
---@param markdown string
---@param title string|nil chapter title, dropped when the text repeats it(章节标题：正文重复时略去)
---@return table[] { text, heading = boolean }
function M.paragraphs(markdown, title)
  local paragraphs = {}
  local current = nil
  local in_code = false
  local seen_title = false
  local wanted = title and vim.trim((title:gsub("%s+", " "))) or nil

  local function flush()
    if current and vim.trim(current.text) ~= "" then
      paragraphs[#paragraphs + 1] = current
    end
    current = nil
  end

  for raw in (markdown .. "\n"):gmatch("([^\n]*)\n") do
    if raw:match("^%s*```") then
      flush()
      in_code = not in_code
    elseif in_code then
      -- code keeps its lines: reflowing it would make it unreadable
      -- (代码保留原行：拼接起来就没法读了)
      if vim.trim(raw) ~= "" then
        paragraphs[#paragraphs + 1] = { text = raw, code = true }
      end
    else
      local heading = raw:match("^#+%s+(.*)$")
      if heading then
        flush()
        heading = vim.trim(plain(heading))
        if not seen_title and wanted and heading == wanted then
          seen_title = true
        elseif heading ~= "" then
          paragraphs[#paragraphs + 1] = { text = heading, heading = true }
        end
      elseif vim.trim(raw) == "" then
        flush()
      else
        local line = plain(raw:gsub("^>%s?", ""))
        if line:find("^　") then
          -- an indented line opens a new paragraph(首行缩进的行开始新段落)
          flush()
        end
        -- strip the full-width indent as a whole string: a byte class like
        -- [　%s] would also eat the lead byte of other CJK punctuation
        -- (整体剥掉全角缩进：[　%s] 这种按字节的字符类会把别的全角标点的首字节一起吃掉)
        local text = line
        repeat
          local before = text
          text = vim.trim(text)
          while text:sub(1, 3) == "　" do
            text = text:sub(4)
          end
        until text == before
        text = vim.trim(text)
        if text ~= "" then
          current = current or { text = "" }
          current.text = join(current.text, text)
        end
      end
    end
  end
  flush()
  return paragraphs
end

-- ------------------------------------------------------------------ preview

---Render the preview of one TOC item.
---(渲染一个目录条目的预览)
---@param item table from M.items
---@param ctx table { total = integer, percent = integer|nil, markdown = string|nil, children = table[]|nil, width = integer|nil, height = integer|nil }
---@return string[] lines
---@return table[] highlights { row, col, end_col, group }
function M.build_preview(item, ctx)
  local width = math.max(math.floor(tonumber(ctx.width) or 64), 24)
  local room = width - 2
  local lines, highlights = {}, {}

  local function add(segments)
    local parts, col, row = { " " }, 1, #lines + 1
    for _, segment in ipairs(segments) do
      local text = segment[1] or ""
      if segment[2] and text ~= "" then
        highlights[#highlights + 1] = { row = row, col = col, end_col = col + #text, group = segment[2] }
      end
      parts[#parts + 1] = text
      col = col + #text
    end
    lines[row] = #segments == 0 and "" or table.concat(parts)
  end

  for _, line in ipairs(text_util.wrap(item.title, room, 3)) do
    add({ { line, "WereadPreviewTitle" } })
  end

  local facts = {}
  local words = tonumber(item.words)
  if words and words > 0 then
    facts[#facts + 1] = short_words(words)
    facts[#facts + 1] = string.format("约 %d 分钟", math.max(1, math.floor(words / CHARS_PER_MINUTE + 0.5)))
  end
  if #facts > 0 then
    add({ { text_util.fit(table.concat(facts, " · "), room), "WereadPreviewDim" } })
  end

  local status, group
  if item.current then
    status, group = "▶ 正在读", "WereadPreviewCurrent"
  elseif item.read then
    status, group = "✓ 已读过", "WereadPreviewDim"
  else
    status, group = "○ 未读", "WereadPreviewDim"
  end
  local tail = (tonumber(ctx.percent) or 0) > 0 and string.format("  读完本章约到全书 %d%%", ctx.percent) or ""
  add({ { status, group }, { tail, "WereadPreviewDim" } })
  add({ { string.rep("─", room), "WereadPreviewRule" } })

  if ctx.children and #ctx.children > 0 then
    add({ { "▎", "WereadPreviewSection" }, { "本部分", "WereadPreviewSection" }, { string.format("  %d 节", #ctx.children), "WereadPreviewDim" } })
    for _, child in ipairs(ctx.children) do
      add({ { "  " .. text_util.fit(child, room - 2) } })
    end
    add({})
  end

  if ctx.markdown then
    local budget = math.max((tonumber(ctx.height) or 40) - #lines, 6)
    for _, paragraph in ipairs(M.paragraphs(ctx.markdown, item.title)) do
      if budget <= 0 then
        break
      end
      if paragraph.code then
        add({ { "  " .. text_util.fit(paragraph.text, room - 2), "WereadCode" } })
        budget = budget - 1
      else
        local indent = paragraph.heading and "" or "  "
        local wrapped = text_util.wrap(paragraph.text, room - #indent, math.min(budget, 6))
        for _, line in ipairs(wrapped) do
          add({ { indent .. line, paragraph.heading and "WereadPreviewPart" or nil } })
        end
        budget = budget - #wrapped
      end
    end
  else
    add({ { "本章还没下载 · 回车打开时加载", "WereadPreviewDim" } })
  end
  return lines, highlights
end

-- ------------------------------------------------------------------ picker

---Titles of the entries a part heads: everything deeper until the next entry
---at its own level.
---(一个「部」统辖的条目标题：直到下一个同级条目之前、更深层级的全部条目)
---@param chapters table[]
---@param index integer
---@return string[]
local function children_of(chapters, index)
  local level = tonumber(chapters[index].level) or 1
  local list = {}
  for position = index + 1, #chapters do
    local chapter = chapters[position]
    if (tonumber(chapter.level) or 1) <= level then
      break
    end
    list[#list + 1] = chapter_title(chapter, position)
  end
  return list
end

---Show the TOC picker for the open book.
---(为当前打开的书显示目录选择器)
function M.open()
  local reader = require("weread.reader")
  local state = reader.state
  local chapters = (state.catalog or {}).chapters or {}
  if #chapters == 0 then
    vim.notify("weread: 目录为空", vim.log.levels.WARN)
    return
  end
  text_util.define_highlights()

  -- The chapter on screen wins over the session's last index: a TOC opened
  -- from a chapter buffer must point at that chapter.
  -- (屏幕上的章节优先于会话里记的下标：从章节 buffer 打开的目录必须指向那一章)
  local current = state.index
  local info = reader.buffer_info()
  if info and state.book and tostring(info.book_id) == tostring(state.book.book_id) and info.chapter_index then
    current = info.chapter_index
  end
  if not chapters[current] then
    current = nil
  end

  local items, current_item = M.items(chapters, current, reader.is_readable)
  local book = state.book or {}
  local book_id = book.book_id

  local title = string.format("《%s》目录 · %d 章", book.title or "微信读书", #items)
  if current_item then
    title = title .. string.format(" · 读到第 %d 章", current_item)
  end

  -- vim.ui.select has no formatter for segments: give it the marker inline
  -- (vim.ui.select 不认片段格式：把标记直接写进文字)
  for _, item in ipairs(items) do
    item.label = (item.current and "▶ " or "  ") .. string.rep("  ", item.depth) .. item.title
  end

  require("weread.ui").select({
    title = title,
    items = items,
    format = function(item)
      return M.format(item)
    end,
    preview = function(ctx)
      M.snacks_preview(ctx, { book_id = book_id, chapters = chapters, total = #items })
    end,
    snacks = {
      on_show = function(picker)
        if not current_item then
          return
        end
        -- land on the chapter being read, centred
        -- (落在正在读的那章上，并居中)
        local ok, err = pcall(function()
          picker.list:view(current_item)
          require("snacks").picker.actions.list_scroll_center(picker)
        end)
        if not ok then
          log.warn("toc: could not centre the current chapter: %s", tostring(err))
        end
      end,
    },
    on_choice = function(item)
      reader.open_index(item.index)
    end,
  })
end

---snacks preview for a TOC item.
---(目录条目的 snacks 预览)
---@param ctx table snacks.picker.preview.ctx
---@param book table { book_id, chapters, total }
function M.snacks_preview(ctx, book)
  local item = ctx.item or {}
  local view = ctx.preview
  view:reset()
  if view.minimal then
    local ok, err = pcall(view.minimal, view)
    if not ok then
      log.warn("toc: preview.minimal failed: %s", tostring(err))
    end
  end
  if not item.chapter then
    view:set_lines({ item.text or "" })
    return
  end
  view:set_title(string.format("第 %d / %d 章", item.position, book.total or item.position))
  local cache = require("weread.cache")
  local markdown = nil
  if book.book_id then
    markdown = cache.read(cache.chapter_file(book.book_id, item.chapter, "md"))
  end
  local percent = nil
  local percent_ok, percent_err = pcall(function()
    percent = require("weread.shell").book_percent(item.index)
  end)
  if not percent_ok then
    log.warn("toc: book percent unavailable: %s", tostring(percent_err))
  end
  local height = ctx.win and vim.api.nvim_win_is_valid(ctx.win) and vim.api.nvim_win_get_height(ctx.win) or nil
  local lines, highlights = M.build_preview(item, {
    total = book.total,
    percent = percent,
    markdown = markdown,
    children = item.part and children_of(book.chapters, item.index) or nil,
    width = text_util.text_width(ctx.win),
    height = height,
  })
  view:set_lines(lines)
  local ok, ns = pcall(function()
    return view:ns()
  end)
  if ok and type(ns) == "number" then
    for _, mark in ipairs(highlights) do
      pcall(vim.api.nvim_buf_set_extmark, ctx.buf, ns, mark.row - 1, mark.col, {
        end_col = mark.end_col,
        hl_group = mark.group,
      })
    end
  end
end

return M
