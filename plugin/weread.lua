--[[
Command registration. Commands pull their modules in on demand, so opening nvim
costs nothing but a few `require` calls.
(命令注册：按需加载模块，启动时只付出少量 require 的代价)
]]

if vim.g.loaded_weread_nvim then
  return
end
vim.g.loaded_weread_nvim = 1

local function weread()
  local plugin = require("weread")
  plugin.ensure_setup()
  return plugin
end

local function require_login()
  local auth = require("weread.auth")
  if not auth.is_logged_in() then
    vim.notify("weread: 尚未登录，请先执行 :WeReadLogin", vim.log.levels.WARN)
    return false
  end
  return true
end

---Open a read-only list in a float sized to fit the screen. The float closes with
---q / <Esc> / <C-c> by default, so no extra keymap is needed.
---(开一个按屏幕大小收缩的只读列表浮窗；float 默认就绑了 q / <Esc> / <C-c> 关闭，无需另绑)
---@param opts table weread.float options; width/height are upper bounds(float 选项；width/height 是上限)
local function open_list_float(opts)
  require("weread.float").open(vim.tbl_extend("force", opts, {
    width = math.min(opts.width, vim.o.columns - 8),
    height = math.min(opts.height, vim.o.lines - 8),
  }))
end

vim.api.nvim_create_user_command("WeReadLogin", function(args)
  -- set up first: logout() clears the cookie jar, which needs http.setup()
  -- (先 setup：logout() 要清 cookie jar，而那依赖 http.setup())
  local plugin = weread()
  if args.bang then
    require("weread.auth").logout()
  end
  plugin.login({ force = args.bang })
end, { bang = true, desc = "微信读书：扫码登录（! 先清除旧凭据）" })

vim.api.nvim_create_user_command("WeReadLogout", function()
  weread().logout()
end, { desc = "微信读书：退出登录并清除本地凭据" })

vim.api.nvim_create_user_command("WeRead", function(args)
  weread()
  if not require_login() then
    return
  end
  local reader = require("weread.reader")
  local keyword = vim.trim(args.args or "")
  if keyword == "" then
    reader.pick_book()
  else
    reader.search_book(keyword)
  end
end, { nargs = "?", desc = "微信读书：书架（带关键词则搜索书城）" })

vim.api.nvim_create_user_command("WeReadSearch", function(args)
  weread()
  if not require_login() then
    return
  end
  require("weread.reader").search_book(args.args)
end, { nargs = "+", desc = "微信读书：搜索书城" })

vim.api.nvim_create_user_command("WeReadOpen", function(args)
  weread()
  if not require_login() then
    return
  end
  require("weread.reader").open_query(args.args)
end, { nargs = "?", desc = "微信读书：打开书（bookId / 书名 / 留空则续读上次）" })

vim.api.nvim_create_user_command("WeReadResume", function()
  weread()
  if not require_login() then
    return
  end
  require("weread.reader").resume()
end, { desc = "微信读书：继续上次阅读" })

vim.api.nvim_create_user_command("WeReadToc", function()
  weread()
  local reader = require("weread.reader")
  if not reader.state.book then
    vim.notify("weread: 还没有打开任何书", vim.log.levels.WARN)
    return
  end
  reader.toc()
end, { desc = "微信读书：目录" })

vim.api.nvim_create_user_command("WeReadStats", function(args)
  weread()
  if not require_login() then
    return
  end
  local modes = { week = "weekly", month = "monthly", year = "annually", all = "overall" }
  require("weread.stats").open(modes[args.args] or args.args)
end, {
  nargs = "?",
  complete = function()
    return { "week", "month", "year", "all" }
  end,
  desc = "微信读书：阅读统计（week/month/year/all）",
})

vim.api.nvim_create_user_command("WeReadHide", function()
  weread()
  require("weread.reader").hide()
end, { desc = "微信读书：速隐 / 回到刚才藏起的章节" })

vim.api.nvim_create_user_command("WeReadBookmarks", function()
  weread()
  require("weread.bookmarks").pick()
end, { desc = "微信读书：书签列表" })

