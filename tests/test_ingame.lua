package.path = MOD_ROOT .. "/?.lua;" .. package.path
local mock = dofile(TESTS_DIR .. "/mock_factorio.lua")
dofile(MOD_ROOT .. "/control.lua")
local H = mock.handlers
local layout = require("scripts.layout")
local board = require("scripts.board")
local catalog = require("scripts.catalog")
local fails = 0
local function check(cond, msg)
  if cond then print("ok   " .. msg) else fails = fails + 1; print("FAIL " .. msg) end
end
local P1, P2 = mock.players[1], mock.players[2]
local function find(p, pred) return mock.find(p.gui.screen, pred) or mock.find(p.gui.left, pred) or mock.find(p.gui.top, pred) end
local function by_action(p, action, extra)
  return find(p, function(el) return el.tags and el.tags.ffp == action and (not extra or extra(el)) end)
end
local function click(p, action, extra)
  local el = by_action(p, action, extra)
  assert(el, "no element for " .. action)
  H[defines.events.on_gui_click]({ player_index = p.index, element = el })
end
local function world_click(p, x, y, right)
  local pos = { x = x, y = y }
  H[right and "ffp-right-click" or "ffp-click"]({ player_index = p.index, cursor_position = pos, in_gui = false })
  if not right and p.cursor_stack.valid_for_read and p.cursor_stack.name == "ffp-board-tool" then
    H[defines.events.on_player_selected_area]({ player_index = p.index, item = "ffp-board-tool", position = pos,
      cursor_position = pos, area = { left_top = pos, right_bottom = pos } })
  end
end
local function drag(p, x1, y1, x2, y2)
  local a, b = { x = x1, y = y1 }, { x = x2, y = y2 }
  H["ffp-click"]({ player_index = p.index, cursor_position = a, in_gui = false })
  H[defines.events.on_player_start_selected_area]({ player_index = p.index, item = "ffp-board-tool", position = a, cursor_position = a })
  H[defines.events.on_player_change_selected_area]({ player_index = p.index, item = "ffp-board-tool", position = a,
    cursor_position = { x = (x1 + x2) / 2, y = (y1 + y2) / 2 } })
  local previewing = board.session(p.index).preview ~= nil
  H[defines.events.on_player_change_selected_area]({ player_index = p.index, item = "ffp-board-tool", position = a, cursor_position = b })
  H[defines.events.on_player_selected_area]({ player_index = p.index, item = "ffp-board-tool", position = a,
    cursor_position = b, area = { left_top = { x = math.min(x1, x2), y = math.min(y1, y2) }, right_bottom = { x = math.max(x1, x2), y = math.max(y1, y2) } } })
  return previewing
end
local function port_world(plan, card, side, res)
  local spec = catalog.spec(card, game.forces.player)
  local x, y = layout.port_point(card, spec, side, res)
  local o = board.origin(plan)
  return o.x + x + (side == "in" and 0.5 or -0.5), o.y + y
end

H.init()

-- Open plans, make one.
H[defines.events.on_lua_shortcut]({ player_index = 1, prototype_name = "ffp-shortcut" })
check(P1.gui.screen.ffp_plans ~= nil, "shortcut opens the plans window")
P1.gui.screen.ffp_plans.foot.new_name.text = "Green circuits"
click(P1, "new-plan")
local plan = storage.plans[1]
check(plan and plan.name == "Green circuits", "plan created with its name")
check(P1.controller_type == defines.controllers.god and P1.surface.name == board.SURFACE, "player moved to the board in god mode")
check(P1.character.destructible == false, "character made indestructible while away")
local ovf = P1.gui.screen.ffp_overview
check(P1.gui.top.ffp_toolbar == nil and ovf ~= nil and P1.gui.left.ffp_overview == nil, "no top toolbar; the side panel holds the controls")
check(ovf.location.x == 0 and ovf.location.y == 0 and ovf.style.height == 1080, "side panel pinned top-left, full screen height")
P1.display_resolution = { width = 2560, height = 1440 }; P1.display_scale = 1.5
H[defines.events.on_player_display_resolution_changed]({ player_index = 1 })
check(P1.gui.screen.ffp_overview.style.height == 960, "and follows resolution and UI scale (1440 / 1.5)")
P1.display_resolution = { width = 1920, height = 1080 }; P1.display_scale = 1
for _, a in ipairs({ "add-recipe", "add-panel", "toggle-links", "plans", "export-current", "leave" }) do
  assert(mock.find(P1.gui.screen, function(el) return el.tags and el.tags.ffp == a end), "side panel lacks " .. a)
