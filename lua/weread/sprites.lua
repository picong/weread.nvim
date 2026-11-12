--[[
Pixel sprites for the moments around reading, drawn like the loading book: a
small picture in half blocks with a line of text under it, in a float of its
own over the page.
(阅读周围那些时刻的像素小画，画法和加载中的书本一样：一张半块字符画成的小图，下面一行字，放在书页
 上方的独立浮窗里)

Two kinds:
(两种)

* A **wait** lasts as long as the thing it stands for (translating a chapter,
  searching the book) and is stopped by whoever started it; it keeps going
  while the reader reads, so a key does not stop it.
  (**等待**：持续的时间就是它所代表的那件事（翻译一章、搜整本书），由发起者停掉；读者照常读，
   按键不会停它)
* A **moment** plays once and is gone within a second (progress sent, the
  phone's place followed, a thought posted, the plant grown); any key ends it.
  (**瞬间**：播放一次、一秒内消失（进度已回传、跟上了手机的位置、想法已发出、植物长大了）；任意键结束)

Sprites are grids of colour keys, one string per pixel row, two rows to a line
of text. Keys are named by their role so every palette paints them in its own
inks: `i` ink, `a` accent, `m` quiet ink, `p` paper wash (the mark colour), `w`
a brighter wash; `.` is the page itself.
(小画是颜色键组成的网格，每个像素行一个字符串，两行像素合成一行文字。键按角色命名，所以每套配色
 都用自己的墨色来画：`i` 墨、`a` 强调色、`m` 淡墨、`p` 纸色淡底（标记色）、`w` 更亮的淡底；
 `.` 就是纸页本身)
]]

local fx = require("weread.fx")

local M = {}

-- ------------------------------------------------------------------ the pictures

---Every sprite, as a list of frames; each frame is a list of pixel rows.
---(每个小画都是若干帧；每帧是若干像素行)
M.ART = {
  ---A quill writing a line, then the next: translating.
  ---(一支羽毛笔写完一行、再写下一行：在翻译)
  quill = {
    {
      "..........aa",
      ".........aa.",
      "........aa..",
      ".......ia...",
      "......i.....",
      "pppppp......",
      "pppppppppppp",
      "pppppppppppp",
    },
    {
      "...........a",
      "..........aa",
      ".........aa.",
      "........ia..",
      ".......i....",
      "pmmmmmm.....",
      "pppppppppppp",
      "pppppppppppp",
    },
    {
      "..........aa",
      ".........aa.",
      "........aa..",
      ".......ia...",
      "......i.....",
      "pmmmmmmmmmp.",
      "pppppppppppp",
      "pppppppppppp",
    },
    {
      "...aa.......",
      "..aa........",
      ".aa.........",
      "ia..........",
      "............",
      "pmmmmmmmmmmp",
      "pmmmp.......",
      "pppppppppppp",
    },
  },
  ---A magnifier sweeping across a line of text: searching the book.
  ---(放大镜扫过一行字：在搜整本书)
  magnifier = {
    {
      ".aaa........",
      "a...a.......",
      "a.w.a.......",
      "a...a.......",
      ".aaa........",
      "....ii......",
      ".....ii.....",
      "mmmmmmmmmmmm",
    },
    {
      "....aaa.....",
      "...a...a....",
      "...a.w.a....",
      "...a...a....",
      "....aaa.....",
      ".......ii...",
      "........ii..",
      "mmmmmmmmmmmm",
    },
    {
      ".......aaa..",
      "......a...a.",
      "......a.w.a.",
      "......a...a.",
      ".......aaa..",
      "..........ii",
      "...........i",
      "mmmmmmmmmmmm",
    },
    {
      "....aaa.....",
      "...a...a....",
      "...a.w.a....",
      "...a...a....",
      "....aaa.....",
      ".......ii...",
      "........ii..",
      "mmmmmmmmmmmm",
    },
  },
  ---A paper plane gliding off to the right: progress sent to the account.
  ---(一架纸飞机向右滑出去：进度已回传到账号)
  plane = {
    {
      "aa..........",
      ".aaaa.......",
      ".awwaaa.....",
      ".aaaa.......",
      "aa..........",
      "............",
      "m...........",
      "............",
    },
    {
      "...aa.......",
      "....aaaa....",
      "....awwaaa..",
      "....aaaa....",
      "...aa.......",
      "............",
      "m.m.........",
      "............",
    },
    {
      "......aa....",
      ".......aaaa.",
      ".......awwaa",
      ".......aaaa.",
      "......aa....",
      "............",
      "m.m.m.......",
      "............",
    },
    {
      "..........aa",
      "...........a",
      "...........a",
      "...........a",
      "..........aa",
      "............",
      "m.m.m.m.....",
      "............",
    },
  },
  ---The phone's place arriving at the book: progress pulled from another device.
  ---(手机上的位置来到书上：从别的设备跟过来了)
  phone = {
    {
      "iiii........",
      "iwwi........",
      "iwwi....pppp",
      "iwwi....pmmp",
      "iwwi....pmmp",
      "iiii....pppp",
      ".ii.........",
      "............",
    },
    {
      "iiii........",
      "iwwi........",
      "iwwi.a..pppp",
      "iwwiaaa.pmmp",
      "iwwi.a..pmmp",
      "iiii....pppp",
      ".ii.........",
      "............",
    },
    {
      "iiii........",
      "iwwi........",
      "iwwi...apppp",
      "iwwi..aaaamp",
      "iwwi...apmmp",
      "iiii....pppp",
      ".ii.........",
      "............",
    },
    {
      "iiii........",
      "iwwi....aaaa",
      "iwwi....amma",
      "iwwi....amma",
      "iwwi....amma",
      "iiii....aaaa",
      ".ii.........",
      "............",
    },
  },
  ---A speech bubble popping up: a thought posted.
  ---(一个对话气泡冒出来：想法已发出)
  bubble = {
    {
      "............",
      "............",
      "............",
      "....aa......",
      "....aa......",
      "....a.......",
      "............",
      "............",
    },
    {
      "............",
      "...aaaaa....",
      "..awwwwwa...",
      "..awwwwwa...",
      "...aaaaa....",
      "...a........",
      "............",
      "............",
    },
    {
      ".aaaaaaaaa..",
      "awwwwwwwwwa.",
      "awmmwmmmwwa.",
      "awwwwwwwwwa.",
      ".aaaaaaaaa..",
      "..aa........",
      "..a.........",
      "............",
    },
    {
      ".aaaaaaaaa..",
      "awwwwwwwwwa.",
      "awmmwmmmwwa.",
      "awwwwwwwwwa.",
      ".aaaaaaaaa..",
      "..aa........",
      "..a.........",
      "............",
    },
  },
  ---A seedling growing a leaf, then another: the plant reached a new stage.
  ---(一株幼苗长出一片叶子、又一片：植物长到了新的阶段)
  sprout = {
    {
      "............",
      "............",
      "............",
      "............",
      ".....a......",
      ".....a......",
      "...mmmmmm...",
      "....mmmm....",
    },
    {
      "............",
      "............",
      "......aa....",
      ".....aa.....",
      ".....a......",
      ".....a......",
      "...mmmmmm...",
      "....mmmm....",
    },
    {
      "............",
      "..aa........",
      "...aa.aa....",
      "....aaa.....",
      ".....a......",
      ".....a......",
      "...mmmmmm...",
      "....mmmm....",
    },
    {
      ".....i......",
      "..aa.i.aa...",
      "...aaiaa....",
      "....aaa.....",
      ".....a......",
      ".....a......",
      "...mmmmmm...",
      "....mmmm....",
    },
  },
  ---A cat curling up for a nap: a long read today (the plant bore fruit).
  ---(一只猫蜷起来打盹：今天读了很久（植物结果了）)
  cat = {
    {
      "............",
      "..a...a.....",
      "..aa.aa.....",
      "..aiaia.....",
      "..aaaaa..a..",
      "...aaaaaaa..",
      "...a.a.a.a..",
      "............",
    },
    {
      "............",
      "............",
      "..a...a.....",
      "..aa.aa.....",
      "..aiaiaaaa..",
      "..aaaaaaaa..",
      "...aaaaaaa..",
      "............",
    },
    {
      "............",
      "............",
      "............",
      "..a.a.......",
      "..aaaaaaaa..",
      "..ammaaaaaa.",
      "...aaaaaaaa.",
      "............",
    },
    {
      "...........m",
      "..........m.",
      "...........m",
      "..a.a.......",
      "..aaaaaaaa..",
      "..ammaaaaaa.",
      "...aaaaaaaa.",
      "............",
    },
  },
}

---Width, in pixels (= cells), of every sprite.
---(每张小画的宽度，单位是像素，也就是字符格)
M.WIDTH = 12

---The inks a sprite's keys stand for, in the current palette.
---(小画的颜色键在当前配色里代表的墨色)
---@return table<string, string>
function M.inks()
  local colors = fx.colors()
  local mix = require("weread.color").mix
  return {
    i = colors.fg,
    a = colors.accent,
    m = colors.muted,
    p = colors.mark,
    w = mix(colors.bg, colors.mark, 0.5),
  }, colors.bg
end

-- ------------------------------------------------------------------ playing

---Where a sprite sits: the bottom right corner of the text column, clear of the
---folio, so it never covers the line being read in the middle of the page.
---(小画放在哪：正文列的右下角，避开页脚，所以绝不会挡住页面中间正在读的那一行)
---@param win integer
---@param width integer
---@param height integer
---@return integer row
---@return integer col
local function corner(win, width, height)
  local rows = vim.api.nvim_win_get_height(win)
  local cols = vim.api.nvim_win_get_width(win)
  local margin = 0
  pcall(function()
    local page_width = require("weread.reader").page_width() or 0
    if page_width > 0 then
      margin = require("weread.layout").margin_for(cols, math.min(page_width, cols))
    end
  end)
  local right = cols - margin
  return math.max(0, rows - height - 2), math.max(0, right - width)
end

---Paint frame `i` of a sprite and its label into a float.
---(把小画的第 i 帧和它的文字画进浮窗)
---@param view table
---@param art string[][]
---@param i integer
---@param label string
---@param width integer
local function paint(view, art, i, label, width)
  local inks, page = M.inks()
  local lines, marks = fx.pixels(art[(i - 1) % #art + 1], inks, page)
  local pad = string.rep(" ", math.floor((width - M.WIDTH) / 2))
  for n, line in ipairs(lines) do
    lines[n] = pad .. line
  end
  for _, mark in ipairs(marks) do
    mark.col = mark.col + #pad
    mark.end_col = mark.end_col + #pad
  end
  if label ~= "" then
    local label_pad = string.rep(" ", math.max(0, math.floor((width - vim.fn.strdisplaywidth(label)) / 2)))
    lines[#lines + 1] = label_pad .. label
    local colors = fx.colors()
    vim.api.nvim_set_hl(0, "WereadFxLabel", { fg = colors.muted, bg = colors.bg })
    marks[#marks + 1] = { row = #lines - 1, col = 0, end_col = #lines[#lines], group = "WereadFxLabel" }
  end
  fx.paint(view, lines, marks)
end

---Play a sprite over a window.
---(在窗口上方播放一张小画)
---@param name string a key of ART(ART 里的键)
---@param opts { win?: integer, label?: string, kind: "wait"|"moment", switch: string, interval?: integer, delay?: integer, max_ms?: integer, center?: boolean }
---@return table|nil handle stop with fx.stop(用 fx.stop 停掉)
function M.play(name, opts)
  local art = M.ART[name]
  local win = opts.win or vim.api.nvim_get_current_win()
  if not art or not fx.enabled(opts.switch) or not vim.api.nvim_win_is_valid(win) then
    return nil
  end
  local ok_reader, reader = pcall(require, "weread.reader")
  if not (ok_reader and reader.buffer_info(vim.api.nvim_win_get_buf(win))) then
    return nil
  end
  local label = opts.label or ""
  local width = math.max(M.WIDTH, vim.fn.strdisplaywidth(label))
  local height = math.ceil(#art[1] / 2) + (label ~= "" and 1 or 0)
  local wait = opts.kind == "wait"
  local view
  return fx.play({
    interval = opts.interval or (wait and 160 or 110),
    -- a moment plays its frames once, then holds the last one a little
    -- (瞬间把各帧播一遍，再在最后一帧上停一会儿)
    frames = (not wait) and (#art + 3) or nil,
    max_ms = opts.max_ms or (wait and 120000 or 1500),
    delay = opts.delay or (wait and 300 or 0),
    stop_on_key = not wait,
    start = function()
      fx.reset_groups()
      local row, col
      if opts.center then
        row = math.floor((vim.api.nvim_win_get_height(win) - height) / 2)
        col = math.floor((vim.api.nvim_win_get_width(win) - width) / 2)
      else
        row, col = corner(win, width, height)
      end
      view = fx.float(win, { row = row, col = col, width = width, height = height, zindex = 44 })
      if not view then
        error("no room")
      end
    end,
    draw = function(frame)
      if not view or not vim.api.nvim_win_is_valid(view.win) then
        return false
      end
      paint(view, art, wait and frame or math.min(frame, #art), label, width)
    end,
    cleanup = function()
      fx.close(view)
    end,
  })
end

---A wait shown while something takes a while; stop it with `fx.stop`.
---(某件事要花些时间时显示的等待；用 fx.stop 停掉)
---@param name string
---@param label string
---@param opts table|nil { win, switch, center }
---@return table|nil
function M.wait(name, label, opts)
  opts = opts or {}
  return M.play(name, { win = opts.win, label = label, kind = "wait", switch = opts.switch or "sprites", center = opts.center })
end

---Every sprite once, one after another in the middle of the page, with its
---name: a way to see them all without waiting for each moment.
---(所有小画依次在页面中间各放一遍，配上名字：不必等每个时刻到来，也能全部看一遍)
---@param win integer|nil
---@return boolean started
function M.gallery(win)
  win = win or vim.api.nvim_get_current_win()
  local names = {
    { "quill", "翻译中" },
    { "magnifier", "书内搜索" },
    { "plane", "进度送出" },
    { "phone", "跟上其他端" },
    { "bubble", "想法发表" },
    { "sprout", "植物长大" },
    { "cat", "读了很久" },
  }
  local index = 0
  local current = nil
  local function step()
    index = index + 1
    local entry = names[index]
    if not entry then
      return
    end
    current = M.play(entry[1], { win = win, label = entry[2], kind = "moment", switch = "sprites", center = true, max_ms = 2000 })
    if current then
      require("weread.timer").defer(function()
        if current and fx.count() > 0 then
          fx.stop(current)
        end
        step()
      end, 1300)
    end
  end
  step()
  return current ~= nil
end

---A moment, played once.
---(一个瞬间，播放一次)
---@param name string
---@param label string|nil
---@param opts table|nil { win, switch }
---@return table|nil
function M.moment(name, label, opts)
  opts = opts or {}
  return M.play(name, { win = opts.win, label = label or "", kind = "moment", switch = opts.switch or "sprites" })
end

return M
