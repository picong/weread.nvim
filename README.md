# weread.nvim

在 Neovim 里读微信读书：扫码登录、书架/搜索、章节正文、插图内联渲染、阅读进度回传、划线与想法。

> **免责声明**：本项目仅供个人学习与个人阅读使用，只访问你自己账号有权阅读的内容。请遵守微信读书的用户协议与相关法律法规，不要用于批量导出或再分发受版权保护的内容。

## 功能状态

| 模块 | 状态 |
| --- | --- |
| 协议层（`_e()` / 签名 / payload 构造） | ✅ 已知向量单测覆盖 |
| HTTP 层（curl + cookie jar + 代理开关） | ✅ |
| 扫码登录（含 4 位 OTP）、凭据持久化、cookie 续期 | ✅ |
| 内容层（目录 / 分片解码 / tar 图片解包 / 缓存） | ✅ |
| XHTML → Markdown 渲染器 + 划线定位用 offset map | ✅ |
| 阅读器（一章一 buffer、目录、跳章、后台预取、位置记忆） | ✅ |
| 插图内联渲染（自驱 snacks placement，不依赖 treesitter 注入）+ 浮窗放大 | ✅ |
| 阅读主题（13 套由亮到暗，可自定义；auto 跟随明暗；仅作用于章节窗口） | ✅ |
| 版心排版（居中文本列 26 字/行、标点禁则、中西文留白、CSS 居中/小字/配色还原） | ✅ |
| 阅读外壳（winbar 进度、藏状态栏与光标、章末续章、滚轮一行） | ✅ |
| 阅读字体（微信读书字体目录 + 按需下载 + 本机字体；章节内临时切换，离开恢复） | ✅ |
| 书架 / 搜索 / 书籍信息（官方 Agent API） | ✅ |
| 书架预览：评分 · 热门点评 · 读到哪 · 完整目录（单击或 Alt-w 进预览回车，直接打开该章）；自己上传的书（书城无记载）只看目录 | ✅ |
| 阅读进度与时长回传 | ✅ |
| 阅读统计（周/月/年/全部：时长、日历热力图、时段偏好、读得最久的书） | ✅ |
| 本地书签、书内搜索（已下载章节）、一键速隐 | ✅ |
| 热门划线按热度分三档（本章最热的为实线强调色）；`K` 同时拉取热门划线下别人的想法 | ✅ |
| 笔记导出（Markdown / quickfix） | ✅ |
| 书架预览点评筛选（`Alt-r`：全部 / 推荐 / 一般 / 不行 / 最新） | ✅ |
| 双向进度同步（停稳即报、退出补发、回焦拉取并跳转） | ✅ |
| 划线与想法（看图：我的划线、热门划线、划线下的想法） | ✅ |
| 自己画线（同步为 App 里的波浪线）、写想法、取消划线（都走阅读器自己的接口） | ✅ |
| 公众号（MP_WXS_*）文章阅读 | ❌ 未实现（接口与普通书完全不同） |
| 整书导出 EPUB | ❌ 未实现（当前方向是原生阅读器） |

## 依赖

| 依赖 | 用途 | 必需 |
| --- | --- | --- |
| Neovim >= 0.10 | `vim.system`、`vim.fs`、`vim.uv` | ✅ |
| `curl` | 所有 HTTP 请求（cookie jar、重定向、TLS） | ✅ |
| `qrencode` | 生成登录二维码（支持图片的终端显示 PNG，否则用半块字符黑白绘制） | 扫码登录 |
| fontconfig（`fc-list` / `fc-scan` / `fc-cache`） | 列出本机字体、登记下载的微信读书字体 | 阅读字体 |
| `unzip` | 解压微信读书字体的 ZIP | 下载字体 |
| `kitten`（kitty 自带） | 阅读时临时切换 kitty 字体 | kitty 阅读字体 |
| `snacks.nvim`（`image` 模块） | 插图内联渲染与浮窗放大 | 图片渲染 |
| kitty / ghostty | kitty graphics protocol | 图片渲染 |
| `magick`（ImageMagick） | snacks 转换非 PNG 图片 | 按需 |

`:checkhealth weread` 会逐项检查依赖、终端图片能力、凭据与数据目录。

## 安装（lazy.nvim）

```lua
{
  dir = vim.fn.expand("~/projects/weread.nvim"),
  name = "weread.nvim",
  dependencies = { "folke/snacks.nvim" },
  cmd = {
    "WeReadLogin", "WeReadLogout", "WeRead", "WeReadSearch", "WeReadOpen", "WeReadResume",
    "WeReadToc", "WeReadStats", "WeReadHide", "WeReadBookmarks", "WeReadBookmark",
    "WeReadFind", "WeReadExport", "WeReadEpub", "WeReadNext", "WeReadPrev", "WeReadChapter",
    "WeReadRefresh", "WeReadSync", "WeReadAnnotations", "WeReadHighlight", "WeReadUnhighlight",
    "WeReadNote", "WeReadDeleteNote", "WeReadTranslate", "WeReadZone", "WeReadSprites",
    "WeReadTrophy", "WeReadTheme", "WeReadWidth", "WeReadDict", "WeReadFont", "WeReadLog",
  },
  opts = {
    layout = { page_chars = 26 }, -- 居中版心：一行 26 个汉字（0 = 用满窗口）
    sync_interval = 60,
    image = { max_width = 60, max_height = 14 },
    proxy = nil, -- "direct" 可强制绕过环境代理
  },
  config = function(_, opts)
    require("weread").setup(opts)
  end,
}
```

图片渲染需要 `snacks.nvim` 的 image 模块（**插件的插图由自己驱动 placement 渲染**，
不依赖 markdown 的 treesitter 注入；把 `doc.inline` 关掉可避免重复渲染）：

```lua
{
  "folke/snacks.nvim",
  opts = {
    image = {
      enabled = true,
      doc = { inline = false, max_width = 60, max_height = 14 },
    },
  },
}
```

若 `render-markdown.nvim` 的渲染与内联插图冲突，可在其配置里对阅读 buffer 关闭：

```lua
require("render-markdown").setup({
  enabled = function()
    return not vim.b.weread_book -- weread 章节 buffer 会置位这个变量
  end,
})
```

## 前置条件：开通「微信读书 Skill」

扫码登录成功后插件还要取一个长期有效的官方 API Key（书架/搜索/划线/进度读都靠它）。
手机打开 **微信读书 App → 我 → 设置 → 微信读书 Skill → 获取 API Key** 即可开通；
没有开通时登录会明确报错并提示这一步。

登录窗口底部显示状态与倒计时（二维码 5 分钟有效）。窗口内按键：`r` 换一张新二维码
（过期后窗口保留，按 `r` 原地刷新），`y` 复制确认链接（可发到手机在微信内打开），
`q` / `<Esc>` 取消。

## 命令

