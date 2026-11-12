# 阅读页排版与「丝滑感」改造

> 目标：把章节页从「缩进的编辑器」做成「一页书」——居中版心、书页行宽、有行距、
> 划线落在原文上、底栏是进度而不是文件路径。方向已与你确认：**居中版心（硬换行）**、
> **26 字/行**、**终端层行距**，并纳入划线高亮 + CSS 语义、文字细节、阅读外壳、滚动手感。

## Context

### 为什么改

实测（tmux 沙箱 + 渲染器直接跑，不是凭印象）当前章节页的问题：

| # | 现状 | 证据 |
| --- | --- | --- |
| 1 | 正文**无任何边距**，从第 0 列一路折到窗口最右；110 列终端每行 ~55 汉字（App ~20） | tmux 截图：正文行宽 110 单元格，折行后每屏行都顶到右边 |
| 2 | **无行距**，行贴行 | 终端行高固定；你机器 `kitty.conf` 已有 `modify_font cell_height 108%`，但阅读页没有任何加宽 |
| 3 | `j`/`k` 按「段」跳，一段 = 一个 buffer 行（数屏行） | 段落是单行 buffer，`j` 直接掠过整段 |
| 4 | 底部状态栏是编辑器的：`.md` 缓存路径 + `64,0-1 54%`；winbar 93 单元格塞着键位提示 | 截图；`reader.set_winbar` 拼了 `]c 下一章  <leader>wt 目录` |
| 5 | CSS 只还原粗斜体/下划线/删除线/底色 | 真实样式表里 `text-align` 232 次（center 221）、`font-size` 23、`display` 18、`padding-left` 7、`color` 4 —— 全部被忽略，于是居中标题/居中图注/右对齐署名/小字引文/节标题配色都退化成普通左对齐段落 |
| 6 | 划线只在行尾挂 `▎我的划线`，原文本身没有标记 | `annotations.render`（`lua/weread/annotations.lua:328`）只放 eol virt_text |
| 7 | 中英混排无留白 | 输出里 `写作*O*（）`、`对 *n*个字符串`、`大*O*符号` |
| 8 | 死配置 | `paragraph.block_gap`、`paragraph.chapter_title` 在 defaults/README 里，代码无人读（`rg block_gap` 只命中 config 与 README） |

### 已验证的技术前提（决定性）

| 实测项 | 结果 |
| --- | --- |
| `statuscolumn = "%#HL#%{repeat(' ', N)}"` | 能做出**真实左边距**，并且**折行后的每一屏行都会带上它**（用 `X` 标记逐行验证） |
| 表达式算宽度 | 可动态居中（`winwidth()`）；也可以直接写死数字，零开销 |
| 自驱硬换行 + 该边距 | 屏幕立即变成居中版心（已出截图） |
| `xhtml.convert` 单章耗时 | **1.4–2.9 ms**（含 27KB 样式表）→ 换宽/换版心/resize 重排完全无压力 |
| kitty 行距 | 0.48 已用 `modify_font cell_height 140%` 取代 `adjust_line_height`（本地 `definition.py` 确认），你机器现在就是 108% |
| 环境 | 你跑的是 LazyVim、`laststatus=3`（全局 lualine）→ **窗口级 statusline 不显示**，进度必须放 winbar 或临时切 `laststatus` |

## Approach

### 1. 渲染层：把段落折成「一页」的行（`xhtml.lua` + `css.lua`）

`xhtml.Buffer` 本来就是排版缓冲区（`append / marker / block_marker / separate / gap / flush_indent`），
只需要让它知道**宽度**：

- `xhtml.convert(xhtml, { page_width = <cells> })`；**`page_width = nil` 时保持旧行为**，
  现有 156+ 断言与全部现有调用不受影响。
- `Buffer:append` 按**显示宽度**（CJK=2）折行：溢出时在折点切段，续行不带段首缩进，
  **每段单独写一条 map 记录**（`line / col_from / col_to`），`xhtml.resolve` 与划线定位因此继续可用。
- 宽度函数：内置东亚宽度区间 + 记忆化 `vim.fn.strdisplaywidth` 兜底（每字符只算一次）。
- **标点禁则 / 悬挂**（`kinsoku`）：行首不出现 `。，、；：？！）》」』】…—·%`（把断点前移一格，
  允许该行超宽 1 格即"悬挂"）；行尾不留下 `（《「『【`（连同下一字一起下移）。
- **中西文自动留白**（`auto_space`）：CJK ↔ 拉丁字母/数字边界插入一个半角空格；
  源码自带的空格不重复插；注入的空格计入 map 的列区间，不参与源 rune 计数（不影响划线对齐）。
- **CSS 语义还原**（`css.lua`）：`Style` 从「全 boolean」扩展为可带值（`merge` 要保留值而不是压成 `true`）：
  | CSS | 终端里的呈现 |
  | --- | --- |
  | `text-align: center / right` | 折行时用行首空格补齐到版心居中/右对齐（版心宽度我们自己算，所以能精确对齐） |
  | `font-size: 0.75em`（脚注/引文） | 该块**左右各缩进 2 格** + 淡色高亮组 `WereadPaperSmall`（终端改不了字号，用缩排+淡色近似） |
  | `color: #c36500`（节标题） | 归到主题 `accent` 色（不照搬硬编码色值，跟随 reading theme） |
  | `text-indent: 0 / 2em` | 覆盖 `paragraph.indent` 默认值（`——孔子` 这类引文因此不再缩进） |
  | `padding-left: 2em` | 计入该块的有效宽度与左缩进 |
