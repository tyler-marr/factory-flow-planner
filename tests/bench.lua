-- Rough timings for a large plan, outside the game. Lupa's Lua 5.2 runs at
-- roughly the speed of Factorio's, so treat these as order-of-magnitude.
package.path = MOD_ROOT .. "/?.lua;" .. package.path
local mock = dofile(TESTS_DIR .. "/mock_factorio.lua")
dofile(MOD_ROOT .. "/control.lua")
local H = mock.handlers
local plan_lib = require("scripts.plan")
local board = require("scripts.board")
local layout = require("scripts.layout")
local links = require("scripts.links")
local catalog = require("scripts.catalog")
H.init()
local P1 = mock.players[1]
H["ffp-toggle"]({ player_index = 1 })
H[defines.events.on_gui_click]({ player_index = 1, element = mock.find(P1.gui.screen, function(el) return el.tags and el.tags.ffp == "new-plan" end) })
local plan = storage.plans[1]

-- N chains of cable -> circuit -> (next chain's circuit feeds nothing): 2 cards and 1-2 links per chain,
-- plus every circuit card wired to a shared output panel to make long, crossing links.
local N = tonumber(BENCH_N) or 40
local out = plan_lib.add_panel(plan, "sink", layout.snap(80), layout.snap(0))
plan_lib.panel_item(out, "item/electronic-circuit")
out.items[1].rule, out.items[1].value = "exact", N * 1.0
for i = 1, N do
  local row = (i - 1) % 10
  local col = math.floor((i - 1) / 10)
  local cab = plan_lib.add_card(plan, "copper-cable", "assembling-machine-2", layout.snap(col * 40), layout.snap(row * 14))
  local cir = plan_lib.add_card(plan, "electronic-circuit", "assembling-machine-2", layout.snap(col * 40 + 18), layout.snap(row * 14))
  plan_lib.add_wire(plan, cab.id, cir.id, "item/copper-cable")
  plan_lib.add_wire(plan, cir.id, out.id, "item/electronic-circuit")
end
local function t(label, f, reps)
  reps = reps or 1
  local t0 = os.clock()
  for _ = 1, reps do f() end
  local ms = (os.clock() - t0) * 1000 / reps
  print(string.format("%-34s %8.1f ms", label, ms))
  return ms
end
print(string.format("plan: %d cards, %d links", #plan.cards, #plan.wires))
t("solve", function() board.resolve(plan) end, 3)
local specs = board.specs(plan)
t("route all links, cold (belts)", function() links.lay(plan, function(c) return specs[c.id] end, storage.results[1].wires, catalog.transport_kit()) end)
t("full first draw incl. entities", function() board.draw(plan) end)
t("redraw, nothing changed", function() board.draw(plan) end, 3)
local flip = false
t("edit a rate (solve + redraw)", function()
  flip = not flip
  out.items[1].value = N * (flip and 1.05 or 1.0)
  board.resolve(plan); board.draw(plan)
end, 3)
local mover = plan.cards[#plan.cards]
t("move one card (solve + redraw)", function()
  mover.x = mover.x + (flip and 2 or -2); flip = not flip
  board.resolve(plan); board.draw(plan)
end, 3)
local ents, tiles = 0, 0
for e in pairs(game.get_surface(board.SURFACE).entities) do if e.valid then ents = ents + 1 end end
local robjs = 0
for _ in pairs(mock.objects) do robjs = robjs + 1 end
local runs = 0
for _ in pairs(storage.link_state[plan.id] or {}) do runs = runs + 1 end
print(string.format("entities on the board: %d   render objects: %d   moving belts: %d", ents, robjs, runs))
t("belt feeder (one 6-tick pass)", function() board.run_belts() end, 20)
board.set_sleeping(plan.id, true)
t("belt feeder, plan asleep", function() board.run_belts() end, 20)
