# 阅读字体预览与字号 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**目标：**在 `:WeReadFont` 中为已安装字体提供诚实的预览信息，并持久化和应用小、中、大三档阅读字号。

**架构：**保留现有单一字体候选列表与 `weread.ui.select` 适配层。Snacks 路径提供只读预览页和悬停时的会话级真实 CJK 字体/字号试用；无 Snacks 时保留普通两阶段选择，绝不新增浮窗。字号属于偏好而非排版行高，`font.lua` 解析 profile 后将点数传入 `font_kitty.lua`；后者用既有串行 pump 将 family、行高与字号作为一个期望状态应用与恢复。

**技术栈：**Neovim 0.10+、Lua、Snacks picker（可选）、kitty remote control、fontconfig、项目内零依赖测试框架。

**规格：**本会话用户请求；设计取自现有 `/home/picong/projects/weread.nvim/lua/weread/font.lua`、`font_kitty.lua` 与 `ui.lua` 的边界。

## 全局约束

- 仅修改字体选择、会话应用、文档及其紧邻测试；不得覆盖工作树已有的无关改动。
- 保持 `:WeReadFont <字体名> [行高]` 语义兼容，`layout.line_height` 仍只表示 `modify_font=cell_height`。
- `preferences.json` 新增 `font_size = "small" | "medium" | "large"`；缺失或非法值按 `medium`，预设固定为 14、16、18 pt。
- 未安装的微信读书字体只能在确认后下载；预览不得网络请求、运行 `fc-cache`、写偏好或触发下载。
- Snacks 悬停试用不得并发启动 `kitten`，必须经已有 `desired`/`busy`/`pump` 收敛；无 UI/headless 不运行终端命令。
- kitty 用 `kitten @ set-font-size <pt>`，不传 `--all`；离开章节以 `set-font-size 0` 重置到 kitty 默认字号。
- kitty 无法精确恢复用户进入阅读前的临时 zoom，状态与文档必须说明该限制；同一 OS window 的子窗口会随之改变。
- TUI/kitty 无法只给 Snacks preview buffer 指定字体。已安装字体的“真实预览”是悬停时整套当前 OS window 的 CJK `symbol_map` 试用；拉丁文和 Nerd Font 仍用终端字体。未安装项必须明确说明尚不能真实预览。
- 注释保持英文并附括号中文说明；不新增依赖，不改 kitty.conf，不自动下载字体。

## 审查重点

- 快速移动光标、前一个 kitty 请求未返回时，最终只能应用最后悬停的 family/字号；在任务 2 的 busy 合并测试覆盖。
- 选择器打开后离开章节或从非章节打开，确认、取消、下载完成都不得碰终端；在任务 3 的来源章节矩阵覆盖。
- 字号从有 `font_size` 的 kitty 命令行启动覆盖恢复时，不能遗失该覆盖；在任务 2 的 restore argv 测试覆盖。
- 未安装目录字体的预览必须标出“选择后下载”，且光标移动不调用 `ensure_by_name`；在任务 3 覆盖。
- 无 Snacks 的 `vim.ui.select` 回退不执行 `preview`、`on_change` 或临时试用，但仍能保存字体和字号；在任务 3 覆盖。

---

### Task 1: 字号 profile 与偏好接口

**文件：**
- 修改：`/home/picong/projects/weread.nvim/lua/weread/font.lua:162-237,305-430,453-536`
- 修改：`/home/picong/projects/weread.nvim/tests/spec/font_spec.lua`

**接口：**
- 产出：`font.size() -> { key: "small"|"medium"|"large", pt: integer, label: string }`。
- 产出：`font.set_size(key, opts?) -> boolean, string`，写入 `prefs.font_size` 并以 `font_session.refresh(opts.from_chapter)` 应用当前章节。
- 扩展：`font.apply*(_, opts)`、`remember(_, fields)`、`activate()` 接受/保留 `opts.font_size` 或 profile 对应 pt；`clear()` 删除 `prefs.font_size`。