- 每行把「显示属性」写进 `map.json`（`lines = { [line] = { align, small, accent } }`），
  供阅读侧画高亮；对齐与缩进直接落进文本，不需要额外机制。

### 2. 阅读层：版心、边距、窗口观感（`reader.lua`）

- `page_width` 默认 `layout.page_chars * 2 = 52` 单元格；`pad = max(0, (winwidth - page_width) / 2)`；
  `statuscolumn = "%#WereadPaperNormal#<pad 个空格>"`（主题 `none` 时不带高亮组）。
  窗口比版心窄时 pad 归零并**按窗口可用宽度重排**，窄终端不破版。
- `map.json` 记录本次 `page_width`；`chapter_cache_is_fresh` 一并比较宽度 → 换宽/换窗口自动重排
  （`render_from_cache` 已实现「本地重排不联网」，直接复用）。
- `VimResized` / `WinResized`：防抖 200ms，宽度变化则重排当前章（2ms 成本）。
- **阅读位置改用源偏移记忆**：位置记录除 `line` 外存该行首段对应的 `src_from`，
  重排/换宽后按 `xhtml.resolve` 落回同一句，而不是按行号漂移（`cache.write_position` 结构向后兼容）。
- **winbar 精简**：`%#WereadPaperWinBar# 书名 · 章节名 %= 62/76 · 32% `（`%=` 右对齐进度）；
  键位提示从 winbar 撤掉（留在 README）。全书百分比按 catalog `wordCount` 累积算，离线可得。
- **底栏**：`layout.statusline = "off"`（默认）→ 进入章节窗口时把 `laststatus` 设为 0、离开恢复，
  屏幕上只剩 winbar + 正文（最像 App）；另导出 `require("weread.statusline").component()` 供 lualine 用户自己接。
- **光标**：`layout.cursor = "hidden"` → 章节窗口内 `guicursor` 设成 `block-Normal`（看不见），离开恢复。
- **滚动手感**：`j/k → gj/gk`、`smoothscroll`、`scrolloff`；进入章节窗口临时设 `mousescroll=ver:1,hor:1`，离开恢复。
- **章末续章**（`auto_next`）：`j`/`<C-f>`/`<C-d>` 抵达章末再按一次即进下一章（`]c` 保留；`k` 反向到上一章末）。

### 3. 划线落在原文上（`annotations.lua` + `theme.lua`）

- 用 `xhtml.resolve` 的 start/finish 画**范围** extmark：我的划线 = 主题色下划线 + 行首竖线标记，
  热门划线 = 另一种淡色；跨折行时逐行画到 finish。
- `annotations.label = false`（默认）：不再在行尾挂 `▎我的划线`（硬换行后行尾不是页面右缘，挂着很板）；
  `<leader>wa` / `K` 仍可看详情，配置可开回标签。

### 4. 插图（`image.lua`）

- 版心宽度决定 `max_width`（不再固定 60 超出页面）；插图按**版心居中**（按该行行首空格算列偏移），
  图注居中（`.picture_figure_title` 的 `text-align: center` 已在渲染层处理）。

### 5. 行距（`font.lua`，终端层）

- `:WeReadFont` 增加行距参数（如 `:WeReadFont 思源宋体CN 140`），片段里写
  `modify_font cell_height 140%`；`layout.line_height` 可在配置里给默认值（默认 nil = 不动你现在的 108%）。
- 你的 `kitty.conf` 目前没有 `include ~/.config/kitty/weread-font.conf`，插件继续按现有流程提示加这一行
  + `ctrl+shift+F5` 重载（开了 remote control 会尝试 `kitten @ load-config`）。这是终端全局设置，属于必须知情项。

### 6. 配置与文档

```lua
layout = {
  page_chars = 26,      -- 版心宽度（汉字数），0 = 关闭版心
  adaptive = false,     -- true = 版心随窗口宽度浮动
  kinsoku = true,       -- 标点禁则/悬挂
  auto_space = true,    -- 中西文自动留白
  align = true,         -- 还原 CSS text-align / 小字缩排 / 节标题配色
  cursor = "hidden",    -- hidden | normal
  statusline = "off",   -- off | window | keep
  auto_next = true,     -- 章末续章
  line_height = nil,    -- 写入 kitty 片段的 modify_font cell_height（%）
  mousescroll = "ver:1,hor:1",
},
annotations = { label = false },
```

同时删掉死配置 `paragraph.block_gap`、`paragraph.chapter_title`（改文档说明「章节标题重复由
`xhtml.repeats_title` 自动判断」），README 的「排版说明」章节按新行为重写。

## Files to modify

