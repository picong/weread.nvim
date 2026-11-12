--[[
Tests for weread.sprites: every picture is well formed, waits outlast keys,
moments end on their own, and nothing is written into the chapter.
(sprites 单测：每张小画格式正确，等待不会被按键停掉，瞬间会自己结束，章节里什么都不写)
]]

local config = require("weread.config")
local tmpdir = "/tmp/weread-test-sprites"
vim.fn.delete(tmpdir, "rf")
vim.fn.mkdir(tmpdir, "p")
config.setup({ data_dir = tmpdir })

local sprites = require("weread.sprites")
local fx = require("weread.fx")

local function chapter_buffer()
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "　　正文第一行", "　　正文第二行" })
  vim.b[buf].weread = { book_id = "S1", chapter_key = "0001", chapter_index = 1, chapter_uid = "1" }
  vim.bo[buf].modifiable = false
  vim.api.nvim_win_set_buf(0, buf)
  return buf
end

describe("sprites art", function()
  it("draws every frame at the same size from known colour keys", function()
    for name, frames in pairs(sprites.ART) do
      truthy(#frames >= 2, name .. " moves")
      for f, frame in ipairs(frames) do
        eq(#frame, 8, name .. " frame " .. f .. " is eight pixels tall")
        for r, row in ipairs(frame) do
          eq(#row, sprites.WIDTH, string.format("%s frame %d row %d width", name, f, r))
          falsy(row:find("[^%.iampw]"), string.format("%s frame %d row %d: unknown key in %q", name, f, r, row))
        end
      end
    end
  end)

  it("paints them in the palette's own inks", function()
    local inks, page = sprites.inks()
    for _, key in ipairs({ "i", "a", "m", "p", "w" }) do
      matches(inks[key], "^#%x%x%x%x%x%x$", key)
    end
    matches(page, "^#%x%x%x%x%x%x$")
  end)
end)

describe("sprites playing", function()
  it("plays a moment once in the corner and leaves the chapter alone", function()
    local buf = chapter_buffer()
    fx._force, fx._sync = true, true
    local before = #vim.api.nvim_list_wins()
    local placed
    local open = vim.api.nvim_open_win
    vim.api.nvim_open_win = function(b, enter, cfg)
      placed = cfg
      return open(b, enter, cfg)
    end
    local handle = sprites.moment("plane", "进度已送出")
    vim.api.nvim_open_win = open
    fx._force, fx._sync = false, false
    truthy(handle)
    truthy(placed, "a float was opened")
    eq(placed.focusable, false)
    truthy(placed.row > 0, "in the lower part of the page, not over the top line")
    eq(#vim.api.nvim_list_wins(), before, "and closed again once played")
    eq(vim.api.nvim_buf_get_lines(buf, 0, -1, false), { "　　正文第一行", "　　正文第二行" })
    vim.api.nvim_buf_delete(buf, { force = true })
  end)

  it("keeps a wait going through keys until it is stopped", function()
    local buf = chapter_buffer()
    fx._force = true
    local handle = sprites.play("quill", { label = "翻译中…", kind = "wait", switch = "translating", delay = 0 })
    truthy(handle)
    fx.stop_all({ keyed = true })
    eq(fx.count(), 1, "a key does not stop the quill")
    fx.stop(handle)
    eq(fx.count(), 0)
    fx._force = false
    vim.api.nvim_buf_delete(buf, { force = true })
  end)

  it("stays off outside a chapter, headless, or when switched off", function()
    eq(sprites.moment("plane"), nil, "headless")
    fx._force = true
    local plain = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_win_set_buf(0, plain)
    eq(sprites.moment("plane"), nil, "not over a chapter")
    local buf = chapter_buffer()
    config.get().animations.sprites = false
    eq(sprites.moment("plane"), nil, "switched off")
    config.get().animations.sprites = true
    eq(sprites.moment("nope"), nil, "unknown sprite")
    fx._force = false
    vim.api.nvim_buf_delete(buf, { force = true })
    vim.api.nvim_buf_delete(plain, { force = true })
  end)

  it("plays the gallery one sprite at a time", function()
    local buf = chapter_buffer()
    fx._force = true
    truthy(sprites.gallery())
    eq(fx.count(), 1, "one at a time")
    fx.stop_all()
    fx._force = false
    vim.api.nvim_buf_delete(buf, { force = true })
  end)
end)
