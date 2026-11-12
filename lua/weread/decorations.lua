--[[
Decide what other markdown decoration plugins may draw on a reading buffer.

LazyVim turns on render-markdown.nvim for every markdown buffer, and chapter
buffers are markdown. Left alone it draws headings with a full width border and a
background band — on a white e-ink page that is a black box around every heading —
plus indent guides and icons.

Two things it draws are wanted, though, and markdown cannot express either on its
own: **pipe tables** (aligned columns, wrapped to fit the window, borders instead
of `|`) and **fenced code blocks** (a language label, a rule above and below). So
instead of keeping it away, this module hands it a buffer-local config that turns
everything off *except* those two, seeded before the file is even read so no other
render ever happens. Its colours come from the reading palette: the window
remaps its `RenderMarkdown*` groups onto paper groups (`weread.theme`).
(LazyVim 给所有 markdown buffer 开了 render-markdown.nvim，而章节 buffer 就是 markdown。
 放着不管，它会给标题画整行边框加底色带——在纯白墨水屏页面上就是每个标题套个黑框——外加缩进
 参考线和图标。

 但它有两样东西是想要的，而且 markdown 自己表达不了：**管道表格**（列对齐、按窗口宽度折行、
 用边框代替 `|`）与**围栏代码块**（语言标签、上下各一条线）。所以这里的做法不是把它挡在外面，
 而是给它一份 buffer 级配置：只开这两样、其余全关；并且在这份文件被读入之前就种好，使它不会
 有第二次别的渲染。颜色取自阅读配色：窗口把它的 `RenderMarkdown*` 组重映射到纸色组
 （`weread.theme`）)
]]

local M = {}

---@return table|nil render-markdown's shared state table
local function state()
  local ok, module = pcall(require, "render-markdown.state")
  if not ok or type(module) ~= "table" then
    return nil
  end
  return module
end

---@return boolean guarded
function M.applied()
  local module = state()
  return module ~= nil and module.weread_guarded == true
end

---Buffer-local switches that send decoration plugins away.
---(告诉装饰插件别来的 buffer 级开关)
---
---Indent guides are the visible one: `snacks.indent` draws a coloured `│` per
---indent level, and a book page is indented, so the page ends up with coloured
---bars down its left edge — the one thing an e-ink screen must not have. Each
---plugin has its own buffer variable, verified against the installed versions.
---(缩进参考线是最明显的那个：`snacks.indent` 每级缩进画一条彩色 `│`，而书页本来就是缩进的，
--- 于是页面左边多出一道彩色竖条——墨水屏上最不该有的东西。每个插件有各自的 buffer 变量，
--- 都已对实际安装的版本核对过)
local QUIET = {
  -- snacks.indent: indent guides and the current scope highlight
  -- (缩进参考线与当前 scope 高亮)
  snacks_indent = false,
  -- snacks.scroll draws a scrollbar inside the window
  -- (在窗口内画滚动条)
  snacks_scroll = false,
  -- mini.animate: scrolling and cursor animations on a page that turns whole
  -- screens (mini.animate：在整屏翻页的书页上做滚动与光标动画)
  minianimate_disable = true,
}

---Tell every decoration plugin we know about to leave this buffer alone.
---(让已知的装饰插件别碰这个 buffer)
---@param buf integer
---@return integer applied
function M.quiet(buf)
  if not vim.api.nvim_buf_is_valid(buf) then
    return 0
  end
  local applied = 0
  for name, value in pairs(QUIET) do
    vim.b[buf][name] = value
    applied = applied + 1
  end
  -- A language server attached to a markdown buffer would print types and link
  -- targets inline; a page has none of that.
  -- (挂在 markdown buffer 上的语言服务器会内联打印类型与链接目标；书页上没有这些)
  pcall(function()
    if vim.lsp.inlay_hint and vim.lsp.inlay_hint.enable then
      vim.lsp.inlay_hint.enable(false, { bufnr = buf })
    end
  end)
  return applied
end

