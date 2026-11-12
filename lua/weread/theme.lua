--[[
Reading themes: make the chapter window look like a page of the WeRead app
instead of like an editor.
(阅读主题：让章节窗口看起来像微信读书的一页，而不是一个编辑器)

The app's look comes mostly from its paper background, its muted ink colour and
its colour for headings and quotes. None of that needs to leak into the rest of
the editor, so every palette is applied **per window** through `winhighlight`:
the chapter window gets the paper colours, your dashboard keeps your
colorscheme.
(App 的观感主要来自纸色底、柔和的墨色，以及标题与引用的颜色。这些都不必污染编辑器的
 其它部分，因此每套配色都通过 `winhighlight` **只作用于窗口**：章节窗口用纸色，
 其它窗口仍是你原来的配色)
]]

local M = {}

---Palettes, hand tuned to sit close to the app's own themes.
---(配色表，手调到接近 App 自带的几套主题)
M.palettes = {
  ---Warm rice paper, the default. Contrast is held around 8:1 on purpose: a
  ---terminal is a light source, and pure black on bright white (21:1) is what
  ---makes a long read sting.
  ---(暖米纸色，默认主题。对比度刻意控制在 8:1 左右：终端本身就是光源，亮白底上的纯黑字
  --- （21:1）正是久读刺眼的原因)
  paper = {
    bg = "#ede4d3",
    fg = "#4a4036",
    ---muted text is read too (footnotes, captions, quotes): APCA Lc ~66
    ---(淡色字也是要读的——脚注、图注、引文：APCA Lc 约 66)
    muted = "#6b5f51",
    ---accent and link one step darker than before (Lc 62 -> 68): titles and
    ---inline code were the faintest ink on the page
    ---(强调色与链接色比原来深一档（Lc 62 -> 68）：标题与行内代码曾是页面上最淡的墨)
    accent = "#7d5038",
    mark = "#e2d6bf",
    link = "#6a5440",
    ---syntax inks for code listings: muted, all at WCAG >= 4.5 on the page
    ---(代码清单的语法墨色：都是低饱和色，在纸页上 WCAG 对比度不低于 4.5)
    code = { keyword = "#8c4a2f", string = "#4f6b2f", func = "#2f5878", type = "#6a4a7a", number = "#8a5a1a", comment = "#7a6e60", punct = "#6b5f51" },
  },
  ---Brighter and yellower than paper, close to the sepia page of the Kindle
  ---apps (#fbf0d9 / #5f4b32, a single unofficial source). The old #efe3cd sat
  ---so close to paper that the two could not be told apart.
  ---(比 paper 更亮更黄，接近 Kindle 应用的 sepia 页面（#fbf0d9 / #5f4b32，仅一个非官方来源）。
  --- 原来的 #efe3cd 与 paper 太接近，两者分不出来)
  sepia = {
    bg = "#fbf0d9",
    fg = "#5f4b32",
    muted = "#7a6448",
    accent = "#8b4513",
    mark = "#f0e0bc",
    link = "#7a5428",
    code = { keyword = "#8b3a12", string = "#4d6326", func = "#2c5370", type = "#673f73", number = "#86541a", comment = "#7d6a52", punct = "#725e45" },
  },
  ---Plain light: no paper tint, for people who dislike warm backgrounds.
  ---(素白：不加纸色，给不喜欢暖底的人)
  light = {
    bg = "#fbfbfb",
    fg = "#2f2f2f",
    muted = "#707070",
    accent = "#2f6f9f",
    mark = "#eef3d8",
    link = "#2f6f9f",
    code = { keyword = "#a33a2a", string = "#3d6b1f", func = "#1f5f8f", type = "#6f3fa0", number = "#8a5a00", comment = "#6e6e6e", punct = "#5a5a5a" },
  },
  ---Night reading: a dark warm ground (not pure black, which halos the
  ---glyphs) with ink held at APCA Lc ~76, the body-text baseline. WCAG ratios
  ---overstate dark pairs; the old #c9bca5 measured Lc 65 and read faint.
  ---(夜间阅读：深暖底色（不用纯黑，纯黑会让字形发晕），墨色保持在 APCA Lc 约 76，即正文的基线。
  --- WCAG 对比度会高估深色组合；原来的 #c9bca5 实测只有 Lc 65，读起来发虚)
  ---The secondary inks were raised from Lc ~-50 to ~-59: footnotes, quotes and
  ---titles read faint before, the same fault the old body ink had.
  ---(次要墨色从 Lc 约 -50 提到约 -59：脚注、引文与标题原来读着发虚，与旧正文墨色是同一个毛病)
  night = {
    bg = "#23201c",
    fg = "#e2d6c0",
    muted = "#c0b39b",
    accent = "#d4aa7a",
    mark = "#3a332a",
    link = "#c8b294",
    code = { keyword = "#e0a07a", string = "#b5c88a", func = "#9cc0dc", type = "#c8a8d8", number = "#e0c080", comment = "#948a78", punct = "#b0a28a" },
  },
  ---E-ink: pure white paper, pure black ink, no colour anywhere — the look of a
  ---black and white screen rather than of tinted paper.
  ---(墨水屏：一种墨、一种纸，任何地方都没有彩色)
  ---
  ---This is the reading mode the app calls 墨水屏 and what an e-reader screen
  ---looks like: headings are black and bold instead of orange, my highlights are
  ---a solid black rule and popular ones a dashed one, and nothing on the page can
  ---be mistaken for a hyperlink colour. Highlights are told apart by the shape of
  ---the rule, which is how a monochrome screen has to do it.
  ---(这就是 App 里叫「墨水屏」的阅读模式，也是电纸书屏幕的样子：标题是黑色加粗而不是橙色，
  --- 我的划线是实线、热门划线是虚线，页面上没有任何一处会被误认成链接色。划线靠线型区分，
  --- 单色屏幕上只能如此)
  eink = {
    bg = "#ffffff",
    fg = "#000000",
    muted = "#595959",
    accent = "#000000",
    mark = "#d9d9d9",
    link = "#000000",
    ---a monochrome screen: code is told apart by weight and slant, not hue
    ---(单色屏：代码靠粗细与倾斜区分，而不是颜色)
    code = { keyword = "#000000", string = "#3a3a3a", func = "#000000", type = "#000000", number = "#3a3a3a", comment = "#595959", punct = "#3a3a3a", mono = true },
    ---no colour in the rules either(连划线也不用彩色)
    mine_sp = "#000000",
    popular_sp = "#808080",
    mine_style = "underdouble",
    popular_style = "underdashed",
  },
  ---E-ink, softened for a screen that glows: an off-white page and a near
  ---black ink (Lc ~100 instead of 106), still without any colour.
  ---(柔和墨水屏，给自发光的屏幕：米白纸、近黑墨（Lc 约 100，而不是 106），依然没有任何彩色)
  eink_soft = {
    bg = "#f7f7f4",
    fg = "#111111",
    muted = "#4a4a4a",
    accent = "#111111",
    mark = "#e2e2de",
    link = "#2a2a2a",
    code = { keyword = "#111111", string = "#3a3a3a", func = "#111111", type = "#111111", number = "#3a3a3a", comment = "#5a5a5a", punct = "#3a3a3a", mono = true },
    mine_sp = "#111111",
    popular_sp = "#808080",
    mine_style = "underdouble",
    popular_style = "underdashed",
  },
  ---Solarized light (Ethan Schoonover), with the body ink darkened: the
  ---original base00 is only Lc 66 on base3, too faint for a whole chapter.
  ---(Solarized 浅色（Ethan Schoonover），正文墨色加深：原版 base00 在 base3 上只有 Lc 66，
  --- 读一整章太淡)
  solarized = {
    bg = "#fdf6e3",
    fg = "#3f5259",
    muted = "#586e75",
    accent = "#a6501a",
    mark = "#eee8d5",
    link = "#1f6fa6",
    code = { keyword = "#686800", string = "#1d7a73", func = "#1f6fa6", type = "#8a6a00", number = "#b0306a", comment = "#6b7f86", punct = "#586e75" },
  },
  ---gruvbox light (morhetz): a warm yellow paper with dark brown ink.
  ---(gruvbox 浅色（morhetz）：暖黄纸配深棕墨)
  gruvbox = {
    bg = "#fbf1c7",
    fg = "#3c3836",
    muted = "#665c54",
    accent = "#af3a03",
    mark = "#ebdbb2",
    link = "#076678",
    code = { keyword = "#9d0006", string = "#66620a", func = "#076678", type = "#8f3f71", number = "#8f3f71", comment = "#7c6f64", punct = "#665c54" },
  },
  ---Dawn, after Rosé Pine Dawn: a neutral warm white with a cool violet ink.
  ---(晨，取自 Rosé Pine Dawn：中性的暖白配偏冷的紫墨)
  dawn = {
    bg = "#faf4ed",
    fg = "#3a3654",
    muted = "#5f5b78",
    accent = "#a3506a",
    mark = "#f2e9e1",
    link = "#286983",
    code = { keyword = "#286983", string = "#a0602a", func = "#9a4560", type = "#2f6a70", number = "#a0602a", comment = "#6f6a85", punct = "#5f5b78" },
  },
  ---Jade: a desaturated green page for readers who like the green reading mode
  ---of the Kindle and WeRead apps. Green is not easier on the eyes than any
  ---other page — there is no evidence for that — it is a preference.
  ---(竹青：降过饱和度的绿底，给喜欢 Kindle、微信读书绿色阅读模式的人。绿色并不比别的底色更
  --- 护眼——没有证据支持——只是偏好)
  jade = {
    bg = "#d8e6d2",
    fg = "#2e3d32",
    muted = "#4f6152",
    accent = "#4e6127",
    mark = "#c6d9bd",
    link = "#335a4b",
    code = { keyword = "#6e3a1f", string = "#3d5a1a", func = "#244e6a", type = "#5a3c6a", number = "#6e4a12", comment = "#556657", punct = "#4f6152" },
  },
  ---Dusk: a mid grey between the light pages and night, for the evening before
  ---the lights go out.
  ---(暮：介于浅色页面与夜间之间的中灰，给关灯之前的傍晚)
  dusk = {
    bg = "#3a3c40",
    fg = "#e2e0da",
    muted = "#c2bfb7",
    accent = "#e0c098",
    mark = "#4a4d52",
    link = "#b8c4cf",
    code = { keyword = "#e8b48a", string = "#c2d49a", func = "#a8c8e0", type = "#d4b8e0", number = "#e8cc90", comment = "#aaa69c", punct = "#c2bfb7" },
  },
  ---Dragon, after Kanagawa dragon: near black for OLED screens in a dark room,
  ---still not pure black, with every secondary ink held at Lc -60 or beyond.
  ---(墨龙，取自 Kanagawa dragon：给暗室里 OLED 屏的近黑底，但仍不是纯黑；所有次要墨色都在
  --- Lc -60 以外)
  dragon = {
    bg = "#181616",
    fg = "#d2d4cf",
    muted = "#b8b8ae",
    accent = "#e0a49c",
    mark = "#2a2826",
    link = "#a8bec8",
    code = { keyword = "#d8a0a0", string = "#a8c090", func = "#a0b8d0", type = "#c0b0d8", number = "#e0b880", comment = "#8e8c86", punct = "#b0b0a8" },
  },
  ---Phosphor: an amber CRT terminal, for fun. One hue only, so code is told
  ---apart by weight and slant as on e-ink.
  ---(琥珀：琥珀色 CRT 终端，图个乐。只有一种色相，所以代码像墨水屏那样靠粗细与倾斜区分)
  phosphor = {
    bg = "#14110a",
    fg = "#f7cd70",
    muted = "#deb05a",
    accent = "#ffdc96",
    mark = "#2a2212",
    link = "#e8b850",
    code = { keyword = "#ffdc96", string = "#e8b850", func = "#f7cd70", type = "#ffdc96", number = "#e8b850", comment = "#b48a3c", punct = "#deb05a", mono = true },
  },
}

---Built-in palettes from the lightest page to the darkest, the order the picker
---and `]t` / `[t` walk them in. Palettes from `setup({ palettes = ... })` follow.
---(内置配色，从最亮的页面排到最暗的，选择器与 `]t` / `[t` 按这个顺序走。
--- `setup({ palettes = ... })` 里的配色排在后面)
M.names = { "light", "eink", "eink_soft", "dawn", "solarized", "sepia", "gruvbox", "paper", "jade", "dusk", "night", "dragon", "phosphor" }

---The built-in palette names, kept apart from `M.names`, which also lists the
---palettes registered from the config.
---(内置配色名，与 `M.names` 分开保存——后者还包含从配置注册的配色)
local BUILTIN = vim.deepcopy(M.names)
local BUILTIN_PALETTES = {}
for _, name in ipairs(BUILTIN) do
  BUILTIN_PALETTES[name] = M.palettes[name]
end

---Hues a derived palette borrows its accent and code inks from, before they
---are pulled towards the body ink until readable.
---(推导配色借用的色相：强调色与代码墨色先取这些颜色，再向正文墨色靠拢直到可读)
local HUES = {
  light = { accent = "#a5521f", link = "#2a6496", keyword = "#9b3a1a", string = "#4b6b1f", func = "#2a5f8f", type = "#6f4a8a", number = "#8a5a12" },
  dark = { accent = "#e3ae78", link = "#9cc0dc", keyword = "#e8a07a", string = "#b5c88a", func = "#9cc0dc", type = "#c8a8d8", number = "#e0c080" },
}

---Pull an ink towards the body ink, a step at a time, until `readable` holds.
---(把某个墨色一步步向正文墨色拉近，直到满足 `readable`)
---@param ink string
---@param fg string
---@param readable fun(color: string): boolean
---@return string
local function pull(ink, fg, readable)
  local mix = require("weread.color").mix
  for step = 0, 10 do
    local candidate = mix(ink, fg, step / 10)
    if readable(candidate) then
      return candidate
    end
  end
  return fg
end

---A whole palette from a page and an ink: the quiet ink, the marks, the accent
---and the code inks are derived in Oklab, then held to the same floors the
---built-in palettes keep (APCA Lc 60 for quiet text and titles, WCAG 4.5 for
---code, 3.5 for comments). Anything given explicitly is kept as is.
---(由纸色与墨色推出一整套配色：淡色、标记、强调色与代码墨色在 Oklab 里推导，再守住内置配色守着的
--- 下限（淡色字与标题 APCA Lc 60，代码 WCAG 4.5，注释 3.5）。显式给出的项原样保留)
---@param spec table { bg, fg, ... }
---@return table palette
function M.derive(spec)
  local color = require("weread.color")
  local bg, fg = spec.bg:lower(), spec.fg:lower()
  local dark = color.luminance(bg) < color.luminance(fg)
  local hues = dark and HUES.dark or HUES.light
  local function quiet(c)
    return math.abs(color.apca(c, bg)) >= 60
  end
  local function code_ink(floor)
    return function(c)
      return color.wcag(c, bg) >= floor
    end
  end
  local muted = spec.muted or pull(color.mix(bg, fg, 0.62), fg, quiet)
  local palette = {
    bg = bg,
    fg = fg,
    muted = muted,
    accent = spec.accent or pull(hues.accent, fg, quiet),
    mark = spec.mark or color.mix(bg, fg, 0.09),
    link = spec.link or pull(hues.link, fg, quiet),
    description = type(spec.description) == "string" and spec.description or "自定义配色",
    mine_sp = spec.mine_sp,
    popular_sp = spec.popular_sp,
    mine_style = spec.mine_style,
    popular_style = spec.popular_style,
  }
  local code = type(spec.code) == "table" and vim.deepcopy(spec.code) or {}
  for _, role in ipairs({ "keyword", "string", "func", "type", "number" }) do
    code[role] = code[role] or pull(hues[role], fg, code_ink(4.5))
  end
  code.comment = code.comment or pull(muted, fg, code_ink(3.5))
  code.punct = code.punct or pull(muted, fg, code_ink(4.5))
  palette.code = code
  return palette
end

---Names a custom palette may not take: aliases and the other words
---`:WeReadTheme` reads as commands.
---(自定义配色不能用的名字：别名，以及 `:WeReadTheme` 当作命令的其它词)
local RESERVED = { "plain", "next", "prev", "global" }

---Rule styles `nvim_set_hl` accepts for a highlight's underline.
---(`nvim_set_hl` 接受的下划线线型)
local RULE_STYLES = { "underline", "undercurl", "underdouble", "underdotted", "underdashed" }

---What is wrong with a custom palette spec, or nil.
---(自定义配色有什么问题；没有问题返回 nil)
---@param spec table
---@return string|nil
function M.check_spec(spec)
  local function is_hex(value)
    return type(value) == "string" and value:match("^#%x%x%x%x%x%x$") ~= nil
  end
  for _, field in ipairs({ "bg", "fg", "muted", "accent", "mark", "link", "mine_sp", "popular_sp" }) do
    local value = spec[field]
    if (field == "bg" or field == "fg" or value ~= nil) and not is_hex(value) then
      return field .. " 应为 #rrggbb"
    end
  end
  for _, field in ipairs({ "mine_style", "popular_style" }) do
    if spec[field] ~= nil and not vim.tbl_contains(RULE_STYLES, spec[field]) then
      return field .. " 应为 " .. table.concat(RULE_STYLES, " / ")
    end
  end
  if spec.code ~= nil then
    if type(spec.code) ~= "table" then
      return "code 应为 table"
    end
    for role, ink in pairs(spec.code) do
      if role == "mono" then
        if type(ink) ~= "boolean" then
          return "code.mono 应为 boolean"
        end
      elseif not is_hex(ink) then
        return "code." .. tostring(role) .. " 应为 #rrggbb"
      end
    end
  end
  -- the page itself must be readable: everything else is derived towards the ink
  -- (书页本身必须可读：其余墨色都是朝着正文墨色推导的)
  local body = math.abs(require("weread.color").apca(spec.fg:lower(), spec.bg:lower()))
  if body < 60 then
    return string.format("bg 与 fg 对比度太低（APCA Lc %d，正文至少要 60，建议 75 以上）", math.floor(body + 0.5))
  end
  return nil
end

---A highlight group name for one palette: every palette name maps to its own,
---since names are letters, digits and underscores, and the underscore is spelt
---out rather than dropped (eink_soft and einksoft stay apart).
---(某套配色的高亮组名：每个配色名都有自己的一个——名字只含字母、数字与下划线，下划线被写出来
--- 而不是丢掉（eink_soft 与 einksoft 因此不会撞名）)
---@param prefix string
---@param name string
---@return string
function M.group_name(prefix, name)
  return prefix .. name:gsub("_", "U"):gsub("^%l", string.upper)
end

---Register the palettes from `setup({ palettes = ... })`, replacing the ones a
---previous setup registered. Bad entries are reported and skipped.
---(注册 `setup({ palettes = ... })` 里的配色，替换上一次 setup 注册的。有问题的条目提示后跳过)
---@param given table|nil
---@return string[] registered names(注册成功的名字)
function M.register(given)
  for name in pairs(M.palettes) do
    if not BUILTIN_PALETTES[name] then
      M.palettes[name] = nil
    end
  end
  M.names = vim.deepcopy(BUILTIN)
  local registered = {}
  if type(given) ~= "table" then
    return registered
  end
  local keys = vim.tbl_keys(given)
  table.sort(keys, function(a, b)
    return tostring(a) < tostring(b)
  end)
  for _, key in ipairs(keys) do
    local spec = given[key]
    local name = type(key) == "string" and key:lower() or ""
    local problem = nil
    if not name:match("^[%a][%w_]*$") then
      problem = "名字只能由字母、数字、下划线组成"
    elseif BUILTIN_PALETTES[name] or vim.tbl_contains(M.special, name) or vim.tbl_contains(RESERVED, name) then
      problem = "与内置主题或命令参数重名"
    elseif M.palettes[name] then
      problem = "与另一个自定义配色重名（名字不分大小写）"
    elseif type(spec) ~= "table" then
      problem = "应为 table"
    else
      problem = M.check_spec(spec)
    end
    if problem then
      vim.notify(string.format("weread: 配色 palettes.%s 已忽略：%s", tostring(key), problem), vim.log.levels.WARN)
    else
      M.palettes[name] = M.derive(spec)
      M.names[#M.names + 1] = name
      registered[#registered + 1] = name
    end
  end
  return registered
end

---Pseudo themes accepted besides the palettes: "none" keeps the colorscheme,
---"auto" picks a light or a dark palette from 'background'.
---(配色之外接受的两个伪主题："none" 沿用配色方案，"auto" 按 'background' 选浅色或深色配色)
M.special = { "auto", "none" }

---Palette "auto" stands for right now.
---(此刻 "auto" 代表哪套配色)
---@return string
function M.resolve_auto()
  local auto = require("weread.config").get().theme_auto or {}
  local dark = vim.o.background == "dark"
  local wanted = dark and (auto.dark or "night") or (auto.light or "paper")
  wanted = type(wanted) == "string" and wanted:lower() or ""
  if M.palettes[wanted] then
    return wanted
  end
  return dark and "night" or "paper"
end

---Whether a name is something the user may choose: a palette, an alias, or a
---pseudo theme. Lets `:WeReadTheme` refuse a typo instead of remembering it.
---(某个名字是否可选：配色、别名或伪主题。让 `:WeReadTheme` 拒绝拼错的名字，而不是把它记住)
---@param name any
---@return boolean
function M.known(name)
  if type(name) ~= "string" then
    return false
  end
  local lowered = name:lower()
  return M.palettes[lowered] ~= nil or lowered == "plain" or vim.tbl_contains(M.special, lowered)
end

---@param name string|nil
---@return string
function M.normalize(name)
  if type(name) ~= "string" then
    return "none"
  end
  local lowered = name:lower()
  if lowered == "plain" or lowered == "none" then
    return "none"
  end
  if lowered == "auto" then
    return M.resolve_auto()
  end
  if M.palettes[lowered] then
    return lowered
  end
  return "none"
end

---The heading groups drawn on heading lines by weread.inline, plus the page
---furniture that has no markdown counterpart: the footer and footnote marks.
---(由 weread.inline 画在标题行上的标题组，以及 markdown 里没有对应物的页面元素：页脚与
--- 脚注标记)
---
---`WereadHeading` stays for compatibility; the levelled groups are what the page
---uses: a chapter title and a section title in the accent colour, everything
---deeper in plain bold ink.
---(`WereadHeading` 为兼容保留；页面实际使用分级的组：章标题与节标题用强调色，更深的层级
--- 用普通墨色加粗)
---@param name string
---@param override table|nil a palette to use instead of the named one(用来代替该名字配色的调色板)
function M.define_heading(name, override)
  local set = vim.api.nvim_set_hl
  if name == "none" then
    -- No palette: stay close to the colorscheme, minus any background.
    -- (不套配色：贴近配色方案，但去掉背景)
    local title = vim.api.nvim_get_hl(0, { name = "Title" })
    set(0, "WereadHeading", { fg = title.fg, bold = true })
    set(0, "WereadHeading1", { fg = title.fg, bold = true })
    set(0, "WereadHeading2", { fg = title.fg, bold = true })
    set(0, "WereadHeading3", { bold = true })
    set(0, "WereadFooter", { link = "Comment" })
    set(0, "WereadFootnote", { link = "Comment" })
    set(0, "WereadCursor", { link = "Cursor" })
    -- Tables and the page margin are drawn with these by name, not through
    -- `winhighlight`, so a palette shown earlier left its paper background on
    -- every table border.
    -- (表格与页边距直接按名字使用这几个组，而不是经过 `winhighlight`，于是之前显示过的配色
    --  会把它的纸色底留在每一条表格边框上)
    set(0, "WereadPaperTableHead", { link = "RenderMarkdownTableHead" })
    set(0, "WereadPaperTableRow", { link = "RenderMarkdownTableRow" })
    set(0, "WereadPaperMargin", { link = "Normal" })
    set(0, "WereadPaperAccent", { link = "Title" })
    -- groups that the plant, the cards and the popups link to (植物、卡片与弹窗链接到的组)
    set(0, "WereadPaperWinBar", { link = "WinBar" })
    set(0, "WereadPaperFloat", { link = "NormalFloat" })
    set(0, "WereadPaperFloatBorder", { link = "FloatBorder" })
    set(0, "WereadPaperFloatTitle", { link = "FloatTitle" })
    set(0, "WereadPaperFloatMuted", { link = "Comment" })
    set(0, "WereadPaperFloatAccent", { link = "Title" })
    set(0, "WereadPaperFloatLine", { link = "CursorLine" })
    set(0, "WereadPaperBarDone", { link = "Title" })
    set(0, "WereadPaperBarTodo", { link = "NonText" })
    set(0, "WereadPaperBarTick", { link = "Comment" })
    -- Inline emphasis goes back to the built-ins too: a paper palette painted
    -- these in its ink and background, and switching to "none" left them there.
    -- (行内强调同样还给内置组：纸色配色用自己的墨色与底色刷过它们，切到 "none" 时它们
    --  一直留着纸色)
    M.define_emphasis_none()
    return
  end
  local palette = override or M.palettes[name]
  if palette then
    set(0, "WereadHeading", { fg = palette.fg, bg = palette.bg, bold = true })
    set(0, "WereadHeading1", { fg = palette.accent, bg = palette.bg, bold = true })
    set(0, "WereadHeading2", { fg = palette.accent, bg = palette.bg, bold = true })
    set(0, "WereadHeading3", { fg = palette.fg, bg = palette.bg, bold = true })
    -- page number and progress under the text: present, but quieter than it
    -- (正文下方的页码与进度：在那儿，但比正文安静)
    set(0, "WereadFooter", { fg = palette.muted, bg = palette.bg })
    set(0, "WereadFootnote", { fg = palette.muted, bg = palette.bg, italic = false })
  end
end

---Built-in groups the inline emphasis falls back to without a palette, with the
---attribute to use when a colorscheme left the built-in empty (`:colorscheme`
---clears `Bold`, `Italic` and `Strikethrough`, and a link to an empty group draws
---plain text).
---(没有配色时行内强调回落到的内置组，以及配色方案把内置组留空时改用的属性（`:colorscheme`
--- 会清空 `Bold`、`Italic` 与 `Strikethrough`，链到空组就只剩普通文字）)
local EMPHASIS_NONE = {
  { group = "WereadStrong", link = "Bold", attr = "bold" },
  { group = "WereadItalic", link = "Italic", attr = "italic" },
  { group = "WereadUnderline", link = "Underlined", attr = "underline" },
  { group = "WereadStrike", link = "Strikethrough", attr = "strikethrough" },
}

---Point the inline emphasis groups back at the colorscheme.
---(把行内强调组重新指回配色方案)
function M.define_emphasis_none()
  for _, spec in ipairs(EMPHASIS_NONE) do
    local ok, target = pcall(vim.api.nvim_get_hl, 0, { name = spec.link, link = false })
    if ok and type(target) == "table" and target[spec.attr] then
      vim.api.nvim_set_hl(0, spec.group, { link = spec.link })
    else
      vim.api.nvim_set_hl(0, spec.group, { [spec.attr] = true })
    end
  end
end

---Define the highlight groups a palette needs. Idempotent, so switching themes
---at runtime just rewrites them.
---(定义一套配色所需的高亮组。幂等，运行时切换主题就是重写它们)
---@param name string
---@param override table|nil a palette to use instead of the named one: a frame of the switch fade(用来代替该名字配色的调色板：切换渐变中的一帧)
function M.define(name, override)
  local palette = override or M.palettes[name]
  if not palette then
    return
  end
  local set = vim.api.nvim_set_hl
  local color = require("weread.color")
  ---A faint wash of `to` over the page: `t` of the way in Oklab, but never a
  ---step the eye cannot see — on a near black page 5% of the way still rounds
  ---to black, so the step grows until it is visible (WCAG 1.1 against the page).
  ---(在纸页上叠一层很淡的 `to`：在 Oklab 里走 t 那么远，但绝不是肉眼看不出的一步——近黑的页面上
  --- 走 5% 取整后仍是黑的，所以这一步会加大到看得出为止（与纸色的 WCAG 对比度 1.1）)
  local function mix(from, to, t)
    local candidate = color.mix(from, to, t)
    while t < 0.5 and color.wcag(candidate, from) < 1.1 do
      t = t + 0.02
      candidate = color.mix(from, to, t)
    end
    return candidate
  end
  set(0, "WereadPaperNormal", { fg = palette.fg, bg = palette.bg })
  set(0, "WereadPaperWinBar", { fg = palette.muted, bg = palette.bg, bold = false })
  -- The cursor line is a faint wash of the ink, not the `<mark>` colour: with
  -- both the same, a marked passage under the cursor vanished into the line.
  -- (光标行是一层很淡的墨色，而不是 `<mark>` 的颜色：两者相同时，光标下被标记的段落就和
  --  光标行混在一起)
  set(0, "WereadPaperCursorLine", { bg = mix(palette.bg, palette.fg, 0.05) })
  -- the reading cursor: paper-coloured text on an accent block
  -- (阅读光标：强调色方块上的纸色文字)
  set(0, "WereadCursor", { fg = palette.bg, bg = palette.accent })
  set(0, "WereadPaperMark", { fg = palette.fg, bg = palette.mark })
  set(0, "WereadPaperLink", { fg = palette.link, underline = true })
  -- Inline code in the code ink, without the link's rule: it used to borrow the
  -- link group and read as a hyperlink (on e-ink it was the same as `<u>`).
  -- (行内代码用代码墨色，不带链接的下划线：它原来借用链接组，读起来像超链接——在墨水屏上与
  --  `<u>` 完全一样)
  set(0, "WereadPaperInlineCode", { fg = (palette.code or {}).func or palette.link, bg = mix(palette.bg, palette.fg, 0.04) })
  -- Quotes stay in body ink: terminal syntax themes often use a pale red here,
  -- which loses contrast against paper.
  -- (引文保持正文墨色：终端语法主题常把这里设成淡红色，在纸色背景上对比度不足)
  set(0, "WereadPaperQuote", { fg = palette.fg, bg = palette.bg, italic = true })
  -- Editor groups that would otherwise keep the colorscheme's colours on the
  -- page: a dark colorscheme's selection or search colour laid on paper can
  -- hide the text under it.
  -- (否则会在书页上保留配色方案颜色的编辑器组：深色配色方案的选区或搜索色叠在纸页上，
  --  可能把下面的字盖住)
  set(0, "WereadPaperVisual", { bg = mix(palette.bg, palette.fg, 0.16) })
  set(0, "WereadPaperSearch", { fg = palette.fg, bg = mix(palette.bg, palette.accent, 0.28) })
  set(0, "WereadPaperCurSearch", { fg = palette.bg, bg = palette.accent, bold = true })
  set(0, "WereadPaperMatchParen", { fg = palette.accent, bold = true })
  set(0, "WereadPaperNonText", { fg = mix(palette.bg, palette.fg, 0.35), bg = palette.bg })
  set(0, "WereadPaperStatusLine", { fg = palette.muted, bg = palette.bg })
  -- marks drawn on the page in the accent: the bookmark sign
  -- (用强调色画在书页上的标记：书签符号)
  set(0, "WereadPaperAccent", { fg = palette.accent, bg = palette.bg })
  -- The folio's progress bar: the read part in the accent, the rest a faint
  -- rule, chapter ticks in the quiet ink.
  -- (页脚进度条：读过的部分用强调色，其余是一道淡线，章节刻度用淡墨)
  set(0, "WereadPaperBarDone", { fg = palette.accent, bg = palette.bg })
  set(0, "WereadPaperBarTodo", { fg = mix(palette.bg, palette.fg, 0.22), bg = palette.bg })
  set(0, "WereadPaperBarTick", { fg = palette.muted, bg = palette.bg })
  set(0, "WereadPaperStrike", { fg = palette.muted, strikethrough = true })
  set(0, "WereadPaperSuperscript", { fg = palette.muted })
  -- Inline emphasis, drawn with the palette's own ink: the built-in `Bold` and
  -- `Italic` groups carry no colour, so a colorscheme's syntax colours would show
  -- through them.
  -- (行内强调用配色自己的墨色绘制：内置的 `Bold`/`Italic` 没有颜色，配色方案的语法颜色会从
  --  它们下面透出来)
  set(0, "WereadStrong", { fg = palette.fg, bg = palette.bg, bold = true })
  set(0, "WereadItalic", { fg = palette.fg, bg = palette.bg, italic = true })
  set(0, "WereadUnderline", { fg = palette.fg, bg = palette.bg, underline = true })
  set(0, "WereadStrike", { fg = palette.muted, bg = palette.bg, strikethrough = true })
  -- Highlights: the rule carries the colour of what is marked, so the text
  -- itself stays ink. My highlights get the accent, popular ones a muted curl —
  -- or, on a monochrome palette, two different rule shapes.
  -- (划线：颜色由下划线承载，文字本身仍是墨色。我的划线用强调色，热门划线用淡色波浪线——
  --  单色配色下则改用两种线型)
  local mine = { fg = palette.fg, sp = palette.mine_sp or palette.accent }
  mine[palette.mine_style or "underline"] = true
  local popular = { fg = palette.fg, sp = palette.popular_sp or palette.muted }
  popular[palette.popular_style or "undercurl"] = true
  set(0, "WereadPaperMineHighlight", mine)
  set(0, "WereadPaperPopularHighlight", popular)
  -- Hotter popular highlights: the same curl in the accent, then a solid accent
  -- rule — a passage half the readers marked should not look like one only a
  -- few did. A monochrome palette keeps its shapes and lets the weight speak.
  -- (更热的热门划线：先是强调色的波浪线，再是强调色实线——一半读者都划过的段落，不该和
  --  只有几个人划过的看起来一样。单色配色保留线型，只靠粗细区分)
  local warm = { fg = palette.fg, sp = palette.popular_sp or palette.accent }
  warm[palette.popular_style or "undercurl"] = true
  local hot = { fg = palette.fg, sp = palette.popular_sp or palette.accent, bold = true }
  hot[palette.popular_style or "underline"] = true
  set(0, "WereadPaperEmphasisDots", { underdotted = true, sp = palette.accent })
  set(0, "WereadPaperPopularWarm", warm)
  set(0, "WereadPaperPopularHot", hot)
  -- Small print (footnotes, figure captions) is inset in the text and dimmed
  -- here: a terminal cannot shrink a glyph.
  -- (小字（脚注、图注）在正文里靠内缩，在这里靠淡色表达：终端改不了字形大小)
  set(0, "WereadPaperSmall", { fg = palette.muted })
  -- The translation under a paragraph: the muted ink, but not inset, so it reads
  -- as the paragraph's other half rather than as a footnote.
  -- (段落下方的译文：淡墨，但不内缩——读起来是这段的另一半，而不是脚注)
  set(0, "WereadPaperTranslation", { fg = palette.muted })
  -- A pipe table: the rules between cells use the muted ink of the palette, the
  -- text inside them keeps whatever highlight it already had.
  -- (管道表格：格与格之间的线用配色的淡墨，格里的文字保留它原本的高亮)
  set(0, "WereadPaperTableHead", { fg = palette.muted, bg = palette.bg })
  set(0, "WereadPaperTableRow", { fg = palette.muted, bg = palette.bg })
  -- Tables the page lays out itself: the header in bold ink, the rules a quiet
  -- line that frames the cells without competing with them.
  -- (书页自己排的表格：表头是加粗的墨色，边框是一道安静的线，框住单元格又不和它们抢)
  set(0, "WereadPaperTableHeadText", { fg = palette.fg, bg = palette.bg, bold = true })
  set(0, "WereadPaperTableRule", { fg = mix(palette.bg, palette.fg, 0.38), bg = palette.bg })
  -- Padding that centers or right aligns a line: it must be the page colour, so
  -- it reads as empty paper rather than as text.
  -- (用于居中/右对齐的补白：必须是纸色，看上去是空纸而不是文字)
  set(0, "WereadPaperMargin", { fg = palette.fg, bg = palette.bg })

  -- Markdown decorations must not punch a coloured hole in the page. These are
  -- what other plugins paint their own headings, fences and tables with, and
  -- they all get the page background back.
  -- (markdown 装饰不能在纸页上打出彩色空洞。其它插件用它画标题、代码块、表格，
  --  这里统一把背景换回纸色)
  set(0, "WereadPaperHeading", { fg = palette.fg, bg = palette.bg, bold = true })
  set(0, "WereadPaperMuted", { fg = palette.muted, bg = palette.bg })
  set(0, "WereadPaperCode", { fg = palette.muted, bg = palette.bg })
  set(0, "WereadPaperLinkBg", { fg = palette.link, bg = palette.bg, underline = true })
  set(0, "WereadPaperStrong", { fg = palette.fg, bg = palette.bg, bold = true })
  set(0, "WereadPaperItalic", { fg = palette.fg, bg = palette.bg, italic = true })
  -- Code listings: the colorscheme's syntax colours are tuned for its own
  -- background and wash out on paper (measured 1.2:1 on the paper page), so
  -- every capture inside a listing is repainted in the palette's syntax inks.
  -- (代码清单：配色方案的语法颜色是按它自己的背景调的，放到纸页上就褪了色——在 paper 页面上
  --  实测只有 1.2:1——因此清单里的每一种捕获都改用配色自己的语法墨色)
  local code = palette.code or {}
  local mono = code.mono == true
  set(0, "WereadPaperSynKeyword", { fg = code.keyword or palette.accent, bg = palette.bg, bold = mono })
  set(0, "WereadPaperSynString", { fg = code.string or palette.fg, bg = palette.bg })
  set(0, "WereadPaperSynFunction", { fg = code.func or palette.fg, bg = palette.bg, bold = mono })
  set(0, "WereadPaperSynType", { fg = code.type or palette.fg, bg = palette.bg, italic = mono })
  set(0, "WereadPaperSynNumber", { fg = code.number or palette.fg, bg = palette.bg })
  set(0, "WereadPaperSynComment", { fg = code.comment or palette.muted, bg = palette.bg, italic = true })
  set(0, "WereadPaperSynPunct", { fg = code.punct or palette.muted, bg = palette.bg })
  set(0, "WereadPaperSynText", { fg = palette.fg, bg = palette.bg })
  -- Popups over the page (stats, contents, thoughts, the dictionary) in the
  -- page's colours: a slightly deeper sheet laid on it, edged in the quiet ink.
  -- (书页上的弹窗（统计、目录、想法、词典）用书页的颜色：一张略深的纸叠在上面，边框用淡墨)
  local sheet = mix(palette.bg, palette.fg, 0.035)
  set(0, "WereadPaperFloat", { fg = palette.fg, bg = sheet })
  set(0, "WereadPaperFloatBorder", { fg = mix(palette.bg, palette.fg, 0.4), bg = sheet })
  set(0, "WereadPaperFloatTitle", { fg = palette.accent, bg = sheet, bold = true })
  set(0, "WereadPaperFloatMuted", { fg = palette.muted, bg = sheet })
  set(0, "WereadPaperFloatAccent", { fg = palette.accent, bg = sheet })
  set(0, "WereadPaperFloatLine", { bg = mix(palette.bg, palette.fg, 0.1) })
  M.define_heading(name, palette)
end

---Groups that colour markdown syntax, from either a renderer plugin or the
---treesitter queries themselves.
---(给 markdown 语法上色的高亮组，可能来自渲染插件，也可能来自 treesitter 查询本身)
---
---Both matter: the visible band behind a heading came from the *colorscheme's*
---`@markup.heading.1.markdown` (which ships a background), and render-markdown
---adds its own `RenderMarkdownH*Bg` on top.
---(两者都要管：标题行那条色带来自**配色方案**的 `@markup.heading.1.markdown`
---（自带背景色），render-markdown 又在上面叠了自己的 `RenderMarkdownH*Bg`)
-- patterns are matched against the lowercased group name, so they are lowercase
-- (模式针对小写化的组名匹配，因此这里全部小写)
local SUBSTITUTIONS = {
  { match = "^@markup%.heading", group = "WereadPaperHeading" },
  { match = "^rendermarkdownh%d", group = "WereadPaperHeading" },
  { match = "tablehead", group = "WereadPaperTableHead" },
  { match = "tablerow", group = "WereadPaperTableRow" },
  { match = "heading", group = "WereadPaperHeading" },
  { match = "strong", group = "WereadPaperStrong" },
  { match = "bold", group = "WereadPaperStrong" },
  { match = "italic", group = "WereadPaperItalic" },
  { match = "strikethrough", group = "WereadPaperStrike" },
  { match = "quote", group = "WereadPaperQuote" },
  { match = "raw", group = "WereadPaperCode" },
  { match = "literal", group = "WereadPaperCode" },
  { match = "string", group = "WereadPaperCode" },
  { match = "number", group = "WereadPaperCode" },
  { match = "title", group = "WereadPaperHeading" },
  { match = "uri", group = "WereadPaperLinkBg" },
  { match = "^rendermarkdowncode", group = "WereadPaperCode" },
  { match = "link", group = "WereadPaperLinkBg" },
  { match = "list", group = "WereadPaperMuted" },
}

---Highlight groups that other markdown renderers define for themselves.
---(其它 markdown 渲染器自定义的高亮组)
---Enumerated at apply time rather than hardcoded: the set grows with plugin
---releases (`H1`..`H7`, `Bg` variants, `Code*`, `Quote1..8`, ...).
---(在应用时枚举而不是写死：这套组会随插件版本增长（H1..H7、Bg 变体、Code*、
--- Quote1..8……）)
---@return string[]
function M.foreign_groups()
  local groups = {}
  local ok, all = pcall(vim.api.nvim_get_hl, 0, {})
  if not ok or type(all) ~= "table" then
    return groups
  end
  for name in pairs(all) do
    -- `@markup.*.markdown` is the markdown tree's own family, but a file also
    -- carries generic captures (`@text.strong`, `@text.italic`, `@text.literal`)
    -- that a colorscheme paints in its own colours — a bold sentence came out
    -- blue on a black and white page because of exactly that.
    -- (`@markup.*.markdown` 是 markdown 语法树自己的家族，但文件里还有通用捕获
    --  （`@text.strong`、`@text.italic`、`@text.literal`），配色方案会给它们上自己的颜色——
    --  加粗的句子在黑白页面上显出蓝色，就是这么来的)
    if name:find("^RenderMarkdown") or name:find("^@markup%.") or name:find("^@text%.") then
      groups[#groups + 1] = name
    elseif name:find("^@") and M.syntax_substitute(name) then
      -- generic code captures (`@function.call`, `@keyword`...): a listing in
      -- a chapter is highlighted by the injected language's tree with these
      -- (通用代码捕获：章节里的代码清单由注入语言的语法树用它们高亮)
      groups[#groups + 1] = name
    end
  end
  table.sort(groups)
  return groups
end

---Code capture families and the syntax ink each takes, most specific first.
---(代码捕获家族与各自使用的语法墨色，越具体的越靠前)
local SYNTAX = {
  { match = "^@comment", group = "WereadPaperSynComment" },
  { match = "^@string", group = "WereadPaperSynString" },
  { match = "^@character", group = "WereadPaperSynString" },
  { match = "^@number", group = "WereadPaperSynNumber" },
  { match = "^@boolean", group = "WereadPaperSynNumber" },
  { match = "^@constant", group = "WereadPaperSynNumber" },
  { match = "^@keyword", group = "WereadPaperSynKeyword" },
  { match = "^@conditional", group = "WereadPaperSynKeyword" },
  { match = "^@repeat", group = "WereadPaperSynKeyword" },
  { match = "^@include", group = "WereadPaperSynKeyword" },
  { match = "^@exception", group = "WereadPaperSynKeyword" },
  { match = "^@operator", group = "WereadPaperSynPunct" },
  { match = "^@punctuation", group = "WereadPaperSynPunct" },
  { match = "^@function", group = "WereadPaperSynFunction" },
  { match = "^@method", group = "WereadPaperSynFunction" },
  { match = "^@constructor", group = "WereadPaperSynType" },
  { match = "^@type", group = "WereadPaperSynType" },
  { match = "^@attribute", group = "WereadPaperSynType" },
  { match = "^@tag", group = "WereadPaperSynKeyword" },
  { match = "^@module", group = "WereadPaperSynType" },
  { match = "^@namespace", group = "WereadPaperSynType" },
  { match = "^@label", group = "WereadPaperSynComment" },
  { match = "^@property", group = "WereadPaperSynFunction" },
  { match = "^@field", group = "WereadPaperSynFunction" },
  { match = "^@parameter", group = "WereadPaperSynText" },
  { match = "^@variable", group = "WereadPaperSynText" },
  { match = "^@none", group = "WereadPaperSynText" },
  { match = "^@diff%.plus", group = "WereadPaperSynString" },
  { match = "^@diff%.minus", group = "WereadPaperSynKeyword" },
  { match = "^@diff", group = "WereadPaperSynPunct" },
}

---Syntax ink for a generic code capture, or nil when it is not one.
---(某个通用代码捕获对应的语法墨色；不是代码捕获时为 nil)
---@param group string
---@return string|nil
function M.syntax_substitute(group)
  for _, rule in ipairs(SYNTAX) do
    if group:find(rule.match) then
      return rule.group
    end
  end
  return nil
end

---Which paper group should stand in for a foreign one.
---(某个外部组应当换成哪个纸色组)
---@param group string
---@return string
function M.substitute(group)
  -- a table's pipes are drawn with the markdown tree's punctuation capture
  -- (表格的竖线用 markdown 语法树的标点捕获绘制)
  if group:find("^@punctuation%.special%.markdown") or group:find("^@punctuation%.delimiter%.markdown") then
    return "WereadPaperTableRow"
  end
  if not group:find("^RenderMarkdown") and not group:find("^@markup%.") and not group:find("^@text%.") then
    local syntax = M.syntax_substitute(group)
    if syntax then
      return syntax
    end
  end
  local lowered = group:lower()
  for _, rule in ipairs(SUBSTITUTIONS) do
    if lowered:find(rule.match) then
      return rule.group
    end
  end
  if lowered:find("info") or lowered:find("hint") or lowered:find("success") then
    return "WereadPaperLinkBg"
  end
  return "WereadPaperMuted"
end

---`winhighlight` value that repaints a window in the given palette.
---(把某个窗口刷成指定配色的 winhighlight 值)
---@param name string
---@return string
function M.winhighlight(name)
  if name == "none" then
    -- no window mapping, but the page's own groups must still exist
    -- (不做窗口映射，但页面自己用的组仍然必须存在)
    M.define_heading("none")
    return ""
  end
  M.define(name)

  local pairs_list = {
    "Normal:WereadPaperNormal",
    -- a colorscheme's dimmed NormalNC would turn the page back to the editor
    -- background the moment a picker or float takes the focus
    -- (配色方案变暗的 NormalNC 会在选择器或浮窗拿走焦点时，把书页变回编辑器底色)
    "NormalNC:WereadPaperNormal",
    "EndOfBuffer:WereadPaperNormal",
    "WinBar:WereadPaperWinBar",
    "WinBarNC:WereadPaperWinBar",
    "CursorLine:WereadPaperCursorLine",
    "Visual:WereadPaperVisual",
    "Search:WereadPaperSearch",
    "IncSearch:WereadPaperCurSearch",
    "CurSearch:WereadPaperCurSearch",
    "MatchParen:WereadPaperMatchParen",
    "NonText:WereadPaperNonText",
    "WereadMark:WereadPaperMark",
    "WereadTableHead:WereadPaperTableHeadText",
    "WereadTableRule:WereadPaperTableRule",
    "WereadBookmark:WereadPaperAccent",
    "WereadCode:WereadPaperInlineCode",
    "WereadSuperscript:WereadPaperSuperscript",
    "WereadSubscript:WereadPaperSuperscript",
    "WereadSmall:WereadPaperSmall",
    "WereadTranslation:WereadPaperTranslation",
    "WereadStrong:WereadStrong",
    "WereadItalic:WereadItalic",
    "WereadUnderline:WereadUnderline",
    "WereadStrike:WereadStrike",
    "WereadMargin:WereadPaperMargin",
    "WereadMineHighlight:WereadPaperMineHighlight",
    "WereadPopularHighlight:WereadPaperPopularHighlight",
    "WereadPopularWarm:WereadPaperPopularWarm",
    "WereadEmphasisDots:WereadPaperEmphasisDots",
    "WereadPopularHot:WereadPaperPopularHot",
    -- `@markup.quote` paints the quotation text itself. It can be created only
    -- when the Markdown parser attaches, after this window receives its theme.
    -- (实际引用正文由 `@markup.quote` 绘制。它可能直到 Markdown 解析器附着时才创建，晚于窗口套主题)
    "@markup.quote:WereadPaperQuote",
    "Strikethrough:WereadPaperStrike",
  }

  -- The chapter's own statusline takes the page colours; with "keep" the
  -- statusline is the editor's (often one global line), so it is left alone.
  -- (章节自己的状态栏用书页颜色；"keep" 时状态栏是编辑器的（常常是一条全局的），不去动它)
  if (require("weread.config").get().layout or {}).statusline == "window" then
    pairs_list[#pairs_list + 1] = "StatusLine:WereadPaperStatusLine"
    pairs_list[#pairs_list + 1] = "StatusLineNC:WereadPaperStatusLine"
  end

  -- Third party markdown decorations: same page background, palette foreground.
  -- (第三方 markdown 装饰：同样的纸色底，前景取自配色)
  for _, group in ipairs(M.foreign_groups()) do
    pairs_list[#pairs_list + 1] = group .. ":" .. M.substitute(group)
  end

  return table.concat(pairs_list, ",")
end

---Editor groups a popup over the page uses (through the plugin's own groups,
---which link to them), and the page group each becomes.
---(书页上的弹窗用到的编辑器组（经由插件自己链接到它们的组），以及各自换成的书页组)
local FLOAT_GROUPS = {
  { "Normal", "WereadPaperFloat" },
  { "NormalFloat", "WereadPaperFloat" },
  { "FloatBorder", "WereadPaperFloatBorder" },
  { "FloatTitle", "WereadPaperFloatTitle" },
  { "FloatFooter", "WereadPaperFloatMuted" },
  { "EndOfBuffer", "WereadPaperFloat" },
  { "Comment", "WereadPaperFloatMuted" },
  { "NonText", "WereadPaperFloatMuted" },
  { "Title", "WereadPaperFloatTitle" },
  { "Function", "WereadPaperFloatAccent" },
  { "Special", "WereadPaperFloatAccent" },
  { "String", "WereadPaperFloat" },
  { "Number", "WereadPaperFloatAccent" },
  { "DiagnosticOk", "WereadPaperFloatAccent" },
  { "DiagnosticInfo", "WereadPaperFloatAccent" },
  { "DiagnosticHint", "WereadPaperFloatMuted" },
  { "DiagnosticWarn", "WereadPaperFloatAccent" },
  { "CursorLine", "WereadPaperFloatLine" },
  { "Visual", "WereadPaperVisual" },
}

---`winhighlight` for a popup opened over a chapter, so it reads as a sheet of
---the same paper rather than a window of the editor; "" when no palette is on
---or the popup is not over a chapter.
---(章节上方弹窗的 winhighlight，让它看起来是同一种纸的一张，而不是编辑器的窗口；没开配色或弹窗
--- 不在章节上方时返回 "")
---@param over integer|nil the window it opens over, the current one by default(它所覆盖的窗口，默认当前窗口)
---@return string
function M.float_winhighlight(over)
  local name = M.current()
  if not M.palettes[name] then
    return ""
  end
  over = over or vim.api.nvim_get_current_win()
  if not vim.api.nvim_win_is_valid(over) then
    return ""
  end
  local ok, info = pcall(require("weread.reader").buffer_info, vim.api.nvim_win_get_buf(over))
  if not ok or not info then
    return ""
  end
  local parts = {}
  for _, pair in ipairs(FLOAT_GROUPS) do
    parts[#parts + 1] = pair[1] .. ":" .. pair[2]
  end
  return table.concat(parts, ",")
end

---Group a chapter's winbar should be painted with, or "" when no palette is
---active — then the colorscheme's own WinBar decides.
---(章节 winbar 使用的高亮组；没有启用配色时返回 ""，交给配色方案自己的 WinBar)
---@return string
function M.winbar_highlight()
  if M.current() == "none" then
    return ""
  end
  return "WereadPaperWinBar"
end

---A theme shown for a moment without being chosen (the picker moving through
---the list); nil when none is being tried.
---(只是暂时显示、并未选定的主题（选择器在列表里移动时）；没有在试时为 nil)
local trial = nil

---The open book's id, or nil.
---(当前打开的书的 id，没有则为 nil)
---@return string|nil
local function open_book()
  local reader = package.loaded["weread.reader"]
  local book = reader and reader.state and reader.state.book or nil
  if not (book and book.book_id) then
    return nil
  end
  -- `state.book` outlives a closed book: it counts as open only while one of
  -- its chapters is still loaded
  -- (`state.book` 在书关掉之后仍然留着：只有它还有章节 buffer 在时才算打开)
  local id = tostring(book.book_id)
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    local info = vim.api.nvim_buf_is_loaded(buf) and reader.buffer_info(buf) or nil
    if info and tostring(info.book_id) == id then
      return id
    end
  end
  return nil
end

---Themes chosen for one book only, by book id (`:WeReadTheme!`).
---(只给某一本书选的主题，按书 id 存（`:WeReadTheme!`）)
---@return table<string, string>
local function book_themes()
  local stored = require("weread.prefs").get("book_themes")
  return type(stored) == "table" and stored or {}
end

---The theme a book was given of its own, if any.
---(某本书单独选定的主题，没有则为 nil)
---@param book_id string|nil defaults to the open book(默认是当前打开的书)
---@return string|nil
function M.book_choice(book_id)
  book_id = book_id or open_book()
  if not book_id then
    return nil
  end
  local choice = book_themes()[tostring(book_id)]
  return M.known(choice) and choice or nil
end

---The choice in force before it is resolved: what is being tried, else the
---open book's own theme, else the global one ("auto", "none" or a palette).
---(解析之前正在生效的选择：在试的那个，否则是当前这本书自己的主题，否则是全局主题
--- （"auto"、"none" 或某套配色）)
---@return string
function M.choice()
  if trial then
    return trial
  end
  local choice = M.book_choice() or require("weread.config").get().theme
  return type(choice) == "string" and choice:lower() or "none"
end

---Current theme name: the palette on the page now, or "none".
---(当前主题名：书页上此刻用的配色，或 "none")
---@return string
function M.current()
  return M.normalize(M.choice())
end

---Define every highlight group of the current theme again.
---(为当前主题重新定义全部高亮组)
---
---`:colorscheme` runs `:highlight clear`, which wipes every group this module
---set — the palette groups the reading windows' `winhighlight` points at among
---them — and nothing would put them back. Call it from a `ColorScheme` autocmd.
---(`:colorscheme` 会执行 `:highlight clear`，清掉本模块设置过的每个组——其中包括阅读窗口
--- winhighlight 指向的配色组——而没有任何东西会把它们补回来。在 `ColorScheme` 自动命令里调用)
---@param name string|nil defaults to the configured theme(默认取配置的主题)
function M.redefine(name)
  name = M.normalize(name or M.current())
  -- The plugin's own base groups go first, the cursor-hiding one among them: once
  -- `:highlight clear` wipes its blend, the cursor shows up again in the middle
  -- of the page. Errors are swallowed, a missing module must not cost the palette.
  -- (先补回插件自己的基础组，其中包括隐藏光标的那个：`:highlight clear` 抹掉它的 blend 后，
  --  光标就又出现在页面中间。错误吞掉，缺了某个模块也不能连累配色)
  pcall(function()
    require("weread.shell").define_highlights()
  end)
  pcall(function()
    require("weread").define_highlights()
  end)
  if name == "none" then
    M.define_heading("none")
    return
  end
  -- a palette that was never shown still gets defined: the groups are cheap and
  -- a window may be switched to it at any time
  -- (从未显示过的配色同样定义：组很便宜，而窗口随时可能切到它)
  M.define(name)
end

---Apply a theme to a reading window.
---(把主题应用到阅读窗口)
---@param win integer
---@param name string|nil
function M.apply(win, name)
  if not vim.api.nvim_win_is_valid(win) then
    return
  end
  name = M.normalize(name or M.current())
  vim.api.nvim_set_option_value("winhighlight", M.winhighlight(name), { scope = "local", win = win })
end

---Apply to every open chapter window, e.g. after switching themes.
---(应用到所有已打开的章节窗口，例如切换主题之后)
---@param name string|nil
function M.apply_all(name)
  local reader = require("weread.reader")
  for _, win in ipairs(vim.api.nvim_list_wins()) do
    local buf = vim.api.nvim_win_get_buf(win)
    if reader.buffer_info(buf) then
      M.apply(win, name)
      -- the winbar and the reading statusline name a palette group, so they are
      -- repainted too — including the switch to "none", which drops it
      -- (winbar 与阅读状态栏引用了配色里的组，因此一起重画——包括切到 "none" 时把
      --  它去掉)
      pcall(reader.repaint, win)
    end
  end
  -- the pager paints its own furniture with palette colours
  -- (翻页器用配色颜色画它自己的页面元素)
  pcall(function()
    local pager = require("weread.pager")
    if pager and type(pager.retheme) == "function" then
      pager.retheme()
    end
  end)
end

---Give a window its own colorscheme back.
---(把窗口自己的配色还回去)
---
---`winhighlight` is a window option, so a window that was reading keeps the paper
---palette even after something else is shown in it. Everything the palette
---replaced — including generic captures like `@text.strong` — has to be handed
---back, or the editor looks wrong after reading.
---(`winhighlight` 是窗口选项，因此读过书的窗口在显示别的内容时仍留着纸色配色。凡是配色替换过
--- 的东西——包括 `@text.strong` 这类通用捕获——都要还回去，否则读完书编辑器看起来是坏的)
---@param win integer
function M.clear(win)
  if not vim.api.nvim_win_is_valid(win) then
    return
  end
  if vim.wo[win].winhighlight:find("Weread", 1, true) then
    vim.api.nvim_set_option_value("winhighlight", "", { scope = "local", win = win })
    -- the page geometry the reader set goes back to the global values too
    -- (阅读器设的书页几何也回到全局值)
    pcall(function()
      vim.api.nvim_set_option_value("scrolloff", -1, { scope = "local", win = win })
      vim.api.nvim_set_option_value("fillchars", "", { scope = "local", win = win })
    end)
  end
end

---Repaint every window whose buffer is not a chapter any more.
---(把所有不再是章节的窗口恢复原配色)
---@return integer cleared
function M.clear_stale()
  local reader = require("weread.reader")
  local cleared = 0
  for _, win in ipairs(vim.api.nvim_list_wins()) do
    local buf = vim.api.nvim_win_get_buf(win)
    if not reader.buffer_info(buf) and vim.wo[win].winhighlight:find("Weread", 1, true) then
      M.clear(win)
      cleared = cleared + 1
    end
  end
  return cleared
end

---How a theme choice reads in a message: "auto" says what it resolved to.
---(主题选择在提示里的写法："auto" 会说明它此刻选中了哪套)
---@param choice string
---@return string
local function spoken(choice)
  local lowered = choice:lower()
  if lowered == "none" or lowered == "plain" then
    return "跟随配色方案"
  end
  if lowered == "auto" then
    return "auto（此刻是 " .. M.resolve_auto() .. "）"
  end
  return lowered
end

---Follow 'background' while the theme is "auto": a colorscheme switch, or a
---terminal that reports its new colours, flips the page between the light and
---the dark palette. Best effort: whether a terminal (or a multiplexer in front
---of it) reports a change at runtime is up to the terminal.
---(主题为 "auto" 时跟随 'background'：切换配色方案，或终端上报了新的颜色，书页就在浅色与深色配色
--- 之间切换。尽力而为：终端（或它前面的复用器）运行中会不会上报变化，取决于终端)
function M.watch_background()
  local group = vim.api.nvim_create_augroup("WereadThemeAuto", { clear = true })
  vim.api.nvim_create_autocmd("OptionSet", {
    group = group,
    pattern = "background",
    callback = function()
      -- nothing is being read until the reader is loaded: no window to repaint,
      -- and loading it here would register its autocommands for nothing
      -- (阅读器没加载就没有在读的书：没有窗口要重画，在这里加载它只会白白注册它的自动命令)
      if not package.loaded["weread.reader"] then
        return
      end
      if M.choice() == "auto" then
        M.apply_all()
      end
    end,
  })
end

---Interactive switch, also remembered for the next session. An unknown name is
---refused rather than quietly turned into "none" and remembered.
---(交互式切换，并记住以便下次启动沿用。不认识的名字直接拒绝，而不是悄悄变成 "none" 再记下来)
---
---The choice goes to the open book alone when `opts.book` says so, or when the
---book already has a theme of its own (so `]t` keeps working on it); otherwise
---it is the global theme.
---(`opts.book` 为真，或这本书本来就有自己的主题（这样 `]t` 照样作用于它）时，选择只给当前这本书；
--- 否则改的是全局主题)
---@param name string|nil
---@param opts table|nil { quiet = boolean, book = boolean } quiet: no message; book: this book only(quiet：不提示；book：只给这本书)
---@return boolean ok
function M.set(name, opts)
  opts = opts or {}
  if not M.known(name) then
    vim.notify(
      "weread: 没有叫 " .. tostring(name) .. " 的阅读主题；可选：" .. table.concat(M.choices(), " / "),
      vim.log.levels.WARN
    )
    return false
  end
  ---@cast name string
  local choice = name:lower() == "plain" and "none" or name:lower()
  local book_id = open_book()
  local for_book = book_id ~= nil and (opts.book or M.book_choice(book_id) ~= nil)
  if opts.book and not book_id then
    vim.notify("weread: 没有打开的书，主题改为全局", vim.log.levels.WARN)
  end
  local before = M.current()
  trial = nil
  local config = require("weread.config")
  if for_book then
    local themes = book_themes()
    themes[book_id] = choice
    require("weread.prefs").set("book_themes", themes)
  else
    config.get().theme = choice
    require("weread.prefs").set("theme", choice)
  end
  M.apply_all()
  M.fade(before, M.current())
  if not opts.quiet then
    local message = "weread: " .. (for_book and "本书主题 → " or "阅读主题 → ") .. spoken(choice)
    local description = M.describe(M.normalize(choice))
    if choice ~= "none" and description ~= "" then
      message = message .. "  " .. description
    end
    if not for_book and config.theme_pinned() then
      message = message .. "（setup 里配置了 theme，重启后以配置为准）"
    end
    vim.notify(message)
  end
  return true
end

---Let the open book follow the global theme again.
---(让当前这本书重新跟随全局主题)
---@return boolean had one(原来是否有单独的主题)
function M.forget_book()
  local book_id = open_book()
  if not book_id or not M.book_choice(book_id) then
    vim.notify("weread: 这本书没有单独的主题，本来就跟随全局", vim.log.levels.INFO)
    return false
  end
  local before = M.current()
  local themes = book_themes()
  themes[book_id] = nil
  require("weread.prefs").set("book_themes", themes)
  M.apply_all()
  M.fade(before, M.current())
  vim.notify("weread: 本书主题 → 跟随全局（" .. spoken(require("weread.config").get().theme or "none") .. "）")
  return true
end

---A palette `t` of the way from one to another, every ink mixed in Oklab.
---(从一套配色走向另一套 t 处的配色，每种墨色都在 Oklab 里混合)
---@param from table
---@param to table
---@param t number 0..1
---@return table
function M.blend(from, to, t)
  local mix = require("weread.color").mix
  local function blend_table(a, b)
    local out = {}
    for key, value in pairs(b) do
      local other = a[key]
      if type(value) == "string" and type(other) == "string" and value:match("^#%x%x%x%x%x%x$") and other:match("^#%x%x%x%x%x%x$") then
        out[key] = mix(other, value, t)
      elseif type(value) == "table" and type(other) == "table" then
        out[key] = blend_table(other, value)
      else
        out[key] = value
      end
    end
    return out
  end
  return blend_table(from, to)
end

---Frames of the switch fade, and the time between them: about 200 ms in all,
---short because a light to dark fade passes through low contrast.
---(切换渐变的帧数与帧间隔：总共约 200 毫秒——要短，因为浅到深的渐变会经过低对比度的中间帧)
local FADE_FRAMES, FADE_MS = 6, 33

---The page fades from one palette into the next after a switch. Only the
---palette groups are rewritten frame by frame: the windows already point at
---them, so nothing is laid out again.
---(切换之后，书页从一套配色渐变到下一套。逐帧只重写配色组：窗口本来就指向它们，所以不会重新排版)
---@param from string palette name before(之前的配色名)
---@param to string palette name after(之后的配色名)
---@return table|nil handle
function M.fade(from, to)
  local old, new = M.palettes[from], M.palettes[to]
  if from == to or not old or not new then
    return nil
  end
  local fx = require("weread.fx")
  if not fx.enabled("theme") then
    return nil
  end
  return fx.play({
    frames = FADE_FRAMES,
    interval = FADE_MS,
    draw = function(frame)
      if M.current() ~= to then
        return false
      end
      M.define(to, M.blend(old, new, frame / FADE_FRAMES))
    end,
    cleanup = function()
      -- whatever stopped it, the page ends on the real palette
      -- (不论是什么停下了它，书页最后都是真正的配色)
      if M.palettes[M.current()] then
        M.define(M.current())
      end
    end,
  })
end

---Step to the next (or previous) palette, lightest to darkest, wrapping round.
---"none" is not a stop: the keys are for trying pages, and the colorscheme is a
---`:WeReadTheme none` away.
---(切到下一套（或上一套）配色，由亮到暗，到头回绕。"none" 不在其中：这两个键是用来试纸页的，
--- 配色方案用 `:WeReadTheme none` 随时可回)
---@param step integer 1 or -1(1 或 -1)
---@return string name the palette now in use(当前使用的配色)
function M.cycle(step)
  local current = M.current()
  local index = 0
  for i, name in ipairs(M.names) do
    if name == current then
      index = i
    end
  end
  if index == 0 then
    -- from "none", forward starts at the first page and back at the last
    -- (从 "none" 出发，向前从第一套开始，向后从最后一套开始)
    index = step > 0 and 0 or #M.names + 1
  end
  local target = M.names[(index - 1 + step) % #M.names + 1]
  M.set(target)
  return target
end

---Every name `:WeReadTheme` accepts, palettes first.
---(`:WeReadTheme` 接受的全部名字，配色在前)
---@return string[]
function M.choices()
  local names = vim.list_extend({}, M.names)
  return vim.list_extend(names, M.special)
end

---One-line description of each choice in the picker.
---(选择器里每个选项的一句话说明)
local DESCRIPTIONS = {
  light = "素白，不带纸色",
  eink = "墨水屏：纯黑白，划线靠线型区分",
  eink_soft = "柔和墨水屏：米白纸、近黑墨，自发光屏上不刺眼",
  dawn = "晨：暖白纸、冷紫墨",
  solarized = "Solarized 浅色，正文墨色加深",
  sepia = "明亮的米黄，近似 Kindle 的 sepia",
  gruvbox = "gruvbox 浅色：暖黄纸、深棕墨",
  paper = "暖米纸色，久读不刺眼",
  jade = "竹青：低饱和的绿底（偏好，不是护眼）",
  dusk = "暮：中灰，关灯前的傍晚",
  night = "深色暖底，关灯阅读",
  dragon = "墨龙：近黑，暗室里的 OLED 屏",
  phosphor = "琥珀 CRT：趣味复古终端",
  auto = "按 'background' 自动选浅色或深色",
  none = "跟随当前配色方案（不改窗口）",
}

---@param name string
---@return string
function M.describe(name)
  local palette = M.palettes[name]
  return DESCRIPTIONS[name] or (palette and palette.description) or ""
end

---@return table[] items for a picker(选择器条目)
function M.items()
  local items = {}
  for _, name in ipairs(M.choices()) do
    local description = M.describe(name)
    items[#items + 1] = { text = name .. "  " .. description, name = name, description = description }
  end
  return items
end

-- ------------------------------------------------------------------ preview

---A sample page: what the reader sees in a chapter, element by element.
---Each segment is { text, role }; roles map to the palette in `sample_groups`.
---(示范页：读者在章节里看到的各种元素。每个片段是 { 文字, 角色 }，角色在 sample_groups 里
--- 映射到配色)
local SAMPLE = {
  { { "第三章　焦油坑", "heading1" } },
  {},
  { { "　　史前史中，没有别的场景比巨兽在焦油坑中垂死挣扎", "text" } },
  { { "的场面更令人震撼。", "text" }, { "上帝见证着", "strong" }, { "恐龙、猛犸象、剑齿", "text" } },
  { { "虎在焦油中挣扎。它们挣扎得越是猛烈，焦油纠缠得越", "text" } },
  { { "紧。", "text" }, { "[1]", "footnote" } },
  { { "　　", "text" }, { "过去几十年的大型系统开发就犹如这样一个焦油坑", "mine" }, { "，", "text" } },
  { { "很多大型和强壮的动物在其中剧烈地挣扎。", "text" }, { "表面上看起来", "popular" } },
  { { "好像没有任何一个单独的问题会导致困难", "hot" }, { "，每个都能被解决。", "text" } },
  {},
  { { "## 编程系统产品", "heading2" } },
  {},
  { { "　　> 一个程序，就是一个能够在系统中运行的完整单元。", "quote" } },
  { { "　　Programming System Product · `go run ./cmd/api`", "code" } },
  {},
  { { "[1] 脚注与图注用淡墨显示。", "small" } },
  {},
  { { "  ", "text" }, { "我的划线", "mine" }, { "  ", "text" }, { "热门划线", "popular" }, { "  ", "text" }, { "很多人划过", "hot" }, { "  ", "text" }, { "着重号", "dots" } },
}

---Highlight groups painting the sample page in one palette. Defined under
---their own names, so showing the preview never touches the groups the open
---chapters use.
---(用某套配色绘制示范页的高亮组。用独立的名字定义，因此显示预览绝不会动到正在打开的章节
--- 使用的组)
---@param name string theme name, "none" for the colorscheme(主题名，"none" 表示配色方案)
---@return table<string, string> role -> group
function M.sample_groups(name)
  local set = vim.api.nvim_set_hl
  local prefix = M.group_name("WereadSample", name)
  local palette = M.palettes[M.normalize(name)]
  local specs
  if palette then
    local mine = { fg = palette.fg, bg = palette.bg, sp = palette.mine_sp or palette.accent }
    mine[palette.mine_style or "underline"] = true
    local popular = { fg = palette.fg, bg = palette.bg, sp = palette.popular_sp or palette.muted }
    popular[palette.popular_style or "undercurl"] = true
    local hot = { fg = palette.fg, bg = palette.bg, sp = palette.popular_sp or palette.accent, bold = true }
    hot[palette.popular_style or "underline"] = true
    local mix = require("weread.color").mix
    specs = {
      normal = { fg = palette.fg, bg = palette.bg },
      text = { fg = palette.fg, bg = palette.bg },
      heading1 = { fg = palette.accent, bg = palette.bg, bold = true },
      heading2 = { fg = palette.accent, bg = palette.bg, bold = true },
      -- the same two groups the page uses: bold is ink, 着重号 is a dotted rule
      -- (与书页用的两个组一致：粗体是墨色，着重号是点线)
      strong = { fg = palette.fg, bg = palette.bg, bold = true },
      dots = { fg = palette.fg, bg = palette.bg, underdotted = true, sp = palette.accent },
      mine = mine,
      popular = popular,
      hot = hot,
      footnote = { fg = palette.muted, bg = palette.bg },
      small = { fg = palette.muted, bg = palette.bg },
      quote = { fg = palette.muted, bg = palette.bg, italic = true },
      code = { fg = (palette.code or {}).func or palette.link, bg = mix(palette.bg, palette.fg, 0.04) },
    }
  else
    -- the colorscheme's own groups(配色方案自己的组)
    specs = {
      normal = { link = "Normal" },
      text = { link = "Normal" },
      heading1 = { link = "Title" },
      heading2 = { link = "Title" },
      strong = { bold = true },
      dots = { underdotted = true },
      mine = { link = "WereadMineHighlight" },
      popular = { link = "WereadPopularHighlight" },
      hot = { link = "WereadPopularHot" },
      footnote = { link = "Comment" },
      small = { link = "Comment" },
      quote = { link = "Comment" },
      code = { link = "Special" },
    }
  end
  local groups = {}
  for role, spec in pairs(specs) do
    local group = prefix .. role:sub(1, 1):upper() .. role:sub(2)
    set(0, group, spec)
    groups[role] = group
  end
  return groups
end

---Lines and highlight segments of the sample page, centred in a width.
---(示范页的行与高亮片段，在给定宽度里居中)
---@param name string
---@param width integer|nil
---@return string[] lines
---@return table[] marks { row, col, end_col, group }
---@return table<string, string> groups
function M.sample(name, width)
  local groups = M.sample_groups(name)
  -- the sample lines are 26 characters, the default page width
  -- (示范行是 26 个字，即默认版心宽度)
  local column = 52
  local pad = string.rep(" ", math.max(1, math.floor(((tonumber(width) or 64) - column) / 2)))
  local lines, marks = { "" }, {}
  for _, segments in ipairs(SAMPLE) do
    local parts, col, row = { pad }, #pad, #lines + 1
    for _, segment in ipairs(segments) do
      local text = segment[1]
      if segment[2] == "heading2" then
        text = text:gsub("^## ", "")
      elseif segment[2] == "quote" then
        text = text:gsub("> ", "")
      elseif segment[2] == "code" then
        text = text:gsub("`", "")
      end
      marks[#marks + 1] = { row = row, col = col, end_col = col + #text, group = groups[segment[2]] }
      parts[#parts + 1] = text
      col = col + #text
    end
    lines[row] = #segments == 0 and "" or table.concat(parts)
  end
  lines[#lines + 1] = ""
  return lines, marks, groups
end

---Swatch groups for the picker list: page, ink, accent and mark of a palette,
---each drawn as a solid block.
---(选择器列表用的色块组：一套配色的纸、墨、强调色与标记色，各画成一个实心块)
---@param name string
---@return string[]|nil groups nil for a pseudo theme(伪主题返回 nil)
function M.swatch_groups(name)
  local palette = M.palettes[name]
  if not palette then
    return nil
  end
  local prefix = M.group_name("WereadSwatch", name)
  local groups = {}
  for i, key in ipairs({ "bg", "fg", "accent", "mark" }) do
    local group = prefix .. i
    vim.api.nvim_set_hl(0, group, { fg = palette[key], bg = palette.bg })
    groups[i] = group
  end
  return groups
end

---The picker title for a palette: how readable its body and quiet inks are.
---(选择器里一套配色的标题：正文与淡色字的可读性)
---@param name string
---@return string
function M.preview_title(name)
  local resolved = M.normalize(name)
  local palette = M.palettes[resolved]
  if not palette then
    return name .. "  跟随配色方案"
  end
  local apca = require("weread.color").apca
  local label = name == resolved and name or (name .. " → " .. resolved)
  return string.format(
    "%s  正文 Lc %d · 淡字 Lc %d",
    label,
    math.floor(math.abs(apca(palette.fg, palette.bg)) + 0.5),
    math.floor(math.abs(apca(palette.muted, palette.bg)) + 0.5)
  )
end

---snacks preview: the sample page in the highlighted theme.
---(snacks 预览：用高亮的主题绘制示范页)
---@param ctx table snacks.picker.preview.ctx
function M.snacks_preview(ctx)
  local item = ctx.item or {}
  local view = ctx.preview
  view:reset()
  if view.minimal then
    pcall(view.minimal, view)
  end
  if not item.name then
    view:set_lines({ item.text or "" })
    return
  end
  view:set_title(M.preview_title(item.name))
  local width = require("weread.preview").text_width(ctx.win)
  local lines, marks, groups = M.sample(item.name, width)
  view:set_lines(lines)
  local ns = view:ns()
  for _, mark in ipairs(marks) do
    pcall(vim.api.nvim_buf_set_extmark, ctx.buf, ns, mark.row - 1, mark.col, {
      end_col = mark.end_col,
      hl_group = mark.group,
      hl_mode = "replace",
    })
  end
  -- the whole window takes the page colour, empty rows and margins included
  -- (整个窗口都换成纸色，空行与两侧留白也一样)
  if ctx.win and vim.api.nvim_win_is_valid(ctx.win) then
    vim.api.nvim_set_option_value("winhighlight", "Normal:" .. groups.normal .. ",NormalNC:" .. groups.normal .. ",EndOfBuffer:" .. groups.normal, { scope = "local", win = ctx.win })
  end
end

---Show a theme on the open chapters without choosing it: nothing is written to
---the preferences, and `untry` puts the previous choice back.
---(在打开的章节上试用某个主题而不选定它：不写偏好，`untry` 会还原之前的选择)
---@param name string
function M.try(name)
  if not M.known(name) then
    return
  end
  trial = name:lower()
  M.apply_all()
end

---Stop trying: the page goes back to the theme in force.
---(结束试用：书页回到正在生效的主题)
function M.untry()
  if trial == nil then
    return
  end
  trial = nil
  M.apply_all()
end

---Wait after the cursor stops on a theme before the chapter is repainted:
---repainting is cheap but not free, and holding `j` should not repaint per row.
---(光标停在某个主题上之后，等多久才重画章节：重画不贵但也不是免费的，按住 `j` 不应每行都重画)
local TRY_MS = 60

---@param opts table|nil { book = boolean } choose for the open book only(只给当前这本书选)
function M.picker(opts)
  opts = opts or {}
  local current = M.current()
  local original = M.choice()
  local for_book = opts.book or M.book_choice() ~= nil
  local items = M.items()
  local swatches = {}
  for _, item in ipairs(items) do
    item.current = item.name == original or (original ~= "auto" and item.name == current)
    swatches[item.name] = M.swatch_groups(item.name)
  end
  local timer = require("weread.timer")
  local trying = timer.debounce(function(name)
    M.try(name)
  end, TRY_MS)
  require("weread.ui").select({
    title = (for_book and "微信读书 · 本书主题" or "微信读书 · 阅读主题") .. "（移动即试用，回车选定，Esc 还原）",
    items = items,
    format = function(item)
      local chunks = { { item.current and "▶ " or "  ", "DiagnosticOk" } }
      local swatch = swatches[item.name]
      if swatch then
        chunks[#chunks + 1] = { " ", swatch[1] }
        for i = 1, 4 do
          chunks[#chunks + 1] = { "█", swatch[i] }
        end
        chunks[#chunks + 1] = { " ", swatch[1] }
      else
        chunks[#chunks + 1] = { item.name == "auto" and "  ◐   " or "  ⊘   ", "Comment" }
      end
      chunks[#chunks + 1] = { " " }
      chunks[#chunks + 1] = { string.format("%-10s", item.name), item.current and "DiagnosticOk" or "Title" }
      chunks[#chunks + 1] = { item.description or "", "Comment" }
      return chunks
    end,
    preview = function(ctx)
      M.snacks_preview(ctx)
    end,
    snacks = {
      -- open on the theme in use, not on the first row
      -- (打开时停在正在用的主题上，而不是第一行)
      on_show = function(picker)
        -- worked out again on every show: a resumed picker must mark the theme
        -- in use now, not the one of the first run
        -- (每次显示都重新算：恢复的选择器要标出此刻在用的主题，而不是第一次打开时的)
        local now, raw = M.current(), M.choice()
        local row = nil
        for i, item in ipairs(picker:items()) do
          item.current = item.name == raw or (raw ~= "auto" and item.name == now)
          row = row or (item.current and i or nil)
        end
        if row then
          picker.list:view(row)
        end
      end,
    },
    on_change = function(item)
      if item and item.name then
        trying.call(item.name)
      end
    end,
    -- Esc: the page goes back to what it was; a confirmed choice is made in
    -- `on_choice` right after, so there is nothing to put back
    -- (Esc：书页回到原样；选定的话紧接着由 `on_choice` 处理，不必还原)
    on_close = function(chosen)
      trying.cancel()
      if not chosen then
        M.untry()
      end
    end,
    on_choice = function(item)
      M.set(item.name, { book = opts.book })
    end,
  })
end

return M
