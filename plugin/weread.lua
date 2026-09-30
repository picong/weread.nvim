--[[
Command registration. Commands pull their modules in on demand so that opening
nvim costs nothing but a few `require` calls.
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

vim.api.nvim_create_user_command("WeReadLog", function()
  local config = require("weread.config")
  local path = require("weread.log").path()
  if path and vim.fn.filereadable(path) == 1 then
    vim.cmd("edit " .. vim.fn.fnameescape(path))
  else
    local lines = require("weread.log").tail(200)
    local float = require("weread.float").open({
      title = "weread.nvim 日志（内存，共 " .. #lines .. " 行）",
      width = math.min(100, vim.o.columns - 8),
      height = math.min(30, vim.o.lines - 8),
      lines = #lines > 0 and lines or { "（暂无日志；在 setup({ debug = true }) 后写入文件）" },
      filetype = "log",
    })
    if float then
      vim.keymap.set("n", "q", function()
        float:close()
      end, { buffer = float:get_buf(), nowait = true, silent = true })
    end
  end
end, { desc = "微信读书：查看运行日志" })", "oldText": "--[[\nCommand registration. Commands pull their modules in on demand so that\n`:WeReadLogin` costs nothing but a `require` at startup.\n(命令注册：按需加载模块，启动时只付出一次 require 的代价)\n]]\n\nif vim.g.loaded_weread_nvim then\n  return\nend\nvim.g.loaded_weread_nvim = 1\n\nlocal function weread()\n  local plugin = require(\"weread\")\n  plugin.ensure_setup()\n  return plugin\nend\n\nvim.api.nvim_create_user_command(\"WeReadLogin\", function(args)\n  if args.bang then\n    require(\"weread.auth\").logout()\n  end\n  weread().login({ force = args.bang })\nend, { bang = true, desc = \"微信读书：扫码登录（! 先清除旧凭据）\" })\n\nvim.api.nvim_create_user_command(\"WeReadLogout\", function()\n  weread().logout()\nend, { desc = \"微信读书：退出登录并清除本地凭据\" })\n\nvim.api.nvim_create_user_command(\"WeReadLog\", function()\n  local config = require(\"weread.config\")\n  local path = require(\"weread.log\").path()\n  if path and vim.fn.filereadable(path) == 1 then\n    vim.cmd(\"edit \" .. vim.fn.fnameescape(path))\n  else\n    local lines = require(\"weread.log\").tail(200)\n    local float = require(\"weread.float\").open({\n      title = \"weread.nvim 日志（内存，共 \" .. #lines .. \" 行）\",\n      width = math.min(100, vim.o.columns - 8),\n      height = math.min(30, vim.o.lines - 8),\n      lines = #lines > 0 and lines or { \"（暂无日志；在 setup({ debug = true }) 后写入文件）\" },\n      filetype = \"log\",\n    })\n    if float then\n      vim.keymap.set(\"n\", \"q\", function()\n        float:close()\n      end, { buffer = float:get_buf(), nowait = true, silent = true })\n    end\n  end\nend, { desc = \"微信读书：查看运行日志\" })"}]