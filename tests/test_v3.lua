package.path = MOD_ROOT .. "/?.lua;" .. package.path
local mock = dofile(TESTS_DIR .. "/mock_factorio.lua")
dofile(MOD_ROOT .. "/control.lua")
local H = mock.handlers
local layout = require("scripts.layout")
local board = require("scripts.board")
local catalog = require("scripts.catalog")
local plan_lib = require("scripts.plan")
local fails = 0
local function check(cond, msg)
  if cond then print("ok   " .. msg) else fails = fails + 1; print("FAIL " .. msg) end
end
local P1 = mock.players[1]
local function find(p, pred) return mock.find(p.gui.screen, pred) or mock.find(p.gui.left, pred) or mock.find(p.gui.top, pred) end
local function by_action(p, action, extra)
  return find(p, function(el) return el.tags and el.tags.ffp == action and (not extra or extra(el)) end)
end
local function click(p, action, extra)
  local el = by_action(p, action, extra)
  assert(el, "no element for " .. action)
  H[defines.events.on_gui_click]({ player_index = p.index, element = el })
end
local function select(p, action, index, extra)
  local el = by_action(p, action, extra)
  assert(el, "no dropdown " .. action)
  el.selected_index = index
  H[defines.events.on_gui_selection_state_changed]({ player_index = p.index, element = el })
end
local tick = 1000
local function wheel(p, pos, dir, mod, also_plain)
  tick = tick + 1
  local name = "ffp-wheel-" .. (dir > 0 and "up" or "down") .. (mod and ("-" .. mod) or "")
  if also_plain then H["ffp-wheel-" .. (dir > 0 and "up" or "down")]({ player_index = p.index, input_name = "ffp-wheel-" .. (dir > 0 and "up" or "down"), cursor_position = pos, tick = tick, in_gui = false }) end
  H[name]({ player_index = p.index, input_name = name, cursor_position = pos, tick = tick, in_gui = false })
  H[defines.events.on_tick]({ tick = tick + 1 })
end
local function tool_select(p, a, b)
  H[defines.events.on_player_selected_area]({ player_index = p.index, item = "ffp-board-tool", position = a, cursor_position = b or a,
    area = { left_top = a, right_bottom = b or a } })
end
local function right_click(p, pos) H["ffp-right-click"]({ player_index = p.index, cursor_position = pos, in_gui = false }) end

H.init()
H["ffp-toggle"]({ player_index = 1 })
P1.gui.screen.ffp_plans.foot.new_name.text = "Science"
click(P1, "new-plan")
local plan = storage.plans[1]
local o = board.origin(plan)
local add = by_action(P1, "add-recipe")
add.elem_value = "electronic-circuit"
H[defines.events.on_gui_elem_changed]({ player_index = 1, element = add })
local C = plan.cards[1]
local force = game.forces.player
local function spec() return catalog.spec(C, force) end
local function W(lx, ly) return { x = o.x + lx, y = o.y + ly } end
local function res() return storage.results[1] end
check(spec().chips and spec().module_slots == 2, "assembler 2 card has a module/beacon chip row (2 slots)")
check(P1.zoom_limits and P1.zoom_limits.closest.zoom == P1.zoom_limits.furthest.zoom, "native zoom held still on the board")

-- Where things are on the card: centres of its parts, from the shared geometry.
local function part_at(card, part, res, dx)
  for _, p in ipairs(layout.geometry(card, catalog.spec(card, force)).parts) do
    if p.part == part and (res == nil or p.res == res) then return W((p.x1 + p.x2) / 2 + (dx or 0), (p.y1 + p.y2) / 2) end
  end
  error("no part " .. part)
end
local count_at = part_at(C, "count")
local machine_at = part_at(C, "machine")
local machine_icon_at = part_at(C, "machine", nil, 1.5)
local modules_at = part_at(C, "modules")
local beacons_at = part_at(C, "beacons")
local out_at = part_at(C, "out", "item/electronic-circuit")