end
check(true, "add recipe, panels, links, plans, export and back are all in the side panel")
check(P1.cursor_stack.valid_for_read and P1.cursor_stack.name == "ffp-board-tool", "board tool put in the cursor")
check(P1.view.show_quickbar == false and P1.view.show_minimap == false and P1.view.show_shortcut_bar == false, "quickbar, minimap and shortcut bar hidden on the board")
P1.cursor_stack.clear()
check(P1.cursor_stack.valid_for_read, "clearing the cursor on the board gives the tool back")
H[defines.events.on_chunk_generated]({ surface = game.get_surface(board.SURFACE), area = { left_top = { x = 0, y = 0 }, right_bottom = { x = 32, y = 32 } } })
check(game.get_surface(board.SURFACE).tiles_set == 1024, "new board chunks get the flat floor")

-- Add a recipe from the toolbar.
local add = by_action(P1, "add-recipe")
add.elem_value = "electronic-circuit"
H[defines.events.on_gui_elem_changed]({ player_index = 1, element = add })
local circuit = plan.cards[1]
check(circuit and circuit.recipe == "electronic-circuit", "card added from the recipe picker")
check(circuit.machine == "assembling-machine-2", "default machine is the best unlocked one (asm2): " .. tostring(circuit.machine))
check(circuit.target and circuit.target.kind == "rate" and circuit.target.value == 1, "first card seeded with a 60/min target")
check(P1.gui.screen.ffp_inspector ~= nil, "inspector opened for the new card")

