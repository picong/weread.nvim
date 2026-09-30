--[[
Tests for weread.image: the markdown parsing, the viewer geometry and the
degradation path when inline rendering is unavailable.
(image 单测：markdown 解析、浮窗几何、以及无法内联渲染时的降级路径)

Inline rendering itself needs a real kitty terminal and is verified manually;
see the README's verification section.
(内联渲染本身需要真实 kitty 终端，走手工验证；见 README 的验证章节)
]]

local image = require("weread.image")

describe("image.image_in_line", function()
  it("extracts the target and alt text", function()
    local path, alt = image.image_in_line("![](/abs/path/epub_1_44.png)")
    eq(path, "/abs/path/epub_1_44.png")
    eq(alt, "")

    path, alt = image.image_in_line("before ![图 1-6](/abs/图1-6.png) after")
    eq(path, "/abs/图1-6.png")
    eq(alt, "图 1-6")
  end)

  it("ignores plain links and prose", function()
    eq(image.image_in_line("[link](/somewhere)"), nil)
    eq(image.image_in_line("普通正文"), nil)
    eq(image.image_in_line(""), nil)
    eq(image.image_in_line(nil), nil)
  end)

  it("stops at whitespace so a title suffix does not leak into the path", function()
    local path = image.image_in_line('![alt](/abs/x.png "title")')
    eq(path, "/abs/x.png")
  end)
end)

describe("image.image_at_cursor", function()
  local buf

  local function make_buffer(lines)
    buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
    vim.api.nvim_win_set_buf(0, buf)
    return buf
  end

  it("finds the image on the cursor line", function()
    make_buffer({ "# 标题", "", "![](/a/one.png)", "正文" })
    vim.api.nvim_win_set_cursor(0, { 3, 0 })
    eq(image.image_at_cursor(buf), "/a/one.png")
  end)

  it("looks one line down and one line up", function()
    make_buffer({ "![](/a/one.png)", "", "正文", "", "![](/a/two.png)" })
    vim.api.nvim_win_set_cursor(0, { 2, 0 })
    eq(image.image_at_cursor(buf), "/a/one.png", "the image above")
    vim.api.nvim_win_set_cursor(0, { 4, 0 })
    eq(image.image_at_cursor(buf), "/a/two.png", "the image below")
  end)

  it("returns nothing when there is no image nearby", function()
    make_buffer({ "# 标题", "正文", "更多正文" })
    vim.api.nvim_win_set_cursor(0, { 2, 0 })
    eq(image.image_at_cursor(buf), nil)
  end)
end)

describe("image.viewer_size", function()
  ---Write a 24 byte PNG header: enough for the geometry code, which only reads
  ---the magic and the IHDR dimensions. No real image data is needed here.
  ---(写一个 24 字节的 PNG 头：几何计算只读魔数与 IHDR 尺寸，不需要真实图像数据)
  ---@param width integer
  ---@param height integer
  ---@return string path
  local function fake_png(width, height)
    local function be32(value)
      return string.char(
        math.floor(value / 16777216) % 256,
        math.floor(value / 65536) % 256,
        math.floor(value / 256) % 256,
        value % 256
      )
    end
    local path = vim.fn.tempname() .. ".png"
    local file = assert(io.open(path, "wb"))
    file:write("\137PNG\r\n\26\n", be32(13), "IHDR", be32(width), be32(height), "\8\2\0\0\0")
    file:close()
    return path
  end

  it("keeps the float inside the screen", function()
    local width, height = image.viewer_size("/nonexistent/file.png", 200)
    truthy(width >= 10, "width is usable")
    truthy(width <= vim.o.columns - 6, "width fits the screen")
    truthy(height >= 3, "height is usable")
    truthy(height <= vim.o.lines - 6, "height fits the screen")
  end)

  it("derives the height from a PNG's aspect ratio", function()
    local _, wide_height = image.viewer_size(fake_png(200, 20), 40)
    local _, square_height = image.viewer_size(fake_png(100, 100), 40)
    truthy(
      wide_height < square_height,
      string.format("a wide image (%d rows) must be shorter than a square one (%d rows)", wide_height, square_height)
    )
    eq(wide_height, 3, "a 10:1 image at 40 cells wide is three rows tall")
  end)

  it("falls back to a 2:1 shape for unknown formats", function()
    local width, height = image.viewer_size("/nonexistent/file.jpg", 40)
    eq(width, 40)
    eq(height, math.floor(40 * 0.5 * 0.5) + 1)
  end)
end)

describe("image.supports_inline", function()
  it("is false without snacks.nvim installed", function()
    -- the test process runs with --clean, so snacks is absent
    -- (测试进程用 --clean 运行，因此没有 snacks)
    eq(image.supports_inline(), false)
  end)
end)

describe("image.mark_lines", function()
  it("annotates image lines only when inline rendering is unavailable", function()
    local buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "正文", "![](/a/one.png)", "更多" })
    image.mark_lines(buf)

    local namespace = vim.api.nvim_create_namespace("weread.image.hints")
    local marks = vim.api.nvim_buf_get_extmarks(buf, namespace, 0, -1, { details = true })
    eq(#marks, 1, "one hint")
    eq(marks[1][2], 1, "on the image line")

    vim.api.nvim_buf_delete(buf, { force = true })
  end)
end)

describe("image.conceal_links", function()
  it("hides the markdown syntax and leaves the caption visible", function()
    local buf = vim.api.nvim_create_buf(false, true)
    local line = "![图 1-6](/home/you/.local/share/nvim/weread/books/43208843/assets/epub_x.png)"
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "正文", line })
    image.conceal_links(buf)

    local namespace = vim.api.nvim_create_namespace("weread.image.conceal")
    local marks = vim.api.nvim_buf_get_extmarks(buf, namespace, 0, -1, { details = true })
    eq(#marks, 2, "one mark for the prefix and one for the path")

    local start_col, end_col, alt = line:find("!%[([^%]]*)%]%(([^%s%)]+)%)")
    eq(start_col, 1)
    local concealed = {}
    for _, mark in ipairs(marks) do
      local from = mark[3]
      local to = mark[4].end_col
      concealed[from] = to
    end
    eq(concealed[0], 2, "conceals `![`")
    eq(concealed[2 + #alt], end_col, "conceals `](path)`")

    -- nothing conceals the alt text itself
    -- (没有任何标记盖住 caption 文本)
    truthy(concealed[2] == nil, "the caption stays visible")

    vim.api.nvim_buf_delete(buf, { force = true })
  end)

  it("handles an image without alt text", function()
    local buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "![](/abs/short.png)" })
    image.conceal_links(buf)
    local namespace = vim.api.nvim_create_namespace("weread.image.conceal")
    local marks = vim.api.nvim_buf_get_extmarks(buf, namespace, 0, -1, { details = true })
    eq(#marks, 2, "the icon replaces the whole syntax")
    vim.api.nvim_buf_delete(buf, { force = true })
  end)

  it("ignores lines that hold no image", function()
    local buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "普通正文", "[普通链接](/x)" })
    image.conceal_links(buf)
    local namespace = vim.api.nvim_create_namespace("weread.image.conceal")
    eq(#vim.api.nvim_buf_get_extmarks(buf, namespace, 0, -1, {}), 0)
    vim.api.nvim_buf_delete(buf, { force = true })
  end)
end)

describe("image.attach", function()
  it("marks the buffer so other renderers can opt out", function()
    local buf = vim.api.nvim_create_buf(false, true)
    image.attach(buf)
    eq(vim.b[buf].weread_book, true)
    vim.api.nvim_buf_delete(buf, { force = true })
  end)
end)