| 命令 | 说明 |
| --- | --- |
| `:WeReadLogin[!]` | 扫码登录（`!` 先清除旧凭据） |
| `:WeReadLogout` | 退出登录并清除本地凭据 |
| `:WeRead [关键词]` | 书架选择器（高亮即预览：评分 / 热门点评 / 读到哪 / 完整目录，目录行可单击或回车直接打开该章；网络数据懒加载并缓存）；带关键词则搜索书城 |
| `:WeReadSearch <关键词>` | 搜索书城（关键词必填，等价于 `:WeRead <关键词>`） |
| `:WeReadOpen [bookId/书名/URL]` | 打开书（留空则续读上次那本） |
| `:WeReadResume` | 继续上次阅读 |
| `:WeReadToc` | 目录选择器（打开即停在正在读的章节；层级缩进、右侧字数、已读调暗；预览给出本章字数与阅读时长、读完到全书几成，已下载的章节附开头正文，「部」列出其下各节） |
| `:WeReadStats [week\|month\|year\|all]` | 阅读统计：总时长、日均、比上期增减、月度日历热力图、24 小时时段分布、读得最久的书与分类；窗口内 `w/m/y/a` 切周期，`[`/`]`（或 `h`/`l`）翻上一期/下一期 |
| `:WeReadBookmark` / `:WeReadBookmarks` | 在光标行加 / 删书签；书签列表（按书中顺序，回车跳回） |
| `:WeReadFind [关键词]` | 书内搜索（只搜已下载到本地的章节，不会为搜索去下载整本书） |
| `:WeReadHide` | 速隐：章节窗口换成你上一个普通 buffer、停止计时；再执行一次回到原章节 |
| `:WeReadExport [qf\|路径]` | 导出本书全部划线与想法：留空写成 Markdown（`data_dir/exports/书名.md`，按章节分组、原文作引用、想法排在下面）；`qf` 放进 quickfix，回车在阅读器里打开对应章节并定位 |
| `:WeReadNext` / `:WeReadPrev` | 下一章 / 上一章 |
| `:WeReadChapter <n>` | 跳到第 n 章（按可读章节计数，封面等零字数条目跳过） |
| `:WeReadRefresh` | 重新抓取当前章节 |
| `:WeReadSync` | 立即把进度与时长回传微信读书 |
| `:WeReadAnnotations[!]` | 本章划线与想法汇总（`!` 重新拉取） |
| `:WeReadHighlight` | 给当前行画线（可带行范围 `:1,3WeReadHighlight`） |
| `:WeReadEpub [bilingual] [cached] [local] [模型] [路径]` | 把整本书连同大模型译文导出成 EPUB 并自动传到你的微信读书书架：没下载、没翻译的章节先下载翻译（默认只有译文，`bilingual` 为双语，`cached` 只用已有的，`local` 不上传，`upload` 只上传上次的导出，`status` 看进度，`stop` 停止） |
| `:WeReadTranslate [on\|off\|only]` | 译文开关（留空切换），同 `<leader>wy`；`only` 只看译文 / 回到原文，同 `<leader>wY` |
| `:WeReadUnhighlight[!]` | 取消划线，账号里同步删除（`!` 清空本章在这里画的划线，也可带行范围） |
| `:WeReadNote [内容]` | 给光标处的划线写想法（不带参数则打开输入框） |
| `:WeReadDeleteNote` | 删除我在光标处划线下写的想法 |
| `:WeReadLog` | 查看运行日志 |
| `:WeReadTheme[!] [名字\|auto\|none\|next\|prev\|global]` | 阅读主题：留空打开选择器（移动即试用）；`next`/`prev` 由亮到暗轮换；`!` 只给这本书，`global` 让这本书跟随全局 |
| `:WeReadZone [rain\|life\|fire]` | 拿当前这一页玩一会儿：字落如雨 / 生命游戏 / 像素壁炉，任意键回到书页 |
| `:WeReadTrophy` | 这本书的读完卡片（`s` 存成 Markdown） |
| `:WeReadSprites` | 把所有像素小画依次放一遍 |
| `:WeReadDict [status\|install [镜像]\|build <csv>]` | 离线英汉词典 ECDICT：`install` 下载（约 66MB）并导入成 SQLite；`build` 用你已下载的 `ecdict.csv`；`status` 看是否就绪 |
| `:WeReadWidth [字数\|+\|-]` | 每行字数：留空查看，`+`/`-` 加宽/收窄两字，数字直接指定（12–60）；本章按光标所在句子重排，选择会被记住（配置里写了 `page_chars` 则重启后以配置为准） |
| `:WeReadFont` | 选择阅读字体：自动下载、保存并刷新当前章节；选择「跟随终端」可关闭。kitty 未启用远程控制时自动启用。 |
| `:checkhealth weread` | 自检 |

## 章节 buffer 内的快捷键

| 键 | 说明 |
| --- | --- |
| `]c` / `[c` | 下一章 / 上一章 |
| `]t` / `[t` | 下一个（更暗）/ 上一个（更亮）阅读主题 |
| `zz` | 光标所在行居中（分页模式下以它为中心重新排这一页，之后从这里接着翻页；`{count}zz` 居中第 count 行） |
| `+` / `-` | 每行加宽 / 收窄两个字（`3+` 一次加六个），同 `:WeReadWidth` |
| `<leader>wt` | 目录 |
| `<leader>wo` | 浮窗放大查看光标处的插图 |
| `K` | **翻译 / 看想法**：光标在英文单词上按 `K`，在光标旁弹出释义（音标、词性、原形）；光标在划线上时先问你「翻译」还是「查看划线的想法」（划线里没有外文就直接看想法）；在脚注标记上则弹出注释。弹窗开着时再按 `K` 进入弹窗（可滚动、复制），`q` 关闭，光标一动自动关。详见下面「查词与翻译」 |
| `K`（可视模式） | 翻译选中的短语或句子（跨行选也行，硬换行会被接回去） |
| 想法面板 | 翻页取完这条划线下所有读者的想法，按卡片排列（作者、♥ 点赞、时间 + 全文）。面板内 `s` 切换按点赞/按时间，`]]` `[[` 在想法间跳转，`<Tab>` / `<S-Tab>` 切到同一行的下一条 / 上一条划线，`c` 写想法，`d` 删除我的想法，`q` 关闭。自己上传的书（`CB_` 开头）没有其他读者的想法 |
| `]f` / `[f` | 下一个 / 上一个脚注 |
| `<leader>wa` | 本章划线与想法汇总 |
| `<leader>wy` | 译文：外文书一键全文翻译，译文排在每段原文下方；打开时弹窗选 Claude Opus 5.5、DeepSeek 或微信读书译文（按书记住，上次选的排第一）；大模型失败再用微信读书译文兜底；再按一次收起 |
| `<leader>wY` | 只看译文：藏起原文，页面上只剩译文（还没译就先译）；再按一次关掉译文，回到原文 |
| `<leader>ws` | 立即回传进度 |
| `<leader>wm` | 在光标行加书签（行尾显示 🔖），再按一次删除 |
| `<leader>wk` | 书签列表 |
| `<leader>wf` | 书内搜索 |
| `<leader>wx` | 速隐（老板键）：一键切回上一个普通 buffer，阅读计时随之停止；`:WeReadHide` 回来 |
| `<leader>wr` | 重新抓取本章 |
| `<Right>` / `<PageDown>` / `<C-f>` / `<C-d>` / `<C-j>` / 滚轮下 | 下一页（最后一页再翻 = 下一章） |
| `<Left>` / `<PageUp>` / `<C-b>` / `<C-u>` / `<C-k>` / 滚轮上 | 上一页（第一页再翻 = 上一章的最后一页） |
| `<Space>` / `<S-Space>` | 下一页 / 上一页（`<Space>` 只在 leader 不是空格时映射；`<S-Space>` 需要终端支持 kitty 键盘协议） |
| `j` / `k` | 下一行 / 上一行（在页内移动光标；走出页底/页顶就翻页） |
| `<leader>wh` | 划线：可视模式给选中文字划线，普通模式给光标所在整行划线 |
| `<leader>wc` | 写想法：光标处有划线就写在那条上；可视模式给选区写（会先补一条划线） |
| `<leader>wd` | 取消划线：光标处我的划线（账号里同步删除）；可视模式删掉与选区重叠的、在这里画的划线 |

`layout.page_mode = "scroll"` 回到连续滚动：那时 `j/k/<C-f>/<C-b>/<C-j>/<C-k>/<C-d>/<C-u>/<C-e>/<C-y>`/滚轮
按原来的方式滚动，滑到章末继续滑进入下一章。

这里刻意占用了 `<leader>w` 前缀（LazyVim 的窗口组），但只在章节 buffer 内生效。

## 配置

