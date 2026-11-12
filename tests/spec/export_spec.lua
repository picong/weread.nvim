--[[
Tests for the notes export: grouping highlights and thoughts by chapter in book
order, and the Markdown it writes.
(笔记导出的测试：按书中顺序把划线和想法分章归组，以及写出的 Markdown)
]]

local export = require("weread.export")

local CATALOG = {
  { chapterUid = 10, chapterIdx = 1, title = "第一章" },
  { chapterUid = 20, chapterIdx = 2, title = "第二章" },
}

local NOTES = {
  bookmarks = {
    chapters = { { chapterUid = 10, chapterIdx = 1, title = "第一章" }, { chapterUid = 20, chapterIdx = 2, title = "第二章" } },
    updated = {
      { chapterUid = 20, range = "50-60", markText = "第二章的划线", type = 1, createTime = 2 },
      { chapterUid = 10, range = "300-320", markText = "后面那条", type = 1, createTime = 3 },
      { chapterUid = 10, range = "100-120", markText = "前面那条\n第二行", type = 1, createTime = 1 },
    },
  },
  thoughts = {
    -- on a highlight(挂在划线上)
    { content = "想法甲", range = "100-120", chapter_uid = "10", time = os.time({ year = 2026, month = 10, day = 1, hour = 12 }) },
    -- on a passage with no highlight(针对没有划线的原文)
    { content = "想法乙\n第二段", abstract = "没划线的原文", range = "200-210", chapter_uid = "10", time = os.time({ year = 2026, month = 10, day = 2, hour = 12 }) },
  },
}

describe("export.group", function()
  it("orders chapters and entries the way the book reads", function()
    local chapters = export.group(NOTES, CATALOG)
    eq(#chapters, 2)
    eq(chapters[1].title, "第一章")
    eq(#chapters[1].entries, 3)
    eq(chapters[1].entries[1].text, "前面那条\n第二行")
    eq(chapters[1].entries[2].kind, "thought", "a thought without a highlight stands on its own")
    eq(chapters[1].entries[3].text, "后面那条")
    eq(chapters[2].entries[1].text, "第二章的划线")
  end)

  it("puts a thought under the highlight it was written on", function()
    local chapters = export.group(NOTES, CATALOG)
    eq(#chapters[1].entries[1].thoughts, 1)
    eq(chapters[1].entries[1].thoughts[1].content, "想法甲")
  end)
end)

describe("export.markdown", function()
  it("writes quotes, thoughts and a summary", function()
    local lines = export.markdown({ title = "测试书", author = "某人", book_id = "B1" }, export.group(NOTES, CATALOG))
    local text = table.concat(lines, "\n")
    matches(text, "^# 测试书\n")
    matches(text, "划线 3 条，想法 2 条")
    matches(text, "\n## 第一章\n")
    matches(text, "\n> 前面那条\n> 第二行\n")
    matches(text, "💭 想法甲  _2026%-10%-01_")
    matches(text, "\n> 没划线的原文\n")
    matches(text, "💭 想法乙\n   第二段\n   _2026%-10%-02_")
    truthy(text:find("## 第一章", 1, true) < text:find("## 第二章", 1, true))
  end)
end)