-- Count: Any (rate target) -> Up to what runs, rounded up -> +-1 -> Any.
wheel(P1, count_at, 1)
check(C.target and C.target.kind == "limit" and C.target.value == 1, "first notch on the count: Up to 1 (0.67 running, rounded up)")
wheel(P1, count_at, 1)
check(C.target.value == 2, "next notch: Up to 2")
wheel(P1, count_at, 1, "ctrl")
check(C.target.value == 12, "Ctrl: +10")
wheel(P1, count_at, -1, "shift")
check(C.target.value == 6, "Shift: halves (12 -> 6)")
wheel(P1, count_at, 1, "shift", true)
check(C.target.value == 12, "Shift notch also seen as a plain notch counts once, as Shift (6 -> 12)")
for _ = 1, 12 do wheel(P1, count_at, -1) end
check(C.target == nil, "below one machine: back to Any")
-- Click cycles the rule.
tool_select(P1, count_at)
check(C.target and C.target.kind == "limit", "click on the count: Up to")
tool_select(P1, count_at)
check(C.target.kind == "machines", "again: Exactly")
right_click(P1, count_at)
check(C.target == nil, "right-click on the count: Any")

-- Output rate.
wheel(P1, out_at, 1)
check(C.target and C.target.kind == "rate" and math.abs(C.target.value * 60 - 1) < 1e-9, "wheel on an output with nothing set: 1/min")
wheel(P1, out_at, 1, "shift")
check(math.abs(C.target.value * 60 - 101) < 1e-9, "Shift: +100/min")
wheel(P1, out_at, 1, "ctrl")
check(math.abs(C.target.value * 60 - 111) < 1e-9, "Ctrl: +10/min")
C.target = { kind = "rate", product = "item/electronic-circuit", value = 1 }

-- Machine.
wheel(P1, machine_at, 1)
check(C.machine == "assembling-machine-3", "wheel up on the machine: next machine (asm 3)")
wheel(P1, machine_icon_at, -1)
check(C.machine == "assembling-machine-2", "wheel down on the machine icon: back to asm 2")

