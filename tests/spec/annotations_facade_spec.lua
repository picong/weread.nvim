--[[
Tests for the `weread.annotations` facade: every field the module exposed before
it was split is still there under its old name, writes to a field reach the
module that owns it, and the family loads without cycles.
(`weread.annotations` 门面的测试：拆分前暴露的每个字段仍以原名存在，对字段的写入会落到
 持有它的模块上，整族模块加载没有环)
]]

local annotations = require("weread.annotations")

-- The surface of the module before the split, taken from the original file.
-- (拆分前模块的接口全貌，取自原文件)
local LEGACY_FIELDS = {
  "add_local", "annotations_on_line", "attach", "attach_thoughts", "cached", "chapter_buffer",
  "clear_local", "compose_thought", "delete_highlight", "delete_thought", "delete_thought_at",
  "entry_at", "fetch_all_thoughts", "find_my_thought_web", "from_bestbookmarks",
  "from_bookmarklist", "heat", "heat_group", "highlight", "highlight_line", "is_uploaded", "label",
  "labels_enabled", "load", "local_annotations", "local_for", "local_path", "local_store",
  "mark_synced", "merged", "my_thought", "my_thought_for", "parse_range", "plain_text",
  "post_highlight", "post_thought", "prune_synced", "range_of_positions", "refresh",
  "refresh_after_write", "remember_note", "remove_highlight", "remove_local", "render",
  "save_local", "selection_text", "show_chapter_summary", "show_thoughts_at_cursor", "source_text",
  "sync_local", "sync_style", "thought_of", "unhighlight", "unhighlight_range", "write_context",
  "write_thought",
}

describe("weread.annotations facade surface", function()
  it("lists the same number of fields as the module had", function()
    eq(#LEGACY_FIELDS, 56)
    eq(#annotations.fields(), 56)
  end)

  it("still exposes every legacy field, each a function", function()
    local missing = {}
    for _, name in ipairs(LEGACY_FIELDS) do
      if type(annotations[name]) ~= "function" then
        missing[#missing + 1] = name
      end
    end
    eq(missing, {})
  end)

  it("exposes nothing the legacy module did not", function()
    local legacy = {}
    for _, name in ipairs(LEGACY_FIELDS) do
      legacy[name] = true
    end
    local extra = {}
    for _, name in ipairs(annotations.fields()) do
      if not legacy[name] then
        extra[#extra + 1] = name
      end
    end
    eq(extra, {})
  end)

  it("gives each field the very function its owning module has", function()
    eq(annotations.parse_range, require("weread.annotations_model").parse_range)
    eq(annotations.local_for, require("weread.annotations_store").local_for)
    eq(annotations.load, require("weread.annotations_fetch").load)
    eq(annotations.render, require("weread.annotations_render").render)
    eq(annotations.post_highlight, require("weread.annotations_sync").post_highlight)
    eq(annotations.highlight, require("weread.annotations_edit").highlight)
    eq(annotations.attach, require("weread.annotations_chapter").attach)
    eq(annotations.write_thought, require("weread.thoughts").write_thought)
  end)

  it("answers nil for a name that was never a field", function()
    eq(annotations.no_such_field, nil)
  end)
end)

describe("weread.annotations facade writes", function()
  it("replaces a field on the owning module, so internal callers see the replacement", function()
    local chapter = require("weread.annotations_chapter")
    local original = chapter.refresh_after_write
    local stub = function() end
    annotations.refresh_after_write = stub
    local forwarded = chapter.refresh_after_write == stub
    annotations.refresh_after_write = original
    eq(forwarded, true)
    eq(chapter.refresh_after_write, original, "and putting it back restores it there too")
  end)

  it("keeps a name that is not a forwarded field on the facade itself", function()
    annotations.scratch_value = 5
    eq(rawget(annotations, "scratch_value"), 5)
    annotations.scratch_value = nil
  end)
end)

describe("the annotations family load order", function()
  local FAMILY = {
    "weread.annotations_model",
    "weread.annotations_store",
    "weread.annotations_fetch",
    "weread.annotations_render",
    "weread.annotations_sync",
    "weread.annotations_edit",
    "weread.annotations_chapter",
    "weread.thoughts",
    "weread.annotations",
  }

  ---Names of the family's modules loaded as a side effect of requiring `name`
  ---from a clean slate.
  ---(从干净状态 require `name` 时，顺带加载进来的本族模块)
  local function loaded_by(name)
    local saved = {}
    for _, module in ipairs(FAMILY) do
      saved[module] = package.loaded[module]
      package.loaded[module] = nil
    end
    local ok, err = pcall(require, name)
    local pulled = {}
    for _, module in ipairs(FAMILY) do
      if package.loaded[module] ~= nil and module ~= name then
        pulled[#pulled + 1] = module
      end
    end
    for _, module in ipairs(FAMILY) do
      package.loaded[module] = saved[module]
    end
    assert(ok, err)
    return pulled
  end

  it("loads the leaf alone", function()
    eq(loaded_by("weread.annotations_model"), {})
  end)

  it("loads store and fetch on top of the model only", function()
    eq(loaded_by("weread.annotations_store"), { "weread.annotations_model" })
    eq(loaded_by("weread.annotations_fetch"), { "weread.annotations_model", "weread.annotations_store" })
  end)

  it("loads render on the model and the store only", function()
    eq(loaded_by("weread.annotations_render"), { "weread.annotations_model", "weread.annotations_store" })
  end)

  it("lets thoughts load without the facade", function()
    local pulled = loaded_by("weread.thoughts")
    for _, module in ipairs(pulled) do
      falsy(module == "weread.annotations", "thoughts must not depend on the facade")
    end
  end)

  it("loads every module on its own without raising", function()
    for _, module in ipairs(FAMILY) do
      loaded_by(module)
    end
  end)
end)
