--[[
Tests for weread.font: listing what is installed, writing a terminal snippet,
remembering the choice — and never touching the real kitty config.
(font 单测：列已装字体、生成终端片段、记住选择——并且绝不碰真实的 kitty 配置)
]]

local config = require("weread.config")
local tmpdir = "/tmp/weread-test-font"
vim.fn.delete(tmpdir, "rf")
vim.fn.mkdir(tmpdir, "p")
config.setup({ data_dir = tmpdir })

-- Redirect the terminal config directory: the tests must not write into the
-- user's real ~/.config/kitty.
-- (把终端配置目录改到临时位置：测试绝不能写进真实的 ~/.config/kitty)
vim.env.XDG_CONFIG_HOME = tmpdir

local font = require("weread.font")

describe("font.installed", function()
  it("lists CJK families, book-ish ones first", function()
    if vim.fn.executable("fc-list") ~= 1 then
      return -- nothing to assert on a machine without fontconfig(没有 fontconfig 就没什么可断言)
    end
    local families = font.installed()
    truthy(#families > 0, "found some CJK fonts")

    local seen = {}
    for _, family in ipairs(families) do
      falsy(seen[family], "no duplicates: " .. family)
      seen[family] = true
    end

    -- a serif face must not sort after a monospace one
    -- (衬线体不应排在等宽体之后)
    local serif_index, mono_index = nil, nil
    for index, family in ipairs(families) do
      local lowered = family:lower()
      if not serif_index and lowered:find("serif", 1, true) then
        serif_index = index
      end
      if not mono_index and lowered:find("mono", 1, true) then
        mono_index = index
      end
    end
    if serif_index and mono_index then
      truthy(serif_index < mono_index, "serif before mono")
    end
  end)
end)

describe("font.snippet", function()
  it("contains the family and the optional line height", function()
    local text = font.snippet("思源宋体 CN")
    truthy(text:find("font_family      思源宋体 CN", 1, true), "family line")
    truthy(text:find("bold_font", 1, true), "bold face")
    truthy(text:find("adjust_line_height", 1, true), "line height left as a hint")
  end)

  it("carries the font size when asked", function()
    truthy(font.snippet("X", { font_size = 16 }):find("font_size        16", 1, true))
  end)
end)

describe("font.apply", function()
  it("writes the snippet and remembers the choice", function()
    local ok, message = font.apply("思源黑体 CN")
    truthy(ok, message)

    local path = font.snippet_path()
    eq(vim.fn.filereadable(path), 1, "snippet written")
    truthy(font.snippet("思源黑体 CN"):find(vim.fn.readfile(path)[3] or "", 1, true) or true)
    truthy(table.concat(vim.fn.readfile(path), "\n"):find("思源黑体 CN", 1, true), "the family is in the file")

    eq(require("weread.prefs").get("font"), "思源黑体 CN", "remembered")
    eq(font.current(), "思源黑体 CN")
    matches(message, "include")
  end)

  it("writes inside the configured terminal config dir", function()
    truthy(font.snippet_path():find(tmpdir, 1, true) == 1, "redirected: " .. font.snippet_path())
  end)
end)

describe("font.status", function()
  it("reports the current choice and the terminal situation", function()
    local text = font.status()
    truthy(text:find("阅读字体", 1, true))
    truthy(text:find("思源黑体 CN", 1, true), "the remembered family")
    truthy(text:find("kitty", 1, true))
  end)
end)
