--[[
Tests for weread.qr.

This spec exists because the image branch of `qr.show` used to be dead code in
CI: headless terminals report no kitty support, so every test took the ASCII
path and a crash in the PNG path (`png_size` returns two values, only one was
captured) went unnoticed until it hit a real kitty user.
(本 spec 的由来：qr.show 的图片分支曾是测试盲区 —— headless 终端不支持 kitty，
 所有测试都走 ASCII 分支，于是 PNG 路径上的崩溃（png_size 返回两个值却只接了一个）
 一直没被发现，直到真实 kitty 用户踩到)
]]

local qr = require("weread.qr")

local tmpdir = "/tmp/weread-test-qr"
vim.fn.delete(tmpdir, "rf")
vim.fn.mkdir(tmpdir, "p")

local URL = "https://weread.qq.com/web/confirm?uid=test-uid"

---Close the floating window a dialog opened, if any.
---(关闭对话打开过的浮窗)
local function close(dialog)
  if dialog and dialog.float then
    pcall(function()
      dialog.float:close()
    end)
  end
end

describe("qr.encode", function()
  it("writes a real PNG with qrencode", function()
    local path = tmpdir .. "/plain.png"
    local ok, err = qr.encode(URL, path)
    truthy(ok, tostring(err))
    eq(vim.fn.getfsize(path) > 0, true, "png written")

    local file = io.open(path, "rb")
    local magic = file:read(8)
    file:close()
    eq(magic, "\137PNG\r\n\26\n", "png magic")
  end)

  it("returns an error instead of raising for an unwritable target", function()
    local ok, err = qr.encode(URL, "/proc/definitely/not/writable/qr.png")
    falsy(ok)
    truthy(err ~= nil, "an error message came back")
    matches(err, "无法创建目录")
  end)
end)

describe("qr.encode_ascii", function()
  it("returns block art lines", function()
    local lines, err = qr.encode_ascii(URL)
    truthy(lines, tostring(err))
    truthy(#lines > 10, "a QR code has quite a few rows: " .. #lines)
    -- the top rows are the quiet zone, so the modules start further down
    -- (顶部几行是静默区，模块从更靠下的行开始)
    local has_module = false
    for _, line in ipairs(lines) do
      if line:find("#", 1, true) then
        has_module = true
        break
      end
    end
    truthy(has_module, "uses # for dark modules")
  end)
end)

describe("qr.show", function()
  it("renders the QR as an image when the terminal supports it", function()
    -- Pretend to be kitty and stub the renderer, which is the only part that
    -- genuinely needs a real terminal.
    -- (假装是 kitty，并把真正需要真实终端的渲染部分打桩)
    local image = require("weread.image")
    local real_supports = image.supports_inline
    image.supports_inline = function()
      return true
    end

    local attached = {}
    package.loaded["snacks.image.buf"] = {
      attach = function(buf, opts)
        attached[#attached + 1] = { buf = buf, opts = opts }
      end,
    }

    local dialog, err = qr.show(URL, { png = tmpdir .. "/login.png" })
    truthy(dialog, tostring(err))
    eq(dialog.mode, "image", "the image branch must be reachable")
    eq(#attached, 1, "the renderer was called once")
    eq(attached[1].opts.src, tmpdir .. "/login.png")
    truthy(dialog.float:is_open(), "the float is open")

    local name = vim.api.nvim_buf_get_name(dialog.float:get_buf())
    eq(name, tmpdir .. "/login.png", "the buffer is named after the png")

    -- the float has to fit on screen, whatever the QR's pixel size
    -- (浮窗必须放得进屏幕，无论二维码像素尺寸多大)
    truthy(dialog.float.width <= vim.o.columns - 6, "width fits")
    truthy(dialog.float.height <= vim.o.lines - 6, "height fits")
    truthy(dialog.float.height >= 3, "height is usable")

    close(dialog)
    image.supports_inline = real_supports
    package.loaded["snacks.image.buf"] = nil
  end)

  it("falls back to ASCII when the renderer fails", function()
    local image = require("weread.image")
    local real_supports = image.supports_inline
    image.supports_inline = function()
      return true
    end
    package.loaded["snacks.image.buf"] = {
      attach = function()
        error("terminal said no")
      end,
    }

    local dialog, err = qr.show(URL)
    truthy(dialog, tostring(err))
    eq(dialog.mode, "ascii", "degraded instead of crashing")

    local lines = vim.api.nvim_buf_get_lines(dialog.float:get_buf(), 0, -1, false)
    truthy(#lines > 5, "the ASCII code is there")

    close(dialog)
    image.supports_inline = real_supports
    package.loaded["snacks.image.buf"] = nil
  end)

  it("uses ASCII when the terminal cannot show images", function()
    local image = require("weread.image")
    local real_supports = image.supports_inline
    image.supports_inline = function()
      return false
    end

    local dialog, err = qr.show(URL)
    truthy(dialog, tostring(err))
    eq(dialog.mode, "ascii")

    close(dialog)
    image.supports_inline = real_supports
  end)

  it("reports a failure when qrencode is missing entirely", function()
    local image = require("weread.image")
    local real_supports = image.supports_inline
    image.supports_inline = function()
      return true
    end

    local real_executable = vim.fn.executable
    vim.fn.executable = function()
      return 0
    end
    local dialog, err = qr.show(URL)
    vim.fn.executable = real_executable
    image.supports_inline = real_supports

    eq(dialog, nil)
    matches(err, "qrencode")
  end)
end)
