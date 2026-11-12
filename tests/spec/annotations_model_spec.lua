--[[
Tests for weread.annotations_model: the pure functions of the annotations
family, and that the module really is a leaf (it loads no other weread module).
(annotations_model 的测试：这一族的纯函数，以及它确实是叶子——不会加载任何别的 weread 模块)
]]

local model = require("weread.annotations_model")

describe("annotations_model is a leaf", function()
  it("loads without pulling in any other weread module", function()
    local before = {}
    for name in pairs(package.loaded) do
      before[name] = true
    end
    package.loaded["weread.annotations_model"] = nil
    require("weread.annotations_model")
    local pulled = {}
    for name in pairs(package.loaded) do
      if name:match("^weread") and not before[name] then
        pulled[#pulled + 1] = name
      end
    end
    eq(pulled, {})
  end)
end)

describe("annotations_model.parse_range", function()
  it("reads from-to", function()
    local from, to = model.parse_range("383-415")
    eq({ from, to }, { 383, 415 })
  end)

  it("gives nil, nil for anything else", function()
    for _, bad in ipairs({ "", "12", "a-b", "1-", "-5", "1-2-3" }) do
      local from, to = model.parse_range(bad)
      eq({ from, to }, {}, bad)
    end
    local from, to = model.parse_range(nil)
    eq({ from, to }, {})
    from, to = model.parse_range(12)
    eq({ from, to }, {})
  end)
end)

describe("annotations_model.upsert", function()
  it("appends a new range with a zero count", function()
    local list = {}
    local entry = model.upsert(list, { range = "1-5", text = "甲" })
    eq(#list, 1)
    eq(entry.count, 0)
  end)

  it("merges the same range: flags, the larger count, the first non-empty text", function()
    local list = {}
    model.upsert(list, { range = "1-5", text = "", mine = true, count = 0 })
    local merged = model.upsert(list, { range = "1-5", text = "甲", popular = true, count = 7 })
    eq(#list, 1)
    eq(merged.mine, true)
    eq(merged.popular, true)
    eq(merged.count, 7)
    eq(merged.text, "甲")
  end)

  it("lets the account's highlight clear the unsynced flag, but not a local one", function()
    local list = { { range = "1-5", text = "甲", mine = true, unsynced = true, count = 0 } }
    model.upsert(list, { range = "1-5", text = "甲", mine = true, unsynced = true, count = 0 })
    eq(list[1].unsynced, true, "another local copy changes nothing")
    model.upsert(list, { range = "1-5", text = "甲", mine = true, bookmark_id = "b", count = 0 })
    eq(list[1].unsynced, nil)
    eq(list[1].bookmark_id, "b")
  end)

  it("keeps a note written here through the merge", function()
    local list = { { range = "1-5", text = "甲", count = 0 } }
    model.upsert(list, { range = "1-5", text = "甲", note = "备注", note_synced = true, count = 0 })
    eq(list[1].note, "备注")
    eq(list[1].note_synced, true)
  end)
end)

describe("annotations_model normalizers", function()
  it("from_bookmarklist keeps only this chapter's highlights that have a range", function()
    local out = model.from_bookmarklist({
      updated = {
        { chapterUid = 2, range = "1-5", markText = "甲", bookmarkId = "b1" },
        { chapterUid = 9, range = "7-8", markText = "别章" },
        { chapterUid = 2, markText = "无 range" },
      },
    }, "2")
    eq(#out, 1)
    eq(out[1].bookmark_id, "b1")
    eq(out[1].mine, true)
    eq(out[1].popular, false)
  end)

  it("from_bestbookmarks carries the reader count", function()
    local out = model.from_bestbookmarks({ items = { { chapterUid = 2, range = "1-5", markText = "甲", totalCount = "12" } } }, "2")
    eq(out[1].count, 12)
    eq(out[1].popular, true)
    eq(out[1].mine, false)
  end)

  it("both cope with a missing response", function()
    eq(model.from_bookmarklist(nil, "2"), {})
    eq(model.from_bestbookmarks(nil, "2"), {})
  end)
end)

describe("annotations_model thoughts", function()
  it("thought_of strips zero-width characters and keeps the review id as a string", function()
    local thought = model.thought_of({
      likesCount = "3",
      review = { reviewId = 55, content = "好\226\128\139句", author = { name = "甲", userVid = 9 }, createTime = 100 },
    })
    eq(thought.content, "好句")
    eq(thought.id, "55")
    eq(thought.author_vid, "9")
    eq(thought.likes, 3)
  end)

  it("thought_of gives nil for an empty or missing review", function()
    eq(model.thought_of({ review = { content = "" } }), nil)
    eq(model.thought_of({}), nil)
    eq(model.thought_of(nil), nil)
  end)

  it("attach_thoughts attaches under the right range and never twice", function()
    local annotations = { { range = "1-5", thoughts = {} }, { range = "9-10", thoughts = {} } }
    local data = {
      reviews = {
        { range = "1-5", totalCount = 2, pageReviews = { { review = { reviewId = "a", content = "一" } }, { review = { reviewId = "b", content = "二" } } } },
      },
    }
    model.attach_thoughts(annotations, data)
    model.attach_thoughts(annotations, data)
    eq(#annotations[1].thoughts, 2)
    eq(annotations[1].thought_total, 2)
    eq(#annotations[2].thoughts, 0)
  end)

  it("find_mine matches by account vid or by the vid_ prefix of the review id", function()
    local list = { { id = "other_1", author_vid = "other" }, { id = "vid_7", author_vid = "" } }
    eq(model.find_mine(list, "vid").id, "vid_7")
    eq(model.find_mine({ { id = "x", author_vid = "vid" } }, "vid").id, "x")
    eq(model.find_mine({ { id = "other_1", author_vid = "other" } }, "vid"), nil)
    eq(model.find_mine(nil, "vid"), nil)
  end)

  it("is_uploaded recognises uploaded books by their CB_ prefix", function()
    eq(model.is_uploaded("CB_abc"), true)
    eq(model.is_uploaded("43208843"), false)
    eq(model.is_uploaded(nil), false)
  end)
end)

describe("annotations_model heat and label", function()
  it("heat is relative to the hottest highlight of the chapter", function()
    eq(model.heat(10, 10), 3)
    eq(model.heat(4, 10), 2)
    eq(model.heat(1, 10), 1)
    eq(model.heat(0, 10), 1)
    eq(model.heat(5, 0), 1)
    eq(model.heat(nil, nil), 1)
  end)

  it("heat_group maps the tiers to groups", function()
    eq(model.heat_group(3), "WereadPopularHot")
    eq(model.heat_group(2), "WereadPopularWarm")
    eq(model.heat_group(1), "WereadPopularHighlight")
  end)

  it("label says where a highlight came from", function()
    local label, group = model.label({ unsynced = true, thoughts = {} })
    eq(label, "▎我的划线（本地）")
    eq(group, "WereadMineHighlight")
    eq((model.label({ mine = true, popular = true, count = 4 })), "▎我的划线 · 4人")
    eq((model.label({ mine = true, thoughts = { {}, {} } })), "▎我的划线 · 2想法")
    eq((model.label({ count = 9 })), "▎9人划线")
    eq((model.label({})), "▎热门划线")
  end)
end)

describe("annotations_model text helpers", function()
  it("first_text_byte skips ASCII and full-width spaces but not other text", function()
    eq(model.first_text_byte("  \t字"), 4)
    eq(model.first_text_byte("　　字"), 7)
    eq(model.first_text_byte("字"), 1)
    eq(model.first_text_byte("  　 "), nil)
    eq(model.first_text_byte(""), nil)
  end)

  it("plain_text removes markdown punctuation and the paragraph indent", function()
    eq(model.plain_text("　　**重点**和`代码`"), "重点和代码")
    eq(model.plain_text("## 标题"), "标题")
    eq(model.plain_text("- 条目"), "条目")
    eq(model.plain_text("看![插图](a.png)吧"), "看插图吧")
    eq(model.plain_text("　　"), "")
  end)

  it("sort puts annotations in rune order and tolerates a bad range", function()
    local list = { { range = "50-60" }, { range = "bad" }, { range = "5-9" } }
    model.sort(list)
    eq({ list[1].range, list[2].range, list[3].range }, { "bad", "5-9", "50-60" })
  end)
end)