-- Click its cable input: picker opens; pick copper cable.
local x, y = port_world(plan, circuit, "in", "item/copper-cable")
world_click(P1, x, y)
check(P1.gui.screen.ffp_picker ~= nil, "clicking an input opens 'what makes this'")
click(P1, "pick", function(el) return el.tags.recipe == "copper-cable" end)
local cable = plan.cards[2]
check(cable and cable.recipe == "copper-cable" and cable.x < circuit.x, "cable card placed to the left")
check(#plan.wires == 1 and plan.wires[1].from == cable.id and plan.wires[1].to == circuit.id, "and wired in")

x, y = port_world(plan, circuit, "in", "item/iron-plate")
world_click(P1, x, y)
click(P1, "pick", function(el) return el.tags.recipe == "iron-plate" end)
local iron = plan.cards[3]
check(iron.machine == "electric-furnace" or iron.machine == "steel-furnace", "smelting gets a speed-2 furnace: " .. tostring(iron.machine))
local r = storage.results[1]
check(math.abs(r.cards[circuit.id].machines - 2/3) < 1e-6, "circuit machines 0.667")
check(math.abs(r.cards[cable.id].machines - 1) < 1e-6, "cable machines 1")
check(math.abs(r.imports["item/copper-plate"] - 1.5) < 1e-6 and math.abs(r.imports["item/iron-ore"] - 1) < 1e-6, "raw inputs computed")
local overlap = false
for i = 1, #plan.cards do for j = i + 1, #plan.cards do
  local a, b = plan.cards[i], plan.cards[j]
  local sa, sb = catalog.spec(a, game.forces.player), catalog.spec(b, game.forces.player)
  local l1, t1, r1, b1 = layout.box(a, sa); local l2, t2, r2, b2 = layout.box(b, sb)
  if l1 < r2 and l2 < r1 and t1 < b2 and t2 < b1 then overlap = true end
end end
check(not overlap, "new cards don't overlap")
print("     render objects:", mock.count_objects())
local ov = overview_text(P1)
print("     overview:", ov)
check(ov:find("Outputs") and ov:find("item%-name%.electronic%-circuit 60/min"), "the overview lists the goal under Outputs")
check(ov:find("Inputs") and ov:find("item%-name%.copper%-plate 90/min"), "and copper plate under Inputs")
check(ov:find("Machines to build 4"), "and the machines to build (0.67, 1 and 1.6 rounded up: 1 + 1 + 2)")
local fb = mock.find(P1.gui.screen, function(el) return el.tags and el.tags.ffp == "focus-card" and el.tags.card == iron.id end)
H[defines.events.on_gui_click]({ player_index = 1, element = fb })
local o9 = board.origin(plan)
check(board.session(1).selected == iron.id and math.abs(P1.position.x - (o9.x + iron.x + layout.CARD_W / 2)) < 0.01,
  "clicking a card in the Machines list selects it and moves the view there")
local tg = mock.find(P1.gui.screen, function(el) return el.tags and el.tags.ffp == "overview-toggle" and el.tags.key == "inputs" end)
H[defines.events.on_gui_click]({ player_index = 1, element = tg })
check(not overview_text(P1):find("copper%-plate 90/min"), "a section header folds its section")
check(P1.gui.top.ffp_toolbar == nil, "there is no top toolbar")

-- Inspector: switch machine and target.
local sel = board.session(1).selected
local dd = by_action(P1, "machine")
dd.selected_index = 1 -- slowest: assembling-machine-1
H[defines.events.on_gui_selection_state_changed]({ player_index = 1, element = dd })
local selcard = require("scripts.plan").card(plan, sel)
check(selcard.machine == catalog.machines_for(selcard.recipe)[1].name, "machine changed from the inspector: " .. selcard.machine)
local kind = by_action(P1, "target-kind")
kind.selected_index = 3
H[defines.events.on_gui_selection_state_changed]({ player_index = 1, element = kind })
check(selcard.target and selcard.target.kind == "machines", "target switched to machine count")
local tf = by_action(P1, "target-value")
tf.text = "2"
click(P1, "target-set")
check(selcard.target.value == 2, "machine target set to 2")
r = storage.results[1]
check(r.cards[sel].machines == 2, "card solved at 2 machines")

-- Move a card by dragging its title.
local o = board.origin(plan)
local y0, x0 = circuit.y, circuit.x
local ghost_lt
local real_update = board.update_preview
board.update_preview = function(pl, pn, dr, at)
  real_update(pl, pn, dr, at)
  local id = board.session(pl.index).preview and board.session(pl.index).preview[1]
  local obj = id and rendering.get_object_by_id(id)
  if obj then ghost_lt = obj.left_top or obj.args.left_top end
end
local previewed = drag(P1, o.x + circuit.x + 3, o.y + circuit.y + 0.5, o.x + circuit.x + 7.3, o.y + circuit.y + 10.6)
board.update_preview = real_update
check(previewed, "a ghost of the card follows the cursor while dragging")
check(ghost_lt and math.abs(ghost_lt.x - (o.x + circuit.x)) < 1e-6 and math.abs(ghost_lt.y - (o.y + circuit.y)) < 1e-6,
  "the ghost is exactly where the card lands")
check(math.abs(circuit.y - (y0 + 10)) < 0.01 and math.abs(circuit.x - (x0 + 4)) < 0.01, "dragging the title moved the card by the drag (to whole tiles)")
check(board.session(1).preview == nil, "ghost removed on drop")

-- Wire by hand: output then a matching input. Duplicate does nothing.
local nwires = #plan.wires
x, y = port_world(plan, cable, "out", "item/copper-cable")
world_click(P1, x, y)
check(board.session(1).wire ~= nil, "clicking an output starts a wire")
x, y = port_world(plan, circuit, "in", "item/copper-cable")
world_click(P1, x, y)
check(#plan.wires == nwires, "duplicate wire not added")
-- Right-click unwires.
world_click(P1, x, y, true)
check(#plan.wires == nwires - 1, "right-click on the input removed its wire")
r = storage.results[1]
check((r.imports["item/copper-cable"] or 0) > 0, "unwired cable now shows as an input from outside")
x, y = port_world(plan, cable, "out", "item/copper-cable")
world_click(P1, x, y)
local cx, cy = port_world(plan, circuit, "in", "item/copper-cable")
world_click(P1, cx, cy)
check(#plan.wires == nwires, "rewired by hand")
-- Clicks on windows are ignored.
local before = #plan.wires
H["ffp-click"]({ player_index = 1, cursor_position = { x = cx, y = cy }, in_gui = true })
check(#plan.wires == before and board.session(1).wire == nil, "clicks on a window don't reach the board")

-- Drag to wire, both directions.
local n0 = #plan.wires
x, y = port_world(plan, cable, "out", "item/copper-cable")
cx, cy = port_world(plan, circuit, "in", "item/copper-cable")
world_click(P1, cx, cy, true) -- unwire first
check(#plan.wires == n0 - 1, "unwired")
local pv = drag(P1, x, y, cx, cy)
check(pv and #plan.wires == n0, "dragging output onto input wires them (with a live wire preview)")
world_click(P1, cx, cy, true)
drag(P1, cx, cy, x, y)
check(#plan.wires == n0, "dragging input onto output wires them too")
-- Drag an output onto empty space: what uses this?
local ox, oy = port_world(plan, circuit, "out", "item/electronic-circuit")
drag(P1, ox, oy, ox + 20, oy)
local picker = P1.gui.screen.ffp_picker
check(picker ~= nil and mock.find(picker, function(el) return el.caption == "What uses this?" end) ~= nil, "dragging an output to empty space asks what uses it")
local ncards = #plan.cards
click(P1, "pick", function(el) return el.tags.recipe == "advanced-circuit" end)
local adv = plan.cards[#plan.cards]
check(#plan.cards == ncards + 1 and adv.recipe == "advanced-circuit", "consumer card added")
check(math.abs((adv.x + o.x) - (ox + 20)) < 1, "placed where it was dropped")
local w = plan.wires[#plan.wires]
check(w.from == circuit.id and w.to == adv.id and w.res == "item/electronic-circuit", "wired from the dragged output")
check(math.abs(storage.results[1].wires[w.id] - 0) < 1e-9, "consumer without a target takes nothing yet")

-- Player 2 joins the same plan.
H["ffp-toggle"]({ player_index = 2 })
check(P2.gui.screen.ffp_plans ~= nil, "hotkey opens plans for player 2")
local listed = mock.find(P2.gui.screen.ffp_plans, function(el) return el.caption == "Green circuits" end)
check(listed ~= nil, "player 2 sees player 1's plan")
click(P2, "open-plan", function(el) return el.tags.plan == 1 end)
check(board.session(2).plan_id == 1 and P2.surface.name == board.SURFACE, "player 2 opened it")
local before_caption = overview_text(P2)
print("     P1 selected", board.session(1).selected, "targets:", circuit.target and circuit.target.kind, cable.target and cable.target.kind, iron.target and iron.target.kind)
board.session(1).selected = cable.id
require("scripts.gui").inspector_update(P1)
local kind1 = by_action(P1, "target-kind")
kind1.selected_index = 3
H[defines.events.on_gui_selection_state_changed]({ player_index = 1, element = kind1 })
by_action(P1, "target-value").text = "3"
click(P1, "target-set")
check(overview_text(P2) ~= before_caption, "player 1's edit updates player 2's toolbar")

-- Export and import.
click(P1, "export-current")
local str = P1.gui.screen.ffp_string.box.text
check(type(str) == "string" and str:sub(1, 5) == "ffp1:", "export string made (" .. #str .. " chars)")
click(P1, "close-string")
H["ffp-toggle"]({ player_index = 2 }) -- leave board
check(P2.controller_type == defines.controllers.character and P2.surface.name == "nauvis", "toggle on the board returns player 2")
check(P2.character.destructible == true, "player 2's character is destructible again")
check(not P2.cursor_stack.valid_for_read, "the board tool is gone after leaving")
check(P2.view.show_quickbar == true and P2.view.show_minimap == true, "HUD restored after leaving")
H["ffp-toggle"]({ player_index = 2 })
click(P2, "import-open")
P2.gui.screen.ffp_string.box.text = str
click(P2, "import-do")
local copy = storage.plans[2]
check(copy and #copy.cards == #plan.cards and #copy.wires == #plan.wires, "import made a new identical plan")
local a, b = storage.results[1], storage.results[2]
check(math.abs((a.power_w or 0) - (b.power_w or 0)) < 1e-6, "imported plan solves to the same numbers")
click(P2, "plans")
click(P2, "import-open")
P2.gui.screen.ffp_string.box.text = "not a plan"
click(P2, "import-do")
check(#P2.printed > 0, "bad string gives a message: " .. tostring(P2.printed[#P2.printed]))
click(P2, "close-string")

-- Delete plan 1 from player 2 while player 1 is on it.
click(P2, "plans")
click(P2, "delete-plan", function(el) return el.tags.plan == 1 end)
click(P2, "delete-plan-confirm", function(el) return el.tags.plan == 1 end)
check(storage.plans[1] == nil, "plan deleted after confirm")
check(P1.controller_type == defines.controllers.character and P1.surface.name == "nauvis", "player 1 sent back to their character")
check(P1.character.destructible == true, "player 1's character restored")
check(P1.gui.top.ffp_toolbar == nil and P1.gui.screen.ffp_inspector == nil, "player 1's board windows closed")
local leaked = 0
for _, obj in pairs(mock.objects) do
  if obj.args.players == nil and obj.args.target and type(obj.args.target) == "table" and obj.args.target.x and obj.args.target.x < 3000 then leaked = leaked + 1 end
end
check(leaked == 0, "plan 1 drawing removed")

-- Lifecycle events.
H.config({})
H[defines.events.on_research_finished]({ research = { force = mock.force } })
check(true, "configuration change and research re-solve without errors")
H[defines.events.on_pre_player_left_game]({ player_index = 2 })
check(P2.controller_type == defines.controllers.character, "leaving the game while on the board restores the character")

-- A delete-card and a Move button pass.
H["ffp-toggle"]({ player_index = 1 })
click(P1, "open-plan", function(el) return el.tags.plan == 2 end)
board.session(1).selected = copy.cards[1].id
H[defines.events.on_gui_click]({ player_index = 1, element = by_action(P1, "close-inspector") })
board.session(1).selected = copy.cards[1].id
require("scripts.gui").inspector_update(P1)
click(P1, "move-card")
world_click(P1, board.origin(copy).x - 30, 0)
check(math.abs(copy.cards[1].x + 30) < 0.6, "Move button then click places the card")
board.session(1).selected = copy.cards[1].id
require("scripts.gui").inspector_update(P1)
click(P1, "unwire-card")
local before_del = #copy.cards
click(P1, "delete-card")
check(#copy.cards == before_del - 1, "card deleted")
for _, w in ipairs(copy.wires) do assert(require("scripts.plan").card(copy, w.from) and require("scripts.plan").card(copy, w.to)) end
check(true, "no wires left dangling")

-- Hand-craft-only recipe gives a message instead of a broken card.
local add2 = by_action(P1, "add-recipe")
add2.elem_value = "wooden-chest"
H[defines.events.on_gui_elem_changed]({ player_index = 1, element = add2 })
print("     wooden chest ->", copy.cards[#copy.cards].recipe, P1.printed[#P1.printed])
print(fails == 0 and "ALL PASS" or (fails .. " FAILURES"))