```lua
require("weread").setup({
  -- 排版：紧凑（段间不留空行）+ 首行缩进两格，像中文书那样
  paragraph = { compact = true, indent = "　　", gap = "compact" },
  -- 版面：居中文本列 26 字/行 + 阅读外壳（详见下面「版面与观感」）
  layout = {
    page_chars = 26,          -- 正文列宽（汉字数），0 = 用满窗口
    adaptive = false,         -- true = 随窗口宽度浮动
    auto_space = true,        -- 中西文之间自动留一格
    statusline = "off",       -- off = 藏起状态栏（页码在页脚）/ window / keep
    cursor = "block",         -- 普通模式光标是强调色方块；"bar" 细竖线 / "normal" 不动 / "hidden" 隐藏
    page_mode = "page",       -- page = 整屏翻页 + 页脚页码；scroll = 连续滚动
    mousescroll = "ver:1,hor:1", -- scroll 模式下滚轮每格几行
    auto_next = true,         -- 章末继续往下就进下一章
    line_height = nil,        -- 阅读时的行高（如 140），离开章节恢复；nil = 不动终端设置
    heading_icons = nil,      -- 标题前的图标（每级一个）；nil = 用 markdown 渲染器那套，false = 不画
  },
  annotations = { label = false, style = 2 }, -- label: 行尾标记；style: 同步到 App 的线型（0 直线 1 马克笔 2 波浪线）
  notify = "quiet",         -- quiet = 例行消息不弹（续读/回传/刷新）；"all" = 全弹
  text_width = 0,           -- >0 会在正文里画一条 colorcolumn 竖线（默认关）
  cursorline = false,       -- true 高亮整个光标段落；"screen" 只高亮光标所在的屏幕行
  sync_interval = 60,       -- 阅读时长回传间隔（秒），0 关闭回传
  sync_on_leave = true,     -- 离开章节时结算并回传
  sync_debounce = 5,        -- 光标停稳 N 秒后上报新位置（0 关闭）
  sync_pull = true,         -- 拉取其他端的进度并自动跳过去
  sync_pull_interval = 120, -- 章节打开时每 N 秒查一次其他端进度（0 关闭；多路复用器下收不到焦点事件时靠它）
  sync_idle = 120,          -- 多少秒没按键算离开：不计阅读时长，回来后第一次按键会去查其他端进度
  image = {
    max_width = 60,
    max_height = 14,        -- 刻意克制：太高的插图会把正文挤下去
    icon = "⧉",
    download = true,        -- 下载章节里以 URL 给出的插图（资源包打不开的书靠它）
  },
  summary_thoughts = 3,     -- 章节汇总里每条划线最多列几条想法（按 K 看全部）
  lookup = {                -- K 查词与翻译（见「查词与翻译」）
    word = { "ecdict", "youdao" },  -- 单词：本地 ECDICT（装了才用）→ 有道在线词典
    sentence = { "llm", "transmart" }, -- 句子：先问大模型，失败/超时才用腾讯交互翻译兜底
    chapter = "llm",                -- 没选过翻译方式的书：大模型逐段翻，失败用微信读书译文；"weread" = 只用微信读书的
    chapter_models = { "claude-opus-5-5", "deepseek-v4-flash" }, -- <leader>wy 弹窗里可选的模型（加上微信读书译文）
    timeout = 3,                    -- 词典与快速翻译每个最多等几秒，超时换下一个
    llm = {                         -- OpenAI 兼容接口
      base_url = nil,               -- nil = Claude Code 配置的网关（$ANTHROPIC_BASE_URL，没有就读 ~/.claude/settings.json）
      model = "deepseek-v4-flash",  -- 网关里的 DeepSeek；"deepseek-v4-pro" 译文略好但慢（4–7 秒）
      api_key_env = nil,            -- nil = 用网关时读 $ANTHROPIC_AUTH_TOKEN，自定义 base_url 时读 $OPENAI_API_KEY
      timeout = 8,                  -- 等大模型几秒，超时由兜底来答
      max_concurrency = 4,          -- 同时最多几个请求在网关上（本地网关每个用户只放行 4 个）；K 优先
    },
    ecdict_db = nil,                -- 默认 data_dir/ecdict.db
  },
  theme = "paper",          -- 默认纸色主题；也可设为 auto（按 'background' 选）或 none（沿用你的配色）
  theme_auto = { light = "paper", dark = "night" },
  palettes = {},            -- 自定义配色：{ 名字 = { bg = "#...", fg = "#..." } }
  animations = {            -- 像素小动画，见「像素小动画」一节
    enabled = true, loading = true, highlight = true, bookmark = true, theme = true,
    translating = true, sprites = true,
    plant = true, stamp = true, trophy = true, bookworm = false, idle_minutes = nil,
  },
  keymaps = true,           -- 章节 buffer 内注册默认快捷键
  proxy = nil,              -- nil 沿用环境变量，"direct" 强制直连
  base_url = "https://weread.qq.com",
  gateway_url = "https://i.weread.qq.com", -- 也可写完整端点 URL
  data_dir = nil,           -- 默认 stdpath("data")/weread
  debug = false,            -- 写日志到 data_dir/weread.log
})
```

`setup()` 会校验配置：类型不对的项（例如 `layout = false`）、未知的键（多半是拼写错误）会用一条
WARN 提示并忽略，沿用默认值；`data_dir` 里的 `~` 会被展开成绝对路径；`base_url` / `gateway_url`
不是 https（本机 `127.0.0.1` / `localhost` 除外）时会警告，因为登录凭据会以明文传输。
数据目录及其 `tmp/` 会被设成 0700。

### 阅读主题

App 的观感主要来自纸色底与柔和墨色。这些通过 `winhighlight` **只作用于章节窗口**，
其它窗口仍是你的配色方案。默认主题是暖米纸色的 `paper`。设为 `auto` 后，编辑器是浅色背景就用
`paper`，深色就用 `night`（两套由 `theme_auto = { light = ..., dark = ... }` 决定）；此时
`'background'` 变了（换配色方案，或终端上报了新底色）会跟着切。`none` 沿用你的配色方案。

```vim
:WeReadTheme          " 选择器：移动即在正文上试用，回车选定，Esc 还原
:WeReadTheme night    " 直接切换（配置没写 theme 时，下次启动沿用；拼错会提示可选项）
:WeReadTheme next     " 下一个（更暗），prev 为上一个；章节里是 ]t / [t
```

主题由亮到暗排列，`]t`/`[t` 就按这个顺序走。对比度用 APCA 衡量：正文都在 Lc 75 以上，
淡色字、标题、链接在 58 以上（测试会守住）。

| 主题 | 底色 | 文字 | 说明 |
| --- | --- | --- | --- |
| `light` | `#fbfbfb` | `#2f2f2f` | 素白，不带纸色 |
| `eink` | `#ffffff` | `#000000` | 墨水屏：纯黑白，划线靠线型区分 |
| `eink_soft` | `#f7f7f4` | `#111111` | 柔和墨水屏，自发光屏上不刺眼 |
| `dawn` | `#faf4ed` | `#3a3654` | 晨，取自 Rosé Pine Dawn |
| `solarized` | `#fdf6e3` | `#3f5259` | Solarized 浅色，正文墨色加深 |
| `sepia` | `#fbf0d9` | `#5f4b32` | 明亮的米黄，近似 Kindle sepia |
| `gruvbox` | `#fbf1c7` | `#3c3836` | gruvbox 浅色 |
| `paper`（默认） | `#ede4d3` | `#4a4036` | 暖米纸色，对比度约 8:1 |
| `jade` | `#d8e6d2` | `#2e3d32` | 竹青绿底（偏好，没有证据表明绿色护眼） |
| `dusk` | `#3a3c40` | `#e2e0da` | 暮，中灰 |
| `night` | `#23201c` | `#e2d6c0` | 深色暖底，关灯阅读 |
| `dragon` | `#181616` | `#d2d4cf` | 墨龙，近黑，取自 Kanagawa dragon |
| `phosphor` | `#14110a` | `#f7cd70` | 琥珀 CRT，趣味档 |
| `auto` | 按 `'background'` 选 | | |
| `none` | 不改窗口，沿用你的配色 | | |

配置里写了 `theme` 就以配置为准；`:WeReadTheme` 的选择只在没配置时补位（提示里会说明）。

`:WeReadTheme` 的选择器里，光标移到哪一项，打开着的章节就先换成那套配色（不记住），
回车才选定，Esc 回到原来的主题。右侧预览是用该主题画出的一页示范：标题、正文、着重号、我的划线、
热门划线（按热度三档）、引文、代码、脚注都在里面，标题栏写着正文与淡色字的 APCA 对比度；
列表里每项前面的四格色块依次是纸、墨、强调色、标记色。

自定义配色只需给纸色和墨色，其余墨色在 Oklab 里推导，并调到上面的对比度下限为止：

```lua
palettes = {
  mine = { bg = "#f4ecd8", fg = "#3b3024" },                   -- 只给两色
  ink  = { bg = "#fffdf7", fg = "#202020", accent = "#8a1f11" }, -- 任意一项都可显式覆盖
},
```

每本书也可以有自己的主题：`:WeReadTheme! 名字`（或 `:WeReadTheme!` 打开选择器）只改当前这本书，
之后在这本书里按 `]t`/`[t` 也只改它；`:WeReadTheme global` 让它重新跟随全局主题。
书页上的弹窗（统计、目录、想法、查词）也换成同一种纸色，像一张叠在书页上的纸。

代码清单在各主题下用主题自己的一套低饱和语法墨色（关键字、字符串、函数、类型、数字、注释、标点），
不再沿用编辑器配色方案的语法色——那些颜色是按深色背景调的，放到纸色上对比度只有 1.2:1。
每种墨色在对应纸色上的对比度都不低于 4.5（注释 3.5）；墨水屏主题只用黑灰，靠粗体和斜体区分。
表格的竖线与分隔线用主题的淡墨，表头加粗。

