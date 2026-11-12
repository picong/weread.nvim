--[[
The book as an EPUB with the LLM's translation (:WeReadEpub), for reading it
elsewhere: imported into WeRead on the phone (传书), it is a book of its own
with the translation in it.
(把书连同大模型译文导出成 EPUB（:WeReadEpub），拿到别处去读：用微信读书的「传书」导入手机，
 它就是一本自带译文的书)

WeRead keeps no translation of ours on the account: its own 译文 is served by
the service, and the only things a reader can write are highlights and
thoughts. A book of its own is what a phone can show without anything else.
(微信读书账号里存不下我们的译文：它自己的「译文」由服务端提供，读者能写进去的只有划线和
 想法。导成一本独立的书，手机不需要任何别的东西就能显示)

Everything comes from the cache: chapters already downloaded, the LLM's
translations stored next to them (`NNNN.llm.json`), the stylesheet and the
illustrations. Nothing is fetched or translated here, and chapters that are
not downloaded or not translated are named in the report.
(一切都来自缓存：已下载的章节、旁边存着的大模型译文（NNNN.llm.json）、样式表与插图。这里不抓取也
 不翻译，没下载或没译过的章节会在报告里列出)

Two shapes: "only" replaces each block of the original with its translation
(a Chinese book), "bilingual" puts the translation under it, as the page here
does.
(两种形状："only" 把原文的每个块换成译文（一本中文书），"bilingual" 把译文排在原文下面，与这里的
 页面一样)
]]

local cache = require("weread.cache")
local session = require("weread.session")

local M = {}

---The five entities XML knows by name; every other named one must become a
---numeric reference, since an EPUB chapter is XML without a DTD.
---(XML 认识名字的五个实体；其余的命名实体都要换成数字引用，因为 EPUB 章节是不带 DTD 的 XML)
local XML_ENTITIES = { amp = true, lt = true, gt = true, quot = true, apos = true }

local MEDIA_TYPES = {
  png = "image/png",
  jpg = "image/jpeg",
  jpeg = "image/jpeg",
  gif = "image/gif",
  webp = "image/webp",
  svg = "image/svg+xml",
  bmp = "image/bmp",
}

---Stylesheet of our own, after the book's: the translation under the original
---in muted ink, as on the page here.
---(在书的样式表之后的我们自己的样式：原文下面的译文用淡墨，与这里的页面一致)
local EXTRA_CSS = table.concat({
  ".wr-translation { color: #6b6b6b; }",
  ".wr-cover { margin: 0; padding: 0; text-align: center; page-break-after: always; }",
  ".wr-cover img { max-width: 100%; max-height: 100vh; }",
  "",
}, "\n")

---@param text string
---@return string
local function escape(text)
  return (tostring(text):gsub("&", "&amp;"):gsub("<", "&lt;"):gsub(">", "&gt;"):gsub('"', "&quot;"))
end