---What render-markdown may draw on a page.
---(render-markdown 允许在书页上画什么)
---
---Everything is off except the two things markdown has no way to express and a
---page wants anyway. The keys are the plugin's *expanded* values, not its style
---presets: presets (`style = "normal"`, `preset = "round"`) are only expanded for
---the global config at setup time, so a per-buffer config that passes a preset
---name is silently ignored.
---(除 markdown 无法表达、而书页又需要的两样之外，其余全关。这里的键是该插件**展开后**的值，
--- 不是它的 style 预设：预设（`style = "normal"`、`preset = "round"`）只在 setup 时对全局
--- 配置展开，buffer 级配置里写预设名会被静默忽略)
local PRETTY = {
  -- The chapter is written as standard markdown (weread.xhtml), so the plugin draws
  -- its structure the way it draws any markdown file: a band behind each heading,
  -- `●` for a bullet, a bar down a quote, a rule for `---`. The heading icon and
  -- the `#` marks are weread.inline's: the page width a heading was laid out for
  -- counts the icon, and it must be there with or without this plugin.
  -- (章节写成标准 markdown（weread.xhtml），因此插件像画任何 markdown 文件一样画它的结构：
  --  标题后的色带、无序项的 `●`、引文左侧的竖条、`---` 的分隔线。标题图标与 `#` 归 weread.inline：
  --  标题排版时的版心宽度算进了图标，有没有这个插件它都得在)
  heading = {
    enabled = true,
    sign = false,
    icons = {},
    position = "inline",
    width = "block",
    left_pad = 0,
    right_pad = 1,
    border = false,
  },
  indent = { enabled = false },
  bullet = { enabled = true, left_pad = 0, right_pad = 0 },
  checkbox = { enabled = false },
  dash = {
    enabled = true,
    -- as wide as the text column, not the window: the page has margins
    -- (与正文列同宽，而不是窗口：书页有页边)
    width = function(ctx)
      local ok, layout = pcall(require, "weread.layout")
      local page = ok and layout.page_width(0) or 0
      if page > 0 then
        return math.min(page, ctx.width)
      end
      return ctx.width
    end,
  },
  quote = { enabled = true, repeat_linebreak = false },
  -- `callout` is deliberately absent: that section is a *map* of callouts keyed by
  -- name, not a config, so adding `enabled = false` to it makes the plugin's own
  -- resolver iterate that boolean as if it were a callout and crash on
  -- `config.raw`. A page has no callouts for the same reason it has no headings.
  -- (`callout` 刻意不写：那一段是以名字为键的 callout **映射**，不是配置；往里加
  --  `enabled = false` 会让插件自己的 resolver 把这个布尔值当成一条 callout 去取
  --  `config.raw` 而崩掉。书页上没有 callout，理由和没有标题边框一样)
  link = { enabled = false },
  html = { enabled = false },
  latex = { enabled = false },
  sign = { enabled = false },
  yaml = { enabled = false },
  inline_highlight = { enabled = false },
  document = { enabled = false },
  paragraph = { enabled = false },
  -- `disabled_modes` (empty) keeps the line the cursor is on drawn like every other
  -- line. The plugin otherwise re-exposes the raw markdown under the cursor, and
  -- the reader keeps the cursor on the page's *top* line — so the first row of a
  -- table (or the first line of a listing) showed `| cell |` while the rest of the
  -- table was drawn.
  -- (`disabled_modes` 置空，使光标所在行的绘制与其他行完全一致。否则插件会重新露出光标下的
  --  markdown 原文，而阅读器把光标放在页面**顶行**——于是表格首行（或清单首行）显示 `| 格 |`
  --  的原文，而表格其余部分已经画好)
  --
  -- Then off altogether: a page is read, not edited, and even with no disabled
  -- mode the plugin still reveals the raw source of the cursor's own row.
  -- (进而整个关掉：书页是读的、不是改的；即便不设禁用模式，插件仍会露出光标所在行的原文)
  anti_conceal = { enabled = false, disabled_modes = {} },
  -- tables: aligned columns, cells wrapped to the window, `|` replaced by borders
  -- (表格：列对齐、单元格按窗口折行、`|` 换成边框)
  pipe_table = {
    enabled = true,
    cell = "padded",
    wrap = true,
    padding = 1,
    min_width = 0,
    -- No top and bottom rule: those two are drawn as *virtual* lines, which start
    -- at the window's left edge and would sit outside the text column, while the
    -- rows themselves are drawn in place. The delimiter row keeps `border[4..11]`
    -- on its own line, so the table still reads as a table.
    -- (不画上下两条外框线：那两条是**虚拟行**，从窗口最左边开始画，会落到正文列之外，而表格
    --  行本身是就地绘制的。分隔行仍会用 `border[4..11]` 画在本行上，表格依然是表格)
    border_enabled = false,
    head = "WereadPaperTableHead",
    row = "WereadPaperTableRow",
  },
  -- code: a language label and a rule above and below, but no background — the
  -- point of a code block here is the syntax highlighting inside it
  -- (代码块：语言标签与上下两条线，但不要底色——这里的代码块要点是里面的语法高亮)
  code = {
    enabled = true,
    sign = false,
    conceal_delimiters = true,
    language = false,
    language_icon = false,
    language_name = false,
    position = "left",
    -- `border = "none"`: every border style places the language label on the empty
    -- line above the fence, and an `overlay` virt_text is **not drawn on an empty
    -- line** (verified against this neovim) — the label simply never appears. With
    -- no border the label is drawn on the fence's own line instead, which has text.
    -- (`border = "none"`：所有边框样式都把语言标签放在围栏**上方**的空行上，而 `overlay`
    --  类虚拟文本在空行上**不会被绘制**（已在本机 neovim 上实测）——标签根本不会出现。不画边框
    --  时标签改画在围栏自己那一行上，那一行有文本)
    border = "none",
    inline = true,
    width = "full",
    disable_background = true,
    -- `highlight_border = false`: the plugin paints the border with the *background*
    -- of the border group used as a foreground (`colors.bg_as_fg`), and on a white
    -- page that background is white — a white label on white paper. With it off the
    -- label and the rules fall back to `RenderMarkdownCodeFallback`, which the
    -- window maps onto the palette's muted ink.
    -- (`highlight_border = false`：插件把边框组的**背景色**当前景色来画边框
    --  （`colors.bg_as_fg`），而纯白页面上那个背景色是白色——于是标签是白纸上的白字。关掉之后
    --  标签与上下线改用 `RenderMarkdownCodeFallback`，窗口把它映射到配色的淡墨)
    highlight_border = false,
  },
  win_options = {
    conceallevel = { rendered = 3 },
    concealcursor = { rendered = "nvic" },
  },
}