| 文件 | 改动 |
| --- | --- |
| `lua/weread/xhtml.lua` | `page_width` + 硬换行 + 禁则 + 中西文留白；`Buffer` 折行切段；map 记录每行显示属性；`VERSION` 5 → 6 |
| `lua/weread/css.lua` | 解析 `text-align / font-size / color / text-indent / padding-left`；`Style` 支持带值；`merge` 保留值 |
| `lua/weread/reader.lua` | 版心/边距计算、resize 重排、winbar 精简 + 进度、`laststatus`/`guicursor`/`mousescroll` 进出恢复、j/k、章末续章、位置用源偏移 |
| `lua/weread/annotations.lua` | 范围高亮 + 行尾标签可选 |
| `lua/weread/inline.lua` | 小字/节标题色/居中块的 extmark 绘制（复用现有 style 区间机制） |
| `lua/weread/theme.lua` | 新增 `WereadPaperMargin`（边距底）、`WereadPaperSmall`、划线两色，随主题切换 |
| `lua/weread/image.lua` | 版心内居中、宽度跟随版心 |
| `lua/weread/font.lua` | 行距写进 kitty 片段；`snippet()` 支持 `cell_height` |
| `lua/weread/statusline.lua`（新） | 供 lualine / 窗口级 statusline 复用的进度组件 |
| `lua/weread/config.lua` | 新增 `layout`/`annotations`，删死配置 |
| `lua/weread/cache.lua` | 位置记录加 `src_from`（向后兼容读取） |
| `README.md` | 排版/配置/键位章节重写，新增「与 App 的差异与取舍」一段 |
| `tests/spec/*` | 换行/禁则/留白/对齐/map 切段/边距计算/位置回落的断言 |

## Reuse

- `xhtml.Buffer` 已是排版缓冲区：折行、缩进、留白、显示属性全挂它，不需要新渲染器。
- `xhtml.resolve` + map 段表：硬换行只需在折点切段，划线/位置解析链路不变。
- `reader.render_from_cache` + `chapter_cache_is_fresh`：已有「本地重排不联网」，换宽重排直接复用。
- `reader.setup_window` / `setup_chapter_buffer`：边距、j/k、章末续章直接加在这里。
- `theme.winhighlight` 的按窗口重映射：边距/小字/划线新组照现有方式加。
- `weread.inline.attach(buf, styles, headings)`：已是「按 map 区间画 extmark」的通用入口。
- `progress.book_progress` / `ui.progress_badge`：进度百分比现成，winbar 直接用。
- `annotations.parse_range` + `M.render`：范围高亮替换 eol 标签即可。

## Steps（已全部完成）

- [x] 1. `css.lua` 支持带值 Style（`text-align/font-size/color/text-indent/padding-left`），补 `css_spec` 断言
- [x] 2. `xhtml.lua` 加 `page_width` 折行 + 每段 map 切分；默认 nil 保持旧输出
- [x] 3. `xhtml.lua` 加禁则、中西文留白、块级排版（对齐/小字/缩进）；补断言
- [x] 4. 渲染层输出每行显示属性（`map.json.lines` + `page_width`）+ `VERSION` 5 → 6；`reader`/`inline` 侧绘制
- [x] 5. `reader.lua`/新 `layout.lua`：版心与 `statuscolumn` 边距 + resize 防抖重排 + 宽度参与缓存新鲜度
- [x] 6. 位置记忆改源偏移（`reader.save_position` + `xhtml.resolve` 回落），兼容旧记录
- [x] 7. winbar 精简 + 进度；新 `shell.lua` 管 `laststatus`/`guicursor`/`mousescroll` 进出恢复；lualine 组件
- [x] 8. j/k 按屏行 + `smoothscroll` + 章末/章首翻页（含 `3j` 计数与边界用例）
- [x] 9. 划线范围高亮（我的下划线 / 热门波浪线，跨折行、字符级定位 `xhtml.locate`）+ 行尾标签可选
- [x] 10. 插图按版心居中、宽度跟随版心（`image.inline_max_width` / `image.placement_col`）
- [x] 11. `font.lua` 行距写入 kitty 片段（`modify_font cell_height`）+ `:WeReadFont <字体> <行距%>`
- [x] 12. 配置（`layout` / `annotations`）与 README 重写，删掉死配置 `paragraph.block_gap`、`paragraph.chapter_title`
- [x] 13. 全量测试 + tmux 沙箱复核（110/96/76/50 列、居中块、划线、插图）

## 实现时对计划的修正

