--[[
Colour arithmetic for the reading palettes: mixing two inks in a perceptual
space, and measuring how readable one is on another.
(阅读配色用的颜色运算：在感知均匀的空间里混合两种墨色，以及测量一种颜色在另一种上的可读性)

Mixing happens in Oklab (Björn Ottosson, public domain reference code): a step
of 10% towards the ink *looks* like 10%, where a straight sRGB mix makes yellows
and cyans jump. Contrast is measured twice, because the two standards disagree on
dark pages: WCAG 2 for the code inks (the floor the tests already hold), APCA for
body text, where WCAG overstates dark pairs.
(混合在 Oklab 里做（Björn Ottosson 的公有领域参考实现）：往墨色走 10% 看起来就是 10%，而直接在
 sRGB 里混，黄色和青色会突然跳亮。对比度测两种，因为两个标准在深色页面上意见不一：WCAG 2 用于
 代码墨色（测试一直守着的下限），APCA 用于正文——WCAG 会高估深色组合)
]]

local M = {}

---@param hex string "#rrggbb"
---@return number r, number g, number b channels in 0..1(0..1 的通道值)
function M.rgb(hex)
  local r, g, b = hex:match("^#(%x%x)(%x%x)(%x%x)$")
  if not r then
    error("weread.color: not a #rrggbb colour: " .. tostring(hex))
  end
  return tonumber(r, 16) / 255, tonumber(g, 16) / 255, tonumber(b, 16) / 255
end

---@param r number
---@param g number
---@param b number
---@return string "#rrggbb"
function M.hex(r, g, b)
  local function byte(c)
    return math.floor(math.max(0, math.min(1, c)) * 255 + 0.5)
  end
  return string.format("#%02x%02x%02x", byte(r), byte(g), byte(b))
end

---@param c number
---@return number
local function to_linear(c)
  return c <= 0.04045 and c / 12.92 or ((c + 0.055) / 1.055) ^ 2.4
end

---@param c number
---@return number
local function to_gamma(c)
  return c <= 0.0031308 and c * 12.92 or 1.055 * c ^ (1 / 2.4) - 0.055
end

---@param x number
---@return number
local function cbrt(x)
  return x < 0 and -((-x) ^ (1 / 3)) or x ^ (1 / 3)
end

---@param hex string
---@return number L, number a, number b
function M.oklab(hex)
  local r, g, b = M.rgb(hex)
  r, g, b = to_linear(r), to_linear(g), to_linear(b)
  local l = cbrt(0.4122214708 * r + 0.5363325363 * g + 0.0514459929 * b)
  local m = cbrt(0.2119034982 * r + 0.6806995451 * g + 0.1073969566 * b)
  local s = cbrt(0.0883024619 * r + 0.2817188376 * g + 0.6299787005 * b)
  return 0.2104542553 * l + 0.7936177850 * m - 0.0040720468 * s,
    1.9779984951 * l - 2.4285922050 * m + 0.4505937099 * s,
    0.0259040371 * l + 0.7827717662 * m - 0.8086757660 * s
end

---@param L number
---@param a number
---@param b number
---@return string
function M.from_oklab(L, a, b)
  local l = (L + 0.3963377774 * a + 0.2158037573 * b) ^ 3
  local m = (L - 0.1055613458 * a - 0.0638541728 * b) ^ 3
  local s = (L - 0.0894841775 * a - 1.2914855480 * b) ^ 3
  return M.hex(
    to_gamma(4.0767416621 * l - 3.3077115913 * m + 0.2309699292 * s),
    to_gamma(-1.2684380046 * l + 2.6097574011 * m - 0.3413193965 * s),
    to_gamma(-0.0041960863 * l - 0.7034186147 * m + 1.7076147010 * s)
  )
end

---A colour `t` of the way from `from` to `to`, mixed in Oklab.
---(从 from 走向 to 的 t 处的颜色，在 Oklab 里混合)
---@param from string
---@param to string
---@param t number 0..1
---@return string
function M.mix(from, to, t)
  local L1, a1, b1 = M.oklab(from)
  local L2, a2, b2 = M.oklab(to)
  return M.from_oklab(L1 + (L2 - L1) * t, a1 + (a2 - a1) * t, b1 + (b2 - b1) * t)
end

---Relative luminance, WCAG 2.
---(WCAG 2 的相对亮度)
---@param hex string
---@return number
function M.luminance(hex)
  local r, g, b = M.rgb(hex)
  return 0.2126 * to_linear(r) + 0.7152 * to_linear(g) + 0.0722 * to_linear(b)
end

---WCAG 2 contrast ratio, 1..21.
---(WCAG 2 对比度，1..21)
---@param a string
---@param b string
---@return number
function M.wcag(a, b)
  local x, y = M.luminance(a), M.luminance(b)
  return (math.max(x, y) + 0.05) / (math.min(x, y) + 0.05)
end

---APCA lightness contrast (APCA-W3 0.0.98G constants): positive for dark ink on
---a light page, negative for light ink on a dark one. Body text wants |Lc| >= 75.
---(APCA 亮度对比（APCA-W3 0.0.98G 常数）：浅底深字为正，深底浅字为负。正文要求 |Lc| >= 75)
---@param text string
---@param page string
---@return number
function M.apca(text, page)
  local function screen_y(hex)
    local r, g, b = M.rgb(hex)
    local y = 0.2126729 * r ^ 2.4 + 0.7151522 * g ^ 2.4 + 0.0721750 * b ^ 2.4
    -- soft clamp near black (黑位附近的软钳制)
    return y >= 0.022 and y or y + (0.022 - y) ^ 1.414
  end
  local t, p = screen_y(text), screen_y(page)
  if math.abs(p - t) < 0.0005 then
    return 0
  end
  if p > t then
    local s = (p ^ 0.56 - t ^ 0.57) * 1.14
    return s < 0.1 and 0 or (s - 0.027) * 100
  end
  local s = (p ^ 0.65 - t ^ 0.62) * 1.14
  return s > -0.1 and 0 or (s + 0.027) * 100
end

return M
