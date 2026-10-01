--[[
Tests for weread.theme: the reading palettes and the fact that they only touch
the chapter window.
(theme 单测：阅读配色，以及「只影响章节窗口」这一条)
]]

local theme = require("weread.theme")

local tmpdir = "/tmp/weread-test-theme"
vim.fn.delete(tmpdir, "rf")
vim.fn.mkdir(tmpdir, "p")

local config = require("weread.config")
config.setup({ data_dir = tmpdir })

describe("theme palettes", function()
  it("defines every colour each palette needs", function()
    for _, name in ipairs(theme.names) do
      local palette = theme.palettes[name]
      truthy(palette, "palette " .. name)
      for _, key in ipairs({ "bg", "fg", "muted", "accent", "mark", "link" }) do
        matches(palette[key], "^#%x%x%x%x%x%x$", name .. "." .. key)
      end
    end
  end)

  it("normalises names and aliases", function()
    eq(theme.normalize("paper"), "paper")
    eq(theme.normalize("NIGHT"), "night")
    eq(theme.normalize("plain"), "none", "plain is an alias for leaving the window alone")
    eq(theme.normalize("none"), "none")
    eq(theme.normalize(nil), "paper")
    eq(theme.normalize("nonsense"), "paper")
  end)

  it("renders each palette into highlight groups", function()
    theme.define("paper")
    local normal = vim.api.nvim_get_hl(0, { name = "WereadPaperNormal" })
    eq(normal.bg, tonumber(theme.palettes.paper.bg:sub(2), 16))
    eq(normal.fg, tonumber(theme.palettes.paper.fg:sub(2), 16))

    theme.define("night")
    local night = vim.api.nvim_get_hl(0, { name = "WereadPaperNormal" })
    eq(night.bg, tonumber(theme.palettes.night.bg:sub(2), 16), "switching rewrites them")
  end)

  it("maps the reading groups through winhighlight", function()
    local value = theme.winhighlight("sepia")
    truthy(value:find("Normal:WereadPaperNormal", 1, true), "window background")
    truthy(value:find("WereadMark:WereadPaperMark", 1, true), "highlights follow the palette")
    truthy(value:find("WinBar:WereadPaperWinBar", 1, true), "and so does the winbar")
    eq(theme.winhighlight("none"), "", "no mapping means the editor colours stay")
  end)
end)