| 计划 | 实际做法与原因 |
| --- | --- |
| 新增 `statusline.lua` | 改为新增 `shell.lua`：「阅读外壳」的状态机（`laststatus`/`guicursor`/`mousescroll`）与进度文字、lualine 组件放在一起，比拆两个模块更内聚 |
| 对齐/小字「直接落进文本」 | 对齐改为**阅读侧补白**（`virt_text_pos = "inline"`，`inline.render_lines`）：把空格写进文本会平移整行所有列号，划线依赖的 offset map 就对不上了；小字仍用左右内缩（那是折行宽度决策，必须落在渲染期） |
| 版心宽度只在步骤 5 接 | 宽度同时写进 `map.json` 并参与缓存新鲜度判断，`VimResized`/`WinResized` 防抖 250ms 后按需重排（实测 1.4–2.9 ms/章） |
| 「隐藏光标」 | 用 `blend = 100` 的光标高亮组：Neovim 会把它变成终端的隐藏光标序列（TUI 里 `guicursor` 的颜色被忽略，这是唯一可行路径） |
| 死配置清理 | `paragraph.block_gap`、`paragraph.chapter_title` 直接删除（章节标题重复与否由 `xhtml.repeats_title` 判断，不需要开关） |
| 「位置记录加 `src_from`」放在 `cache.lua` | 实际只改 `reader.lua`：`positions.json` 本就没有 schema（`cache.write_position` 存任意表），改的是写记录的那两处 |
| 边距算法 | 拆成纯函数（`layout.page_width_for` / `margin_for` / `statuscolumn_for`）：`--headless` 下没有屏幕，窗口宽度改不动，纯函数才测得了 |
| （复核时修掉）`shell.enter` 原本是「只进一次」 | 改为「原值只存一次、阅读值每次窗口事件都重新施加」，否则阅读中改 `layout.statusline` / `cursor` 不生效 |
| （复核时补上）`ruler` | `laststatus=0` 会把 `ruler` 顶到消息行，成为页面上唯一的编辑器痕迹；阅读时一并关掉并在离开时还原 |

## Verification

- `sh scripts/test.sh`：离线 156+ 断言全绿；新增断言覆盖
  「无一行超出版心宽度」「行首不出现禁则标点」「中西文交界恰好一格」「center/right 对齐到版心」
  「跨折行的划线 start/finish 正确」「`page_width=nil` 时输出与今天逐字节一致」。
- 脚本化版心检查：`nvim --headless -l` 跑 `xhtml.convert{page_width=52}`，用 `strdisplaywidth` 统计每行宽度分布。
- tmux 沙箱（数据目录指 `/tmp/wrdata` 副本，不碰真实阅读记录）截图复核：
  版心居中与留白、行距、标题/图注居中、划线底色、winbar/底栏、resize 后重新居中、
  `j` 到章末自动续章、`q`/`<C-w>` 行为未变。
- 回归：旧缓存章节自动重排（renderer 版本 + 宽度双重判断）、位置记忆仍落在原句。

## 取舍与风险（需要你知道）

1. **缓存 markdown 会被按行重排**：markdown 语义不变（段内软换行），`grep` 仍可搜；
   但 `/` 搜索**跨折点的短语会搜不到**（例如 `减无可减` 恰好被折在中间）。
   可选补一个 P2 小功能：`:WeReadFind`，用缓存 xhtml 的纯文本 + `xhtml.resolve` 定位（不受折行影响）。
2. **行距是终端级设置**：`modify_font cell_height` 影响整个 kitty 窗口（你现有 108%），
   插件默认不动它，只在显式设置时写入片段；tmux 无行高控制。
3. **`statuscolumn` 边距占左侧列**：`<C-w>v` 分屏后每窗口各算各的边距（符合预期）；
   LazyVim 全局状态栏下看不到窗口级 statusline，所以默认走 winbar + 临时 `laststatus=0`。
4. **`laststatus` / `guicursor` / `mousescroll` 是全局选项**：进出章节窗口成对设置并恢复，
   异常退出（崩溃）可能留下其中一个非默认值——`setup()` 时做一次对齐检查。
5. 小字（0.75em）在终端里只能近似：左右缩排 + 淡色，无法真的缩字号。

---

# 第二轮：光标、滚动翻页、画线（用户反馈后）

用户反馈四点，第 1/2/4 点已实现，第 3 点实现了「本地画线」，服务端同步受阻于写权限。

## 1. 光标恢复可见

`layout.cursor` 默认从 `"hidden"` 改为 `"normal"`：读者需要看清自己在哪里、再按一下会到哪。
隐藏仍然可用（`"hidden"`，靠 `blend = 100` 的光标高亮组）。

## 2. 滚动到两端自动翻页

- `j`/`k`/`<C-f>`/`<C-b>`/`<C-d>`/`<C-u>`/`<C-e>`/`<C-y>` 以及**鼠标滚轮**
  （`<ScrollWheelDown/Up/Left/Right>`）都会在章节两端翻页：
  往后 → 下一章章首；往前 → 上一章章末。
- 滚动逻辑提到模块级（`reader.scroll_or_turn` / `reader.wheel_or_turn` / `reader.wheel_lines`），
  因为无界面会话注入不了鼠标事件，键位只做转发——这样才测得动。
- 滚轮按「屏幕上还露不露得出新内容」判断（`line("w$") >= line_count`），而不是看光标动不动：
  `<C-e>` 本来可以一直滚进章末之后的空白区，没人想要那个。
- 滚轮每格行数取自 `layout.mousescroll`。

## 3. 画线（本地）+ 显示 + K 看评论

- `xhtml.rune_at(map, line, col, text)`：`locate` 的逆运算，把「渲染行列」还原成源 rune。
  顺带修了一个真 bug：自动留白注入的空格原本混在 map 段落里，使该行之后的每个 rune 都
  偏一列（画线/选区双向都会错位）；现在空格单独写出，不属于任何段落。
