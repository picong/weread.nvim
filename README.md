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
| 插图内联渲染（kitty graphics）+ 浮窗放大 | ✅ |
| 书架 / 搜索 / 书籍信息（官方 Agent API） | ✅ |
| 阅读进度与时长回传 | ✅ |
| 划线与想法（我的划线、热门划线、划线下的想法） | ✅ |
| 公众号（MP_WXS_*）文章阅读 | ❌ 未实现（接口与普通书完全不同） |
| 整书导出 EPUB | ❌ 未实现（当前方向是原生阅读器） |

## 依赖

| 依赖 | 用途 | 必需 |
| --- | --- | --- |
| Neovim >= 0.10 | `vim.system`、`vim.fs`、`vim.uv` | ✅ |
| `curl` | 所有 HTTP 请求（cookie jar、重定向、TLS） | ✅ |
| `qrencode` | 生成登录二维码 PNG（缺失时降级为 ASCII 二维码） | 扫码登录 |
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
  cmd = { "WeRead", "WeReadLogin", "WeReadOpen", "WeReadSearch", "WeReadResume", "WeReadToc" },
  opts = {
    text_width = 78,
    sync_interval = 60,
    image = { max_width = 60, max_height = 30 },
    proxy = nil, -- "direct" 可强制绕过环境代理
  },
  config = function(_, opts)
    require("weread").setup(opts)
  end,
}
```

图片渲染需要在 `snacks.nvim` 中开启 image 模块：

```lua
{
  "folke/snacks.nvim",
  opts = {
    image = {
      enabled = true,
      doc = { inline = true, max_width = 60, max_height = 30 },
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

## 命令

| 命令 | 说明 |
| --- | --- |
| `:WeReadLogin[!]` | 扫码登录（`!` 先清除旧凭据） |
| `:WeReadLogout` | 退出登录并清除本地凭据 |
| `:WeRead [关键词]` | 书架选择器；带关键词则搜索书城 |
| `:WeReadOpen [bookId/书名/URL]` | 打开书（留空则续读上次那本） |
| `:WeReadResume` | 继续上次阅读 |
| `:WeReadToc` | 目录选择器 |
| `:WeReadNext` / `:WeReadPrev` | 下一章 / 上一章 |
| `:WeReadChapter <n>` | 跳到第 n 章（按可读章节计数，封面等零字数条目跳过） |
| `:WeReadRefresh` | 重新抓取当前章节 |
| `:WeReadSync` | 立即把进度与时长回传微信读书 |
| `:WeReadAnnotations[!]` | 本章划线与想法汇总（`!` 重新拉取） |
| `:WeReadLog` | 查看运行日志 |
| `:checkhealth weread` | 自检 |

## 章节 buffer 内的快捷键

| 键 | 说明 |
| --- | --- |
| `]c` / `[c` | 下一章 / 上一章 |
| `<leader>wt` | 目录 |
| `<leader>wo` | 浮窗放大查看光标处的插图 |
| `K` | 查看光标处划线下的想法 |
| `<leader>wa` | 本章划线与想法汇总 |
| `<leader>ws` | 立即回传进度 |
| `<leader>wr` | 重新抓取本章 |
| `j` / `k` | 上下移动（一行 = 一个段落，因为段间不再有空行） |

这里刻意占用了 `<leader>w` 前缀（LazyVim 的窗口组），但只在章节 buffer 内生效。

## 配置

```lua
require("weread").setup({
  -- 排版：紧凑（段间不留空行）+ 首行缩进两格，像中文书那样
  paragraph = { compact = true, indent = "　　", block_gap = true },
  text_width = 0,           -- >0 会在正文里画一条 colorcolumn 竖线（默认关）
  cursorline = false,       -- 是否高亮整个光标行
  sync_interval = 60,       -- 进度回传间隔（秒），0 关闭回传
  sync_on_leave = true,     -- 离开章节时结算并回传
  image = { max_width = 60, max_height = 20, icon = "⧉" },
  keymaps = true,           -- 章节 buffer 内注册默认快捷键
  proxy = nil,              -- nil 沿用环境变量，"direct" 强制直连
  base_url = "https://weread.qq.com",
  gateway_url = "https://i.weread.qq.com", -- 也可写完整端点 URL
  data_dir = nil,           -- 默认 stdpath("data")/weread
  debug = false,            -- 写日志到 data_dir/weread.log
})
```

### 排版说明

正文按中文书的样子渲染，而不是按 markdown 的习惯：

- **段间不留空行**，靠首行缩进两格区分段落。原本每段一个空行时，一屏有一半是空白（实测 10 段占 19 行，现在 10 行）。
- 标题、插图、分隔线周围保留空行；列表项独占一行且不缩进。
- 原文自带全角缩进的 TXT 型书籍不会重复缩进。
- **插图行只显示一个图标与图注**：`![图 1-6](/home/…/assets/epub_x.png)` 显示为 `⧉ 图 1-6`，长缓存路径被 conceal 掉，`<leader>wo` 仍可放大查看。
- 默认不画 `colorcolumn` 竖线、不高亮整行。

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

1. 有本地阅读记录 → **直接跳到上次那一章那一行**，并提示「续读《书名》· 章节名」；
2. 本地没记录但服务端进度已越过开篇章节 → 按服务端进度续读；
3. 两边都没有 → 打开目录让你选。

阅读位置在离开章节、切换窗口、退出、以及阅读中每 5 秒各记录一次（切章时以新章节为准，不会被上一章覆盖）。想看目录随时 `<leader>wt` 或 `:WeReadToc`。

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
sh scripts/test.sh
# 等价于： nvim --headless --clean -l tests/run.lua
```

156+ 组断言，全部离线（本地 mock 服务器 + 真实 curl 进程），不需要账号与网络。
夹具由上游 **python 编码器**生成（`scripts/gen_fixtures.py`），因此 Lua 解码链是与
另一套独立实现对拍，而不是自证。

覆盖内容：协议向量（`_e()`/签名/MD5）、cookie jar、登录状态机（正常/OTP/错码/
未开通 Skill/过期/取消）、内容流水线（服务端验签 + 分片解码 + tar 解包 + 落盘）、
阅读器（buffer/winbar/缓存复用/位置记忆/预取/切章）、进度回传（服务端验证
签名与 `sg`）、划线与想法（归并/定位/弹窗）、插图几何与降级。

## 工作原理

微信读书没有公开的正文接口：官方 Agent API（`i.weread.qq.com/api/agent/gateway`，
Bearer API Key）只提供书架、搜索、目录、进度、笔记与统计。**章节正文**必须走网页
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
