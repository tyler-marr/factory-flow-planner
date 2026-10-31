-- The plan data model and its exchange string. Pure Lua.
-- A plan is plain data (arrays, strings, numbers) so it can live in `storage`,
-- go through JSON, and be identical on every multiplayer client.
--
-- plan = {
--   id, name, force, author, created_tick,
--   next_id,
--   cards = {
--     recipe card: { id, recipe, machine, x, y, modules = item name | nil, beacons = { count, module } | nil,
--                    target = nil | {kind="rate", product=res, value=per_s}
--                                 | {kind="machines", value=n}   exactly n machines
--                                 | {kind="limit", value=n} }     up to n machines
--     panel:       { id, kind = "source" | "sink", x, y,
--                    items = { { res, rule = nil | "upto" | "exact", value = per_s } } }
--   },
--   wires = { { id, from = card_id, to = card_id, res } },
-- }

local plan_lib = {}

plan_lib.STRING_PREFIX = "ffp1:"

function plan_lib.new(id, name, force_index, author, tick)
  return {
    id = id,
    name = name,
    force = force_index,
    author = author,
    created_tick = tick or 0,
    next_id = 1,
    cards = {},
    wires = {},
  }
end

local function take_id(plan)
  local id = plan.next_id
  plan.next_id = id + 1
  return id
end

function plan_lib.card(plan, id)
  for _, c in ipairs(plan.cards) do if c.id == id then return c end end
end

