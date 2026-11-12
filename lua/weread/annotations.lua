--[[
Highlights and thoughts: the public face of the annotations family.
(划线与想法：annotations 这一族对外的门面)

The code lives in smaller modules, one per responsibility:
(代码按职责拆在几个小模块里：)

* `annotations_model`    pure functions: ranges, merging, normalizing, labels
* `annotations_store`    disk: per-chapter cache, offset map, local highlights
* `annotations_fetch`    reading from the Agent API
* `annotations_render`   drawing into the chapter buffer, lookup by line
* `annotations_sync`     writing to the account through the web reader
* `annotations_edit`     making and removing highlights from the editor
* `annotations_chapter`  attach / refresh orchestration for a chapter
* `thoughts`             the thought panel, composer, my thoughts, popups

Load order has no cycles: model is a leaf, store/fetch/render sit on it, sync on
those, then edit/chapter, then thoughts; this file depends on all of them and
nothing depends on this file except callers outside the family.
(加载顺序没有环：model 是叶子，store/fetch/render 建在它上面，sync 再在其上，然后是
 edit/chapter，再然后是 thoughts；本文件依赖全部，族内没有任何模块依赖本文件)

Every field the module ever exposed is still here under its old name. Reads and
writes are forwarded to the module that owns the field, so replacing a field on
this table (as the specs do with `refresh_after_write`) replaces it where the
family's own code calls it too, instead of only on this table.
(这个模块曾经暴露过的每个字段仍以原名保留。读写都转发给持有该字段的模块，因此替换本表上
 的字段（spec 对 `refresh_after_write` 就是这么做的）也会替换族内代码实际调用的那一个，
 而不是只改本表)
]]

local modules = {
  model = require("weread.annotations_model"),
  store = require("weread.annotations_store"),
  fetch = require("weread.annotations_fetch"),
  render = require("weread.annotations_render"),
  sync = require("weread.annotations_sync"),
  edit = require("weread.annotations_edit"),
  chapter = require("weread.annotations_chapter"),
  thoughts = require("weread.thoughts"),
}

---Field name -> the module that owns it.
---(字段名 → 持有它的模块)
local FIELDS = {
  model = {
    "parse_range", "from_bookmarklist", "from_bestbookmarks", "thought_of", "attach_thoughts",
    "is_uploaded", "heat", "heat_group", "label", "plain_text",
  },
  store = {
    "cached", "local_path", "local_store", "save_local", "local_for", "add_local", "remove_local",
    "local_annotations", "merged", "mark_synced", "prune_synced", "source_text", "write_context",
    "chapter_buffer",
  },
  fetch = { "fetch_all_thoughts", "load" },
  render = { "render", "labels_enabled", "annotations_on_line", "entry_at" },
  sync = {
    "find_my_thought_web", "sync_style", "post_highlight", "delete_highlight", "sync_local",
    "remove_highlight", "post_thought", "delete_thought",
  },
  edit = {
    "range_of_positions", "selection_text", "highlight", "highlight_line", "unhighlight_range",
    "clear_local", "unhighlight",
  },
  chapter = { "attach", "refresh", "refresh_after_write" },
  thoughts = {
    "my_thought", "my_thought_for", "delete_thought_at", "remember_note", "write_thought",
    "compose_thought", "show_thoughts_at_cursor", "show_chapter_summary",
  },
}

---@type table<string, table>
local OWNER = {}
for name, fields in pairs(FIELDS) do
  for _, field in ipairs(fields) do
    OWNER[field] = modules[name]
  end
end

local M = {}

---Names of every forwarded field, sorted. `pairs(M)` cannot list them (they are
---not stored on this table), so a caller that wants the surface asks here.
---(所有被转发的字段名，已排序。`pairs(M)` 列不出它们（它们不存在本表里），所以想知道
--- 接口全貌的调用方来这里问)
---@return string[]
function M.fields()
  local names = vim.tbl_keys(OWNER)
  table.sort(names)
  return names
end

return setmetatable(M, {
  __index = function(_, key)
    local owner = OWNER[key]
    if owner then
      return owner[key]
    end
    return nil
  end,
  __newindex = function(self, key, value)
    local owner = OWNER[key]
    if owner then
      owner[key] = value
    else
      rawset(self, key, value)
    end
  end,
})
