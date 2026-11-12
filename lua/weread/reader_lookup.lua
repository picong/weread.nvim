--[[
`K` on a page: the translation popup, and the choice between translating and
reading the thoughts when the cursor is on a highlight.
(书页上的 K：翻译弹窗，以及光标在划线上时「翻译」与「看想法」之间的选择)

The popup opens next to the cursor at once, saying it is working, and is filled
in when the answer arrives; the editor never waits. It closes like a hover:
when the cursor moves, the buffer changes or insert mode starts. `K` again
moves into it, so a long sentence can be scrolled or yanked; `q` closes it.
(弹窗立刻在光标旁打开，先显示正在查，结果到了再填上；编辑器从不等待。它像 hover 一样关闭：
 光标一动、换 buffer、进插入模式就关。再按一次 K 进入弹窗，长句可以滚动或复制；q 关闭)
]]

local session = require("weread.session")

local M = {}

local WIDTH = 52

---@type { win: integer|nil, buf: integer|nil, source: integer|nil, anchor: integer[]|nil, group: integer|nil, token: integer, entering: boolean }
local popup = { token = 0, entering = false }

function M.define_highlights()
  vim.api.nvim_set_hl(0, "WereadLookupWord", { link = "Title", default = true })
  vim.api.nvim_set_hl(0, "WereadLookupPhonetic", { link = "Comment", default = true })
  vim.api.nvim_set_hl(0, "WereadLookupSource", { link = "Comment", default = true })
end

-- ------------------------------------------------------------------ text

---The English word at a byte column of a line: letters with inner apostrophes
---and hyphens. nil when the column is not on one.
---(某行某字节列上的英文单词：字母，中间可以有撇号与连字符。列不在单词上时为 nil)
---@param line string
---@param col integer 0-based byte column
---@return string|nil word
---@return integer|nil from 0-based byte column the word starts at
function M.word_at(line, col)
  local position = 1
  while true do
    local from, to = line:find("[%a][%a'%-]*", position)
    if not from then
      return nil
    end
    -- trailing apostrophes and hyphens belong to the punctuation, not the word
    -- (末尾的撇号与连字符属于标点，不属于单词)
    local word = line:sub(from, to):gsub("['%-]+$", "")
    if col + 1 >= from and col + 1 <= from + #word - 1 then
      return word, from - 1
    end
    if from > col + 1 then
      return nil
    end
    position = to + 1
  end
end

---Selected lines as one passage: markdown markers and indents gone, hard wraps
---joined with a space between Latin words and nothing between CJK characters.
---(把选中的行合成一段：去掉 markdown 标记与缩进，硬换行在西文之间补一个空格、在中文之间直接相连)
---@param lines string[]
---@return string
function M.join(lines)
  local out = ""
  for _, line in ipairs(lines) do
    line = line:gsub("!%[[^%]]*%]%([^)]*%)", ""):gsub("[*_`]+", ""):gsub("^#+%s*", ""):gsub("^>%s*", "")
    line = vim.trim((line:gsub("^[　%s]+", "")))
    if line ~= "" then
      if out == "" then
        out = line
      elseif out:sub(-1):match("[%w%p]") and line:sub(1, 1):match("[%w%p]") then
        out = out .. " " .. line
      else
        out = out .. line
      end
    end
  end
  return out
end

---The visual selection as text, read while visual mode is still on.
---(可视选区的文字，在可视模式仍然开着的时候读取)
---@return string
function M.selection()
  local mode = vim.fn.mode()
  local from, to = vim.fn.getpos("v"), vim.fn.getpos(".")
  local ok, lines = pcall(vim.fn.getregion, from, to, { type = mode })
  vim.cmd("normal! \27")
  if not ok then
    return ""
  end
  -- across lines of a table, the passage is read from the book: the lines in
  -- between also hold the other columns
  -- (跨表格行时，这段话从书里读：中间那些行上还有别的列)
  if mode == "v" then
    local head, tail = { from[2], from[3] - 1 }, { to[2], to[3] }
    if head[1] > tail[1] or (head[1] == tail[1] and head[2] > tail[2]) then
      head, tail = { to[2], to[3] - 1 }, { from[2], from[3] }
    end
    local passage = require("weread.annotations_edit").passage_text(vim.api.nvim_get_current_buf(), head, tail)
    if passage ~= "" then
      return M.join({ passage })
    end
  end
  return M.join(lines)
end

-- ------------------------------------------------------------------ popup