---The buffer config for a chapter, sized to the page it is read on.
---(章节的 buffer 级配置，按它所在书页的尺寸)
---
---A heading's band is drawn as wide as the plugin measures the heading, and
---anything past that is painted over with blank. It does not count what the page
---draws inline in front of the text — the heading icon, the padding that centres
---a title — so the end of a centred heading disappeared under the band's edge.
---As wide as the page, the band holds every heading the converter laid out.
---(标题色带按插件量出的标题宽度来画，超出部分被空白盖掉。它不计算书页内联画在文字前面的
--- 东西——标题图标、让标题居中的补白——于是居中标题的结尾消失在色带边缘之下。与版心同宽时，
--- 色带装得下转换器排出的每个标题)
---@return table
function M.pretty_config()
  local config = vim.deepcopy(PRETTY)
  local ok, layout = pcall(require, "weread.layout")
  local page = ok and layout.page_width(0) or 0
  if page > 0 then
    config.heading.min_width = page
  else
    config.heading.width = "full"
  end
  return config
end

---`M.prettify_error` value for "the plugin is not loaded yet", as opposed to a
---config it refused.
---(`M.prettify_error` 里表示「插件还没加载」的值，以区别于它拒收的配置)
local NOT_SET_UP = "not set up yet"

---@return table|nil render-markdown's api module
local function api()
  local ok, module = pcall(require, "render-markdown.api")
  if not ok or type(module) ~= "table" then
    return nil
  end
  return module