- [ ] **步骤 1：写失败测试**：断言缺失和非法 `prefs.font_size` 解析为 `{ key = "medium", pt = 16, label = "中" }`，三档分别为 14/16/18，重置 prefs 缓存后仍能读回；断言 `set_size("small")` 写入键并向 session 传入来源章节。
- [ ] **步骤 2：运行字体测试确认失败**：运行 `sh /home/picong/projects/weread.nvim/scripts/test.sh font`；预期因 `font.size`/`font.set_size` 不存在而失败。
- [ ] **步骤 3：实现 profile、持久化和应用传参**：在 `font.lua` 集中定义 profile；`activate()` 将 `font.size().pt` 作为 `font_kitty.set(..., { font_size = ... })` 参数，异步下载完成后的 `remember` 不得丢失字号。
- [ ] **步骤 4：运行字体测试确认通过**：运行同一命令；预期全部通过。
- [ ] **步骤 5：提交**：`git add lua/weread/font.lua tests/spec/font_spec.lua && git commit -m "feat: persist reading font size"`。

### Task 2: kitty 与 GUI 会话字号状态机

**文件：**
- 修改：`/home/picong/projects/weread.nvim/lua/weread/font_kitty.lua:42-102,516-750`
- 修改：`/home/picong/projects/weread.nvim/tests/spec/font_spec.lua`

**接口：**
- 消费：`font_kitty.set(family, { line_height?, font_size?, on_error? })` 中 `font_size` 为正整数 pt。
- 产出：`font_kitty.status()` 增加 `font_size` 和 `original_font_size`。
- 行为：kitty 先执行既有 `load-config`，成功后执行 `set-font-size <pt>`；恢复先执行原字体恢复，再执行 `set-font-size 0`。GUI 使用 `guifont=<family>:h<pt>`，恢复原 `guifont`/`linespace`。

- [ ] **步骤 1：写失败测试**：断言 16 pt 依次调用 `load-config` 与 `set-font-size 16`；仅字号改变也触发一次新字号请求；`clear()` 和 `restore_sync()` 在字体恢复后执行 `set-font-size 0`；命令行 `font_size=15` 不被覆盖丢失；GUI 接到 18 pt 时写入 `:h18` 并恢复快照。
- [ ] **步骤 2：运行字体测试确认失败**：运行 `sh /home/picong/projects/weread.nvim/scripts/test.sh font`；预期缺少字号 argv 或 GUI `desired.font_size` 未保存。
- [ ] **步骤 3：实现扩展状态与串行阶段**：将字号写入 `state.desired`，把状态去重比较扩展到字号；以小型内部阶段/回调串接第二条 kitty 命令，保留 busy 至整个转换完成，下一轮 pump 只读取最新 desired。
- [ ] **步骤 4：补充 busy 合并测试并验证**：让第一次回调暂停，连续设 14、18 pt 后完成第一次请求；断言最终只收敛至 18 pt，不回放陈旧请求。运行字体测试，预期通过。
- [ ] **步骤 5：提交**：`git add lua/weread/font_kitty.lua tests/spec/font_spec.lua && git commit -m "feat: apply reading font size by session"`。

### Task 3: 选择器预览、确认流程与回退

**文件：**
- 修改：`/home/picong/projects/weread.nvim/lua/weread/font.lua:576-720`
- 修改：`/home/picong/projects/weread.nvim/lua/weread/ui.lua:22-84`（仅在适配层测试暴露需要时）
- 修改：`/home/picong/projects/weread.nvim/tests/spec/font_spec.lua`
- 新建：`/home/picong/projects/weread.nvim/tests/spec/ui_spec.lua`

**接口：**
- 产出：`font.snacks_preview(ctx)`：使用 `ctx.preview:reset()`、`set_title()`、`set_lines()` 渲染字体名、来源、安装状态、当前字号和中文主样张 `春眠不觉晓，处处闻啼鸟`，以及 Latin/数字限制说明。
- 产出：`font.preview(item, from_chapter)`：只对已安装且来源章节仍有效的字体临时调用 `font_kitty.set`；不写 prefs。
- 行为：字体确认后再显示“阅读字号”菜单，候选为“小 · 14 pt”“中 · 16 pt”“大 · 18 pt”；取消字号菜单保留原字号且不提交刚选的字体。Snacks `on_close(false)` 恢复选择器打开时已保存的字体与字号；确认后不再恢复。