- 本地划线存 `<data>/books/<id>/highlights.json`，按**源 rune 区间**记录（与微信读书同一套
  坐标），因此换版心宽度、重新排版、改窗口大小都不会错位，也不会丢（有测试）。
- 用法：可视模式 `<leader>wh` 给选中文字划线；普通模式 `<leader>wh` 给整行划线（不含段首
  缩进）；`<leader>wd` 取消。命令 `:WeReadHighlight` / `:WeReadUnhighlight`。
- 显示与「我的划线」同一套（强调色下划线）；`K` 显示这条划线与其下的想法；本地划线没有想法
  时，用它的 range 去问服务端（`/book/readreviews`），把别的读者的评论显示出来。
- 给已经划过的段落再画一次会被明确拒绝（不是静默并进服务端那条）。

## 4. 服务端同步：为什么没做

| 通道 | 结论 |
| --- | --- |
| 官方 Agent API（Skill） | `/_list` 列出 17 个接口，**全部只读** |
| 墨水屏/手机接口 `POST /book/addBookmark` | 需要设备登录的 `vid` + `accessToken`；本插件 Web 会话的 refresh token 在 `POST i.weread.qq.com/login` 被拒（`-2013 鉴权失败`） |
| Web 接口 `POST /web/book/addBookmark` | 端点存在（探测多种请求体：JSON/表单/短键名/`bookId`+`range`+`markText` 各种组合、加签名、加 referer/origin/UA，全部 400 空响应），非浏览器发来的请求被拒 |

顺带发现并记录：`auth.renew`（`POST /web/login/renewal`）此前**是死代码**，全仓无人调用；
旧会话在 `i.weread.qq.com` 上因此报 `-2012 登录超时`。本次在排查时手动调用验证了它本身可用，
但**尚未接上自动续期**（见下）。

---

# 第三轮：写想法、取消划线、墨水屏

## 写想法（真同步）

- 输入框：`<leader>wc`（光标在划线上）或可视模式选中文字；`<C-s>` 发表、`<Esc>` 取消。
  实现是 `annotations.compose_thought`，基于现有 `weread.float`。
- 写接口：`POST /web/review/add`（发表）与 `POST /web/review/delete`（删除），用扫码登录的
  cookie 会话。这是本轮最大的发现——**写权限是有的，只是不在官方 Agent API 上**：
  | 通道 | 结论 |
  | --- | --- |
  | 官方 Agent API | `/_list` 17 个接口全只读 |
  | `POST /web/review/add` | ✅ 可用：返回 `{"reviewId":...,"createTime":...}` |
  | `POST /web/review/delete` | ✅ 可用：返回 `{"succ":1}` |
  | `POST /web/book/addBookmark` | ❌ 端点存在但拒绝（400），`/web/book/removeBookmark` 同样不可用 |
- 发表成功后**同时在本机留一份副本**（`remember_note`）：`K` 立刻看得到，服务端读不回来也不丢；
  服务端拒绝时同样落本地并明确提示。
- 未能闭环验证的一点（已如实记录）：`/book/readreviews` 在我连续探测后开始返回 `-2020`
  （疑似限流；早先同形状的调用是通的），因此「想法是否按 range 挂在该划线下面」这次没能当场
  读到。`range` 的两种形状（`start-end` 与单个起始偏移）都试过，都返回了 reviewId。

## 取消划线（为什么之前没生效）

- 根因：键位只在**章节 buffer 创建时**注册一次，已在阅读的 buffer 拿不到更新里新增的键位。
  现在改成 `M.install_keymaps(buf)`：创建时注册，`BufEnter`/`WinEnter` 时对章节 buffer 再补一次
  （`vim.b[buf].weread_keymaps` 保证幂等）。
- 补齐了删除的其它入口：可视模式 `<leader>wd` 删掉与选区重叠的本地划线；
  `:WeReadUnhighlight!` 清空本章本地划线（卡住时的退路）；`:WeReadUnhighlight 1,5` 按行范围删。
- 服务端划线仍然只能在 App 里取消（`/web/book/removeBookmark` 不可用），提示里已写明。

## 墨水屏主题（默认）

- `theme = "eink"`：`bg #f5f5f3` / `fg #1b1b1b`，标题黑色加粗（不再橙色），
  我的划线 `underdouble`、热门划线 `underdashed`——**单色屏幕上靠线型区分**，整页没有彩色。
- `:WeReadTheme eink` 可切换并记住（运行时选择优先于配置里的 theme）。

## 顺带修掉的真问题

- `auth.renew` 是**死代码**（README 一直宣称的 cookie 续期没人调用），而过期的会话会让
  所有 web 请求回 `-2012 登录超时`（正文抓取、写想法都受影响）。现在 HTTP 层集中处理：
  收到 `-2012` → 续期一次 → **原样重试一次**；登录接口自身不触发续期以免递归。有离线测试。
- `auth.lua` 的六个 URL 原本是**写死的常量**（BASE），配置/测试指向别处也会打向正式环境——
  续期因此完全没法测试。现在改为调用时读配置（`M.renewal_url()` 等）。
- 写接口的 origin 同样改为跟随 `config.base_url`，于是写路径可以用 mock 覆盖。

