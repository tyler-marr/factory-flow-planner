local solver = require("scripts.solver")
local rm = require("scripts.recipe_math")
local plan_lib = require("scripts.plan")
local layout = require("scripts.layout")

local MACHINES = {
  ["assembling-machine-2"] = { speed = 0.75, power_w = 150000 },
  ["chemical-plant"] = { speed = 1, power_w = 210000 },
  ["oil-refinery"] = { speed = 1, power_w = 420000 },
  ["electric-furnace"] = { speed = 2, power_w = 180000 },
}
local function spec_of(card)
  if card.kind == "source" or card.kind == "sink" then
    local ports = {}
    for _, it in ipairs(card.items) do ports[#ports + 1] = { res = it.res } end
    return { panel = true, inputs = card.kind == "sink" and ports or {}, outputs = card.kind == "source" and ports or {} }
  end
  return rm.spec(RECIPES[card.recipe], MACHINES[card.machine], card.bonus)
end
local fails = 0
local function near(a, b, msg)
  if math.abs((a or -1) - b) > 1e-6 * math.max(1, math.abs(b)) then
    fails = fails + 1; print("FAIL " .. msg .. ": got " .. tostring(a) .. " want " .. b)
  else print("ok   " .. msg .. " = " .. string.format("%.4f", a)) end
end

-- 1. Green circuits fed by a cable card; plates imported.
local p = plan_lib.new(1, "green", 1, "me")
local A = plan_lib.add_card(p, "electronic-circuit", "assembling-machine-2", 20, 0)
local B = plan_lib.add_card(p, "copper-cable", "assembling-machine-2", 0, 0)
local C = plan_lib.add_card(p, "iron-plate", "electric-furnace", 0, 10)
plan_lib.add_wire(p, B.id, A.id, "item/copper-cable")
plan_lib.add_wire(p, C.id, A.id, "item/iron-plate")
A.target = { kind = "rate", product = "item/electronic-circuit", value = 1 }
local r = solver.solve(p, spec_of)
print("status", r.status)
near(r.cards[A.id].machines, 2/3, "circuit assemblers")
near(r.cards[B.id].machines, 1, "cable assemblers")
near(r.cards[C.id].machines, 1/(2/3.2), "iron furnaces (3.2s recipe)")
near(r.imports["item/copper-plate"], 1.5, "copper plate import")
near(r.imports["item/iron-ore"], 1, "iron ore import")
near(r.surplus["item/copper-cable"] or 0, 0, "no cable surplus")
near(r.power_w, (2/3)*150000 + 150000 + 1.6*180000, "power")

-- 2. Cable card pinned to half a machine: circuits are short of cable.
B.target = { kind = "machines", value = 0.5 }
r = solver.solve(p, spec_of)
print("status", r.status)
near(r.cards[B.id].machines, 0.5, "pinned cable machines")
near(r.shortfall["item/copper-cable"], 1.5, "cable shortfall (3 needed, 1.5 made)")
B.target = nil

-- 3. Advanced oil with both crackers wired back: everything ends as petroleum.
local q = plan_lib.new(2, "oil", 1, "me")
local R = plan_lib.add_card(q, "advanced-oil-processing", "oil-refinery", 0, 0)
local H = plan_lib.add_card(q, "heavy-oil-cracking", "chemical-plant", 15, 0)
local Lc = plan_lib.add_card(q, "light-oil-cracking", "chemical-plant", 30, 0)
local Sink = plan_lib.add_card(q, "plastic-bar", "chemical-plant", 45, 0)
plan_lib.add_wire(q, R.id, H.id, "fluid/heavy-oil")
plan_lib.add_wire(q, R.id, Lc.id, "fluid/light-oil")
plan_lib.add_wire(q, H.id, Lc.id, "fluid/light-oil")
plan_lib.add_wire(q, R.id, Sink.id, "fluid/petroleum-gas")
plan_lib.add_wire(q, Lc.id, Sink.id, "fluid/petroleum-gas")
Sink.target = { kind = "rate", product = "item/plastic-bar", value = 2 }
r = solver.solve(q, spec_of)
print("status", r.status)
near(r.surplus["fluid/heavy-oil"] or 0, 0, "no heavy oil left")
near(r.surplus["fluid/light-oil"] or 0, 0, "no light oil left")
near(r.surplus["fluid/petroleum-gas"] or 0, 0, "no petroleum left")
-- plastic: 20 petroleum + 1 coal -> 2 plastic, 1s.  2/s needs 20 petroleum/s.
local crude = r.imports["fluid/crude-oil"]
print(string.format("     crude %.3f/s, refineries %.3f, heavy crackers %.3f, light crackers %.3f",
  crude, r.cards[R.id].machines, r.cards[H.id].machines, r.cards[Lc.id].machines))
-- per refinery craft (100 crude): 25 heavy -> 20 light (40 heavy:30 light), 45+18.75 light -> 2/3*... check by balance
local per_craft_pet = 55 + (45 + 25 * 30/40) * (20/30)
near(crude, 20 / per_craft_pet * 100, "crude needed matches hand calc")

-- 4. Productivity bonus applies to products only.
local s = rm.spec(RECIPES["iron-gear-wheel"], MACHINES["assembling-machine-2"], { productivity = 0.1 })
near(s.outputs[1].amount, 1.1, "gear with 10% productivity")

-- 5. A target nobody can meet without a contradiction is reported, not crashed.
local z = plan_lib.new(3, "bad", 1, "me")
local G = plan_lib.add_card(z, "iron-gear-wheel", "assembling-machine-2", 0, 0)
G.target = { kind = "rate", product = "item/iron-gear-wheel", value = 1 }
local G2 = plan_lib.add_card(z, "iron-gear-wheel", "assembling-machine-2", 0, 0)
r = solver.solve(z, spec_of)
print("     unrelated empty card machines", r.cards[G2.id].machines, "status", r.status)

-- 5b. A wired consumer with no target doesn't eat the goal output.
local g = plan_lib.new(5, "goal", 1, "me")
local Gc = plan_lib.add_card(g, "electronic-circuit", "assembling-machine-2", 0, 0)
local Ga = plan_lib.add_card(g, "advanced-circuit", "assembling-machine-2", 20, 0)
plan_lib.add_wire(g, Gc.id, Ga.id, "item/electronic-circuit")
Gc.target = { kind = "rate", product = "item/electronic-circuit", value = 1 }
r = solver.solve(g, spec_of)
near(r.cards[Ga.id].machines, 0, "untargeted consumer stays idle")
near(r.products["item/electronic-circuit"], 1, "goal output reported as product")

-- 5c. Panels: a supply capped at 30 cable/min feeds circuits; an output panel wants 120 circuits/min.
local pp = plan_lib.new(6, "panels", 1, "me")
local Sup = plan_lib.add_panel(pp, "source", 0, 0)
local it = plan_lib.panel_item(Sup, "item/copper-cable"); it.rule, it.value = "upto", 0.5
local Cc = plan_lib.add_card(pp, "electronic-circuit", "assembling-machine-2", 15, 0)
local Out = plan_lib.add_panel(pp, "sink", 30, 0)
local o = plan_lib.panel_item(Out, "item/electronic-circuit"); o.rule, o.value = "exact", 2
plan_lib.add_wire(pp, Sup.id, Cc.id, "item/copper-cable")
plan_lib.add_wire(pp, Cc.id, Out.id, "item/electronic-circuit")
r = solver.solve(pp, spec_of)
print("status", r.status)
near(r.cards[Sup.id].outputs["item/copper-cable"].rate, 0.5, "supply gives its cap")
near(r.cards[Cc.id].rate, 0.5 / 3, "the capped cable is the bottleneck, as in game")
near(r.shortfall["item/electronic-circuit"], 2 - 0.5 / 3, "output panel shows what it is short")
it.rule, it.value = nil, nil
r = solver.solve(pp, spec_of)
near(r.cards[Cc.id].rate, 2, "uncapped: output panel drives the circuit card (2 crafts/s)")
near(r.products["item/electronic-circuit"], 2, "output panel takes 120/min")
it.rule, it.value = nil, nil
r = solver.solve(pp, spec_of)
near(r.cards[Sup.id].outputs["item/copper-cable"].rate, 6, "uncapped supply gives what is needed")
near(r.imports["item/copper-cable"], 6, "and counts as an input")
near(r.shortfall["item/copper-cable"] or 0, 0, "no shortfall")

-- 5d. Machine limit: up to 1 circuit machine (1.5 crafts/s) caps the output panel.
Cc.target = { kind = "limit", value = 1 }
r = solver.solve(pp, spec_of)
near(r.cards[Cc.id].machines, 1, "limit holds the card at 1 machine")
near(r.shortfall["item/electronic-circuit"], 0.5, "output panel short by what the limit blocks")
Cc.target = nil
o.rule = "upto"; o.value = 1
local Tg = plan_lib.add_card(pp, "electronic-circuit", "assembling-machine-2", 15, 20)
Tg.target = { kind = "rate", product = "item/electronic-circuit", value = 3 }
plan_lib.add_wire(pp, Tg.id, Out.id, "item/electronic-circuit")
r = solver.solve(pp, spec_of)
near(r.cards[Out.id].inputs["item/electronic-circuit"].rate, 1, "an Up to output panel takes no more than its cap")

-- 6. Exchange string round trip.
local codec = { to_json = py_to_json, from_json = py_from_json, encode = py_encode, decode = py_decode }
local str = plan_lib.to_string(q, codec)
print("     string length", #str, string.sub(str, 1, 24) .. "...")
local back, err, dropped = plan_lib.from_string(str, codec, function(n) return RECIPES[n] ~= nil end, 9, 1, "friend", 0)
assert(back, err)
near(#back.cards, 4, "cards survive"); near(#back.wires, 5, "wires survive")
local pstr = plan_lib.to_string(pp, codec)
local pback = plan_lib.from_string(pstr, codec, function(n) return RECIPES[n] ~= nil end, 10, 1, "friend", 0)
near(#pback.cards, 4, "panels survive a round trip")
near(pback.cards[1].items[1].res == "item/copper-cable" and 1 or 0, 1, "panel items survive")
near(pback.cards[3].items[1].value, 1, "panel rules survive")
local r2 = solver.solve(back, spec_of)
near(r2.imports["fluid/crude-oil"], crude, "same answer after import")
local bad = plan_lib.from_string("ffp1:garbage", codec, function() return true end, 1, 1, "x", 0)
print("     garbage string ->", tostring(bad))

-- 7. Hit testing.
local spA = spec_of(A)
local x, y = layout.port_point(A, spA, "in", "item/copper-cable")
local h = layout.hit(A, spA, x + 0.5, y)
print("     hit", h.part, h.res)
assert(h.part == "in" and h.res == "item/copper-cable")

-- 8. Size: 60 cards in a chain solves fast.
local big = plan_lib.new(4, "big", 1, "me")
local prev
for i = 1, 60 do
  local c = plan_lib.add_card(big, i % 2 == 0 and "copper-cable" or "electronic-circuit", "assembling-machine-2", i * 12, 0)
  if prev and RECIPES[prev.recipe].results[1].name == "copper-cable" and c.recipe == "electronic-circuit" then
    plan_lib.add_wire(big, prev.id, c.id, "item/copper-cable")
  end
  c.target = (i % 2 == 1) and { kind = "rate", product = "item/electronic-circuit", value = i / 10 } or nil
  prev = c
end
local t0 = os.clock()
r = solver.solve(big, spec_of)
print(string.format("     60 cards: %s in %.1f ms", r.status, (os.clock() - t0) * 1000))
print(fails == 0 and "ALL PASS" or (fails .. " FAILURES"))
