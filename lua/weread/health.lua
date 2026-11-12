--[[
`:checkhealth weread` implementation.

Checks the external tools, the terminal's image capability and the local
credential cache so that "nothing shows up" can be diagnosed in one place.
(自检：外部工具、终端图片能力、本地凭据，便于一站式定位“怎么什么都不显示”)
]]

local config = require("weread.config")
local http = require("weread.http")

local M = {}

---@param name string
---@param hint string
local function tool(name, hint)
  if vim.fn.executable(name) == 1 then
    vim.health.ok(string.format("%s: %s", name, vim.fn.exepath(name)))
    return true
  end
  vim.health.error(string.format("%s not found. %s", name, hint))
  return false
end

---@return boolean|nil available
---@return string detail
local function snacks_image()
  local ok, snacks = pcall(require, "snacks")
  if not ok or type(snacks) ~= "table" then
    return nil, "snacks.nvim is not installed"
  end
  if not snacks.config or not snacks.config.image or not snacks.config.image.enabled then
    return false, "snacks.nvim is installed but its `image` module is disabled"
  end
  local ok_support, supported = pcall(function()
    return require("snacks.image").supports_terminal()
  end)
  if not ok_support then
    return false, "snacks.image failed to report terminal support"
  end
  if not supported then
    return false, "the current terminal does not implement the kitty graphics protocol"
  end
  return true, string.format("terminal %s supports the kitty graphics protocol", vim.env.TERM or "?")
end