## 第四轮：纯白墨水屏 + 去掉标题黑框

- `eink` 配色改为**纯白底 / 纯黑字**（`#ffffff` / `#000000`），次级信息用灰（`muted #595959`、
  `mark #d9d9d9`），划线仍是墨色双实线 / 灰虚线。色板测试同步收紧（其余各色都断言为灰阶）。
- 标题黑框的来源不是我们的配色，而是 **LazyVim 的 `render-markdown.nvim`**：它给每个标题画
  整行边框（`heading.border = true`）、底色带和图标，而 `anti_conceal.ignore.head_border`
  又让它们在普通模式可见——在纯白页面上就是标题外套黑框。
  - 新模块 `weread.decorations`：把阅读 buffer 接进 render-markdown 的 `ignore(buf)`
    （它每个 buffer 都会问一次，且向用户的 `ignore` 链式传递），并清掉它已经画在章节里的
    命名空间；因为它是防抖渲染，还会在 150/600/1500ms 后补扫，避免它在我们之后才画。
  - 同时在用户的 `~/.config/nvim/lua/plugins/markdown.lua` 里加了 `ignore`（按用户要求
    「在微信阅读里去掉」），从源头就不渲染它。
- 实测（用用户真实 LazyVim 配置跑）：`render-markdown.nvim` 命名空间在章节 buffer 里
  `marks=0`，屏幕上的 `▄▄▄/▀▀▀` 边框、图标、`●` 项目符号全部消失。

## 第五轮：纯白墨水屏 + 界面装饰彻底清干净

用户反馈：翻页后仍有黑框、墨水屏效果没显现。逐项实测（用用户真实 LazyVim 配置 + 带颜色的
`tmux capture-pane -e` 采样）后，找到并修掉这些东西：

| 现象 | 真因 | 处理 |
| --- | --- | --- |
| 标题外面套黑框 | LazyVim 的 `render-markdown.nvim`（`heading.border = true` + 图标 + 底色带，`anti_conceal` 让它在普通模式可见） | 新 `weread.decorations`：链式接进它的 `ignore(buf)`、清掉已画的命名空间、并在 150/600/1500ms 后补扫（它是防抖渲染）；另外按用户要求在 `~/.config/nvim/lua/plugins/markdown.lua` 加了 `ignore` 一行 |
| 页边一道彩色竖线（「墨水屏没显现」的主因之一） | `snacks.indent` 的缩进参考线（LazyVim 默认开） | 章节 buffer 置 `vim.b.snacks_indent = false`（`snacks.scroll` 同理），`decorations.quiet()` 负责 |
| 加粗/斜体句子发蓝 | 行内强调用的是内置 `Bold`/`Italic`（自身无颜色，配色方案的语法色透出来）；且 `winhighlight` 对 extmark 组并不总是生效 | 行内强调改用纸色组 `WereadStrong`/`WereadItalic`/`WereadUnderline`/`WereadStrike` + `hl_mode = replace`；窗口重映射纳入整个 `@markup.*` / `@text.*` 家族 |
| 折行处 `*` 没被隐藏且被上色 | `after_wrap` 在写重开标记**之前**记录列号，重开区间因此从列 0 开始（把标记也包进去） | 先写标记再记列号（与正常开样式一致）；`xhtml.VERSION` 6 → 7 让缓存章节重排 |
| 读过书的窗口在显示别的文件时仍是纸色 | `winhighlight` 是窗口选项，没人还回去 | `theme.clear_stale()` + `sync_shell` 里调用（并有测试） |
| 测试卡在书架上 | 我的新 spec 让 `weread.reader` 提前加载，`gateway_spec` 的 ui 桩失效（reader 在加载时抓住 ui） | `gateway_spec` 里显式 `package.loaded["weread.reader"] = nil` 再加载 |

实测结果（用户真实配置）：正文与翻页后的页面**纯白底**、页面上**没有任何非灰阶颜色**、
`snacks_indent=false`、`render-markdown` 命名空间 0 标记、`WereadStrong fg=#000000 bg=#ffffff bold`。

另外提醒用户：**必须重启 nvim** 才能加载改动后的插件代码（Lua 模块按加载时缓存），这也是
「翻页之后还有黑框」最可能的原因——那次会话里跑的还是旧代码。

## 第六轮：提示消息、内联插图（两个都实测定位到根因）

### 翻页时的提示

`reader.lua` 每次打开章节都会 `vim.notify("was: 续读《…》· 章节名")`（INFO），定时器每 60 秒还会
弹「已回传进度」，`<leader>wr` 弹「已刷新划线」——在页面正中。

新增 `notify` 配置（默认 `"quiet"`）+ `ui.notify(message, level, { routine = true })`：
例行消息在 quiet 下只写日志、不弹；**手动操作**（按键/命令）的回应照常弹；警告与错误永远弹。
`sync_now()` 默认按手动处理，只有定时器给自己的调用打 `routine` 标记。

### 插图为什么只弹窗不内联

实测（用户真实环境）发现**两个**独立原因：

