# 护眼主题 + 双向自动进度同步

## Context

用户反馈三点：阅读刺眼、色调不舒服、希望阅读进度自动同步，其他端打开就能跳到当前位置。

实测发现：

- **刺眼的根因**：`~/.local/share/nvim/weread/preferences.json` 里存着 `{"theme":"eink"}`。`init.lua` 让运行时偏好
  优先于配置，所以用户配置里的 `theme = "paper"` 被覆盖，实际显示的是 `eink`：`#ffffff` 底配 `#000000` 字，
  对比度 **21:1**（paper 10.4、sepia 9.0）。大面积纯白加极高对比度，是终端里长时间阅读刺眼的主因。
- **上报的偏移坐标系不对**：`progress.chapter_offset()` 上报的是*渲染后 buffer 的字符偏移*（含缩进、边距、换行）。
  App 用的是*原始章节 XHTML 的 rune 偏移*，和划线 `range` 是同一套坐标。实测：App（appId `226426210`）
  上报《CB_Gcv5…》封底章 `co=753`，正好对应该章 XHTML 第 753 个码点。插件本地已经按这套坐标存了位置
  （`positions.json` 的 `src_from`；《人月神话》本地 3015 = XHTML 原文下标），只是上报时没用它。
- **百分比偏粗**：`progress.book_progress` 按章节序号算，不含章内进度。`shell.book_percent` 已经有按 `wordCount` 算的版本。
- **上报时机偏粗**：只在进入章节（rt=0）、BufLeave、每 60 秒定时器时上报。退出 nvim 时发出的异步请求可能被进程退出直接杀掉。
- **反向同步（其他端 → nvim）缺失**：`start_index()` 以本地记录为准，远端章节只取自缓存的 meta，并且只定位到章。
  `api_gateway.progress()`（`/book/getprogress`）实测可用，返回 `chapterUid / chapterOffset / progress / updateTime / summary`。
  另有一个隐患：打开章节时 `progress.enter()` 会先把**本地旧位置**上报出去，这会覆盖掉其他端更新的进度，必须在拉取远端之后再报。

## Approach

用户已确认：暖米纸色低对比、双向同步、位置停下 5 秒后上报、配置优先于旧偏好。

### A. 主题

- 把 `paper` 重调成暖米纸色并设为默认。新配色以 `#ede4d3` 为底，对比度经 WCAG 公式计算：

  | 项 | 值 | 对底对比度 |
  | --- | --- | --- |
  | bg | `#ede4d3` | — |
  | fg | `#4a4036` | 8.0 |
  | muted（winbar/引文/脚注） | `#76695a` | 4.2 |
  | accent（标题、我的划线） | `#8c5f45` | 4.3 |
  | link | `#7d6650` | 4.3 |
  | mark（光标行/标记底） | `#e2d6bf` | 与 fg 7.0 |

- `night` 一并调成暖色深夜：bg `#23201c`、fg `#c9bca5`（8.7）、muted `#8a7e6a`、accent `#c49a6c`、mark `#3a332a`。
- `eink / sepia / light` 保留，仍可在 `:WeReadTheme` 里选；`eink` 不再作为默认值。
- **配置优先**：`config.setup` 记录用户是否显式传了 `theme`。显式传了就以配置为准，`preferences.json` 只在没配置时生效。
  在 `:WeReadTheme` 里切换仍然即时生效；如果配置里固定了主题，提示一句「重启后以 setup 配置为准」。

### B. 进度同步

1. **正确的坐标**：新增 `reader.source_offset(buf, win)`，用光标所在行列计算源 rune 偏移。优先用 `xhtml.rune_at`，
   退化到 `rune_of_line`，没有偏移表时再退回旧算法。`build_payload` 改用它，`co` 与 App 对齐。
2. **更准的百分比**：全书进度 =（本章之前的字数 + 本章字数 × 章内比例）/ 总字数，章内比例取 `offset / meta.source_runes`。
   从 `shell.book_percent` 抽出共享函数，winbar 和上报都用它。`summary` 额外去掉全角缩进（实测出现过「　　Chapter 6.1.」）。
3. **防抖上报**：在章节 buffer 上监听 `CursorMoved / WinScrolled`，每次重启一个 5 秒的 `timer.defer`。
   到时如果 `(chapter_uid, offset)` 与上次上报不同，就上报一次，同时带上累计的阅读时长。新配置 `sync_debounce = 5`（秒，0 关闭）。
   原有 60 秒定时器保留，用来在位置不动时结算阅读时长。