function M.check()
  -- :checkhealth may run before any :WeRead* command loaded the plugin.
  -- (:checkhealth 可能在任何 :WeRead* 命令加载插件之前运行)
  if not pcall(http.jar_path) then
    require("weread").ensure_setup()
  end
  vim.health.start("weread.nvim")

  vim.health.info("Neovim: " .. tostring(vim.version()))

  vim.health.start("weread.nvim: external tools")
  tool("curl", "Required. Install curl; all HTTP requests go through it.")
  tool("qrencode", "Required for QR login. Install qrencode.")
  tool("magick", "Optional. snacks.image uses it to convert non-PNG illustrations.")
  local optional = {
    { "zip", "Optional. Needed by :WeReadEpub to pack the EPUB." },
    { "openssl", "Optional. Needed to upload an exported EPUB to the shelf." },
    { "fc-list", "Optional. Needed by :WeReadFont to list local fonts." },
    { "fc-scan", "Optional. Needed by :WeReadFont to read the family of a WeRead font." },
    { "fc-cache", "Optional. Needed by :WeReadFont to register downloaded fonts." },
    { "unzip", "Optional. Needed by :WeReadFont to unpack a fetched font." },
    { "kitten", "Optional. Needed by :WeReadFont to switch kitty's font while reading." },
    { "sqlite3", "Optional. Needed by :WeReadDict install and the ecdict lookup." },
  }
  for _, item in ipairs(optional) do
    if vim.fn.executable(item[1]) == 1 then
      vim.health.ok(string.format("%s: %s", item[1], vim.fn.exepath(item[1])))
    else
      vim.health.warn(string.format("%s not found. %s", item[1], item[2]))
    end
  end

  vim.health.start("weread.nvim: reading font")
  local ok_font, font = pcall(require, "weread.font")
  if ok_font then
    local choice = font.choice()
    if choice then
      vim.health.ok(string.format(
        "font: %s (%s)",
        choice.name,
        choice.kind == "weread" and "WeRead" or "local"
      ))
    else
      vim.health.info("font: not chosen; the terminal's own font is used")
    end
    local reason = font.unavailable_reason()
    local ok_kitty, kitty = pcall(require, "weread.font_kitty")
    local remote = ok_kitty and kitty.status().remote or nil
    local gui = ok_kitty and kitty.gui() or false
    if reason ~= "" then
      vim.health.warn(reason, {
        "The choice is still remembered; it applies the next time a chapter opens in kitty.",
        "选择字体时会自动启用 kitty 远程控制。",
      })
    elseif gui then
      vim.health.ok("GUI font switching is ready (guifont / linespace)")
    elseif remote == true then
      vim.health.ok("kitty runtime font switching is ready")
    elseif remote == false then
      vim.health.warn("kitty remote control is off; the reading font cannot be switched", {
        "选择字体时会自动启用 kitty 远程控制。",
      })
    else
      vim.health.info("kitty 远程控制尚未检测；选择字体时自动启用")
    end
  end

  vim.health.start("weread.nvim: image rendering")
  local available, detail = snacks_image()
  if available == true then
    vim.health.ok(detail)
  elseif available == false then
    vim.health.warn(detail, {
      "Images will fall back to a placeholder line; use the hover mapping to view them.",
      "Enable it with: { 'folke/snacks.nvim', opts = { image = { enabled = true } } }",
    })
  else
    vim.health.warn(detail, { "Illustrations will only be viewable as placeholder lines." })
  end
  local ok_image, image = pcall(require, "weread.image")
  if ok_image and not image.supports_inline() then
    local reason = image.unsupported_reason()
    if reason ~= "" then
      vim.health.warn("inline illustrations are off: " .. reason, {
        "Illustrations still render on demand with <leader>wo (they are downloaded first).",
      })
    end
  end

  vim.health.start("weread.nvim: tables and code blocks")
  local decorations = require("weread.decorations")
  if decorations.available() then
    local error_message = decorations.prettify_error
    if error_message and error_message ~= "not set up yet" then
      vim.health.warn("render-markdown refused the page's config: " .. error_message, {
        "Tables and code blocks fall back to plain markdown, everything else still works.",
      })
    else
      vim.health.ok("render-markdown draws tables and code blocks, in the reading palette")
    end
  else
    vim.health.info("render-markdown.nvim is not installed", {
      "Tables stay as `| cell | cell |` text and code fences stay plain.",
      "Nothing breaks: the page keeps its own typography either way.",
    })
  end
  -- A fence without a parser is uncoloured, and two thirds of a book's listings
  -- are shell, JSON, YAML or Python rather than markdown.
  -- (没有 parser 的围栏不会被上色，而书里约三分之二的清单是 shell/JSON/YAML/Python 而不是
  --  markdown)
  local wanted = { "bash", "json", "yaml", "python", "lua", "javascript" }
  local missing = {}
  for _, language in ipairs(wanted) do
    if #vim.api.nvim_get_runtime_file("parser/" .. language .. ".*", true) == 0 then
      missing[#missing + 1] = language
    end
  end
  if #missing == 0 then
    vim.health.ok("tree-sitter parsers for the languages books write are installed")
  else
    vim.health.warn("no tree-sitter parser for: " .. table.concat(missing, ", "), {
      "Those listings show the language name but no syntax colours.",
      "Install them with :TSInstall " .. table.concat(missing, " "),
    })
  end

  vim.health.start("weread.nvim: storage")
  local dir = config.ensure_dirs()
  if vim.fn.filewritable(dir) == 2 then
    vim.health.ok("data directory: " .. dir)
  else
    vim.health.error("data directory is not writable: " .. dir)
  end

  vim.health.start("weread.nvim: account")
  local jar = http.load_cookies()
  local credentials_path = config.path("credentials.json")
  if vim.fn.filereadable(credentials_path) == 1 then
    vim.health.ok("credentials.json found")
  else
    vim.health.info("no credentials.json yet; run :WeReadLogin")
  end
  local ok_key, key = pcall(require("weread.auth").api_key)
  if ok_key and type(key) == "string" and key ~= "" then
    vim.health.ok("official API key present")
  else
    vim.health.warn("no official API key; shelf, search, stats and export will fail", {
      "Enable 「微信读书 Skill」 in the app, then run :WeReadLogin again.",
    })
  end
  local names = {}
  for _, cookie in ipairs(jar) do
    names[cookie.name] = cookie.value
  end
  for _, key in ipairs({ "wr_vid", "wr_skey", "wr_rt" }) do
    if names[key] and names[key] ~= "" then
      vim.health.ok(string.format("cookie %s present", key))
    else
      vim.health.warn(string.format("cookie %s missing; run :WeReadLogin", key))
    end
  end

  local duplicates = {}
  local seen = {}
  for _, cookie in ipairs(jar) do
    if cookie.name == "wr_skey" or cookie.name == "wr_rt" then
      seen[cookie.name] = (seen[cookie.name] or 0) + 1
      if seen[cookie.name] > 1 then
        duplicates[cookie.name] = true
      end
    end
  end
  for name in pairs(duplicates) do
    vim.health.warn(string.format("duplicate %s entries in the cookie jar", name), {
      "Stale duplicates can cause `登录超时`; run :WeReadLogin to rebuild the jar.",
    })
  end

  vim.health.start("weread.nvim: reading")
  local progress_ok, progress = pcall(require, "weread.progress")
  if progress_ok then
    local status = progress.status()
    if status.enabled then
      if status.last_error then
        vim.health.warn("the last progress report failed: " .. tostring(status.last_error))
      else
        vim.health.ok(
          "progress reporting is enabled (every "
            .. tostring(config.get().sync_interval)
            .. "s, plus a settled cursor after "
            .. tostring(config.get().sync_debounce or 0)
            .. "s)"
        )
      end
      if config.get().sync_pull ~= false then
        if status.pulled_at then
          vim.health.ok(
            "remote progress pull works (last: "
              .. os.date("%Y-%m-%d %H:%M", status.pulled_at)
              .. (status.pulled_position and (", " .. tostring(status.pulled_position.chapter_uid) .. " @ " .. tostring(status.pulled_position.chapter_offset)) or "")
              .. ")"
          )
        elseif status.pull_error then
          vim.health.warn("the last remote progress pull failed: " .. tostring(status.pull_error))
        else
          vim.health.info("remote progress pull is on but has not run yet in this session")
        end
        local every = tonumber(config.get().sync_pull_interval) or 0
        if every > 0 then
          vim.health.info("while a chapter is open, the phone's progress is checked every " .. every .. "s")
        end
      else
        vim.health.info("remote progress pull is off (sync_pull = false)")
      end
    else
      vim.health.info("progress reporting is disabled (sync_interval = 0)")
    end
  end

  local reader_ok, reader = pcall(require, "weread.reader")
  if reader_ok then
    local book = reader.state.book
    if book then
      vim.health.ok(string.format("open book: %s (%s)", book.title or "?", book.book_id))
    else
      vim.health.info("no book opened yet")
    end
  end

  vim.health.start("weread.nvim: page layout")
  local layout_ok, layout = pcall(require, "weread.layout")
  if layout_ok then
    local settings = layout.config()
    if not settings.enabled then
      vim.health.info("page layout is off (layout.page_chars = 0): full window width")
    else
      local win = vim.api.nvim_get_current_win()
      local width = layout.page_width(win)
      vim.health.ok(
        string.format(
          "page: %d characters (%d cells) %s, margin %d cells, window %d columns",
          math.floor(width / 2),
          width,
          settings.adaptive and "adaptive" or "fixed",
          layout.margin(win, width),
          vim.api.nvim_win_get_width(win)
        )
      )
    end
    local shell_ok, shell = pcall(require, "weread.shell")
    if shell_ok then
      local opts = config.get().layout or {}
      vim.health.ok(
        string.format(
          "reading shell: statusline %s, cursor %s, mouse wheel %s, auto next chapter %s",
          tostring(opts.statusline or "off"),
          tostring(opts.cursor or "block"),
          tostring(opts.mousescroll or "ver:1,hor:1"),
          tostring(opts.auto_next ~= false)
        )
      )
      if reader_ok then
        local info = reader.buffer_info()
        local open_chapter = info and ((reader.state.catalog or {}).chapters or {})[info.chapter_index]
        local rendered = open_chapter
            and require("weread.cache").read_json(
              require("weread.cache").chapter_file(info.book_id, open_chapter, "map.json")
            )
        local wanted = require("weread.reader").page_width()
        if rendered and tonumber(rendered.page_width) and wanted and tonumber(rendered.page_width) ~= wanted then
          vim.health.warn(
            string.format(
              "the open chapter was laid out for %s cells while the window wants %s; it re-renders on resize or reopen",
              tostring(rendered.page_width),
              tostring(wanted)
            )
          )
        end
      end
    end
  end

  vim.health.start("weread.nvim: translation (K)")
  local lookup_opts = config.get().lookup or {}
  local ecdict = require("weread.ecdict")
  local word_list = table.concat(lookup_opts.word or {}, " → ")
  local sentence_list = table.concat(lookup_opts.sentence or {}, " → ")
  vim.health.info("words: " .. word_list .. "; sentences: " .. sentence_list)
  if vim.tbl_contains(lookup_opts.word or {}, "ecdict") then
    if vim.fn.executable("sqlite3") ~= 1 then
      vim.health.warn("sqlite3 not found: the offline dictionary (ECDICT) is skipped", { "Install sqlite3" })
    elseif ecdict.available() then
      vim.health.ok("offline dictionary: " .. ecdict.path())
    else
      vim.health.info("offline dictionary not installed; words go online. Run :WeReadDict install for offline lookups")
    end
  end
  local lookup = require("weread.lookup")
  if lookup.llm_available() then
    vim.health.info("chapter translation (<leader>wy): pick one of "
      .. table.concat(lookup_opts.chapter_models or {}, ", ") .. " or WeRead's translation; WeRead's is the fallback")
  else
    vim.health.info("chapter translation (<leader>wy): no LLM, WeRead's translation is used")
  end
  if vim.tbl_contains(lookup_opts.sentence or {}, "llm") then
    local llm = lookup_opts.llm or {}
    local endpoint = lookup.llm_endpoint()
    local fallback = "sentences use the fast translator instead"
    if type(llm.model) ~= "string" or llm.model == "" then
      vim.health.warn("lookup.llm.model is not set: " .. fallback)
    elseif not endpoint.url then
      vim.health.warn("no LLM endpoint (" .. endpoint.via .. "): " .. fallback, {
        "Set lookup.llm.base_url, or start nvim where $ANTHROPIC_BASE_URL is set",
      })
    elseif not endpoint.key then
      vim.health.warn(string.format("no API key for %s (%s): %s", endpoint.url, endpoint.via, fallback))
    else
      vim.health.ok(string.format("sentences: %s at %s (%s)", llm.model, endpoint.url, endpoint.via))
    end
  end
end

return M