function plan_lib.add_card(plan, recipe, machine, x, y)
  local card = { id = take_id(plan), recipe = recipe, machine = machine, x = x, y = y }
  plan.cards[#plan.cards + 1] = card
  return card
end

function plan_lib.is_panel(card) return card.kind == "source" or card.kind == "sink" end

--- A supply panel (things come in from outside: outputs only) or an output
--- panel (things leave the plan: inputs only).
function plan_lib.add_panel(plan, kind, x, y)
  local card = { id = take_id(plan), kind = kind, x = x, y = y, items = {} }
  plan.cards[#plan.cards + 1] = card
  return card
end

--- The panel's entry for a resource, added if missing.
function plan_lib.panel_item(card, res)
  for _, it in ipairs(card.items) do
    if it.res == res then return it end
  end
  local it = { res = res }
  card.items[#card.items + 1] = it
  return it
end

function plan_lib.remove_panel_item(plan, card, res)
  for i = #card.items, 1, -1 do
    if card.items[i].res == res then table.remove(card.items, i) end
  end
  plan_lib.remove_port_wires(plan, card.id, card.kind == "source" and "out" or "in", res)
end

function plan_lib.remove_card(plan, id)
  for i = #plan.cards, 1, -1 do
    if plan.cards[i].id == id then table.remove(plan.cards, i) end
  end
  for i = #plan.wires, 1, -1 do
    local w = plan.wires[i]
    if w.from == id or w.to == id then table.remove(plan.wires, i) end
  end
end

--- Adds a wire unless an identical one exists or it would join a card to itself.
function plan_lib.add_wire(plan, from, to, res)
  if from == to then return nil, "same-card" end
  for _, w in ipairs(plan.wires) do
    if w.from == from and w.to == to and w.res == res then return nil, "exists" end
  end
  local wire = { id = take_id(plan), from = from, to = to, res = res }
  plan.wires[#plan.wires + 1] = wire
  return wire
end

--- Removes every wire on one port. side: "in" or "out".
function plan_lib.remove_port_wires(plan, card_id, side, res)
  local n = 0
  for i = #plan.wires, 1, -1 do
    local w = plan.wires[i]
    local hit = w.res == res and ((side == "in" and w.to == card_id) or (side == "out" and w.from == card_id))
    if hit then table.remove(plan.wires, i); n = n + 1 end
  end
  return n
end

--- Plain copy of the shareable part of a plan.
local function copy(v)
  if type(v) ~= "table" then return v end
  local out = {}
  for k, x in pairs(v) do out[k] = copy(x) end
  return out
end

function plan_lib.export_table(plan)
  local out = { v = 2, name = plan.name, links = plan.links, units = plan.units, cards = {}, wires = {} }
  for _, c in ipairs(plan.cards) do
    out.cards[#out.cards + 1] = {
      id = c.id, kind = c.kind, recipe = c.recipe, machine = c.machine, x = c.x, y = c.y,
      target = copy(c.target), modules = c.modules, beacons = copy(c.beacons), items = copy(c.items),
    }
  end
  for _, w in ipairs(plan.wires) do
    out.wires[#out.wires + 1] = { from = w.from, to = w.to, res = w.res }
  end
  return out
end

--- @param codec table { to_json = fn, from_json = fn, encode = fn, decode = fn }
function plan_lib.to_string(plan, codec)
  return plan_lib.STRING_PREFIX .. codec.encode(codec.to_json(plan_lib.export_table(plan)))
end

local function num(v) return type(v) == "number" and v == v and v ~= math.huge and v ~= -math.huge end

--- Parses an exchange string into a fresh plan (new ids, every card checked).
--- @param recipe_exists fun(name: string): boolean
--- @return table|nil plan, string|nil error, integer dropped_cards
function plan_lib.from_string(str, codec, recipe_exists, id, force_index, author, tick)
  if type(str) ~= "string" then return nil, "empty" end
  str = string.gsub(str, "%s", "")
  if string.sub(str, 1, #plan_lib.STRING_PREFIX) ~= plan_lib.STRING_PREFIX then return nil, "bad-prefix" end
  local ok, decoded = pcall(codec.decode, string.sub(str, #plan_lib.STRING_PREFIX + 1))
  if not ok or type(decoded) ~= "string" then return nil, "bad-data" end
  local ok2, data = pcall(codec.from_json, decoded)
  if not ok2 or type(data) ~= "table" or type(data.cards) ~= "table" then return nil, "bad-data" end

  local name = type(data.name) == "string" and string.sub(data.name, 1, 100) or "Imported plan"
  local plan = plan_lib.new(id, name, force_index, author, tick)
  if data.links == "lines" then plan.links = "lines" end
  if type(data.units) == "string" and #data.units < 100 then plan.units = data.units end
  local remap, dropped = {}, 0
  local RULES = { upto = true, exact = true }
  for _, c in ipairs(data.cards) do
    local card
    if type(c) == "table" and num(c.x) and num(c.y) and (c.kind == "source" or c.kind == "sink") then
      card = plan_lib.add_panel(plan, c.kind, c.x, c.y)
      for _, it in ipairs(type(c.items) == "table" and c.items or {}) do
        if type(it) == "table" and type(it.res) == "string" then
          local item = plan_lib.panel_item(card, it.res)
          if RULES[it.rule] and num(it.value) and it.value >= 0 then item.rule, item.value = it.rule, it.value end
        end
      end
    elseif type(c) == "table" and type(c.recipe) == "string" and recipe_exists(c.recipe) and num(c.x) and num(c.y) then
      card = plan_lib.add_card(plan, c.recipe, type(c.machine) == "string" and c.machine or nil, c.x, c.y)
      local t = c.target
      if type(t) == "table" and num(t.value) and t.value >= 0 then
        if t.kind == "machines" or t.kind == "limit" then
          card.target = { kind = t.kind, value = t.value }
        elseif t.kind == "rate" and type(t.product) == "string" then
          card.target = { kind = "rate", product = t.product, value = t.value }
        end
      end
      if type(c.modules) == "string" then card.modules = c.modules end
      local b = c.beacons
      if type(b) == "table" and num(b.count) and b.count > 0 then
        card.beacons = { count = math.min(math.floor(b.count), 100), module = type(b.module) == "string" and b.module or nil }
      end
    end
    if card then
      if c.id ~= nil then remap[c.id] = card.id end
    else
      dropped = dropped + 1
    end
  end
  for _, w in ipairs(type(data.wires) == "table" and data.wires or {}) do
    if type(w) == "table" and type(w.res) == "string" then
      local a, b = remap[w.from], remap[w.to]
      if a and b then plan_lib.add_wire(plan, a, b, w.res) end
    end
  end
  return plan, nil, dropped
end

return plan_lib