end

---Draw a buffer now, past render-markdown's debounce.
---(越过 render-markdown 的防抖，立刻绘制一个 buffer)
---
---`api.render` only *schedules* a render, and the plugin's debounce drops every
---request that arrives while its timer runs — each request restarting the timer.
---A page turn fires a burst of resizes, so the request that mattered was dropped
---and the tables went back to raw `| cell |` text. The plugin's own updater, run
---directly with `force`, parses, clears its marks through its decorator and draws
---them again, all at once. Falls back to `api.render` on a version without it.
---(`api.render` 只是**排期**一次渲染，而插件的防抖会丢掉计时期间到达的每个请求——每个请求
--- 还会重启计时器。翻页会连发几次 resize，于是真正要紧的那次请求被丢掉，表格退回成
--- `| 格 |` 原文。直接以 `force` 运行插件自己的 updater，会一次完成解析、经由 decorator
--- 清除旧标记、重新绘制。没有它的版本退回 `api.render`)
---@param module table render-markdown's api module
---@param buf integer
---@param win integer|nil
---@return boolean drawn
local function draw(module, buf, win)
  M.keep_rows()
  local ok_ui, ui = pcall(require, "render-markdown.core.ui")
  local updater = ok_ui and type(ui) == "table" and type(ui.updater) == "table" and ui.updater
  if updater and type(updater.new) == "function" and win then
    local ok = pcall(function()
      local plugin = state()
      plugin.get(buf)
      plugin.attach()
      updater.new(buf, win, true):run()
    end)
    if ok then
      return true
    end
  end
  return (pcall(module.render, { buf = buf, win = win }))
end

---Can this buffer be drawn by render-markdown at all?
---(这个 buffer 能不能交给 render-markdown 绘制)
---@return boolean
function M.available()
  return api() ~= nil and state() ~= nil
end

---Give render-markdown its buffer-local config for a chapter.
---(给 render-markdown 一份章节专用的 buffer 级配置)
---
---Seeded **before** the file is read. Reading it fires `FileType`, and that is when
---the plugin attaches and builds its per-buffer config — a config seeded after
---that moment loses to the one already built, and the page gets a black box
---around its first heading.
---(在文件被读入**之前**就种好。读文件会触发 `FileType`，而那正是插件 attach 并构建 buffer
--- 级配置的时刻——晚于那一刻种下的配置会输给已经建好的那份，页面就会在第一个标题上多出一个黑框)
---@param buf integer
---@return boolean seeded
function M.prettify(buf)
  local module = state()
  if not module or type(module.get) ~= "function" or not vim.api.nvim_buf_is_valid(buf) then
    return false
  end
  -- Not set up yet: LazyVim loads the plugin on `FileType markdown`, and the
  -- reader calls this *before* the file is read, so on a cold start there is
  -- nothing to seed into. The caller retries before drawing.
  -- (还没 setup：LazyVim 在 `FileType markdown` 时才加载这个插件，而阅读器在文件被读入
  --  **之前**就调用了它，因此冷启动时还没有可种的地方。调用方在绘制前会再试一次)
  if module.config == nil then
    M.prettify_error = NOT_SET_UP
    return false
  end
  local ok, err = pcall(module.get, buf, M.pretty_config())
  -- Kept for `:checkhealth weread`: the seeding is a single point of failure (a
  -- config the plugin refuses, an internal rename) and it fails silently by
  -- design, because a reading session must not break over a decoration.
  -- (留给 `:checkhealth weread`：种配置是单点失败（插件拒收的配置、内部改名），而且按设计
  --  是静默失败的——阅读过程不能因为一个装饰而中断)
  M.prettify_error = ok and nil or tostring(err)
  return ok
end

