-- Window builders. They only draw from storage; every click is handled in
-- control.lua, which changes the data and calls back into these to redraw.

local catalog = require("scripts.catalog")
local plan_lib = require("scripts.plan")
local fmt = require("scripts.fmt")
local board = require("scripts.board")

local gui = {}

local OVERVIEW_W = 290

-- Bumped whenever a window gains or loses elements, so ones kept in a save
-- from an older version are rebuilt instead of read.
gui.VERSION = 10

local function titlebar(frame, caption, close_action)
  local bar = frame.add({ type = "flow", direction = "horizontal" })
  bar.drag_target = frame
  bar.add({ type = "label", caption = caption, style = "frame_title", ignored_by_interaction = true })
  local filler = bar.add({ type = "empty-widget", style = "draggable_space_header", ignored_by_interaction = true })
  filler.style.horizontally_stretchable = true
  filler.style.height = 24
  filler.style.right_margin = 4
  bar.add({
    type = "sprite-button", style = "frame_action_button", sprite = "utility/close",
    tooltip = "Close", tags = { ffp = close_action },
  })
  return bar
end

local function destroy(root, name)
  local el = root[name]
  if el and el.valid then el.destroy() end
end

-- ---------------------------------------------------------------------------
-- Plans window: every plan of the player's force.

function gui.plans_open(player)
  destroy(player.gui.screen, "ffp_plans")
  local frame = player.gui.screen.add({ type = "frame", name = "ffp_plans", direction = "vertical" })
  titlebar(frame, "Factory Flow Planner plans", "close-plans")
  local inner = frame.add({ type = "frame", name = "inner", style = "inside_shallow_frame_with_padding", direction = "vertical" })
  inner.add({ type = "label", caption = "Plans are shared with everyone on your team.", style = "label" })
  local scroll = inner.add({ type = "scroll-pane", name = "scroll" })
  scroll.style.maximal_height = 420
  scroll.style.minimal_width = 520
  scroll.style.top_margin = 8
  scroll.add({ type = "table", name = "list", column_count = 5 })

  local foot = frame.add({ type = "flow", name = "foot", direction = "horizontal" })
  foot.style.top_margin = 8
  foot.style.vertical_align = "center"
  local name = foot.add({ type = "textfield", name = "new_name", text = "", tooltip = "Name for a new plan", tags = { ffp = "new-name" } })
  name.style.width = 220
  foot.add({ type = "button", caption = "New plan", style = "confirm_button_without_tooltip", tags = { ffp = "new-plan" } })
  local pad = foot.add({ type = "empty-widget" })
  pad.style.horizontally_stretchable = true
  foot.add({ type = "button", caption = "Import string", tags = { ffp = "import-open" } })

  frame.force_auto_center()
  player.opened = frame
  gui.plans_update(player)
end

