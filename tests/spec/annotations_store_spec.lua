--[[
Tests for weread.annotations_store: the local highlight store and its
read-modify-write callers, above all that a damaged or unreadable
`highlights.json` is never replaced by an empty table.
(annotations_store 的测试：本地划线存储及其读-改-写调用点，重点是损坏或读不了的
 `highlights.json` 绝不会被一张空表覆盖)

`cache.read_json` moves a corrupt file aside as `<name>.corrupt-<stamp>` and
returns nil; the store must then start over without destroying what is left.
(`cache.read_json` 会把损坏文件改名为 `<name>.corrupt-<时间戳>` 并返回 nil；
 之后 store 重新开始时不能毁掉剩下的东西)
]]

local tmpdir = vim.fn.tempname()
vim.fn.mkdir(tmpdir, "p")
require("weread.config").setup({ data_dir = tmpdir })

local cache = require("weread.cache")
local store = require("weread.annotations_store")
local thoughts = require("weread.thoughts")

local counter = 0

---A fresh book id, so cases never share files.
---(新的书 id，用例之间不共用文件)
---@return string
local function fresh_book()
  counter = counter + 1
  return "store-spec-" .. counter
end

---Files next to `path` named `<path>.corrupt-*`.
---(与 `path` 同目录、名为 `<path>.corrupt-*` 的文件)
local function backups_of(path)
  return vim.fn.glob(path .. ".corrupt-*", false, true)
end

---Put raw text where the store looks for a book's highlights.
---(把原始文本放到 store 查找本书划线的位置)
local function plant(book_id, text)
  local path = store.local_path(book_id)
  assert(cache.write(path, text))
  return path
end