| 原因 | 证据 | 处理 |
| --- | --- | --- |
| 资源包其实是 **zip**：某书 `tar` 字段指向的 `tar_…_60` 下载回来是 `Zip archive data`，`tar.parse` 解出 0 个条目 | 网上直连该 URL → 139890B zip；`fetch_assets` 返回 `images=0`；`assets/` 为空 | 新 `image.ensure_local()`：正文里的图片 URL 直接下载到 `assets/url-<id>.<ext>`（按 magic bytes 定扩展名，一次即缓存）；`render_inline`/`hover` 都走它 |
| tmux 下 snacks 探测不到图形：`TERM_PROGRAM=tmux` + `TERM=xterm-kitty`，snacks 在 tmux 分支只查了 `#{client_termname}` 而没设 `supported` | `supports_terminal()=false`，屏幕没有任何图形序列 | 在用户 snacks 配置里加 `force = true`（并在 README/`:checkhealth` 说明）；实测后 `supports_terminal()=true`、6 张图落盘、`render_inline created=6` |

顺带：`cached_image_path` 现在也认下载来的 `url-<id>.<ext>`（重排时能找到），并按已知扩展名
查找——测试发现原来的 `id.*` 通配会把下载器留下的 `.headers` 当成插图。

### 状态栏在 LazyVim 下没收起来

lualine 加载时会把 `laststatus` 设回 3，而那时启动命令打开的章节已经在屏幕上了。补了
`User VeryLazy` / `VimEnter`（延迟 200ms）/ `ColorScheme` 三个事件重放阅读外壳；实测
`laststatus=0` 保持。

## 第七轮：表格、代码清单、黑框的根因

### 表格被摊成「一格一行」

截图里的表格每格各占一行、行尾挂着 `|`。源文件是一张 8 列的 `<table>`，单元格里还套着
`<p class="bt">`，而块级排版对每个块都断行——表格因此被彻底摊平。

修法（`xhtml.lua`）：`<table>` 记状态；`<tr>` 开一行；`<td>`/`<th>` 以 `| ` 作格界；`</tr>`
补行尾 `|`；首行后自动补 markdown 分隔行并**在渲染后隐藏它**（`inline.conceal_structure`）。
表格内的块级元素不再断行（否则又会退化成原样）。渲染器版本 8。

### 代码清单被当成散文

`<pre>` 里的换行与空格被散文规则吃掉（自动空格、首行缩进），CRLF 还留下一串 `^M`。
现在有个 `verbatim` 缓冲模式：不加缩进、不做中西文自动空格、保留源码换行与空格，外围补
``` 围栏（围栏独占一行），CRLF 归一化。渲染器版本 9 → 10。

### 标题黑框：为什么是「偶尔」

之前只知道「有时候又出现黑框」，清扫（150/600/1500ms）看起来没生效。读 render-markdown
源码后明确了：

- `ignore` 只在 `attach` / `should_attach` 时被问一次；
- `attach` 同时注册一批 buffer 级自动命令（`CursorMoved` / `WinScrolled` / `ModeChanged` /
  `TextChanged` …），**这些回调只看 `state.get(buf).enabled`，不看 `ignore`**。

而 reader 里 `vim.b.weread_book = true` 原本设在 `bufload` **之后**——`bufload` 会触发
`FileType`，render-markdown 正是在那时 attach（并注册自动命令）：标记晚了，它先接手，之后
每次移动光标、每次滚屏都重画一次，清扫自然追不上。「偶尔」= 你一动它就画。

三处修：

1. 标记（`weread_book` + `decorations.quiet`）移到 `bufload` **之前**，attach 时就被 `ignore`
   挡掉，**自动命令根本不会注册**（实机 `attached=no`）；
2. 已 attach 的 buffer 用它的 buffer 级开关关掉（`state.get(buf).enabled = false`）；
3. 保留原有的命名空间清理与补扫。

### 顺带挖出的真 bug：map.json 静默写不出去

查「为什么某些章节没有 map」时发现的：`vim.json.encode` **拒绝稀疏数组**
（`excessively sparse array`），而 map 里的逐行显示属性表正是「键是行号、只有几行存在」的
稀疏表（键全 ≥1 且没有 `0` 时会被当成数组）。于是：

- `write_json` 失败只回一个 `false`，**没有原因**；
- 两处调用点都没看返回值，日志照样打「re-rendered」。

结果：这些章节的 map.json 从未写出（md 是旧的、渲染器版本也是旧的），划线偏移、样式、标题
记录全部丢失，每次打开又静默重排一遍。修法：键以字符串写出（`xhtml.json_lines`）、
`write_json` 说明失败原因、写入处检查并 `log.warn`，并加一个按真实章节形状写的用例。

### 实测

- 表格：8 列表格按源表行渲染，分隔行隐藏（截图核对）；
- 代码清单：`# 最基本的Headless模式调用` 等行原文照排，无 `^M`；
- 黑框：连开 3 章 `attached=no`、滚动/移动光标后 `render-markdown` extmark 数保持 0；
- 缓存：重排后 `md CR 数=0`、`map renderer=10 segments=1474 headings=40 lines=2`、`lines` 键为
  字符串；
- 测试：345 组断言通过。

## 第八轮：表格交给 markdown 渲染、代码块语法高亮

