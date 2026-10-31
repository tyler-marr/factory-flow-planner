-- Number formatting for cards and windows. Rates are stored per second and
-- shown per minute, like the game's production statistics.

local fmt = {}

local function num(v)
  local a = math.abs(v)
  if a >= 1e6 then return string.format("%.2fM", v / 1e6) end
  if a >= 1e4 then return string.format("%.1fk", v / 1e3) end
  if a >= 100 then return string.format("%.0f", v) end
  if a >= 10 then return (string.gsub(string.format("%.1f", v), "%.0$", "")) end
  if a >= 0.01 or a == 0 then return (string.gsub(string.gsub(string.format("%.2f", v), "0+$", ""), "%.$", "")) end
  return string.format("%.3f", v)
end
fmt.num = num

-- Display units. A plan picks one (everyone on it sees the same board):
-- "s", "min", "h", or "belt:<belt name>" for fractions of that belt.
-- Set before drawing or building windows with fmt.use(plan.units, kit).
local TIME = { s = { 1, "/s", "second" }, min = { 60, "/min", "minute" }, h = { 3600, "/h", "hour" } }
local current = { key = "min", factor = 60, suffix = "/min" }

function fmt.use(units, kit)
  units = units or "min"
  local t = TIME[units]
  if t then
    current = { key = units, factor = t[1], suffix = t[2], word = t[3] }
    return
  end
  local name = type(units) == "string" and string.match(units, "^belt:(.+)$")
  if name and kit then
    for _, b in ipairs(kit.belts or {}) do
      if b.name == name then
        current = { key = units, belt = b.name, belt_rate = b.items_per_s, factor = 60, suffix = "/min", word = "minute" }
        return
      end
    end
  end
  current = { key = "min", factor = 60, suffix = "/min", word = "minute" }
end

--- The time unit typed numbers and wheel steps use: seconds per unit, and its name.
function fmt.step_unit() return current.factor, current.word or "minute", current.suffix end

--- A rate for display. Belts show items as a fraction of the chosen belt;
--- fluids (and anything when res is unknown in belt mode) show per minute.
function fmt.rate(per_s, res)
  per_s = per_s or 0
  if current.belt and not (res and string.sub(res, 1, 6) == "fluid/") and res ~= nil then
    return num(per_s / current.belt_rate) .. " [entity=" .. current.belt .. "]"
  end
  return num(per_s * current.factor) .. current.suffix
end

--- The unit choices for a dropdown: keys and their labels.
function fmt.unit_options(kit)
  local keys = { "s", "min", "h" }
  local labels = { "Items per second", "Items per minute", "Items per hour" }
  for _, b in ipairs(kit and kit.belts or {}) do
    keys[#keys + 1] = "belt:" .. b.name
    labels[#labels + 1] = { "", "Fraction of a [entity=" .. b.name .. "] ", { "entity-name." .. b.name } }
  end
  return keys, labels
end

function fmt.count(n) return num(n or 0) end

function fmt.power(w)
  w = w or 0
  if w >= 1e9 then return string.format("%.2f GW", w / 1e9) end
  if w >= 1e6 then return string.format("%.2f MW", w / 1e6) end
  if w >= 1e3 then return string.format("%.0f kW", w / 1e3) end
  return string.format("%.0f W", w)
end

--- Parses what a player typed; nil when it is not a usable non-negative number.
function fmt.parse(str)
  if type(str) ~= "string" then return nil end
  local v = tonumber((string.gsub(str, ",", ".")))
  if not v or v ~= v or v < 0 or v == math.huge then return nil end
  return v
end

return fmt
