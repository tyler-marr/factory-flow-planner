-- Factory Flow Planner: an in-game flowchart planner.
-- Plans live in `storage` per force, so everyone on a team sees and edits the
-- same plans. Every change goes through `changed(plan)`, which re-solves,
-- redraws the board for everyone on it and refreshes their windows.

local plan_lib = require("scripts.plan")
local layout = require("scripts.layout")
local catalog = require("scripts.catalog")
local board = require("scripts.board")
local gui = require("scripts.gui")
local fmt = require("scripts.fmt")
local hints = require("scripts.hints")

local CODEC = {
  to_json = function(t) return helpers.table_to_json(t) end,
  from_json = function(s) return helpers.json_to_table(s) end,
  encode = function(s) return helpers.encode_string(s) end,
  decode = function(s) return helpers.decode_string(s) end,
}

-- ---------------------------------------------------------------------------
-- Change propagation

local function viewers(plan)
  local list = {}
  for _, p in pairs(game.players) do
    local s = storage.players[p.index]
    if s and s.on_board and s.plan_id == plan.id then list[#list + 1] = p end
  end
  return list
end

--- The hover popup and toolbar hint follow the hotspot under the cursor.
local function update_hover(player)
  local s = board.session(player.index)
  s.hint = nil
  local plan = board.plan_of(player)
  local e = player.selected
  if not (plan and s.on_board and e and e.valid and string.sub(e.name, 1, 8) == "ffp-hot-") then
    board.draw_hover(player, nil)
    return
  end
  local card, hit = board.pick(plan, e.position)
  if not (card and hit) then
    board.draw_hover(player, nil)
    return
  end
  local force = board.force_of(plan)
  local spec = catalog.spec(card, force)
  local geom
  for _, p in ipairs(layout.geometry(card, spec).parts) do
    if p.part == hit.part and p.res == hit.res then geom = p end
  end
  local h = hints.for_part(plan, card, hit, storage.results[plan.id], force)
  s.hint = hints.flat(h)
  local _, _, right = layout.box(card, spec)
  board.draw_hover(player, plan, card, geom, h, right)
end

local function refresh_player(player)
  board.draw_overlay(player)
  update_hover(player)
  gui.toolbar_update(player)
  gui.overview_update(player)
  gui.inspector_update(player)
end

-- How many of a team's plans stay loaded (drawn, with their belts) at once:
-- the most recently opened ones. Others are cleared off the board and redrawn
-- when next opened.
local KEEP_LOADED = 3

--- Wakes plans someone is viewing, puts the rest of the team's recent plans to
--- sleep (belts paused), and unloads plans beyond the KEEP_LOADED most recent.
local function balance_plans(force_index)
  local list = {}
  for _, plan in pairs(storage.plans) do
    if plan.force == force_index then list[#list + 1] = plan end
  end
  table.sort(list, function(a, b)
    local ta, tb = a.last_viewed or -1, b.last_viewed or -1
    if ta ~= tb then return ta > tb end
    return a.id < b.id
  end)
  for i, plan in ipairs(list) do
    local viewed = #viewers(plan) > 0
    if viewed then
      board.set_sleeping(plan.id, false)
    elseif i <= KEEP_LOADED then
      board.set_sleeping(plan.id, true)
    elseif storage.render[plan.id] then
      board.unload(plan.id)
    end
  end
end

local function changed(plan)
  board.resolve(plan)
  local watched = viewers(plan)
  if #watched == 0 then
    -- Nobody is looking: redraw when someone opens it.
    storage.stale = storage.stale or {}
    storage.stale[plan.id] = true
    gui.plans_update_force(plan.force)
    return
  end
  board.draw(plan)
  for _, p in ipairs(watched) do
    local s = board.session(p.index)
    if s.selected and not plan_lib.card(plan, s.selected) then s.selected = nil end
    if s.moving and not plan_lib.card(plan, s.moving) then s.moving = nil end
    if s.wire and not plan_lib.card(plan, s.wire.from) then s.wire = nil end
    refresh_player(p)
  end
  gui.plans_update_force(plan.force)
end

-- ---------------------------------------------------------------------------
-- Plan actions

local function new_plan(player, name)
  if not name or name == "" then name = "Plan " .. storage.next_plan_id end
  local plan = plan_lib.new(storage.next_plan_id, string.sub(name, 1, 100), player.force.index, player.name, game.tick)
  storage.next_plan_id = storage.next_plan_id + 1
  storage.plans[plan.id] = plan
  return plan
end

local function open_plan(player, plan)
  gui.plans_close(player)
  gui.string_close(player)
  plan.last_viewed = game.tick
  if storage.stale and storage.stale[plan.id] and storage.render[plan.id] then
    board.draw(plan) -- changed while nobody was looking
  end
  if storage.stale then storage.stale[plan.id] = nil end
  board.enter(player, plan)
  balance_plans(plan.force)
  refresh_player(player)
  gui.plans_update_force(plan.force)
end

local function leave(player)
  local plan = board.plan_of(player)
  gui.close_all(player)
  board.leave(player)
  if plan then
    plan.last_viewed = game.tick
    balance_plans(plan.force)
    gui.plans_update_force(plan.force)
  end
end

local function delete_plan(plan)
  for _, p in ipairs(viewers(plan)) do
    p.print("Factory Flow Planner: the plan \"" .. plan.name .. "\" was deleted.")
    leave(p)
  end
  board.destroy_plan_drawing(plan.id)
  storage.plans[plan.id] = nil
  if storage.stale then storage.stale[plan.id] = nil end
  gui.plans_update_force(plan.force)
end

--- Gives a first card a sensible target so the board shows numbers at once.
local function seed_target(plan, card)
  for _, c in ipairs(plan.cards) do
    if c.target then return end
  end
  local spec = catalog.spec(card, board.force_of(plan))
  if spec and spec.outputs[1] then
    card.target = { kind = "rate", product = spec.outputs[1].res, value = 1 }
  end
end

local function add_card(player, plan, recipe, x, y)
  local force = board.force_of(plan)
  local machine = catalog.default_machine(recipe, force)
  if not machine then
    player.print("Factory Flow Planner: no machine can make that recipe (it may be hand-craft only).")
    return nil
  end
  local probe = { recipe = recipe, machine = machine }
  local spec = catalog.spec(probe, force)
  if not spec then return nil end
  x, y = layout.free_spot(plan.cards, function(c) return catalog.spec(c, force) end, spec, x, y)
  local card = plan_lib.add_card(plan, recipe, machine, x, y)
  seed_target(plan, card)
  return card
end

-- ---------------------------------------------------------------------------
-- Card controls: the machine count, the machine, modules, beacons and rates.
-- Each one steps with the wheel, a click (+1) or a right-click (-1), like the
-- GTNH planner's card. Ctrl and Shift make the wheel's steps bigger.

local is_control, clear_port_restriction

local function card_result(plan, card)
  local r = storage.results[plan.id]
  return r and r.cards[card.id]
end

--- Machine count rule, as in the GTNH planner: Any -> Up to (what runs, rounded up)
--- -> a machine more or fewer -> below one, back to Any. Exactly keeps its rule.
local function step_count(plan, card, dir, mod)
  local t = card.target
  local cr = card_result(plan, card)
  local now = cr and cr.machines or 0
  if not t or t.kind == "rate" then
    card.target = { kind = "limit", value = math.max(1, math.ceil(now - 1e-6)) }
    return
  end
  local v = t.value
  if mod == "shift" then
    v = dir > 0 and v * 2 or v / 2
    v = math.floor(v + 0.5)
  else
    v = math.floor(v + 0.5) + dir * (mod == "ctrl" and 10 or 1)
  end
  if v < 1 then card.target = nil else t.value = v end
end

--- Click on the count cycles the rule: Any -> Up to -> Exactly -> Any.
local function cycle_count_rule(plan, card)
  local t = card.target
  local cr = card_result(plan, card)
  local n = math.max(1, math.ceil((cr and cr.machines or 0) - 1e-6))
  if not t or t.kind == "rate" then
    card.target = { kind = "limit", value = n }
  elseif t.kind == "limit" then
    card.target = { kind = "machines", value = t.value }
  else
    card.target = nil
  end
end

local function step_list(list, current, dir, allow_none)
  local idx = allow_none and 0 or 1
  for i, v in ipairs(list) do if v == current then idx = i end end
  idx = idx + dir
  local lo = allow_none and 0 or 1
  if idx < lo then idx = lo end
  if idx > #list then idx = #list end
  if idx == 0 then return nil end
  return list[idx]
end

--- One wheel notch on a rate, in the plan's shown time unit (per second, minute or hour).
local function rate_step(per_s, dir, mod)
  local factor = fmt.step_unit()
  local step = mod == "shift" and 100 or (mod == "ctrl" and 10 or 1)
  local shown = math.floor(per_s * factor + 0.5)
  return math.max(0, shown + dir * step) / factor
end

local CONTROLS = { count = true, machine = true, modules = true, beacons = true, out = true }

--- Parts of a card that the wheel steps (anything else under the wheel zooms).
function is_control(card, hit)
  if plan_lib.is_panel(card) then return hit.part == "in" or hit.part == "out" end
  return CONTROLS[hit.part] == true
end

--- Clears a rate restriction on a port: a recipe output's target rate, or a
--- panel item's Up to / Exactly. Returns true if there was one.
function clear_port_restriction(card, hit)
  if plan_lib.is_panel(card) then
    for _, it in ipairs(card.items or {}) do
      if it.res == hit.res and it.rule then
        it.rule, it.value = nil, nil
        return true
      end
    end
    return false
  end
  local t = card.target
  if hit.part == "out" and t and t.kind == "rate" and t.product == hit.res then
    card.target = nil
    return true
  end
  return false
end

--- Steps one card control. Returns true when something changed.
local function step_part(player, plan, card, hit, dir, mod)
  local force = board.force_of(plan)
  fmt.use(plan.units, catalog.transport_kit())
  local part = hit.part
  if plan_lib.is_panel(card) then
    if part ~= "in" and part ~= "out" then return false end
    local it = plan_lib.panel_item(card, hit.res)
    local cr = card_result(plan, card)
    local port = cr and (cr.inputs[hit.res] or cr.outputs[hit.res])
    local now = it.value or (port and port.rate) or 0
    local next_v = rate_step(now, dir, mod)
    if next_v <= 0 then
      it.rule, it.value = nil, nil
    else
      it.rule = it.rule or (card.kind == "source" and "upto" or "exact")
      it.value = next_v
    end
    return true
  end
  if part == "count" then
    step_count(plan, card, dir, mod)
    return true
  elseif part == "machine" then
    local names = {}
    for _, m in ipairs(catalog.machines_for(card.recipe)) do names[#names + 1] = m.name end
    local spec = catalog.spec(card, force)
    local nxt = step_list(names, spec and spec.machine, dir, false)
    if nxt and nxt ~= card.machine then card.machine = nxt; return true end
    return false
  elseif part == "modules" then
    local spec = catalog.spec(card, force)
    local options = catalog.module_options(card.recipe, spec and spec.machine)
    if #options == 0 then return false end
    local nxt = step_list(options, card.modules, dir, true)
    if nxt == card.modules then return false end
    card.modules = nxt
    return true
  elseif part == "beacons" then
    local spec = catalog.spec(card, force)
    if not (spec and spec.beacons_ok) then return false end
    local b = card.beacons or { count = 0 }
    if mod == "shift" then
      local options = catalog.beacon_module_options(card.recipe)
      local nxt = step_list(options, b.module, dir, false)
      if not nxt then return false end
      b.module = nxt
      if b.count == 0 then b.count = 1 end
    else
      b.count = math.max(0, math.min(64, (b.count or 0) + dir * (mod == "ctrl" and 4 or 1)))
      b.module = b.module or catalog.default_beacon_module(card.recipe)
      if not b.module then return false end
    end
    card.beacons = b.count > 0 and b or nil
    return true
  elseif part == "out" then
    local t = card.target
    local cr = card_result(plan, card)
    local now = (t and t.kind == "rate" and t.product == hit.res) and t.value
      or (cr and cr.outputs[hit.res] and cr.outputs[hit.res].rate) or 0
    local next_v = rate_step(now, dir, mod)
    if next_v <= 0 then
      if t and t.kind == "rate" and t.product == hit.res then card.target = nil end
    else
      card.target = { kind = "rate", product = hit.res, value = next_v }
    end
    return true
  end
  return false
end

-- ---------------------------------------------------------------------------
-- Board clicks and drags
--
-- On the board the player holds the board tool, so every press arrives as a
-- selection: a click is a selection that didn't move, a drag carries where it
-- started and ended. Without the tool (cursor cleared), plain clicks still work.

local CLICK_SLOP = 0.35 -- tiles a click may wander and still count as a click

--- Wires a port to a panel, adding the resource to the panel.
local function wire_to_panel(plan, card, hit, panel)
  if hit.part == "out" and panel.kind == "sink" then
    plan_lib.panel_item(panel, hit.res)
    plan_lib.add_wire(plan, card.id, panel.id, hit.res)
    return true
  elseif hit.part == "in" and panel.kind == "source" then
    plan_lib.panel_item(panel, hit.res)
    plan_lib.add_wire(plan, panel.id, card.id, hit.res)
    return true
  end
  return false
end

local function wire_between(player, plan, a, a_hit, b, b_hit)
  -- Either direction works: output -> input or input -> output.
  local from, to, res
  if a_hit.part == "out" and b_hit.part == "in" then
    from, to, res = a, b, a_hit.res
  elseif a_hit.part == "in" and b_hit.part == "out" then
    from, to, res = b, a, a_hit.res
  else
    return false
  end
  if a_hit.res ~= b_hit.res then
    -- Onto a panel, a new resource just becomes a new port.
    if plan_lib.is_panel(b) and wire_to_panel(plan, a, a_hit, b) then
      changed(plan)
      return true
    end
    player.create_local_flying_text({ text = "Those carry different things", create_at_cursor = true })
    return true
  end
  if from.id == to.id then return true end
  plan_lib.add_wire(plan, from.id, to.id, res)
  changed(plan)
  return true
end

local function board_click(player, plan, pos, right)
  local s = board.session(player.index)
  local card, hit, at = board.pick(plan, pos)

  if s.moving then
    local moved = plan_lib.card(plan, s.moving)
    s.moving = nil
    if moved then
      moved.x = layout.snap(at.x - (s.move_offset and s.move_offset.x or 0))
      moved.y = layout.snap(at.y - (s.move_offset and s.move_offset.y or 0))
      changed(plan)
    else
      refresh_player(player)
    end
    return
  end

  if s.wire then
    local from = s.wire
    s.wire = nil
    local src = plan_lib.card(plan, from.from)
    local src_hit = { part = "out", res = from.res }
    if src and card and hit and (hit.part == "in" or hit.part == "out") then
      if wire_between(player, plan, src, src_hit, card, hit) then return end
    elseif src and card and plan_lib.is_panel(card) then
      if wire_to_panel(plan, src, src_hit, card) then changed(plan); return end
    elseif src and not card then
      gui.picker_open(player, src.id, from.res, "use", at)
    end
    refresh_player(player)
    return
  end

  if not card then
    if s.selected then
      s.selected = nil
      refresh_player(player)
    end
    gui.picker_close(player)
    return
  end

  s.selected = card.id
  local part = hit.part
  if part == "count" then
    cycle_count_rule(plan, card)
    changed(plan)
    return
  elseif part == "machine" or part == "modules" or part == "beacons" then
    if step_part(player, plan, card, hit, 1, nil) then changed(plan) return end
  elseif part == "out" then
    s.wire = { from = card.id, res = hit.res }
  elseif part == "in" and not plan_lib.is_panel(card) then
    gui.picker_open(player, card.id, hit.res, "make")
  end
  refresh_player(player)
end

local function board_drag(player, plan, start, finish)
  local s = board.session(player.index)
  if s.moving or s.wire then return board_click(player, plan, finish) end
  local card, hit, a = board.pick(plan, start)
  if not card then return board_click(player, plan, start) end
  local target, thit, b = board.pick(plan, finish)

  if layout.is_card_part(hit.part) then
    card.x = layout.snap(card.x + (b.x - a.x))
    card.y = layout.snap(card.y + (b.y - a.y))
    s.selected = card.id
    changed(plan)
    return
  end
  -- Dragged from a port.
  s.selected = card.id
  if target and thit and (thit.part == "in" or thit.part == "out") then
    if not wire_between(player, plan, card, hit, target, thit) then
      player.create_local_flying_text({ text = "Drag from an output to an input", create_at_cursor = true })
      refresh_player(player)
    end
  elseif target and plan_lib.is_panel(target) then
    if wire_to_panel(plan, card, hit, target) then changed(plan) else refresh_player(player) end
  elseif not target then
    gui.picker_open(player, card.id, hit.res, hit.part == "out" and "use" or "make", b)
    refresh_player(player)
  else
    refresh_player(player)
  end
end

local function on_board_click(event, right)
  local player = game.get_player(event.player_index)
  if not player or not board.on_board(player) or event.in_gui then return end
  local plan = board.plan_of(player)
  if not plan then return end
  local s = board.session(player.index)

  if right then
    board.clear_preview(player)
    s.drag = nil
    if s.moving or s.wire then
      s.moving, s.wire = nil, nil
      refresh_player(player)
      return
    end
    local card, hit = board.pick(plan, event.cursor_position)
    if not (card and hit) then return end
    if hit.part == "in" or hit.part == "out" then
      -- A restriction set on this port (a target rate, or a panel item's
      -- Up to / Exactly) is cleared first; with none, right-click unlinks.
      if clear_port_restriction(card, hit) then
        changed(plan)
      elseif plan_lib.remove_port_wires(plan, card.id, hit.part, hit.res) > 0 then
        changed(plan)
      end
    elseif hit.part == "count" then
      card.target = nil
      changed(plan)
    elseif step_part(player, plan, card, hit, -1, nil) then
      changed(plan)
    end
    return
  end
  -- With the board tool in hand the selection events below handle the press.
  if board.holding_tool(player) then return end
  board_click(player, plan, event.cursor_position)
end

-- ---------------------------------------------------------------------------
-- The wheel. One notch may arrive as both a plain and a Ctrl/Shift input, so
-- notches are gathered for the tick and handled once, strongest modifier first.

local WHEEL = {
  ["ffp-wheel-up"] = { 1 }, ["ffp-wheel-down"] = { -1 },
  ["ffp-wheel-up-ctrl"] = { 1, "ctrl" }, ["ffp-wheel-down-ctrl"] = { -1, "ctrl" },
  ["ffp-wheel-up-shift"] = { 1, "shift" }, ["ffp-wheel-down-shift"] = { -1, "shift" },
}
local MOD_RANK = { shift = 2, ctrl = 1 }

local function on_wheel(e)
  local player = game.get_player(e.player_index)
  if not player or not board.on_board(player) or e.in_gui then return end
  local w = WHEEL[e.input_name]
  storage.wheel = storage.wheel or {}
  local pending = storage.wheel[player.index]
  if pending and pending.tick == e.tick then
    if (MOD_RANK[w[2]] or 0) > (MOD_RANK[pending.mod] or 0) then pending.mod = w[2] end
    return
  end
  storage.wheel[player.index] = { tick = e.tick, dir = w[1], mod = w[2], pos = e.cursor_position }
end

for name in pairs(WHEEL) do script.on_event(name, on_wheel) end

local function handle_wheel(player, w)
  local plan = board.plan_of(player)
  if not plan then return end
  local card, hit = board.pick(plan, w.pos)
  if card and hit and is_control(card, hit) then
    -- A control keeps the wheel even at the end of its range, so a long spin
    -- never turns into a zoom.
    if step_part(player, plan, card, hit, w.dir, w.mod) then changed(plan) end
    return
  end
  -- Not over a control: the board zooms.
  board.zoom_step(player, w.dir)
end

script.on_event(defines.events.on_tick, function(e)
  local pending = storage.wheel
  if not pending or next(pending) == nil then return end
  storage.wheel = {}
  for index, w in pairs(pending) do
    local player = game.get_player(index)
    if player and board.on_board(player) then handle_wheel(player, w) end
  end
end)

script.on_event("ffp-click", function(e) on_board_click(e, false) end)
script.on_event("ffp-right-click", function(e) on_board_click(e, true) end)

local function tool_event(e)
  if e.item ~= board.TOOL then return nil end
  local player = game.get_player(e.player_index)
  if not player or not board.on_board(player) then return nil end
  local plan = board.plan_of(player)
  if not plan then return nil end
  return player, plan
end

local function selection_finished(e)
  local player, plan = tool_event(e)
  if not player then return end
  board.clear_preview(player)
  board.session(player.index).drag = nil
  local start = e.position or e.area.left_top
  local finish = e.cursor_position or e.area.right_bottom
  local dx, dy = finish.x - start.x, finish.y - start.y
  if dx * dx + dy * dy <= CLICK_SLOP * CLICK_SLOP then
    board_click(player, plan, start)
  else
    board_drag(player, plan, start, finish)
  end
end

script.on_event(defines.events.on_player_selected_area, selection_finished)
script.on_event(defines.events.on_player_alt_selected_area, selection_finished)

-- Live preview while dragging (Factorio 2.1.22+).
if defines.events.on_player_start_selected_area then
  script.on_event(defines.events.on_player_start_selected_area, function(e)
    local player, plan = tool_event(e)
    if not player then return end
    local s = board.session(player.index)
    s.drag = nil
    if s.moving or s.wire then return end
    local card, hit, at = board.pick(plan, e.position or e.cursor_position)
    if card and hit and hit.part ~= "body" then
      s.drag = { card = card.id, part = hit.part, res = hit.res, start = at }
    end
  end)
  script.on_event(defines.events.on_player_change_selected_area, function(e)
    local player, plan = tool_event(e)
    if not player then return end
    local s = board.session(player.index)
    if not s.drag then return end
    local o = board.origin(plan)
    board.update_preview(player, plan, s.drag, { x = e.cursor_position.x - o.x, y = e.cursor_position.y - o.y })
  end)
  script.on_event(defines.events.on_player_cancel_selected_area, function(e)
    local player = tool_event(e)
    if not player then return end
    board.clear_preview(player)
    board.session(player.index).drag = nil
  end)
end

-- The overview fills the screen's height: follow resolution and UI scale changes.
local function on_display_changed(e)
  local player = game.get_player(e.player_index)
  if player and board.on_board(player) then gui.overview_update(player) end
end
script.on_event(defines.events.on_player_display_resolution_changed, on_display_changed)
script.on_event(defines.events.on_player_display_scale_changed, on_display_changed)

-- Keep the belts moving.
script.on_nth_tick(board.RUN_EVERY, function() board.run_belts() end)

script.on_event(defines.events.on_selected_entity_changed, function(e)
  local player = game.get_player(e.player_index)
  if not (player and board.on_board(player)) then return end
  update_hover(player)
  gui.toolbar_update(player)
end)

-- Keep the tool in hand on the board (Q clears the cursor).
script.on_event(defines.events.on_player_cursor_stack_changed, function(e)
  local player = game.get_player(e.player_index)
  if player and board.on_board(player) then board.give_tool(player) end
end)

-- The board floor: one flat tile instead of the lab checkerboard.
script.on_event(defines.events.on_chunk_generated, function(e)
  if e.surface.name == board.SURFACE then board.floor(e.surface, e.area) end
end)

-- ---------------------------------------------------------------------------
-- Toggle: shortcut and hotkey

local function toggle(player)
  if board.on_board(player) then
    leave(player)
  elseif player.gui.screen.ffp_plans then
    gui.plans_close(player)
  else
    gui.plans_open(player)
  end
end

script.on_event("ffp-toggle", function(e)
  local player = game.get_player(e.player_index)
  if player then toggle(player) end
end)

script.on_event(defines.events.on_lua_shortcut, function(e)
  if e.prototype_name ~= "ffp-shortcut" then return end
  local player = game.get_player(e.player_index)
  if player then toggle(player) end
end)

-- ---------------------------------------------------------------------------
-- GUI events

local function card_from_tags(player, tags)
  local plan = board.plan_of(player)
  return plan, plan and tags.card and plan_lib.card(plan, tags.card)
end

local function set_target_value(player, plan, card)
  local frame = player.gui.screen.ffp_inspector
  local tf
  if frame then
    -- The field sits a few flows deep; find it by name.
    local function find(el)
      if el.name == "ffp_target_value" then return el end
      for _, child in pairs(el.children) do
        local f = find(child)
        if f then return f end
      end
    end
    tf = find(frame)
  end
  local v = tf and fmt.parse(tf.text)
  if not (v and card.target) then return end
  fmt.use(plan.units, catalog.transport_kit())
  if card.target.kind == "rate" then
    card.target.value = v / (fmt.step_unit())
  else
    card.target.value = v
  end
  changed(plan)
end

local CLICK = {}

CLICK["close-plans"] = function(player) gui.plans_close(player) end
CLICK["close-string"] = function(player) gui.string_close(player) end
CLICK["close-picker"] = function(player) gui.picker_close(player) end
CLICK["close-inspector"] = function(player)
  board.session(player.index).selected = nil
  refresh_player(player)
end
CLICK["plans"] = function(player) gui.plans_open(player) end
CLICK["leave"] = function(player) leave(player) end

CLICK["new-plan"] = function(player, el)
  local field = el.parent.new_name
  local plan = new_plan(player, field and field.text or "")
  gui.plans_update_force(player.force.index)
  open_plan(player, plan)
end

CLICK["open-plan"] = function(player, _, tags)
  local plan = storage.plans[tags.plan]
  if plan and plan.force == player.force.index then open_plan(player, plan) end
end

CLICK["delete-plan"] = function(player, _, tags)
  board.session(player.index).confirm_delete = tags.plan
  gui.plans_update(player)
end

CLICK["delete-plan-confirm"] = function(player, _, tags)
  board.session(player.index).confirm_delete = nil
  local plan = storage.plans[tags.plan]
  if plan and plan.force == player.force.index then delete_plan(plan) end
end

CLICK["export-plan"] = function(player, _, tags)
  local plan = storage.plans[tags.plan]
  if plan then gui.string_open(player, "export", plan_lib.to_string(plan, CODEC)) end
end

CLICK["export-current"] = function(player)
  local plan = board.plan_of(player)
  if plan then gui.string_open(player, "export", plan_lib.to_string(plan, CODEC)) end
end

CLICK["import-open"] = function(player) gui.string_open(player, "import", "") end

CLICK["import-do"] = function(player, el)
  local frame = player.gui.screen.ffp_string
  local text = frame and frame.box.text or ""
  local plan, err, dropped = plan_lib.from_string(text, CODEC, catalog.recipe_exists,
    storage.next_plan_id, player.force.index, player.name, game.tick)
  if not plan then
    player.print("Factory Flow Planner: that is not a Factory Flow Planner string (" .. tostring(err) .. ").")
    return
  end
  storage.next_plan_id = storage.next_plan_id + 1
  storage.plans[plan.id] = plan
  if dropped > 0 then
    player.print("Factory Flow Planner: " .. dropped .. " card(s) used recipes this game doesn't have and were left out.")
  end
  gui.string_close(player)
  open_plan(player, plan)
end

CLICK["move-card"] = function(player, _, tags)
  local plan, card = card_from_tags(player, tags)
  if not card then return end
  local s = board.session(player.index)
  s.moving = card.id
  s.move_offset = { x = 0, y = 0 }
  refresh_player(player)
end

CLICK["unwire-card"] = function(player, _, tags)
  local plan, card = card_from_tags(player, tags)
  if not card then return end
  for i = #plan.wires, 1, -1 do
    local w = plan.wires[i]
    if w.from == card.id or w.to == card.id then table.remove(plan.wires, i) end
  end
  changed(plan)
end

CLICK["delete-card"] = function(player, _, tags)
  local plan, card = card_from_tags(player, tags)
  if not card then return end
  plan_lib.remove_card(plan, card.id)
  board.session(player.index).selected = nil
  changed(plan)
end

CLICK["target-set"] = function(player, _, tags)
  local plan, card = card_from_tags(player, tags)
  if card then set_target_value(player, plan, card) end
end

CLICK["pick"] = function(player, _, tags)
  local plan, anchor = card_from_tags(player, tags)
  gui.picker_close(player)
  if not (plan and anchor) then return end
  local force = board.force_of(plan)
  local aspec = catalog.spec(anchor, force)
  local use = tags.mode == "use"
  local _, py = layout.port_point(anchor, aspec, use and "out" or "in", tags.res)
  local x, y
  if use then
    x, y = anchor.x + layout.CARD_W + 5, (py or anchor.y) - layout.HEADER_H - 0.5
    if tags.drop_x then x, y = tags.drop_x, tags.drop_y - layout.HEADER_H - 0.5 end
  else
    x, y = anchor.x - layout.CARD_W - 5, (py or anchor.y) - layout.HEADER_H - 0.5
    if tags.drop_x then x, y = tags.drop_x - layout.CARD_W, tags.drop_y - layout.HEADER_H - 0.5 end
  end
  local card
  if tags.panel then
    local probe = { kind = tags.panel, items = { { res = tags.res } } }
    x, y = layout.free_spot(plan.cards, function(c) return catalog.spec(c, force) end, catalog.spec(probe, force), x, y)
    card = plan_lib.add_panel(plan, tags.panel, x, y)
    plan_lib.panel_item(card, tags.res)
  else
    card = add_card(player, plan, tags.recipe, x, y)
  end
  if card then
    if use then
      plan_lib.add_wire(plan, anchor.id, card.id, tags.res)
    else
      plan_lib.add_wire(plan, card.id, anchor.id, tags.res)
    end
    board.session(player.index).selected = card.id
  end
  changed(plan)
end

CLICK["overview-toggle"] = function(player, _, tags)
  local s = board.session(player.index)
  s.overview_collapsed = s.overview_collapsed or {}
  local open = s.overview_collapsed[tags.key]
  if open == nil then open = tags.key == "internal" end
  s.overview_collapsed[tags.key] = not open
  gui.overview_update(player)
end

--- Selects a card and moves the view to it.
CLICK["focus-card"] = function(player, _, tags)
  local plan, card = card_from_tags(player, tags)
  if not card then return end
  local spec = catalog.spec(card, board.force_of(plan))
  local l, t, r, b = layout.box(card, spec)
  local o = board.origin(plan)
  player.teleport({ x = o.x + (l + r) / 2, y = o.y + (t + b) / 2 }, board.surface())
  board.session(player.index).selected = card.id
  refresh_player(player)
end

CLICK["toggle-links"] = function(player)
  local plan = board.plan_of(player)
  if not plan then return end
  plan.links = plan.links == "lines" and "belts" or "lines"
  changed(plan)
end

CLICK["add-panel"] = function(player, _, tags)
  local plan = board.plan_of(player)
  if not plan then return end
  local force = board.force_of(plan)
  local o = board.origin(plan)
  local probe = { kind = tags.kind, items = {} }
  local x, y = layout.free_spot(plan.cards, function(c) return catalog.spec(c, force) end, catalog.spec(probe, force),
    player.position.x - o.x - layout.CARD_W / 2, player.position.y - o.y - 2)
  local card = plan_lib.add_panel(plan, tags.kind, x, y)
  board.session(player.index).selected = card.id
  changed(plan)
end

CLICK["panel-remove"] = function(player, _, tags)
  local plan, card = card_from_tags(player, tags)
  local it = card and card.items and card.items[tags.item]
  if not it then return end
  plan_lib.remove_panel_item(plan, card, it.res)
  changed(plan)
end

script.on_event(defines.events.on_gui_click, function(e)
  local el = e.element
  if not (el and el.valid) then return end
  local action = el.tags and el.tags.ffp
  local handler = action and CLICK[action]
  if not handler then return end
  local player = game.get_player(e.player_index)
  if player then handler(player, el, el.tags) end
end)

script.on_event(defines.events.on_gui_confirmed, function(e)
  local el = e.element
  if not (el and el.valid and el.tags and el.tags.ffp) then return end
  local player = game.get_player(e.player_index)
  if not player then return end
  if el.tags.ffp == "panel-value" then
    local plan, card = card_from_tags(player, el.tags)
    local it = card and card.items and card.items[el.tags.item]
    local v = fmt.parse(el.text)
    if it and v then
      fmt.use(plan.units, catalog.transport_kit())
      it.value = v / (fmt.step_unit())
      if v == 0 then it.rule, it.value = nil, nil end
      changed(plan)
    end
  elseif el.tags.ffp == "target-value" then
    local plan, card = card_from_tags(player, el.tags)
    if card then set_target_value(player, plan, card) end
  elseif el.tags.ffp == "new-name" then
    CLICK["new-plan"](player, el, {})
  end
end)

script.on_event(defines.events.on_gui_elem_changed, function(e)
  local el = e.element
  if not (el and el.valid and el.tags and el.tags.ffp == "add-recipe") then return end
  local player = game.get_player(e.player_index)
  local recipe = el.elem_value
  el.elem_value = nil
  if not (player and recipe and board.on_board(player)) then return end
  local plan = board.plan_of(player)
  if not plan then return end
  local o = board.origin(plan)
  local card = add_card(player, plan, recipe, player.position.x - o.x - layout.CARD_W / 2, player.position.y - o.y - 2)
  if card then board.session(player.index).selected = card.id end
  changed(plan)
end)

script.on_event(defines.events.on_gui_selection_state_changed, function(e)
  local el = e.element
  if not (el and el.valid and el.tags and el.tags.ffp) then return end
  local player = game.get_player(e.player_index)
  if not player then return end
  if el.tags.ffp == "units" then
    local plan = board.plan_of(player)
    if not plan then return end
    local keys = fmt.unit_options(catalog.transport_kit())
    plan.units = keys[el.selected_index] or "min"
    changed(plan)
    return
  end
  local plan, card = card_from_tags(player, el.tags)
  if not card then return end
  local action, i = el.tags.ffp, el.selected_index
  local force = board.force_of(plan)
  if action == "machine" then
    local m = catalog.machines_for(card.recipe)[i]
    if m then card.machine = m.name end
  elseif action == "target-kind" then
    local result = (storage.results[plan.id] or { cards = {} }).cards[card.id]
    local spec = catalog.spec(card, force)
    if i == 1 then
      card.target = nil
    elseif i == 2 and spec and spec.outputs[1] then
      local res = spec.outputs[1].res
      local now = result and result.outputs[res] and result.outputs[res].rate or 0
      card.target = { kind = "rate", product = res, value = now > 0 and now or 1 }
    elseif i == 3 or i == 4 then
      local now = result and result.machines or 0
      card.target = { kind = i == 3 and "machines" or "limit", value = now > 0 and math.ceil(now - 1e-6) or 1 }
    end
  elseif action == "modules" then
    local spec = catalog.spec(card, force)
    card.modules = catalog.module_options(card.recipe, spec and spec.machine)[i - 1]
  elseif action == "beacon-count" then
    local n = i - 1
    if n == 0 then
      card.beacons = nil
    else
      card.beacons = card.beacons or {}
      card.beacons.count = n
      card.beacons.module = card.beacons.module or catalog.default_beacon_module(card.recipe)
    end
  elseif action == "beacon-module" then
    local m = catalog.beacon_module_options(card.recipe)[i]
    card.beacons = card.beacons or { count = 1 }
    card.beacons.module = m
  elseif action == "panel-rule" then
    local it = card.items and card.items[el.tags.item]
    if not it then return end
    local result = (storage.results[plan.id] or { cards = {} }).cards[card.id]
    local port = result and (result.inputs[it.res] or result.outputs[it.res])
    if i == 1 then
      it.rule, it.value = nil, nil
    else
      it.rule = i == 2 and "upto" or "exact"
      it.value = it.value or (port and port.rate and port.rate > 0 and port.rate) or 1
    end
  elseif action == "target-product" then
    local spec = catalog.spec(card, force)
    local p = spec and spec.outputs[i]
    if p and card.target then card.target.product = p.res end
  else
    return
  end
  changed(plan)
end)

script.on_event(defines.events.on_gui_closed, function(e)
  local el = e.element
  if not (el and el.valid) then return end
  if el.name == "ffp_plans" or el.name == "ffp_string" then el.destroy() end
end)

-- ---------------------------------------------------------------------------
-- Lifecycle

script.on_init(function()
  board.init_storage()
end)

script.on_configuration_changed(function()
  board.init_storage()
  board.floor_all()
  -- Windows saved by an older version may lack newer elements: close them all;
  -- the toolbar and inspector are rebuilt below for players on the board.
  for _, p in pairs(game.players) do
    gui.close_all(p)
    gui.plans_close(p)
    gui.string_close(p)
  end
  -- Belts, pipes, drawings and routes are rebuilt from scratch: an older
  -- version may have laid them differently, and the mod list may have changed
  -- what belts exist. Plans nobody is viewing are unloaded until next opened.
  for _, ents in pairs(storage.link_ents or {}) do
    for _, e in ipairs(ents) do if e.valid then e.destroy() end end
  end
  storage.link_ents, storage.link_sig, storage.link_runs = nil, nil, nil
  for pid in pairs(storage.plans) do board.unload(pid) end
  storage.route_cache = {}
  -- Recipes or machines may have changed with the mod list: re-solve and redraw
  -- everything. Cards go onto whole tiles so belts and pipes line up with ports.
  for _, plan in pairs(storage.plans) do
    for _, c in ipairs(plan.cards) do
      c.x, c.y = layout.snap(c.x), layout.snap(c.y)
    end
    board.resolve(plan)
    if #viewers(plan) > 0 then board.draw(plan) end
  end
  for _, p in pairs(game.players) do
    if board.on_board(p) then
      board.refresh_hud(p)
      refresh_player(p)
    end
  end
  for _, force in pairs(game.forces) do balance_plans(force.index) end
end)

-- Research changes productivity bonuses.
script.on_event(defines.events.on_research_finished, function(e)
  local force = e.research.force
  for _, plan in pairs(storage.plans) do
    if plan.force == force.index and #plan.cards > 0 then changed(plan) end
  end
end)

-- Never leave someone stranded on the board.
script.on_event(defines.events.on_pre_player_left_game, function(e)
  local player = game.get_player(e.player_index)
  if player and board.session(player.index).on_board then leave(player) end
end)

script.on_event(defines.events.on_player_changed_surface, function(e)
  local player = game.get_player(e.player_index)
  if not player then return end
  local s = board.session(player.index)
  if s.on_board and player.surface.name ~= board.SURFACE then
    -- Something else moved them off the board: put them back in their character.
    leave(player)
  end
end)

script.on_event(defines.events.on_player_removed, function(e)
  storage.players[e.player_index] = nil
end)
