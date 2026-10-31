-- 0.12 performance work: cached routes, per-card redraw, sleeping and unloading plans.
package.path = MOD_ROOT .. "/?.lua;" .. package.path
local mock = dofile(TESTS_DIR .. "/mock_factorio.lua")
dofile(MOD_ROOT .. "/control.lua")
local H = mock.handlers
local plan_lib = require("scripts.plan")
local board = require("scripts.board")
local layout = require("scripts.layout")
local fails = 0
local function check(cond, msg)
  if cond then print("ok   " .. msg) else fails = fails + 1; print("FAIL " .. msg) end
end
local P1 = mock.players[1]
local function find(p, pred) return mock.find(p.gui.screen, pred) or mock.find(p.gui.left, pred) end
local function click(p, action, tags)
  local el = find(p, function(el) return el.tags and el.tags.ffp == action end)
  assert(el, "no element for " .. action)
  if tags then
    el = { tags = tags, valid = true, name = el.name, parent = el.parent }
    for k, v in pairs(tags) do el.tags[k] = v end
    el.tags.ffp = action
  end
  H[defines.events.on_gui_click]({ player_index = p.index, element = el })
end

H.init()
H["ffp-toggle"]({ player_index = 1 })

local function new_plan(name)
  game.tick = game.tick + 60
  if not find(P1, function(el) return el.tags and el.tags.ffp == "new-plan" end) then click(P1, "plans") end
  P1.gui.screen.ffp_plans.foot.new_name.text = name
  click(P1, "new-plan")
  return board.plan_of(P1)
end

-- A plan with four chains into one output panel.
local plan = new_plan("Chains")
local out = plan_lib.add_panel(plan, "sink", layout.snap(80), layout.snap(0))
plan_lib.panel_item(out, "item/electronic-circuit")
out.items[1].rule, out.items[1].value = "exact", 4
local cards = {}
for i = 1, 4 do
  local cab = plan_lib.add_card(plan, "copper-cable", "assembling-machine-2", layout.snap(0), layout.snap((i - 1) * 14))
  local cir = plan_lib.add_card(plan, "electronic-circuit", "assembling-machine-2", layout.snap(18), layout.snap((i - 1) * 14))
  plan_lib.add_wire(plan, cab.id, cir.id, "item/copper-cable")
  plan_lib.add_wire(plan, cir.id, out.id, "item/electronic-circuit")
  cards[i] = { cab = cab, cir = cir }
end
board.resolve(plan)
board.draw(plan)

local function link_ents()
  local m = {}
  for wid, rec in pairs(storage.link_state[plan.id] or {}) do m[wid] = rec.ents end
  return m
end
local function count(t) local n = 0; for _ in pairs(t) do n = n + 1 end; return n end
local function card_ids()
  local m = {}
  for cid, rec in pairs(storage.render[plan.id].cards) do m[cid] = rec.ids end
  return m
end

