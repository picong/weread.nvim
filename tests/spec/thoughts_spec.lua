--[[
Tests for the thought panel (weread.thoughts) and the `K` mapping that opens it.
(想法面板 weread.thoughts 以及打开它的 K 映射的测试)

The gateway is stubbed with the pagination the live service was observed to
use: `maxIdx` is the offset of the next page, `hasMore = 1` while there is one.
(gateway 打桩成实测线上服务的分页方式：`maxIdx` 是下一页的偏移，有下一页时 `hasMore = 1`)
]]

local tmpdir = vim.fn.tempname()
vim.fn.mkdir(tmpdir, "p")

local RANGE = "100-140"
local TOTAL = 23

---@param index integer
---@return table page entry as `/book/readreviews` returns it
local function page_entry(index)
  return {
    reviewId = "u" .. index .. "_r",
    likesCount = index == 7 and 99 or (index % 3),
    review = {
      reviewId = "u" .. index .. "_r",
      content = "第 " .. index .. " 条想法",
      createTime = 1700000000 + index * 3600,
      author = { name = "读者" .. index, userVid = 1000 + index },
    },
  }
end

local calls = {}
local fail_with = nil
local fake_gateway = {}
function fake_gateway.call(api_name, params, opts, callback)
  if type(opts) == "function" then
    callback = opts
  end
  calls[#calls + 1] = { api_name = api_name, params = params }
  if fail_with then
    callback(false, fail_with)
    return
  end
  local asked = params.reviews[1]
  local offset, count = asked.maxIdx, asked.count
  local pages = {}
  for index = offset + 1, math.min(offset + count, TOTAL) do
    pages[#pages + 1] = page_entry(index)
  end
  local more = offset + count < TOTAL
  callback(true, {
    reviews = {
      {
        range = asked.range,
        totalCount = TOTAL,
        hasMore = more and 1 or 0,
        maxIdx = more and (offset + count) or 0,
        pageReviews = pages,
      },
    },
  })
end
package.loaded["weread.api_gateway"] = fake_gateway

local config = require("weread.config")
config.setup({ data_dir = tmpdir })

local annotations = require("weread.annotations")
local thoughts = require("weread.thoughts")
local reader = require("weread.reader")

---@return integer|nil win
local function panel()
  for _, win in ipairs(vim.api.nvim_list_wins()) do
    if vim.api.nvim_win_get_config(win).relative ~= "" then
      return win
    end
  end
  return nil
end

---@return string
local function panel_text()
  local win = panel()
  if not win then
    return ""
  end
  return table.concat(vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(win), 0, -1, false), "\n")
end

local function close_panel()
  local win = panel()
  if win then
    pcall(vim.api.nvim_win_close, win, true)
  end
end

---@param book_id string
---@param entries table[]
---@return integer buf
local function chapter(book_id, entries)
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "第一行", "第二行", "第三行" })
  vim.b[buf].weread = { book_id = book_id, chapter_key = "0002", chapter_index = 1 }
  vim.b[buf].weread_annotations = entries
  vim.api.nvim_win_set_buf(0, buf)
  vim.api.nvim_win_set_cursor(0, { 1, 0 })
  reader.state.catalog = { chapters = { { chapterUid = 2 } } }
  return buf
end

---@param range string
---@param extra table|nil
---@return table entry
local function entry(range, extra)
  local annotation = vim.tbl_extend("force", {
    range = range,
    text = "被划线的原文",
    popular = true,
    mine = false,
    count = 42,
    thoughts = {},
  }, extra or {})
  return { annotation = annotation, line = 0, finish_line = 0 }
end

local function reset()
  close_panel()
  calls = {}
  fail_with = nil
  thoughts.reset()
end

