-- Everything the planner knows about recipes and machines, read live from the
-- game's prototypes. Because this runs after every mod's data stage, modded
-- recipes, machines, items and fluids (and their icons) appear with no export.

local recipe_math = require("scripts.recipe_math")

local catalog = {}

local CRAFTING_TYPES = { ["assembling-machine"] = true, ["furnace"] = true, ["rocket-silo"] = true }

-- Derived caches. They are rebuilt from prototypes on every client the same
-- way, never written to `storage`, and only speed up lookups.
local producers_index -- res -> { recipe names }
local machines_cache = {} -- recipe name -> { {name, speed} } sorted by speed

local function recipe_categories(proto)
  if proto.categories then return proto.categories end
  if proto.category then return { proto.category } end
  return {}
end

function catalog.recipe(name)
  local proto = prototypes.recipe[name]
  if proto and not proto.parameter then return proto end
end

function catalog.recipe_exists(name)
  return catalog.recipe(name) ~= nil
end

local function machine_speed(proto)
  local ok, v = pcall(function() return proto.get_crafting_speed() end)
  if ok and v then return v end
  return proto.crafting_speed or 1
end

--- Crafting machines able to make this recipe, slowest first.
function catalog.machines_for(recipe_name)
  local cached = machines_cache[recipe_name]
  if cached then return cached end
  local proto = catalog.recipe(recipe_name)
  local found, list = {}, {}
  if proto then
    for _, cat in pairs(recipe_categories(proto)) do
      local ents = prototypes.get_entity_filtered({ { filter = "crafting-category", crafting_category = cat } })
      for name, ent in pairs(ents) do
        if not found[name] and CRAFTING_TYPES[ent.type] and not ent.hidden then
          found[name] = true
          list[#list + 1] = { name = name, speed = machine_speed(ent) }
        end
      end
    end
  end
  table.sort(list, function(a, b)
    if a.speed ~= b.speed then return a.speed < b.speed end
    return a.name < b.name
  end)
  machines_cache[recipe_name] = list
  return list
end

local function machine_unlocked(force, entity_name)
  local ent = prototypes.entity[entity_name]
  local items = ent and ent.items_to_place_this
  if not items or not items[1] then return true end
  local item_name = items[1].name
  local r = force.recipes[item_name]
  if r then return r.enabled end
  return true
end

--- The fastest machine this force can already build, else the slowest one.
function catalog.default_machine(recipe_name, force)
  local list = catalog.machines_for(recipe_name)
  for i = #list, 1, -1 do
    if machine_unlocked(force, list[i].name) then return list[i].name end
  end
  return list[1] and list[1].name or nil
end

-- ---------------------------------------------------------------------------
-- Modules and beacons

-- A module fits where every effect it is FOR (speed up, productivity up,
-- quality up, consumption down, pollution down) is allowed, and its category is.
local BENEFIT = { speed = 1, productivity = 1, quality = 1, consumption = -1, pollution = -1 }

local function module_fits(module, allowed_effects, allowed_categories)
  if allowed_categories and module.category and not allowed_categories[module.category] then return false end
  local eff = module.module_effects or {}
  for k, sign in pairs(BENEFIT) do
    local v = eff[k] or 0
    if v * sign > 0 and allowed_effects and not allowed_effects[k] then return false end
  end
  return true
end

local modules_cache
local function all_modules()
  if not modules_cache then
    modules_cache = {}
    for name, item in pairs(prototypes.get_item_filtered({ { filter = "type", type = "module" } })) do
      if not item.hidden then modules_cache[#modules_cache + 1] = item end
    end
    table.sort(modules_cache, function(a, b)
      if (a.category or "") ~= (b.category or "") then return (a.category or "") < (b.category or "") end
      if (a.tier or 0) ~= (b.tier or 0) then return (a.tier or 0) < (b.tier or 0) end
      return a.name < b.name
    end)
  end
  return modules_cache
end

--- Modules that fit this recipe in this machine, in order (category, then tier).
function catalog.module_options(recipe_name, machine_name)
  local recipe = catalog.recipe(recipe_name)
  local ent = prototypes.entity[machine_name]
  if not (recipe and ent) or (ent.module_inventory_size or 0) == 0 then return {} end
  local list = {}
  for _, m in ipairs(all_modules()) do
    if module_fits(m, ent.allowed_effects, ent.allowed_module_categories)
      and module_fits(m, recipe.allowed_effects, recipe.allowed_module_categories) then
      list[#list + 1] = m.name
    end
  end
  return list
end

--- The beacon the planner assumes: vanilla's if present, else the first one found.
function catalog.beacon()
  local best
  for name, ent in pairs(prototypes.get_entity_filtered({ { filter = "type", type = "beacon" } })) do
    if not ent.hidden and (ent.module_inventory_size or 0) > 0 then
      if name == "beacon" then return ent end
      if not best or name < best.name then best = ent end
    end
  end
  return best
end

function catalog.beacon_module_options(recipe_name)
  local b = catalog.beacon()
  local recipe = catalog.recipe(recipe_name)
  if not b then return {} end
  local list = {}
  for _, m in ipairs(all_modules()) do
    if module_fits(m, b.allowed_effects, b.allowed_module_categories)
      and (not recipe or module_fits(m, recipe.allowed_effects, recipe.allowed_module_categories)) then
      list[#list + 1] = m.name
    end
  end
  return list
end

--- The beacon module a new beacon chip starts with: the strongest speed module.
function catalog.default_beacon_module(recipe_name)
  local best, speed = nil, 0
  for _, name in ipairs(catalog.beacon_module_options(recipe_name)) do
    local eff = prototypes.item[name].module_effects or {}
    if (eff.speed or 0) > speed then best, speed = name, eff.speed end
  end
  return best
end

function catalog.uses_beacons(machine_name)
  local ent = prototypes.entity[machine_name]
  if not ent then return false end
  local er = ent.effect_receiver
  if er and er.uses_beacon_effects == false then return false end
  return catalog.beacon() ~= nil
end

--- Sum of module and beacon effects for a card on a machine.
local function card_effects(card, ent)
  local total = { speed = 0, productivity = 0, consumption = 0 }
  local function add(eff, times)
    for k in pairs(total) do total[k] = total[k] + (eff[k] or 0) * times end
  end
  local slots = ent.module_inventory_size or 0
  local mod = card.modules and prototypes.item[card.modules]
  if mod and slots > 0 then add(mod.module_effects or {}, slots) end
  local b = card.beacons
  if b and (b.count or 0) > 0 and catalog.uses_beacons(ent.name) then
    local beacon = catalog.beacon()
    local bmod = b.module and prototypes.item[b.module]
    if beacon and bmod then
      local n = b.count
      local profile = beacon.profile
      local p = 1
      if profile and #profile > 0 then p = profile[math.min(n, #profile)] end
      local per_beacon = (beacon.distribution_effectivity or 0.5) * p * (beacon.module_inventory_size or 0)
      add(bmod.module_effects or {}, n * per_beacon)
    end
  end
  return total
end

local function machine_numbers(entity_name)
  local ent = prototypes.entity[entity_name]
  if not ent then return nil end
  local base_prod = 0
  local er = ent.effect_receiver
  if er and er.base_effect and er.base_effect.productivity then base_prod = er.base_effect.productivity end
  return { speed = machine_speed(ent), power_w = (ent.energy_usage or 0) * 60 }, base_prod, ent
end

--- Per-craft numbers for a card, including modules, beacons and research productivity.
--- Panels get their ports only.
--- @return table|nil spec
function catalog.spec(card, force)
  if card.kind == "source" or card.kind == "sink" then
    local ports = {}
    for _, it in ipairs(card.items or {}) do ports[#ports + 1] = { res = it.res } end
    return {
      panel = true,
      inputs = card.kind == "sink" and ports or {},
      outputs = card.kind == "source" and ports or {},
    }
  end
  local proto = catalog.recipe(card.recipe)
  if not proto then return nil end
  local machine = card.machine
  if not machine or not prototypes.entity[machine] then
    machine = catalog.default_machine(card.recipe, force)
  end
  if not machine then return nil end
  local numbers, base_prod, ent = machine_numbers(machine)
  if not numbers then return nil end
  local eff = card_effects(card, ent)
  local prod = base_prod + eff.productivity
  local fr = force and force.recipes[card.recipe]
  if fr then prod = prod + (fr.productivity_bonus or 0) end
  local spec = recipe_math.spec({
    energy = proto.energy,
    ingredients = proto.ingredients,
    products = proto.products,
    maximum_productivity = proto.maximum_productivity,
  }, numbers, { productivity = prod, speed = eff.speed, consumption = eff.consumption })
  spec.machine = machine
  spec.productivity = prod
  spec.speed_bonus = eff.speed
  spec.module_slots = ent.module_inventory_size or 0
  spec.beacons_ok = catalog.uses_beacons(machine)
  spec.chips = spec.module_slots > 0 or spec.beacons_ok
  return spec
end

--- Recipes that produce a resource ("item/x" or "fluid/x"), unlocked ones first.
function catalog.producers(res, force)
  if not producers_index then
    producers_index = {}
    for name, proto in pairs(prototypes.recipe) do
      if not proto.parameter and not proto.hidden then
        for _, p in pairs(proto.products) do
          local key = recipe_math.key(p.type, p.name)
          producers_index[key] = producers_index[key] or {}
          table.insert(producers_index[key], name)
        end
      end
    end
  end
  local list = {}
  for _, name in ipairs(producers_index[res] or {}) do
    local fr = force.recipes[name]
    list[#list + 1] = { name = name, enabled = fr and fr.enabled or false }
  end
  table.sort(list, function(a, b)
    if a.enabled ~= b.enabled then return a.enabled end
    return a.name < b.name
  end)
  return list
end

local consumers_index -- res -> { recipe names }

--- Recipes that use a resource, unlocked ones first.
function catalog.consumers(res, force)
  if not consumers_index then
    consumers_index = {}
    for name, proto in pairs(prototypes.recipe) do
      if not proto.parameter and not proto.hidden then
        for _, i in pairs(proto.ingredients) do
          local key = recipe_math.key(i.type, i.name)
          consumers_index[key] = consumers_index[key] or {}
          table.insert(consumers_index[key], name)
        end
      end
    end
  end
  local list = {}
  for _, name in ipairs(consumers_index[res] or {}) do
    local fr = force.recipes[name]
    list[#list + 1] = { name = name, enabled = fr and fr.enabled or false }
  end
  table.sort(list, function(a, b)
    if a.enabled ~= b.enabled then return a.enabled end
    return a.name < b.name
  end)
  return list
end

local kit_cache

--- Belts (with their undergrounds) and pipes the game has, for drawing links.
function catalog.transport_kit()
  if kit_cache then return kit_cache end
  local kit = { belts = {} }
  for name, e in pairs(prototypes.get_entity_filtered({ { filter = "type", type = "transport-belt" } })) do
    local under = e.related_underground_belt
    if not e.hidden and e.belt_speed and under then
      kit.belts[#kit.belts + 1] = {
        name = name, underground = under.name, items_per_s = e.belt_speed * 480,
        reach = under.max_underground_distance or 5,
      }
    end
  end
  table.sort(kit.belts, function(a, b)
    if a.items_per_s ~= b.items_per_s then return a.items_per_s < b.items_per_s end
    return a.name < b.name
  end)
  -- Each belt's splitter: the splitter running at the same speed.
  local splitters = prototypes.get_entity_filtered({ { filter = "type", type = "splitter" } })
  for _, b in ipairs(kit.belts) do
    local best
    for name, sp in pairs(splitters) do
      if not sp.hidden and string.sub(name, 1, 4) ~= "ffp-" and sp.belt_speed and math.abs(sp.belt_speed * 480 - b.items_per_s) < 1e-6 then
        if not best or name < best then best = name end
      end
    end
    -- The planner's own copy (see data-final-fixes.lua) if it exists.
    if best and prototypes.entity["ffp-planner-" .. best] then best = "ffp-planner-" .. best end
    b.splitter = best
  end
  local function first(kind, preferred)
    if prototypes.entity[preferred] then return prototypes.entity[preferred] end
    local best
    for name, e in pairs(prototypes.get_entity_filtered({ { filter = "type", type = kind } })) do
      if not e.hidden and (not best or name < best.name) then best = e end
    end
    return best
  end
  local pipe, ptg = first("pipe", "pipe"), first("pipe-to-ground", "pipe-to-ground")
  if pipe and ptg then
    local reach = 10
    for _, fb in pairs(ptg.fluidbox_prototypes or {}) do
      for _, c in pairs(fb.pipe_connections or {}) do
        if c.connection_type == "underground" and c.max_underground_distance then reach = c.max_underground_distance end
      end
    end
    kit.pipe = { name = pipe.name, underground = ptg.name, reach = reach }
  end
  kit_cache = kit
  return kit
end

function catalog.res_proto(res)
  local kind, name = recipe_math.split(res)
  if kind == "fluid" then return prototypes.fluid[name] end
  return prototypes.item[name]
end

function catalog.res_name(res)
  local p = catalog.res_proto(res)
  if p then return p.localised_name end
  return res
end

function catalog.sprite(res)
  if helpers.is_valid_sprite_path(res) then return res end
  return "utility/questionmark"
end

return catalog
