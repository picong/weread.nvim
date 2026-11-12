--[[
Display-width text helpers shared by the popups and pickers (book preview,
thought panel, stats, bookmarks, chapter TOC): measuring, ellipsizing, fitting
and wrapping text by display cells, plus the highlight groups those views share.
(弹窗与选择器共用的按显示宽度处理文本的工具——书籍预览、想法面板、统计、书签、章节目录：
 度量、省略、截断、折行，以及这些视图共用的高亮组)

Kept out of preview.lua so a view that only needs a width calculation does not
have to load the whole book preview (and its snacks glue) to get it.
(从 preview.lua 里拆出来，这样只需要算宽度的视图不必为此加载整个书籍预览及其 snacks 胶水)
]]

local M = {}

---Display cells of a string. `nvim_strwidth`, not `strdisplaywidth`: the
---latter depends on the current window (a string wider than it picks up
---'showbreak'/'breakindent' cells).
---(字符串的显示单元格数。用 `nvim_strwidth` 而不是 `strdisplaywidth`：后者取决于当前
--- 窗口——比窗口宽的字符串会被算上 'showbreak'/'breakindent' 的补白)
---@param text string
---@return integer
function M.cells(text)
  return vim.api.nvim_strwidth(text)
end

---Characters of a string, one entry each (a multibyte character stays whole).
---(把字符串拆成字符，多字节字符保持完整)
---@param text string
---@return string[]
function M.chars(text)
  return vim.fn.split(text, "\\zs")
end

---Cut to a display width with a trailing ellipsis. Cells, not bytes or
---characters: a Chinese character is two cells wide.
---(按显示宽度截断并补省略号。按单元格而不是字节或字符：一个汉字占两格)
---@param text string
---@param width integer
---@param force boolean|nil add the ellipsis even when the text fits(放得下也补省略号)
---@return string
function M.ellipsize(text, width, force)
  if width <= 0 then
    return ""
  end
  if not force and M.cells(text) <= width then
    return text
  end
  local out, used = {}, 0
  for _, char in ipairs(M.chars(text)) do
    local w = M.cells(char)
    if used + w > width - 1 then
      break
    end
    out[#out + 1] = char
    used = used + w
  end
  return vim.trim(table.concat(out)) .. "…"
end

---One line of text, whitespace collapsed, fitted to a width.
---(单行文本：折叠空白后按宽度截断)
---@param text any
---@param width integer
---@return string
function M.fit(text, width)
  local flat = vim.trim((tostring(text or ""):gsub("%s+", " ")))
  return M.ellipsize(flat, width)
end

---Wrap a paragraph to a display width, at most `max_lines` lines; the last
---line ends in an ellipsis when text was left over. Latin text breaks at the
---last space, CJK text anywhere.
---(按显示宽度折行，最多 `max_lines` 行；有剩余时末行以省略号结尾。西文在最后一个
--- 空格处断行，中文任意处可断)
---@param text any
---@param width integer
---@param max_lines integer
---@return string[]
function M.wrap(text, width, max_lines)
  local lines = {}
  local leftover = false
  for para in tostring(text or ""):gmatch("[^\r\n]+") do
    para = vim.trim(para)
    if para ~= "" then
      if #lines >= max_lines then
        leftover = true
        break
      end
      local current, used = {}, 0
      for _, char in ipairs(M.chars(para)) do
        local w = M.cells(char)
        if used + w > width then
          if #lines + 1 >= max_lines then
            leftover = true
            break
          end
          local cut = nil
          for position = #current, math.max(1, #current - 16), -1 do
            if current[position] == " " then
              cut = position
              break
            end
          end
          local carry = {}
          if cut then
            for position = cut + 1, #current do
              carry[#carry + 1] = current[position]
            end
            current = vim.list_slice(current, 1, cut - 1)
          end
          lines[#lines + 1] = vim.trim(table.concat(current))
          current = carry
          used = M.cells(table.concat(carry))
          if char == " " and #current == 0 then
            w = 0
          end
        end
        if w > 0 then
          current[#current + 1] = char
          used = used + w
        end
      end
      lines[#lines + 1] = vim.trim(table.concat(current))
      if leftover then
        break
      end
    end
  end
  if leftover and #lines > 0 then
    lines[#lines] = M.ellipsize(lines[#lines], width, true)
  end
  return lines
end

---Text width of a window, gutter excluded.
---(窗口的正文宽度，不含行号等边栏)
---@param win integer|nil
---@return integer|nil
function M.text_width(win)
  if not win or not vim.api.nvim_win_is_valid(win) then
    return nil
  end
  local info = vim.fn.getwininfo(win)[1]
  return vim.api.nvim_win_get_width(win) - ((info and info.textoff) or 0)
end

---Highlight groups shared by the popups. Defined on every paint: `:colorscheme`
---clears them, and `default = true` keeps the call harmless when the user has
---their own.
---(弹窗共用的高亮组。每次绘制都定义：`:colorscheme` 会把它们清掉；`default = true`
--- 保证用户自定义时这次调用不产生影响)
function M.define_highlights()
  local function set(name, spec)
    spec.default = true
    vim.api.nvim_set_hl(0, name, spec)
  end
  set("WereadPreviewTitle", { link = "Title" })
  set("WereadPreviewSection", { link = "Function" })
  set("WereadPreviewRule", { link = "Comment" })
  set("WereadPreviewDim", { link = "Comment" })
  set("WereadPreviewStar", { link = "DiagnosticWarn" })
  set("WereadPreviewCurrent", { link = "DiagnosticOk" })
  set("WereadPreviewPart", { bold = true })
end

return M
