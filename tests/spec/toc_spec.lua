--[[
Tests for the chapter TOC picker: the items (levels, read state, the current
chapter), the row format, the cached-chapter excerpt and the preview render,
and that the picker opens on the chapter being read.
(章节目录选择器的测试：条目（层级、已读状态、当前章节）、行格式、本地缓存章节的摘录与
预览渲染，以及选择器打开时停在正在读的那章)
]]

local toc = require("weread.toc")

local function join(lines)
  return table.concat(lines, "\n")
end

local CHAPTERS = {
  { chapterUid = 1, chapterIdx = 1, title = "封面", wordCount = 0, level = 1 },
  { chapterUid = 2, chapterIdx = 2, title = "第一部分 基础", wordCount = 100, level = 1 },
  { chapterUid = 3, chapterIdx = 3, title = "第1章 开始", wordCount = 12000, level = 2 },
  { chapterUid = 4, chapterIdx = 4, title = "第2章 继续", wordCount = 4000, level = 2 },
  { chapterUid = 5, chapterIdx = 5, title = "第二部分 进阶", wordCount = 100, level = 1 },
  { chapterUid = 6, chapterIdx = 6, title = "第3章 深入", wordCount = 8000, level = 2 },
}

local function readable(chapter)
  return (tonumber(chapter.wordCount) or 1) > 0
end

describe("toc.items", function()
  it("skips wordless entries and knows the chapter being read", function()
    local items, current = toc.items(CHAPTERS, 4, readable)
    eq(#items, 5, "the cover is not a chapter")
    eq(current, 3, "chapter index 4 is the third item")
    truthy(items[3].current)
    truthy(items[1].read and items[2].read, "chapters before the current one count as read")
    falsy(items[4].read)
    eq(items[1].text, "第一部分 基础", "the filter matches the title alone")
  end)

  it("indents by level and marks parts", function()
    local items = toc.items(CHAPTERS, nil, readable)
    eq(items[1].depth, 0)
    eq(items[2].depth, 1)
    truthy(items[1].part, "a level-1 entry followed by deeper ones is a part")
    falsy(items[2].part)
  end)

  it("has no current chapter when nothing is being read", function()
    local items, current = toc.items(CHAPTERS, nil, readable)
    eq(current, nil)
    for _, item in ipairs(items) do
      falsy(item.current or item.read)
    end
  end)
end)

describe("toc.format", function()
  it("draws the marker, the indent and the length", function()
    local items = toc.items(CHAPTERS, 3, readable)
    local row = toc.format(items[2])
    eq(row[1][1], "▶ ")
    eq(row[2][1], "  ", "level 2 is indented one step")
    eq(row[3][1], "第1章 开始")
    eq(row[3][2], "WereadPreviewCurrent")
    eq(row[4].virt_text[1][1], "1.2万字 ", "the length is right-aligned virtual text")
    eq(toc.format(items[1])[3][2], "WereadPreviewDim", "a read chapter is dimmed")
  end)
end)

describe("toc.paragraphs", function()
  it("reflows the cached markdown and drops the repeated title", function()
    local markdown = table.concat({
      "",
      "# 第1章 开始",
      "",
      "　　Before we get into the nuts and bolts of how to",
      "intercept signals, let us **move** the code.",
      "　　中文段落第一行，",
      "接着第二行。",
      "",
      "## 1.1 小节",
      "",
      "```",
      "go run ./cmd/api",
      "```",
      "![](/tmp/x.jpg)",
    }, "\n")
    local paragraphs = toc.paragraphs(markdown, "第1章 开始")
    eq(paragraphs[1].text, "Before we get into the nuts and bolts of how to intercept signals, let us move the code.")
    eq(paragraphs[2].text, "中文段落第一行，接着第二行。", "CJK lines join without a space")
    eq(paragraphs[3].text, "1.1 小节")
    truthy(paragraphs[3].heading)
    eq(paragraphs[4].text, "go run ./cmd/api")
    truthy(paragraphs[4].code)
    eq(paragraphs[5].text, "〔插图〕")
    for _, paragraph in ipairs(paragraphs) do
      falsy(paragraph.text == "第1章 开始", "the title is not repeated")
    end
  end)
end)

describe("toc.build_preview", function()
  it("explains the chapter and shows its opening", function()
    local items = toc.items(CHAPTERS, 3, readable)
    local lines = toc.build_preview(items[2], {
      total = 5,
      percent = 52,
      markdown = "# 第1章 开始\n\n　　正文开头。\n",
      width = 50,
    })
    local text = join(lines)
    matches(text, "第1章 开始")
    matches(text, "1%.2万字 · 约 30 分钟")
    matches(text, "▶ 正在读")
    matches(text, "读完本章约到全书 52%%")
    matches(text, "正文开头。")
    falsy(text:find("idx =", 1, true), "no raw item dump")
    for _, line in ipairs(lines) do
      truthy(vim.api.nvim_strwidth(line) <= 50, "too wide: " .. line)
    end
  end)

  it("lists a part's sections and says when the text is not on disk", function()
    local items = toc.items(CHAPTERS, 3, readable)
    local text = join(toc.build_preview(items[4], { total = 5, children = { "第3章 深入" }, width = 50 }))
    matches(text, "○ 未读")
    matches(text, "▎本部分  1 节")
    matches(text, "第3章 深入")
    matches(text, "本章还没下载")
  end)
end)

describe("toc.open", function()
  it("opens on the chapter being read, with the format and preview wired", function()
    local reader = require("weread.reader")
    local ui = require("weread.ui")
    local real_select = ui.select
    local captured = nil
    ui.select = function(opts)
      captured = opts
    end
    local saved_book, saved_catalog, saved_index = reader.state.book, reader.state.catalog, reader.state.index
    reader.state.book = { book_id = "toc-spec", title = "测试书" }
    reader.state.catalog = { chapters = CHAPTERS }
    reader.state.index = 4
    local ok, err = pcall(toc.open)
    reader.state.book, reader.state.catalog, reader.state.index = saved_book, saved_catalog, saved_index
    ui.select = real_select
    truthy(ok, tostring(err))
    truthy(captured, "the picker was shown")
    matches(captured.title, "读到第 3 章")
    eq(type(captured.format), "function")
    eq(type(captured.preview), "function")

    -- the picker lands on the current item(选择器落在当前条目上)
    local viewed = nil
    package.loaded["snacks"] = {
      picker = {
        actions = {
          list_scroll_center = function() end,
        },
      },
    }
    captured.snacks.on_show({
      list = {
        view = function(_, idx)
          viewed = idx
        end,
      },
    })
    eq(viewed, 3)
    eq(captured.items[3].label, "▶   第2章 继续", "vim.ui.select gets the marker inline")
  end)
end)