---Make a chapter body well-formed XML: named entities XML does not know become
---numeric references, a bare `&` is escaped, void elements are closed.
---(把章节正文变成合式 XML：XML 不认识的命名实体换成数字引用，裸 `&` 转义，空元素闭合)
---@param body string
---@return string
function M.xml_body(body)
  local xhtml = require("weread.xhtml")
  body = body:gsub("&([^;%s<&]*;?)", function(rest)
    local name = rest:match("^(#?%w+);$")
    if not name then
      return "&amp;" .. rest
    end
    if name:sub(1, 1) == "#" or XML_ENTITIES[name] then
      return "&" .. rest
    end
    local decoded = xhtml.decode_entities("&" .. rest)
    if decoded == "&" .. rest then
      return "&amp;" .. rest
    end
    local refs = {}
    for _, code in ipairs(vim.fn.str2list(decoded, true)) do
      refs[#refs + 1] = string.format("&#%d;", code)
    end
    return table.concat(refs)
  end)
  -- `<br>` and friends written the HTML way(按 HTML 写法写的 `<br>` 之类)
  body = body:gsub("<(%a+)([^<>]-)>", function(tag, rest)
    local lower = tag:lower()
    if (lower == "br" or lower == "img" or lower == "hr") and not rest:match("/%s*$") then
      return "<" .. tag .. rest .. "/>"
    end
    return nil
  end)
  -- scripts never run in a reading system worth the name(像样的阅读器不会运行脚本)
  body = body:gsub("<script.-</script>", "")
  body = M.unique_attributes(body)
  body = M.unique_ids(body)
  body = M.wrap_stray_items(body)
  return body
end

---Rename an id met again in the same page (`id670` → `id670-2`). A chapter
---WeRead joins from several files of the book repeats the wrapper of each.
---(同一页里再次出现的 id 改名（id670 → id670-2）。微信读书由原书几个文件拼成的章节，每个文件的外层都会重复)
---@param body string
---@return string
function M.unique_ids(body)
  local seen = {}
  return (body:gsub('(%sid=")([^"]+)(")', function(open, id, close)
    if not seen[id] then
      seen[id] = 1
      return nil
    end
    seen[id] = seen[id] + 1
    return open .. id .. "-" .. seen[id] .. close
  end))
end

local VOID = { br = true, img = true, hr = true, meta = true, link = true, input = true, col = true, wbr = true, source = true }

---Put list items standing outside any list into one. WeRead cuts a long index
---between files in the middle of a list, and the next file starts with bare
---`<li>`s, which XHTML does not allow.
---(把不在任何列表里的列表项放进一个列表。微信读书把长索引在列表中间切到下一个文件，下一个文件就以光秃秃的
--- <li> 开头，XHTML 不允许这样)
---@param body string
---@return string
function M.wrap_stray_items(body)
  local out, stack = {}, {}
  local pos = 1
  local function close_synthetic()
    while stack[#stack] == "ul*" do
      table.remove(stack)
      out[#out + 1] = "</ul>"
    end
  end
  while true do
    local start, finish, slash, name, rest = body:find("<(/?)(%a[%w:%-]*)([^<>]*)>", pos)
    if not start then
      break
    end
    out[#out + 1] = body:sub(pos, start - 1)
    local tag = name:lower()
    local own = rest:match("/%s*$") ~= nil or VOID[tag]
    if slash == "/" then
      -- a closing tag ends the synthetic list it stands in(结束标签结束它所在的补出来的列表)
      if stack[#stack] == "ul*" and tag ~= "li" then
        close_synthetic()
      end
      for index = #stack, 1, -1 do
        if stack[index] == tag then
          for _ = #stack, index, -1 do
            table.remove(stack)
          end
          break
        end
      end
    elseif tag == "li" then
      local top = stack[#stack]
      if top ~= "ul" and top ~= "ol" and top ~= "menu" and top ~= "ul*" then
        out[#out + 1] = "<ul>"
        stack[#stack + 1] = "ul*"
      end
      stack[#stack + 1] = "li"
    else
      if stack[#stack] == "ul*" then
        close_synthetic()
      end
      if not own then
        stack[#stack + 1] = tag
      end
    end
    out[#out + 1] = body:sub(start, finish)
    pos = finish + 1
  end
  out[#out + 1] = body:sub(pos)
  close_synthetic()
  return table.concat(out)
end

---Point a link at the page alone when the place in it it names is not there:
---WeRead's index refers to anchors its pages never carry.
---(链接所指的页内位置不存在时，只指向那一页：微信读书的索引引用的锚点在页面里根本没有)
---@param files table[] the book's files, chapters rewritten in place(书的文件，就地改写章节)
function M.drop_dead_fragments(files)
  local ids = {}
  for _, file in ipairs(files) do
    if file.data and file.name:match("^OEBPS/[^/]+%.xhtml$") then
      local set = {}
      for id in file.data:gmatch('%sid="([^"]+)"') do
        set[id] = true
      end
      ids[(file.name:gsub("^OEBPS/", ""))] = set
    end
  end
  for _, file in ipairs(files) do
    if file.data and ids[(file.name:gsub("^OEBPS/", ""))] and not file.name:match("nav%.xhtml$") then
      local own = file.name:gsub("^OEBPS/", "")
      file.data = file.data:gsub('href="([^"#]*)#([^"]+)"', function(target, fragment)
        local set = ids[target ~= "" and target or own]
        if set and not set[fragment] then
          return 'href="' .. (target ~= "" and target or own) .. '"'
        end
        return nil
      end)
    end
  end
end

---Keep the first of an attribute written twice in one tag. WeRead's pages do
---that to every illustration (`data-w="…" … data-w="…"`), and XML stops
---reading the page at it.
---(同一个标签里写了两次的属性只留第一个。微信读书的页面给每张插图都这么写（data-w="…" … data-w="…"），
--- XML 读到这里就整页读不下去)
---@param body string
---@return string
function M.unique_attributes(body)
  return (body:gsub("<(%a[%w:%-]*)(%s[^<>]-)(/?)>", function(tag, attrs, close)
    local seen, kept, twice = {}, {}, false
    local rest = attrs:gsub("%s+([%w:_%.%-]+)%s*=%s*(([\"'])(.-)%3)", function(name, value)
      if seen[name] then
        twice = true
      else
        seen[name] = true
        kept[#kept + 1] = " " .. name .. "=" .. value
      end
      return ""
    end)
    -- only a tag made of quoted attributes alone is rewritten(只改写完全由带引号属性组成的标签)
    if not twice or rest:match("%S") then
      return nil
    end
    return "<" .. tag .. table.concat(kept) .. close .. ">"
  end))
end

---The body of a cached chapter: what is inside `<body>`, or the whole of a TXT
---book's fragment. A chapter made of several files of the book holds several
---documents one after another, each with its own `<?xml?>` and `<body>`; the
---bodies are joined.
---(缓存章节的正文：`<body>` 里面的内容，TXT 型书则是整个片段。由原书多个文件组成的章节是几份文档首尾相接，
--- 各有自己的 `<?xml?>` 与 `<body>`；把各个正文拼起来)
---@param source string
---@return string
function M.body_of(source)
  local bodies = {}
  for inner in source:gmatch("<body[^>]*>(.-)</body>") do
    bodies[#bodies + 1] = inner
  end
  if #bodies > 0 then
    return table.concat(bodies, "\n")
  end
  -- no body: a fragment, declarations and doctypes of its own taken out
  -- (没有 body：是个片段，去掉它自带的声明与 doctype)
  return (source:gsub("<%?xml[^>]*%?>", ""):gsub("<!DOCTYPE[^>]*>", ""))
end

---@param title string
---@param css_files string[]
---@param body string
---@param lang string
---@return string
local function chapter_document(title, css_files, body, lang)
  local links = {}
  for _, name in ipairs(css_files) do
    links[#links + 1] = string.format('<link rel="stylesheet" type="text/css" href="%s"/>', name)
  end
  return table.concat({
    '<?xml version="1.0" encoding="utf-8"?>',
    "<!DOCTYPE html>",
    string.format(
      '<html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops" lang="%s" xml:lang="%s">',
      lang,
      lang
    ),
    "<head>",
    "<title>" .. escape(title) .. "</title>",
    table.concat(links, "\n"),
    "</head>",
    "<body>",
    body,
    "</body>",
    "</html>",
  }, "\n")
end

---Put the cached illustrations into the book and point the chapter at them;
---one that is not cached is dropped, its alt text kept.
---(把缓存的插图放进书里、让章节指向它们；没缓存的插图去掉，保留它的 alt 文字)
---@param body string
---@param book_id string
---@param images table<string, table> src -> { name, media }, filled in(按 src 记录，就地填写)
---@param files table[]
---@return string
local function place_images(body, book_id, images, files)
  local pipeline = require("weread.chapter_pipeline")
  return (body:gsub("<img([^>]-)/?>", function(attrs)
    local src = attrs:match('src="([^"]*)"') or attrs:match("src='([^']*)'")
    if not src then
      return ""
    end
    local entry = images[src]
    if not entry then
      local path = pipeline.cached_image_path(book_id, src)
      if not path then
        local alt = attrs:match('alt="([^"]*)"') or ""
        return alt ~= "" and ('<span class="wr-missing-figure">' .. alt .. "</span>") or '<span class="wr-missing-figure"></span>'
      end
      local ext = (path:match("%.(%w+)$") or "png"):lower()
      local count = vim.tbl_count(images) + 1
      entry = { name = string.format("images/img%04d.%s", count, ext), media = MEDIA_TYPES[ext] or "image/png" }
      entry.id = string.format("img%04d", count)
      images[src] = entry
      files[#files + 1] = { name = "OEBPS/" .. entry.name, path = path, id = entry.id, media = entry.media }
    end
    local cleaned = attrs:gsub('%s+src="[^"]*"', ""):gsub("%s+src='[^']*'", "")
    return string.format('<img src="%s"%s/>', entry.name, cleaned)
  end))
end

-- --------------------------------------------------------------- contents

---What an entry of the contents is called. Translation-only books use the
---catalog's Chinese title; a split file's leftover name (`_2`) is no title at
---all and gets none.
---(目录项叫什么。只有译文的书用目录里的中文标题；拆分文件留下的名字（`_2`）根本不是标题，不用它)
---@param title string|nil
---@param translated string|nil
---@param mode string
---@return string
function M.label(title, translated, mode)
  title = vim.trim(tostring(title or ""))
  translated = vim.trim(tostring(translated or ""))
  if mode == "only" and translated ~= "" then
    return translated
  end
  return title
end

---Is this the name of a file a book was split into, rather than a title?
---(这是书拆分出来的文件名，而不是标题吗)
---@param title string
---@return boolean
local function placeholder(title)
  -- `_2` alone, or the book's own title with `_N` (or nothing) after it: the
  -- names a split file and a colophon are listed under
  -- (单独的 `_2`，或者书名后面跟着 `_N`（或什么都不跟）：拆分文件与版权页挂的名字)
  return title == "" or title:match("^_%d+$") ~= nil
end

---Is this catalog entry not a chapter of its own: the book's title standing in
---for a split file, a colophon or a second index page?
---(这条目录项不是独立的一章：书名替拆分文件、版权页或索引的第二页占位)
---@param title string
---@param book_title string|nil
---@return boolean
function M.is_placeholder(title, book_title)
  title = vim.trim(tostring(title or ""))
  if placeholder(title) then
    return true
  end
  local stem = title:gsub("_%d+$", "")
  if stem ~= title then
    -- `<anything>_3`: the name a split file was given(拆分文件得到的名字)
    return true
  end
  book_title = vim.trim(tostring(book_title or "")):gsub("%s*%(.-%)%s*$", "")
  return book_title ~= "" and (title == book_title or title:sub(1, #book_title) == book_title)
end

---Is this the title of back matter that stands on its own: an index, a
---glossary, the colophon, the authors?
---(这是不是自成一条的书后部分标题：索引、术语表、版权页、作者介绍)
---@param title string|nil
---@return boolean
function M.is_back_matter(title)
  local text = vim.trim(tostring(title or "")):lower()
  for _, name in ipairs({ "index", "glossary", "colophon", "about the author", "about the authors", "bibliography", "索引", "术语表" }) do
    if text == name or text:sub(1, #name) == name then
      return true
    end
  end
  return false
end

---Does this catalog entry carry on the one before it — the next file of a
---chapter (or an index) the book was split into?
---(这条目录项是否接着前一条——书被拆分后同一章（或索引）的下一个文件？)
---@param chapter table
---@param previous table|nil
---@return boolean
function M.continues(chapter, previous)
  if not previous then
    return false
  end
  local function stem(entry)
    local file = type(entry.files) == "table" and entry.files[1] or nil
    return file and tostring(file):match("^(.-)__split__%d+") or nil
  end
  local mine, theirs = stem(chapter), stem(previous)
  if mine and theirs and mine == theirs then
    return true
  end
  return false
end

---The text of every heading in a page that carries (or sits inside) an id,
---keyed by that id: what a contents entry pointing there should say. The
---nearest heading after the element with the id, before the next id'd block.
---(页面里每个带 id（或位于带 id 的元素里）的标题文字，按 id 索引：指向那里的目录项就该显示它。取带 id 的元素
--- 之后最近的标题，且不越过下一个带 id 的块)
---@param body string
---@return table<string, string>
function M.heading_texts(body)
  local out = {}
  local pending = {}
  local pos = 1
  while true do
    local start, finish, tag, attrs = body:find("<(%a[%w]*)([^>]*)>", pos)
    if not start then
      break
    end
    local lower = tag:lower()
    local id = attrs:match('%sid="([^"]+)"')
    if lower:match("^h[1-6]$") then
      local close = body:find("</" .. tag .. "%s*>", finish + 1)
      if close then
        local text = require("weread.xhtml").decode_entities((body:sub(finish + 1, close - 1):gsub("<[^>]*>", "")))
        text = vim.trim((text:gsub("%s+", " ")))
        if text ~= "" then
          if id then
            pending[#pending + 1] = id
          end
          for _, waiting in ipairs(pending) do
            out[waiting] = out[waiting] or text
          end
          pending = {}
        end
        pos = close + 1
      else
        pos = finish + 1
      end
    else
      if id then
        pending[#pending + 1] = id
      end
      pos = finish + 1
    end
  end
  return out
end

---The headings of a chapter the catalog lists (`anchors`), the chapter's own
---first one left out, kept only when this body has the element they point at.
---(目录列出的本章小节标题（anchors），去掉本章自己的那条，只保留在正文里能找到所指元素的)
---@param chapter table
---@param body string
---@param mode string
---@param headings table<string, string>|nil from M.heading_texts(body)
---@return table[] { id, title, level }
function M.anchors(chapter, body, mode, headings)
  local out = {}
  local level = tonumber(chapter.level) or 1
  headings = headings or M.heading_texts(body)
  for index, anchor in ipairs(type(chapter.anchors) == "table" and chapter.anchors or {}) do
    local id = tostring(anchor.anchor or "")
    local title = M.label(anchor.title, anchor.translateTitle, mode)
    -- a book WeRead never translated has no translateTitle: the page's own
    -- heading, translated by the LLM, is what the entry should say
    -- (微信读书从没翻译过的书没有 translateTitle：条目应当显示页面上已被大模型译好的标题)
    if mode == "only" and not (anchor.translateTitle and vim.trim(anchor.translateTitle) ~= "") and headings[id] then
      title = headings[id]
    end
    -- the first anchor is the chapter itself, whatever element it points at
    -- (第一个 anchor 就是本章自己，不管它指向哪个元素)
    local own = index == 1 and ((tonumber(anchor.level) or level) <= level or anchor.title == chapter.title)
    if not own and id ~= "" and not placeholder(title) and body:find('id="' .. id .. '"', 1, true) then
      out[#out + 1] = { id = id, title = title, level = tonumber(anchor.level) or (level + 1) }
    end
  end
  return out
end

---Levels for the contents when the catalog's own say nothing. Some books list
---every chapter at level 1 — "6. SQL Migrations", "6.1. An Overview…" — and the
---numbering is then the only structure there is: one more level per dot. A part
---("I. …", "Part II …") holds the chapters after it, up to the next part or to
---back matter (a lettered appendix, an unnumbered index).
---(目录本身的层级说明不了结构时用的层级。有些书把每一章都标成第 1 级——"6. SQL Migrations"、
--- "6.1. An Overview…"——这时编号就是仅有的结构：每多一个点就深一级。部（"I. …"、"Part II …"）
--- 统领它后面的章，直到下一个部或者书后部分（字母编号的附录、无编号的索引）)
---@param titles string[] original titles, in order(原文标题，按顺序)
---@param levels integer[] the catalog's levels(目录给的层级)
---@return integer[]
function M.derive_levels(titles, levels)
  local distinct = {}
  for _, level in ipairs(levels) do
    distinct[level] = true
  end
  local flat = vim.tbl_count(distinct) <= 1
  local function is_part(title)
    return title:match("^[IVXLC]+%.%s") ~= nil or title:match("^[Pp]art%s+[%wIVXLC]+") ~= nil
  end
  local has_parts = false
  for _, title in ipairs(titles) do
    if is_part(title) then
      has_parts = true
    end
  end
  local out = {}
  local in_part = false
  for index, title in ipairs(titles) do
    local level = levels[index] or 1
    local numbering = title:match("^(%d+[%.%d]*)[%.%s]")
    if flat and numbering then
      local _, dots = numbering:gsub("%.", "")
      if numbering:sub(-1) == "." then
        dots = dots - 1
      end
      level = 1 + math.max(0, dots)
    end
    if has_parts then
      if is_part(title) then
        in_part = true
        level = 1
      elseif not numbering and level == 1 then
        -- back matter, or front matter before the first part(书后部分，或第一部之前的书前部分)
        in_part = false
      elseif in_part then
        level = level + 1
      end
    end
    out[index] = level
  end
  return out
end

---The contents as a tree. The catalog gives every chapter and heading a level
---(1 is a part or a chapter, 2 a section, …); a node goes under the nearest
---one before it with a lower level. A placeholder chapter (the rest of a split
---index) has no entry of its own.
---(把目录建成树。目录给每章、每个小节都标了层级（1 是部或章，2 是节……）；一个节点挂在它之前最近的、
--- 层级更低的节点下面。占位章节（拆分索引的剩余部分）不单独成条)
---@param spine table[] { name, title, level, anchors }
---@return table[] nodes { title, href, level, children }
function M.toc_tree(spine)
  local root = { level = 0, children = {} }
  local stack = { root }
  local function add(title, href, level)
    while #stack > 1 and stack[#stack].level >= level do
      table.remove(stack)
    end
    local node = { title = title, href = href, level = level, children = {} }
    table.insert(stack[#stack].children, node)
    stack[#stack + 1] = node
  end
  for _, entry in ipairs(spine) do
    if entry.continues and #stack > 1 then
      -- the rest of a chapter split into several files: its headings go on
      -- under the chapter, the entry itself is no new one
      -- (拆成几个文件的章节的后续部分：小节接着挂在本章下面，条目本身不另起一条)
      while #stack > 2 and stack[#stack].level >= math.max(2, entry.level or 2) do
        table.remove(stack)
      end
      if not placeholder(entry.title) and entry.level and entry.level > 1 then
        add(entry.title, entry.name, entry.level)
      end
      for _, anchor in ipairs(entry.anchors or {}) do
        add(anchor.title, entry.name .. "#" .. anchor.id, math.max(2, anchor.level))
      end
    elseif not placeholder(entry.title) then
      local level = math.max(1, entry.level or 1)
      if M.is_back_matter(entry.original or entry.title) then
        -- an index or a glossary stands on its own, whatever level the catalog
        -- gave its first file
        -- (索引或术语表自成一条，不管目录给它的第一个文件标了几级)
        level = 1
      end
      add(entry.title, entry.name, level)
      for _, anchor in ipairs(entry.anchors or {}) do
        -- The catalog's own level, as long as it stays under the entry: the
        -- second file of a split chapter starts mid-chapter, at a section, and
        -- what follows climbs back up to the chapter's own sections.
        -- (用目录自己的层级，只要仍在本条目之下：拆分章节的第二个文件从章中间的某一节开始，后面的小节会
        --  回升到本章自己的节一级)
        local floor = entry.continues and 2 or ((entry.level or 1) + 1)
        add(anchor.title, entry.name .. "#" .. anchor.id, math.max(floor, anchor.level))
      end
    end
  end
  return root.children
end

---@param nodes table[]
---@return integer
function M.depth(nodes)
  local deepest = 0
  for _, node in ipairs(nodes) do
    deepest = math.max(deepest, 1 + M.depth(node.children))
  end
  return deepest
end

---@param nodes table[]
---@return string
function M.nav_list(nodes)
  if #nodes == 0 then
    return ""
  end
  local parts = { "<ol>" }
  for _, node in ipairs(nodes) do
    parts[#parts + 1] = string.format('<li><a href="%s">%s</a>%s</li>', node.href, escape(node.title), M.nav_list(node.children))
  end
  parts[#parts + 1] = "</ol>"
  return table.concat(parts)
end

---@param nodes table[]
---@param counter table|nil { n = integer } play order so far(到目前为止的播放顺序)
---@return string
function M.ncx_points(nodes, counter)
  counter = counter or { n = 0 }
  local parts = {}
  for _, node in ipairs(nodes) do
    counter.n = counter.n + 1
    local order = counter.n
    parts[#parts + 1] = string.format(
      '<navPoint id="p%d" playOrder="%d"><navLabel><text>%s</text></navLabel><content src="%s"/>%s</navPoint>',
      order,
      order,
      escape(node.title),
      node.href,
      M.ncx_points(node.children, counter)
    )
  end
  return table.concat(parts, "\n")
end

---Point links between chapters at this book's files: the book linked to its
---own file names (`ch07.xhtml#…`), which are not the names here. A link to a
---chapter left out keeps its text and loses the link.
---(把跨章链接改指向本书的文件：原书链接的是它自己的文件名（ch07.xhtml#…），而这里的文件名不同。指向未收入
--- 章节的链接保留文字、去掉链接)
---@param body string
---@param renamed table<string, string> original file -> file here(原文件名 → 本书文件名)
---@return string
function M.relink(body, renamed)
  return (body:gsub('href="([^"#:]+%.x?html?)(#?[^"]*)"', function(file, fragment)
    local target = renamed[vim.fs.basename(file)]
    if target then
      return string.format('href="%s%s"', target, fragment)
    end
    return 'href="' .. (fragment ~= "" and fragment or "#") .. '"'
  end))
end

---The image type of a file, from its first bytes: covers come without an
---extension.
---(由开头几个字节判断图片类型：封面下载下来没有扩展名)
---@param path string
---@return string|nil
function M.image_type(path)
  local file = io.open(path, "rb")
  if not file then
    return nil
  end
  local head = file:read(12) or ""
  file:close()
  if head:sub(1, 8) == "\137PNG\r\n\26\n" then
    return "png"
  elseif head:sub(1, 3) == "\255\216\255" then
    return "jpg"
  elseif head:sub(1, 4) == "GIF8" then
    return "gif"
  elseif head:sub(1, 4) == "RIFF" and head:sub(9, 12) == "WEBP" then
    return "webp"
  end
  return nil
end

---Is the book typeset anew (`weread.epub_style`) rather than with its own
---stylesheets? `opts.restyle` decides, then `epub.restyle` in the config; on
---unless turned off.
---(是否用统一排版（weread.epub_style）而不是书自己的样式表？先看 opts.restyle，再看配置里的
--- epub.restyle；不关掉就是开着的)
---@param opts table|nil
---@return boolean
function M.restyle(opts)
  if opts and opts.restyle ~= nil then
    return opts.restyle ~= false
  end
  local configured = (require("weread.config").get().epub or {}).restyle
  return configured ~= false
end

---Every file of the EPUB for a book, from the cache.
---(从缓存生成一本书的 EPUB 全部文件)
---@param book table { book_id, title, author }
---@param chapters table[] the catalog(目录)
---@param opts table|nil { mode = "only"|"bilingual", cover = string|nil, restyle = boolean|nil } cover: path of the cover image(封面图片路径)
---@return table result { files, chapters, translated, missing, untranslated }
function M.build(book, chapters, opts)
  opts = opts or {}
  local mode = opts.mode == "bilingual" and "bilingual" or "only"
  local llm = require("weread.llm_translate")
  local book_id = tostring(book.book_id)
  local lang = mode == "only" and "zh-CN" or "en"
  local files = {}
  local css_names, css_seen = {}, {}
  local images = {}
  local spine = {}
  local missing, untranslated = {}, {}
  local translated = 0
  -- the book's own file of each chapter, so links between chapters can be
  -- pointed at the files of this book
  -- (每章在原书里的文件名，书内跨章链接据此改指向本书的文件)
  local renamed = {}
  -- one typesetting for the whole book instead of the book's own stylesheets
  -- (全书统一排版，不用书自己的样式表)
  local restyle = M.restyle(opts)
  local style = require("weread.epub_style")
  local next_id = 0
  for _, chapter in ipairs(chapters) do
    if session.is_readable(chapter) and vim.fn.filereadable(cache.chapter_file(book_id, chapter, "xhtml")) == 1 then
      next_id = next_id + 1
      for _, original in ipairs(type(chapter.files) == "table" and chapter.files or {}) do
        renamed[vim.fs.basename(tostring(original))] = string.format("c%04d.xhtml", next_id)
      end
    end
  end

  local previous_chapter = nil
  -- pages named only by their heading, which stand at the top of the contents
  -- (只靠自己标题命名的页面，放在目录顶层)
  local placeholder_pages = {}
  for _, chapter in ipairs(chapters) do
    if session.is_readable(chapter) then
      local source = cache.read(cache.chapter_file(book_id, chapter, "xhtml"))
      -- a chapter cached before translations were told apart still carries
      -- WeRead's: only the LLM's go into the book
      -- (区分译文之前缓存的章节还带着微信读书的译文：书里只放大模型的)
      source = source and (require("weread.xhtml").split_translation(source))
      if not source or source == "" then
        missing[#missing + 1] = chapter.title or tostring(chapter.chapterUid)
      else
        local items = llm.load(book_id, chapter).items or {}
        local text, count
        if mode == "only" then
          text, count = llm.translated_only(source, items)
        else
          text, count = llm.bilingual(source, items)
        end
        if count > 0 then
          translated = translated + 1
        else
          untranslated[#untranslated + 1] = chapter.title or tostring(chapter.chapterUid)
        end
        -- the chapter's stylesheet, shared by every chapter that has the same one
        -- (章节的样式表：内容相同的章节共用一份)
        local links = {}
        local css = not restyle and cache.read(cache.chapter_file(book_id, chapter, "css")) or nil
        if css and css ~= "" then
          local name = css_seen[css]
          if not name then
            name = string.format("styles/book%d.css", #css_names + 1)
            css_seen[css] = name
            css_names[#css_names + 1] = name
            files[#files + 1] = { name = "OEBPS/" .. name, data = css, id = "css" .. #css_names, media = "text/css" }
          end
          links[#links + 1] = name
        end
        links[#links + 1] = "styles/weread.css"
        local body = M.xml_body(M.body_of(text))
        if restyle then
          body = style.body(body)
        end
        body = place_images(body, book_id, images, files)
        body = M.relink(body, renamed)
        local id = string.format("c%04d", #spine + 1)
        local title = M.label(chapter.title, chapter.translateTitle, mode)
        local headings = M.heading_texts(body)
        if mode == "only" and not (chapter.translateTitle and vim.trim(chapter.translateTitle) ~= "") then
          -- no translated title in the catalog: the page's first heading. Not the
          -- one the first anchor points at — some books aim it at the first
          -- section (DDIA's chapter 1 points at "Operational Versus Analytical
          -- Systems").
          -- (目录里没有译名：用页面上的第一个标题。不能用第一个 anchor 指向的那个——有的书把它指向第一节
          --  （DDIA 第 1 章指向的是「Operational Versus Analytical Systems」）)
          local heading = body:match("<h[1-6][^>]*>(.-)</h[1-6]>")
          local own = heading and vim.trim((require("weread.xhtml").decode_entities((heading:gsub("<[^>]*>", ""))):gsub("%s+", " "))) or nil
          if own and own ~= "" and not M.is_placeholder(title, book.title) then
            title = own
          end
        end
        if M.is_placeholder(chapter.title, book.title) then
          -- Named after the book: the next file of a split chapter, which has no
          -- entry of its own, or a page (the authors, the colophon) whose real
          -- name is its own heading.
          -- (以书名命名的：拆分章节的下一个文件——它不单独成条；或者一页真正的名字就是它自己标题的页面
          --  （作者介绍、版权页）)
          title = ""
          if not M.continues(chapter, previous_chapter) then
            local heading = body:match("<h[1-6][^>]*>(.-)</h[1-6]>")
            title = heading and vim.trim((require("weread.xhtml").decode_entities((heading:gsub("<[^>]*>", ""))):gsub("%s+", " "))) or ""
            if title ~= "" then
              placeholder_pages[#placeholder_pages + 1] = #spine + 1
            end
          end
        end
        local name = id .. ".xhtml"
        files[#files + 1] = {
          name = "OEBPS/" .. name,
          data = chapter_document(title, links, body, lang),
          id = id,
          media = "application/xhtml+xml",
          -- EPUB 3 wants a page with formulas to say so(EPUB 3 要求含公式的页面声明 mathml)
          properties = body:find("<math", 1, true) and "mathml" or nil,
        }
        spine[#spine + 1] = {
          id = id,
          name = name,
          title = title,
          original = chapter.title,
          level = tonumber(chapter.level) or 1,
          -- headings inside the chapter that the catalog names, each found in this body
          -- (目录里列出的、章内的小节标题，每条都确认在正文里能找到)
          anchors = M.anchors(chapter, body, mode, headings),
          -- The second and later files of a split chapter (or index): the
          -- catalog lists them below level 1 and their first file is the
          -- previous entry.
          -- (拆分章节（或索引）的第二个及以后的文件：目录把它们列在 1 级以下，而它们的第一个文件就是前一条)
          continues = M.continues(chapter, previous_chapter),
        }
        if placeholder_pages[#placeholder_pages] == #spine then
          spine[#spine].level = 1
          spine[#spine].anchors = {}
        end
      end
      previous_chapter = chapter
    end
  end
  M.drop_dead_fragments(files)
  files[#files + 1] = {
    name = "OEBPS/styles/weread.css",
    data = restyle and style.CSS or EXTRA_CSS,
    id = "css-weread",
    media = "text/css",
  }

  local title = (book.title or book_id) .. (mode == "only" and "（译文）" or "（双语）")
  -- the cover: the image, as the manifest's cover-image, and a page of its own
  -- first in the book
  -- (封面：作为 manifest 的 cover-image 的图片，以及书里第一页单独的封面页)
  local cover = nil
  if opts.cover and vim.fn.filereadable(opts.cover) == 1 then
    local ext = (M.image_type(opts.cover) or "jpg")
    cover = { name = "images/cover." .. ext }
    files[#files + 1] = {
      name = "OEBPS/" .. cover.name,
      path = opts.cover,
      id = "cover-image",
      media = MEDIA_TYPES[ext] or "image/jpeg",
      properties = "cover-image",
    }
    files[#files + 1] = {
      name = "OEBPS/cover.xhtml",
      id = "cover",
      media = "application/xhtml+xml",
      data = chapter_document(title, { "styles/weread.css" }, string.format(
        '<div class="wr-cover"><img src="%s" alt="%s"/></div>',
        cover.name,
        escape(title)
      ), lang),
    }
  end
  local identifier = "urn:weread-nvim:" .. book_id .. ":" .. mode

  -- table of contents, EPUB 3 nav(目录，EPUB 3 的 nav)
  -- the catalog's levels, or the numbering's when they say nothing
  -- (用目录的层级；目录的层级说明不了结构时用编号推出的)
  local originals, levels = {}, {}
  for index, entry in ipairs(spine) do
    originals[index], levels[index] = entry.original or entry.title, entry.level or 1
  end
  local derived = M.derive_levels(originals, levels)
  for index, entry in ipairs(spine) do
    local shift = derived[index] - (entry.level or 1)
    entry.level = derived[index]
    for _, anchor in ipairs(entry.anchors or {}) do
      anchor.level = anchor.level + shift
    end
  end
  local tree = M.toc_tree(spine)
  local nav = { M.nav_list(tree) }
  files[#files + 1] = {
    name = "OEBPS/nav.xhtml",
    id = "nav",
    media = "application/xhtml+xml",
    properties = "nav",
    data = table.concat({
      '<?xml version="1.0" encoding="utf-8"?>',
      "<!DOCTYPE html>",
      string.format('<html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops" lang="%s" xml:lang="%s">', lang, lang),
      "<head><title>" .. escape(title) .. "</title></head>",
      '<body><nav epub:type="toc" id="toc"><h1>目录</h1>',
      table.concat(nav, "\n"),
      "</nav>",
      cover and '<nav epub:type="landmarks" hidden=""><ol><li><a epub:type="cover" href="cover.xhtml">封面</a></li></ol></nav>' or "",
      "</body></html>",
    }, "\n"),
  }
  -- and the EPUB 2 one, for readers that only know that(以及 EPUB 2 的目录，给只认它的阅读器)
  local points = { M.ncx_points(tree) }
  files[#files + 1] = {
    name = "OEBPS/toc.ncx",
    id = "ncx",
    media = "application/x-dtbncx+xml",
    data = table.concat({
      '<?xml version="1.0" encoding="utf-8"?>',
      '<ncx xmlns="http://www.daisy.org/z3986/2005/ncx/" version="2005-1">',
      '<head><meta name="dtb:uid" content="' .. escape(identifier) .. '"/><meta name="dtb:depth" content="' .. M.depth(tree) .. '"/></head>',
      "<docTitle><text>" .. escape(title) .. "</text></docTitle>",
      "<navMap>",
      table.concat(points, "\n"),
      "</navMap></ncx>",
    }, "\n"),
  }

  local manifest, itemrefs = {}, {}
  for _, file in ipairs(files) do
    if file.id then
      manifest[#manifest + 1] = string.format(
        '<item id="%s" href="%s" media-type="%s"%s/>',
        file.id,
        (file.name:gsub("^OEBPS/", "")),
        file.media,
        file.properties and (' properties="' .. file.properties .. '"') or ""
      )
    end
  end
  if cover then
    itemrefs[#itemrefs + 1] = '<itemref idref="cover" linear="yes"/>'
  end
  for _, entry in ipairs(spine) do
    itemrefs[#itemrefs + 1] = string.format('<itemref idref="%s"/>', entry.id)
  end
  files[#files + 1] = {
    name = "OEBPS/content.opf",
    data = table.concat({
      '<?xml version="1.0" encoding="utf-8"?>',
      '<package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="bookid">',
      '<metadata xmlns:dc="http://purl.org/dc/elements/1.1/">',
      '<dc:identifier id="bookid">' .. escape(identifier) .. "</dc:identifier>",
      "<dc:title>" .. escape(title) .. "</dc:title>",
      "<dc:creator>" .. escape(book.author or "") .. "</dc:creator>",
      "<dc:language>" .. lang .. "</dc:language>",
      '<meta property="dcterms:modified">' .. os.date("!%Y-%m-%dT%H:%M:%SZ") .. "</meta>",
      -- EPUB 2 readers find the cover by this(EPUB 2 阅读器靠这一行找封面)
      cover and '<meta name="cover" content="cover-image"/>' or "",
      "</metadata>",
      "<manifest>",
      table.concat(manifest, "\n"),
      "</manifest>",
      '<spine toc="ncx">',
      table.concat(itemrefs, "\n"),
      "</spine>",
      "</package>",
    }, "\n"),
  }
  files[#files + 1] = {
    name = "META-INF/container.xml",
    data = table.concat({
      '<?xml version="1.0" encoding="utf-8"?>',
      '<container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">',
      '<rootfiles><rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/></rootfiles>',
      "</container>",
    }, "\n"),
  }

  return {
    files = files,
    title = title,
    cover = cover ~= nil,
    toc = tree,
    chapters = #spine,
    translated = translated,
    missing = missing,
    untranslated = untranslated,
  }
end

---Zip the files into an EPUB: `mimetype` first and stored, as the format
---requires, then the rest.
---(把文件打包成 EPUB：按格式要求，mimetype 放在最前且不压缩，然后是其余文件)
---@param path string
---@param files table[] { name, data?, path? }
---@return boolean ok
---@return string|nil err
function M.write(path, files)
  if vim.fn.executable("zip") ~= 1 then
    return false, "找不到 zip 命令"
  end
  local dir = vim.fn.tempname() .. "-epub"
  local ok, err = pcall(function()
    assert(cache.write(dir .. "/mimetype", "application/epub+zip"), "写不进临时目录")
    for _, file in ipairs(files) do
      local target = dir .. "/" .. file.name
      if file.path then
        local data = cache.read(file.path)
        assert(data and cache.write(target, data), "复制不了 " .. file.path)
      else
        assert(cache.write(target, file.data), "写不进 " .. target)
      end
    end
    vim.fn.mkdir(vim.fn.fnamemodify(path, ":h"), "p")
    if vim.fn.filereadable(path) == 1 then
      vim.uv.fs_unlink(path)
    end
    local first = vim.system({ "zip", "-X", "-0", "-q", path, "mimetype" }, { cwd = dir }):wait()
    assert(first.code == 0, "zip 失败：" .. tostring(first.stderr))
    local rest = vim.system({ "zip", "-X", "-r", "-9", "-q", path, "META-INF", "OEBPS" }, { cwd = dir }):wait()
    assert(rest.code == 0, "zip 失败：" .. tostring(rest.stderr))
  end)
  vim.fn.delete(dir, "rf")
  if not ok then
    return false, (tostring(err):gsub("^.-:%d+: ", ""))
  end
  return true, nil
end

-- ------------------------------------------------------------- the check

---@param message string
---@param level integer|nil
local function say(message, level)
  vim.notify("weread: " .. message, level or vim.log.levels.INFO, { id = "weread-epub", title = "WeRead EPUB" })
end


---Look the finished book over before it leaves: every file well-formed, every
---page and image in the manifest, the cover there, the contents nested and
---pointing at places that exist. Errors stop the upload; warnings are told.
---(书在送出之前过一遍：每个文件都是合式 XML、每页每张图都在 manifest 里、封面在、目录有层次且指向存在的
--- 位置。错误会拦下上传；警告只是告知)
---@param result table from M.build
---@return string[] errors
---@return string[] warnings
function M.check(result)
  local errors, warnings = {}, {}
  local by_name = {}
  for _, file in ipairs(result.files) do
    by_name[file.name] = file
  end
  local xmllint = vim.fn.executable("xmllint") == 1
  for _, file in ipairs(result.files) do
    if file.data and (file.name:match("%.xhtml$") or file.name:match("%.opf$") or file.name:match("%.ncx$") or file.name:match("%.xml$")) then
      if xmllint then
        local check = vim.system({ "xmllint", "--noout", "--nonet", "-" }, { stdin = file.data }):wait()
        if check.code ~= 0 then
          local first = vim.split(vim.trim(check.stderr or ""), "\n")[1] or "?"
          errors[#errors + 1] = string.format("%s 不是合式 XML：%s", file.name:gsub("^OEBPS/", ""), (first:gsub("^%-:%d+: ", "")))
        end
      end
      if file.name:match("^OEBPS/c%d+%.xhtml$") then
        -- every image a page shows is in the book(页面显示的每张图都在书里)
        for src in file.data:gmatch('<img[^>]-src="([^"]+)"') do
          if not by_name["OEBPS/" .. src] then
            errors[#errors + 1] = string.format("%s 引用了不存在的图片 %s", file.name:gsub("^OEBPS/", ""), src)
          end
        end
        if file.data:find('src="https?://') then
          warnings[#warnings + 1] = file.name:gsub("^OEBPS/", "") .. " 还引用着网络资源"
        end
      end
    end
  end
  if not result.cover then
    warnings[#warnings + 1] = "没有封面：" .. tostring(result.cover_reason or "下载封面失败")
  end
  -- figures the book shows but could not carry(书里有、却没能放进来的插图)
  local dropped = 0
  for _, file in ipairs(result.files) do
    if file.data and file.name:match("^OEBPS/c%d+%.xhtml$") then
      local _, count = file.data:gsub('<span class="wr%-missing%-figure">', "")
      dropped = dropped + count
    end
  end
  if dropped > 0 then
    warnings[#warnings + 1] = string.format("有 %d 张插图下载不下来，只留了图注文字", dropped)
  end
  -- the contents: not flat when the catalog has levels, every link landing
  -- (目录：目录本身有层级时不能是平的，每个链接都要落得到地方)
  local entries, broken = 0, 0
  local function walk(nodes)
    for _, node in ipairs(nodes) do
      entries = entries + 1
      local file, id = node.href:match("^([^#]+)#?(.*)$")
      local page = by_name["OEBPS/" .. file]
      if not page or (id ~= "" and not page.data:find('id="' .. id .. '"', 1, true)) then
        broken = broken + 1
      end
      if node.title == "" then
        errors[#errors + 1] = "目录里有空标题：" .. node.href
      end
      walk(node.children)
    end
  end
  walk(result.toc or {})
  if entries == 0 then
    errors[#errors + 1] = "目录是空的"
  end
  if broken > 0 then
    errors[#errors + 1] = string.format("目录里有 %d 条指向不存在的位置", broken)
  end
  return errors, warnings
end

---The cover of a book, downloaded once into the book's directory.
---(书的封面，下载一次存在书的目录里)
---@param book table
---@param callback fun(path: string|nil, reason: string|nil) reason: why there is none(没有封面时的原因)
function M.fetch_cover(book, callback)
  local log = require("weread.log")
  local path = cache.book_dir(book.book_id) .. "/cover"
  if vim.fn.filereadable(path) == 1 and M.image_type(path) then
    callback(path, nil)
    return
  end
  ---@param reason string
  local function none(reason)
    log.warn("epub: no cover for %s: %s", tostring(book.book_id), reason)
    callback(nil, reason)
  end
  local function download(url, source)
    url = require("weread.protocol").normalize_cover_url(url)
    require("weread.http").download(url, path, { referer = false, origin = false, no_cookies = true, timeout = 30 }, function(res)
      if res.code >= 200 and res.code < 300 and M.image_type(path) then
        callback(path, nil)
        return
      end
      os.remove(path)
      none(string.format("下载 %s 的封面失败（%s）", source, tostring(res.error or ("HTTP " .. tostring(res.code)))))
    end)
  end
  if type(book.cover) == "string" and book.cover ~= "" then
    download(book.cover, "书籍信息")
    return
  end
  -- The book's meta does not keep the cover (the reader never needed it), so
  -- ask for it: the official API's /book/info first, it answers whatever the
  -- web session is doing; then the web reader's, which wants a live session.
  -- (书的 meta 里没有存封面（阅读器从来用不到），所以去问：先问官方 API 的 /book/info，它不受网页会话影响；
  --  再问网页阅读器的那个，它需要会话有效)
  local function remember(url)
    book.cover = url
    local meta = cache.read_meta(book.book_id)
    if type(meta) == "table" then
      meta.cover = url
      pcall(cache.write_meta, book.book_id, meta)
    end
  end
  local function from_web(previous)
    local http = require("weread.http")
    local origin = require("weread.config").web_origin()
    http.request({ url = origin .. "/web/book/info?bookId=" .. tostring(book.book_id), timeout = 15 }, function(res)
      local data, err = http.decode_json(res)
      local url = type(data) == "table" and data.cover or nil
      if type(url) == "string" and url ~= "" then
        remember(url)
        download(url, "网页书籍信息")
        return
      end
      local said = type(data) == "table" and (data.errMsg or data.errmsg) or err
      none(string.format("书籍信息里没有封面地址（%s；网页：%s）", tostring(previous), tostring(said or "没有 cover 字段")))
    end)
  end
  local ok_gateway, gateway = pcall(require, "weread.api_gateway")
  if ok_gateway and gateway.book_info then
    gateway.book_info(book.book_id, function(ok, data)
      local url = ok and type(data) == "table" and data.cover or nil
      if type(url) == "string" and url ~= "" then
        remember(url)
        download(url, "官方书籍信息")
        return
      end
      from_web(ok and "官方接口没有 cover 字段" or ("官方接口：" .. tostring(data)))
    end)
    return
  end
  from_web("没有官方接口")
end

---Download every illustration the book's cached chapters show that is not on
---disk yet. The reader fetches illustrations only for the pages it draws, so a
---book translated straight through has most of its figures still on the web —
---and the book left without them.
---(把书里已缓存章节显示的、还不在磁盘上的插图全部下载下来。阅读器只为它画出的页面取插图，所以一本直接整本翻译的
--- 书，大部分图还在网上——书里也就没有它们)
---@param book table
---@param chapters table[]
---@param callback fun(stats: { wanted: integer, fetched: integer, failed: string[] })
function M.fetch_images(book, chapters, callback)
  local image = require("weread.image")
  local pipeline = require("weread.chapter_pipeline")
  local book_id = tostring(book.book_id)
  local dir = cache.assets_dir(book_id)
  local wanted, seen = {}, {}
  for _, chapter in ipairs(chapters) do
    if session.is_readable(chapter) then
      local source = cache.read(cache.chapter_file(book_id, chapter, "xhtml")) or ""
      for src in source:gmatch('<img[^>]-src="([^"]+)"') do
        if not seen[src] and image.is_remote(src) and not pipeline.cached_image_path(book_id, src) then
          seen[src] = true
          wanted[#wanted + 1] = src
        end
      end
    end
  end
  local stats = { wanted = #wanted, fetched = 0, failed = {} }
  if #wanted == 0 then
    callback(stats)
    return
  end
  say(string.format("正在下载书里的 %d 张插图…", #wanted))
  local index, active = 0, 0
  local function pump()
    while active < M.IMAGE_WORKERS and index < #wanted do
      index = index + 1
      active = active + 1
      local src = wanted[index]
      image.ensure_local(src, dir, function(path, err)
        active = active - 1
        if path then
          stats.fetched = stats.fetched + 1
        else
          stats.failed[#stats.failed + 1] = src
          require("weread.log").warn("epub: illustration %s: %s", src, tostring(err))
        end
        if active == 0 and index >= #wanted then
          callback(stats)
        else
          vim.schedule(pump)
        end
      end)
    end
  end
  pump()
end

---Illustrations downloaded at once.(同时下载的插图数)
M.IMAGE_WORKERS = 6

---Build, check, write and upload: the end of every export.
---(构建、检查、写出、上传：每次导出的收尾)
---@param book table
---@param catalog table[]
---@param opts table { mode, path, upload }
---@param failed string[]|nil chapters whose translation failed(翻译出错的章节)
function M.finish(book, catalog, opts, failed)
  failed = failed or {}
  M.fetch_images(book, catalog, function(image_stats)
  M.fetch_cover(book, function(cover, cover_reason)
    local result = M.build(book, catalog, { mode = opts.mode, cover = cover })
    result.cover_reason = cover_reason
    result.images_failed = image_stats.failed
    if result.chapters == 0 then
      say("一章都没下载下来，没有导出", vim.log.levels.ERROR)
      return
    end
    local path = opts.path
    if not path then
      local name = result.title:gsub("[/\\:%*%?\"<>|]", "_")
      path = require("weread.config").path("exports/" .. name .. ".epub")
    end
    local errors, warnings = M.check(result)
    local ok, err = M.write(path, result.files)
    if not ok then
      say("导出 EPUB 失败：" .. tostring(err), vim.log.levels.ERROR)
      return
    end
    -- Remember the file, so `:WeReadEpub upload` finds it whatever its mode or path.
    -- (记下文件，`:WeReadEpub upload` 不论导出时用的版本和路径都能找到它)
    local last = require("weread.prefs").get("epub_last")
    last = type(last) == "table" and last or {}
    last[tostring(book.book_id)] = path
    require("weread.prefs").set("epub_last", last)
    local lines = {
      string.format("已导出：%s", vim.fn.fnamemodify(path, ":~")),
      string.format("%d 章，其中 %d 章有译文；目录 %d 层%s", result.chapters, result.translated, M.depth(result.toc), result.cover and "，带封面" or ""),
    }
    local function listed(names)
      return table.concat(vim.list_slice(names, 1, 5), "、") .. (#names > 5 and "…" or "")
    end
    if #result.missing > 0 then
      lines[#lines + 1] = string.format("下载失败、未收入的 %d 章：%s", #result.missing, listed(result.missing))
    end
    if #result.untranslated > 0 then
      lines[#lines + 1] = string.format("没有译文、保留原文的 %d 章：%s", #result.untranslated, listed(result.untranslated))
    end
    if #failed > 0 then
      lines[#lines + 1] = string.format("翻译出错的 %d 章（再执行一次会重试）：%s", #failed, listed(failed))
    end
    for _, warning in ipairs(warnings) do
      lines[#lines + 1] = "注意：" .. warning
    end
    if #errors > 0 then
      for _, problem in ipairs(vim.list_slice(errors, 1, 8)) do
        lines[#lines + 1] = "检查不通过：" .. problem
      end
      lines[#lines + 1] = "没有上传；这多半是导出的毛病，请把这段提示发给开发者"
      say(table.concat(lines, "\n"), vim.log.levels.ERROR)
      return
    end
    lines[#lines + 1] = "检查通过：格式、图片、目录都没问题"
    local partial = #result.missing > 0 or #result.untranslated > 0 or #failed > 0 or #warnings > 0
    local level = partial and vim.log.levels.WARN or vim.log.levels.INFO
    if opts.upload == false then
      lines[#lines + 1] = "用微信读书的「传书」导入，手机上就是一本带译文的书"
      say(table.concat(lines, "\n"), level)
      return
    end
    say(table.concat(lines, "\n") .. "\n正在传到微信读书书架…", level)
    M.upload(book, path)
  end)
  end)
end

-- ------------------------------------------------------------- whole book


---Chapters downloaded at once; chapters translated one at a time, with this
---many batches in flight. The gateway turns away requests past a few at once
---per user ("Concurrency limit exceeded"), and the reader may be translating
---the page on screen at the same time.
---(同时下载的章数；翻译一次一章、同时在途这么多批。网关对每个用户同时只放行几个请求（"Concurrency
--- limit exceeded"），而读者此时可能也正在翻译屏幕上这一页)
M.FETCH_WORKERS = 2
---Minutes of no progress after which the status says the export may be stuck.
---(多少秒没有进展，状态就提示可能卡住了)
M.QUIET_WARN_S = 600
M.TRANSLATE_WORKERS = 1
M.TRANSLATE_BATCHES = 2

---The export under way, so a second :WeReadEpub reports instead of starting
---another, and :WeReadEpub stop can end it.
---(进行中的导出：再敲一次 :WeReadEpub 只报告进度而不是另起一个，:WeReadEpub stop 可以停掉它)
local job = nil

---Stop the export under way, for sure: its translations are cancelled (only
---the export's own; the page's go on), the job is cleared at once, and a new
---:WeReadEpub goes on from where this one stopped.
---(可靠地停掉进行中的导出：取消它的翻译（只取消导出自己的；页面的照常），立即清掉任务，再执行 :WeReadEpub
--- 会从停下的地方接着做)
---@return boolean stopped
function M.stop()
  local current = job
  if not current then
    vim.notify("weread: 没有正在进行的导出", vim.log.levels.INFO)
    return false
  end
  current.stopped = true
  job = nil
  require("weread.llm_translate").cancel({ owner = "epub", book_id = current.book_id })
  if current.pump then
    current.pump()
  end
  if not current.finished then
    -- nothing came back to finish it(没有任何回调来收尾)
    current.finished = true
    say("已停止导出；已下载和已译出的部分都留着，再执行 :WeReadEpub 会接着做", vim.log.levels.WARN)
  end
  return true
end

---Run `work` over every item, `workers` at a time, then call `done`.
---(对每一项执行 work，同时最多 workers 个，全部完成后调用 done)
---@param items any[]
---@param workers integer
---@param work fun(item: any, next: fun())
---@param done fun()
---@param stopped fun(): boolean
local function each(items, workers, work, done, stopped)
  local index, active, finished = 0, 0, false
  local function pump()
    if finished then
      return
    end
    -- stopped: done now, whatever is still out there; the work that comes back
    -- later lands on a finished run and does nothing
    -- (已停止：不管还有什么没回来，现在就结束；之后回来的工作落在已结束的一轮上，什么也不做)
    if stopped() then
      finished = true
      done()
      return
    end
    while active < workers and index < #items and not stopped() do
      index = index + 1
      active = active + 1
      local item = items[index]
      work(item, function()
        active = active - 1
        vim.schedule(pump)
      end)
    end
    if active == 0 and index >= #items then
      finished = true
      done()
    end
  end
  pump()
  return pump
end

---Is a chapter's LLM translation done, by the model in use?
---(某章的大模型译文是否已完成、且是所用的模型译的)
---@param book_id string
---@param chapter table
---@param model string
---@return boolean
local function translated(book_id, chapter, model)
  local data = require("weread.llm_translate").load(book_id, chapter)
  return data.complete == true and data.model == model
end

---How far the export under way has got, for a reader asking.
---(进行中的导出做到哪了，给问起的读者看)
---@return string|nil
function M.status_text()
  if not job then
    return nil
  end
  local minutes = math.floor((os.time() - job.started) / 60)
  local lines = {
    string.format("正在导出《%s》：%s %d / %d 章（已用 %d 分钟）", job.title or "?", job.phase, job.done, job.total, minutes),
  }
  if job.phase == "翻译" and job.current then
    local part = job.blocks_total > 0 and string.format("（%d / %d 段）", job.blocks_done, job.blocks_total) or ""
    lines[#lines + 1] = "当前：" .. job.current .. part
  end
  local quiet = os.time() - (job.progressed or job.started)
  if quiet >= M.QUIET_WARN_S then
    -- an estimate from a clock that has stopped is nonsense; say what is known
    -- (时钟停了时的估算毫无意义；只说知道的)
    lines[#lines + 1] = string.format("已经 %d 分钟没有进展，可能卡住了：:WeReadEpub stop 停下，再执行 :WeReadEpub 接着做", math.floor(quiet / 60))
  elseif job.phase == "翻译" and job.done < job.total then
    -- by paragraphs: chapters differ in length by tens of times
    -- (按段落估：章与章的长度能差几十倍)
    local paragraphs = job.blocks_all_done + job.blocks_done
    local spent = os.time() - (job.phase_started or job.started)
    if paragraphs >= 20 and spent > 0 then
      local per_chapter = paragraphs / math.max(1, job.done + (job.blocks_total > 0 and job.blocks_done / job.blocks_total or 0))
      local left = per_chapter * (job.total - job.done) - job.blocks_done
      lines[#lines + 1] = string.format("预计还要约 %d 分钟（按段落进度估算）", math.max(1, math.ceil(left * spent / paragraphs / 60)))
    end
  end
  if #job.failed > 0 then
    lines[#lines + 1] = string.format("翻译出错 %d 章（结束后再执行一次会重试）", #job.failed)
  end
  lines[#lines + 1] = "EPUB 要等全部做完才会写出；:WeReadEpub stop 停止"
  return table.concat(lines, "\n")
end

---Download and translate every chapter of the book that is not yet, then write
---the EPUB. Chapters already done are not touched again; one that fails is
---left as it is (untranslated, or out of the book) and named at the end.
---(把这本书还没下载、还没翻译的章节全部下载并翻译，然后写出 EPUB。已经完成的章节不再动；失败的章节
--- 保持原样（不翻译，或不收入）并在最后列出)
---@param book table
---@param catalog table[]
---@param opts { mode: string, path: string|nil, model: string|nil }
local function whole_book(book, catalog, opts)
  local pipeline = require("weread.chapter_pipeline")
  local llm = require("weread.llm_translate")
  local book_id = tostring(book.book_id)
  local model = opts.model
  local state = {
    stopped = false,
    phase = "下载",
    done = 0,
    total = 0,
    failed = {},
    started = os.time(),
    current = nil,
    title = book.title,
    book_id = book_id,
    -- paragraphs of the chapter on hand, for the estimate and the stall check
    -- (手头这一章的段落进度，用于估算剩余时间与判断是否卡住)
    blocks_done = 0,
    blocks_total = 0,
    blocks_all_done = 0,
    progressed = os.time(),
  }
  job = state
  local function stopped()
    return state.stopped
  end
  local readable = {}
  for _, chapter in ipairs(catalog) do
    if session.is_readable(chapter) then
      readable[#readable + 1] = chapter
    end
  end

  local function finish()
    if job == state then
      job = nil
    end
    if state.finished then
      return
    end
    state.finished = true
    if state.stopped then
      say("已停止导出；已下载和已译出的部分都留着，再执行 :WeReadEpub 会接着做", vim.log.levels.WARN)
      return
    end
    M.finish(book, catalog, opts, state.failed)
  end

  local function translate_all()
    local todo = {}
    for _, chapter in ipairs(readable) do
      local cached = vim.fn.filereadable(cache.chapter_file(book_id, chapter, "xhtml")) == 1
      if cached and not translated(book_id, chapter, model) then
        todo[#todo + 1] = chapter
      end
    end
    state.phase, state.done, state.total = "翻译", 0, #todo
    state.phase_started = os.time()
    if #todo > 0 then
      say(string.format("正在用 %s 翻译 %d 章…（:WeReadEpub stop 停止）", model, #todo))
    end
    state.pump = each(todo, M.TRANSLATE_WORKERS, function(chapter, next_one)
      state.current = chapter.title
      state.blocks_done, state.blocks_total = 0, 0
      state.progressed = os.time()
      local answered = false
      llm.run(book_id, chapter, {
        owner = "epub",
        model = model,
        workers = M.TRANSLATE_BATCHES,
        on_progress = function(count, total)
          state.blocks_done, state.blocks_total = count, total
          state.progressed = os.time()
        end,
        on_done = function(ok, err, stats)
          -- once per chapter, whatever ends it(每章只算一次，不管是什么让它结束的)
          if answered or state.finished then
            return
          end
          answered = true
          state.done = state.done + 1
          state.progressed = os.time()
          state.blocks_all_done = state.blocks_all_done + ((stats or {}).total or 0)
          if err == llm.CANCELLED and state.stopped then
            next_one()
            return
          end
          if not ok and err ~= "本章没有可翻译的外文" then
            state.failed[#state.failed + 1] = chapter.title or tostring(chapter.chapterUid)
            require("weread.log").warn("epub: translating %s failed: %s", tostring(chapter.title), tostring(err))
          end
          if state.done < state.total then
            say(M.status_text())
          end
          next_one()
        end,
      })
    end, finish, stopped)
  end

  local fetch = {}
  for _, chapter in ipairs(readable) do
    if vim.fn.filereadable(cache.chapter_file(book_id, chapter, "xhtml")) ~= 1 then
      fetch[#fetch + 1] = chapter
    end
  end
  state.total = #fetch
  if #fetch > 0 then
    say(string.format("整本导出：先下载没下载的 %d 章…（:WeReadEpub stop 停止）", #fetch))
  end
  state.pump = each(fetch, M.FETCH_WORKERS, function(chapter, next_one)
    pipeline.ensure_cached(book, chapter, function(ok, err)
      if state.finished then
        return
      end
      state.done = state.done + 1
      state.progressed = os.time()
      if not ok then
        require("weread.log").warn("epub: fetching %s failed: %s", tostring(chapter.title), tostring(err))
      end
      if state.done % 5 == 0 and state.done < state.total then
        say(M.status_text())
      end
      next_one()
    end)
  end, function()
    if not model then
      -- WeRead's translation was picked for the book: nothing to translate here
      -- (这本书选的是微信读书译文：这里没什么可译的)
      finish()
      return
    end
    translate_all()
  end, stopped)
end

---Books this exporter put on the shelf, by the book they were made from:
---{ [source id] = { book_id, md5 } }.
---(本导出器传到书架上的书，按来源书记录)
---@return table
local function uploaded()
  local value = require("weread.prefs").get("epub_uploads")
  return type(value) == "table" and value or {}
end

---Put an exported EPUB on the account's shelf (传书). A file the shelf already
---has, byte for byte, is not imported twice; an export that changed is a new
---book, and the reader is told the old one is still there.
---(把导出的 EPUB 传到账号书架（传书）。书架上已有逐字节相同的文件就不再导入；内容变了就是一本新书，并告诉
--- 读者旧的那本还在)
---@param book table the source book(来源书)
---@param path string
function M.upload(book, path)
  local source = tostring(book.book_id)
  local data = cache.read(path)
  local md5 = data and require("weread.crypto").md5_hex(data) or nil
  local previous = uploaded()[source]
  if previous and previous.md5 == md5 then
    say("书架上已经有这一版了（" .. tostring(previous.book_id) .. "），没有重复上传")
    return
  end
  require("weread.upload").import(path, function(ok, result)
    if not ok then
      say("传书失败：" .. tostring(result) .. "\n文件在 " .. vim.fn.fnamemodify(path, ":~") .. "，可以用「传书」手动导入", vim.log.levels.ERROR)
      return
    end
    local all = uploaded()
    all[source] = { book_id = result, md5 = md5, at = os.time() }
    require("weread.prefs").set("epub_uploads", all)
    local lines = { "已传到微信读书书架，手机上刷新书架就能看到：" .. vim.fs.basename(path) }
    if previous and previous.book_id and previous.book_id ~= result then
      lines[#lines + 1] = "之前传的旧版还在书架上，不需要的话在 App 里删掉"
    end
    say(table.concat(lines, "\n"))
  end, function(message)
    say(message)
  end)
end

---Export the open book as an EPUB: the whole book, downloading and translating
---whatever is not yet.
---(把当前这本书导出成 EPUB：整本书，没下载、没翻译的部分先下载、翻译)
---@param arg string|nil words: "bilingual" (original with the translation under it) or "only" (default), "cached" (only what is already here, nothing fetched or translated), "stop", a model name, or a file path(“bilingual” 双语、“only” 只有译文（默认）、“cached” 只用已有的、“stop” 停止、模型名，或文件路径)
function M.run(arg)
  local reader = require("weread.reader")
  local book = reader.state.book
  if not book then
    vim.notify("weread: 还没有打开任何书", vim.log.levels.WARN)
    return
  end
  local words = vim.split(vim.trim(arg or ""), "%s+", { trimempty = true })
  if words[1] == "status" then
    say(M.status_text() or "没有正在进行的导出")
    return
  end
  if words[1] == "stop" then
    M.stop()
    return
  end
  if job then
    say(M.status_text())
    return
  end
  local llm = require("weread.llm_translate")
  local models = (require("weread.config").get().lookup or {}).chapter_models or {}
  local opts = { mode = "only", path = nil, model = nil, cached = false, upload = true }
  local mode_given = false
  for _, word in ipairs(words) do
    if word == "bilingual" or word == "only" then
      opts.mode = word
      mode_given = true
    elseif word == "cached" then
      opts.cached = true
    elseif word == "local" then
      opts.upload = false
    elseif word == "upload" then
      -- only put the last export on the shelf(只把上次的导出传到书架)
      opts.upload_only = true
    elseif vim.tbl_contains(models, word) then
      opts.model = word
    elseif word:find("[/~]") or word:match("%.epub$") then
      opts.path = vim.fn.expand(word)
    else
      -- A mistyped model name must not become a file named after it.
      -- (打错的模型名不能变成以它命名的文件)
      say("未知参数：" .. word .. "（路径需含 / 或以 .epub 结尾）", vim.log.levels.WARN)
      return
    end
  end
  local catalog = (reader.state.catalog or {}).chapters or {}
  if opts.upload_only then
    local path = opts.path
    if not path and not mode_given then
      local last = require("weread.prefs").get("epub_last")
      path = type(last) == "table" and last[tostring(book.book_id)] or nil
    end
    if not path then
      local result = M.build(book, {}, { mode = opts.mode })
      path = require("weread.config").path("exports/" .. result.title:gsub("[/\\:%*%?\"<>|]", "_") .. ".epub")
    end
    if vim.fn.filereadable(path) ~= 1 then
      say("还没有导出过：" .. vim.fn.fnamemodify(path, ":~"), vim.log.levels.WARN)
      return
    end
    M.upload(book, path)
    return
  end
  if opts.cached then
    if M.build(book, catalog, { mode = opts.mode }).translated == 0 then
      vim.notify("weread: 这本书还没有大模型译过的章节", vim.log.levels.WARN)
      return
    end
    M.finish(book, catalog, opts)
    return
  end
  local function start(model)
    opts.model = model
    whole_book(book, catalog, opts)
  end
  if opts.model then
    start(opts.model)
    return
  end
  local engine = require("weread.translate").engine(book.book_id)
  local model = llm.model(book.book_id)
  if model or engine == "weread" or not require("weread.lookup").llm_available() then
    start(model)
    return
  end
  -- the book was never translated here: ask which model, as the 译文 key does
  -- (这本书还没在这里翻译过：像译文键那样问用哪个模型)
  local items = {}
  for _, name in ipairs(models) do
    items[#items + 1] = { text = "大模型 " .. name, engine = name }
  end
  require("weread.ui").select({
    title = "用哪个模型翻译整本书",
    items = items,
    on_choice = function(item)
      require("weread.translate").set_engine(book.book_id, item.engine)
      start(item.engine)
    end,
  })
end

return M