---Retries a single render request may spend waiting for render-markdown to be
---set up, and for the page margin to show in the window width.
---(一次渲染请求最多为「等 render-markdown 就绪」「等版心边距体现在窗口宽度里」各花多少次重试)
local RENDER_RETRIES = 8
local WIDTH_RETRIES = 12

---The retries one render request has used. A request is born each time `render`
---is called from outside and dies with its buffer; the timers it arms carry it,
---so a request that was superseded stops by itself.
---(一次渲染请求已经用掉的重试次数。每次外部调用 `render` 就产生一个新请求，随 buffer 一起消亡；
--- 它设下的定时器带着它走，所以被取代的请求会自己停下)
---@class WereadRenderRequest
---@field render integer retries spent waiting for render-markdown
---@field width integer retries spent waiting for the window width

---Requests by buffer and then window (0 when there is none): two windows on one
---buffer wait for their own width, and one buffer's retries never eat another's.
---(按 buffer、再按窗口（没有窗口记为 0）存放：同一 buffer 的两个窗口各等各的宽度，
--- 一个 buffer 的重试也不会吃掉另一个的额度)
---@type table<integer, table<integer, WereadRenderRequest>>
local requests = {}

local watching = false

---Forget a buffer's requests when it goes away.
---(buffer 消失时忘掉它的请求)
local function watch()
  if watching then
    return
  end
  watching = true
  local group = vim.api.nvim_create_augroup("WereadDecorations", { clear = true })
  vim.api.nvim_create_autocmd({ "BufWipeout", "BufDelete" }, {
    group = group,
    callback = function(args)
      requests[args.buf] = nil
    end,
  })
end

---The request a render belongs to; a `fresh` one replaces what the window had.
---(一次渲染所属的请求；`fresh` 会取代这个窗口原有的那个)
---@param buf integer
---@param win integer|nil
---@param fresh boolean
---@return WereadRenderRequest
local function request_for(buf, win, fresh)
  watch()
  local by_window = requests[buf]
  if not by_window then
    by_window = {}
    requests[buf] = by_window
  end
  local key = win or 0
  if fresh or not by_window[key] then
    by_window[key] = { render = 0, width = 0 }
  end
  return by_window[key]
end

---Retries a window's current request has spent, for diagnostics and tests; nil
---when nothing is being tracked for it.
---(某窗口当前请求已用掉的重试次数，供诊断与测试使用；没有记录时为 nil)
---@param buf integer
---@param win integer|nil
---@return WereadRenderRequest|nil
function M.retries(buf, win)
  local by_window = requests[buf]
  return by_window and by_window[win or 0] or nil
end

local attempt

---Try `attempt` again after `delay` ms, unless a newer request has taken over.
---(`delay` 毫秒后再试一次 `attempt`，除非已有更新的请求接手)
---@param buf integer
---@param win integer|nil
---@param request WereadRenderRequest
---@param delay integer
---@param window_needed boolean whether the window has to still exist(窗口是否必须仍然存在)
local function retry(buf, win, request, delay, window_needed)
  vim.defer_fn(function()
    local by_window = requests[buf]
    if not by_window or by_window[win or 0] ~= request then
      return
    end
    if window_needed and not vim.api.nvim_win_is_valid(win or 0) then
      return
    end
    attempt(buf, win, request)
  end, delay)
end