describe("annotations.fetch_all_thoughts", function()
  it("follows hasMore/maxIdx until every thought is in", function()
    reset()
    local got, total
    annotations.fetch_all_thoughts("3300000001", "2", RANGE, function(ok, list, count)
      truthy(ok)
      got, total = list, count
    end)
    eq(#got, TOTAL, "every page was read")
    eq(total, TOTAL)
    eq(#calls, 1, "one page of 50 covers 23 thoughts")
    eq(calls[1].params.reviews[1].count, 50)
  end)

  it("drops duplicates across pages", function()
    reset()
    local real = fake_gateway.call
    -- a service that repeats the last entry of each page on the next one
    -- (服务端把每页最后一条在下一页又给一次)
    fake_gateway.call = function(name, params, opts, callback)
      local asked = params.reviews[1]
      local start = asked.maxIdx == 0 and 1 or asked.maxIdx
      local pages = {}
      for index = start, math.min(start + 4, TOTAL) do
        pages[#pages + 1] = page_entry(index)
      end
      local next_offset = start + 4
      callback(true, {
        reviews = {
          { range = asked.range, totalCount = TOTAL, hasMore = next_offset < TOTAL and 1 or 0, maxIdx = next_offset, pageReviews = pages },
        },
      })
    end
    local got
    annotations.fetch_all_thoughts("3300000001", "2", RANGE, function(_, list)
      got = list
    end)
    fake_gateway.call = real
    local ids = {}
    for _, thought in ipairs(got) do
      falsy(ids[thought.id], "duplicate " .. thought.id)
      ids[thought.id] = true
    end
    eq(#got, TOTAL)
  end)

  it("keeps the likes count of each thought", function()
    reset()
    local got
    annotations.fetch_all_thoughts("3300000001", "2", RANGE, function(_, list)
      got = list
    end)
    eq(got[7].likes, 99)
  end)
end)

describe("annotations.thought_of", function()
  it("strips zero-width characters from the content", function()
    local thought = annotations.thought_of({ review = { content = "修改代码的艺术\226\128\139》\239\187\191" } })
    eq(thought.content, "修改代码的艺术》")
  end)
end)

describe("thoughts.sorted", function()
  it("puts the most liked first and breaks ties by time", function()
    local list = thoughts.sorted({
      { id = "a", likes = 1, time = 10 },
      { id = "b", likes = 5, time = 1 },
      { id = "c", likes = 1, time = 20 },
    }, "likes")
    eq(list[1].id, "b")
    eq(list[2].id, "c", "newer of the tied pair")
    eq(list[3].id, "a")
  end)

  it("sorts newest first by time", function()
    local list = thoughts.sorted({ { id = "a", time = 10 }, { id = "b", time = 30 }, { id = "c", time = 20 } }, "time")
    eq(list[1].id, "b")
    eq(list[3].id, "a")
  end)
end)

describe("thoughts.layout", function()
  it("says whether the local copy already reached the server", function()
    -- After a successful post "本地" made the thought look unsynced; the label
    -- now follows the flag saved with the note.
    -- (发表成功后仍写「本地」会让人以为没同步；现在标签跟着备注一起存的标志走)
    local view = {
      entries = {
        { annotation = { text = "被划线的原文", note = "我写的想法", note_synced = true, count = 0 } },
      },
      index = 1,
      width = 40,
      order = "likes",
      thoughts = {},
      total = 0,
    }
    local synced = table.concat(thoughts.layout(view, 38), "\n")
    truthy(synced:find("我的想法（已同步）", 1, true), synced)

    view.entries[1].annotation.note_synced = false
    local local_only = table.concat(thoughts.layout(view, 38), "\n")
    truthy(local_only:find("我的想法（本地）", 1, true), local_only)
  end)
end)

describe("thoughts panel", function()
  it("shows every thought, most liked first, as cards", function()
    reset()
    local buf = chapter("3300000001", { entry(RANGE) })
    annotations.show_thoughts_at_cursor(buf)
    vim.wait(1000, function()
      return panel_text():find("读者23", 1, true) ~= nil
    end, 20)

    local text = panel_text()
    truthy(text:find("被划线的原文", 1, true), "the passage is quoted")
    truthy(text:find("42 人划线 · 23 条想法", 1, true), "header: " .. text:sub(1, 200))
    for index = 1, TOTAL do
      truthy(text:find("第 " .. index .. " 条想法", 1, true), "thought " .. index)
    end
    local top = text:find("读者7", 1, true)
    local other = text:find("读者1\n", 1, true) or text:find("读者1 ", 1, true)
    truthy(top and other and top < other, "the 99-like thought comes first")
    truthy(text:find("♥ 99", 1, true), "likes are shown")
    close_panel()
  end)

  it("toggles the order with s", function()
    reset()
    local buf = chapter("3300000001", { entry(RANGE) })
    annotations.show_thoughts_at_cursor(buf)
    vim.wait(1000, function()
      return panel_text():find("读者23", 1, true) ~= nil
    end, 20)
    vim.api.nvim_set_current_win(panel())
    vim.api.nvim_feedkeys("s", "x", false)
    local text = panel_text()
    truthy(text:find("按时间", 1, true))
    truthy(text:find("读者23", 1, true) < text:find("读者7", 1, true), "newest first")
    close_panel()
  end)

  it("cycles between highlights on the same line with Tab", function()
    reset()
    local buf = chapter("3300000001", {
      entry(RANGE),
      entry("200-220", { text = "第二条划线", count = 3 }),
    })
    annotations.show_thoughts_at_cursor(buf)
    vim.wait(1000, function()
      return #calls >= 1
    end, 20)
    truthy(panel_text():find("被划线的原文", 1, true))
    vim.api.nvim_set_current_win(panel())
    vim.api.nvim_feedkeys("\t", "x", false)
    vim.wait(1000, function()
      return panel_text():find("第二条划线", 1, true) ~= nil
    end, 20)
    truthy(panel_text():find("第二条划线", 1, true), "switched to the second highlight")
    local title = vim.api.nvim_win_get_config(panel()).title
    matches(vim.inspect(title), "2/2")
    close_panel()
  end)

  it("reuses fetched thoughts on the next K", function()
    reset()
    local buf = chapter("3300000001", { entry(RANGE) })
    annotations.show_thoughts_at_cursor(buf)
    vim.wait(1000, function()
      return panel_text():find("读者23", 1, true) ~= nil
    end, 20)
    close_panel()
    local before = #calls
    vim.api.nvim_set_current_win(vim.fn.bufwinid(buf))
    annotations.show_thoughts_at_cursor(buf)
    eq(#calls, before, "no new request inside the freshness window")
    truthy(panel_text():find("读者23", 1, true))
    close_panel()
  end)

  it("explains an uploaded book instead of asking the service", function()
    reset()
    local buf = chapter("CB_uploaded", { entry(RANGE, { mine = true, popular = false, count = 0 }) })
    annotations.show_thoughts_at_cursor(buf)
    eq(#calls, 0, "no request for an uploaded book")
    truthy(panel_text():find("自己上传的书", 1, true), panel_text())
    close_panel()
  end)

  it("says so inline when the thoughts cannot be loaded", function()
    reset()
    fail_with = "-2020"
    local buf = chapter("3300000001", { entry(RANGE) })
    annotations.show_thoughts_at_cursor(buf)
    vim.wait(1000, function()
      return panel_text():find("加载失败", 1, true) ~= nil
    end, 20)
    truthy(panel_text():find("想法加载失败", 1, true), panel_text())
    close_panel()
  end)

  it("keeps the thoughts it already had when a refetch fails", function()
    reset()
    fail_with = "network"
    local buf = chapter("3300000001", {
      entry(RANGE, { thoughts = { { id = "x", author = "老读者", content = "缓存里的想法", time = 1 } } }),
    })
    annotations.show_thoughts_at_cursor(buf)
    vim.wait(200, function()
      return false
    end, 20)
    truthy(panel_text():find("缓存里的想法", 1, true))
    falsy(panel_text():find("加载失败", 1, true))
    close_panel()
  end)
end)

describe("thoughts panel deletion", function()
  it("offers d to delete my thought under the current highlight", function()
    reset()
    local buf = chapter("3300000001", { entry(RANGE, { note = "我写的想法", note_synced = true }) })
    annotations.show_thoughts_at_cursor(buf)
    vim.wait(1000, function()
      return panel() ~= nil
    end, 20)
    local panel_buf = vim.api.nvim_win_get_buf(panel())
    local delete = nil
    for _, map in ipairs(vim.api.nvim_buf_get_keymap(panel_buf, "n")) do
      if map.lhs == "d" then
        delete = map
      end
    end
    truthy(delete, "d is mapped in the panel")
    truthy(delete.callback, "and it is one of ours")
    close_panel()
  end)
end)

describe("reader.claim_hover", function()
  it("takes K back from an LSP hover mapping", function()
    local buf = chapter("3300000001", { entry(RANGE) })
    -- what LazyVim/snacks does after a language server attaches
    -- (语言服务器 attach 之后 LazyVim/snacks 做的事)
    vim.keymap.set("n", "K", function() end, { buffer = buf, desc = "Hover" })
    eq(reader.claim_hover(buf), true, "claimed")
    eq(vim.fn.maparg("K", "n", false, true).desc, "微信读书：翻译光标处外文 / 查看划线想法")
    eq(reader.claim_hover(buf), false, "already ours, nothing to do")
  end)

  it("leaves a buffer that is not a chapter alone", function()
    local plain = vim.api.nvim_create_buf(false, true)
    eq(reader.claim_hover(plain), false)
  end)
end)