### 像素小动画

动画只出现在两种时刻：状态改变的那一下（一秒内结束），或者你不在的时候。书页停稳之后屏幕上不再有任何东西在动，
任意按键立刻停止所有动画。动画画在独立的浮窗或独立命名空间的 extmark 里，不写章节 buffer，也不加虚拟行，
所以分页和划线定位都不受影响。无界面运行时全部关闭；`vim.g.weread_animations = false`
（或 snacks 的 `vim.g.snacks_animate = false`）也会全部关闭。

| 时刻 | 动画 | 开关（`animations.*`） |
| --- | --- | --- |
| 下载章节 | 一本像素书在翻页（等 150 毫秒才出现，缓存里的章节不会闪） | `loading` |
| 划线 | 墨从这段的中间向两端洇开，再干成划线 | `highlight` |
| 加 / 删书签 | 页面右上角垂下 / 抽回一条缎带；行尾标记是一格的 `▚` | `bookmark` |
| 换主题 | 约 200 毫秒的渐变 | `theme` |
| 翻译本章 | 页面右下角一支羽毛笔一行行地写，译完消失；读者照常读，按键不会停它 | `translating` |
| 书内搜索 | 放大镜扫过一行字，写着找到几处 | `sprites` |
| 手动回传进度（`<leader>ws`） | 一架纸飞机滑出去（定时回传不放） | `sprites` |
| 跟上其他端进度 | 手机上的位置跳到书上 | `sprites` |
| 想法发表 | 冒出一个对话气泡 | `sprites` |
| 每一页 | 页脚左侧一条盲文点进度条（半格精度，顶层章节有刻度）；开 `bookworm` 后，条上有只尺蠖，一页一步 | `layout.progress_bar`、`bookworm` |
| 今天读了多久 | winbar 末尾一株植物：种子 → 发芽（5 分钟）→ 长叶（15）→ 开花（30）→ 结果（60），不显示数字；每长一级，角落里的幼苗长一片叶，结果时一只猫蜷起来打盹 | `plant` |
| 读完一章 | 最后一页的页脚盖一个印章，翻页即消失 | `stamp` |
| 读完全书 | 一张卡片：书名、读过的日子、划线数、你自己的一句划线；`s` 存成 Markdown（`:WeReadTrophy` 随时再看） | `trophy` |
| 离开很久 | `idle_minutes` 分钟没有按键，书页上烧起像素壁炉；任意键回来（这一下不会翻页） | `idle_minutes` |

`:WeReadSprites` 把所有像素小画在页面中间依次放一遍。小画都放在正文列右下角、页脚上方，不挡正在读的那一行，颜色取自当前阅读主题。

`:WeReadZone [rain|life|fire]` 拿当前这一页玩一会儿：字落如雨、生命游戏、像素壁炉，任意键回到书页。

植物与 `:WeReadStats` 月视图里的「像素花园」只计真正在读的时间：一页停留 4 秒到 5 分钟之间才算，
开着页面去泡茶不算。没读的日子是空地，不画叉；连续计的是「周」，漏一天不会断。数据存在 `data_dir/journal.json`。

### 阅读字体

终端字体属于整个 kitty，nvim 不能只给一个 buffer 换字形。因此字体按阅读会话临时切换：进入章节时换成选中的字体，离开章节或退出 nvim 时恢复终端原字体。

```vim
:WeReadFont                 " 打开字体选择器
```

选择本机字体会立即刷新当前章节。选择微信读书字体时，插件按需下载、登记并刷新；下次直接复用。选择器第一项「跟随终端」会关闭阅读字体。

kitty 需要远程控制才能即时切换。选择字体后，插件会自动写入并重载 `kitty.conf`：

```
allow_remote_control yes
```

此权限允许同一终端内的程序控制 kitty。非 kitty 终端或 tmux 未传入 `KITTY_LISTEN_ON` 时，字体选择仍会保存，但不能立即应用。GUI 版 nvim 直接设置 `guifont`。

## 版面与观感

阅读页做成「一页书」而不是「缩进的编辑器」：**居中版心 + 行宽 26 字 + 标点禁则 +
书里的居中/小字/配色语义**。全部离线完成——章节源 XHTML 已缓存在本地，改版心宽度只是
重新排一遍（实测 1.4–2.9 ms/章），不联网。

### 版心

```
              程序员修炼之道：通向务实的最高境界（第2版） · 45 需求之坑     62/76 · 85%
                                 　　所谓完美境界，亦非加无可加，而是减无可减……
                                 　　——安托万·德圣埃克絮佩里 《风沙星辰》，1939
                                 　　许多书籍和教程都将采集需求放在项目的早期阶段。
                                 “采集”一词似乎隐喻着，一群快乐的分析师，他们在周遭的
```

- **文本列 26 汉字（52 单元格）居中**，两侧留白。左边距由 `statuscolumn` 实现
  （长行折行后每一屏行都会带上它），右边距来自渲染出的行宽本身。
- 渲染器自己折行，因此**行宽可控**：`layout.page_chars = 26`（0 = 用满窗口，
  `adaptive = true` = 随窗口浮动）。窗口变窄时版心自动夹紧并重排（`VimResized` 防抖 250ms）。
- **标点禁则**：行首不出现 `。，、；：？！）》」』】…`；这类标点改为悬挂出格（最多 4 格），
  `……` 与 `。」` 因此不会被拆开；行尾不留下 `（《「『【`，会连同下一字下移。
- **中西文留白**：`写作O（1）` → `写作 O（1）`，`对10个数字` → `对 10 个数字`；
  书里本来就有的空格不会重复；放不下时由折行本身充当间隔。
- **不切开拉丁词**：`1939`、书名、URL 会整词挪到下一行，只有比版心还长的词才会被切开。

### 中文排版细节

- **孤字不成行**：段落末行不会只剩一个字（标点不算），上一行让出一个字下来。
- **孤行不成页**：分页模式下，段落的最后一行不会单独出现在下一页顶部，前一行会一起带过去。
- **着重号**：终端里中文粗体常常看不出来，所以书里加粗的中文另外画一条点状下划线（中文排版的着重号，
  标点下面不画）；拉丁文仍是粗体。`layout.emphasis_dots = false` 关闭。
- **自适应版心**：`layout.adaptive = true` 时行宽随窗口变化，但夹在每行 17–40 字之间（clreq 给出的正文区间）。
- **配色对比度**：夜间主题墨色提到 APCA Lc ≈ 76（正文基线），各主题的淡色字（脚注、图注、引文）提到 Lc 60 以上。
- 行距只在阅读期间生效：`:WeReadFont 名字 140` 或 `layout.line_height = 140`（kitty 的 `modify_font cell_height`，离开章节恢复）。

### 书籍样式表里的排版语义

真实书的样式表里 `text-align` 出现上百次，以前全被忽略。现在：

| CSS | 阅读时的呈现 |
| --- | --- |
| `text-align: center` / `right`（含 `<center>`） | 该行在版心内居中 / 右对齐（补白是绘制出来的，不占文本列） |
| `font-size: 0.75em`（脚注、图注、引文） | 左右内缩 + 淡色，读起来像小字而不是正文 |
| `color: #c36500`（节标题） | 跟随主题强调色 |
| `text-indent: 0` / `2em` | 覆盖 `paragraph.indent` 默认缩进 |
| `padding-left/right: 2em` | 计入该块的缩进与行宽（外层 `<div>` 的 padding 会传给里面的 `<p>`） |

### 表格：由转换器自己排成真表格

书里的表格在网页上是 `<table>`，单元格里常常还套着 `<p>`。转换器把整张表读完之后自己排版，
每一行屏幕内容都是 buffer 里真实的一行：

- 列宽先按各列内容的自然宽度给；版心放不下时，每列先取最窄（最长的单词，最多 8 个汉字宽），
  剩下的宽度一格一格分给离自然宽度最远的那一列。表格**永远不超出版心**：全屏、分屏都一样，
  和正文对齐在同一列里。
- 单元格按列宽折行，英文按单词断，中文遵守标点禁则（`。` 不起行）。单元格里的 `<p>`、`<br>`
  是这一格里的换行。
- 用 `┌ ┬ ┐ │ ├ ┼ ┤ └ ┴ ┘` 画边框；表头下面一条实线，折成多行的行与行之间一条虚线 `╌`，
  免得一行的结尾读起来像下一行的开头。版心实在太窄时，单元格两侧的补白也会让出来。
