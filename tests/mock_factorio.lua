-- A small stand-in for the Factorio runtime API, enough to run control.lua.
-- Built from Wube's vanilla recipe data (RECIPES, loaded by run.py).
local M = {}
local next_obj = 0

defines = {
  direction = { north = 0, east = 4, south = 8, west = 12 },
  controllers = { ghost = 0, character = 1, god = 2, editor = 3, cutscene = 4, spectator = 5, remote = 6 },
  events = {},
}
for i, n in ipairs({ "on_gui_click", "on_gui_confirmed", "on_gui_elem_changed", "on_gui_selection_state_changed",
  "on_gui_closed", "on_lua_shortcut", "on_research_finished", "on_pre_player_left_game",
  "on_player_changed_surface", "on_player_removed", "on_player_selected_area", "on_player_alt_selected_area",
  "on_player_start_selected_area", "on_player_change_selected_area", "on_player_cancel_selected_area",
  "on_player_cursor_stack_changed", "on_chunk_generated", "on_tick", "on_selected_entity_changed",
  "on_player_display_resolution_changed", "on_player_display_scale_changed" }) do defines.events[n] = i end

local handlers = {}
script = {
  on_init = function(f) handlers.init = f end,
  on_configuration_changed = function(f) handlers.config = f end,
  on_event = function(id, f) handlers[id] = f end,
  on_nth_tick = function(n, f) handlers["nth" .. n] = f end,
}
M.handlers = handlers
storage = {}

-- Prototypes ----------------------------------------------------------------
local MACHINES = {
  ["assembling-machine-1"] = { cats = { "crafting", "advanced-crafting" }, speed = 0.5, kw = 75, slots = 0 },
  ["assembling-machine-2"] = { cats = { "crafting", "advanced-crafting", "crafting-with-fluid" }, speed = 0.75, kw = 150, slots = 2 },
  ["assembling-machine-3"] = { cats = { "crafting", "advanced-crafting", "crafting-with-fluid" }, speed = 1.25, kw = 375, slots = 4 },
  ["stone-furnace"] = { cats = { "smelting" }, speed = 1, kw = 90, slots = 0, nobeacon = true },
  ["steel-furnace"] = { cats = { "smelting" }, speed = 2, kw = 90, slots = 0, nobeacon = true },
  ["electric-furnace"] = { cats = { "smelting" }, speed = 2, kw = 180, slots = 2 },
  ["oil-refinery"] = { cats = { "oil-processing" }, speed = 1, kw = 420, slots = 3 },
  ["chemical-plant"] = { cats = { "chemistry" }, speed = 1, kw = 210, slots = 3 },
  ["character"] = { cats = { "crafting", "hand-crafting" }, speed = 1, kw = 0, type = "character" },
}
local entity = {}
for name, m in pairs(MACHINES) do
  local cc = {}
  for _, c in ipairs(m.cats) do cc[c] = true end
  entity[name] = {
    name = name, type = m.type or "assembling-machine", hidden = false, crafting_categories = cc,
    get_crafting_speed = function() return m.speed end, energy_usage = m.kw * 1000 / 60,
    localised_name = { "entity-name." .. name },
    items_to_place_this = m.type and nil or { { name = name, count = 1 } },
    module_inventory_size = m.slots or 0,
    effect_receiver = { base_effect = {}, uses_beacon_effects = not m.nobeacon },
  }
end
for i, b in ipairs({ { "transport-belt", "underground-belt", 0.03125, 5 }, { "fast-transport-belt", "fast-underground-belt", 0.0625, 7 },
  { "express-transport-belt", "express-underground-belt", 0.09375, 9 } }) do
  entity[b[2]] = { name = b[2], type = "underground-belt", hidden = false, max_underground_distance = b[4] }
  entity[b[1]] = { name = b[1], type = "transport-belt", hidden = false, belt_speed = b[3], related_underground_belt = entity[b[2]] }
end
for _, b in ipairs({ { "splitter", 0.03125 }, { "fast-splitter", 0.0625 }, { "express-splitter", 0.09375 } }) do
  entity[b[1]] = { name = b[1], type = "splitter", hidden = false, belt_speed = b[2] }
  entity["ffp-planner-" .. b[1]] = { name = "ffp-planner-" .. b[1], type = "splitter", hidden = true, belt_speed = b[2] }
end
entity["pipe"] = { name = "pipe", type = "pipe", hidden = false }
entity["pipe-to-ground"] = { name = "pipe-to-ground", type = "pipe-to-ground", hidden = false,
  fluidbox_prototypes = { { pipe_connections = { { connection_type = "normal" }, { connection_type = "underground", max_underground_distance = 10 } } } } }
