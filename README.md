# weread.nvim

在 Neovim 里读微信读书：扫码登录、书架/搜索、章节正文、插图内联渲染、阅读进度回传、划线与想法。

> **免责声明**：本项目仅供个人学习与个人阅读使用，只访问你自己账号有权阅读的内容。请遵守微信读书的用户协议与相关法律法规，不要用于批量导出或再分发受版权保护的内容。

## 状态

| 模块 | 状态 |
| --- | --- |
| 协议层（`_e()` / 签名 / payload） | ✅ 已实现，已知向量单测覆盖 |
| HTTP 层（curl + cookie jar） | ✅ 已实现 |
| 扫码登录 | ✅ 已实现（含 4 位 OTP） |
| 内容层（目录 / 分片解码 / tar 图片解包） | ✅ 已实现 |
| XHTML → Markdown 渲染器 | ✅ 已实现 |
| 阅读器（一章一 buffer、目录、跳章、位置记忆） | ✅ 已实现 |
| 插图内联渲染（kitty graphics） | ✅ 已实现（依赖 `snacks.nvim`，见下） |
| 书架 / 搜索 / 书籍信息 | ✅ 已实现（官方 Agent API） |
| 阅读进度回传 | ✅ 已实现 |
| 划线与想法 | ✅ 已实现 |

## 依赖

| 依赖 | 用途 | 必需 |
| --- | --- | --- |
| Neovim >= 0.10 | `vim.system`、`vim.fs` | ✅ |
| `curl` | 所有 HTTP 请求（含 cookie jar、重定向、TLS） | ✅ |
| `qrencode` | 生成登录二维码 PNG | 扫码登录需要 |
| `snacks.nvim`（`image` 模块） | 插图内联渲染与浮窗放大 | 图片渲染需要 |
| kitty / ghostty | 图片协议（kitty graphics protocol） | 图片渲染需要 |
| `magick`（ImageMagick） | 非 PNG 图片转换 | 按需 |

`:checkhealth weread` 会逐项检查以上依赖。

## 安装（lazy.nvim）

```lua
{
  "you/weread.nvim",
  dir = vim.fn.expand("~/projects/weread.nvim"), -- 本地开发
  dependencies = { "folke/snacks.nvim" },
  cmd = { "WeRead", "WeReadLogin", "WeReadOpen", "WeReadSearch", "WeReadSyncProgress" },
  opts = {},
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

## 命令

| 命令 | 说明 |
| --- | --- |
| `:WeReadLogin` | 扫码登录（`!` 强制重新登录） |
| `:WeRead` | 打开书架选择器（无书目时进入搜索） |
| `:WeReadOpen [书名或 bookId]` | 打开书籍目录 / 直接打开某本书 |
| `:WeReadChapter <n>` | 跳到第 n 章 |
| `:WeReadSearch <关键词>` | 搜索书城 |
| `:WeReadAnnotations` | 查看当前章节的划线与想法汇总 |
| `:WeReadSyncNow` | 立即把本地进度回传到微信读书 |
| `:checkhealth weread` | 自检 |

## 默认快捷键（章节 buffer 内，`<leader>` 取 `vim.g.mapleader`）

| 键 | 说明 |
| --- | --- |
| `<leader>wt` | 目录 |
| `]c` / `[c` | 下一章 / 上一章 |
| `K` | 查看光标处划线下的想法 |
| `<leader>wo` | 以浮窗放大查看光标处的插图 |
| `<leader>wa` | 本章划线与想法汇总 |
| `<leader>ws` | 立即回传进度 |

## 配置

```lua
require("weread").setup({
  -- 阅读正文宽度（字符数），0 表示跟随窗口
  text_width = 78,
  -- 阅读进度自动回传间隔（秒），0 表示关闭
  sync_interval = 60,
  -- 图片内联渲染的最大宽高（单元格）
  image = { max_width = 60, max_height = 30 },
  -- 章节缓存目录，默认 stdpath("data")/weread
  data_dir = nil,
})
```

## 数据与凭据

```
$XDG_DATA_HOME/nvim/weread/
├── credentials.json     0600，cookies + 官方 API Key + 账号信息
├── cookies.txt          0600，curl cookie jar
├── positions.json       阅读位置
└── books/<bookId>/      按书缓存：目录、章节 XHTML/Markdown、图片、划线
```

Cookie 与 API Key 只保存在本地，不会发送到除 `weread.qq.com` 之外的任何地方。

## 测试

```sh
nvim --headless --clean -l tests/run.lua
# 或
sh scripts/test.sh
```

单测覆盖协议层与解码链的已知向量（`_e()`、`web_app_id()`、签名、MD5、tar 解析、XHTML 转换），可在无网络、无账号的情况下运行。

## 工作原理

微信读书没有公开的正文接口：官方 Agent API（`i.weread.qq.com/api/agent/gateway`，Bearer API Key）只提供书架、搜索、目录、进度、笔记与统计。**章节正文**必须走网页阅读器链路——密文下发，由前端 JS 解码：

1. 正文分片来自 `POST /web/book/chapter/e_0|e_1|e_3`（EPUB 型）或 `t_0|t_1`（TXT 型），请求体需携带签名 `s`、`ps`（阅读器 HTML 里的 `reader.psvts`）与 `pc = _e(ct)`。
2. 响应前 32 字符是余下内容的 MD5，其余部分经「去首字符 → 反转字符交换 → base64url → UTF-8 修复」还原。
3. 插图来自 `chapterInfos` 响应中的 `tar` 资源包（POSIX tar，内含无扩展名图片文件）。

本插件把上述流程完整实现在 Lua 中，并缓存到本地。算法细节与已知向量见 `tests/spec/` 与上游文档 `weread.koplugin/docs/weread-api-reference.md`。

## 许可证

AGPL-3.0-only。部分代码移植自同样以 AGPL-3.0 授权的 [QiuYukang/weread.koplugin](https://github.com/QiuYukang/weread.koplugin)，详见 [NOTICE](NOTICE)。