---One pass of `render`: draws, or arms a retry on the request.
---(`render` 的一遍：画出来，或者在请求上设下一次重试)
---@param buf integer
---@param win integer|nil
---@param request WereadRenderRequest
---@return boolean drawn
attempt = function(buf, win, request)
  local module = api()
  if not module or not vim.api.nvim_buf_is_valid(buf) then
    return false
  end
  -- Seeded here as well as at buffer creation: by now the plugin is set up, and
  -- the config has to be in its cache *before* it builds one of its own.
  -- (这里再种一次：此时插件已经 setup，而这份配置必须在它自建之前进入它的缓存)
  if not M.prettify(buf) then
    -- Cold start: LazyVim loads render-markdown on its own schedule, and the
    -- first chapter can be on screen before that. Waiting and asking again is the
    -- difference between a page with tables and a page without them, and the
    -- plugin builds a buffer's config exactly once — a later attempt is ignored,
    -- so this has to happen before anything else draws here.
    -- (冷启动：LazyVim 按自己的时机加载 render-markdown，而第一章可能在它之前就上了屏幕。
    --  等一会儿再问一次，就是「有表格的页面」和「没表格的页面」的区别；而这个插件为一个 buffer
    --  只构建一次配置——此后再试会被忽略，因此这必须在别的东西在这里绘制之前发生)
    if M.prettify_error == NOT_SET_UP and request.render < RENDER_RETRIES then
      request.render = request.render + 1
      retry(buf, win, request, 250, true)
    end
    return false
  end
  request.render = 0
  -- The page margin is a `statuscolumn`, and a window that has not been drawn yet
  -- still reports the *old* text width: `getwininfo().textoff` only accounts for it
  -- once the screen is redrawn. A table is laid out against that width, so drawing
  -- now would fold its cells into a window 29 columns wider than the page — the
  -- table would then be cut off at the right edge. Wait for the width to exist.
  -- (版心边距是一个 `statuscolumn`，而尚未重绘的窗口报告的仍是**旧的**文本宽度：
  --  `getwininfo().textoff` 要等屏幕重绘后才会把它算进去。表格正是按那个宽度排的，此刻就画
  --  会把单元格折进一个比版心宽 29 列的窗口——表格右边会被截掉。等宽度出现再画)
  local info = win and vim.fn.getwininfo(win)[1]
  if info and (info.textoff or 0) == 0 and M.reading(buf) and vim.wo[win].statuscolumn ~= "" then
    if request.width < WIDTH_RETRIES then
      request.width = request.width + 1
      retry(buf, win, request, 50, true)
    end
    return false
  end
  request.width = 0
  -- Drawn from scratch: the plugin lays a table out against the window width,
  -- and a table drawn before the page's own config landed (or at another window
  -- size) keeps the columns it chose. A forced update parses again and replaces
  -- every mark it drew.
  -- (从头画：表格是按窗口宽度排的，而在书页自己的配置生效之前（或另一个窗口尺寸下）画的表格会
  --  留着它当时算出的列宽。强制更新会重新解析，并替换它画过的每个标记)
  return draw(module, buf, win)
end

---Draw the tables and code blocks of a chapter.
---(画出章节里的表格与代码块)
---
---Called explicitly rather than left to the plugin's own autocmds: those are only
---registered when it attaches, and attaching is exactly what the guard prevents in
---chapter buffers. Explicit rendering also means a re-render happens when the
---layout changes (a resize changes the width the table folds its cells into).
---(显式调用，而不是交给插件自己的自动命令：那些命令只在它 attach 时注册，而章节里的守卫正是
--- 在阻止它 attach。显式渲染还意味着版式变化时能重画一次（窗口尺寸变了，表格折单元格的宽度也变了）)
---
---Every call starts a new request with its retries back at zero, so running out
---of them once never stops a later render from waiting again.
---(每次调用都开一个新请求，重试额度从零起算，因此某一次用完额度，不会让之后的渲染再也不等)
---@param buf integer
---@param win integer|nil
---@return boolean drawn
function M.render(buf, win)
  if not api() or not vim.api.nvim_buf_is_valid(buf) then
    return false
  end
  if not win or not vim.api.nvim_win_is_valid(win) then
    win = nil
  end
  return attempt(buf, win, request_for(buf, win, true))
end