- 单元格里的文字和正文一样带着源文偏移：**每一行光标都能停、能选**，可以划线、写想法、`K` 查词。
  跨几行选中一个折行单元格时，划线只画在这一格自己的字下面，不会画到同一行别的列；选中的文字
  从书里按区间读出，不会混进相邻列的内容。
- 表头加粗，边框用主题的淡墨；表题（`<caption>`）排在表格上方。单元格里的粗体、斜体、
  脚注标记照常显示。

```text
┌────────────────┬─────────────────────────────────┐
│ Category       │ Description                     │
├────────────────┼─────────────────────────────────┤
│ Application    │ These are the metrics you get   │
│ metrics        │ from Kafka itself, from the JMX │
│                │ interface.                      │
├╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌┼╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌┤
│ Logs           │ Another type of monitoring data │
```

以前表格是 markdown 管道表格，交给 render-markdown 盖画：窗口放不下的行被画成虚拟行、原来的
那一行被隐藏，光标停不上去（于是有些行选不中），而且按整个窗口而不是版心去折，全屏时一直撑到
窗口右边。排版版本升到 20 之后，已缓存的章节打开时会按新规则自动重排（不联网）。

### 代码清单：语法高亮

`<pre>` 走**逐字**路径：不加首行缩进、不做中西文自动空格、保留源码自己的换行与空格，外围补上
``` 围栏，CRLF 归一化（否则书里用 Windows 换行的清单会显示成一串 `^M`）。

书**不给**清单标语言（抽样三本书 148 份清单，全都只有同一个 CSS 类），而没有语言的围栏不会得到
任何语法高亮——所以语言从内容读（`xhtml.language_of`）：

- 强信号直接定案：shebang、`$` 提示符、能解析的 JSON、整块 `key: value`。
- 其余按行认领投票，胜者要占到非注释行的一半以上；判不出来就**不给语言**（`nil`）。
- 保守是刻意的：把中文散文按 YAML 上色比不着色更糟。抽样实测：bash 33、json 27、markdown 27、
  yaml 8、python 1，其余 52 份是散文/目录树，保持素净。

语言名由**书页自己**写在围栏行上（淡色）。render-markdown 也会写，但它把名字放在围栏上方的
**空行**上，而 `overlay` 类虚拟文本在空行上不会被 nvim 绘制（已实测）——那条路走不通。

语法高亮本身由 treesitter 注入提供（围栏写上 `bash` 就会按 bash 解析）。`:checkhealth weread`
会列出缺哪些语言的 parser——没有 parser 时清单保持单色，语言名仍然显示。

### 传统排版细节

- **段间不留空行**，靠首行缩进两格区分段落。原本每段一个空行时，一屏有一半是空白（实测 10 段占 19 行，现在 10 行）。
- **章节标题不再出现在正文里**（winbar 已经显示书名与章节），每章省两行；若第一个标题与章节标题不一致则保留。
- **图注紧贴插图**（图前留一空行、图后不留），比之前每图省一行；`paragraph.gap = "none"` 可连标题周围的空行也去掉。
- 标题、插图、分隔线周围保留空行；列表项独占一行且不缩进；插图按版心居中、宽度不超过版心。
- 原文自带全角缩进的 TXT 型书籍不会重复缩进。
- **插图行只显示一个图标与图注**：`![图 1-6](/home/…/assets/epub_x.png)` 显示为 `⧉ 图 1-6`，长缓存路径被 conceal 掉，`<leader>wo` 仍可放大查看。
- **划线画在原文上**：我的划线用强调色下划线，热门划线用淡色波浪线（`annotations.label = true` 可让旧的 `▎我的划线` 行尾标记回来）。
- 默认不画 `colorcolumn` 竖线、不高亮整行。

### 阅读外壳

- **整屏翻页**（`layout.page_mode = "page"`，默认）：每页只放完整的行，页面以下的几行被一块
  纸色遮罩盖住，不会露出下一页的半截；下一页从上一页最后一行的下一行开始，不重复、不跳过。
  标题不会孤零零地留在页末，页首不会是空行；插图按真实占用的高度算进页里（插图高度不超过一页）。
- **页脚**：窗口最后一行居中显示「3 / 12」，版心右缘显示「本章剩 9 页 · 约 12 分钟 · 37%」（百分比是当前页在全书的位置，
  按目录字数算）。页脚是浮在窗口上的一行，不依赖状态栏，lualine 之类的插件不会把它冲掉。
  剩余时间按你自己的读速估计：每次往后翻页记下这一页停了多久、页上有多少字，跳过（4 秒内翻走）和走开
  （停留超过 5 分钟）的页不算，其余取偏向最近几页的移动平均，存进偏好跨会话沿用；还没量过时按每分钟
  350 字估。窗口放不下时先省掉剩余时间，页码永远保留。
- **winbar** 只有「书名 · 章节名」与右侧的「第 62 / 76 章」；键位提示从 winbar 撤掉了。
- **底栏**默认藏起来（`layout.statusline = "off"`：进章节窗口时 `laststatus=0` 并关掉 `ruler`
  ——否则光标位置会跑到消息行上；离开全部还原），想要自己的状态栏可以设 `"window"`，
  或在自己的配置里接 `require("weread.shell").lualine_component()`。
- **光标是强调色方块**（`layout.cursor = "block"`）：颜色取自当前阅读主题的强调色，跟着光标读时一眼就能找到；
  可视/插入模式的光标形状不变。`"bar"` 改成文字间的细竖线；`"normal"` 保持编辑器原样；`"hidden"` 整页无光标（靠光标高亮组
  `blend = 100`，Neovim 会发出终端的「隐藏光标」序列）。离开章节窗口自动恢复。
- **连续滚动模式**（`layout.page_mode = "scroll"`）：`j`/`k`/`<C-f>`/`<C-b>`/`<C-d>`/`<C-u>`/`<C-e>`/`<C-y>` 以及**鼠标滚轮**
  都可以；在章末继续往下滚、在章首继续往上滚就翻页（滚轮按「屏幕上还露不露得出新内容」
  判断，不会滚进章末之后的空白）。往回翻会落在**上一章的章末**，从那里接着往上读。
  `layout.auto_next = false` 可关。
- **滚轮一次几行**由 `layout.mousescroll` 控制（默认 1 行），长行按屏行滚动（`smoothscroll`）。
- **阅读位置按源偏移记忆**：重排（换版心宽度、换窗口大小）后仍落在同一句上。

### 行距：只在阅读期间生效

终端行高是终端管的，nvim 改不了。插件在进入章节时连同字体一起把 kitty 的
`modify_font cell_height` 切到 `layout.line_height`（或 `:WeReadFont 名字 140` 当次指定的值），
离开章节或退出时恢复；不写 `kitty.conf`。

`nil`（默认）表示不动你终端现在的设置。GUI 版 nvim 用 `linespace`，同样只在阅读期间生效。

### 写想法

光标停在划线上按 `<leader>wc` 写想法（可视模式直接给选区写，会先补一条划线）；输入框里
**回车**（`<CR>`）或 `<C-s>` 发表，`<C-j>`（`<S-CR>` / `<C-CR>` 亦可）换行，`<Esc>` 取消
（已经写了内容时会先确认，不会静默丢掉）。`K` 里能看到自己的、也能看到别人的想法；
删除自己写的那条：在 `K` 面板里按 `d`，或把光标放在划线上执行 `:WeReadDeleteNote`（都会先确认）。
发表的 review id 会跟本地副本一起保存，所以刚写完、服务端还没返回时也能删；旧版本留下的备注
没有 review id 时，会先按 range 向服务端查一次「哪条是我的」，再删那一条。

写操作走**阅读器自己的接口**（`POST /web/review/add` 与 `/web/review/delete`），用你扫码
登录留下的 cookie 会话——官方 Agent API 是只读的（`/_list` 列出的 17 个接口全是读），
而这两个接口是实测通的：发表返回 `reviewId`，删除返回 `{"succ":1}`。

发表成功后插件**同时在本机留一份副本**：这样 `K` 一定看得到，服务端一时读不回来也不会丢。
如果服务端拒绝了（比如会话过期），内容会存在本地并明确提示，不会静默丢弃。

### 划线：同步到微信读书（波浪线）

选中一段文字按 `<leader>wh` 就能划线（普通模式下按 `<leader>wh` 给整行划线），划线立刻画在
原文上，同时传进微信读书账号，手机 App 里显示为**波浪线**（`annotations.style`：0 直线、
1 马克笔、2 波浪线，默认 2）。`<leader>wd` 取消光标处我的划线，账号里也一起删掉；`K` 看这条
划线下的想法。

划线按**源文 rune 区间**记录（和微信读书自己用的同一套坐标），因此换版心宽度、重新排版、
甚至换窗口大小都不会错位，也不会丢。

- 写接口是 Web 阅读器自己用的 `POST /web/book/addBookmark` / `removeBookmark`，走扫码登录的
  cookie 会话。早先探测一直 400，原因是阅读器发送的 `markText` 要 **Base64 编码**；照做之后
  `/book/bookmarklist` 能按给定 `style` 读回。
- 同步失败（离线、会话过期）时划线留在本机，标为「我的划线（本地）」，**下次打开本章自动补传**；
  以前只存在本地的旧划线也会这样补上去。
- 手机上删掉的划线，下次打开本章时这里也跟着消失。
- 只为挂想法补的记录（写在别人划线上的想法）不会变成你的划线。

### 译文：一键全文翻译

外文书按 `<leader>wy`（或 `:WeReadTranslate`）：每段原文下方排出它的中文译文（淡墨色），标题的译文
仍是标题。再按一次收起，回到纯原文。开关按书记住。

想只读译文就按 `<leader>wY`（或 `:WeReadTranslate only`）：有译文的段落把原文藏起来，页面上只剩
译文；没有译文的内容（插图、表格、代码、还没译到的段落）照常显示。再按一次关掉译文，回到纯原文。
原文只是不显示，buffer 里还在，划线、阅读位置、进度上报照旧按原文计算。双语时按 `<leader>wY`
直接切成只看译文，不重排；只看译文时按 `<leader>wy` 也是关掉译文。

**打开译文时先弹窗选由谁来翻**：`lookup.chapter_models` 里的每个网关模型（默认 `claude-opus-5-5`
和 `deepseek-v4-flash`），以及「微信读书译文」。选中的按书记住，下次弹窗排第一。Opus 译得更准，
也更慢：网关上实测一批 8 段 6.6 秒，DeepSeek 3.9 秒。换了模型，这一章按新模型重新翻译。

选了大模型时（没选过的书按 `lookup.chapter = "llm"` 与下面「查词与翻译」里的模型），
`deepseek-v4-flash`），微信读书自己的译文只做兜底：

- 先翻**你正在看的这一屏**（从页顶开始，约一屏的文字作为第一批），然后向两边扩展（往后两段配往前
  一段），四批并行。实测：这一屏 4–7 秒出现译文；整章 13 段 4 秒，63 段 12.5 秒，166 段约 43 秒。
  每到一批页面重排一次（最多 1.5 秒一次），**停在你正在读的那句话上**，不会跳页。
- 翻译期间页面上只有大模型的译文：还没轮到的段落暂时只有原文，不会和微信读书的译文混在一起。
- 只翻正文段落、标题、列表项、术语表、图注；表格、代码清单、纯数字不送。
- 译文按段存在 `chapters/0003.llm.json`，下次打开不再请求；翻到一半关掉，下次从没译的段落接着翻；
  换了模型则重新翻。开着译文时进下一章会自动翻译，并在你读本章时提前翻好下一章。
- **兜底**：网关没配、连不上，或有段落两次都没译出来时，提示「deepseek-v4-flash 翻译失败（原因），
  改用微信读书译文」，整章换成微信读书的译文。已经译出的段落留着，再按一次 `<leader>wy` 重试时
  只补没译的部分。
- 大模型的译文按微信读书双语章节的格式拼进原文，划线 range 与阅读位置照旧按原文计算，开关译文
  不会让划线错位，也不会让进度跳。
- 不想用大模型：`lookup = { chapter = "weread" }`。
- **带到手机上读**：微信读书账号里存不了我们的译文（它只接受划线和想法），所以用 `:WeReadEpub`
  把整本书导出成 EPUB：先下载没下载的章节、再用这本书选的模型翻译没译完的章节（已完成的不再动，
  中途 `:WeReadEpub stop` 停下，下次接着做），最后写出 EPUB。默认每段原文换成译文（一本中文书），
  `:WeReadEpub bilingual` 则译文排在原文下面；`:WeReadEpub cached` 只用已有的、不下载也不翻译。
  书里带上原书封面（封面地址先问官方 API，再问网页接口；拿不到时导出提示里会写明原因），目录按
  「部 → 章 → 节」分层（层级取自微信读书的目录；目录没有层级的书按 `6.` / `6.1.` 这样的编号推出来），
  书里的插图全部放在原位（导出前把还没下载的插图都下载下来——阅读时只会下载看过的那几页的图；
  实在下载不下来的只留图注文字，导出提示里会说有几张）。目录标题用译文：微信读书没给译名的书，取正文里已译好的标题；拆分文件留下的
  「书名_5」这类假章名不进目录，拆成几个文件的章节合并成一条。书内跨章的链接改指向本书的页面。上传之前会自动检查：每页都是
  合式 XHTML、图片都在书里、目录每一条都能跳到地方；有错就不上传，并列出问题。
  写好后**用当前登录态自动传到你的书架**（和网页「传书」走同一套接口），手机刷新书架就能看到；
  同一个文件不会重复上传，内容变了会作为新书再传一次（旧的要在 App 里手动删）。不想上传加
  `local`，文件留在 `data_dir/exports/`。进度用 `:WeReadEpub status` 看。整本书要花不少时间和
  网关额度（Opus 一章 166 段约 75 秒）；手机上是一本新书，进度和划线跟原书各算各的。
  导出期间照常读书没关系：在页面上关译文、换书只会停掉页面自己发起的翻译，不会停掉导出。某一章
  超过 4 分半（批量请求超时的 3 倍）既没有请求发出也没有回复，就判为失败、记进日志，接着译下一章；
  `:WeReadEpub stop` 一定会立刻停下并清掉任务，之后再执行 `:WeReadEpub` 从停下的地方接着做。
  `status` 里的剩余时间按段落进度估算，10 分钟没有进展会直接提示可能卡住了。
- **网关并发**：所有走网关的请求（K、译文键、整本导出，哪怕几本书同时导出）共用一个闸门，同时最多
  `lookup.llm.max_concurrency` 个（默认 4），其余在插件里排队，不再吃「Concurrency limit
  exceeded」；K 查词和句子翻译插在所有批量请求前面。万一网关仍然回这个错误，照旧等几秒重试。

微信读书自己的译文（兜底时，或 `chapter = "weread"`）：

- 插件请服务端翻译本章与下一章（`POST /web/book/enRead`），轮询到完成后重新取一次本章——翻译过的
  章节由服务端直接以双语返回。同时同步账号里的翻译开关（`/web/reader/toggleTranslate`）。
- 翻译过的章节，服务端**不管开没开译文**都会返回双语内容。插件把译文与随之加入的标记拿掉，
  逐字节还原出原文单独缓存（`chapters/0003.xhtml`），双语版另存（`0003.trans.xhtml`）。
- 这是微信读书的会员功能，只对外文书提供；服务端拒绝时会如实提示。自己上传的书（`CB_` 开头）
  多半没有这份兜底。

### 查词与翻译（K）

光标停在英文单词上按 `K`，释义就在光标旁弹出；可视模式选一段按 `K` 翻译整句。目标是**快**：

弹窗里**只有一份中文**：

- **单词**先查本地 ECDICT（`:WeReadDict install` 之后才有，离线，几毫秒），没装或查不到再问
  有道在线词典（免 key，实测 60–120 ms）。屈折形式标出原形（teeth → 原形 tooth）；它自己的词条
  只是「run 的过去式」这种指路条目时，换成原形的释义，自己有释义时只显示自己的，不叠两组。
  哪本词典都不认识的词（人名、新造词）自动改走句子翻译。
- **短语与句子**只显示大模型的译文。等待时弹窗写着「翻译中…（deepseek-v4-flash）」，实测
  一句 1–2.5 秒出结果。大模型默认用 **Claude Code 配置的网关**：地址取 `$ANTHROPIC_BASE_URL`
  （自动补 `/v1`），key 取 `$ANTHROPIC_AUTH_TOKEN`；nvim 不是从带这些变量的 shell 启动时，
  改读 `~/.claude/settings.json` 的 `env` 段。
- **兜底**：网关连不上、报错或超过 `lookup.llm.timeout`（默认 8 秒）时，改用腾讯交互翻译
  （TranSmart，免 key，150–300 ms），弹窗页脚写「兜底：腾讯交互翻译」，译文下面用淡色注明原因。
  兜底结果不缓存，下次按 `K` 还会先问大模型；大模型失败后 2 分钟内句子直接走兜底，免得每次白等超时。
  没配网关（找不到地址或 key）时，腾讯交互翻译就是正式结果，不标兜底。
- **缓存**：查过的词和句子存在 `data_dir/lookup.json`（最多 3000 条），再查是 0 ms，重启后仍在。
  以前由快速翻译缓存的句子，在大模型可用时会重新问一次大模型。
  同样的查询同时在途只发一个请求。
- 全都失败时弹窗里写明每个服务的失败原因；页脚标出答案来自哪里、用了多久。
- **隐私**：查词和翻译会把选中的文字发给第三方服务（有道、腾讯，或你配置的大模型），不带
  微信读书的 cookie 与任何账号信息。不想联网就把 `lookup.word` 设为 `{ "ecdict" }`、
  `lookup.sentence` 设为 `{}`。
- 有道 `jsonapi` 与腾讯 TranSmart 都是网页端在用的公开接口，没有官方 SLA，哪天改了格式会失效；
  失效时弹窗会提示，换成大模型或本地词典即可。

换别的大模型（key 放在环境变量里，不要写进配置文件）：

```lua
lookup = {
  llm = { base_url = "https://api.deepseek.com/v1", model = "deepseek-chat", api_key_env = "DEEPSEEK_API_KEY" },
},
-- 网关里换模型：lookup = { llm = { model = "deepseek-v4-pro" } }（每句 4–7 秒）
-- 不用大模型、只要快：lookup = { sentence = { "transmart" } }
```

### 提示消息

`notify = "quiet"`（默认）只让**警告与错误**到达消息区。插件自己干活的消息——「续读《X》」
「已回传进度」「已刷新本章划线」——都被挡掉（它们会出现在页面正中，而读者不需要知道）：它们
照旧写进日志（`debug = true` 时在 `data_dir/weread.log`）。**你按键得到的回应**（`:WeReadTheme`、
`:WeReadSync`、写想法、划线失败等）不受影响。想要全都弹就设 `notify = "all"`。

### 插图直接画在正文里

章节里的插图会**下载后画在正文中**（版心居中、宽度不超过版心），不再是只显示一个占位符。

- 下载来源有两种：章节的资源包（解出来的图）和正文里的 URL。**后者才是可靠路径**——有些书在
  `tar` 字段下发的其实是 zip，解包器在里面一无所获（实测某本书 6 张图全丢）。现在正文里的
  URL 会被下载到 `<data>/books/<id>/assets/url-<id>.<ext>`（一次即可，之后走缓存）。
- `<leader>wo` 放大查看同样支持 URL：先下载，再打开。浮窗按插图原比例铺满屏幕。
- **尺寸按像素算，不按文件里的 DPI 算**。书里的插图常标 300/600 DPI，snacks 据此定尺寸，
  于是 480 像素的插图不管给多大地方都只有 25 格宽。现在页面上按像素 1:1 画（不超过版心宽、
  不超过 `max_height`，也不超过它自己的像素，避免发虚）；浮窗放大与光标处的自动预览最多放大
  到 3 倍，再大就只是糊。自动预览的上限仍由 snacks 的 `image.doc.max_width/max_height` 决定。
- 想关掉下载：`image = { download = false }`。

#### kitty + tmux 的坑（一定要设）

在 tmux 里跑 kitty 时，snacks 的探测**不会**把终端标记为支持图形（它自己会打开
`allow-passthrough`，只是漏了这一步），于是插图一张都不画。设这一行即可：

```lua
require("snacks").setup({
  image = { enabled = true, force = true }, -- kitty under tmux: 探测不可信
})
```

`:checkhealth weread` 会在这种情况下说明原因（`inline illustrations are off: kitty + tmux …`）。

### 与装饰插件共存（页面为什么能保持干净）

LazyVim 会给所有 markdown buffer 开 `render-markdown.nvim`，而章节 buffer 就是 markdown：
它的**标题整行边框 + 底色带 + 图标**放在书页上就是一个个黑框（在纯白墨水屏页面上尤其显眼）。

除了它，还有两类东西会把「纸页」变成「编辑器」：

| 来源 | 表现 | 处理 |
| --- | --- | --- |
| `snacks.indent`（LazyVim 默认开） | 每级缩进一条彩色 `│`，书页左边多出一道彩条 | 章节 buffer 里置 `vim.b.snacks_indent = false`（`snacks.scroll` 同理） |
| 配色方案的语法色（`@text.strong`、`@markup.italic` …） | 加粗/斜体的句子在黑白页面上显出蓝色 | 行内强调改用**纸色自己的组**（`WereadStrong` / `WereadItalic` / `WereadUnderline` / `WereadStrike`）绘制，并以 `hl_mode = replace` 压过语法高亮；窗口重映射也把整个 `@markup.*` / `@text.*` 家族纳入 |
| 读过书的窗口 | 换显示别的文件后仍留着纸色配色 | 章节离开窗口时把 `winhighlight` 还回去（`theme.clear_stale`） |

render-markdown 则从两侧处理：

1. **别让它接手**：它在 `FileType` 上 attach，而 attach 同时会注册一批 buffer 级自动命令
   （`CursorMoved` / `WinScrolled` / `ModeChanged` …）。**那些回调不再看 `ignore`** —— 所以
   标记必须在读文件**之前**打好（`bufload` 之前置 `vim.b.weread_book`）：attach 时忽略一次就
   再也不会重画。标记打在 `bufload` 之后，它先 attach 完，然后你每动一下光标它就重画一次，
   黑框于是「偶尔」冒出来。已经 attach 的 buffer 另有它自己的 buffer 级开关
   （`state.get(buf).enabled = false`），由 `weread.decorations` 一并关上；
   章节窗口每次建立时还会清空它的命名空间，并在 150/600/1500ms 后各补扫一次；
2. **推荐在你自己的配置里一刀切**（最干净，只渲染一次的机会都不给它）：

```lua
require("render-markdown").setup({
  -- 章节 buffer 由 weread.nvim 置位 vim.b.weread_book
  ignore = function(buf)
    return vim.b[buf] ~= nil and vim.b[buf].weread_book == true
  end,
})
```

（旧文档里写的 `enabled = function() ... end` 在新版 render-markdown 里已被 `ignore` 取代。）

### 会话续期

微信读书的 web 会话很短命（实测一到两小时），过期后所有 web 请求都会回 `-2012 登录超时`
（正文抓取、写想法都受影响）。现在 HTTP 层会在拿到 `-2012` 时自动调
`POST /web/login/renewal` 续期并**原样重试一次**（同一次请求只续期一次，登录接口本身不触发
续期以免递归）。这条路径有离线测试覆盖。

### 与 App 仍然不同的地方（取舍）

- **搜索跨折点**：正文被折成短行后，`/` 搜一个恰好被断在行尾的短语会搜不到；折点两侧的
  字用 `
