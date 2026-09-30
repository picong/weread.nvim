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

vim.api.nvim_create_user_command("WeReadLogin", function(args)
  if args.bang then
    require("weread.auth").logout()
  end
  weread().login({ force = args.bang })
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

vim.api.nvim_create_user_command("WeReadNext", function()
  require("weread.reader").next_chapter()
end, { desc = "微信读书：下一章" })

vim.api.nvim_create_user_command("WeReadPrev", function()
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

vim.api.nvim_create_user_command("WeReadLog", function()
  local path = require("weread.log").path()
  if path and vim.fn.filereadable(path) == 1 then
    vim.cmd("edit " .. vim.fn.fnameescape(path))
    return
  end
  local lines = require("weread.log").tail(200)
  local float = require("weread.float").open({
    title = string.format("weread.nvim 日志（内存，共 %d 行）", #lines),
    width = math.min(100, vim.o.columns - 8),
    height = math.min(30, vim.o.lines - 8),
    lines = #lines > 0 and lines or { "暂无日志；在 setup({ debug = true }) 之后会写入文件" },
    filetype = "log",
  })
  if float then
    vim.keymap.set("n", "q", function()
      float:close()
    end, { buffer = float:get_buf(), nowait = true, silent = true })
  end
end, { desc = "微信读书：查看运行日志" })