---Draw what scrolled into view.
---(画出滚进视野的部分)
---
---render-markdown only lays out the rows on screen (and a few around them), and in
---a chapter buffer its own scroll autocmds are never registered — the guard keeps
---it from attaching. So a page turned to a table showed the raw `| cell |` text.
---Not forced: the plugin parses only when the view left what it already drew.
---(render-markdown 只排屏幕上（及其上下几行）的内容，而章节 buffer 里它自己的滚动自动命令从未
--- 注册——守卫阻止了它 attach。于是翻到一页表格时显示的是 `| 格 |` 原文。这里不强制：只有视野
--- 离开了它已画过的范围，插件才会重新解析)
---@param buf integer
---@param win integer
---@return boolean drawn
function M.follow(buf, win)
  if not vim.api.nvim_buf_is_valid(buf) or not vim.api.nvim_win_is_valid(win) then
    return false
  end
  local plugin = state()
  local ok_ui, ui = pcall(require, "render-markdown.core.ui")
  local updater = ok_ui and type(ui) == "table" and type(ui.updater) == "table" and ui.updater
  if not plugin or plugin.config == nil or not updater or type(updater.new) ~= "function" then
    return false
  end
  -- a buffer the plugin has never drawn is left to `render`, which seeds it first
  -- (插件从未画过的 buffer 交给 `render`，它会先种好配置)
  if type(plugin.cache) == "table" and plugin.cache[buf] == nil then
    return false
  end
  return (pcall(function()
    updater.new(buf, win, false):run()
  end))
end

---Keep a wrapped table row drawn while the cursor is on it.
---(光标停在折行的表格行上时，仍然把它画出来)
---
---A row too wide for the window is drawn as virtual lines over a concealed
---source line, and render-markdown hides such a replacement whenever the cursor
---is on its row, assuming the cursor needs the source to edit. The pager keeps the
---cursor on the page's top line, so a page that began with a table showed its
---header as raw `| cell |` text. In a chapter the cursor never edits, and
---`concealcursor` keeps the source concealed under it, so the replacement stays.
---(放不下的表格行会画成虚拟行、盖在被隐藏的源行上，而 render-markdown 只要光标在那一行就会
--- 撤掉替换——它以为光标要编辑源文本。分页器把光标放在页面顶行，于是以表格开头的一页，表头
--- 显示成 `| 格 |` 原文。章节里光标从不编辑，`concealcursor` 也让光标下的源文本保持隐藏，
--- 因此替换留着)
---@return boolean patched
function M.keep_rows()
  local ok, ui = pcall(require, "render-markdown.core.ui")
  local updater = ok and type(ui) == "table" and type(ui.updater) == "table" and ui.updater
  if not updater or type(updater.hide) ~= "function" or updater.weread_rows then
    return false
  end
  local hide = updater.hide
  updater.hide = function(self, extmark, range)
    local mark = type(extmark) == "table" and type(extmark.get) == "function" and extmark:get() or nil
    if mark and mark.replace and M.reading(self.buf) then
      -- answered as if the row had no replacement; every other rule still applies
      -- (按该行没有替换来回答；其余规则照旧)
      local replace = mark.replace
      mark.replace = nil
      local hidden = hide(self, extmark, range)
      mark.replace = replace
      return hidden
    end
    return hide(self, extmark, range)
  end
  updater.weread_rows = true
  return true
end

---Is this buffer a chapter being read?
---(这个 buffer 是不是正在读的章节？)
---
---Two ways to tell, because the buffer variable is set by the image module and the
---question can arrive before it does: ask the reader itself when the flag is not
---there yet.
---(两种判断，因为那个 buffer 变量由图片模块设置，而问题可能在它之前就到来：标记还没有时
--- 直接问阅读器)
---@param buf integer
---@return boolean
function M.reading(buf)
  if not vim.api.nvim_buf_is_valid(buf) then
    return false
  end
  if vim.b[buf].weread_book then
    return true
  end
  local ok, reader = pcall(require, "weread.reader")
  return ok and reader.buffer_info and reader.buffer_info(buf) ~= nil
end

---Make render-markdown skip chapter buffers.
---(让 render-markdown 跳过章节 buffer)
---@return boolean guarded
function M.guard()
  local module = state()
  if not module or module.weread_guarded then
    return false
  end
  local previous = module.ignore
  module.ignore = function(buf)
    if M.reading(buf) then
      return true
    end
    if type(previous) == "function" then
      return previous(buf)
    end
    return false
  end
  module.weread_guarded = true
  return true
end

return M
