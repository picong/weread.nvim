--[[
Tests for weread.text: display-width helpers (cells, ellipsize, fit, wrap),
the window text width, the shared highlight groups, and that the old
`weread.preview` fields still point at the same functions.
(显示宽度工具的测试：cells、ellipsize、fit、wrap，窗口正文宽度，共用高亮组，
以及旧的 `weread.preview` 字段仍指向同一批函数)
]]

local text = require("weread.text")

describe("text.cells", function()
  it("counts display cells, two for a CJK character", function()
    eq(text.cells("abc"), 3)
    eq(text.cells("汉字"), 4)
    eq(text.cells(""), 0)
  end)

  it("does not depend on the current window", function()
    -- a string wider than the window must not pick up 'showbreak' cells
    -- (比窗口宽的字符串不能被算上 'showbreak' 的补白)
    local previous = vim.o.showbreak
    vim.o.showbreak = ">>>>"
    local long = string.rep("字", 400)
    eq(text.cells(long), 800)
    vim.o.showbreak = previous
  end)
end)

describe("text.chars", function()
  it("keeps multibyte characters whole", function()
    eq(text.chars("a汉b"), { "a", "汉", "b" })
    eq(text.chars(""), {})
  end)
end)

describe("text.ellipsize", function()
  it("leaves text that fits alone", function()
    eq(text.ellipsize("hello", 5), "hello")
    eq(text.ellipsize("汉字", 4), "汉字")
  end)

  it("cuts by cells and ends in an ellipsis", function()
    local cut = text.ellipsize("汉字汉字汉字", 7)
    eq(cut, "汉字汉…")
    truthy(text.cells(cut) <= 7)
  end)

  it("can force the ellipsis onto text that fits", function()
    eq(text.ellipsize("ab", 10, true), "ab…")
  end)

  it("gives nothing for a width with no room", function()
    eq(text.ellipsize("abc", 0), "")
    eq(text.ellipsize("abc", -3), "")
  end)
end)

describe("text.fit", function()
  it("collapses whitespace and newlines to single spaces", function()
    eq(text.fit("a \n\t b   c", 20), "a b c")
  end)

  it("tolerates nil and non-strings", function()
    eq(text.fit(nil, 10), "")
    eq(text.fit(42, 10), "42")
  end)

  it("fits to a width", function()
    eq(text.fit("一二三四五六七八", 7), "一二三…")
  end)
end)

describe("text.wrap", function()
  it("wraps CJK text anywhere", function()
    eq(text.wrap("一二三四五六", 6, 10), { "一二三", "四五六" })
  end)

  it("breaks Latin text at the last space", function()
    eq(text.wrap("hello brave world", 13, 10), { "hello brave", "world" })
  end)

  it("keeps paragraphs apart and drops blank ones", function()
    eq(text.wrap("one\n\n\ntwo", 20, 10), { "one", "two" })
  end)

  it("stops at max_lines and ends the last line in an ellipsis", function()
    local lines = text.wrap("一二三四五六七八九十", 4, 2)
    eq(#lines, 2)
    eq(lines[2]:sub(-3), "…")
    for _, line in ipairs(lines) do
      truthy(text.cells(line) <= 4, "no line is wider than the width")
    end
  end)

  it("ellipsizes when whole paragraphs are left over", function()
    local lines = text.wrap("first\nsecond\nthird", 20, 2)
    eq(#lines, 2)
    eq(lines[2], "second…")
  end)

  it("gives no lines for empty input", function()
    eq(text.wrap("", 10, 5), {})
    eq(text.wrap(nil, 10, 5), {})
  end)
end)

describe("text.text_width", function()
  it("is nil for a missing or closed window", function()
    eq(text.text_width(nil), nil)
    local win = vim.api.nvim_open_win(vim.api.nvim_create_buf(false, true), false, {
      relative = "editor",
      width = 10,
      height = 2,
      row = 0,
      col = 0,
    })
    vim.api.nvim_win_close(win, true)
    eq(text.text_width(win), nil)
  end)

  it("leaves out the gutter", function()
    local buf = vim.api.nvim_create_buf(false, true)
    local win = vim.api.nvim_open_win(buf, false, {
      relative = "editor",
      width = 30,
      height = 2,
      row = 0,
      col = 0,
    })
    vim.wo[win].number = false
    vim.wo[win].signcolumn = "no"
    eq(text.text_width(win), 30)
    vim.wo[win].number = true
    truthy(text.text_width(win) < 30, "line numbers take width off the text")
    vim.api.nvim_win_close(win, true)
  end)
end)

describe("text.define_highlights", function()
  it("defines the shared groups without overriding the user's own", function()
    vim.api.nvim_set_hl(0, "WereadPreviewDim", { fg = "#123456" })
    text.define_highlights()
    local dim = vim.api.nvim_get_hl(0, { name = "WereadPreviewDim" })
    eq(dim.fg, 0x123456, "default = true leaves a user definition alone")
    for _, name in ipairs({ "WereadPreviewTitle", "WereadPreviewSection", "WereadPreviewRule", "WereadPreviewStar", "WereadPreviewCurrent", "WereadPreviewPart" }) do
      falsy(vim.tbl_isempty(vim.api.nvim_get_hl(0, { name = name })), name .. " is defined")
    end
  end)
end)

describe("weread.preview compatibility", function()
  it("re-exports the text helpers under their old names", function()
    local preview = require("weread.preview")
    eq(preview.cells, text.cells)
    eq(preview.fit, text.fit)
    eq(preview.wrap, text.wrap)
    eq(preview.ellipsize, text.ellipsize)
    eq(preview.text_width, text.text_width)
    eq(preview.define_highlights, text.define_highlights)
  end)
end)