` 连接仍可搜到（如 `/减无可
减`）。也可以在缓存 markdown 里 grep。
- **小字只能近似**：终端无法改变单个字符的字号，脚注/引文用「内缩 + 淡色」表达。
- **对齐是逐行的**：`text-align: center` 的段落每行各自居中（与浏览器一致）。

### 标题与正文统一底色

`#` / `##` / `###` 标题原本会带着**配色方案给的背景色**显示（实测你机器上
`@markup.heading.1.markdown` 自带 `bg=#2c314a`，render-markdown 又叠了自己的
`RenderMarkdownH1Bg`），在纸色页面上就是一条条色带。两道处理：

1. **窗口重映射**：阅读窗口的 `winhighlight` 把所有给 markdown 上色的组
   （`@markup.*.markdown` 与 `RenderMarkdown*`，动态枚举而非写死）都换成纸色组，
   背景回到纸色；
2. **阅读器自己画标题行**：`weread.inline` 用一个高优先级 extmark 覆盖整行
   （`WereadHeading` = 墨色 + 纸色底 + 粗体），并把 `#` 标记 conceal 掉。

这样无论配色方案或渲染插件怎么上色，标题就是「加粗的正文」——和 App 里一样。
`theme = "none"` 时 `WereadHeading` 会退回跟随 `Title` 的前景色，不带背景。