describe("annotations_store.local_store with no file", function()
  it("is an empty table and writes nothing by itself", function()
    local book = fresh_book()
    eq(store.local_store(book), {})
    eq(vim.uv.fs_stat(store.local_path(book)), nil)
  end)

  it("round-trips what add_local stored, sorted by range", function()
    local book = fresh_book()
    store.add_local(book, "0001", "50-60", "后面")
    store.add_local(book, "0001", "5-9", "前面")
    local list = store.local_for(book, "0001")
    eq(#list, 2)
    eq(list[1].range, "5-9")
    eq(list[2].range, "50-60")
    eq(store.local_for(book, "0002"), {})
  end)
end)

describe("annotations_store.local_store with a damaged file", function()
  it("moves invalid JSON aside and keeps its bytes", function()
    local book = fresh_book()
    local path = plant(book, '{"0001": [ {"range": "1-2", ')
    eq(store.local_store(book), {})
    eq(vim.uv.fs_stat(path), nil, "the broken file is out of the way")
    local backups = backups_of(path)
    eq(#backups, 1)
    eq(cache.read(backups[1]), '{"0001": [ {"range": "1-2", ')
  end)

  it("treats valid JSON that is not a table as damaged", function()
    local book = fresh_book()
    local path = plant(book, "42")
    eq(store.local_store(book), {})
    eq(#backups_of(path), 1)
  end)

  it("lets the next highlight be saved after the damaged file was set aside", function()
    local book = fresh_book()
    local path = plant(book, "not json at all")
    store.add_local(book, "0001", "1-9", "新的划线")
    eq(#store.local_for(book, "0001"), 1, "the new highlight is stored")
    eq(#backups_of(path), 1, "and the old bytes are still on disk")
    eq(cache.read(backups_of(path)[1]), "not json at all")
  end)

  it("drops entries and chapters it cannot iterate, keeping a copy of the original", function()
    local book = fresh_book()
    local original = vim.json.encode({
      ["0001"] = { { range = "1-9", text = "好" }, "stray", 7, { text = "no range" } },
      ["0002"] = "not a list",
      ["0003"] = { { range = "3-4", text = "另一章" } },
    })
    local path = plant(book, original)

    local data = store.local_store(book)
    eq(#data["0001"], 1)
    eq(data["0001"][1].range, "1-9")
    eq(data["0002"], nil)
    eq(data["0003"][1].text, "另一章")
    local backups = backups_of(path)
    eq(#backups, 1, "what was dropped can still be recovered")
    eq(cache.read(backups[1]), original)
  end)

  it("does not make a backup when nothing had to be dropped", function()
    local book = fresh_book()
    local path = plant(book, vim.json.encode({ ["0001"] = { { range = "1-9", text = "好" } } }))
    eq(#store.local_for(book, "0001"), 1)
    eq(#backups_of(path), 0)
  end)
end)

describe("annotations_store with a highlights file that exists but cannot be read", function()
  -- A directory where the file should be: it exists, reading it fails. (Not
  -- chmod: that proves nothing when the suite runs as root.)
  -- (在文件的位置放一个目录：它存在，读它会失败。不用 chmod：以 root 跑测试时那证明不了什么)
  local function unreadable_book()
    local book = fresh_book()
    local path = store.local_path(book)
    vim.fn.mkdir(path, "p")
    return book, path
  end

  it("reads as empty but refuses to save over it", function()
    local book, path = unreadable_book()
    eq(store.local_store(book), {})
    eq(store.save_local(book, { ["0001"] = {} }), false)
    eq(vim.fn.isdirectory(path), 1, "what is there was not replaced")
    vim.fn.delete(path, "rf")
  end)

  it("keeps every read-modify-write caller from replacing it", function()
    local book, path = unreadable_book()
    store.add_local(book, "0001", "1-9", "x")
    store.remove_local(book, "0001", "1-9")
    store.mark_synced(book, "0001", "1-9", "bm")
    store.prune_synced(book, "0001", {}, os.time() + 10)
    store.set_note(book, "0001", "1-9", "备注", "x", true, "rev")
    eq(vim.fn.isdirectory(path), 1, "none of them got through")
    vim.fn.delete(path, "rf")
  end)

  it("saves again once the file can be read", function()
    local book, path = unreadable_book()
    eq(store.save_local(book, {}), false)
    vim.fn.delete(path, "rf")
    store.add_local(book, "0001", "1-9", "x")
    eq(#store.local_for(book, "0001"), 1)
  end)
end)

describe("annotations_store.chapter_map", function()
  it("reads the chapter's offset map through the session cache", function()
    local book = fresh_book()
    assert(cache.write_json(store.map_path(book, "0007"), { map = { { 0, 5 } }, source_runes = 5 }))
    local map = store.chapter_map(book, "0007")
    eq(map.source_runes, 5)
  end)

  it("is nil for a chapter with no map, and writes nothing", function()
    local book = fresh_book()
    eq(store.chapter_map(book, "0009"), nil)
    eq(vim.uv.fs_stat(store.map_path(book, "0009")), nil)
  end)

  it("is nil for a corrupt map, which the cache sets aside", function()
    local book = fresh_book()
    local path = store.map_path(book, "0008")
    assert(cache.write(path, "{ broken"))
    eq(store.chapter_map(book, "0008"), nil)
    eq(#backups_of(path), 1)
  end)

  it("pairs the map with the cached account list in store.cached", function()
    local book = fresh_book()
    assert(cache.write_json(store.map_path(book, "0003"), { source_runes = 1 }))
    assert(cache.write_json(store.annotations_path(book, "0003"), { { range = "1-2", text = "x" } }))
    local map, list = store.cached(book, "0003")
    eq(map.source_runes, 1)
    eq(list[1].range, "1-2")
    local none_map, none_list = store.cached(book, "0004")
    eq(none_map, nil)
    eq(none_list, nil)
  end)
end)

describe("annotations_store.forget_server and forget_thought on the cached list", function()
  local function cached_book()
    local book = fresh_book()
    assert(cache.write_json(store.annotations_path(book, "0001"), {
      { range = "1-9", text = "甲", thought_total = 2, thoughts = { { id = "a" }, { id = "b" } } },
      { range = "20-30", text = "乙", thoughts = {} },
    }))
    return book
  end

  local function scratch_buf()
    local buf = vim.api.nvim_create_buf(false, true)
    vim.b[buf].weread_server_annotations = { { range = "1-9", thoughts = { { id = "a" } } } }
    return buf
  end

  it("removes a highlight from the buffer's list and the cached one", function()
    local book = cached_book()
    local buf = scratch_buf()
    store.forget_server(buf, book, "0001", "1-9")
    eq(vim.b[buf].weread_server_annotations, {})
    local left = cache.read_json(store.annotations_path(book, "0001"))
    eq(#left, 1)
    eq(left[1].range, "20-30")
  end)

  it("removes one thought and counts it off thought_total", function()
    local book = cached_book()
    local buf = scratch_buf()
    store.forget_thought(buf, book, "0001", "1-9", "a")
    local left = cache.read_json(store.annotations_path(book, "0001"))
    eq(#left[1].thoughts, 1)
    eq(left[1].thoughts[1].id, "b")
    eq(left[1].thought_total, 1)
  end)

  it("does nothing without a review id", function()
    local book = cached_book()
    store.forget_thought(scratch_buf(), book, "0001", "1-9", nil)
    eq(#cache.read_json(store.annotations_path(book, "0001"))[1].thoughts, 2)
  end)

  it("leaves a corrupt cached list set aside instead of writing an empty one over it", function()
    local book = fresh_book()
    local path = store.annotations_path(book, "0001")
    assert(cache.write(path, "[ {oops"))
    store.forget_server(scratch_buf(), book, "0001", "1-9")
    eq(vim.uv.fs_stat(path), nil, "no replacement list was invented")
    eq(#backups_of(path), 1)
    eq(cache.read(backups_of(path)[1]), "[ {oops")
  end)

  it("still cleans the buffer's list when nothing is cached", function()
    local book = fresh_book()
    local buf = scratch_buf()
    store.forget_server(buf, book, "0001", "1-9")
    eq(vim.b[buf].weread_server_annotations, {})
    eq(vim.uv.fs_stat(store.annotations_path(book, "0001")), nil)
  end)
end)

describe("annotations_store.merged and local_annotations", function()
  it("marks a local highlight as unsynced until it carries a bookmark id", function()
    local book = fresh_book()
    store.add_local(book, "0001", "5-9", "本地")
    local list = store.local_annotations(book, "0001")
    eq(list[1].unsynced, true)
    eq(list[1].mine, true)
    store.mark_synced(book, "0001", "5-9", "bm_1")
    list = store.local_annotations(book, "0001")
    eq(list[1].unsynced, nil)
    eq(list[1].bookmark_id, "bm_1")
  end)

  it("merges a local highlight into the account's on the same range and keeps its thoughts", function()
    local book = fresh_book()
    store.add_local(book, "0001", "5-9", "本地")
    local server = { { range = "5-9", text = "本地", mine = true, bookmark_id = "bm_9", count = 0, thoughts = { { id = "t1" } } } }
    local merged = store.merged(book, "0001", server)
    eq(#merged, 1)
    eq(#merged[1].thoughts, 1)
    eq(merged[1].bookmark_id, "bm_9")
    eq(merged[1].unsynced, nil, "the account has it, so it is no longer only local")
  end)

  it("orders the result by range", function()
    local book = fresh_book()
    store.add_local(book, "0001", "50-60", "后")
    local merged = store.merged(book, "0001", { { range = "2-3", text = "前", count = 0, thoughts = {} } })
    eq({ merged[1].range, merged[2].range }, { "2-3", "50-60" })
  end)
end)

describe("annotations_store.prune_synced", function()
  it("forgets a synced highlight the account no longer has, but not one synced after the fetch began", function()
    local book = fresh_book()
    store.add_local(book, "0001", "1-9", "旧")
    store.add_local(book, "0001", "20-30", "新")
    store.mark_synced(book, "0001", "1-9", "bm_old")
    store.mark_synced(book, "0001", "20-30", "bm_new")
    local records = store.local_store(book)
    records["0001"][1].synced_at = 100
    records["0001"][2].synced_at = os.time() + 1000
    store.save_local(book, records)

    local removed = store.prune_synced(book, "0001", {}, os.time())
    eq(removed, 1)
    local left = store.local_for(book, "0001")
    eq(#left, 1)
    eq(left[1].range, "20-30")
  end)
end)

describe("annotations_store.set_note", function()
  it("makes a note-only record for a range with no local highlight", function()
    local book = fresh_book()
    store.set_note(book, "0001", "5-9", "我的备注", "原文", true, "vid_1")
    local record = store.local_for(book, "0001")[1]
    eq(record.note, "我的备注")
    eq(record.note_synced, true)
    eq(record.note_review_id, "vid_1")
    eq(record.local_only, true, "a thought on someone else's highlight is not a highlight of mine")
  end)

  it("puts the note on an existing highlight without making it local-only", function()
    local book = fresh_book()
    store.add_local(book, "0001", "5-9", "我划的")
    store.set_note(book, "0001", "5-9", "补一句", nil, false, nil)
    local list = store.local_for(book, "0001")
    eq(#list, 1)
    eq(list[1].note, "补一句")
    eq(list[1].note_synced, false)
    eq(list[1].local_only, nil)
  end)
end)

describe("annotations_store.source_text", function()
  it("reads the book's own text a range covers, without tags or layout whitespace", function()
    local book = fresh_book()
    assert(cache.write(string.format("%s/0001.xhtml", cache.chapters_dir(book)), "<p>零一二三四五六</p>\n<p>七八九</p>"))
    -- runes 3..6 of "<p>零一二三四五六</p>" are 零一二 (tags count as runes)
    -- (原文里标签也算 rune：第 3 到 6 个正好是 零一二)
    eq(store.source_text(book, "0001", "3-6"), "零一二")
  end)

  it("is nil for a bad range or a chapter whose source is not on disk", function()
    local book = fresh_book()
    eq(store.source_text(book, "0001", "3-6"), nil)
    assert(cache.write(string.format("%s/0001.xhtml", cache.chapters_dir(book)), "<p>短</p>"))
    eq(store.source_text(book, "0001", "bad"), nil)
    eq(store.source_text(book, "0001", "5-5"), nil)
    eq(store.source_text(book, "0001", "100-200"), nil)
  end)
end)

-- thoughts is loaded here so the file also proves that `thoughts` and the store
-- can be required side by side (加载 thoughts 是为了顺带证明它和 store 能并存)
describe("annotations_store with thoughts loaded", function()
  it("coexist", function()
    truthy(type(thoughts.write_thought) == "function")
    truthy(type(store.set_note) == "function")
  end)
end)
