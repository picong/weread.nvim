--[[
Tests for the way xhtml.lua is split: the facade keeps every public field, and
the xhtml_* modules depend on each other in one direction only.
(xhtml 拆分的结构测试：facade 保留全部公共字段，xhtml_* 之间只有单向依赖)
]]

local xhtml = require("weread.xhtml")

describe("weread.xhtml facade", function()
  it("keeps every public field callers rely on", function()
    local functions = {
      "convert",
      "resolve",
      "locate",
      "rune_at",
      "json_lines",
      "footnote_at",
      "find_segment",
      "language_of",
      "count_runes",
      "leading_white",
      "decode_entities",
      "normalize_text",
      "first_heading",
      "inline_stylesheet",
      "repeats_title",
      "split_translation",
      "translation_ranges",
    }
    for _, name in ipairs(functions) do
      eq(type(xhtml[name]), "function", "xhtml." .. name)
    end
    eq(type(xhtml.VERSION), "number")
    eq(type(xhtml.HANG_BUDGET), "number")
    eq(type(xhtml.HEADING_ICONS), "table")
  end)

  it("serves the same functions as the modules they were split into", function()
    local map = require("weread.xhtml_map")
    local code = require("weread.xhtml_code")
    local buffer = require("weread.xhtml_buffer")
    eq(xhtml.rune_at, map.rune_at)
    eq(xhtml.locate, map.locate)
    eq(xhtml.resolve, map.resolve)
    eq(xhtml.footnote_at, map.footnote_at)
    eq(xhtml.json_lines, map.json_lines)
    eq(xhtml.find_segment, map.find_segment)
    eq(xhtml.language_of, code.language_of)
    eq(xhtml.count_runes, buffer.count_runes)
    eq(xhtml.HANG_BUDGET, buffer.HANG_BUDGET)
  end)

  it("loads the split modules without needing the facade (no load-time cycle)", function()
    for _, name in ipairs({ "weread.xhtml", "weread.xhtml_map", "weread.xhtml_code", "weread.xhtml_buffer" }) do
      package.loaded[name] = nil
    end
    -- leaves first: each of these must load while weread.xhtml is absent
    -- (先加载叶子：它们加载时 weread.xhtml 必须不在)
    for _, name in ipairs({ "weread.xhtml_buffer", "weread.xhtml_code", "weread.xhtml_map" }) do
      local loaded = require(name)
      eq(type(loaded), "table", name)
      eq(package.loaded["weread.xhtml"], nil, name .. " must not pull in the facade")
    end
    eq(type(require("weread.xhtml").convert), "function")
  end)
end)
