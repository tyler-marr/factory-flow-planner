package.path = MOD_ROOT .. "/?.lua;" .. package.path
local mock = dofile(TESTS_DIR .. "/mock_factorio.lua")
dofile(MOD_ROOT .. "/control.lua")
local H = mock.handlers
local board = require("scripts.board")
local plan_lib = require("scripts.plan")
H.init()
local P1 = mock.players[1]
H["ffp-toggle"]({ player_index = 1 })
P1.gui.screen.ffp_plans.foot.new_name.text = "science"
H[defines.events.on_gui_click]({ player_index = 1, element = mock.find(P1.gui.screen, function(el) return el.tags and el.tags.ffp == "new-plan" end) })
local plan = storage.plans[1]
local sci = plan_lib.add_card(plan, "chemical-science-pack", "assembling-machine-3", 30, 0)
sci.target = { kind = "rate", product = "item/chemical-science-pack", value = 1 }
local sul = plan_lib.add_card(plan, "sulfur", "chemical-plant", 10, 0)
sul.modules = "speed-module-3"; sul.beacons = { count = 8, module = "speed-module-3" }
sul.target = { kind = "limit", value = 1 }
local crk = plan_lib.add_card(plan, "light-oil-cracking", "chemical-plant", -10, 0)
local sup = plan_lib.add_panel(plan, "source", -20, 0)
local w = plan_lib.panel_item(sup, "fluid/water"); w.rule, w.value = "upto", 20
local out = plan_lib.add_panel(plan, "sink", 50, 0)
plan_lib.panel_item(out, "item/chemical-science-pack")
plan_lib.add_wire(plan, sul.id, sci.id, "item/sulfur")
plan_lib.add_wire(plan, crk.id, sul.id, "fluid/petroleum-gas")
plan_lib.add_wire(plan, sup.id, sul.id, "fluid/water")
plan_lib.add_wire(plan, sup.id, crk.id, "fluid/water")
plan_lib.add_wire(plan, sci.id, out.id, "item/chemical-science-pack")
board.resolve(plan); board.draw(plan)
-- hover the count of the sulfur card
local layout = require("scripts.layout")
local catalog = require("scripts.catalog")
local o = board.origin(plan)
for _, p in ipairs(layout.geometry(sul, catalog.spec(sul, game.forces.player)).parts) do
  if p.part == "count" then
    for e in pairs(game.get_surface(board.SURFACE).entities) do
      if e.valid and math.abs(e.position.x - (o.x + (p.x1 + p.x2) / 2)) < 1e-6 and math.abs(e.position.y - (o.y + (p.y1 + p.y2) / 2)) < 1e-6 then P1.selected = e end
    end
  end
end
H[defines.events.on_selected_entity_changed]({ player_index = 1 })
OBJECTS = {}
for _, obj in pairs(mock.objects) do OBJECTS[#OBJECTS + 1] = obj end
table.sort(OBJECTS, function(a, b) return a.id < b.id end)
ORIGIN = o
ENTS = {}
for e in pairs(game.get_surface(board.SURFACE).entities) do
  if e.valid and not e.name:find("^ffp%-hot") then ENTS[#ENTS + 1] = e end
end
