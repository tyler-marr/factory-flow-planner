-- Per-craft amounts and per-machine speed for a recipe, from prototype-shaped
-- tables. Pure Lua: in game it is fed LuaRecipePrototype fields, in tests it is
-- fed the raw data tables (which still use `probability`), so both spellings
-- of the product chance are read.

local recipe_math = {}

function recipe_math.key(kind, name) return kind .. "/" .. name end

function recipe_math.split(res)
  local kind, name = string.match(res, "^([^/]+)/(.+)$")
  return kind, name
end

local function product_chance(p)
  local chance = p.independent_probability or p.probability or 1
  local sp = p.shared_probability
  if sp and sp.min and sp.max then chance = chance * (sp.max - sp.min) end
  return chance
end

--- Expected amount of one product per craft, with productivity applied.
function recipe_math.product_amount(p, productivity)
  local base = p.amount
  if base == nil then base = ((p.amount_min or 0) + (p.amount_max or 0)) / 2 end
  local chance = product_chance(p)
  local ignored = math.min(p.ignored_by_productivity or 0, base)
  local extra = p.extra_count_fraction or 0
  return chance * (base + extra) + chance * (base - ignored) * (productivity or 0)
end

--- @param recipe table  { energy|energy_required, ingredients, products|results, maximum_productivity }
--- @param machine table { speed, power_w }   power_w = active draw of one machine in watts
--- @param bonus table   { productivity = number, speed = number, consumption = number } (all optional)
function recipe_math.spec(recipe, machine, bonus)
  bonus = bonus or {}
  local energy = recipe.energy or recipe.energy_required or 0.5
  if energy <= 0 then energy = 1 / 60 end
  local speed = (machine.speed or 1) * math.max(0.2, 1 + (bonus.speed or 0))
  local prod = bonus.productivity or 0
  if recipe.maximum_productivity then prod = math.min(prod, recipe.maximum_productivity) end
  if prod < 0 then prod = 0 end

  local inputs, outputs = {}, {}
  for _, ing in ipairs(recipe.ingredients or {}) do
    inputs[#inputs + 1] = { res = recipe_math.key(ing.type or "item", ing.name), amount = ing.amount or 0 }
  end
  for _, p in ipairs(recipe.products or recipe.results or {}) do
    outputs[#outputs + 1] = {
      res = recipe_math.key(p.type or "item", p.name),
      amount = recipe_math.product_amount(p, prod),
    }
  end
  return {
    inputs = inputs,
    outputs = outputs,
    cpm = speed / energy, -- crafts per second per machine
    power_w = (machine.power_w or 0) * math.max(0.2, 1 + (bonus.consumption or 0)),
  }
end

return recipe_math
