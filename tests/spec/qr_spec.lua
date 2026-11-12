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

-- `qr.show` without an explicit `png` writes <data_dir>/tmp/login-qr.png; point the
-- data dir at the sandbox so a run never touches the reader's real data directory.
-- (不传 png 时 qr.show 会写 <data_dir>/tmp/login-qr.png；把数据目录指进沙箱，
--  测试就不会碰读者真实的数据目录)
require("weread.config").setup({ data_dir = tmpdir .. "/data" })
vim.fn.mkdir(tmpdir .. "/data/tmp", "p")

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

describe("qr.render", function()
  local matrix = assert(qr.matrix(URL))

  it("reads a square module matrix", function()
    eq(#matrix, #matrix[1], "square")
    -- a finder pattern sits in the top left corner (左上角是定位图案)
    truthy(matrix[1][1] and matrix[1][7] and matrix[7][1])
    falsy(matrix[2][2])
  end)

  it("packs two module rows into one line with half blocks", function()
    local lines, highlights = qr.render(matrix, { margin = 2, ambiwidth = "single" })
    eq(#lines, math.ceil((#matrix + 4) / 2))
    eq(vim.api.nvim_strwidth(lines[1]), #matrix + 4)
    eq(#highlights, #lines, "one highlight per line")
    eq(highlights[1][4], "WereadQr")
  end)

  it("paints spaces when half blocks would be double width", function()
    local lines, highlights = qr.render(matrix, { margin = 2, ambiwidth = "double" })
    eq(#lines, #matrix + 4)
    eq(lines[1], string.rep(" ", (#matrix + 4) * 2))
    local dark = 0
    for _, mark in ipairs(highlights) do
      if mark[4] == "WereadQrDark" then
        dark = dark + 1
      end
    end
    truthy(dark > #matrix, "dark runs are painted")
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

  it("sizes the float from the PNG's real pixel shape", function()
    -- A QR code is square, and terminal cells are about twice as tall as wide, so
    -- the height is half the width plus the border row. That only comes out right
    -- if the PNG header was actually read (via image.pixel_size).
    -- (二维码是正方形，终端单元格高约为宽的两倍，所以高度是宽度的一半加边框一行；
    --  只有真的读到了 PNG 头（经 image.pixel_size）才会得到这个值)
    local image = require("weread.image")
    local real_supports = image.supports_inline
    image.supports_inline = function()
      return true
    end
    package.loaded["snacks.image.buf"] = {
      attach = function() end,
    }

    local dialog, err = qr.show(URL, { png = tmpdir .. "/sized.png", width = 20 })
    truthy(dialog, tostring(err))
    eq(dialog.mode, "image")
    local pixel_width, pixel_height = image.pixel_size(tmpdir .. "/sized.png")
    eq(pixel_width, pixel_height, "qrencode writes a square")
    eq(dialog.float.width, 20)
    eq(dialog.float.height, 11, "20 * 1 * 0.5 + 1")

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
    eq(dialog.mode, "text", "degraded instead of crashing")

    local lines = vim.api.nvim_buf_get_lines(dialog.float:get_buf(), 0, -1, false)
    truthy(#lines > 5, "the text code is there")
    eq(dialog.float.height, #lines, "the window fits the code exactly")

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
    eq(dialog.mode, "text")

    local fired = false
    dialog = (function()
      close(dialog)
      return qr.show(URL, {
        footer = " 等待扫码 ",
        actions = {
          r = function()
            fired = true
          end,
        },
      })
    end)()
    local config = vim.api.nvim_win_get_config(dialog.float:get_win())
    matches(vim.inspect(config.footer), "等待扫码")
    vim.api.nvim_set_current_win(dialog.float:get_win())
    vim.api.nvim_feedkeys("r", "x", false)
    truthy(fired, "the caller action is mapped")

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
