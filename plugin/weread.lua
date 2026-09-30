--[[
Command registration. Commands pull their modules in on demand so that
`:WeReadLogin` costs nothing but a `require` at startup.
(命令注册：按需加载模块，启动时只付出一次 require 的代价)
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

vim.api.nvim_create_user_command("WeReadLogin", function(args)
  if args.bang then
    require("weread.auth").logout()
  end
  weread().login({ force = args.bang })
end, { bang = true, desc = "微信读书：扫码登录（! 先清除旧凭据）" })

vim.api.nvim_create_user_command("WeReadLogout", function()
  weread().logout()
end, { desc = "微信读书：退出登录并清除本地凭据" })

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
end, { desc = "微信读书：查看运行日志" })