local ents0 = link_ents()
check(count(ents0) == #plan.wires, "every link has its own entities (" .. count(ents0) .. ")")

-- 1. A rate change inside the same belt tier keeps every route and entity.
local laid0 = storage.route_cache[plan.id].laid
out.items[1].value = 4.5
board.resolve(plan)
board.draw(plan)
local ents1 = link_ents()
local same = 0
for wid, e in pairs(ents0) do if ents1[wid] == e then same = same + 1 end end
check(same == count(ents0), "a small rate change keeps every link's entities (" .. same .. "/" .. count(ents0) .. ")")

-- 2. Moving one card re-lays only the links that touch it.
local ids0 = card_ids()
local moved = cards[4].cab
moved.x = moved.x - 4
board.resolve(plan)
board.draw(plan)
local ents2 = link_ents()
local touched, kept, rebuilt_other = 0, 0, 0
for _, w in ipairs(plan.wires) do
  local touches = w.from == moved.id or w.to == moved.id
  if touches then
    if ents2[w.id] ~= ents1[w.id] then touched = touched + 1 end
  elseif ents2[w.id] == ents1[w.id] then
    kept = kept + 1
  else
    rebuilt_other = rebuilt_other + 1
  end
end
check(touched == 1, "the moved card's link is rebuilt")
check(rebuilt_other == 0 and kept == #plan.wires - 1, "other links keep their entities (" .. kept .. " kept)")

-- 3. Per-card redraw: the moved card is redrawn, a far card is not.
local ids1 = card_ids()
check(ids1[moved.id] ~= ids0[moved.id], "the moved card is redrawn")
check(ids1[cards[1].cab.id] == ids0[cards[1].cab.id], "an unchanged card keeps its drawing")
local before = card_ids()
board.draw(plan)
local unchanged = 0
for cid, ids in pairs(card_ids()) do if before[cid] == ids then unchanged = unchanged + 1 end end
check(unchanged == count(before), "a redraw with nothing changed draws no card again")

-- 4. Sleeping: leaving the board pauses the belts and the feeder skips them.
local function asleep_ents(pid)
  local on, off = 0, 0
  for _, rec in pairs(storage.link_state[pid] or {}) do
    for _, e in ipairs(rec.ents) do
      if e.valid and e.name:find("belt") then if e.disabled_by_script then off = off + 1 else on = on + 1 end end
    end
  end
  return on, off
end
local on, off = asleep_ents(plan.id)
check(on > 0 and off == 0, "viewed plan's belts run")
game.tick = game.tick + 60
click(P1, "leave")
on, off = asleep_ents(plan.id)
check(on == 0 and off > 0, "after leaving, the plan's belts are paused (" .. off .. ")")
check(storage.sleeping[plan.id], "plan marked asleep")
local fed = {}
for _, rec in pairs(storage.link_state[plan.id]) do for _, e in ipairs(rec.ents) do fed[e] = e.fed end end
for _ = 1, 5 do H["nth6"]({}) end
local fed_more = 0
for e, n in pairs(fed) do if e.fed ~= n then fed_more = fed_more + 1 end end
check(fed_more == 0, "the feeder leaves sleeping belts alone")

-- 5. Reopening wakes it.
H["ffp-toggle"]({ player_index = 1 })
click(P1, "open-plan", { plan = plan.id })
check(board.plan_of(P1) == plan, "reopened the plan")
on, off = asleep_ents(plan.id)
check(on > 0 and off == 0, "reopening wakes the belts")

-- 6. Only the 3 most recently viewed plans stay loaded.
local others = {}
for i = 1, 4 do
  others[i] = new_plan("Other " .. i)
  plan_lib.add_card(others[i], "iron-gear-wheel", "assembling-machine-2", layout.snap(0), layout.snap(0))
  board.resolve(others[i])
  board.draw(others[i])
end
game.tick = game.tick + 60
click(P1, "leave")
check(storage.render[plan.id] == nil and storage.link_state[plan.id] == nil, "the oldest plan is unloaded (no drawing, no belts)")
check(storage.render[others[1].id] == nil, "the next oldest is unloaded too")
local loaded = 0
for _, p in pairs(storage.plans) do if storage.render[p.id] then loaded = loaded + 1 end end
check(loaded == 3, "three plans stay loaded (" .. loaded .. ")")
H["ffp-toggle"]({ player_index = 1 })
click(P1, "open-plan", { plan = plan.id })
check(storage.render[plan.id] ~= nil and count(link_ents()) == #plan.wires, "opening an unloaded plan draws it again with its belts")
loaded = 0
for _, p in pairs(storage.plans) do if storage.render[p.id] then loaded = loaded + 1 end end
check(loaded == 3 and storage.render[others[2].id] == nil, "and the least recent loaded plan makes room (" .. loaded .. " loaded incl. the viewed one)")

if fails > 0 then error(fails .. " checks failed") end