describe("theme foreign markdown groups", function()
  it("puts the page background back under headings and fences", function()
    -- render-markdown.nvim paints headings with its own background (that is
    -- what made a heading line look like a coloured band), so a couple of its
    -- groups are faked here.
    -- (render-markdown.nvim 用自己的背景画标题——这正是标题行看起来像色带的原因。
    --  这里伪造它的几个组)
    vim.api.nvim_set_hl(0, "RenderMarkdownH1Bg", { bg = 0x2c314a, fg = 0xffffff, bold = true })
    vim.api.nvim_set_hl(0, "RenderMarkdownH2Bg", { bg = 0x38343d, fg = 0xffffff })
    vim.api.nvim_set_hl(0, "RenderMarkdownH3", { fg = 0x89b4fa })
    vim.api.nvim_set_hl(0, "RenderMarkdownCode", { bg = 0x1e2030 })
    vim.api.nvim_set_hl(0, "RenderMarkdownQuote", { fg = 0xf9e2af })
    vim.api.nvim_set_hl(0, "RenderMarkdownBullet", { fg = 0x89dceb })
    vim.api.nvim_set_hl(0, "UnrelatedGroup", { bg = 0x112233 })
    -- the treesitter groups are the other half of the problem: they ship a
    -- background too
    -- (treesitter 的组是问题的另一半：它们同样自带背景)
    vim.api.nvim_set_hl(0, "@markup.heading.1.markdown", { bg = 0x2c314a, fg = 0x82aaff })
    vim.api.nvim_set_hl(0, "@markup.strong.markdown", { fg = 0xffc777, bold = true })
    vim.api.nvim_set_hl(0, "@markup.heading.1.html", { bg = 0x2c314a })

    local groups = theme.foreign_groups()
    truthy(#groups >= 8, "found the syntax groups: " .. #groups)
    eq(vim.tbl_contains(groups, "UnrelatedGroup"), false, "and nothing else")
    eq(vim.tbl_contains(groups, "@markup.heading.1.markdown"), true, "treesitter markdown groups are included")
    eq(vim.tbl_contains(groups, "@markup.heading.1.html"), false, "other languages are left alone")

    eq(theme.substitute("RenderMarkdownH1Bg"), "WereadPaperHeading")
    eq(theme.substitute("RenderMarkdownH7"), "WereadPaperHeading")
    eq(theme.substitute("RenderMarkdownCodeBorder"), "WereadPaperCode")
    eq(theme.substitute("RenderMarkdownQuote1"), "WereadPaperQuote")
    eq(theme.substitute("RenderMarkdownLink"), "WereadPaperLinkBg")
    eq(theme.substitute("RenderMarkdownBullet"), "WereadPaperMuted")
    eq(theme.substitute("@markup.heading.1.markdown"), "WereadPaperHeading")
    eq(theme.substitute("@markup.heading.6.markdown"), "WereadPaperHeading")
    eq(theme.substitute("@markup.strong.markdown"), "WereadPaperStrong")
    eq(theme.substitute("@markup.italic.markdown"), "WereadPaperItalic")
    eq(theme.substitute("@markup.raw.block.markdown"), "WereadPaperCode")
    eq(theme.substitute("@markup.quote.markdown"), "WereadPaperQuote")
    eq(theme.substitute("@markup.link.url.markdown"), "WereadPaperLinkBg")
  end)

  it("maps them to groups that carry the paper background", function()
    theme.define("paper")
    local paper_bg = tonumber(theme.palettes.paper.bg:sub(2), 16)

    for _, group in ipairs({
      "WereadPaperHeading",
      "WereadPaperCode",
      "WereadPaperMuted",
      "WereadPaperLinkBg",
      "WereadPaperStrong",
      "WereadPaperItalic",
    }) do
      eq(vim.api.nvim_get_hl(0, { name = group }).bg, paper_bg, group .. " must not form a band")
    end
    eq(vim.api.nvim_get_hl(0, { name = "WereadPaperHeading" }).bold, true, "headings stay bold")

    local value = theme.winhighlight("paper")
    truthy(value:find("RenderMarkdownH1Bg:WereadPaperHeading", 1, true) ~= nil, "got: " .. value)
    truthy(value:find("RenderMarkdownCode:WereadPaperCode", 1, true) ~= nil)
    truthy(
      value:find("@markup.heading.1.markdown:WereadPaperHeading", 1, true) ~= nil,
      "the treesitter heading group is remapped too"
    )
  end)

  it("follows the palette when switching themes", function()
    theme.define("night")
    eq(
      vim.api.nvim_get_hl(0, { name = "WereadPaperHeading" }).bg,
      tonumber(theme.palettes.night.bg:sub(2), 16)
    )
    theme.define("paper")
  end)
end)

describe("theme.apply", function()
  ---@return integer buf
  local function chapter_buffer()
    local buf = vim.api.nvim_create_buf(false, true)
    vim.b[buf].weread = { book_id = "1", chapter_key = "0001", chapter_index = 1 }
    return buf
  end

  it("repaints the chapter window and nothing else", function()
    local plain = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_win_set_buf(0, plain)
    vim.cmd("vsplit")
    local other = vim.api.nvim_get_current_win()
    vim.api.nvim_win_set_buf(other, chapter_buffer())

    local plain_win = nil
    for _, win in ipairs(vim.api.nvim_list_wins()) do
      if win ~= other then
        plain_win = win
      end
    end
    truthy(plain_win, "two windows")
    vim.wo[plain_win].winhighlight = ""
    vim.wo[other].winhighlight = ""

    theme.apply(other, "paper")
    truthy(vim.wo[other].winhighlight:find("WereadPaperNormal", 1, true), "chapter window repainted")
    eq(vim.wo[plain_win].winhighlight, "", "the other window is untouched")

    vim.cmd("only")
    pcall(vim.api.nvim_buf_delete, plain, { force = true })
  end)

  it("applies to every open chapter window when switching themes", function()
    local buf = chapter_buffer()
    vim.api.nvim_win_set_buf(0, buf)
    theme.set("night")
    truthy(vim.wo.winhighlight:find("WereadPaperNormal", 1, true))
    eq(require("weread.prefs").get("theme"), "night", "remembered for the next session")
    eq(config.get().theme, "night", "and active right away")
    pcall(vim.api.nvim_buf_delete, buf, { force = true })
  end)

  it("offers every palette plus an opt-out", function()
    local names = {}
    for _, item in ipairs(theme.items()) do
      names[item.name] = true
    end
    for _, name in ipairs(theme.names) do
      truthy(names[name], "listed: " .. name)
    end
    truthy(names.none, "and the opt-out")
  end)
end)