---@return boolean
function M.is_open()
  return popup.win ~= nil and vim.api.nvim_win_is_valid(popup.win)
end

function M.close()
  if popup.group then
    pcall(vim.api.nvim_del_augroup_by_id, popup.group)
    popup.group = nil
  end
  if popup.win and vim.api.nvim_win_is_valid(popup.win) then
    pcall(vim.api.nvim_win_close, popup.win, true)
  end
  popup.win, popup.buf, popup.source, popup.anchor = nil, nil, nil, nil
end

---The window of the popup, for tests.
---(弹窗的窗口，供测试)
---@return integer|nil
function M.window()
  return M.is_open() and popup.win or nil
end

---Lines and highlights of a result.
---(结果的行与高亮)
---@param result table
---@param width integer
---@return string[] lines
---@return table[] marks { line, from, to, group }
function M.render(result, width)
  local text = require("weread.text")
  local lines, marks = {}, {}
  if result.lines then
    local head = result.word or result.original or ""
    lines[1] = head
    marks[#marks + 1] = { 0, 0, #head, "WereadLookupWord" }
    if result.phonetic then
      local phonetic = "  /" .. result.phonetic .. "/"
      marks[#marks + 1] = { 0, #head, #head + #phonetic, "WereadLookupPhonetic" }
      lines[1] = head .. phonetic
    end
    if result.lemma and result.lemma:lower() ~= tostring(result.word or ""):lower() then
      local note = "原形 " .. result.lemma
      lines[#lines + 1] = note
      marks[#marks + 1] = { #lines - 1, 0, #note, "WereadLookupPhonetic" }
    end
    for _, line in ipairs(result.lines) do
      vim.list_extend(lines, text.wrap(line, width, 6))
    end
  else
    vim.list_extend(lines, text.wrap(result.text or "", width, 40))
  end
  return lines, marks
end

---Footer of a result: where the answer came from and how long it took, and
---"兜底" when a better service failed first.
---(结果的页脚：答案来自哪里、用了多久；更好的服务先失败了时写上「兜底」)
---@param result table
---@return string
local function footer_of(result)
  local lookup = require("weread.lookup")
  -- the model by name: "大模型" says nothing about which one answered
  -- (直接写模型名："大模型"说不清是哪一个答的)
  local parts = { result.source == "llm" and result.model or lookup.provider_name(result.source) }
  if result.fallback then
    parts[1] = "兜底：" .. parts[1]
  end
  parts[#parts + 1] = result.cached and "缓存" or string.format("%d ms", result.ms or 0)
  return " " .. table.concat(parts, " · ") .. " "
end

---Fill the popup (or open it) with lines.
---(把行填进弹窗（没开就先开）)
---@param lines string[]
---@param marks table[]
---@param footer string|nil
local function show(lines, marks, footer)
  local text = require("weread.text")
  local width = 8
  for _, line in ipairs(lines) do
    width = math.max(width, text.cells(line))
  end
  if footer then
    width = math.max(width, text.cells(footer))
  end
  width = math.min(width, math.max(10, vim.o.columns - 4))
  local height = math.min(#lines, math.max(1, math.floor(vim.o.lines / 2)))
  if not M.is_open() or not popup.buf or not vim.api.nvim_buf_is_valid(popup.buf) then
    M.close()
    local buf = vim.api.nvim_create_buf(false, true)
    vim.bo[buf].bufhidden = "wipe"
    vim.bo[buf].filetype = "weread-lookup"
    popup.buf = buf
  end
  vim.bo[popup.buf].modifiable = true
  vim.api.nvim_buf_set_lines(popup.buf, 0, -1, false, lines)
  vim.bo[popup.buf].modifiable = false
  local namespace = vim.api.nvim_create_namespace("weread.lookup")
  vim.api.nvim_buf_clear_namespace(popup.buf, namespace, 0, -1)
  for _, mark in ipairs(marks) do
    pcall(vim.api.nvim_buf_set_extmark, popup.buf, namespace, mark[1], mark[2], { end_col = mark[3], hl_group = mark[4] })
  end
  -- below the cursor when there is room, above it otherwise
  -- (下方放得下就放下方，否则放上方)
  local below = vim.fn.winline() + height + 3 <= vim.api.nvim_win_get_height(0)
  local config = {
    relative = "cursor",
    row = below and 1 or -(height + 2),
    col = 0,
    width = width,
    height = height,
    style = "minimal",
    border = "rounded",
    zindex = 70,
    focusable = true,
  }
  if footer then
    config.footer = { { footer, "WereadLookupSource" } }
    config.footer_pos = "right"
  end
  if M.is_open() then
    -- keep it where it opened: the cursor may be inside it by now
    -- (留在打开时的位置：光标这时可能已经进了弹窗)
    pcall(vim.api.nvim_win_set_config, popup.win, {
      width = width,
      height = height,
      footer = config.footer,
      footer_pos = config.footer_pos,
    })
    return
  end
  popup.win = vim.api.nvim_open_win(popup.buf, false, config)
  vim.wo[popup.win].wrap = true
  local page = require("weread.theme").float_winhighlight()
  vim.wo[popup.win].winhighlight = page ~= "" and page or "Normal:NormalFloat,FloatBorder:FloatBorder"
  for _, key in ipairs({ "q", "<Esc>" }) do
    vim.keymap.set("n", key, M.close, { buffer = popup.buf, nowait = true, silent = true })
  end
end

---Close the popup when the reader moves on.
---(读者走开时关闭弹窗)
local function watch()
  popup.source = vim.api.nvim_get_current_win()
  popup.anchor = vim.api.nvim_win_get_cursor(0)
  popup.group = vim.api.nvim_create_augroup("weread_lookup_popup", { clear = true })
  local source_buf = vim.api.nvim_get_current_buf()
  vim.api.nvim_create_autocmd({ "CursorMoved", "InsertEnter", "BufLeave" }, {
    group = popup.group,
    buffer = source_buf,
    callback = function(event)
      if event.event == "CursorMoved" then
        local now = vim.api.nvim_win_get_cursor(0)
        if popup.anchor and now[1] == popup.anchor[1] and now[2] == popup.anchor[2] then
          return
        end
      end
      if event.event == "BufLeave" and popup.entering then
        -- `K` again: going into the popup, not away from it (再按 K：是进入弹窗，不是离开)
        return
      end
      M.close()
    end,
  })
  vim.api.nvim_create_autocmd("WinLeave", {
    group = popup.group,
    callback = function()
      -- leaving the popup itself, after `K` moved into it (离开弹窗本身：K 进去之后)
      if popup.win and vim.api.nvim_get_current_win() == popup.win then
        vim.schedule(M.close)
      end
    end,
  })
end

---Translate a passage (or a word) and show it next to the cursor.
---(翻译一段文字（或一个词），显示在光标旁边)
---@param text string
---@return boolean started
function M.translate(text)
  local lookup = require("weread.lookup")
  if not lookup.normalize(text) then
    require("weread.ui").notify("weread: 这里没有可翻译的外文", vim.log.levels.INFO)
    return false
  end
  M.close()
  popup.token = popup.token + 1
  local token = popup.token
  -- a sentence waits for the LLM: say who is being asked, it takes a second or two
  -- (句子要等大模型：写明在问谁，它要一两秒)
  local waiting_for = nil
  if not lookup.is_word(lookup.normalize(text)) and lookup.llm_first() then
    waiting_for = (require("weread.config").get().lookup.llm or {}).model
  end
  show({ waiting_for and ("翻译中…（" .. waiting_for .. "）") or "翻译中…" }, {}, nil)
  watch()
  local width = math.min(WIDTH, math.max(20, vim.o.columns - 8))
  lookup.translate(text, {
    on_result = function(result)
      if token ~= popup.token or not M.is_open() then
        return
      end
      local lines, marks = M.render(result, width)
      if result.fallback then
        -- why the fallback answered, under the translation, in the muted colour
        -- (兜底的原因，写在译文下面，用淡色)
        local reason = (result.fallback_reasons or {})[1] or "大模型不可用"
        for _, line in ipairs(require("weread.text").wrap("（兜底结果：" .. reason .. "）", width, 3)) do
          lines[#lines + 1] = line
          marks[#marks + 1] = { #lines - 1, 0, #line, "WereadLookupSource" }
        end
      end
      show(lines, marks, footer_of(result))
    end,
    on_error = function(message)
      if token ~= popup.token or not M.is_open() then
        return
      end
      local lines = require("weread.text").wrap("翻译失败：" .. message, width, 8)
      lines[#lines + 1] = "（:checkhealth weread 查看翻译服务状态）"
      show(lines, { { 0, 0, #("翻译失败："), "DiagnosticError" } }, nil)
    end,
  })
  return true
end

---The English word under the cursor, or nil.
---(光标下的英文单词，没有则为 nil)
---@return string|nil
function M.word_under_cursor()
  local cursor = vim.api.nvim_win_get_cursor(0)
  local line = vim.api.nvim_get_current_line()
  return (M.word_at(line, cursor[2]))
end

---Text of a highlight drawn in a buffer.
---(buffer 里某条划线的文字)
---@param buf integer
---@param entry table
---@return string
local function entry_text(buf, entry)
  local finish = entry.finish_line or entry.line
  local lines = vim.api.nvim_buf_get_lines(buf, entry.line, finish + 1, false)
  if #lines == 0 then
    return ""
  end
  if #lines == 1 then
    lines[1] = lines[1]:sub((entry.from_col or 0) + 1, entry.to_col or #lines[1])
  else
    lines[1] = lines[1]:sub((entry.from_col or 0) + 1)
    lines[#lines] = lines[#lines]:sub(1, entry.to_col or #lines[#lines])
  end
  return M.join(lines)
end

---Is the cursor on a footnote mark (or right next to it)?
---(光标是否在脚注标记上（或紧挨着它）)
---@return boolean
local function on_footnote()
  local cursor = vim.api.nvim_win_get_cursor(0)
  local footnote = require("weread.xhtml").footnote_at(session.footnotes(), cursor[1] - 1, cursor[2])
  if not footnote then
    return false
  end
  local from, to = tonumber(footnote.col_from) or 0, tonumber(footnote.col_to) or 0
  return cursor[2] >= from - 1 and cursor[2] <= to
end

---What `K` does in normal mode on a page.
---(书页上普通模式 K 的行为)
---
---1. Inside an open popup's reach (`K` twice): move into the popup.
---2. On a footnote mark: the footnote.
---3. On a highlight: choose between translating and the thoughts. A highlight
---   with no foreign text in it has nothing to translate, so it goes straight to
---   the thoughts.
---4. On an English word: translate it.
---5. Near a highlight on this line: its thoughts, as `K` always did.
---(1. 弹窗开着时再按 K：进入弹窗。2. 在脚注标记上：脚注。3. 在划线上：在翻译与想法之间选；
--- 划线里没有外文就没什么可翻译，直接看想法。4. 在英文单词上：翻译它。5. 这一行附近有划线：
--- 像以前一样看它的想法)
function M.hover()
  if M.is_open() and popup.source == vim.api.nvim_get_current_win() then
    popup.entering = true
    pcall(vim.api.nvim_set_current_win, popup.win)
    popup.entering = false
    return
  end
  local reader = require("weread.reader")
  if on_footnote() and reader.show_footnote() then
    return
  end
  local buf = vim.api.nvim_get_current_buf()
  local cursor = vim.api.nvim_win_get_cursor(0)
  local annotations = require("weread.annotations")
  local word = M.word_under_cursor()
  local entry = require("weread.annotations_render").entry_covering(buf, cursor[1] - 1, cursor[2])
  if entry then
    local passage = entry_text(buf, entry)
    local target = word or (passage:find("%a") and passage or nil)
    if not target then
      annotations.show_thoughts_at_cursor(buf, cursor[1] - 1)
      return
    end
    local line = cursor[1] - 1
    local label = require("weread.text").ellipsize(target, 24)
    vim.ui.select({ "translate", "thoughts" }, {
      prompt = "划线",
      format_item = function(item)
        return item == "translate" and ("翻译「" .. label .. "」") or "查看划线的想法"
      end,
    }, function(choice)
      if choice == "translate" then
        M.translate(target)
      elseif choice == "thoughts" then
        annotations.show_thoughts_at_cursor(buf, line)
      end
      -- nil: the menu was dismissed, and dismissing is the answer (nil：菜单被关掉，关掉就是答复)
    end)
    return
  end
  if word then
    M.translate(word)
    return
  end
  if reader.show_footnote() then
    return
  end
  if #annotations.annotations_on_line(buf, cursor[1] - 1) > 0 then
    annotations.show_thoughts_at_cursor(buf, cursor[1] - 1)
    return
  end
  require("weread.ui").notify("weread: 光标下没有外文；选中一段文字再按 K 可整段翻译", vim.log.levels.INFO)
end

---`K` in visual mode: translate what is selected.
---(可视模式的 K：翻译选中的内容)
function M.hover_selection()
  M.translate(M.selection())
end

return M
