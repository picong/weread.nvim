--[[
Plugin configuration: defaults, validation and the on-disk layout.
(插件配置：默认值、校验与磁盘布局)
]]

local log = require("weread.log")

local M = {}

M.defaults = {
  ---Root directory for credentials, caches and reading positions.
  ---(凭据、缓存与阅读位置的根目录)
  ---@type string|nil
  data_dir = nil,

  ---Width guide drawn as a colorcolumn. 0 disables it; it is off by default
  ---because a solid vertical line through Chinese text reads badly.
  ---(用 colorcolumn 画的宽度参考线。0 表示不画；默认关闭，因为一条竖线穿过中文
  --- 正文观感很差)
  ---@type integer
  text_width = 0,

  ---Typesetting of the rendered body.
  ---(正文排版)
  ---@type table
  paragraph = {
    ---Drop the blank line between paragraphs. A Chinese book separates
    ---paragraphs by indentation, not by empty lines, and the blank lines
    ---otherwise eat half of every screen.
    ---(去掉段间空行。中文书靠首行缩进区分段落而不是空行，否则每屏一半是空白)
    compact = true,
    ---Air around headings, figures and rules: "compact" (default) or "none".
    ---("compact" 或 "none"：标题/插图/分隔线周围是否留空行)
    gap = "compact",
    ---Fallback first-line indent, used when the book's stylesheet says nothing
    ---about `text-indent`. Books that do say something win, so a quote with
    ---`text-indent: 0` really starts flush.
    ---(首行缩进的退路值，在书籍样式表没提 `text-indent` 时使用。样式表说了话就听它的，
    --- 因此 `text-indent: 0` 的引文真的顶格开始)
    indent = "　　",
  },

  ---Page layout: the text column and its margins, and the reading shell around
  ---it. See `weread.layout` and `weread.shell`.
  ---(版面：正文列与两侧边距，以及它外面的阅读外壳。见 weread.layout 与 weread.shell)
  ---@type table
  layout = {
    ---Text column width, in Chinese characters. 0 falls back to the full window.
    ---(正文列宽，单位为汉字。0 表示退回满窗口)
    page_chars = 26,
    ---Let the column follow the window instead of a fixed number of characters.
    ---(让正文列随窗口浮动，而不是固定字数)
    adaptive = false,
    ---Insert the space the app inserts between Chinese and Latin text.
    ---(补上 App 会在中西文之间插入的空格)
    auto_space = true,
    ---"off" hides the statusline while reading (progress goes to the winbar),
    ---"window" gives the chapter window a statusline of its own, "keep" leaves
    ---the editor's alone.
    ---("off" 阅读时藏起状态栏（进度改在 winbar 上），"window" 给章节窗口一条自己的
    --- 状态栏，"keep" 不动编辑器的)
    statusline = "off",
    ---"block" draws the normal-mode cursor as a block in the palette's accent
    ---colour, easy to follow while reading; "bar" draws it as a thin bar, a
    ---caret in the text; "hidden" hides it, "normal" leaves it alone.
    ---("block" 把普通模式光标画成调色板强调色的方块，读的时候容易跟住；"bar" 画成一条细竖线，
    --- 文字间的插入符；"hidden" 隐藏它，"normal" 不动它)
    cursor = "block",
    ---"page" reads a screen at a time: whole lines per page, the rest of the
    ---window covered, a folio with the page number at the bottom. "scroll" is
    ---one continuous scroll through the chapter.
    ---("page" 一次读一屏：每页都是完整的行，窗口剩下的部分被遮住，底部是带页码的页脚。
    --- "scroll" 是整章连续滚动)
    page_mode = "page",
    ---Lines the mouse wheel scrolls per notch in "scroll" mode; in "page" mode
    ---the wheel turns pages.
    ---("scroll" 模式下滚轮每格滚动几行；"page" 模式下滚轮翻页)
    mousescroll = "ver:1,hor:1",
    ---Keep reading into the next chapter when you walk past the end of this one.
    ---(走到本章末尾之外时继续读下一章)
    auto_next = true,
    ---Line height used while a chapter is on screen, in percent of the default
    ---cell (e.g. 140). It is switched together with the reading font and put
    ---back when the chapter is left; nil leaves the terminal's own setting alone.
    ---(阅读章节时使用的行高，单位是默认单元格的百分比（如 140）。它和阅读字体一起切换，
    --- 离开章节时恢复；nil 表示不动终端自己的设置)
    ---@type integer|nil
    line_height = nil,
    ---Icons in front of headings, one per level; nil uses the ones a markdown
    ---renderer draws, false draws none.
    ---(标题前的图标，每级一个；nil 用 markdown 渲染器画的那套，false 不画)
    ---@type string[]|false|nil
    heading_icons = nil,
    ---A thin pixel bar in the folio for how far into the book the page is.
    ---(页脚里一条细细的像素进度条，表示这一页在全书的什么位置)
    progress_bar = true,
    ---Dotted emphasis under bold Chinese text, as the app draws it.
    ---(粗体中文下面画着重号，和 App 一样)
    emphasis_dots = true,
  },

  ---Small pixel animations around the page. They play at a change of state and
  ---end within a second (or while you are away), never while you read, and any
  ---key stops them. Off in a headless editor; `vim.g.weread_animations = false`
  ---turns them all off too.
  ---(书页周围的小像素动画。只在状态改变时播放、一秒内结束（或在你离开时播放），读的时候从不动，
  --- 任意按键都会停下。无界面编辑器里关闭；`vim.g.weread_animations = false` 也能全部关闭)
  ---@type table
  animations = {
    enabled = true,
    ---a pixel book turning its pages while a chapter is fetched
    ---(下载章节时，一本像素书在翻页)
    loading = true,
    ---ink spreading from the middle of a new highlight
    ---(新划线时，墨从中间洇开)
    highlight = true,
    ---a ribbon dropping when a bookmark is set
    ---(加书签时垂下一条缎带)
    bookmark = true,
    ---the page fading into the new palette after `]t` or `:WeReadTheme`
    ---(`]t` 或 `:WeReadTheme` 之后，书页渐变到新的配色)
    theme = true,
    ---a quill writing in the corner while a chapter is translated
    ---(翻译一章时，角落里一支羽毛笔在写)
    translating = true,
    ---the small pictures for one moment each, in the corner of the page: a
    ---magnifier after a search, a paper plane when progress is sent by hand, the
    ---phone's place arriving, a speech bubble for a thought posted
    ---(书页角落里只出现一下的小画：搜索后的放大镜、手动回传进度时的纸飞机、跟上手机进度、想法发出
    --- 时的对话气泡)
    sprites = true,
    ---an inchworm on the folio's progress bar, a step per page
    ---(页脚进度条上的一只尺蠖，每翻一页走一步)
    bookworm = false,
    ---a pixel plant at the end of the winbar, growing from a seed to fruit as
    ---today's reading adds up (5, 15, 30, 60 minutes); no numbers shown
    ---(winbar 末尾的一株像素植物，随今天的阅读累积从种子长到结果（5、15、30、60 分钟）；不显示数字)
    plant = true,
    ---a stamp at the foot of the page when a chapter is read to its end
    ---(读完一章时，在页脚盖一个印章)
    stamp = true,
    ---a card when the last page of the book is read
    ---(读到全书最后一页时弹出一张卡片)
    trophy = true,
    ---minutes without a key before a pixel fireplace burns over the page;
    ---0 or nil never (any key puts the page back)
    ---(多少分钟没有按键之后，在书页上点起像素壁炉；0 或 nil 表示从不（任意键还原书页）)
    ---@type integer|nil
    idle_minutes = nil,
  },

  ---Highlight markers.
  ---(划线标记)
  ---@type table
  annotations = {
    ---Also mark each highlight at the end of its line. Off by default: the
    ---underline already says what is marked, and on a wrapped line the marker
    ---lands in the middle of the page.
    ---(同时在行尾标记每条划线。默认关闭：下划线本身已经说明了被标记的位置，而折行后的
    --- 行尾标记会落在页面中间)
    label = false,
    ---Line style a highlight made here is synced to the account with, as the
    ---app shows it: 0 straight, 1 marker, 2 wavy.
    ---(在这里画的划线同步到账号时用的线型，即 App 里看到的样子：0 直线、1 马克笔、2 波浪线)
    ---@type integer
    style = 2,
  },

  ---Highlight the paragraph under the cursor; "screen" highlights only the
  ---screen line the cursor is on, one row of a wrapped paragraph.
  ---(是否高亮光标所在段落；"screen" 只高亮光标所在的那一屏幕行，即折行段落中的一行)
  ---@type boolean|"screen"
  cursorline = false,

  ---Reading palette applied to the chapter window only: one of the palettes
  ---(`:WeReadTheme` lists them), "auto" to follow 'background', or "none" to
  ---keep your colorscheme.
  ---(只作用于章节窗口的阅读配色：某套配色（`:WeReadTheme` 会列出），"auto" 跟随 'background'，
  --- 或 "none" 沿用你的配色)
  ---
  ---Defaults to `paper` (warm rice paper at about 8:1). Set `auto` to follow
  ---'background': `theme_auto` selects its light and dark palettes.
  ---(默认是 `paper`（暖米纸色、约 8:1）。设为 `auto` 时跟随 'background'，
  --- 其浅色和深色配色由 `theme_auto` 决定)
  ---@type string
  theme = "paper",

  ---The palettes `theme = "auto"` chooses between.
  ---(`theme = "auto"` 在哪两套配色之间选)
  theme_auto = {
    light = "paper",
    dark = "night",
  },

  ---Palettes of your own, by name: `{ mine = { bg = "#f4ecd8", fg = "#3b3024" } }`.
  ---Only `bg` and `fg` are needed; every other ink (muted, accent, mark, link,
  ---code) is derived from them and pushed until it is readable, and any of them
  ---may be given to override the derived one.
  ---(你自己的配色，按名字给：`{ mine = { bg = "#f4ecd8", fg = "#3b3024" } }`。只需 `bg` 与 `fg`；
  --- 其余墨色（淡色、强调、标记、链接、代码）都由它们推导，并调到可读为止；任何一项都可以显式
  --- 给出来覆盖推导值)
  ---@type table<string, table>
  palettes = {},

  ---Upload the local position/reading time to WeRead every N seconds. 0 disables it.
  ---(每 N 秒把本地进度与阅读时长回传微信读书，0 表示关闭)
  ---@type integer
  sync_interval = 60,

  ---Upload progress when leaving a chapter buffer.
  ---(离开章节 buffer 时回传进度)
  ---@type boolean
  sync_on_leave = true,

  ---Seconds of cursor stillness before a new position is uploaded. Reading a
  ---place is worth telling the other devices about before the reading-time
  ---interval is up. 0 disables it.
  ---(光标停稳多少秒后上报新位置。读到一个位置，值得在阅读时长间隔到点之前就告诉其它
  --- 设备。0 表示关闭)
  ---@type integer
  sync_debounce = 5,

  ---Pull the service-side position when opening a book (and on BufEnter, on
  ---return from idle, and every sync_pull_interval), so a place left on the
  ---phone continues here. Requires the official Agent API key from :WeReadLogin.
  ---(打开书（以及 BufEnter、空闲回来、每 sync_pull_interval 秒）时拉取服务端位置，让手机上留下的位置在这里继续。
  --- 需要 :WeReadLogin 拿到的官方 Agent API Key)
  ---@type boolean
  sync_pull = true,

  ---Check the service for a newer position from another device every N seconds
  ---while a chapter is open, and follow it. Focus events cover this in a plain
  ---terminal; behind a multiplexer they often never arrive. 0 disables it.
  ---(章节打开时每 N 秒查一次服务端有没有别的设备更新的进度，有就跟过去。普通终端里
  --- 焦点事件就能做到；多路复用器后面焦点事件常常根本不来。0 表示关闭)
  ---@type integer
  sync_pull_interval = 120,

  ---Seconds without a key press after which the reader counts as away: that
  ---time is not reading time, and the next key press asks the service whether
  ---another device moved on.
  ---(多少秒没有按键就算读者离开：这段时间不计阅读时长，下一次按键时还会问服务端有没有
  --- 别的设备往后读了)
  ---@type integer
  sync_idle = 120,

  ---Inline image rendering limits, in terminal cells.
  ---(插图内联渲染上限，单位为终端单元格)
  ---@type table
  image = {
    max_width = 60,
    ---Kept modest on purpose: a tall figure pushes the text off screen.
    ---(刻意克制：太高的插图会把正文挤下去)
    max_height = 14,
    ---Icon replacing the markdown image syntax while reading.
    ---(阅读时替换 markdown 图片语法的图标)
    icon = "⧉",
    ---Download illustrations the chapter links by URL, so they can be drawn inside
    ---the text. Some books ship a resource pack the tarball reader cannot open
    ---(it is a zip), and then the URLs in the markup are the only source.
    ---(下载章节里以 URL 形式给出的插图，才能把它们画在正文中。有些书下发的资源包 tar
    --- 解包器根本打不开（其实是 zip），此时正文里的 URL 就是唯一来源)
    ---@type boolean
    download = true,
  },

  ---HTTP proxy mode: nil inherits the environment, "direct" bypasses every proxy.
  ---Set it to "direct" when the machine's proxy would route domestic traffic abroad.
  ---(代理模式：nil 沿用环境变量，"direct" 强制直连；当机器的代理会把国内流量
  --- 绕到境外时，建议设为 "direct")
  ---@type string|nil
  proxy = nil,

  ---Service root. Only changed by tests, which point it at a local mock server.
  ---(服务根地址；仅测试会改成本地 mock 服务器)
  ---@type string
  base_url = "https://weread.qq.com",

  ---Official Agent API origin or full endpoint url.
  ---(官方 Agent API 的 origin 或完整端点地址)
  ---@type string
  gateway_url = "https://i.weread.qq.com",

  ---`K` on foreign text: a word goes to the dictionaries, a phrase or sentence
  ---(a visual selection) to the sentence translators. Each list is tried in
  ---order until one answers; results are cached in `data_dir/lookup.json`.
  ---See `weread.lookup`.
  ---(外文上的 `K`：单词查词典，短语或句子（可视选区）走句子翻译。每个列表按顺序试，直到
  --- 有一个答出来；结果缓存在 `data_dir/lookup.json`。见 weread.lookup)
  ---@type table
  lookup = {
    ---Dictionaries for a single word: "ecdict" (local, after
    ---`:WeReadDict install`), "youdao" (online, no key).
    ---(查单词用的词典："ecdict"（本地，需 `:WeReadDict install`）、"youdao"（在线，免 key）)
    ---@type string[]
    word = { "ecdict", "youdao" },
    ---Translators for a phrase or sentence, best first: "llm" (an
    ---OpenAI-compatible chat API, by default the Claude Code gateway, see
    ---`lookup.llm`), "transmart" (Tencent, online, no key). Only one answer is
    ---shown: the first that comes back, so a translator after the LLM is a
    ---fallback, used (and marked as such) only when the LLM fails, times out
    ---or cannot be reached.
    ---(翻译短语与句子的服务，好的在前："llm"（OpenAI 兼容的对话接口，默认是 Claude Code 的网关，
    --- 见 lookup.llm）、"transmart"（腾讯交互翻译，在线，免 key）。只显示一份结果：第一个答出来
    --- 的。所以排在大模型后面的服务是兜底，只有大模型失败、超时或连不上时才用，并标明是兜底)
    ---@type string[]
    sentence = { "llm", "transmart" },
    ---Who translates a whole chapter for the 译文 key (`<leader>wy`): "llm"
    ---(the gateway model, paragraph by paragraph, with WeRead's own translation
    ---as the fallback) or "weread" (WeRead's only).
    ---(译文键（<leader>wy）整章翻译由谁来做："llm"（网关大模型逐段翻译，微信读书自己的译文兜底）
    --- 或 "weread"（只用微信读书的）)
    ---@type string
    chapter = "llm",
    ---Models the 译文 key offers for a whole chapter, next to WeRead's own
    ---translation; the one picked is remembered per book. Opus reads better
    ---and takes longer: a batch of 8 paragraphs 6.6 s against the fast
    ---DeepSeek's 3.9 s, measured on the gateway.
    ---(译文键整章翻译时可选的模型，与微信读书自己的译文并列；选中的按书记住。Opus 译得更准、也更慢：
    --- 网关上实测一批 8 段 6.6 秒，快的 DeepSeek 3.9 秒)
    ---@type string[]
    chapter_models = { "claude-opus-5-5", "deepseek-v4-flash" },
    ---Seconds a dictionary or a fast translator may take before the next one is
    ---asked. The LLM has its own, `lookup.llm.timeout`.
    ---(词典或快速翻译最多等几秒，超时就问下一个。大模型有自己的 lookup.llm.timeout)
    timeout = 3,
    ---OpenAI-compatible chat completions endpoint. By default it is the gateway
    ---Claude Code is configured with: `$ANTHROPIC_BASE_URL` and
    ---`$ANTHROPIC_AUTH_TOKEN`, or the `env` block of `~/.claude/settings.json`
    ---when nvim was started without them. Setting `base_url` points it
    ---elsewhere; the key then comes from `api_key_env` (or `api_key`).
    ---(OpenAI 兼容的 chat completions 接口。默认就是 Claude Code 配置的网关：
    --- `$ANTHROPIC_BASE_URL` 与 `$ANTHROPIC_AUTH_TOKEN`；nvim 启动时没有这两个变量，就读
    --- `~/.claude/settings.json` 的 env 段。写了 base_url 就指向别处，key 改从 api_key_env（或 api_key）读)
    ---@type table
    llm = {
      ---nil: the Claude Code gateway (nil：Claude Code 的网关)
      ---@type string|nil
      base_url = nil,
      ---The gateway's fast DeepSeek: 1-3 s a sentence, measured. "deepseek-v4-pro"
      ---reads a little better and takes 4-7 s (it always reasons first).
      ---(网关里快的 DeepSeek：实测每句 1–3 秒。"deepseek-v4-pro" 译文略好，要 4–7 秒——它总是先推理)
      ---@type string
      model = "deepseek-v4-flash",
      ---@type string|nil nil: $ANTHROPIC_AUTH_TOKEN with the gateway, $OPENAI_API_KEY otherwise
      api_key_env = nil,
      ---@type string|nil
      api_key = nil,
      ---Seconds to wait for the LLM before the fallback answers. The fast
      ---DeepSeek takes 1-3 s a sentence, so 8 s only cuts off a stuck gateway.
      ---(等大模型多少秒，超时就由兜底来答。快的 DeepSeek 每句 1–3 秒，8 秒只会截掉卡住的网关)
      timeout = 8,
      ---Requests the gateway takes at once per user; the rest wait in the plugin
      ---instead of coming back "Concurrency limit exceeded". `K` goes ahead of
      ---chapter translations and exports.
      ---(网关对每个用户同时接受的请求数；其余的在插件里排队，而不是被回「Concurrency limit exceeded」。
      --- K 排在章节翻译与导出前面)
      max_concurrency = 4,
    },
    ---SQLite file built from ECDICT; nil means `data_dir/ecdict.db`.
    ---(由 ECDICT 生成的 SQLite 文件；nil 表示 data_dir/ecdict.db)
    ---@type string|nil
    ecdict_db = nil,
  },

  ---How many thoughts to list per highlight in the chapter summary popup.
  ---A well annotated chapter carries dozens, and a wall of them buries the
  ---highlights; `K` shows all of them for one highlight.
  ---(章节汇总里每条划线最多列几条想法。被划得多的章节动辄几十条，全铺开会把划线本身
  --- 埋掉；想细看某一条按 K)
  ---@type integer
  summary_thoughts = 3,

  ---How chatty the plugin is while reading.
  ---(阅读时插件的唠叨程度)
  ---
  ---"quiet" (default) keeps routine traffic — "resumed book X", "progress
  ---uploaded", "annotations refreshed" — out of the message area: none of it needs
  ---the reader's attention, and every page turn would otherwise pop a notification
  ---in the middle of the page. Warnings and errors are always shown, and
  ---"all" restores the routine messages for anyone who wants them.
  ---("quiet"（默认）把例行消息——「续读《X》」「已回传进度」「已刷新划线」——挡在消息区之外：
  --- 这些都不需要读者关注，否则每次翻页都会在页面中间弹一个提示。警告与错误始终显示；
  --- 想看例行消息就设 "all")
  ---@type string
  notify = "quiet",

  ---Register the default buffer-local keymaps in chapter buffers.
  ---(在章节 buffer 注册默认快捷键)
  ---@type boolean
  keymaps = true,

  ---Write a debug log to `data_dir/weread.log`.
  ---(把调试日志写到 data_dir/weread.log)
  ---@type boolean
  debug = false,

  ---The EPUB export (:WeReadEpub). See `weread.epub`.
  ---(EPUB 导出 :WeReadEpub。见 weread.epub)
  ---@type table
  epub = {
    ---Typeset the whole book with one stylesheet (`weread.epub_style`) instead
    ---of the book's own: the same face, size, leading and indent on every
    ---page, and no boxes around sidebars, tips or labels. `false` keeps the
    ---publisher's stylesheets.
    ---(用一份样式表（weread.epub_style）统一排版整本书，而不是书自己的：每页同样的字体、字号、
    --- 行距和缩进，侧栏、提示、标签不带框。false 保留出版社的样式表)
    ---@type boolean
    restyle = true,
  },
}

local state = {
  opts = vim.deepcopy(M.defaults),
  configured = false,
  theme_pinned = false,
  given = {},
}

-- Types a key accepts when the default alone cannot say: the default is nil, or
-- the key takes more than one type. Keyed by dotted path.
-- (默认值本身说不清楚时，某个键接受的类型：默认值是 nil，或者该键接受多种类型。按点分路径索引)
local ACCEPTED_TYPES = {
  data_dir = { "string" },
  proxy = { "string" },
  cursorline = { "boolean", "string" },
  ["layout.line_height"] = { "number" },
  ["layout.heading_icons"] = { "table", "boolean" },
  ["lookup.llm.base_url"] = { "string" },
  ["lookup.llm.api_key_env"] = { "string" },
  ["lookup.llm.api_key"] = { "string" },
  ["lookup.ecdict_db"] = { "string" },
  ["animations.idle_minutes"] = { "number" },
  palettes = { "table" },
}

-- Keys earlier versions documented and later versions dropped. Old configs still
-- carry them, so they are skipped quietly: telling the user off about a key the
-- plugin itself used to advertise would read as a typo warning, which it is not.
-- (早期版本写进文档、后来删掉的键。旧配置里还留着它们，所以静默跳过：对一个插件自己
--  曾经宣传过的键报“未知”，会被读成拼写警告，而事实并非如此)
local RETIRED_KEYS = {
  ["paragraph.chapter_title"] = true, -- the repeated title is now decided by xhtml.repeats_title(是否重复标题由 xhtml.repeats_title 判断)
  ["paragraph.block_gap"] = true,
  font = true, -- the font is chosen with :WeReadFont and kept in prefs(字体用 :WeReadFont 选，存在 prefs 里)
  ["lookup.refine"] = true, -- the LLM answers first now, nothing is refined afterwards(现在大模型先答，不再事后润色)
}

-- Hosts that may be reached over plain http (the test suite's mock server).
-- (允许走明文 http 的主机：测试用的 mock 服务器)
local LOCAL_HOSTS = { ["127.0.0.1"] = true, localhost = true, ["::1"] = true }

-- Permission masks, spelled out because LuaJIT has no octal literals: 0777 and 0700.
-- (权限掩码，即 0777 与 0700；LuaJIT 没有八进制字面量，因此这样写)
local PERMISSION_BITS = tonumber("777", 8)
local OWNER_BITS = tonumber("700", 8)

---Copy the user's options, dropping what has the wrong shape. A mistyped table
---key would otherwise replace a whole default table (`layout = false`).
---(复制用户给的选项，丢掉形状不对的部分。否则写错类型的表键会把整张默认表替换掉，
--- 例如 `layout = false`)
---@param defaults table
---@param given table
---@param prefix string dotted path of `given`, "" at the top(`given` 的点分路径，顶层为空串)
---@param problems { unknown: string[], types: string[] }
---@return table clean
local function sanitize(defaults, given, prefix, problems)
  local clean = {}
  for key, value in pairs(given) do
    local path = prefix .. tostring(key)
    local default = defaults[key]
    local accepted = ACCEPTED_TYPES[path]
    if not accepted and default ~= nil then
      accepted = { type(default) }
    end
    if RETIRED_KEYS[path] then
      -- dropped on purpose, nothing to report(有意丢弃，无需提示)
    elseif not accepted then
      problems.unknown[#problems.unknown + 1] = path
    elseif not vim.tbl_contains(accepted, type(value)) then
      problems.types[#problems.types + 1] = string.format(
        "weread: 配置项 %s 应为 %s，实际是 %s，已忽略并沿用默认值",
        path,
        table.concat(accepted, "/"),
        type(value)
      )
    elseif type(default) == "table" and vim.islist(default) then
      -- a list is one value: its entries are not keys to check one by one
      -- (列表是一个整体值：它的元素不是要逐个检查的键)
      clean[key] = value
    elseif type(default) == "table" and type(value) == "table" then
      clean[key] = sanitize(default, value, path .. ".", problems)
    else
      clean[key] = value
    end
  end
  return clean
end

---Make a data directory setting absolute, with `~` and `$VAR` expanded.
---(把数据目录设置展开 `~` / `$VAR` 并绝对化)
---@param path string
---@return string
local function absolute_dir(path)
  local absolute = vim.fn.fnamemodify(vim.fs.normalize(path), ":p")
  -- ":p" appends a slash to directories that exist; paths are joined with "/"
  -- (":p" 会给已存在的目录补尾斜杠；路径拼接时自己带 "/")
  if #absolute > 1 then
    absolute = (absolute:gsub("/+$", ""))
  end
  return absolute
end

---Whether a url would send credentials over the network in the clear.
---(这个地址是否会把凭据明文发上网络)
---@param url string
---@return boolean
local function is_insecure_remote(url)
  local scheme, rest = url:match("^(%a[%w+.-]*)://(.*)$")
  if scheme and scheme:lower() == "https" then
    return false
  end
  local authority = (rest or url):match("^([^/?#]*)")
  authority = authority:match("@(.*)$") or authority
  local host = authority:match("^%[([^%]]+)%]") or authority:match("^([^:]*)")
  return not LOCAL_HOSTS[host:lower()]
end

---Tell the user about everything setup() had to ignore.
---(把 setup() 不得不忽略的东西告诉用户)
---@param problems { unknown: string[], types: string[] }
local function report(problems)
  if #problems.unknown > 0 then
    table.sort(problems.unknown)
    vim.notify(
      "weread: 未知的配置项：" .. table.concat(problems.unknown, "、") .. "（已忽略，请检查拼写）",
      vim.log.levels.WARN
    )
  end
  for _, message in ipairs(problems.types) do
    vim.notify(message, vim.log.levels.WARN)
  end
end

---@param opts table|nil
function M.setup(opts)
  local problems = { unknown = {}, types = {} }
  local given = opts
  if given ~= nil and type(given) ~= "table" then
    problems.types[1] = "weread: setup() 的参数应为 table，实际是 " .. type(given) .. "，已忽略"
    given = nil
  end
  local clean = sanitize(M.defaults, given or {}, "", problems)
  if clean.data_dir == "" then
    clean.data_dir = nil
    problems.types[#problems.types + 1] = "weread: 配置项 data_dir 不能为空串，已忽略并沿用默认值"
  end
  report(problems)

  state.opts = vim.tbl_deep_extend("force", vim.deepcopy(M.defaults), clean)
  if state.opts.data_dir then
    state.opts.data_dir = absolute_dir(state.opts.data_dir)
  end
  for _, key in ipairs({ "base_url", "gateway_url" }) do
    local url = state.opts[key]
    if is_insecure_remote(url) then
      vim.notify(
        string.format("weread: %s 不是 https（%s），登录凭据会以明文传输；只有本机测试才应该这样配置", key, url),
        vim.log.levels.WARN
      )
    end
  end
  -- the LLM gets a Bearer key: over plain http it would travel in the clear.
  -- Only an address written here is checked; the Claude Code gateway is the
  -- user's own setting, already trusted with the same key.
  -- (大模型要带 Bearer key：走明文 http 就是裸奔。只检查这里写的地址；Claude Code 的网关是用户
  --  自己的设置，同一把 key 早已交给它)
  local llm_url = (((clean.lookup or {}).llm) or {}).base_url
  if type(llm_url) == "string" and is_insecure_remote(llm_url) then
    vim.notify(
      string.format("weread: lookup.llm.base_url 不是 https（%s），API key 会以明文传输", llm_url),
      vim.log.levels.WARN
    )
  end
  state.configured = true
  state.theme_pinned = clean.theme ~= nil
  state.given = clean
  return state.opts
end

---Whether setup() named a theme explicitly.
---(setup() 是否显式指定了主题)
---@return boolean
function M.theme_pinned()
  return state.theme_pinned
end

---Whether setup() set a key explicitly, by dotted path ("layout.page_chars").
---A choice made at runtime only fills in for keys the config leaves alone.
---(setup() 是否显式设置了某个键，按点分路径。运行时做的选择只在配置没写的键上补位)
---@param path string
---@return boolean
function M.pinned(path)
  local node = state.given
  for part in path:gmatch("[^.]+") do
    if type(node) ~= "table" then
      return false
    end
    node = node[part]
  end
  return node ~= nil
end

---@return table
function M.get()
  return state.opts
end

---Web origin (no trailing slash) every cookie-authenticated request is built from.
---The defaults table always carries a value, so there is no second literal here.
---(网页端 origin（不带尾斜杠），所有 cookie 鉴权请求都由它拼出；defaults 恒有值，
--- 这里不再另写一份字面量)
---@return string
function M.web_origin()
  local origin = (state.opts.base_url or M.defaults.base_url):gsub("/+$", "")
  return origin
end

---@return string
function M.data_dir()
  return state.opts.data_dir or (vim.fn.stdpath("data") .. "/weread")
end

---@param ... string
---@return string
function M.path(...)
  return table.concat({ M.data_dir(), ... }, "/")
end

---Create the directory tree the plugin writes into.
---(创建插件写入所需的目录树)
---@return string data_dir
function M.ensure_dirs()
  local root = M.data_dir()
  for _, dir in ipairs({ root, root .. "/books", root .. "/tmp" }) do
    local ok, err = pcall(vim.fn.mkdir, dir, "p")
    if not ok then
      error(string.format("weread: 无法创建数据目录 %s（可在 setup 里改 data_dir）：%s", dir, tostring(err)))
    end
  end
  -- Credentials and cookies live here: keep other users out. Only the group and
  -- other bits are taken away; the owner's bits are never touched, so a directory
  -- the user made read-only stays that way. A failure is only logged (a
  -- filesystem without modes must not stop the plugin).
  -- (凭据与 cookie 都在这里：挡住其他用户。只收回 group/other 位，不动属主位，因此用户设成
  --  只读的目录仍是只读。失败只记日志，不支持权限位的文件系统不该让插件起不来)
  for _, dir in ipairs({ root, root .. "/tmp" }) do
    local stat = vim.uv.fs_stat(dir)
    local current = stat and bit.band(stat.mode, PERMISSION_BITS)
    local wanted = current and bit.band(current, OWNER_BITS)
    if current and wanted ~= current then
      local ok, err = vim.uv.fs_chmod(dir, wanted)
      if not ok then
        log.warn("chmod %o %s failed: %s", wanted, dir, tostring(err))
      end
    end
  end
  return root
end

return M
