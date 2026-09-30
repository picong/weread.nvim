--[[
Minimal zero-dependency test framework for weread.nvim.
(零依赖极简测试框架)

Usage: see tests/run.lua. Specs use the globals `describe`, `it`, `eq`,
`truthy`, `falsy`, `matches`.
]]

local M = {
  passed = 0,
  failed = 0,
  failures = {},
  stack = {},
}

local out = io.stdout

local function emit(line)
  out:write(line, "\n")
end

-- Render a value for failure messages(把值渲染成可读文本，用于失败信息)
local function fmt(value, seen, depth)
  local kind = type(value)
  if kind == "string" then
    return string.format("%q", value)
  end
  if kind ~= "table" then
    return tostring(value)
  end
  seen = seen or {}
  depth = depth or 0
  if seen[value] then
    return "<cycle>"
  end
  if depth > 5 then
    return "{...}"
  end
  seen[value] = true

  local parts = {}
  local count = 0
  for key, item in pairs(value) do
    count = count + 1
    if count > 20 then
      parts[#parts + 1] = "..."
      break
    end
    parts[#parts + 1] = "[" .. fmt(key, seen, depth + 1) .. "]=" .. fmt(item, seen, depth + 1)
  end
  seen[value] = nil
  return "{" .. table.concat(parts, ", ") .. "}"
end

local function deep_equal(left, right, seen)
  if type(left) ~= type(right) then
    return false
  end
  if type(left) ~= "table" then
    return left == right
  end
  seen = seen or {}
  if seen[left] and seen[left] == right then
    return true
  end
  seen[left] = right
  for key, value in pairs(left) do
    if not deep_equal(value, right[key], seen) then
      return false
    end
  end
  for key in pairs(right) do
    if left[key] == nil then
      return false
    end
  end
  return true
end

local function label(message)
  return message and (message .. ": ") or ""
end

function M.describe(name, body)
  table.insert(M.stack, name)
  local ok, err = pcall(body)
  if not ok then
    M.failed = M.failed + 1
    table.insert(M.failures, {
      name = table.concat(M.stack, " > "),
      message = "describe body raised: " .. tostring(err),
    })
    emit("  ! " .. table.concat(M.stack, " > ") .. " raised " .. tostring(err))
  end
  table.remove(M.stack)
end

function M.it(name, body)
  local full = #M.stack > 0 and (table.concat(M.stack, " > ") .. " > " .. name) or name
  local ok, err = pcall(body)
  if ok then
    M.passed = M.passed + 1
    emit("  ok   " .. full)
  else
    M.failed = M.failed + 1
    table.insert(M.failures, { name = full, message = tostring(err) })
    emit("  FAIL " .. full)
    emit("       " .. tostring(err):gsub("\n", "\n       "))
  end
end

function M.eq(actual, expected, message)
  if not deep_equal(actual, expected) then
    error(label(message) .. "expected " .. fmt(expected) .. ", got " .. fmt(actual), 2)
  end
end

function M.truthy(value, message)
  if not value then
    error(label(message) .. "expected a truthy value, got " .. fmt(value), 2)
  end
end

function M.falsy(value, message)
  if value then
    error(label(message) .. "expected a falsy value, got " .. fmt(value), 2)
  end
end

function M.matches(value, pattern, message)
  if type(value) ~= "string" or not value:match(pattern) then
    error(label(message) .. "expected " .. fmt(value) .. " to match " .. fmt(pattern), 2)
  end
end

function M.raises(body, pattern, message)
  local ok, err = pcall(body)
  if ok then
    error(label(message) .. "expected an error, but the call succeeded", 2)
  end
  if pattern and not tostring(err):match(pattern) then
    error(label(message) .. "expected error matching " .. fmt(pattern) .. ", got " .. fmt(err), 2)
  end
end

function M.finish()
  emit("")
  if M.failed == 0 then
    emit(string.format("PASS %d assertion groups", M.passed))
    return true
  end
  emit(string.format("FAIL %d failed, %d passed", M.failed, M.passed))
  for _, failure in ipairs(M.failures) do
    emit("  - " .. failure.name .. ": " .. failure.message)
  end
  return false
end

return M