-- Modules: none -> efficiency -> productivity 3 -> speed 1 -> speed 3.
local opts = catalog.module_options("electronic-circuit", "assembling-machine-2")
print("     module options:", table.concat(opts, ", "))
wheel(P1, modules_at, 1)
check(C.modules == opts[1], "wheel on modules: first module (" .. tostring(C.modules) .. ")")
for _ = 1, 10 do wheel(P1, modules_at, 1) end
check(C.modules == opts[#opts], "stops at the last module, doesn't wrap")
C.modules = "speed-module-3"
H[defines.events.on_tick]({ tick = tick + 5 })
local r0 = res().cards[C.id]
C.modules = nil; local base = catalog.spec(C, force); C.modules = "speed-module-3"
local sp = catalog.spec(C, force)
check(math.abs(sp.cpm / base.cpm - 2) < 1e-9, "2 x speed 3 in asm 2: +100% speed, twice the crafts")
check(math.abs(sp.power_w / base.power_w - 2.4) < 1e-9, "and +140% power")
local opts_gear = catalog.module_options("wooden-chest", "assembling-machine-2")
local has_prod = false
for _, n in ipairs(opts_gear) do if n == "productivity-module-3" then has_prod = true end end
check(not has_prod, "productivity modules not offered for a final product (wooden chest)")

-- Beacons.
C.modules = nil
wheel(P1, beacons_at, 1)
check(C.beacons and C.beacons.count == 1 and C.beacons.module == "speed-module-3", "wheel on beacons: 1 beacon with the best speed module")
wheel(P1, beacons_at, 1, "ctrl")
check(C.beacons.count == 5, "Ctrl: +4 beacons")
wheel(P1, beacons_at, -1, "shift")
check(C.beacons.module == "speed-module", "Shift: cycles the beacon module (" .. tostring(C.beacons.module) .. ")")
C.beacons = { count = 8, module = "speed-module-3" }
local bs = catalog.spec(C, force)
local expect = 8 * 1.5 * 0.3535 * 2 * 0.5
check(math.abs(bs.speed_bonus - expect) < 1e-9, string.format("8 beacons: +%.1f%% speed (effectivity x profile x slots)", expect * 100))
local beff = false
for _, n in ipairs(catalog.beacon_module_options("electronic-circuit")) do if n == "productivity-module-3" then beff = true end end
check(not beff, "beacons don't take productivity modules")
right_click(P1, beacons_at)
check(C.beacons.count == 7, "right-click on beacons: one fewer")
tool_select(P1, beacons_at)
check(C.beacons.count == 8, "click on beacons: one more")

-- Wheel over nothing zooms.
local z0 = P1.zoom
wheel(P1, W(C.x - 30, C.y), 1)
check(P1.zoom > z0 and P1.zoom_limits.closest.zoom == P1.zoom, "wheel over empty space zooms in")
wheel(P1, W(C.x - 30, C.y), -1)
check(math.abs(P1.zoom - z0) < 1e-9, "and back out")
wheel(P1, part_at(C, "header"), 1)
check(P1.zoom > z0, "wheel over a card title zooms too")
-- Wheel over a window does nothing.
local before = C.beacons.count
H["ffp-wheel-up"]({ player_index = 1, input_name = "ffp-wheel-up", cursor_position = beacons_at, tick = 5000, in_gui = true })
H[defines.events.on_tick]({ tick = 5001 })
check(C.beacons.count == before, "wheel over a window is left to the window")

-- Inspector controls for modules and beacons.
board.session(1).selected = C.id
require("scripts.gui").inspector_update(P1)
select(P1, "modules", 1 + #opts)
check(C.modules == opts[#opts], "inspector: module dropdown")
select(P1, "beacon-count", 1)
check(C.beacons == nil, "inspector: 0 beacons clears them")
select(P1, "target-kind", 4)
check(C.target.kind == "limit", "inspector: Up to N machines")

-- Panels from the toolbar.
click(P1, "add-panel", function(el) return el.tags.kind == "source" end)
local Sup = plan.cards[#plan.cards]
check(Sup.kind == "source" and #Sup.items == 0, "+ Supply adds an empty supply panel")
-- Drag the circuit card's iron input onto the supply panel.
local ix, iy = layout.port_point(C, catalog.spec(C, force), "in", "item/iron-plate")
local sl, st = layout.box(Sup, catalog.spec(Sup, force))
tool_select(P1, W(ix + 0.5, iy), W(Sup.x + 3, Sup.y + 0.5))
check(#Sup.items == 1 and Sup.items[1].res == "item/iron-plate", "dragging an input onto a supply panel adds that item")
local wired = false
for _, w in ipairs(plan.wires) do if w.from == Sup.id and w.to == C.id and w.res == "item/iron-plate" then wired = true end end
check(wired, "and wires it")
C.target = { kind = "rate", product = "item/electronic-circuit", value = 1 }
board.resolve(plan)
check(math.abs(res().cards[Sup.id].outputs["item/iron-plate"].rate - 1) < 1e-9, "the supply panel hands out what the card needs")
-- Wheel on the supply port: caps it (Up to), starting from what it gives now.
wheel(P1, part_at(Sup, "out", "item/iron-plate"), -1, "ctrl")
check(Sup.items[1].rule == "upto" and math.abs(Sup.items[1].value * 60 - 50) < 1e-9, "Ctrl-wheel down on the supply: up to 50/min")
check(res().shortfall["item/iron-plate"] ~= nil, "the cap now shows as short downstream")

-- Picker: output panel from an output dragged into space.
local cx2, cy2 = layout.port_point(C, catalog.spec(C, force), "out", "item/electronic-circuit")
tool_select(P1, W(cx2 - 0.5, cy2), W(cx2 + 25, cy2))
click(P1, "pick", function(el) return el.tags.panel == "sink" end)
local Out = plan.cards[#plan.cards]
check(Out.kind == "sink" and Out.items[1].res == "item/electronic-circuit", "picker's first choice makes an output panel for it")
wheel(P1, part_at(Out, "in", "item/electronic-circuit"), 1, "shift")
check(Out.items[1].rule == "exact", "wheel on an output panel's item sets Exactly")
C.target = nil
board.resolve(plan)
-- With only the panel asking, the card follows it (up to its supply cap).
check(res().status ~= "no_target", "an Exactly output panel counts as a target")

-- Right-click clears a port's restriction first, and only then unlinks.
local function wires_on(card_id, res)
  local n = 0
  for _, w in ipairs(plan.wires) do if (w.from == card_id or w.to == card_id) and w.res == res then n = n + 1 end end
  return n
end
local out_res = "item/chemical-science-pack"
C.target = { kind = "rate", product = "item/electronic-circuit", value = 1 }
local cw = wires_on(C.id, "item/electronic-circuit")
right_click(P1, part_at(C, "out", "item/electronic-circuit"))
check(C.target == nil and wires_on(C.id, "item/electronic-circuit") == cw, "right-click on a targeted output clears the target and keeps its link")
right_click(P1, part_at(C, "out", "item/electronic-circuit"))
check(wires_on(C.id, "item/electronic-circuit") == 0, "a second right-click unlinks it")
Out.items[1] = Out.items[1] or { res = "item/electronic-circuit" }
plan_lib.add_wire(plan, C.id, Out.id, Out.items[1].res)
Out.items[1].rule, Out.items[1].value = "exact", 1
local ow = wires_on(Out.id, Out.items[1].res)
right_click(P1, part_at(Out, "in", Out.items[1].res))
check(Out.items[1].rule == nil and wires_on(Out.id, Out.items[1].res) == ow, "right-click on a panel item with a rate clears the rate and keeps its link")
right_click(P1, part_at(Out, "in", Out.items[1].res))
check(wires_on(Out.id, Out.items[1].res) == 0, "and a second right-click unlinks it")
Out.items[1].rule, Out.items[1].value = "upto", 0.5

-- Panel inspector.
board.session(1).selected = Out.id
require("scripts.gui").inspector_update(P1)
select(P1, "panel-rule", 2)
check(Out.items[1].rule == "upto", "panel inspector: rule dropdown")
local tf = by_action(P1, "panel-value")
tf.text = "30"
H[defines.events.on_gui_confirmed]({ player_index = 1, element = tf })
check(math.abs(Out.items[1].value * 60 - 30) < 1e-9, "panel inspector: typed rate")
click(P1, "panel-remove")
check(#Out.items == 0, "panel inspector: remove item (and its wires)")
for _, w in ipairs(plan.wires) do assert(w.to ~= Out.id) end

-- Round trip with modules, beacons and panels.
C.modules = "speed-module-3"; C.beacons = { count = 4, module = "speed-module-3" }
click(P1, "export-current")
local str = P1.gui.screen.ffp_string.box.text
click(P1, "close-string")
click(P1, "plans"); click(P1, "import-open")
P1.gui.screen.ffp_string.box.text = str
click(P1, "import-do")
local copy = storage.plans[2]
local cc = copy.cards[1]
check(cc.modules == "speed-module-3" and cc.beacons.count == 4, "modules and beacons survive export/import")
check(copy.cards[2].kind == "source" and copy.cards[2].items[1].rule == "upto", "panels and their rules survive")
check(math.abs(storage.results[2].power_w - storage.results[1].power_w) < 1e-6, "same numbers after import")

-- Hover: hotspots exist for every control, and hovering one explains it.
local hot = 0
for e in pairs(game.get_surface(board.SURFACE).entities) do if e.valid then hot = hot + 1 end end
check(hot > 10, "hover hotspots placed over card controls (" .. hot .. ")")
local function hover_entity(pos)
  for e in pairs(game.get_surface(board.SURFACE).entities) do
    if e.valid and math.abs(e.position.x - pos.x) < 1e-6 and math.abs(e.position.y - pos.y) < 1e-6 then return e end
  end
end
local cplan = board.plan_of(P1)
local Cc = cplan.cards[1]
local function cpart(part, res)
  for _, p in ipairs(layout.geometry(Cc, catalog.spec(Cc, force)).parts) do
    if p.part == part and (res == nil or p.res == res) then
      local o2 = board.origin(cplan)
      return { x = o2.x + (p.x1 + p.x2) / 2, y = o2.y + (p.y1 + p.y2) / 2 }
    end
  end
end
local e = hover_entity(cpart("count"))
check(e and e.name == "ffp-hot-count", "a count hotspot sits over the machine count")
P1.selected = e
H[defines.events.on_selected_entity_changed]({ player_index = 1 })
local hint = board.session(1).hint
local flat = {}
local function walk(x) if type(x) == "table" then for _, v in ipairs(x) do walk(v) end else flat[#flat + 1] = tostring(x) end end
walk(hint)
local htext = table.concat(flat, "")
print("     hint: " .. htext)
check(htext:find("Machines:") and htext:find("Ctrl %+%-10"), "hover explains the count's wheel and clicks")
check(#(board.session(1).hover_ids or {}) >= 4, "hover popup drawn beside the part")
P1.selected = hover_entity(cpart("beacons"))
H[defines.events.on_selected_entity_changed]({ player_index = 1 })
flat = {}; walk(board.session(1).hint)
check(table.concat(flat, ""):find("Shift%+Scroll"), "beacons hint mentions Shift+Scroll for the module")
P1.selected = nil
H[defines.events.on_selected_entity_changed]({ player_index = 1 })
check(#(board.session(1).hover_ids or {}) == 0, "popup gone when nothing is hovered")

-- Links as belts: belt/pipe entities exist for this plan, the toggle switches to lines and back.
local function count_kind(pat)
  local n = 0
  for e in pairs(game.get_surface(board.SURFACE).entities) do if e.valid and e.name:find(pat) then n = n + 1 end end
  return n
end
local belts_before = count_kind("belt") + count_kind("pipe")
local loaded, frozen, nbelts, filled = 0, 0, 0, 0
for e in pairs(game.get_surface(board.SURFACE).entities) do
  if e.valid and e.name:find("belt") then
    nbelts = nbelts + 1
    if #e.items > 0 then loaded = loaded + 1 end
    if e.disabled_by_script then frozen = frozen + 1 end
  end
  if e.valid and e.name:find("pipe") and e.fluid then filled = filled + 1 end
end
check(nbelts > 0 and frozen == 0, "belts run (not switched off)")
for _ = 1, 20 do H["nth6"]({}) end
local fed, drained = 0, 0
for e in pairs(game.get_surface(board.SURFACE).entities) do
  if e.valid and e.name:find("belt") then fed = fed + e.fed; drained = drained + e.cleared end
end
check(fed > 0 and drained > 0, "running belts are fed at the start and emptied at the end (" .. fed .. " fed, " .. drained .. " cleared)")
check(loaded > 0, "belts carry their link's items (" .. loaded .. " of " .. nbelts .. " belt tiles hold some)")
check(belts_before > 0, "links are laid as belts/pipes (" .. belts_before .. " entities)")
local sig = storage.link_sig[cplan.id]
local nents = #storage.link_ents[cplan.id]
board.draw(cplan)
check(#storage.link_ents[cplan.id] == nents and storage.link_sig[cplan.id] == sig, "redrawing with nothing changed keeps the same entities")
click(P1, "toggle-links")
check(cplan.links == "lines" and #storage.link_ents[cplan.id] == 0, "toggle to lines removes the belts")
click(P1, "toggle-links")
check(cplan.links == "belts" and #storage.link_ents[cplan.id] > 0, "and back to belts")

-- Units: per second, then a fraction of a yellow belt.
local udd = by_action(P1, "units")
check(udd ~= nil, "units dropdown at the top of the side panel")
local keys = {}
for i, l in ipairs(udd.items) do keys[i] = l end
udd.selected_index = 1
H[defines.events.on_gui_selection_state_changed]({ player_index = 1, element = udd })
check(cplan.units == "s" and overview_text(P1):find("/s"), "per second shows /s in the overview")
local before_t = Cc.target
Cc.target = { kind = "rate", product = "item/electronic-circuit", value = 1 }
wheel(P1, cpart("out", "item/electronic-circuit"), 1)
check(math.abs(Cc.target.value - 2) < 1e-9, "in /s a wheel notch is +1/s (1 -> 2 per second)")
udd = by_action(P1, "units")
udd.selected_index = 4 -- first belt
H[defines.events.on_gui_selection_state_changed]({ player_index = 1, element = udd })
check(cplan.units == "belt:transport-belt" and overview_text(P1):find("%[entity=transport%-belt%]"), "belt units show fractions of a yellow belt")
require("scripts.fmt").use("belt:transport-belt", catalog.transport_kit())
check(require("scripts.fmt").rate(7.5, "item/iron-plate"):find("^0.5 "), "7.5 items/s is half a yellow belt")
check(require("scripts.fmt").rate(7.5, "fluid/water") == "450/min", "fluids stay per minute in belt units")
udd = by_action(P1, "units"); udd.selected_index = 2
H[defines.events.on_gui_selection_state_changed]({ player_index = 1, element = udd })
Cc.target = before_t

-- Leaving gives the game its zoom back.
H["ffp-toggle"]({ player_index = 1 })
check(P1.zoom_limits and next(P1.zoom_limits) == nil, "leaving releases the zoom")
-- Deleting a plan removes its hotspots.
H["ffp-toggle"]({ player_index = 1 })
click(P1, "delete-plan", function(el) return el.tags.plan == 2 end)
click(P1, "delete-plan-confirm", function(el) return el.tags.plan == 2 end)
local left = 0
local o3 = 2 * 2000
for e2 in pairs(game.get_surface(board.SURFACE).entities) do if e2.valid and e2.position.x > o3 - 500 and e2.position.x < o3 + 500 then left = left + 1 end end
check(left == 0, "deleting a plan removes its hotspots and belts")
local renders = 0
for _ in pairs(mock.objects) do renders = renders + 1 end
print("     render objects in use:", renders)
print(fails == 0 and "ALL PASS" or (fails .. " FAILURES"))
