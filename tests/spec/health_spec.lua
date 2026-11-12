--[[
Tests for weread.health (`:checkhealth weread`).

Nearly everything in it is a call into vim.health, so the tests replace
vim.health with a recorder and check what a run reports: that a missing curl is
an error and a present one is not, and that the whole check runs to the end on
a fresh data directory.
(health 单测：它几乎全是对 vim.health 的调用，因此用记录器替换 vim.health，检查一次运行
 报告了什么：缺 curl 是错误、有 curl 不是，以及在全新数据目录上整个检查能跑完)
]]

local tmpdir = "/tmp/weread-test-health"
vim.fn.delete(tmpdir, "rf")
vim.fn.mkdir(tmpdir, "p")

local config = require("weread.config")
local http = require("weread.http")

config.setup({ data_dir = tmpdir, sync_interval = 0, proxy = "direct", keymaps = false })
config.ensure_dirs()
http.setup({ jar = config.path("cookies.txt"), tmpdir = config.path("tmp"), proxy = "direct" })

local health = require("weread.health")

---Run the check with vim.health recorded and `executable()` answered per tool.
---(记录 vim.health，并按工具名回答 executable()，然后跑一遍检查)
---@param available table<string, boolean> which tools exist(哪些工具存在)
---@return { kind: string, message: string }[] reports
local function run_check(available)
  local reports = {}
  local function recorder(kind)
    return function(message)
      reports[#reports + 1] = { kind = kind, message = tostring(message) }
    end
  end
  local names = { "start", "ok", "warn", "error", "info" }
  local original_health = {}
  for _, name in ipairs(names) do
    original_health[name] = vim.health[name]
    vim.health[name] = recorder(name)
  end
  local original_executable = vim.fn.executable
  local original_exepath = vim.fn.exepath
  vim.fn.executable = function(name)
    if available[name] ~= nil then
      return available[name] and 1 or 0
    end
    return original_executable(name)
  end
  vim.fn.exepath = function(name)
    if available[name] then
      return "/usr/bin/" .. name
    end
    return original_exepath(name)
  end

  local ok, err = pcall(health.check)

  vim.fn.executable = original_executable
  vim.fn.exepath = original_exepath
  for _, name in ipairs(names) do
    vim.health[name] = original_health[name]
  end
  if not ok then
    error(err, 0)
  end
  return reports
end

---@param reports { kind: string, message: string }[]
---@param kind string
---@param needle string
---@return boolean
local function reported(reports, kind, needle)
  for _, report in ipairs(reports) do
    if report.kind == kind and report.message:find(needle, 1, true) then
      return true
    end
  end
  return false
end

describe("weread.health", function()
  it("reports a missing curl as an error", function()
    local reports = run_check({ curl = false, qrencode = true, magick = true })
    truthy(reported(reports, "error", "curl not found"), "curl is required, so its absence is an error")
    falsy(reported(reports, "ok", "curl:"), "and it is not also reported as present")
  end)

  it("reports a present curl as ok, without an error", function()
    local reports = run_check({ curl = true, qrencode = true, magick = true })
    truthy(reported(reports, "ok", "curl: /usr/bin/curl"))
    falsy(reported(reports, "error", "curl"), "no error about curl")
    falsy(reported(reports, "error", "not found"), "and no tool is reported missing")
  end)

  it("reports a missing qrencode as an error but keeps going", function()
    local reports = run_check({ curl = true, qrencode = false, magick = true })
    truthy(reported(reports, "error", "qrencode not found"))
    truthy(reported(reports, "ok", "curl:"), "the other tools are still checked")
  end)

  it("runs through to the account and storage sections on a fresh data directory", function()
    local reports = run_check({ curl = true, qrencode = true, magick = true })
    truthy(reported(reports, "ok", "data directory: " .. tmpdir), "storage is checked")
    truthy(reported(reports, "info", "no credentials.json yet"), "no credentials is information, not an error")
    truthy(reported(reports, "warn", "cookie wr_skey missing"), "and the missing cookies are warnings")
    local started = vim.tbl_filter(function(report)
      return report.kind == "start"
    end, reports)
    truthy(#started >= 6, "every section announced itself")
  end)
end)