### 行内样式保真

书里的强调不总是 `<b>`：更常见的是样式表里的类（`<span class="calibre3">` +
`.calibre3{font-weight:700}`）或行内 `style="font-weight:bold"`。插件会解析章节样式表
（就是分片 `e_2`，已随章节缓存）与行内 style，把它们还原成样式：

| HTML | 阅读时的样子 |
| --- | --- |
| `<b>` `<strong>` / `font-weight:bold\|700` | **真加粗**（颜色方案里的 `Bold`） |
| `<em>` `<i>` / `font-style:italic` | *真斜体*（`Italic`） |
| `<u>` / `text-decoration:underline` | 下划线（markdown 表达不了，用 extmark 绘制） |
| `<del>` `<s>` / `line-through` | 删除线 |
| 有背景色 / `<mark>` | 高亮底色（`WereadMark`） |
| `<sup>` `<sub>` `<small>` `<code>` | 分别用 `WereadSuperscript` / `WereadSubscript` / `WereadSmall` / `WereadCode` |

两点设计取舍：

- 缓存文件里仍然是**标准 markdown**（`**加粗**`），便于 grep 与移植；阅读时由 extmark
  把标记 conceal 掉并施加真实属性，所以屏幕上不会出现星号。
- **标题内不生成强调标记**：markdown 标题本身已经突出，再包一层 `**` 只是徒增待隐藏的
  标记。

