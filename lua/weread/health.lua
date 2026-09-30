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
  vim.health.start("weread.nvim")

  vim.health.info("Neovim: " .. tostring(vim.version()))

  vim.health.start("weread.nvim: external tools")
  tool("curl", "Required. Install curl; all HTTP requests go through it.")
  tool("qrencode", "Required for QR login. Install qrencode.")
  tool("magick", "Optional. Needed to convert non-PNG illustrations.")

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
end

return M