- [ ] **步骤 1：写失败预览与条目测试**：伪造 `ctx.preview`，分别断言本机、已安装微信读书、待下载微信读书与跟随终端的标题和文本；待下载项包含“选择后下载，当前无法真实预览”。断言 `ui.select` 收到 `preview`、`on_change`、`on_close`，预览不调用下载或 prefs。
- [ ] **步骤 2：写失败选择流程测试**：打桩两个 `ui.select` 回调，断言选择字体后才展示三档字号、确认“小”保存 profile 并在原章节立即应用；取消第二菜单不改变字体或字号；Esc 在 Snacks 中恢复选择器打开时的状态；离开来源章节、非章节、未安装条目悬停的安全矩阵均不调用终端或下载。
- [ ] **步骤 3：运行新旧测试确认失败**：运行 `sh /home/picong/projects/weread.nvim/scripts/test.sh font` 与 `sh /home/picong/projects/weread.nvim/scripts/test.sh ui`；预期缺失回调、预览或第二菜单。
- [ ] **步骤 4：实现静态 preview 和受限悬停试用**：在 picker 条目保留 `kind/family/id/name` 并加安装元数据与样张；使用现有 `ui.select` hooks，给悬停调用加短 debounce，关闭时取消；不要在 `vim.ui.select` 路径传递或执行预览/试用。
- [ ] **步骤 5：实现回退验证并运行测试**：新增 `ui_spec.lua`，模拟 Snacks 缺失时验证 `preview`/`on_change` 不被调用且两阶段确认仍交给 `on_choice`。运行两个定向命令，预期通过。
- [ ] **步骤 6：提交**：`git add lua/weread/font.lua lua/weread/ui.lua tests/spec/font_spec.lua tests/spec/ui_spec.lua && git commit -m "feat: preview reading fonts and choose size"`。

### Task 4: 命令、状态和文档

**文件：**
- 修改：`/home/picong/projects/weread.nvim/plugin/weread.lua:489-525`
- 修改：`/home/picong/projects/weread.nvim/lua/weread/font.lua:490-536,697-720`
- 修改：`/home/picong/projects/weread.nvim/README.md:148,350-366,503-509`
- 修改：`/home/picong/projects/weread.nvim/doc/weread.txt:200-207`
- 修改：`/home/picong/projects/weread.nvim/tests/spec/font_spec.lua`

**接口：**
- 扩展：`:WeReadFont size small|medium|large`；`font.complete()` 返回 `size` 和三档 key，同时保留字体名与原有子命令。
- 扩展：`font.status()` 显示“阅读字号：中（16 pt）”；kitty 状态另说明仅当前 OS window、离开重置默认字号、不能还原先前临时 zoom。

- [ ] **步骤 1：写失败命令与状态测试**：加载插件后执行 `WeReadFont size large`，断言调用 `font.set_size("large")`；断言补全含 `size/small/medium/large`，状态有当前档位和 kitty 恢复限制。
- [ ] **步骤 2：运行字体测试确认失败**：运行 `sh /home/picong/projects/weread.nvim/scripts/test.sh font`；预期命令解析或状态文本断言失败。
- [ ] **步骤 3：实现显式子命令与文档**：优先识别 `size`，其他输入继续走 `parse_command`；README 与 help 明示 Snacks 的已安装字体悬停预览、未安装项限制、无 Snacks 的无预览回退及 kitty 影响范围。
- [ ] **步骤 4：执行完整验证**：运行 `sh /home/picong/projects/weread.nvim/scripts/test.sh font`，再运行 `sh /home/picong/projects/weread.nvim/scripts/test.sh`；预期全绿。
- [ ] **步骤 5：提交**：`git add plugin/weread.lua lua/weread/font.lua README.md doc/weread.txt tests/spec/font_spec.lua && git commit -m "docs: document reading font preview and size"`。

## 明确不做

- 不为每个字体生成截图、引入字体渲染服务、预下载字体或缓存预览图。
- 不在 TUI 中伪称 preview buffer 局部渲染候选字体；未安装字体不做真实预览。
- 不修改 `layout.line_height` 的语义，也不将字号做成连续滑块或任意 pt 输入。
- 不使用 kitty `--all`，不更改 kitty.conf，不试图恢复无法查询的临时 zoom。
- 不新增独立字体大小命令或配置项；入口保持 `:WeReadFont` 与其 `size` 子命令。
