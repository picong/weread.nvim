# 阅读链路稳定性与预取优化 Implementation Plan

> 执行方式：在当前会话直接实现并验证。用户已授权检查和优化；保留工作区现有改动，不提交 Git。

**Goal:** 修复快速切章、缓存写入失败和刷新不更新正文的问题，并减少无效预取。

**Architecture:** 保持现有 reader/session/chapter_pipeline/reader_window 分工。通过请求身份检查处理异步乱序，沿现有回调传递缓存错误，复用 timer 模块合并延迟预取，不新增依赖或配置。

**Tech Stack:** Lua、Neovim >= 0.10、现有零依赖 spec 框架与本地 HTTP mock。

**Spec:** 本轮用户请求；仓库 AGENTS.md 的阅读流水线、缓存、测试规范。

## Global Constraints

- 保留全部既有未提交改动、公开接口与版权声明。
- 注释采用英文加括号中文；日志使用英文。
- 全部验证离线，不访问真实账号。
- 回调乱序、磁盘失败必须用回归用例复现。

## Review Focus

- 同一窗口先请求 A 再请求 B，A 最后返回：页面停在 B。
- 请求期间窗口换成普通 buffer：结果可缓存，不能替换普通 buffer。
- 刷新替换了在途下载：旧下载不能覆盖新缓存，所有等待者仍结束。
- XHTML/Markdown/map/CSS 写入失败：不报告成功，不因磁盘错误重复联网。
- 连续切章与预取让步期间有新目标：只执行最新的延迟预取。

## Task 1：异步章节请求与缓存刷新

**Files:** `lua/weread/reader.lua`、`lua/weread/reader_window.lua`、`tests/spec/reader_async_spec.lua`。

**Interfaces:** 保持 `open_index(index, opts)`；内部请求按窗口区分。刷新时让已存在的 buffer 重新读盘。

- [ ] 添加乱序回调、切离 buffer、独立窗口、强制刷新回归用例。
- [ ] 运行 `sh scripts/test.sh reader_async`，确认对应用例失败。
- [ ] 实现请求身份校验与刷新重读。
- [ ] 重跑相关 spec。

## Task 2：缓存错误与过期下载

**Files:** `lua/weread/chapter_pipeline.lua`、`tests/spec/chapter_pipeline_spec.lua`。

**Interfaces:** 保持 `ensure_cached(book, chapter, callback)`；失败以 `callback(false, err)` 结束，所有合并等待者各结束一次。

- [ ] 添加各缓存文件写入失败、失败后重试、旧下载晚到的用例。
- [ ] 运行 `sh scripts/test.sh chapter_pipeline`，确认用例暴露问题。
- [ ] 传递写入错误；区分缺少源文和本地写入失败；禁止过期请求继续写缓存。
- [ ] 重跑相关 spec，并检查已有刷新等待者用例。

## Task 3：合并延迟预取

**Files:** `lua/weread/chapter_pipeline.lua`、`lua/weread/reader.lua`、`tests/spec/chapter_pipeline_spec.lua`。

**Interfaces:** 保留 `schedule_prefetch(book, index)`，增加内部可调用的取消入口；使用 `weread.timer`。

- [ ] 添加连续调度与延迟重试被新目标替换的用例。
- [ ] 确认旧实现会执行多余预取。
- [ ] 新目标取消旧定时器，保留现有空闲判断与最多让步次数。
- [ ] 运行相关 spec，再运行 `sh scripts/test.sh` 全量验证。

## 执行记录

- 修改前源码与 diff 已保存在 `/tmp/weread-optimize.sAqyau/`。
- 基线测试正在执行，结果写入同目录 `baseline.log`。
