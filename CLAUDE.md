# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## 项目

weread.nvim：在 Neovim（>= 0.10）里读微信读书。纯 Lua，无构建步骤，无 linter 配置。外部依赖只有 `curl`（必需）、`qrencode`、`snacks.nvim`（图片/选择器，可选）。许可证 AGPL-3.0-only；`crypto.lua`、`protocol.lua`、`reader_state.lua`、`content.lua` 解码链、`auth.lua` 登录协议、`progress.lua` payload 形状移植自 weread.koplugin，改动这些文件时保留文件头版权声明（见 NOTICE）。

## 测试

```sh
sh scripts/test.sh                       # 可从任意目录运行，全量
sh scripts/test.sh reader                # 只跑文件名含 "reader" 的 spec（环境变量 SPEC=reader 同效）
nvim --headless --clean -l tests/run.lua # 必须在仓库根目录执行，等价于全量
```

- 自研零依赖框架（`tests/framework.lua`），spec 用全局 `describe/it/eq/truthy/falsy/matches/raises`。
- `tests/run.lua` 默认加载 `tests/spec/*_spec.lua` 全部文件；可按文件名片段过滤（见上），但没有按用例过滤的参数；整套约 50 秒。
- 每个 spec 文件前后，runner 会快照并还原 `package.loaded`、`vim.notify`、`vim.defer_fn`、`vim.ui.input`、`vim.fn.timer_stop`，清空 buffer，重置窗口局部选项。所以 spec 可以随意打桩模块，不会串到别的 spec。
- 全部离线：`tests/mock.lua` 起本地 mock 微信读书服务器，由真实 curl 进程访问。mock 的路由处理器跑在 libuv 回调（fast event context）里，调用 `vim.fn.*` 会报 E5560，所以夹具要在文件作用域读好。
- `tests/fixtures/` 由上游 Python 编码器生成（`scripts/gen_fixtures.py /path/to/weread.koplugin`），Lua 解码链靠它和另一套独立实现对拍。不要用 Lua 侧自己生成夹具。

## 架构

入口：`plugin/weread.lua` 定义全部 `:WeRead*` 命令；`require("weread").setup(opts)`（`init.lua`）依次初始化 config、http（cookie jar、代理）、log、auth cookie、progress 定时器、高亮组、主题。

两条完全不同的后端链路：
- **官方 Agent API**（`api_gateway.lua`，`i.weread.qq.com/api/agent/gateway`，Bearer `wrk-*` API Key）：书架、搜索、目录、进度读取、笔记、点评。API Key 在扫码登录后获取，需要用户在 App 里开通「微信读书 Skill」。
- **网页阅读器链路**（cookie 鉴权）：章节正文、进度上报、自己画线和写想法、译文。正文是密文：`reader.lua` 先取阅读器页面拿到逐章变化的 `psvts`，再由 `content.lua` 用 `protocol.lua`/`crypto.lua` 签名请求 `e_0|e_1|e_3`（EPUB）或 `t_0|t_1`（TXT）分片，校验 MD5 后解码；插图来自 `tar` 资源包（`tar.lua`，按 magic bytes 判断类型）。

渲染流水线（一章一个 buffer）：
1. `xhtml.lua` 把原始 XHTML 转成 markdown，同时产出 **offset map**（原始 HTML 的 rune 偏移，含标签字符，映射到 markdown 行列），以及样式 span、标题、逐行显示属性。划线 `range` 用的就是这种偏移，map 丢了划线就定位不了。`css.lua` 解析书籍样式表和行内 `style`，决定哪些 span 是粗体、斜体等。排版（版心宽度、标点禁则、中西文留白）也在转换时用硬换行完成，宽度来自 `layout.lua`。
2. `cache.lua` 落盘到 `$XDG_DATA_HOME/nvim/weread/books/<bookId>/chapters/NNNN.{xhtml,md,map.json}`。重开已缓存章节不联网；窗口 resize 只用缓存的源重新排版。
3. buffer 就是这个 `.md` 文件，设为 `nomodifiable`、置 `vim.b.weread_book`。markdown 标记留在文件里（可 grep），由 extmark 呈现：`inline.lua`（隐藏标记、加真实属性）、`annotations.lua`（划线与想法）、`image.lua`（自己驱动 snacks.image placement，不依赖 treesitter 注入）。
4. 窗口层：`pager.lua`（按屏分页，只是“看”buffer 的方式，不改内容）、`shell.lua`（winbar 进度、藏状态栏和光标）、`theme.lua`（阅读配色，只作用于章节窗口）、`decorations.lua`（压住 render-markdown 等装饰插件在阅读 buffer 上的绘制）。

`progress.lua` 负责双向进度同步：停稳才上报，退出补发，BufEnter/空闲回来/`sync_pull_interval` 轮询时拉取并跳转。不要依赖 FocusGained，用户的终端复用器下焦点事件不可靠。

## 已知的坑

- 稀疏且键都 ≥1 的表会被 `vim.json.encode` 当成数组拒绝（`excessively sparse array`）。map 里的逐行属性表因此以字符串键写出（`xhtml.json_lines`），写 JSON 时要检查返回值。
- `vim.defer_fn` 返回的是 uv timer 句柄，不是数字 id，传给 `vim.fn.timer_stop` 会失败且定时器继续跑。需要可停止的定时器时用 `timer.lua`。
- 用户的 `mapleader = " "`：buffer 局部映射 `<Space>` 会吞掉所有 `<leader>` 映射。

## 代码约定

- 注释写英文，后面跟括号里的中文翻译，例如 `-- foo (中文说明)`；文件头的 `--[[ ]]` 块说明模块的设计理由。新代码保持这个格式。
- 类型注解用 LuaLS 的 `---@param`/`---@return`。
- 高亮组用 `default = true` 定义，前缀 `Weread`，不覆盖用户自定义。
