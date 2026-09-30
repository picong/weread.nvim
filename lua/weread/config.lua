--[[
Plugin configuration: defaults, validation and the on-disk layout.
(插件配置：默认值、校验与磁盘布局)
]]

local M = {}

M.defaults = {
  ---Root directory for credentials, caches and reading positions.
  ---(凭据、缓存与阅读位置的根目录)
  ---@type string|nil
  data_dir = nil,

  ---Width guide drawn as a colorcolumn. 0 disables it; it is off by default
  ---because a solid vertical line through Chinese text reads badly.
  ---(用 colorcolumn 画的宽度参考线。0 表示不画；默认关闭，因为一条竖线穿过中文
  --- 正文观感很差)
  ---@type integer
  text_width = 0,

  ---Typesetting of the rendered body.
  ---(正文排版)
  ---@type table
  paragraph = {
    ---Drop the blank line between paragraphs. A Chinese book separates
    ---paragraphs by indentation, not by empty lines, and the blank lines
    ---otherwise eat half of every screen.
    ---(去掉段间空行。中文书靠首行缩进区分段落而不是空行，否则每屏一半是空白)
    compact = true,
    ---Air around headings, figures and rules: "compact" (default) or "none".
    ---("compact" 或 "none"：标题/插图/分隔线周围是否留空行)
    gap = "compact",
    ---Repeat the chapter title as the first heading. The winbar already shows
    ---it, so this is off by default and saves two rows per chapter.
    ---(是否在正文里重复章节标题。winbar 已经显示了，默认关闭，每章省两行)
    chapter_title = false,
    ---Prefix for the first line of a paragraph. Ignored when the source
    ---already carries its own indent (TXT books ship with full-width spaces).
    ---(段落首行缩进。若原文自带缩进则不再追加——TXT 型书籍本身带全角空格)
    indent = "　　",
    ---Blank lines kept around headings, figures and rules.
    ---(标题、插图、分隔线周围保留的空行)
    block_gap = true,
  },

  ---Highlight the paragraph under the cursor.
  ---(是否高亮光标所在段落)
  ---@type boolean
  cursorline = false,

  ---Reading palette applied to the chapter window only: paper, sepia, light,
  ---night, or "none" to keep your colorscheme.
  ---(只作用于章节窗口的阅读配色：paper/sepia/light/night，或 "none" 沿用你的配色)
  ---@type string
  theme = "paper",

  ---Preferred reading font. Terminals own their fonts, so this writes a snippet
  ---you include from your terminal config; GUIs get `guifont` directly.
  ---(偏好的阅读字体。终端字体由终端掌管，因此这里写出一段供终端 include 的片段；
  --- GUI 则会直接设置 guifont)
  ---@type string|nil
  font = nil,

  ---Upload the local position/reading time to WeRead every N seconds. 0 disables it.
  ---(每 N 秒把本地进度与阅读时长回传微信读书，0 表示关闭)
  ---@type integer
  sync_interval = 60,

  ---Upload progress when leaving a chapter buffer.
  ---(离开章节 buffer 时回传进度)
  ---@type boolean
  sync_on_leave = true,

  ---Inline image rendering limits, in terminal cells.
  ---(插图内联渲染上限，单位为终端单元格)
  ---@type table
  image = {
    max_width = 60,
    ---Kept modest on purpose: a tall figure pushes the text off screen.
    ---(刻意克制：太高的插图会把正文挤下去)
    max_height = 14,
    ---Icon replacing the markdown image syntax while reading.
    ---(阅读时替换 markdown 图片语法的图标)
    icon = "⧉",
  },

  ---HTTP proxy mode: nil inherits the environment, "direct" bypasses every proxy.
  ---Set it to "direct" when the machine's proxy would route domestic traffic abroad.
  ---(代理模式：nil 沿用环境变量，"direct" 强制直连；当机器的代理会把国内流量
  --- 绕到境外时，建议设为 "direct")
  ---@type string|nil
  proxy = nil,

  ---Service root. Only changed by tests, which point it at a local mock server.
  ---(服务根地址；仅测试会改成本地 mock 服务器)
  ---@type string
  base_url = "https://weread.qq.com",

  ---Official Agent API origin or full endpoint url.
  ---(官方 Agent API 的 origin 或完整端点地址)
  ---@type string
  gateway_url = "https://i.weread.qq.com",

  ---Register the default buffer-local keymaps in chapter buffers.
  ---(在章节 buffer 注册默认快捷键)
  ---@type boolean
  keymaps = true,
}

local state = {
  opts = vim.deepcopy(M.defaults),
  configured = false,
}

---@param opts table|nil
function M.setup(opts)
  state.opts = vim.tbl_deep_extend("force", vim.deepcopy(M.defaults), opts or {})
  state.configured = true
  return state.opts
end

---@return table
function M.get()
  return state.opts
end

---@return boolean
function M.is_configured()
  return state.configured
end

---@return string
function M.data_dir()
  return state.opts.data_dir or (vim.fn.stdpath("data") .. "/weread")
end

---@param ... string
---@return string
function M.path(...)
  return table.concat({ M.data_dir(), ... }, "/")
end

---Create the directory tree the plugin writes into.
---(创建插件写入所需的目录树)
---@return string data_dir
function M.ensure_dirs()
  local root = M.data_dir()
  for _, dir in ipairs({ root, root .. "/books", root .. "/tmp" }) do
    local ok, err = pcall(vim.fn.mkdir, dir, "p")
    if not ok then
      error(string.format("weread: 无法创建数据目录 %s（可在 setup 里改 data_dir）：%s", dir, tostring(err)))
    end
  end
  return root
end

return M
