--[[
Tests for weread.annotations_render: where an underline starts and ends when a
passage crosses inline styling or ends right at a segment boundary.
(annotations_render 单测：划线跨过行内样式、或正好结束在段边界时，下划线的起止位置)
]]

local xhtml = require("weread.xhtml")
local render = require("weread.annotations_render")

-- 前面的文字 = runes 3..8, 加粗部分 = 11..15, 后面的文字结束 = 19..26
local SOURCE = "<p>前面的文字<b>加粗部分</b>后面的文字结束</p>"

---@param range string
---@return table resolved
local function draw(range)
  local result = xhtml.convert(SOURCE, {})
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, vim.split(result.text, "\n"))
  render.render(buf, result, { { range = range, mine = true } })
  local resolved = vim.b[buf].weread_annotations[1]
  local line = vim.api.nvim_buf_get_lines(buf, 0, 1, false)[1]
  return resolved, line
end

describe("weread.annotations_render", function()
  it("ends a passage that runs from plain text into bold inside the bold part", function()
    local resolved, line = draw("5-13")
    eq(line:sub(resolved.from_col + 1, resolved.to_col), "的文字**加粗")
  end)

  it("ends a passage that crosses bold in the plain text after it", function()
    local resolved, line = draw("4-22")
    eq(line:sub(resolved.from_col + 1, resolved.to_col), "面的文字**加粗部分**后面的")
  end)

  it("keeps a passage ending at a segment boundary on its own line", function()
    local resolved, line = draw("3-8")
    eq(resolved.finish_line, 0)
    eq(line:sub(resolved.from_col + 1, resolved.to_col), "前面的文字")
  end)
end)
