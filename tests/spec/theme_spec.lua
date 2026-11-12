--[[
Tests for weread.theme: the reading palettes and the fact that they only touch
the chapter window.
(theme 单测：阅读配色，以及「只影响章节窗口」这一条)
]]

local theme = require("weread.theme")

---WCAG contrast ratio between two "#rrggbb" colours.
---(两个颜色之间的 WCAG 对比度)
local function contrast(a, b)
  local function luminance(hex)
    local channels = {}
    for i = 0, 2 do
      local c = tonumber(hex:sub(2 + i * 2, 3 + i * 2), 16) / 255
      channels[#channels + 1] = c <= 0.03928 and c / 12.92 or ((c + 0.055) / 1.055) ^ 2.4
    end
    return 0.2126 * channels[1] + 0.7152 * channels[2] + 0.0722 * channels[3]
  end
  local x, y = luminance(a), luminance(b)
  return (math.max(x, y) + 0.05) / (math.min(x, y) + 0.05)
end

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
    eq(theme.normalize(nil), "none", "no theme keeps the colorscheme")
    eq(theme.normalize("nonsense"), "none", "an unknown name falls back to the default")
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
    -- Generic captures are taken over as well, `@text.strong` and friends
    -- included: they are what paints a bold sentence in the colorscheme's blue on
    -- a black and white page. That is safe because `winhighlight` is per window
    -- and the window gets its colors back the moment the chapter leaves it.
    -- (通用捕获也一并接管，包括 `@text.strong` 这类：黑白页面上加粗句子显出配色方案的蓝色就是
    --  它们干的。这样做是安全的，因为 `winhighlight` 只作用于窗口，章节离开该窗口时颜色就还回去了)
    eq(vim.tbl_contains(groups, "@markup.heading.1.html"), true, "captures are mapped by family, not by language")

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
    local quote = vim.api.nvim_get_hl(0, { name = "WereadPaperQuote" })
    eq(quote.fg, tonumber(theme.palettes.paper.fg:sub(2), 16), "quotes use readable body ink")
    eq(quote.bg, paper_bg, "quotes stay on paper")

    local value = theme.winhighlight("paper")
    truthy(value:find("RenderMarkdownH1Bg:WereadPaperHeading", 1, true) ~= nil, "got: " .. value)
    truthy(value:find("RenderMarkdownCode:WereadPaperCode", 1, true) ~= nil)
    truthy(value:find("@markup.quote:WereadPaperQuote", 1, true) ~= nil, "quote body is mapped before parser attach")
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

describe("theme picker preview", function()
  it("paints a sample page in each palette, under groups of its own", function()
    for _, name in ipairs({ "paper", "night", "eink", "none" }) do
      local lines, marks, groups = theme.sample(name, 64)
      local text = table.concat(lines, "\n")
      matches(text, "焦油坑", name .. " shows a page of text")
      matches(text, "我的划线", name .. " shows the highlight styles")
      truthy(#marks > 10, name .. " colours the sample")
      truthy(groups.normal:find("^WereadSample"), "a sample group, not a chapter one")
      if name ~= "none" then
        local normal = vim.api.nvim_get_hl(0, { name = groups.normal })
        eq(string.format("#%06x", normal.bg), theme.palettes[name].bg, name .. " page colour")
      end
    end
  end)

  it("describes every choice in words, not hex codes", function()
    for _, item in ipairs(theme.items()) do
      falsy(item.text:find("#%x%x%x%x%x%x"), "no colour codes in the list: " .. item.text)
      truthy(item.description and item.description ~= "", item.name .. " has a description")
    end
  end)
end)

describe("theme code listings", function()
  it("repaints code captures in the palette's syntax inks", function()
    eq(theme.syntax_substitute("@function.call.bash"), "WereadPaperSynFunction")
    eq(theme.syntax_substitute("@keyword.return.lua"), "WereadPaperSynKeyword")
    eq(theme.syntax_substitute("@string.go"), "WereadPaperSynString")
    eq(theme.syntax_substitute("@comment"), "WereadPaperSynComment")
    eq(theme.syntax_substitute("Normal"), nil)
    eq(theme.substitute("@punctuation.special.markdown"), "WereadPaperTableRow", "a table's pipes")
    eq(theme.substitute("@markup.raw.block.markdown"), "WereadPaperCode", "markdown captures keep their mapping")
  end)

  it("keeps every syntax ink readable on its page", function()
    for _, name in ipairs(theme.names) do
      local palette = theme.palettes[name]
      for role, ink in pairs(palette.code or {}) do
        if type(ink) == "string" then
          local floor = role == "comment" and 3.5 or 4.5
          truthy(contrast(palette.bg, ink) >= floor, string.format("%s %s %s on %s: %.1f", name, role, ink, palette.bg, contrast(palette.bg, ink)))
        end
      end
    end
  end)
end)

describe("theme foreign groups", function()
  it("takes over the generic text captures too", function()
    -- A colorscheme paints `@text.strong` and `@text.italic` in its own colours,
    -- and those are not markdown specific: they were what turned bold text blue
    -- on a black and white page.
    -- (配色方案会给 `@text.strong`、`@text.italic` 上自己的颜色，而它们并不属于 markdown 专属
    --  家族——黑白页面上加粗文字显出蓝色就是它们干的)
    vim.api.nvim_set_hl(0, "@text.strong", { fg = "#c8d3f5" })
    vim.api.nvim_set_hl(0, "@text.italic", { fg = "#c8d3f5" })
    vim.api.nvim_set_hl(0, "@text.literal", { fg = "#c8d3f5" })
    vim.api.nvim_set_hl(0, "@markup.heading.2.markdown", { fg = "#c8d3f5", bg = "#2c314a" })

    local groups = theme.foreign_groups()
    local seen = {}
    for _, name in ipairs(groups) do
      seen[name] = true
    end
    eq(seen["@text.strong"], true, "generic captures are included")
    eq(seen["@text.italic"], true)
    eq(seen["@markup.heading.2.markdown"], true)

    eq(theme.substitute("@text.strong"), "WereadPaperStrong")
    eq(theme.substitute("@text.italic"), "WereadPaperItalic")
    eq(theme.substitute("@text.literal"), "WereadPaperCode")

    local value = theme.winhighlight("eink")
    truthy(value:find("@text%.strong:WereadPaperStrong", 1) or value:find("@text.strong:WereadPaperStrong", 1),
      "and it reaches the window: " .. value:sub(1, 120))
  end)
end)

describe("theme.clear_stale", function()
  it("hands a window its colorscheme back once the chapter is gone", function()
    -- `winhighlight` is a window option: without this, a window that once showed
    -- a chapter keeps the paper palette for whatever is shown in it next.
    -- (`winhighlight` 是窗口选项：没有这一步，曾经显示过章节的窗口会一直用纸色配色显示后面的内容)
    local reader = require("weread.reader")
    local win = vim.api.nvim_get_current_win()
    local chapter = vim.api.nvim_create_buf(false, true)
    local plain = vim.api.nvim_create_buf(false, true)
    vim.b[chapter].weread = { book_id = "1", chapter_key = "0001" }
    vim.wo[win].winhighlight = theme.winhighlight("eink")
    truthy(vim.wo[win].winhighlight ~= "", "the page is painted")

    -- showing another buffer in the window already triggers the cleanup through
    -- the reader's WinEnter/BufEnter autocmd
    -- (在窗口里显示别的 buffer 时，清理会经由阅读器的 WinEnter/BufEnter 自动触发)
    vim.api.nvim_win_set_buf(win, plain)
    eq(vim.wo[win].winhighlight, "", "the colors came back on their own")

    -- and the sweep catches a window that was painted some other way
    -- (而清扫函数能兜住以别的方式被刷色的窗口)
    vim.wo[win].winhighlight = theme.winhighlight("eink")
    eq(theme.clear_stale(), 1, "the stale window was found")
    eq(vim.wo[win].winhighlight, "", "and it got its colors back")

    -- a chapter window keeps its palette
    -- (章节窗口保留自己的配色)
    vim.wo[win].winhighlight = theme.winhighlight("eink")
    vim.api.nvim_win_set_buf(win, chapter)
    eq(theme.clear_stale(), 0, "reading windows are left alone")
    truthy(vim.wo[win].winhighlight ~= "", "still painted")
    vim.wo[win].winhighlight = ""
    vim.api.nvim_buf_delete(chapter, { force = true })
    vim.api.nvim_buf_delete(plain, { force = true })
    truthy(reader ~= nil, "keep the import honest")
  end)
end)


describe("theme eye comfort", function()
  it("defaults to paper; auto still follows a light or dark editor", function()
    eq(require("weread.config").defaults.theme, "paper")
    local background = vim.o.background
    vim.o.background = "light"
    eq(theme.normalize("auto"), "paper")
    vim.o.background = "dark"
    eq(theme.normalize("auto"), "night")
    vim.o.background = background
  end)

  it("keeps body text readable but well below pure black on white", function()
    for _, name in ipairs({ "paper", "night", "sepia", "jade", "dusk", "dragon" }) do
      local palette = theme.palettes[name]
      local ratio = contrast(palette.bg, palette.fg)
      -- A light page stays under 10 so it does not glare; a dark one only has a
      -- floor, because WCAG overstates dark pairs (the old night ink scored
      -- 8.7 here yet read faint — APCA put it at Lc 65).
      -- (浅色页面保持在 10 以下，免得刺眼；深色只设下限，因为 WCAG 会高估深色组合——
      --  旧的夜间墨色这里算出 8.7，读起来却发虚，APCA 只有 Lc 65)
      local dark = require("weread.color").luminance(palette.bg) < 0.2
      local ceiling = dark and math.huge or 10
      truthy(ratio >= 7 and ratio <= ceiling, string.format("%s body contrast %.1f should be within 7..%s", name, ratio, tostring(ceiling)))
      truthy(contrast(palette.bg, palette.muted) >= 3.5, name .. " muted text stays legible")
      truthy(contrast(palette.mark, palette.fg) >= 6, name .. " marked text stays legible")
    end
  end)
end)

describe("theme precedence", function()
  it("lets a theme written in setup win over the remembered one", function()
    local weread = require("weread")
    local prefs = require("weread.prefs")
    prefs.set("theme", "eink")

    weread.setup({ data_dir = tmpdir, theme = "paper" })
    eq(config.get().theme, "paper", "the config is not overridden by an old :WeReadTheme choice")
    truthy(config.theme_pinned())

    weread.setup({ data_dir = tmpdir })
    eq(config.get().theme, "eink", "without a configured theme the remembered one fills in")
    falsy(config.theme_pinned())

    prefs.clear()
    config.setup({ data_dir = tmpdir })
    eq(config.get().theme, "paper", "without a configured or remembered theme, paper is used")
  end)
end)

describe("theme eink", function()
  it("offers no colour at all", function()

    local palette = theme.palettes.eink
    truthy(palette, "the palette exists")
    eq(palette.bg, "#ffffff", "the paper is pure white")
    eq(palette.fg, "#000000", "and the ink is pure black")
    local function channels(hex)
      local r, g, b = hex:match("^#(%x%x)(%x%x)(%x%x)$")
      return tonumber(r, 16), tonumber(g, 16), tonumber(b, 16)
    end
    for _, key in ipairs({ "bg", "fg", "muted", "accent", "mark", "link" }) do
      local r, g, b = channels(palette[key])
      truthy(r, "palette has " .. key)
      local spread = math.max(r, g, b) - math.min(r, g, b)
      truthy(spread <= 8, string.format("%s must be grey, got %s (spread %d)", key, palette[key], spread))
    end
    eq(theme.normalize("eink"), "eink")
    truthy(vim.tbl_contains(theme.names, "eink"), "and it is offered by the picker")
  end)

  it("tells highlights apart by rule shape instead of colour", function()
    theme.define("eink")
    local mine = vim.api.nvim_get_hl(0, { name = "WereadPaperMineHighlight" })
    local popular = vim.api.nvim_get_hl(0, { name = "WereadPaperPopularHighlight" })
    eq(mine.underdouble, true, "my highlights are a double rule")
    eq(popular.underdashed, true, "popular ones a dashed one")
    falsy(popular.undercurl, "no coloured curl on a monochrome page")
    eq(mine.sp, tonumber("000000", 16), "the rule is ink, not a colour")
    -- put the default palette back for the next spec file
    theme.define(theme.normalize(require("weread.config").get().theme))
  end)
end)

describe("theme heading levels and page furniture", function()
  local GROUPS = { "WereadHeading", "WereadHeading1", "WereadHeading2", "WereadHeading3", "WereadFooter", "WereadFootnote" }

  it("defines every group in every palette", function()
    for _, name in ipairs(theme.names) do
      theme.define(name)
      local palette = theme.palettes[name]
      for _, group in ipairs(GROUPS) do
        truthy(next(vim.api.nvim_get_hl(0, { name = group })), name .. " defines " .. group)
      end
      local accent = tonumber(palette.accent:sub(2), 16)
      eq(vim.api.nvim_get_hl(0, { name = "WereadHeading1" }).fg, accent, name .. ": chapter titles in the accent")
      eq(vim.api.nvim_get_hl(0, { name = "WereadHeading2" }).fg, accent)
      eq(vim.api.nvim_get_hl(0, { name = "WereadHeading3" }).fg, tonumber(palette.fg:sub(2), 16), "deeper levels in ink")
      eq(vim.api.nvim_get_hl(0, { name = "WereadHeading3" }).bold, true)
      eq(vim.api.nvim_get_hl(0, { name = "WereadFooter" }).fg, tonumber(palette.muted:sub(2), 16))
      eq(vim.api.nvim_get_hl(0, { name = "WereadFootnote" }).fg, tonumber(palette.muted:sub(2), 16))
    end
    theme.define(theme.normalize(require("weread.config").get().theme))
  end)

  it("defines them for the none theme too", function()
    theme.winhighlight("none")
    for _, group in ipairs(GROUPS) do
      truthy(next(vim.api.nvim_get_hl(0, { name = group })), "none defines " .. group)
    end
    theme.define(theme.normalize(require("weread.config").get().theme))
  end)
end)

describe("theme switching back to none and colorscheme reloads", function()
  local EMPHASIS = {
    WereadStrong = "bold",
    WereadItalic = "italic",
    WereadUnderline = "underline",
    WereadStrike = "strikethrough",
  }

  it("hands inline emphasis back to the colorscheme when leaving a palette", function()
    theme.define("paper")
    local paper_bg = tonumber(theme.palettes.paper.bg:sub(2), 16)
    eq(vim.api.nvim_get_hl(0, { name = "WereadStrong" }).bg, paper_bg, "the palette painted it")
    theme.winhighlight("none")
    for group, attr in pairs(EMPHASIS) do
      local hl = vim.api.nvim_get_hl(0, { name = group, link = false })
      eq(hl.bg, nil, group .. " keeps no paper background")
      eq(hl.fg, nil, group .. " keeps no paper ink")
      truthy(hl[attr], group .. " still carries " .. attr)
    end
    theme.define(theme.normalize(require("weread.config").get().theme))
  end)

  it("keeps the attribute even after a colorscheme cleared the built-ins", function()
    vim.cmd("highlight clear")
    theme.define_emphasis_none()
    for group, attr in pairs(EMPHASIS) do
      truthy(vim.api.nvim_get_hl(0, { name = group, link = false })[attr], group .. " carries " .. attr)
    end
  end)

  it("redefines the palette groups a :colorscheme wiped", function()
    theme.define("night")
    vim.cmd("highlight clear")
    eq(next(vim.api.nvim_get_hl(0, { name = "WereadPaperNormal" })), nil, "highlight clear wipes them")
    theme.redefine("night")
    local night = theme.palettes.night
    eq(vim.api.nvim_get_hl(0, { name = "WereadPaperNormal" }).bg, tonumber(night.bg:sub(2), 16))
    eq(vim.api.nvim_get_hl(0, { name = "WereadHeading1" }).fg, tonumber(night.accent:sub(2), 16))
    eq(vim.api.nvim_get_hl(0, { name = "WereadStrong" }).fg, tonumber(night.fg:sub(2), 16))
    truthy(next(vim.api.nvim_get_hl(0, { name = "WereadFootnote" })), "page furniture too")

    vim.cmd("highlight clear")
    theme.redefine("none")
    truthy(next(vim.api.nvim_get_hl(0, { name = "WereadFooter" })), "none still defines its groups")
    truthy(vim.api.nvim_get_hl(0, { name = "WereadStrong", link = false }).bold)
    theme.redefine()
  end)

  it("puts the cursor-hiding group back after :colorscheme", function()
    -- `:colorscheme default` runs `:highlight clear`, and a cursor without its
    -- blend shows up in the middle of the page again
    -- (`:colorscheme default` 会执行 `:highlight clear`，失去 blend 的光标又会出现在页面中间)
    -- noautocmd: the plugin's own ColorScheme autocmd would answer before the
    -- assertion, and it is redefine itself under test here
    -- (noautocmd：插件自己的 ColorScheme 自动命令会抢在断言之前补回，而这里测的是 redefine 本身)
    vim.cmd("noautocmd colorscheme default")
    eq(vim.api.nvim_get_hl(0, { name = "WereadCursorHidden" }).blend, nil, "the colorscheme wiped it")
    theme.redefine("night")
    eq(vim.api.nvim_get_hl(0, { name = "WereadCursorHidden" }).blend, 100)
    truthy(next(vim.api.nvim_get_hl(0, { name = "WereadMineHighlight" })), "annotation groups too")
    theme.redefine()
  end)

  it("paints the reading cursor in the palette's accent", function()
    theme.define("paper")
    local cursor = vim.api.nvim_get_hl(0, { name = "WereadCursor" })
    eq(cursor.bg, tonumber(theme.palettes.paper.accent:sub(2), 16), "an accent block stands out on paper")
    eq(cursor.fg, tonumber(theme.palettes.paper.bg:sub(2), 16), "the character under it stays readable")
    theme.define_heading("none")
    eq(vim.api.nvim_get_hl(0, { name = "WereadCursor" }).link, "Cursor", "none keeps the editor's cursor")
    theme.redefine()
  end)

  it("draws the normal-mode cursor as the accent block while reading", function()
    local shell = require("weread.shell")
    local reader = require("weread.reader")
    local original = reader.buffer_info
    local guicursor = vim.o.guicursor
    reader.buffer_info = function()
      return {}
    end
    shell.leave()
    shell.enter()
    eq(vim.o.guicursor:sub(-#"n:block-WereadCursor"), "n:block-WereadCursor", "block is the default: " .. vim.o.guicursor)
    shell.leave()
    eq(vim.o.guicursor, guicursor, "restored on the way out")
    reader.buffer_info = original
  end)

  it("takes the paper background off tables under none", function()
    -- tables are drawn with these groups by name, not through winhighlight, so a
    -- palette shown earlier left a yellow band behind every table border
    -- (表格按名字使用这些组、不经过 winhighlight，于是之前显示过的配色在每条表格边框后面留下黄底)
    theme.define("paper")
    truthy(vim.api.nvim_get_hl(0, { name = "WereadPaperTableRow" }).bg, "paper paints them")
    theme.define_heading("none")
    for _, group in ipairs({ "WereadPaperTableHead", "WereadPaperTableRow", "WereadPaperMargin" }) do
      truthy(vim.api.nvim_get_hl(0, { name = group }).link, group .. " follows the colorscheme")
    end
    theme.redefine()
  end)

  it("asks the pager to repaint after a switch, and survives a pager without it", function()
    local original = package.loaded["weread.pager"]
    local calls = 0
    package.loaded["weread.pager"] = { retheme = function()
      calls = calls + 1
    end }
    theme.apply_all("paper")
    eq(calls, 1)
    package.loaded["weread.pager"] = { retheme = function()
      error("boom")
    end }
    theme.apply_all("paper")
    package.loaded["weread.pager"] = {}
    theme.apply_all("paper")
    package.loaded["weread.pager"] = original
  end)
end)

describe("theme readability", function()
  local color = require("weread.color")

  it("holds every palette to the APCA floors", function()
    -- Body text at Lc 75 or beyond (APCA's floor for body text), quiet ink,
    -- titles and links at 58 — the night palette's old Lc 50 inks read faint.
    -- (正文 Lc 75 以上（APCA 的正文下限），淡色字、标题、链接在 58 以上——夜间配色原来 Lc 50 的
    --  墨色读起来发虚)
    for _, name in ipairs(theme.names) do
      local palette = theme.palettes[name]
      local body = math.abs(color.apca(palette.fg, palette.bg))
      truthy(body >= 75, string.format("%s body Lc %.1f", name, body))
      for _, key in ipairs({ "muted", "accent", "link" }) do
        local lc = math.abs(color.apca(palette[key], palette.bg))
        truthy(lc >= 58, string.format("%s %s Lc %.1f", name, key, lc))
      end
    end
  end)

  it("gives every palette its code inks", function()
    for _, name in ipairs(theme.names) do
      truthy(type(theme.palettes[name].code) == "table", name .. " has a code table")
    end
  end)

  it("tells sepia and paper apart", function()
    local L1 = color.oklab(theme.palettes.paper.bg)
    local L2 = color.oklab(theme.palettes.sepia.bg)
    truthy(math.abs(L1 - L2) >= 0.03, "the pages differ in lightness")
  end)

  it("orders the palettes from light to dark", function()
    local first = color.luminance(theme.palettes[theme.names[1]].bg)
    local last = color.luminance(theme.palettes[theme.names[#theme.names]].bg)
    truthy(first > last, "lightest first")
  end)
end)

describe("theme choices", function()
  it("refuses an unknown name instead of remembering it", function()
    local prefs = require("weread.prefs")
    theme.set("paper", { quiet = true })
    local notified = {}
    local notify = vim.notify
    vim.notify = function(message, level)
      notified[#notified + 1] = { message = message, level = level }
    end
    eq(theme.set("sepai"), false)
    vim.notify = notify
    eq(prefs.get("theme"), "paper", "the typo was not written down")
    eq(config.get().theme, "paper")
    eq(notified[1].level, vim.log.levels.WARN)
    matches(notified[1].message, "sepia", "the message lists what is there")
  end)

  it("cycles through the palettes and wraps round", function()
    theme.set(theme.names[#theme.names], { quiet = true })
    local notify = vim.notify
    vim.notify = function() end
    eq(theme.cycle(1), theme.names[1], "past the darkest comes the lightest")
    eq(theme.cycle(-1), theme.names[#theme.names], "and back")
    eq(theme.cycle(2), theme.names[2], "a count skips ahead")
    theme.set("none")
    eq(theme.cycle(1), theme.names[1], "from none, forward starts at the first page")
    vim.notify = notify
    theme.set("paper", { quiet = true })
  end)

  it("keeps auto as the choice and resolves it on the page", function()
    local background = vim.o.background
    vim.o.background = "dark"
    theme.set("auto", { quiet = true })
    eq(config.get().theme, "auto", "the choice itself is remembered")
    eq(theme.current(), "night")
    vim.o.background = background
    theme.set("paper", { quiet = true })
  end)

  it("lists auto and none after the palettes", function()
    local choices = theme.choices()
    eq(choices[#choices - 1], "auto")
    eq(choices[#choices], "none")
  end)

  it("tries a theme without remembering it, and puts the old one back", function()
    local prefs = require("weread.prefs")
    theme.set("paper", { quiet = true })
    theme.try("night")
    eq(theme.current(), "night", "the page shows it")
    eq(prefs.get("theme"), "paper", "but nothing was written")
    theme.untry()
    eq(theme.current(), "paper")
  end)
end)

describe("theme picker hooks", function()
  it("tries on move, restores on Esc, and sets on confirm", function()
    local ui = require("weread.ui")
    local original = ui.select
    local opts
    ui.select = function(o)
      opts = o
    end
    theme.set("paper", { quiet = true })
    theme.picker()
    ui.select = original
    truthy(opts and opts.on_change and opts.on_close, "the picker follows the cursor")
    local current
    for _, item in ipairs(opts.items) do
      if item.current then
        current = item.name
      end
    end
    eq(current, "paper", "the theme in use is marked")

    theme.try("dragon")
    opts.on_close(false)
    eq(theme.current(), "paper", "Esc puts the page back")

    local notify = vim.notify
    vim.notify = function() end
    opts.on_close(true)
    opts.on_choice({ name = "dusk" })
    vim.notify = notify
    eq(theme.current(), "dusk")
    eq(require("weread.prefs").get("theme"), "dusk")
    theme.set("paper", { quiet = true })
  end)

  it("draws a four-colour swatch per palette", function()
    local groups = theme.swatch_groups("eink_soft")
    eq(#groups, 4)
    eq(vim.api.nvim_get_hl(0, { name = groups[3] }).fg, tonumber(theme.palettes.eink_soft.accent:sub(2), 16))
    eq(theme.swatch_groups("none"), nil)
  end)
end)

describe("theme window mapping", function()
  it("repaints selection, search and the unfocused window", function()
    local value = theme.winhighlight("paper")
    for _, pair in ipairs({
      "NormalNC:WereadPaperNormal",
      "Visual:WereadPaperVisual",
      "Search:WereadPaperSearch",
      "CurSearch:WereadPaperCurSearch",
      "WereadCode:WereadPaperInlineCode",
    }) do
      truthy(value:find(pair, 1, true), pair)
    end
  end)

  it("keeps the cursor line apart from marked text, and inline code off the link rule", function()
    theme.define("paper")
    local line = vim.api.nvim_get_hl(0, { name = "WereadPaperCursorLine" })
    local mark = vim.api.nvim_get_hl(0, { name = "WereadPaperMark" })
    truthy(line.bg ~= mark.bg, "cursor line and <mark> differ")
    falsy(vim.api.nvim_get_hl(0, { name = "WereadPaperInlineCode" }).underline, "inline code is not a link")
    theme.redefine()
  end)
end)

describe("theme custom palettes", function()
  local color = require("weread.color")

  it("derives a readable palette from a page and an ink", function()
    for _, spec in ipairs({
      { bg = "#f4ecd8", fg = "#3b3024" },
      { bg = "#1d2021", fg = "#d5c4a1" },
      { bg = "#ffffff", fg = "#333333" },
    }) do
      local palette = theme.derive(spec)
      for _, key in ipairs({ "muted", "accent", "link" }) do
        truthy(math.abs(color.apca(palette[key], palette.bg)) >= 58, key .. " on " .. spec.bg)
      end
      for role, ink in pairs(palette.code) do
        if type(ink) == "string" then
          truthy(color.wcag(ink, palette.bg) >= (role == "comment" and 3.5 or 4.5), role .. " on " .. spec.bg)
        end
      end
      truthy(color.wcag(palette.mark, palette.fg) >= 6 or color.luminance(palette.bg) < 0.2, "marked text readable")
    end
  end)

  it("registers palettes from setup and offers them", function()
    local notify = vim.notify
    local warnings = {}
    vim.notify = function(message)
      warnings[#warnings + 1] = message
    end
    local registered = theme.register({
      Mine = { bg = "#f4ecd8", fg = "#3b3024", accent = "#123456" },
      paper = { bg = "#ffffff", fg = "#000000" },
      broken = { bg = "white", fg = "#000000" },
    })
    vim.notify = notify
    eq(registered, { "mine" })
    eq(theme.palettes.mine.accent, "#123456", "an explicit ink is kept")
    eq(theme.names[#theme.names], "mine", "listed after the built-ins")
    eq(theme.normalize("mine"), "mine")
    eq(#warnings, 2, "the clash and the bad colour are reported")
    eq(theme.palettes.paper.bg, "#ede4d3", "a built-in is never replaced")

    theme.register(nil)
    eq(theme.palettes.mine, nil, "a later setup drops it")
    eq(theme.normalize("mine"), "none")
  end)
end)

describe("theme per book", function()
  local reader = require("weread.reader")
  local prefs = require("weread.prefs")

  local function with_book(id, fn)
    local saved = reader.state.book
    reader.state.book = { book_id = id }
    -- a book counts as open while a chapter of it is loaded (书有章节 buffer 在时才算打开)
    local buf = vim.api.nvim_create_buf(false, true)
    vim.b[buf].weread = { book_id = id, chapter_key = "0001", chapter_index = 1 }
    local ok, err = pcall(fn)
    vim.api.nvim_buf_delete(buf, { force = true })
    reader.state.book = saved
    if not ok then
      error(err, 0)
    end
  end

  it("keeps a theme for one book and the global one for the rest", function()
    local notify = vim.notify
    vim.notify = function() end
    theme.set("paper", { quiet = true })
    with_book("B1", function()
      theme.set("dragon", { book = true })
      eq(theme.current(), "dragon", "this book")
      eq(config.get().theme, "paper", "the global theme is untouched")
      eq(prefs.get("book_themes").B1, "dragon")
      theme.cycle(1)
      eq(theme.current(), "phosphor", "]t keeps working on the book's own theme")
      eq(config.get().theme, "paper")
    end)
    with_book("B2", function()
      eq(theme.current(), "paper", "another book follows the global theme")
    end)
    with_book("B1", function()
      truthy(theme.forget_book())
      eq(theme.current(), "paper", "back to following the global theme")
      eq(prefs.get("book_themes").B1, nil)
    end)
    vim.notify = notify
  end)

  it("ignores a stored book theme that no longer exists", function()
    prefs.set("book_themes", { B3 = "gone" })
    with_book("B3", function()
      eq(theme.book_choice(), nil)
      eq(theme.current(), theme.normalize(config.get().theme))
    end)
    prefs.set("book_themes", nil)
  end)

  it("tries on top of a book's theme and goes back to it", function()
    local notify = vim.notify
    vim.notify = function() end
    with_book("B4", function()
      theme.set("dusk", { book = true })
      theme.try("light")
      eq(theme.current(), "light")
      theme.untry()
      eq(theme.current(), "dusk")
      theme.forget_book()
    end)
    vim.notify = notify
  end)
end)

describe("theme fade", function()
  local fx = require("weread.fx")

  it("walks the palette groups from one page to the next and ends on the real one", function()
    fx._force, fx._sync = true, true
    local seen = {}
    local define = theme.define
    theme.define = function(name, override)
      if override then
        seen[#seen + 1] = override.bg
      end
      return define(name, override)
    end
    theme.set("paper", { quiet = true })
    local notify = vim.notify
    vim.notify = function() end
    theme.set("night")
    vim.notify = notify
    theme.define = define
    fx._force, fx._sync = false, false
    truthy(#seen >= 3, "several frames: " .. #seen)
    truthy(seen[1] ~= theme.palettes.paper.bg and seen[1] ~= theme.palettes.night.bg, "a frame in between")
    eq(vim.api.nvim_get_hl(0, { name = "WereadPaperNormal" }).bg, tonumber(theme.palettes.night.bg:sub(2), 16), "ends on night")
    theme.set("paper", { quiet = true })
  end)

  it("blends every ink, code inks included", function()
    local mid = theme.blend(theme.palettes.paper, theme.palettes.night, 0.5)
    truthy(mid.bg ~= theme.palettes.paper.bg)
    truthy(mid.code.keyword ~= theme.palettes.night.code.keyword)
  end)
end)

describe("theme popups", function()
  it("paints a popup over a chapter in the page colours, and leaves others alone", function()
    theme.set("paper", { quiet = true })
    local buf = vim.api.nvim_create_buf(false, true)
    vim.b[buf].weread = { book_id = "1", chapter_key = "0001", chapter_index = 1 }
    vim.api.nvim_win_set_buf(0, buf)
    local value = theme.float_winhighlight()
    truthy(value:find("NormalFloat:WereadPaperFloat", 1, true), value)
    local view = require("weread.float").open({ lines = { "x" } })
    truthy(vim.wo[view.win].winhighlight:find("WereadPaperFloat", 1, true), "float.open uses it")
    view:close()
    local plain = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_win_set_buf(0, plain)
    eq(theme.float_winhighlight(), "", "not over a chapter")
    theme.set("none", { quiet = true })
    vim.api.nvim_win_set_buf(0, buf)
    eq(theme.float_winhighlight(), "", "no palette")
    theme.set("paper", { quiet = true })
    vim.api.nvim_buf_delete(buf, { force = true })
    vim.api.nvim_buf_delete(plain, { force = true })
  end)
end)

describe("theme custom palette checks", function()
  local function quiet(fn)
    local notify = vim.notify
    local warnings = {}
    vim.notify = function(message)
      warnings[#warnings + 1] = message
    end
    local ok, result = pcall(fn)
    vim.notify = notify
    if not ok then
      error(result, 0)
    end
    return result, warnings
  end

  it("rejects bad rule styles, code inks and unreadable pairs", function()
    local registered, warnings = quiet(function()
      return theme.register({
        style = { bg = "#ffffff", fg = "#000000", mine_style = "wavy" },
        code = { bg = "#ffffff", fg = "#000000", code = { keyword = "red" } },
        sp = { bg = "#ffffff", fg = "#000000", mine_sp = "blue" },
        faint = { bg = "#ffffff", fg = "#eeeeee" },
        ok = { bg = "#ffffff", fg = "#222222", code = { keyword = "#aa0000", mono = true } },
      })
    end)
    eq(registered, { "ok" })
    eq(#warnings, 4)
    theme.register(nil)
  end)

  it("refuses names that clash by case or with command words", function()
    local registered, warnings = quiet(function()
      return theme.register({
        Mine = { bg = "#ffffff", fg = "#000000" },
        mine = { bg = "#000000", fg = "#ffffff" },
        next = { bg = "#ffffff", fg = "#000000" },
        global = { bg = "#ffffff", fg = "#000000" },
      })
    end)
    eq(registered, { "mine" }, "the first by sort order wins")
    eq(#warnings, 3)
    local count = 0
    for _, name in ipairs(theme.names) do
      if name == "mine" then
        count = count + 1
      end
    end
    eq(count, 1, "listed once")
    theme.register(nil)
  end)

  it("gives every palette its own sample and swatch groups", function()
    quiet(function()
      theme.register({ e_ink = { bg = "#ff0000", fg = "#000000" }, einksoft = { bg = "#00ff00", fg = "#000000" } })
    end)
    local seen = {}
    for _, name in ipairs(theme.names) do
      local group = theme.swatch_groups(name)[1]
      falsy(seen[group], name .. " shares " .. group .. " with " .. tostring(seen[group]))
      seen[group] = name
      local sample = theme.sample_groups(name).normal
      falsy(seen[sample], name .. " shares " .. sample)
      seen[sample] = name
    end
    theme.register(nil)
  end)

  it("keeps a faint wash visible on a near black page", function()
    local color = require("weread.color")
    quiet(function()
      theme.register({ pitch = { bg = "#000000", fg = "#cccccc" } })
    end)
    theme.define("pitch")
    local line = string.format("#%06x", vim.api.nvim_get_hl(0, { name = "WereadPaperCursorLine" }).bg)
    truthy(color.oklab(line) - color.oklab("#000000") >= 0.02, "cursor line " .. line .. " is not black")
    theme.register(nil)
    theme.redefine()
  end)

  it("drops a remembered custom theme the config no longer has", function()
    local weread = require("weread")
    local prefs = require("weread.prefs")
    weread.setup({ data_dir = tmpdir, palettes = { mine = { bg = "#f4ecd8", fg = "#3b3024" } } })
    theme.set("mine", { quiet = true })
    eq(prefs.get("theme"), "mine")
    weread.setup({ data_dir = tmpdir })
    eq(config.get().theme, "paper", "the removed custom theme falls back to the paper default, not a plain page")
    prefs.clear()
    config.setup({ data_dir = tmpdir })
  end)
end)

describe("theme picker resumed and background watcher", function()
  it("forgets the last outcome when a resumed picker shows again", function()
    local ui = require("weread.ui")
    local snacks_opts
    local fake = { picker = { pick = function(o)
      snacks_opts = o
    end } }
    local original = ui.snacks
    ui.snacks = function()
      return fake
    end
    theme.set("paper", { quiet = true })
    theme.picker()
    ui.snacks = original
    local picker = { items = function()
      return snacks_opts.items
    end, list = { view = function() end }, close = function() end }
    local notify = vim.notify
    vim.notify = function() end
    snacks_opts.on_show(picker)
    snacks_opts.confirm(picker, { name = "night" })
    snacks_opts.on_close(picker)
    -- resumed: same closures (恢复：同一批闭包)
    snacks_opts.on_show(picker)
    theme.try("dragon")
    snacks_opts.on_close(picker)
    vim.notify = notify
    eq(theme.current(), "night", "Esc in the resumed picker put the chosen page back")
    local marked
    for _, item in ipairs(snacks_opts.items) do
      if item.current then
        marked = item.name
      end
    end
    eq(marked, "night", "and it marks the theme in use now")
    theme.set("paper", { quiet = true })
  end)

  it("leaves the statusline alone unless the chapter has its own", function()
    falsy(theme.winhighlight("paper"):find("StatusLine:", 1, true), "keep/off: the editor's statusline")
    config.get().layout.statusline = "window"
    truthy(theme.winhighlight("paper"):find("StatusLine:WereadPaperStatusLine", 1, true))
    config.get().layout.statusline = "off"
  end)
end)

describe("theme per book once the book is closed", function()
  it("changes the global theme, not the closed book's", function()
    local reader = require("weread.reader")
    local prefs = require("weread.prefs")
    local saved = reader.state.book
    reader.state.book = { book_id = "CLOSED" }
    prefs.set("book_themes", { CLOSED = "sepia" })
    theme.set("dusk", { quiet = true })
    eq(config.get().theme, "dusk", "no chapter of the book is loaded: the global theme")
    eq(prefs.get("book_themes").CLOSED, "sepia", "the book's own choice is untouched")
    prefs.set("book_themes", nil)
    reader.state.book = saved
    theme.set("paper", { quiet = true })
  end)
end)