第七轮把表格还原成了 markdown 表格文本、把清单还原成了逐字围栏，但页面上看到的仍是「管道与
下划线」。这一轮让 render-markdown.nvim 只画这两样，并让清单里的代码真正上色。

### 做法：不是「挡住装饰插件」，而是「只让它画两样」

第七轮是把它挡在外面（`ignore` + 清命名空间）。表格要画成真表格，就得反过来：给它一份
**buffer 级配置**（`render-markdown.api.render({ buf, win, config })`），只开 `pipe_table` 与
`code`，其余全关（标题、缩进参考线、图标、底色带、列表、引号……）。

路上踩到的坑，都记下来：

1. **`state.get(buf, custom)` 的缓存优先于自定义配置**：一个 buffer 的配置只构建一次，晚种就
   无效。而 `bufload` 会触发 `FileType`，插件正是在那时 attach 并构建配置——所以阅读器在
   `bufload` **之前**就种（沿用第七轮的教训），并且在真正绘制前再种一次。
2. **冷启动时插件还没 setup**：LazyVim 按自己的时机加载它，第一章可能先上屏。种配置前先看
   `state.config` 是否存在，不存在就延后重试（250ms × 8）。
3. **`callout` 是映射而不是配置**：给它加 `enabled = false` 会让插件的 resolver 把这个布尔值
   当成一条 callout 去取 `config.raw` 而崩（`resolved.lua:34`）。安静地崩在 pcall 里，只表现
   为「表格没画出来」。现在 `prettify_error` 会记下原因，`:checkhealth weread` 会显示。
4. **per-buffer 配置里的 `style` 预设不展开**：`style = "normal"`、`preset = "round"` 只在
   setup 时对全局配置展开，buffer 级配置必须写展开后的键（`border_enabled = false` 之类）。
5. **窗口尚未重绘时 `textoff` 是 0**：版心边距是一个 `statuscolumn`，而表格是按窗口文本宽度
   折单元格的。画得太早，表格会按「比版心宽 29 列」的窗口排版，右边被截掉。现在会等到
   `textoff` 出现再画（50ms × 12，只对阅读 buffer）。
6. **先清命名空间再画**：上一次渲染（配置未生效时、或另一个窗口尺寸下）留下的列宽会被继承，
   表格看起来永远是错的。
7. **`overlay` 类虚拟文本在空行上不会被绘制**（实测）：插件把语言标签放在围栏上方那一行，而
   我们的渲染在围栏前正好是空行——标签永远不出现。所以语言名改由书页自己写在**围栏行**上
   （那一行有文本），插件的语言名/border 关掉（它的细边框同样画在空行上）。

### 表格行不再折行

markdown 没有办法给表格行续行：一行断开会被读成两行、列还错位。所以渲染时表格内暂停版心宽度
与块级排版，整行输出；折单元格交给渲染器按窗口宽度做（渲染器版本 → 11，缓存的章节会重排一次）。

### 清单语言：从内容读

书不标语言（三本书 148 份清单全是同一个 CSS 类），没有语言的围栏不会有任何语法高亮。新增
`xhtml.language_of`：强信号（shebang / `$` 提示符 / 可解析的 JSON / 整块 `key: value`）+ 逐行
认领投票，胜者需占非注释行一半以上，否则**不给语言**。保守是刻意的——把中文散文按 YAML 上色
比不着色更糟。实测 148 份：bash 33、json 27、markdown 27、yaml 8、python 1，其余 52 份
（散文、目录树、权限规则）保持素净。

写这段时又踩了 Lua 模式的两个坑：**Lua 模式没有 `|` 交替**（`(def|class)` 是字面量），以及
`-` 在模式里是**懒惰重复修饰符**（`language-([%w+%-]+)` 实际匹配的是 `languag` + `e-`，
得写 `language%-`）。两者都只表现为「判断不出来」，不会报错。

### 颜色

表格边框、围栏标签都用配色的淡墨（新增 `WereadPaperTableHead` / `WereadPaperTableRow`，
窗口重映射接上），格子里的文字保留它自己的高亮；代码块**不要底色**（`disable_background = true`），
否则语法高亮会被底色盖掉——这也是「代码看起来没高亮」的另一个原因。

### 实测

- 表格：8 列宽表按窗口折成约 72 列、在版心左边界对齐、`┤` 收尾（冷启动即正确）；
- 代码块：bash 语法高亮生效（`claude` 蓝、`-p` 橙、注释灰蓝），围栏行显示 `bash` 标签；
- 标题：普通标题行上 render-markdown 的标记数为 0（没有黑框）；
- 测试：354 组断言通过。

### 已知瑕疵

render-markdown 不在**光标所在行**创建标记（它把这当作「让光标下露出原文」）。阅读器把光标放在
页面顶行，因此当表格首行/清单首行正好落在顶行时，那一行显示的是 `| 格 |` 原文，而表格其余部分
已经画好。`anti_conceal.disabled_modes = {}`、`enabled = false`、`concealcursor = nvic` 都试过，
都不影响这个行为（是创建期跳过，不是绘制期隐藏）。书页自己的围栏语言标签不受影响——它是普通的
overlay 虚拟文本，实测在光标行上照常绘制。