vim.api.nvim_create_user_command("WeReadBookmark", function()
  weread()
  require("weread.bookmarks").toggle()
end, { desc = "微信读书：在光标行加书签 / 删书签" })

vim.api.nvim_create_user_command("WeReadFind", function(args)
  weread()
  require("weread.bookmarks").search_pick(args.args)
end, { nargs = "?", desc = "微信读书：书内搜索（只搜已下载的章节）" })

vim.api.nvim_create_user_command("WeReadExport", function(args)
  weread()
  if not require_login() then
    return
  end
  require("weread.export").run(args.args)
end, {
  nargs = "?",
  complete = function()
    return { "qf" }
  end,
  desc = "微信读书：导出本书划线与想法（留空 = Markdown 文件，qf = quickfix，或给文件路径）",
})

vim.api.nvim_create_user_command("WeReadEpub", function(args)
  weread()
  require("weread.epub").run(args.args)
end, {
  nargs = "*",
  complete = function()
    local words = { "only", "bilingual", "cached", "local", "upload", "status", "stop" }
    for _, model in ipairs((require("weread.config").get().lookup or {}).chapter_models or {}) do
      words[#words + 1] = model
    end
    return words
  end,
  desc = "微信读书：把整本书连同大模型译文导出成 EPUB 并传到书架（没下载、没翻译的章节先下载翻译；bilingual = 双语，cached = 只用已有的，local = 不上传，upload = 只上传上次的导出，status = 进度，stop = 停止）",
})

---Is the current buffer a chapter? Says so when it is not.
---(当前 buffer 是不是章节；不是时提示)
---@return boolean
local function in_chapter()
  if require("weread.reader").buffer_info(vim.api.nvim_get_current_buf()) then
    return true
  end
  vim.notify("weread: 当前不在章节 buffer 中", vim.log.levels.WARN)
  return false
end

---Is a book open? Says so when none is. (有没有打开书；没有时提示)
---@return boolean
local function book_open()
  if require("weread.reader").state.book then
    return true
  end
  vim.notify("weread: 还没有打开书，先用 :WeReadShelf 选一本", vim.log.levels.WARN)
  return false
end

vim.api.nvim_create_user_command("WeReadNext", function()
  if not book_open() then
    return
  end
  require("weread.reader").next_chapter()
end, { desc = "微信读书：下一章" })

vim.api.nvim_create_user_command("WeReadPrev", function()
  if not book_open() then
    return
  end
  require("weread.reader").prev_chapter()
end, { desc = "微信读书：上一章" })

vim.api.nvim_create_user_command("WeReadChapter", function(args)
  weread()
  local position = tonumber(args.args)
  if not position or position < 1 then
    vim.notify("weread: 需要一个正整数章节序号", vim.log.levels.ERROR)
    return
  end
  require("weread.reader").goto_readable_position(math.floor(position))
end, { nargs = 1, desc = "微信读书：跳到第 n 章（按可读章节计数）" })

vim.api.nvim_create_user_command("WeReadRefresh", function()
  if not in_chapter() then
    return
  end
  require("weread.reader").reload()
end, { desc = "微信读书：重新抓取当前章节" })

vim.api.nvim_create_user_command("WeReadSync", function()
  local ok, progress = pcall(require, "weread.progress")
  if not ok then
    vim.notify("weread: 进度模块未加载", vim.log.levels.WARN)
    return
  end
  progress.sync_now()
end, { desc = "微信读书：立即回传阅读进度" })

vim.api.nvim_create_user_command("WeReadAnnotations", function(args)
  local ok, annotations = pcall(require, "weread.annotations")
  if not ok then
    vim.notify("weread: 划线模块未加载", vim.log.levels.WARN)
    return
  end
  if args.bang then
    annotations.refresh(true)
  else
    annotations.show_chapter_summary()
  end
end, { bang = true, desc = "微信读书：本章划线与想法（! 重新拉取）" })

---The lines a command was given (`:5Cmd`, `:1,3Cmd`, a visual selection), or nil
---when it was typed without a range.
---(命令带的行范围（`:5Cmd`、`:1,3Cmd`、可视选区），没带范围则为 nil)
---@param args table command callback argument
---@return integer|nil first
---@return integer|nil last
local function command_lines(args)
  if args.range == 0 then
    return nil, nil
  end
  return args.line1, args.line2
end

---Buffer positions covering whole lines, from the first line's text to the end of
---the last one. The paragraph indent is layout, not text, and has no source rune
---to map to, so the span starts after it.
---(覆盖整行的 buffer 位置：从首行的正文起到末行行尾。段落缩进是排版而不是正文，没有可映射的
--- 源 rune，因此区间从缩进之后开始)
---@param buf integer
---@param first integer
---@param last integer
---@return integer[] from
---@return integer[] to
local function line_span(buf, first, last)
  local text = vim.api.nvim_buf_get_lines(buf, first - 1, first, false)[1] or ""
  local head = math.max(vim.fn.match(text, "[^ \t　]"), 0)
  local tail = vim.api.nvim_buf_get_lines(buf, last - 1, last, false)[1] or ""
  return { first, head }, { last, #tail }
end

vim.api.nvim_create_user_command("WeReadHighlight", function(args)
  local ok, annotations = pcall(require, "weread.annotations")
  if not ok then
    vim.notify("weread: 划线模块未加载", vim.log.levels.WARN)
    return
  end
  if not in_chapter() then
    return
  end
  local buf = vim.api.nvim_get_current_buf()
  local first, last = command_lines(args)
  local good, message
  if not first then
    good, message = annotations.highlight_line(buf, vim.fn.line("."))
  elseif first == last then
    good, message = annotations.highlight_line(buf, first)
  else
    -- a range of lines: highlight all of them
    -- (一段行范围：整段划线)
    good, message = annotations.highlight(buf, line_span(buf, first, last))
  end
  vim.notify(message, good and vim.log.levels.INFO or vim.log.levels.WARN)
end, { nargs = 0, range = true, desc = "微信读书：给当前行/选中行画线（同步到微信读书）" })

vim.api.nvim_create_user_command("WeReadUnhighlight", function(args)
  local ok, annotations = pcall(require, "weread.annotations")
  if not ok or not in_chapter() then
    return
  end
  local buf = vim.api.nvim_get_current_buf()
  if args.bang then
    -- `!` is the way out when something is stuck: forget every highlight made
    -- here in the chapter, taking the synced ones off the account as well (the
    -- ones drawn in the app are untouched).
    -- (`!` 是卡住时的退路：忘掉本章所有在这里画的划线，已同步的也从账号里删掉（在 App 里画的
    --  不受影响）)
    local removed = annotations.clear_local(buf)
    vim.notify(string.format("weread: 已清掉本章 %d 条在这里画的划线", removed), vim.log.levels.INFO)
    return
  end
  local first, last = command_lines(args)
  if first then
    local removed = annotations.unhighlight_range(buf, line_span(buf, first, last))
    vim.notify(string.format("weread: 已取消 %d 条划线", removed), vim.log.levels.INFO)
    return
  end
  local good, message = annotations.unhighlight(buf, vim.fn.line(".") - 1)
  vim.notify(message, good and vim.log.levels.INFO or vim.log.levels.WARN)
end, { nargs = 0, bang = true, range = true, desc = "微信读书：取消划线（! 清空本章在这里画的，可带行范围）" })

vim.api.nvim_create_user_command("WeReadNote", function(args)
  local ok, annotations = pcall(require, "weread.annotations")
  if not ok then
    return
  end
  local buf = vim.api.nvim_get_current_buf()
  local text = vim.trim(args.args or "")
  local entry = annotations.entry_at(buf, vim.fn.line(".") - 1)
  if not entry then
    vim.notify("weread: 光标处没有划线，先用 <leader>wh 划一条", vim.log.levels.WARN)
    return
  end
  if text == "" then
    annotations.compose_thought(buf, entry.annotation.range, entry.annotation.text or "")
    return
  end
  annotations.write_thought(buf, entry.annotation.range, entry.annotation.text or "", text)
end, { nargs = "?", desc = "微信读书：给光标处的划线写想法（不带参数则打开输入框）" })

vim.api.nvim_create_user_command("WeReadDeleteNote", function()
  local ok, annotations = pcall(require, "weread.annotations")
  if not ok then
    return
  end
  local buf = vim.api.nvim_get_current_buf()
  local entry = annotations.entry_at(buf, vim.fn.line(".") - 1)
  if not entry then
    vim.notify("weread: 光标处没有划线", vim.log.levels.WARN)
    return
  end
  local range = entry.annotation.range
  -- The local copy carries the review id, so this works for a thought written
  -- moments ago, before the next readreviews fetch.
  -- (本地副本带着 review id，因此刚写完、还没重新拉取时也能删)
  local mine = annotations.my_thought_for(buf, range)
  if not mine then
    vim.notify("weread: 这条划线下没有我写的想法", vim.log.levels.WARN)
    return
  end
  vim.ui.input({
    prompt = string.format("删掉这条想法？「%s」(y/N) ", vim.fn.strcharpart(mine.content or "", 0, 20)),
  }, function(answer)
    if not answer or answer:lower() ~= "y" then
      return
    end
    annotations.delete_thought_at(buf, range, function(deleted, message)
      vim.notify(message, deleted and vim.log.levels.INFO or vim.log.levels.WARN)
    end)
  end)
end, { nargs = 0, desc = "微信读书：删除我在光标处划线下写的想法" })

vim.api.nvim_create_user_command("WeReadTranslate", function(args)
  weread()
  local value = vim.trim(args.args or "")
  if value == "only" then
    require("weread.reader").toggle_translation_only()
    return
  end
  local on = nil
  if value == "on" then
    on = true
  elseif value == "off" then
    on = false
  end
  require("weread.reader").toggle_translation(on)
end, {
  nargs = "?",
  complete = function()
    return { "on", "off", "only" }
  end,
  desc = "微信读书：译文（全文翻译；留空切换 / on / off / only 只看译文）",
})

vim.api.nvim_create_user_command("WeReadZone", function(args)
  weread()
  local name = vim.trim(args.args or "")
  require("weread.zone").play(name ~= "" and name or nil)
end, {
  nargs = "?",
  complete = function()
    return require("weread.zone").SCENES
  end,
  desc = "微信读书：发会儿呆（rain 字落如雨 / life 生命游戏 / fire 像素壁炉；任意键回到书页）",
})

vim.api.nvim_create_user_command("WeReadSprites", function()
  weread()
  if not require("weread.sprites").gallery() then
    vim.notify("weread: 在章节里才能看像素小画（或动画已关闭）", vim.log.levels.WARN)
  end
end, { desc = "微信读书：把所有像素小画依次放一遍" })

vim.api.nvim_create_user_command("WeReadTrophy", function()
  weread()
  if not require("weread.milestone").trophy({ force = true }) then
    vim.notify("weread: 先打开一本书", vim.log.levels.WARN)
  end
end, { desc = "微信读书：这本书的读完卡片（s 存成 Markdown）" })

vim.api.nvim_create_user_command("WeReadTheme", function(args)
  weread()
  local theme = require("weread.theme")
  local name = vim.trim(args.args or "")
  if name == "global" then
    theme.forget_book()
  elseif name == "" then
    theme.picker({ book = args.bang })
  elseif name == "next" or name == "prev" then
    theme.cycle(name == "next" and 1 or -1)
  else
    theme.set(name, { book = args.bang })
  end
end, {
  nargs = "?",
  complete = function(lead)
    local theme = require("weread.theme")
    return vim.tbl_filter(function(name)
      return name:find(lead:lower(), 1, true) == 1
    end, vim.list_extend(theme.choices(), { "next", "prev", "global" }))
  end,
  bang = true,
  desc = "微信读书：阅读主题（留空打开选择器 / 主题名 / auto / none / next / prev；! 只给这本书，global 让这本书跟随全局）",
})

vim.api.nvim_create_user_command("WeReadWidth", function(args)
  weread()
  local value = vim.trim(args.args or "")
  local reader = require("weread.reader")
  local step = require("weread.layout").STEP
  if value == "" then
    local chars = math.floor((reader.page_width() or 0) / 2)
    vim.notify(chars > 0 and string.format("weread: 每行 %d 字", chars) or "weread: 版心未启用（用满窗口）")
  elseif value == "+" or value == "-" then
    reader.set_page_chars(nil, value == "+" and step or -step)
  elseif tonumber(value) then
    reader.set_page_chars(tonumber(value))
  else
    vim.notify("weread: 用法 :WeReadWidth [字数|+|-]", vim.log.levels.ERROR)
  end
end, { nargs = "?", desc = "微信读书：每行字数（留空查看 / 字数 / + / -）" })

vim.api.nvim_create_user_command("WeReadDict", function(args)
  weread()
  local ecdict = require("weread.ecdict")
  local action, rest = vim.trim(args.args or ""):match("^(%S*)%s*(.-)$")
  local function report(ok, message)
    vim.notify("weread: " .. message, ok and vim.log.levels.INFO or vim.log.levels.ERROR)
  end
  if action == "" or action == "status" then
    if ecdict.available() then
      vim.notify("weread: 离线词典已就绪：" .. ecdict.path())
    else
      vim.notify("weread: 离线词典未安装（:WeReadDict install），查词暂走在线词典")
    end
  elseif action == "install" then
    vim.notify("weread: 正在下载 ECDICT（约 66MB），完成后会提示；期间可以照常阅读")
    ecdict.install(rest ~= "" and rest or nil, report)
  elseif action == "build" and rest ~= "" then
    vim.notify("weread: 正在导入 " .. rest)
    ecdict.build(vim.fn.fnamemodify(vim.fn.expand(rest), ":p"), report)
  else
    vim.notify("weread: 用法 :WeReadDict [status | install [镜像地址] | build <ecdict.csv>]", vim.log.levels.ERROR)
  end
end, {
  nargs = "*",
  complete = function()
    return { "status", "install", "build" }
  end,
  desc = "微信读书：离线英汉词典（ECDICT）",
})

vim.api.nvim_create_user_command("WeReadFont", function(args)
  weread()
  local font = require("weread.font")
  local value = vim.trim(args.args or "")
  if value == "" then
    font.picker()
    return
  end
  if value == "status" then
    vim.notify("weread: " .. font.status())
    return
  end
  if value == "list" then
    vim.notify("weread: " .. table.concat(font.list_lines(), "\n"))
    return
  end
  local ok, message
  if value == "off" then
    ok, message = font.clear()
  elseif value == "restore" then
    ok, message = font.restore()
  elseif value == "enable" then
    ok, message = font.enable()
  elseif value == "cleanup" then
    ok, message = font.cleanup()
  else
    local name, line_height = font.parse_command(value)
    ok, message = font.apply(name, { line_height = line_height })
  end
  vim.notify("weread: " .. message, ok and vim.log.levels.INFO or vim.log.levels.ERROR)
end, {
  nargs = "*",
  complete = function(lead)
    return require("weread.font").complete(lead)
  end,
  desc = "微信读书：阅读字体（留空选择 / status / list / 字体名 [行距] / off / restore / enable / cleanup）",
})

vim.api.nvim_create_user_command("WeReadLog", function()
  local path = require("weread.log").path()
  if path and vim.fn.filereadable(path) == 1 then
    vim.cmd("edit " .. vim.fn.fnameescape(path))
    return
  end
  local lines = require("weread.log").tail(200)
  open_list_float({
    title = string.format("weread.nvim 日志（内存，共 %d 行）", #lines),
    width = 100,
    height = 30,
    lines = #lines > 0 and lines or { "暂无日志；在 setup({ debug = true }) 之后会写入文件" },
    filetype = "log",
  })
end, { desc = "微信读书：查看运行日志" })