4. **离开时立刻上报**：`FocusLost` 强制上报。`VimLeavePre` 改为同步发送（`http.request_sync`，3 秒上限），避免退出时请求丢失。
5. **拉取远端（双向）**：
   - 续读（`open_book` 的 resume 路径）时，先调用 `api_gateway.progress`（3 秒超时；失败或没有 API Key 时静默退回本地）。
     如果远端 `updateTime` 比本地 `positions.json` 的 `updated_at` 和上次成功上报时间都晚（容差 5 秒），并且位置不同，
     就打开远端那一章，再用 `xhtml.resolve(meta, chapterOffset)` 定位到那一句，提示「已跳到其他端进度：章名 · 摘要」。
   - 拉取完成之后才执行 `progress.enter()` 的首次上报，修掉上面提到的覆盖问题。
   - `FocusGained` 且当前就在章节 buffer 时，用同一套规则再拉取一次：在手机上读了一段再切回终端，会自动跳过去。
     跳转时取消待发的防抖上报。（需要终端或 tmux 开启 focus events，否则只有打开书时会拉取。）
   - 新配置 `sync_pull = true`（false 关闭反向同步）。
6. `:checkhealth weread` / `progress.status()` 增加最近一次拉取的结果与时间。

## Files to modify

- `lua/weread/theme.lua`：重调 `paper`、`night`，`set()` 的提示
- `lua/weread/config.lua`：默认 `theme = "paper"`；新增 `sync_debounce`、`sync_pull`；记录显式传入的 theme
- `lua/weread/init.lua`：偏好只在配置没指定 theme 时生效；注册 Focus 相关 autocmd（或放在 reader 里）
- `lua/weread/progress.lua`：偏移与百分比、防抖、同步 flush、远端拉取与比较
- `lua/weread/reader.lua`：`source_offset`、续读流程先拉远端、按偏移定位、`CursorMoved / FocusLost / FocusGained / VimLeavePre` 钩子
- `lua/weread/shell.lua`：百分比改用共享函数
- `lua/weread/health.lua`：显示同步状态
- `README.md`：主题与同步说明
- `tests/spec/theme_spec.lua`、`tests/spec/progress_spec.lua`、`tests/spec/reader_spec.lua`、`tests/mock.lua`（为 `getprogress` 加 mock 路由）

## Reuse

- `xhtml.resolve(meta, from, to)`：源 rune → 渲染行（续读已经在用）
- `xhtml.rune_at(map, line, col, text)`、`reader.lua` 中的 `rune_of_line` / `chapter_map`：渲染位置 → 源 rune
- `shell.book_percent(index)`：按 wordCount 计算全书百分比
- `api_gateway.progress(book_id, cb)`：远端进度
- `timer.defer / stop`：可以停止的防抖定时器
- `http.request_sync`：退出时阻塞发送
- `cache.read_position`：本地位置与 `updated_at`
- `ui.notify(..., { routine = true })`：例行上报保持安静；跳转提示走非 routine

## Steps

- [x] theme：重调 `paper` / `night`，默认改为 `paper`；更新 theme_spec（默认值；fg/bg 对比度落在 7–10 之间的断言）
- [x] config/init：显式 `theme` 优先于 prefs，并补测试
- [x] reader：`source_offset()`，补测试（重排前后偏移不变）
- [x] progress：`build_payload` 改用源偏移、新百分比和 summary 清理，更新 progress_spec
- [x] progress：防抖上报（同一位置不重复上报），补测试
- [x] progress/reader：FocusLost 强制上报、VimLeavePre 同步 flush，补测试
- [x] progress/reader：远端拉取 + 比较 + 跳转；`enter()` 推迟到拉取之后；FocusGained，补测试（远端更新则跳、远端更旧不跳、拉取失败退回本地）
- [x] health、README 更新
- [x] `scripts/test.sh` 全量通过

## Verification

- `scripts/test.sh` 全量通过（mock gateway 覆盖 `getprogress` 与 `/web/book/read`）。
- 真实账号手测：
  1. 打开 nvim 读《人月神话》，确认是暖米底；`:checkhealth weread` 显示主题 `paper`。
  2. 翻到章中某句，停 5 秒后用 `api_gateway.progress` 查询（headless 脚本），`chapterOffset` 应与该句在 XHTML 中的下标一致。
  3. 手机 App 打开同一本书，确认跳到同一句附近。
  4. 在手机上往后读几段，切回终端（FocusGained）或重新 `:WeReadResume`，nvim 应跳到手机的位置并给出提示。
- 无法在本地自动验证的部分：App 端实际跳转的效果，以及 tmux 下 focus events 是否开启，需要用户手动确认。