entity["beacon"] = { name = "beacon", type = "beacon", hidden = false, module_inventory_size = 2,
  distribution_effectivity = 1.5, profile = { 1, 0.7071, 0.5773, 0.5, 0.4472, 0.4082, 0.3779, 0.3535 },
  allowed_effects = { speed = true, consumption = true, pollution = true }, localised_name = { "entity-name.beacon" } }
local recipe, item, fluid = {}, {}, {}
local function res_proto(kind, name)
  local t = kind == "fluid" and fluid or item
  t[name] = t[name] or { name = name, localised_name = { kind .. "-name." .. name } }
end
for name, r in pairs(RECIPES) do
  local ings, prods = {}, {}
  for _, i in ipairs(r.ingredients or {}) do
    ings[#ings + 1] = { type = i.type or "item", name = i.name or i[1], amount = i.amount or i[2] }
    res_proto(i.type or "item", i.name or i[1])
  end
  for _, p in ipairs(r.results or {}) do
    prods[#prods + 1] = { type = p.type or "item", name = p.name, amount = p.amount, amount_min = p.amount_min,
      amount_max = p.amount_max, independent_probability = p.probability or 1, shared_probability = { min = 0, max = 1 } }
    res_proto(p.type or "item", p.name)
  end
  recipe[name] = {
    name = name, energy = r.energy_required or 0.5, ingredients = ings, products = prods,
    categories = r.categories or { r.category or "crafting" }, hidden = r.hidden or false,
    parameter = r.parameter or false, localised_name = { "recipe-name." .. name }, maximum_productivity = 3,
  }
end
local MODULES = {
  ["speed-module"] = { category = "speed", tier = 1, eff = { speed = 0.2, consumption = 0.5, quality = -0.1 } },
  ["speed-module-3"] = { category = "speed", tier = 3, eff = { speed = 0.5, consumption = 0.7, quality = -0.25 } },
  ["productivity-module-3"] = { category = "productivity", tier = 3, eff = { productivity = 0.1, speed = -0.15, consumption = 0.8, pollution = 0.1 } },
  ["efficiency-module"] = { category = "efficiency", tier = 1, eff = { consumption = -0.3 } },
}
for name, m in pairs(MODULES) do
  item[name] = { name = name, type = "module", hidden = false, category = m.category, tier = m.tier,
    module_effects = m.eff, localised_name = { "item-name." .. name } }
end
-- Vanilla: productivity only on intermediates.
local INTERMEDIATE = { ["electronic-circuit"] = true, ["copper-cable"] = true, ["iron-gear-wheel"] = true,
  ["advanced-circuit"] = true, ["iron-plate"] = true, ["copper-plate"] = true, ["plastic-bar"] = true }
for name, r in pairs(recipe) do
  r.allowed_effects = { speed = true, consumption = true, pollution = true, quality = true, productivity = INTERMEDIATE[name] or false }
end
prototypes = {
  recipe = recipe, entity = entity, item = item, fluid = fluid,
  get_entity_filtered = function(filters)
    local out = {}
    for name, e in pairs(entity) do
      for _, f in ipairs(filters) do
        if f.filter == "crafting-category" and e.crafting_categories and e.crafting_categories[f.crafting_category] then out[name] = e end
        if f.filter == "type" and e.type == f.type then out[name] = e end
      end
    end
    return out
  end,
  get_item_filtered = function(filters)
    local out = {}
    for name, it in pairs(item) do
      for _, f in ipairs(filters) do
        if f.filter == "type" and it.type == f.type then out[name] = it end
      end
    end
    return out
  end,
}

-- Helpers and rendering -----------------------------------------------------
helpers = {
  table_to_json = py_to_json, json_to_table = py_from_json, encode_string = py_encode, decode_string = py_decode,
  is_valid_sprite_path = function(p) return type(p) == "string" and p:find("/") ~= nil end,
}
local objects = {}
M.objects = objects
local function make(kind, t)
  next_obj = next_obj + 1
  assert(t.surface, kind .. " needs surface")
  if kind == "text" then assert(t.text ~= nil and t.target and t.color, "text fields") end
  if kind == "sprite" then assert(type(t.sprite) == "string" and t.target, "sprite fields") end
  if kind == "line" then assert(t.from and t.to and t.width and t.color, "line fields") end
  if kind == "rectangle" then assert(t.left_top and t.right_bottom and t.color, "rect fields") end
  if kind == "circle" then assert(t.radius and t.target and t.color, "circle fields") end
  local obj = { id = next_obj, valid = true, kind = kind, args = t }
  obj.destroy = function() obj.valid = false; objects[obj.id] = nil end
  objects[obj.id] = obj
  return obj
end
rendering = {
  draw_text = function(t) return make("text", t) end,
  draw_sprite = function(t) return make("sprite", t) end,
  draw_line = function(t) return make("line", t) end,
  draw_rectangle = function(t) return make("rectangle", t) end,
  draw_circle = function(t) return make("circle", t) end,
  get_object_by_id = function(id) return objects[id] end,
}
function M.count_objects()
  local n = 0
  for _ in pairs(objects) do n = n + 1 end
  return n
end

-- GUI -----------------------------------------------------------------------
local Gui = {}
local function new_el(spec, parent)
  local el = { children = {}, parent = parent, valid = true,
    style = setmetatable({ column_alignments = {} }, { __index = function() return 0 end }) }
  for k, v in pairs(spec) do if k ~= "style" then el[k] = v end end
  el.style.name = spec.style
  el.tags = spec.tags or {}
  if el.type == "drop-down" then el.selected_index = spec.selected_index or 0 end
  setmetatable(el, Gui)
  -- Factorio binds methods, so they are called with a dot: frame.add{...}
  for _, m in ipairs({ "add", "destroy", "clear", "force_auto_center", "focus", "select_all" }) do
    local f = Gui[m]
    rawset(el, m, function(...) return f(el, ...) end)
  end
  return el
end
Gui.__index = function(el, key)
  local m = rawget(Gui, key)
  if m then return m end
  for _, c in ipairs(rawget(el, "children")) do
    if c.name == key then return c end
  end
  return nil
end
local KNOWN = { frame = 1, flow = 1, label = 1, button = 1, ["sprite-button"] = 1, sprite = 1, table = 1,
  ["scroll-pane"] = 1, textfield = 1, ["text-box"] = 1, ["drop-down"] = 1, ["choose-elem-button"] = 1, ["empty-widget"] = 1 }
function Gui.add(el, spec)
  assert(KNOWN[spec.type], "unknown gui type " .. tostring(spec.type))
  if spec.name then
    for _, c in ipairs(el.children) do assert(c.name ~= spec.name, "duplicate gui name " .. spec.name) end
  end
  local c = new_el(spec, el)
  table.insert(el.children, c)
  return c
end
function Gui.destroy(el)
  el.valid = false
  local p = el.parent
  if p then
    for i, c in ipairs(p.children) do if c == el then table.remove(p.children, i) break end end
  end
end
function Gui.clear(el) for i = #el.children, 1, -1 do el.children[i].destroy() end end
function Gui.force_auto_center() end
function Gui.focus() end
function Gui.select_all() end
function M.find(el, pred)
  if pred(el) then return el end
  for _, c in ipairs(el.children or {}) do
    local f = M.find(c, pred)
    if f then return f end
  end
end

-- Hotspot entities the data stage defines.
do
  local layout = dofile(MOD_ROOT .. "/scripts/layout.lua")
  prototypes_entity_names = {}
  for _, h in pairs(layout.HOTSPOTS) do prototypes_entity_names[h.name] = true end
  for _, n in ipairs({ "transport-belt", "fast-transport-belt", "express-transport-belt", "underground-belt",
    "fast-underground-belt", "express-underground-belt", "pipe", "pipe-to-ground",
    "ffp-planner-splitter", "ffp-planner-fast-splitter", "ffp-planner-express-splitter" }) do prototypes_entity_names[n] = true end
end

-- Game ----------------------------------------------------------------------
local surfaces = {}
local function surface(name, index)
  local s = { name = name, index = index, valid = true, tiles_set = 0, entities = {}, chunks = {} }
  s.is_chunk_generated = function(cp) return s.chunks[cp[1] .. "," .. cp[2]] == true end
  s.request_to_generate_chunks = function(pos, r)
    local cx, cy = math.floor(pos.x / 32), math.floor(pos.y / 32)
    for dx = -r, r do for dy = -r, r do s.chunks[(cx + dx) .. "," .. (cy + dy)] = true end end
  end
  s.force_generate_chunk_requests = function() end
  s.create_entity = function(t)
    assert(t.name and t.position and t.force, "create_entity fields")
    assert(prototypes_entity_names == nil or prototypes_entity_names[t.name], "unknown entity " .. t.name)
    if t.name:find("underground%-belt") then assert(t.type == "input" or t.type == "output", "underground needs type") end
    if t.name:find("belt") or t.name:find("splitter") or t.name == "pipe-to-ground" then assert(t.direction ~= nil, "direction needed for " .. t.name) end
    local e = { name = t.name, position = t.position, valid = true, surface = s, direction = t.direction, type = t.type }
    e.destroy = function() e.valid = false; s.entities[e] = nil end
    e.items = {}
    e.lines = e.lines or {}
    e.fed, e.cleared = 0, 0
    e.get_transport_line = function(i)
      assert(not t.name:find("pipe"), "pipes have no transport lines")
      assert(i == 1 or i == 2, "lane index")
      return { line_length = 1,
        insert_at = function(x, it) assert(x >= 0 and x < 1 and it.name, "insert_at position"); table.insert(e.items, it.name); return true end,
        insert_at_back = function(it) assert(it.name); e.fed = e.fed + 1; return true end,
        clear = function() e.cleared = e.cleared + 1 end }
    end
    e.insert_fluid = function(f) assert(f.name and f.amount); e.fluid = f.name; return f.amount end
    s.entities[e] = true
    return e
  end
  s.set_tiles = function(tiles) for _, t in ipairs(tiles) do assert(t.name and t.position) end; s.tiles_set = s.tiles_set + #tiles end
  s.get_chunks = function()
    local list = { { area = { left_top = { x = 0, y = 0 }, right_bottom = { x = 32, y = 32 } } } }
    local i = 0
    return function() i = i + 1; return list[i] end
  end
  surfaces[name] = s
  surfaces[index] = s
  return s
end
surface("nauvis", 1)

local force_recipes = setmetatable({}, { __index = function(t, k)
  if recipe[k] or entity[k] then
    local r = { name = k, enabled = (k ~= "assembling-machine-3"), productivity_bonus = 0 }
    rawset(t, k, r)
    return r
  end
end })
local force = { index = 1, name = "player", recipes = force_recipes, set_surface_hidden = function() end }

local players = {}
local function player(index, name)
  local p = {
    index = index, name = name, force = force, valid = true,
    surface = surfaces.nauvis, position = { x = 10 * index, y = 5 },
    controller_type = defines.controllers.character,
    display_resolution = { width = 1920, height = 1080 }, display_scale = 1,
    printed = {},
  }
  p.character = { valid = true, destructible = true, surface = surfaces.nauvis, position = { x = 10 * index, y = 5 } }
  p.gui = { screen = new_el({ type = "frame", name = "screen" }), top = new_el({ type = "flow", name = "top" }),
    left = new_el({ type = "flow", name = "left" }) }
  p.print = function(msg) table.insert(p.printed, msg) end
  local view = { show_quickbar = true, show_minimap = true, show_research_info = true, show_alert_gui = true,
    show_hotkey_suggestions = true, show_crafting_queue = true, show_pins_gui = true, show_surface_list = true,
    show_shortcut_bar = true, show_tool_bar = true }
  setmetatable(p, { __index = function(_, k)
    if k == "game_view_settings" then local c = {}; for a, b in pairs(view) do c[a] = b end; return c end
  end, __newindex = function(t, k, v)
    if k == "game_view_settings" then for a, b in pairs(v) do view[a] = b end else rawset(t, k, v) end
  end })
  p.view = view
  p.zoom = 1
  p.set_zoom_limits = function(ctrl, limits)
    assert(ctrl == defines.controllers.god)
    p.zoom_limits = limits
  end
  local stack = { valid_for_read = false }
  local function changed() handlers[defines.events.on_player_cursor_stack_changed]({ player_index = p.index }) end
  stack.set_stack = function(t) stack.valid_for_read = true; stack.name = t.name; changed(); return true end
  stack.clear = function() stack.valid_for_read = false; stack.name = nil; changed() end
  p.cursor_stack = stack
  p.create_local_flying_text = function(t) p.flying = t.text end
  p.exit_remote_view = function() p.controller_type = defines.controllers.character end
  p.set_controller = function(t)
    p.controller_type = t.type
    if t.type == defines.controllers.character then
      assert(t.character and t.character.valid, "character needed")
      local old = p.surface
      p.surface, p.position = t.character.surface, t.character.position
      if old ~= p.surface then handlers[defines.events.on_player_changed_surface]({ player_index = p.index }) end
    end
  end
  p.teleport = function(pos, surf)
    local old = p.surface
    p.position = { x = pos.x or pos[1], y = pos.y or pos[2] }
    if surf then p.surface = type(surf) == "table" and surf or surfaces[surf] end
    if old ~= p.surface then handlers[defines.events.on_player_changed_surface]({ player_index = p.index }) end
    return true
  end
  players[index] = p
  return p
end
player(1, "whit")
player(2, "friend")

game = {
  tick = 100,
  players = players,
  forces = { player = force, [1] = force },
  surfaces = surfaces,
  get_player = function(i) return players[i] end,
  get_surface = function(n) return surfaces[n] end,
  create_surface = function(name, settings)
    assert(settings == nil or type(settings) == "table")
    return surface(name, 2)
  end,
}


-- Everything the overview panel says, as one string.
function overview_text(p)
  local parts = {}
  local function walk(x)
    if type(x) == "table" then for _, v in ipairs(x) do walk(v) end else parts[#parts + 1] = tostring(x) end
  end
  local function visit(el)
    if el.caption then walk(el.caption); parts[#parts + 1] = " " end
    for _, c in ipairs(el.children or {}) do visit(c) end
  end
  local f = p.gui.screen.ffp_overview
  if f then visit(f) end
  return table.concat(parts)
end

M.players = players
M.force = force
return M