`render-markdown.nvim` 的行内 handler 只处理 code span、链接、图片与 `==高亮==`，
并不处理强调，因此这里不存在重复渲染。

### 续读行为

打开一本书时（`:WeRead <书名>` / `:WeReadOpen <bookId>` / `:WeReadResume`）：

1. 先拉一次服务端进度（需要官方 API Key，拉不到就当没有）；
2. 服务端位置比本地的更新（手机上刚读过）→ **跳到那一章那一句**，提示「已跳到其他端进度」；
3. 否则有本地阅读记录 → **直接跳到上次那一章那一行**，并提示「续读《书名》· 章节名」；
4. 两边都没有 → 打开目录让你选。

读着读着切去手机、再切回终端（`FocusGained`，tmux 需开 `set -g focus-events on`）也会拉一次：
手机上读下去的位置会自动跳过来。

阅读位置在离开章节、切换窗口、退出、以及阅读中每 5 秒各记录一次（切章时以新章节为准，不会被上一章覆盖）。想看目录随时 `<leader>wt` 或 `:WeReadToc`。

### 进度同步（双向）

上报走微信读书网页端自己的 `POST /web/book/read`（没有官方写接口，复刻浏览器调用）：

- **位置**：以**源 XHTML 的 rune 偏移**上报（与划线 `range` 同一套坐标，各端通用），
  光标停稳 `sync_debounce` 秒（默认 5）即上报，不必等阅读时长间隔；
- **阅读时长**：每 `sync_interval` 秒结算一次，离开章节、终端失焦时立刻结算；超过 `sync_idle` 秒没按键
  的时间不算阅读；
- **不覆盖其他端**：位置没动时定时器不会再报一遍同一个位置（以前 nvim 停在章节上，每 60 秒就把旧位置
  盖到服务端，手机刚读的进度随即被冲掉）；要结算时长而位置没变时，先查一次远端，远端更新就跟过去、不上报；
- **一次只有一个上报在路上**：切章时上一章与新一章的上报不再赛跑，服务端最后停在最新的位置；
- **会话握手与续期**：每本书每次会话先发一次网页端的 enter 上报；阅读上下文（psvts/token）超过 15 分钟
  先刷新再报；被拒时依次「刷新上下文重试 → 续期 cookie → 再刷新重试」（续期 10 分钟内至多一次）；
- **退出**：`VimLeavePre` 同步补发一次（上限约 4 秒），从侧边栏等非章节窗口 `:qa` 也会上报最后读的那一章；
- **回读（其他端 → nvim）**：经官方 Agent API `/book/getprogress` 拉取远端位置，比本地与最近一次上报
  都新时自动跳过去。拉取时机：打开书、回到章节窗口、终端回焦、离开 `sync_idle` 秒后第一次按键、以及章节
  打开期间每 `sync_pull_interval` 秒一次（终端在 tmux/herdr 等多路复用器里收不到焦点事件时就靠它）。
  跳转只发生在正显示这本书的窗口里：人在代码窗口时先记下，回到书里再跳；拉取途中按过键就推迟到下一次，
  不会把正在读的人拽走。本地位置的时间戳只在位置真的变化时更新，切窗口不会让本地「显得更新」。
  `sync_pull = false` 关闭。

`<leader>ws` / `:WeReadSync` 随时手动回传。

## 数据与凭据

```
$XDG_DATA_HOME/nvim/weread/
├── credentials.json         0600，cookies + 官方 API Key + 账号
├── cookies.txt              0600，curl cookie jar
├── positions.json           阅读位置
├── weread.log               debug = true 时写入
└── books/<bookId>/
    ├── meta.json            书名/作者/format/psvts
    ├── catalog.json
    ├── assets/              tar 解包出的插图
    ├── chapters/0002.xhtml  原始章节（划线定位的基准）
    ├── chapters/0002.md     渲染后的正文
    ├── chapters/0002.map.json  源 rune 偏移 → markdown 位置
    └── annotations/0002.json   划线与想法
```

Cookie 与 API Key 只保存在本地，只发往 `weread.qq.com` / `i.weread.qq.com`。
若机器上的代理会把国内流量绕到境外，建议设 `proxy = "direct"`。

## 测试

```sh
sh scripts/test.sh            # 全量，可从任意目录运行（等价于在仓库根执行 nvim --headless --clean -l tests/run.lua）
sh scripts/test.sh reader     # 只跑文件名含 "reader" 的 spec（环境变量 SPEC=reader 同效）
```

全部离线（本地 mock 服务器 + 真实 curl 进程），不需要账号与网络；用例数量以运行
`sh scripts/test.sh` 的输出为准。
夹具由上游 **python 编码器**生成（`scripts/gen_fixtures.py`），因此 Lua 解码链是与
另一套独立实现对拍，而不是自证。

覆盖内容：协议向量（`_e()`/签名/MD5）、cookie jar、登录状态机（正常/OTP/错码/
未开通 Skill/过期/取消）、内容流水线（服务端验签 + 分片解码 + tar 解包 + 落盘）、
阅读器（buffer/winbar/缓存复用/位置记忆/预取/切章）、进度回传（服务端验证
签名与 `sg`）、划线与想法（归并/定位/弹窗）、插图几何与降级，以及章节缓存的**可写性**
（见下）。

> **一个值得记住的坑**：章节的 map 里有一张「逐行显示属性」表，键是行号、且只有少数几行
> 存在。键全 ≥1 的稀疏表会被 `vim.json.encode` 当成数组并**直接拒绝**
> （`excessively sparse array`），于是整份 map 写不出去——而那两处写入原本没检查返回值，
> 日志照样说「已重排」。丢掉 map 就是丢掉划线偏移、样式与标题记录。现在键以字符串写出
> （`xhtml.json_lines`），`write_json` 会说明失败原因，写入处也会记 warning。有一个用例
> 专门按真实章节的形状（几百行、每十行一条属性、没有 `0` 键）覆盖这条路径。

## 工作原理

微信读书没有公开的正文接口：官方 Agent API（`i.weread.qq.com/api/agent/gateway`，
Bearer API Key）只提供书架、搜索、目录、进度、笔记、统计与公开点评。**章节正文**必须走网页
阅读器链路——密文下发，由前端 JS 解码：

1. 正文分片来自 `POST /web/book/chapter/e_0|e_1|e_3`（EPUB 型）或 `t_0|t_1`（TXT 型），
   请求体需携带签名 `s`、`ps`（阅读器 HTML 里的 `reader.psvts`）与 `pc = _e(ct)`。
2. 响应前 32 字符是余下内容的 MD5，其余部分经「去首字符 → 反转字符交换 → base64url
   → UTF-8 修复」还原。
3. 插图来自 `chapterInfos` 响应中的 `tar` 资源包（POSIX tar，内含无扩展名图片文件，
   按 magic bytes 判类型）。
4. 划线的 `range` 是**原始 HTML 的 rune 偏移（含标签字符）**，因此转换正文时会同时
   产出 offset map，用于把划线落到 markdown 的行列上。

`psvts` 逐章变化，所以每章会先取一次阅读器页面；命中缓存后重开章节完全不联网。

## 许可证

AGPL-3.0-only。部分代码移植自同样以 AGPL-3.0 授权的
[QiuYukang/weread.koplugin](https://github.com/QiuYukang/weread.koplugin)：
`crypto.lua`、`protocol.lua`、`reader_state.lua` 的解码链、`auth.lua` 的登录协议、
`content.lua` 的分片解码、`progress.lua` 的 payload 形状。详见 [NOTICE](NOTICE)。