function gui.plans_update(player)
  local frame = player.gui.screen.ffp_plans
  if not (frame and frame.valid) then return end
  local list = frame.inner.scroll.list
  list.clear()
  local viewers = {}
  for _, p in pairs(game.players) do
    local s = storage.players[p.index]
    if s and s.on_board and s.plan_id then viewers[s.plan_id] = (viewers[s.plan_id] or 0) + 1 end
  end
  local session = board.session(player.index)
  local plans = {}
  for _, plan in pairs(storage.plans) do
    if plan.force == player.force.index then plans[#plans + 1] = plan end
  end
  table.sort(plans, function(a, b) return a.id < b.id end)
  if #plans == 0 then
    list.add({ type = "label", caption = "No plans yet. Name one below and press New plan." })
    return
  end
  for _, plan in ipairs(plans) do
    local name = list.add({ type = "label", caption = plan.name, style = "bold_label" })
    name.style.minimal_width = 200
    local who = viewers[plan.id] and (" · " .. viewers[plan.id] .. " on it now") or ""
    list.add({ type = "label", caption = #plan.cards .. " cards · by " .. (plan.author or "?") .. who, style = "label" })
    list.add({ type = "button", caption = "Open", tags = { ffp = "open-plan", plan = plan.id } })
    list.add({ type = "button", caption = "Export", tags = { ffp = "export-plan", plan = plan.id } })
    if session.confirm_delete == plan.id then
      list.add({ type = "button", caption = "Really delete?", style = "red_button", tags = { ffp = "delete-plan-confirm", plan = plan.id } })
    else
      list.add({ type = "sprite-button", sprite = "utility/trash", style = "tool_button_red", tooltip = "Delete plan for everyone", tags = { ffp = "delete-plan", plan = plan.id } })
    end
  end
end

function gui.plans_update_force(force_index)
  for _, p in pairs(game.players) do
    if p.force.index == force_index then gui.plans_update(p) end
  end
end

function gui.plans_close(player)
  destroy(player.gui.screen, "ffp_plans")
end

-- ---------------------------------------------------------------------------
-- String window: export (read only) or import.

function gui.string_open(player, mode, text)
  destroy(player.gui.screen, "ffp_string")
  local frame = player.gui.screen.add({ type = "frame", name = "ffp_string", direction = "vertical" })
  titlebar(frame, mode == "import" and "Import plan" or "Export plan", "close-string")
  frame.add({
    type = "label",
    caption = mode == "import" and "Paste a Factory Flow Planner string. It opens as a new plan."
      or "Copy this string (Ctrl+C) and share it. Anyone with the mod can import it.",
  })
  local box = frame.add({ type = "text-box", name = "box", text = text or "" })
  box.style.width = 480
  box.style.height = 160
  box.word_wrap = true
  if mode == "import" then
    local row = frame.add({ type = "flow", direction = "horizontal" })
    local pad = row.add({ type = "empty-widget" })
    pad.style.horizontally_stretchable = true
    row.add({ type = "button", caption = "Import", style = "confirm_button_without_tooltip", tags = { ffp = "import-do" } })
  else
    box.read_only = true
    box.select_all()
  end
  box.focus()
  frame.force_auto_center()
  player.opened = frame
end

function gui.string_close(player)
  destroy(player.gui.screen, "ffp_string")
end

-- ---------------------------------------------------------------------------
-- Toolbar: shown at the top while on the board.

--- The old top toolbar is gone; its controls live in the overview. This only
--- clears one left in a save from an older version.
function gui.toolbar_update(player)
  destroy(player.gui.top, "ffp_toolbar")
end

--- A short message for the top of the overview, only when there is something to say.
local function board_message(plan, s)
  local result = storage.results[plan.id] or {}
  if s.moving then return "Click where the card should go. Right-click cancels." end
  if s.wire then return "Click a matching input, or empty space to add a user. Right-click cancels." end
  if #plan.cards == 0 then return "Pick a recipe above to start, or add a supply or output panel." end
  if result.status == "no_target" then return "Give a card a target: scroll over an output's rate, or select it and set one." end
  if result.status and result.status ~= "optimal" then
    return "[color=1,0.4,0.35]This plan can't be balanced (" .. result.status .. "). Check targets that fight each other.[/color]"
  end
  return nil
end

--- The controls along the top of the overview: everything the toolbar had.
local function overview_controls(head, plan, s)
  head.clear()
  local title = head.add({ type = "flow", direction = "horizontal" })
  title.style.vertical_align = "center"
  local name = title.add({ type = "label", caption = plan.name, style = "frame_title" })
  name.style.horizontally_stretchable = true
  name.style.maximal_width = 200
  local pad = title.add({ type = "empty-widget" })
  pad.style.horizontally_stretchable = true
  title.add({ type = "sprite-button", sprite = "utility/close", style = "tool_button_red",
    tooltip = "Back to the game", tags = { ffp = "leave" } })

  local row = head.add({ type = "flow", direction = "horizontal" })
  row.style.vertical_align = "center"
  row.style.horizontal_spacing = 4
  row.add({
    type = "choose-elem-button", name = "add_recipe", elem_type = "recipe",
    elem_filters = { { filter = "hidden", invert = true } }, style = "slot_button",
    tooltip = "Add a recipe: pick one to put its card where you are looking", tags = { ffp = "add-recipe" },
  })
  local function tool(sprite, tooltip, tags)
    local b = row.add({ type = "sprite-button", sprite = sprite, style = "tool_button", tooltip = tooltip, tags = tags })
    b.style.size = 36
    return b
  end
  tool("utility/import_slot", "Add a supply panel: things that come in from outside the plan", { ffp = "add-panel", kind = "source" })
  tool("utility/export_slot", "Add an output panel: things that leave the plan", { ffp = "add-panel", kind = "sink" })
  local belts = plan.links ~= "lines"
  tool(belts and "entity/transport-belt" or "utility/go_to_arrow",
    belts and "Links are belts and pipes. Click for plain lines." or "Links are plain lines. Click for belts and pipes.",
    { ffp = "toggle-links" })
  tool("utility/list_view", "Plans: open, import or delete", { ffp = "plans" })
  tool("utility/export", "Export this plan as a string to share", { ffp = "export-current" })

  local urow = head.add({ type = "flow", direction = "horizontal" })
  urow.style.vertical_align = "center"
  urow.style.top_margin = 4
  urow.add({ type = "label", caption = "Show rates as" })
  local keys, labels = fmt.unit_options(catalog.transport_kit())
  local sel = 2
  for i, k in ipairs(keys) do if k == (plan.units or "min") then sel = i end end
  local dd = urow.add({ type = "drop-down", items = labels, selected_index = sel, tags = { ffp = "units" },
    tooltip = "How rates are shown on the board and here, for everyone on this plan" })
  dd.style.width = 190

  local msg = board_message(plan, s)
  if msg then
    local l = head.add({ type = "label", caption = msg })
    l.style.single_line = false
    l.style.maximal_width = OVERVIEW_W
    l.style.font_color = { 1, 0.85, 0.5 }
  end
end

-- ---------------------------------------------------------------------------
-- Overview: the plan's summary down the left side, as the GTNH planner's.
-- Inputs, outputs, what's short, internal flows and every machine to build.


local COLLAPSED_DEFAULT = { internal = true }

local function collapsed(s, key)
  s.overview_collapsed = s.overview_collapsed or {}
  local v = s.overview_collapsed[key]
  if v == nil then return COLLAPSED_DEFAULT[key] == true end
  return v
end

local function section(parent, s, key, title, count, right)
  local head = parent.add({ type = "frame", style = "subheader_frame", direction = "horizontal" })
  head.style.horizontally_stretchable = true
  head.style.top_margin = 4
  local arrow = collapsed(s, key) and "[img=utility/expand]" or "[img=utility/collapse]"
  local l = head.add({ type = "label", style = "subheader_caption_label",
    caption = arrow .. " " .. title .. "  [color=0.6,0.6,0.6]" .. count .. "[/color]",
    tags = { ffp = "overview-toggle", key = key }, tooltip = "Show or hide" })
  l.style.horizontally_stretchable = true
  if right then head.add({ type = "label", caption = right }).style.right_margin = 6 end
  if collapsed(s, key) then return nil end
  local body = parent.add({ type = "table", column_count = 3 })
  body.style.left_margin = 8
  body.style.horizontal_spacing = 6
  body.style.column_alignments[3] = "right"
  return body
end

local function sorted_keys(map)
  local keys = {}
  for k in pairs(map or {}) do keys[#keys + 1] = k end
  table.sort(keys)
  return keys
end

local function item_rows(body, map, color)
  for _, res in ipairs(sorted_keys(map)) do
    local icon = body.add({ type = "sprite", sprite = catalog.sprite(res) })
    icon.style.width, icon.style.height, icon.style.stretch_image_to_widget_size = 24, 24, true
    local name = body.add({ type = "label", caption = catalog.res_name(res) })
    name.style.width = 150
    local rate = body.add({ type = "label", caption = fmt.rate(map[res], res), style = "bold_label" })
    if color then rate.style.font_color = color end
  end
end

function gui.overview_update(player)
  local plan = board.plan_of(player)
  if plan then fmt.use(plan.units, catalog.transport_kit()) end
  local s = board.session(player.index)
  destroy(player.gui.left, "ffp_overview") -- where older versions put it
  local frame = player.gui.screen.ffp_overview
  if frame and frame.valid and (frame.tags or {}).ffp_v ~= gui.VERSION then frame.destroy(); frame = nil end
  if not (plan and s.on_board) then
    if frame and frame.valid then frame.destroy() end
    return
  end
  -- Keep the frame and refill its scroll pane, so the scroll position stays put.
  local scroll
  if frame and frame.valid then
    scroll = frame.inner.scroll
    scroll.clear()
  else
    -- Pinned to the left edge, the full height of the screen. Only the list
    -- inside scrolls; the controls at the top stay put.
    frame = player.gui.screen.add({ type = "frame", name = "ffp_overview", direction = "vertical", tags = { ffp_v = gui.VERSION } })
    frame.style.width = OVERVIEW_W + 24
    frame.style.horizontally_stretchable = false
    local head = frame.add({ type = "flow", name = "head", direction = "vertical" })
    head.style.bottom_margin = 6
    local inner = frame.add({ type = "frame", name = "inner", style = "inside_deep_frame", direction = "vertical" })
    inner.style.horizontally_stretchable = false
    inner.style.vertically_stretchable = true
    scroll = inner.add({ type = "scroll-pane", name = "scroll", direction = "vertical",
      horizontal_scroll_policy = "never", vertical_scroll_policy = "auto-and-reserve-space" })
    scroll.style.width = OVERVIEW_W
    scroll.style.vertically_stretchable = true
  end
  overview_controls(frame.head, plan, s)
  local res = player.display_resolution
  frame.style.height = math.floor(res.height / player.display_scale)
  frame.location = { x = 0, y = 0 }

  local result = storage.results[plan.id] or { cards = {}, wires = {} }
  local force = board.force_of(plan)

  -- Machines, grouped by machine type.
  local groups, order, total_build = {}, {}, 0
  for _, c in ipairs(plan.cards) do
    local cr = result.cards[c.id]
    if not plan_lib.is_panel(c) and cr then
      local spec = catalog.spec(c, force)
      if spec then
        local g = groups[spec.machine]
        if not g then
          g = { machine = spec.machine, build = 0, power = 0, cards = {} }
          groups[spec.machine] = g
          order[#order + 1] = g
        end
        local build = math.ceil((cr.machines or 0) - 1e-6)
        g.build = g.build + build
        g.power = g.power + (cr.power_w or 0)
        total_build = total_build + build
        table.insert(g.cards, { card = c, cr = cr, build = build })
      end
    end
  end
  table.sort(order, function(a, b) return a.build > b.build or (a.build == b.build and a.machine < b.machine) end)

  -- Totals.
  local top = scroll.add({ type = "flow", direction = "vertical" })
  top.style.left_margin = 8
  top.style.top_margin = 4
  top.add({ type = "label", caption = "[img=utility/status_working] Power " .. fmt.power(result.power_w or 0), style = "bold_label" })
  top.add({ type = "label", caption = "Machines to build " .. total_build, style = "bold_label" })

  local count = function(map) return #sorted_keys(map) end
  local body = section(scroll, s, "inputs", "Inputs", count(result.imports))
  if body then item_rows(body, result.imports, { 1, 0.7, 0.35 }) end
  body = section(scroll, s, "outputs", "Outputs", count(result.products) + count(result.surplus))
  if body then
    item_rows(body, result.products, { 0.45, 0.9, 0.45 })
    if next(result.surplus or {}) then
      local spare = {}
      for k, v in pairs(result.surplus) do spare[k] = v end
      item_rows(body, spare, { 0.95, 0.85, 0.35 })
    end
  end
  if next(result.shortfall or {}) then
    body = section(scroll, s, "short", "[color=1,0.4,0.35]Short[/color]", count(result.shortfall))
    if body then item_rows(body, result.shortfall, { 1, 0.4, 0.35 }) end
  end
  -- Internal: what flows along the plan's own links.
  local internal = {}
  for _, w in ipairs(plan.wires) do
    local f = result.wires[w.id]
    if f and f > 1e-9 then internal[w.res] = (internal[w.res] or 0) + f end
  end
  body = section(scroll, s, "internal", "Internal", count(internal))
  if body then item_rows(body, internal) end

  -- Machines: each type with the cards that use it. Click a card to go to it.
  local mhead = section(scroll, s, "machines", "Machines", #order, fmt.power(result.power_w or 0))
  if mhead then
    mhead.destroy()
    for _, g in ipairs(order) do
      local ent = prototypes.entity[g.machine]
      local row = scroll.add({ type = "flow", direction = "horizontal" })
      row.style.left_margin = 8
      row.style.top_margin = 4
      row.style.vertical_align = "center"
      local icon = row.add({ type = "sprite", sprite = "entity/" .. g.machine })
      icon.style.width, icon.style.height, icon.style.stretch_image_to_widget_size = 28, 28, true
      local name = row.add({ type = "label", caption = ent and ent.localised_name or g.machine, style = "bold_label" })
      name.style.width = 128
      row.add({ type = "label", caption = "×" .. g.build, style = "bold_label", tooltip = "Machines to build" }).style.width = 40
      local pw = row.add({ type = "label", caption = fmt.power(g.power) })
      pw.style.width = 56
      pw.style.horizontal_align = "right"
      table.sort(g.cards, function(a, b) return a.cr.machines > b.cr.machines end)
      for _, e in ipairs(g.cards) do
        local proto = catalog.recipe(e.card.recipe)
        local t = e.card.target
        local rule = t and t.kind == "limit" and ("  up to " .. fmt.count(t.value))
          or t and t.kind == "machines" and ("  exactly " .. fmt.count(t.value)) or ""
        local b = scroll.add({
          type = "button", style = "list_box_item",
          caption = { "", "[recipe=" .. e.card.recipe .. "] ", proto and proto.localised_name or e.card.recipe,
            "   [font=default-bold]×" .. fmt.count(e.cr.machines) .. "[/font]" .. rule },
          tooltip = "Go to this card", tags = { ffp = "focus-card", card = e.card.id },
        })
        b.style.width = OVERVIEW_W - 44
        b.style.left_margin = 24
        if s.selected == e.card.id then b.style.font_color = { 1, 0.8, 0.3 } end
      end
    end
  end
end

-- ---------------------------------------------------------------------------
-- Inspector: the selected card.

local function target_kinds()
  local _, word = fmt.step_unit()
  return { "None (driven by wires)", "Output rate (per " .. word .. ")", "Exactly N machines", "Up to N machines" }
end
local TARGET_INDEX = { rate = 2, machines = 3, limit = 4 }
local function rules_list()
  local _, word = fmt.step_unit()
  return { "Any amount", "Up to (per " .. word .. ")", "Exactly (per " .. word .. ")" }
end
local RULE_INDEX = { upto = 2, exact = 3 }

local function row(parent, caption)
  local r = parent.add({ type = "flow", direction = "horizontal" })
  r.style.vertical_align = "center"
  r.style.top_margin = 6
  r.add({ type = "label", caption = caption }).style.width = 90
  return r
end

local function panel_inspector(inner, plan, card)
  local result = (storage.results[plan.id] or { cards = {} }).cards[card.id]
  inner.add({ type = "label", caption = card.kind == "source"
    and "Things that come in from outside the plan. Drag an input onto this panel to add one."
    or "Things that leave the plan. Drag an output onto this panel to add one.", style = "label" }).style.single_line = false
  if #(card.items or {}) == 0 then
    inner.add({ type = "label", caption = "Empty." }).style.top_margin = 6
  end
  for i, it in ipairs(card.items or {}) do
    local port = result and (result.inputs[it.res] or result.outputs[it.res])
    local r = row(inner, "")
    r.children[1].caption = { "", board.rich(it.res) .. " ", fmt.rate(port and port.rate or 0, it.res) }
    r.add({ type = "drop-down", items = rules_list(), selected_index = RULE_INDEX[it.rule] or 1,
      tags = { ffp = "panel-rule", card = card.id, item = i } }).style.width = 150
    if it.rule then
      local tf = r.add({ type = "textfield", text = fmt.num((it.value or 0) * (fmt.step_unit())), numeric = true, allow_decimal = true,
        lose_focus_on_confirm = true, tags = { ffp = "panel-value", card = card.id, item = i } })
      tf.style.width = 60
    end
    r.add({ type = "sprite-button", sprite = "utility/close", style = "tool_button_red", tooltip = "Remove from the panel",
      tags = { ffp = "panel-remove", card = card.id, item = i } })
  end
end

local function recipe_inspector(inner, plan, card)
  local force = board.force_of(plan)
  local spec = catalog.spec(card, force)
  local proto = catalog.recipe(card.recipe)
  local result = (storage.results[plan.id] or { cards = {} }).cards[card.id]

  local head = inner.add({ type = "flow", direction = "horizontal" })
  head.style.vertical_align = "center"
  head.add({ type = "sprite", sprite = "recipe/" .. card.recipe })
  head.add({ type = "label", caption = proto and proto.localised_name or card.recipe, style = "bold_label" })

  -- Machine.
  local machines = catalog.machines_for(card.recipe)
  if #machines > 0 then
    local items, selected = {}, 1
    for i, m in ipairs(machines) do
      local ent = prototypes.entity[m.name]
      items[i] = { "", "[entity=" .. m.name .. "] ", ent.localised_name, " (speed " .. fmt.num(m.speed) .. ")" }
      if spec and m.name == spec.machine then selected = i end
    end
    row(inner, "Machine").add({ type = "drop-down", items = items, selected_index = selected, tags = { ffp = "machine", card = card.id } })
  end

  -- Modules and beacons.
  if spec and spec.module_slots > 0 then
    local options = catalog.module_options(card.recipe, spec.machine)
    local items, selected = { "None" }, 1
    for i, name in ipairs(options) do
      items[i + 1] = { "", "[item=" .. name .. "] ", prototypes.item[name].localised_name }
      if name == card.modules then selected = i + 1 end
    end
    local r = row(inner, "Modules")
    r.add({ type = "drop-down", items = items, selected_index = selected, tags = { ffp = "modules", card = card.id } })
    r.add({ type = "label", caption = "x" .. spec.module_slots })
  end
  if spec and spec.beacons_ok then
    local b = card.beacons or {}
    local counts = {}
    for n = 0, 16 do counts[#counts + 1] = tostring(n) end
    local r = row(inner, "Beacons")
    r.add({ type = "drop-down", items = counts, selected_index = math.min((b.count or 0), 16) + 1,
      tags = { ffp = "beacon-count", card = card.id } }).style.width = 60
    local options = catalog.beacon_module_options(card.recipe)
    local items, selected = {}, 1
    local current = b.module or catalog.default_beacon_module(card.recipe)
    for i, name in ipairs(options) do
      items[i] = { "", "[item=" .. name .. "] ", prototypes.item[name].localised_name }
      if name == current then selected = i end
    end
    if #items > 0 then
      r.add({ type = "drop-down", items = items, selected_index = selected, tags = { ffp = "beacon-module", card = card.id } })
    end
  end

  -- Target.
  local tr = row(inner, "Target")
  tr.add({ type = "drop-down", items = target_kinds(), selected_index = card.target and TARGET_INDEX[card.target.kind] or 1,
    tags = { ffp = "target-kind", card = card.id } })
  if card.target and spec then
    if card.target.kind == "rate" and #spec.outputs > 1 then
      local items, selected = {}, 1
      for i, p in ipairs(spec.outputs) do
        items[i] = { "", board.rich(p.res) .. " ", catalog.res_name(p.res) }
        if p.res == card.target.product then selected = i end
      end
      row(inner, "of").add({ type = "drop-down", items = items, selected_index = selected, tags = { ffp = "target-product", card = card.id } })
    end
    local factor, word = fmt.step_unit()
    local vr = row(inner, card.target.kind == "rate" and ("Per " .. word) or "Machines")
    local shown = card.target.kind == "rate" and card.target.value * factor or card.target.value
    local tf = vr.add({
      type = "textfield", name = "ffp_target_value", text = fmt.num(shown), numeric = true, allow_decimal = true,
      allow_negative = false, lose_focus_on_confirm = true, tags = { ffp = "target-value", card = card.id },
    })
    tf.style.width = 100
    vr.add({ type = "button", caption = "Set", tags = { ffp = "target-set", card = card.id } })
  end

  -- Numbers.
  if result and spec then
    local info = inner.add({ type = "flow", direction = "vertical" })
    info.style.top_margin = 8
    info.add({ type = "label", caption = "Machines needed: " .. fmt.count(result.machines) .. " (build " .. math.ceil(result.machines - 1e-6) .. ")" })
    info.add({ type = "label", caption = "Power: " .. fmt.power(result.power_w) })
    if math.abs(spec.speed_bonus or 0) > 1e-6 then
      info.add({ type = "label", caption = string.format("Speed: %+d%%", math.floor(spec.speed_bonus * 100 + 0.5)) })
    end
    if (spec.productivity or 0) > 0 then
      info.add({ type = "label", caption = "Productivity: +" .. fmt.num(spec.productivity * 100) .. "%" })
    end
  elseif not spec then
    inner.add({ type = "label", caption = "This recipe or its machine no longer exists." })
  end
end

function gui.inspector_update(player)
  local plan = board.plan_of(player)
  if plan then fmt.use(plan.units, catalog.transport_kit()) end
  local s = board.session(player.index)
  local card = plan and s.selected and plan_lib.card(plan, s.selected)
  if not card then
    destroy(player.gui.screen, "ffp_inspector")
    return
  end
  local frame = player.gui.screen.ffp_inspector
  local location
  if frame and frame.valid then
    location = frame.location
    frame.destroy()
  end
  frame = player.gui.screen.add({ type = "frame", name = "ffp_inspector", direction = "vertical" })
  titlebar(frame, plan_lib.is_panel(card) and (card.kind == "source" and "Supply panel" or "Output panel") or "Card", "close-inspector")
  local inner = frame.add({ type = "frame", style = "inside_shallow_frame_with_padding", direction = "vertical" })
  inner.style.width = 360
  if plan_lib.is_panel(card) then
    panel_inspector(inner, plan, card)
  else
    recipe_inspector(inner, plan, card)
  end

  local brow = inner.add({ type = "flow", direction = "horizontal" })
  brow.style.top_margin = 8
  brow.add({ type = "button", caption = "Move", tags = { ffp = "move-card", card = card.id } })
  brow.add({ type = "button", caption = "Unwire all", tags = { ffp = "unwire-card", card = card.id } })
  local pad = brow.add({ type = "empty-widget" })
  pad.style.horizontally_stretchable = true
  brow.add({ type = "button", caption = "Delete", style = "red_button", tags = { ffp = "delete-card", card = card.id } })

  if location then
    frame.location = location
  else
    local res, scale = player.display_resolution, player.display_scale
    frame.location = { x = res.width - (380 * scale), y = 160 * scale }
  end
end

-- ---------------------------------------------------------------------------
-- Picker: recipes that make the resource an input needs.

--- mode "make": recipes producing res (feeds the card's input).
--- mode "use": recipes consuming res (takes the card's output).
--- drop: optional {x, y} in plan coordinates where the new card should go.
function gui.picker_open(player, card_id, res, mode, drop)
  mode = mode or "make"
  destroy(player.gui.screen, "ffp_picker")
  local plan = board.plan_of(player)
  if not plan then return end
  local frame = player.gui.screen.add({ type = "frame", name = "ffp_picker", direction = "vertical" })
  titlebar(frame, mode == "use" and "What uses this?" or "What makes this?", "close-picker")
  local inner = frame.add({ type = "frame", style = "inside_shallow_frame_with_padding", direction = "vertical" })
  inner.add({ type = "label", caption = { "", board.rich(res) .. " ", catalog.res_name(res) }, style = "bold_label" })
  local force = board.force_of(plan)
  local list = mode == "use" and catalog.consumers(res, force) or catalog.producers(res, force)
  if #list == 0 then
    inner.add({ type = "label", caption = mode == "use" and "No recipe uses this."
      or "No recipe makes this. It stays an input from outside the plan." })
  else
    inner.add({ type = "label", caption = "Pick a recipe; it is added and wired in. Red ones are not researched yet." })
  end
  local grid = inner.add({ type = "table", column_count = 10 })
  grid.style.top_margin = 6
  local pc = plan_lib.card(plan, card_id)
  if not (pc and plan_lib.is_panel(pc)) then
    grid.add({
      type = "sprite-button", style = "yellow_slot_button",
      sprite = mode == "use" and "utility/export_slot" or "utility/import_slot",
      tooltip = mode == "use" and "Output panel: it leaves the plan" or "Supply panel: it comes in from outside",
      tags = { ffp = "pick", card = card_id, res = res, panel = mode == "use" and "sink" or "source", mode = mode,
        drop_x = drop and drop.x or nil, drop_y = drop and drop.y or nil },
    })
  end
  do
    for _, r in ipairs(list) do
      local proto = prototypes.recipe[r.name]
      grid.add({
        type = "sprite-button", sprite = "recipe/" .. r.name,
        style = r.enabled and "slot_button" or "red_slot_button",
        tooltip = r.enabled and proto.localised_name or { "", proto.localised_name, " (not researched)" },
        tags = { ffp = "pick", card = card_id, res = res, recipe = r.name, mode = mode,
          drop_x = drop and drop.x or nil, drop_y = drop and drop.y or nil },
      })
    end
  end
  frame.force_auto_center()
end

function gui.picker_close(player)
  destroy(player.gui.screen, "ffp_picker")
end

function gui.close_all(player)
  destroy(player.gui.top, "ffp_toolbar")
  destroy(player.gui.left, "ffp_overview")
  destroy(player.gui.screen, "ffp_overview")
  destroy(player.gui.screen, "ffp_inspector")
  destroy(player.gui.screen, "ffp_picker")
end

return gui
