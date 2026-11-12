--[[
Tests for weread.layout: the page geometry the reading window is drawn with.

Three numbers have to agree, or the page is not a page: how wide the text column
is, how far it is inset from the window edges, and the `statuscolumn` value that
actually creates that inset.
(layout 单测：阅读窗口的版心几何。三个数字必须自洽，否则「页」就不成页：正文列多宽、
 离窗口两边留多少、以及真正做出左边距的那个 statuscolumn 值)
]]

local config = require("weread.config")
local layout = require("weread.layout")

config.setup({ data_dir = "/tmp/weread-test-layout", sync_interval = 0, keymaps = false })

---The geometry is arithmetic on the window width, and a headless Neovim has no
---screen to resize, so the pure half is what gets tested here.
---(这套几何是「窗口宽度上的算术」，而无 UI 的 Neovim 没有可调大小的屏幕，因此这里测的
--- 是其中的纯函数部分)
local CEILING = 80

---Run a case with the page config given, then put the defaults back.
---(在指定的版面配置下跑一个用例，之后恢复默认值)
---@param opts table
---@param body fun()
local function with_layout(opts, body)
  local current = config.get().layout
  local previous = { page_chars = current.page_chars, adaptive = current.adaptive }
  current.page_chars = opts.page_chars or 26
  current.adaptive = opts.adaptive == true
  local ok, err = pcall(body)
  current.page_chars = previous.page_chars
  current.adaptive = previous.adaptive
  if not ok then
    error(err)
  end
end

describe("layout.page_width", function()
  it("is the configured number of characters, in cells", function()
    with_layout({ page_chars = 26 }, function()
      eq(layout.page_width_for(120), 52, "26 Chinese characters are 52 cells")
      eq(layout.page_width_for(CEILING), 52, "and it does not depend on the window")
    end)
  end)

  it("clamps to the window instead of running off the page", function()
    with_layout({ page_chars = 26 }, function()
      eq(layout.page_width_for(40), 36, "four cells of slack for hanging punctuation")
      eq(layout.page_width_for(56), 52, "just wide enough: the page is used as is")
    end)
  end)

  it("falls back to the full window when no page would be left", function()
    with_layout({ page_chars = 26 }, function()
      eq(layout.page_width_for(20), 0, "below 30 columns the page layout is off")
      eq(layout.page_width_for(29), 0)
      eq(layout.page_width_for(30), 26, "at the boundary the page still fits")
    end)
  end)

  it("follows the window when adaptive", function()
    with_layout({ page_chars = 26, adaptive = true }, function()
      local wide = layout.page_width_for(120)
      local narrow = layout.page_width_for(60)
      truthy(narrow < wide, string.format("adaptive: %d then %d", wide, narrow))
      eq(wide % 2, 0, "an even number of cells keeps full width characters aligned")
      truthy(wide < 120, "and it is still a page, not the whole window")
      eq(layout.page_width_for(120, { enabled = true, page_chars = 26, adaptive = false }), 52,
        "a pre-read config avoids re-reading the config per line")
      eq(layout.page_width_for(300), 80, "a wide window still caps the line at 40 characters")
      eq(layout.page_width_for(50), 34, "a narrow one keeps at least 17 characters")
    end)
  end)

  it("is off when the config says so", function()
    with_layout({ page_chars = 0 }, function()
      eq(layout.page_width_for(120), 0)
      eq(layout.statuscolumn_for(120, 0), "", "and no inset is added")
    end)
  end)

  it("reads the width of a real window", function()
    with_layout({ page_chars = 26 }, function()
      local win = vim.api.nvim_get_current_win()
      eq(layout.page_width(0), layout.page_width_for(vim.api.nvim_win_get_width(win)))
      eq(layout.page_width(99999), 0, "an invalid window has no page")
    end)
  end)
end)

describe("layout.margin and statuscolumn", function()
  it("centers the page in the window", function()
    eq(layout.margin_for(120, 52), 34, "(120 - 52) / 2")
    eq(layout.margin_for(53, 52), 0, "an odd column left over is not worth padding")
    eq(layout.margin_for(52, 52), 0)
    eq(layout.margin_for(120, 0), 0, "no page, no margin")
  end)

  it("builds the statuscolumn out of plain spaces", function()
    local value = layout.statuscolumn_for(120, 52)
    truthy(vim.startswith(value, "%#WereadMargin#"), "painted with the page colour: " .. value)
    eq(#value - #"%#WereadMargin#", 34, "one cell per column of margin")
    falsy(value:find("%{", 1, true), "no expression: Neovim must not evaluate anything per line")
    eq(layout.statuscolumn_for(34, 52), "", "narrower than the page: no inset at all")
  end)

  it("applies the inset to a window and reports the width it used", function()
    with_layout({ page_chars = 26 }, function()
      local win = vim.api.nvim_get_current_win()
      local applied = layout.apply(win)
      eq(applied, layout.page_width(win), "returns the width it laid out for")
      eq(vim.wo[win].statuscolumn, layout.statuscolumn(win, applied))
      vim.wo[win].statuscolumn = ""
    end)
  end)
end)
