-- The board: a lab-tiled surface where each plan has its own region, drawn
-- with the rendering API. Players visit it in god mode (their character stays
-- where they left it, made indestructible until they return). Everyone on a
-- plan sees the same drawing, so editing together needs nothing extra.

local layout = require("scripts.layout")
local plan_lib = require("scripts.plan")
local solver = require("scripts.solver")
local catalog = require("scripts.catalog")
local fmt = require("scripts.fmt")
local links = require("scripts.links")

local board = {}

board.SURFACE = "factory-flow-planner-board"
local REGION = 2000 -- tiles between plan origins

local COLORS = {
  card = { 0.19, 0.19, 0.21, 0.97 },
  header = { 0.25, 0.25, 0.28, 0.97 },
  border = { 0.45, 0.45, 0.48, 1 },
  border_short = { 0.95, 0.3, 0.25, 1 },
  border_target = { 0.4, 0.85, 0.4, 1 },
  text = { 0.95, 0.95, 0.95 },
  dim = { 0.7, 0.7, 0.72 },
  import = { 1, 0.7, 0.35 },
  short = { 1, 0.4, 0.35 },
  spare = { 0.95, 0.85, 0.35 },
  wire_item = { 0.9, 0.72, 0.3, 0.9 },
  wire_fluid = { 0.35, 0.65, 1, 0.9 },
  select = { 1, 0.75, 0.1, 1 },
  pending = { 0.3, 1, 0.5, 1 },
  supply = { 0.16, 0.24, 0.34, 0.97 },
  output = { 0.17, 0.3, 0.2, 0.97 },
  chips = { 0.12, 0.12, 0.14, 0.97 },
  effect = { 0.55, 0.8, 1 },
  footer = { 0.15, 0.15, 0.17, 0.97 },
  tile = { 0.13, 0.13, 0.15, 0.97 },
  tile_edge = { 0.33, 0.33, 0.36, 1 },
  tile_short = { 0.3, 0.19, 0.07, 0.97 },
  short_edge = { 1, 0.6, 0.15, 1 },
  limit = { 1, 0.8, 0.3 },
  popup = { 0.07, 0.07, 0.08, 0.96 },
  popup_edge = { 0.45, 0.45, 0.48, 1 },
}

-- ---------------------------------------------------------------------------
-- Storage helpers

function board.init_storage()
  storage.plans = storage.plans or {}           -- plan id -> plan
  storage.next_plan_id = storage.next_plan_id or 1
  storage.results = storage.results or {}       -- plan id -> solver result
  storage.render = storage.render or {}         -- plan id -> { render object ids }
  storage.players = storage.players or {}       -- player index -> session
end

function board.session(player_index)
  local s = storage.players[player_index]
  if not s then
    s = {}
    storage.players[player_index] = s
  end
  return s
end

function board.plan_of(player)
  local s = storage.players[player.index]
  return s and s.plan_id and storage.plans[s.plan_id] or nil
end

function board.surface()
  local surface = game.get_surface(board.SURFACE)
  if not surface then
    surface = game.create_surface(board.SURFACE, { peaceful_mode = true, no_enemies_mode = true })
    surface.generate_with_lab_tiles = true
    surface.always_day = true
    surface.show_clouds = false
    for _, force in pairs(game.forces) do
      pcall(function() force.set_surface_hidden(surface, true) end)
    end
  end
  return surface
end

function board.origin(plan)
  return { x = plan.id * REGION, y = 0 }
end

function board.force_of(plan)
  return game.forces[plan.force] or game.forces.player
end

--- Specs for every card of a plan, computed once per call.
function board.specs(plan)
  local force = board.force_of(plan)
  local specs = {}
  for _, c in ipairs(plan.cards) do
    specs[c.id] = catalog.spec(c, force)
  end
  return specs
end

-- ---------------------------------------------------------------------------
-- Drawing

local function destroy_ids(ids)
  for _, id in ipairs(ids or {}) do
    local obj = rendering.get_object_by_id(id)
    if obj and obj.valid then obj.destroy() end
  end
end

local function rich(res)
  local kind, name = string.match(res, "^([^/]+)/(.+)$")
  return "[" .. kind .. "=" .. name .. "]"
end
board.rich = rich

-- Factorio's GUI palette: frames, inset panels, slots and the title colour.
local FW = {
  frame = { 0.192, 0.188, 0.192, 0.98 },
  deep = { 0.141, 0.137, 0.141, 0.98 },
  light = { 0.37, 0.365, 0.37, 1 },
  dark = { 0.07, 0.07, 0.07, 1 },
  heading = { 1, 0.902, 0.753 },
  label = { 0.82, 0.82, 0.82 },
  dim = { 0.5, 0.5, 0.5 },
  slot = { 0.52, 0.52, 0.52, 1 },
  slot_light = { 0.68, 0.68, 0.68, 1 },
  slot_dark = { 0.3, 0.3, 0.3, 1 },
  slot_red = { 0.78, 0.33, 0.3, 1 },
  slot_green = { 0.42, 0.68, 0.33, 1 },
  slot_yellow = { 0.82, 0.68, 0.28, 1 },
  bar_bg = { 0.09, 0.09, 0.09, 1 },
  progress = { 0.89, 0.6, 0.15, 1 },
  handle_dark = { 0.13, 0.13, 0.13, 1 },
  handle_light = { 0.3, 0.3, 0.3, 1 },
}

local STATUS = {
  short = { "SHORT", { 1, 0.62, 0.15 } },
  limited = { "AT LIMIT", { 1, 0.8, 0.3 } },
  idle = { "IDLE", { 0.6, 0.6, 0.62 } },
  target = { "TARGET", { 0.45, 0.9, 0.45 } },
  running = { "RUNNING", { 0.75, 0.85, 1 } },
}

function board.draw(plan)
  fmt.use(plan.units, catalog.transport_kit())
  destroy_ids(storage.render[plan.id])
  local ids = {}
  storage.render[plan.id] = ids
  local surface = board.surface()
  local o = board.origin(plan)
  local result = storage.results[plan.id] or { cards = {}, wires = {} }
  local specs = board.specs(plan)

  local function P(x, y) return { x = o.x + x, y = o.y + y } end
  local function keep(obj) ids[#ids + 1] = obj.id end
  local function text(str, x, y, color, scale, align, font)
    keep(rendering.draw_text({
      text = str, surface = surface, target = P(x, y), color = color or COLORS.text,
      scale = scale or 1, alignment = align or "left", vertical_alignment = "middle", font = font,
      use_rich_text = true,
    }))
  end
  -- Cards are drawn above entities so belts and pipes run in under their
  -- edges. Shapes in that layer cover sprites, so icons are drawn as rich
  -- text, which draws above them.
  local function sprite(path, x, y, scale)
    local kind, name = string.match(path, "^([^/]+)/(.+)$")
    local tag = (kind == "utility") and ("[img=" .. path .. "]") or ("[" .. kind .. "=" .. name .. "]")
    keep(rendering.draw_text({
      text = tag, surface = surface, target = P(x, y), color = { 1, 1, 1 }, scale = scale * 3.2,
      alignment = "center", vertical_alignment = "middle", use_rich_text = true,
    }))
  end
  local function rect(x1, y1, x2, y2, color, filled, width)
    keep(rendering.draw_rectangle({ surface = surface, color = color, filled = filled, width = width,
      left_top = P(x1, y1), right_bottom = P(x2, y2) }))
  end
  local function dot(x, y, color)
    keep(rendering.draw_circle({ surface = surface, color = color, radius = 0.16, filled = true, target = P(x, y) }))
  end

  -- Links as belts and pipes (the default), or as drawn lines.
  local as_lines = {}
  local laid, failed = {}, plan.wires
  if plan.links ~= "lines" then
    laid, failed = links.lay(plan, function(c) return specs[c.id] end, result.wires or {}, catalog.transport_kit())
    for _, L in ipairs(laid) do
      if L.mult > 1 then
        text("×" .. L.mult, L.start_tile[1] + 0.5, L.start_tile[2] - 0.45, COLORS.limit, 0.9, "center", "default-bold")
      end
    end
  end
  for _, w in ipairs(failed) do as_lines[w.id] = true end
  board.place_links(plan, laid, failed)

  -- Wires drawn as lines (all of them in line mode, or ones no belt could reach).
  for _, w in ipairs(plan.wires) do
    if not as_lines[w.id] then goto next_wire end
    local a, b = plan_lib.card(plan, w.from), plan_lib.card(plan, w.to)
    local sa, sb = a and specs[a.id], b and specs[b.id]
    if sa and sb then
      local x1, y1 = layout.port_point(a, sa, "out", w.res)
      local x2, y2 = layout.port_point(b, sb, "in", w.res)
      if x1 and x2 then
        local _, _, _, ba = layout.box(a, sa)
        local _, _, _, bb = layout.box(b, sb)
        local pts, label = layout.route(x1, y1, x2, y2, math.max(ba, bb) + 1)
        local color = string.sub(w.res, 1, 6) == "fluid/" and COLORS.wire_fluid or COLORS.wire_item
        for i = 1, #pts - 1 do
          keep(rendering.draw_line({ surface = surface, color = color, width = 3, draw_on_ground = true,
            from = P(pts[i][1], pts[i][2]), to = P(pts[i + 1][1], pts[i + 1][2]) }))
        end
        -- Arrow head just before the input.
        for _, dy in ipairs({ -0.28, 0.28 }) do
          keep(rendering.draw_line({ surface = surface, color = color, width = 3, draw_on_ground = true,
            from = P(x2 - 0.75, y2 + dy), to = P(x2 - 0.35, y2) }))
        end
      end
    end
    ::next_wire::
  end

  -- Factorio window pieces ------------------------------------------------
  local function line(x1, y1, x2, y2, color, w)
    keep(rendering.draw_line({ surface = surface, color = color, width = w or 2, from = P(x1, y1), to = P(x2, y2) }))
  end
  --- A beveled box: light top/left and dark bottom/right when raised, the
  --- other way round when sunk (inset panels and slots).
  local function bevel(x1, y1, x2, y2, fill, raised, light, dark)
    rect(x1, y1, x2, y2, fill, true)
    local tl, br = light or FW.light, dark or FW.dark
    if not raised then tl, br = br, tl end
    line(x1, y1, x2, y1, tl); line(x1, y1, x1, y2, tl)
    line(x1, y2, x2, y2, br); line(x2, y1, x2, y2, br)
  end
  local SLOT_FILL = { short = FW.slot_red, target = FW.slot_green, spare = FW.slot_yellow }
  local function slot(x1, y1, size, icon, state)
    bevel(x1, y1, x1 + size, y1 + size, SLOT_FILL[state] or FW.slot, false, FW.slot_light, FW.slot_dark)
    if icon then sprite(icon, x1 + size / 2, y1 + size / 2, size * 0.42) end
  end
  local function drag_handle(x1, x2, y1, y2)
    local x = x1
    while x < x2 do
      line(x, y1, x, y2, FW.handle_dark, 2)
      line(x + 0.06, y1, x + 0.06, y2, FW.handle_light, 1)
      x = x + 0.2
    end
  end
  local function title_bar(g, title, est_chars, right_text)
    local cy = g.t + layout.HEADER_H / 2
    text(title, g.l + 0.35, cy, FW.heading, 1.05, "left", "heading-2")
    -- Leave room for the title (its width can't be measured, so be generous).
    local hx1 = g.l + 1.3 + est_chars * 0.3
    local hx2 = g.r - 0.35 - (right_text and (#right_text * 0.15 + 0.3) or 0)
    if hx2 - hx1 > 0.6 then drag_handle(hx1, hx2, cy - 0.2, cy + 0.2) end
    if right_text then text(right_text, g.r - 0.35, cy, COLORS.effect, 0.8, "right") end
  end
  local function status_line(g, y, icon, word, detail, color, right)
    text("[img=utility/" .. icon .. "] ", g.l + 0.35, y, COLORS.text, 0.9, "left")
    text(word, g.l + 0.9, y, color, 0.9, "left", "default-bold")
    if detail then text(detail, g.l + 0.9 + #word * 0.2 + 0.3, y, FW.label, 0.8, "left") end
    if right then text(right, g.r - 0.35, y, FW.label, 0.85, "right") end
  end
  --- An input or output: a slot at the card edge, the rate beside it and the name under the rate.
  local function tile(p, res, rate, line2, line2_color, slot_right, state)
    local size = p.y2 - p.y1
    if slot_right then
      slot(p.x2 - size, p.y1, size, res, state)
      text(rate, p.x2 - size - 0.25, p.y1 + 0.42, COLORS.text, 1.05, "right", "default-bold")
      text(line2, p.x2 - size - 0.25, p.y1 + 0.95, line2_color or FW.label, 0.7, "right")
    else
      slot(p.x1, p.y1, size, res, state)
      text(rate, p.x1 + size + 0.25, p.y1 + 0.42, COLORS.text, 1.05, "left", "default-bold")
      text(line2, p.x1 + size + 0.25, p.y1 + 0.95, line2_color or FW.label, 0.7, "left")
    end
  end

  for _, c in ipairs(plan.cards) do
    local spec = specs[c.id]
    local cr = result.cards[c.id]
    if spec and spec.panel then
      -- A panel: things entering the plan (supply) or leaving it (output).
      local g = layout.geometry(c, spec)
      local source = c.kind == "source"
      bevel(g.l, g.t, g.r, g.b, FW.frame, true)
      bevel(g.l + 0.15, g.t + layout.PANEL_HEADER_H, g.r - 0.15, g.b - 0.15, FW.deep, false)
      title_bar(g, source and "Supply" or "Output", 6, source and "comes in" or "leaves")
      if #(c.items or {}) == 0 then
        text(source and "Drop an input here" or "Drop an output here", (g.l + g.r) / 2, g.empty_y, FW.label, 0.8, "center")
      end
      for _, p in ipairs(g.parts) do
        if p.part == "in" or p.part == "out" then
          local it
          for _, x in ipairs(c.items) do if x.res == p.res then it = x end end
          local port = cr and (cr.inputs[p.res] or cr.outputs[p.res])
          local rule = it and it.rule == "upto" and "up to " .. fmt.rate(it.value, p.res)
            or it and it.rule == "exact" and "exactly " .. fmt.rate(it.value, p.res) or nil
          local state, line2, color = nil, rule and { "", catalog.res_name(p.res), " · " .. rule } or catalog.res_name(p.res), nil
          if port and (port.shortfall or 0) > 1e-6 then
            state, line2, color = "short", "short " .. fmt.rate(port.shortfall, p.res), COLORS.short
          elseif port and (port.surplus or 0) > 1e-6 then
            state, line2, color = "spare", "spare " .. fmt.rate(port.surplus, p.res), COLORS.spare
          end
          tile(p, p.res, fmt.rate(port and port.rate or 0, p.res), line2, color, source, state)
          dot(p.port.x, p.port.y, FW.light)
        end
      end
    elseif spec then
      local g = layout.geometry(c, spec)
      local t = c.target
      local machines = cr and cr.machines or 0
      local short_res, spare = nil, false
      for _, p in ipairs(spec.inputs) do
        local port = cr and cr.inputs[p.res]
        if port and (port.shortfall or 0) > 1e-6 and not short_res then short_res = p.res end
      end
      for _, p in ipairs(spec.outputs) do
        local port = cr and cr.outputs[p.res]
        if port and (port.surplus or 0) > 1e-6 then spare = true end
      end

      -- Frame, title bar and the inset body.
      bevel(g.l, g.t, g.r, g.b, FW.frame, true)
      bevel(g.l + 0.15, g.body_top, g.r - 0.15, g.footer_top, FW.deep, false)
      local fx = {}
      if math.abs(spec.speed_bonus or 0) > 1e-6 then fx[#fx + 1] = string.format("%+d%% speed", math.floor(spec.speed_bonus * 100 + 0.5)) end
      if (spec.productivity or 0) > 1e-6 then fx[#fx + 1] = string.format("+%d%% prod", math.floor(spec.productivity * 100 + 0.5)) end
      local proto = catalog.recipe(c.recipe)
      title_bar(g, { "", "[recipe=" .. c.recipe .. "] ", proto and proto.localised_name or c.recipe }, #c.recipe + 2,
        #fx > 0 and table.concat(fx, "  ") or nil)

      -- Middle: what builds it and how many. The point of the card.
      local ent = prototypes.entity[spec.machine]
      text(ent and ent.localised_name or spec.machine, g.mid_cx, g.body_top + 0.4, FW.label, 0.8, "center")
      slot(g.mid_cx - 0.8, g.body_top + 0.65, 1.6, "entity/" .. spec.machine)
      local count_color = t and t.kind == "machines" and COLORS.border_target or (t and t.kind == "limit" and COLORS.limit or COLORS.text)
      text("×" .. fmt.count(machines), g.mid_cx, g.body_top + 2.62, count_color, 1.45, "center", "default-large-bold")
      local build = math.ceil(machines - 1e-6)
      local sub = "build " .. build
      if t and t.kind == "limit" then sub = sub .. " · up to " .. fmt.count(t.value)
      elseif t and t.kind == "machines" then sub = sub .. " · exactly " .. fmt.count(t.value) end
      if cr and (cr.power_w or 0) > 0 then sub = sub .. " · " .. fmt.power(cr.power_w) end
      text(sub, g.mid_cx, g.power_y - 0.17, FW.label, 0.72, "center")
      if t and (t.kind == "limit" or t.kind == "machines") and t.value > 0 then
        local bx1, bx2, by = g.mid_cx - 1.6, g.mid_cx + 1.6, g.power_y + 0.12
        bevel(bx1, by, bx2, by + 0.2, FW.bar_bg, false)
        local frac = math.max(0, math.min(1, machines / t.value))
        if frac > 0 then rect(bx1 + 0.03, by + 0.03, bx1 + 0.03 + (bx2 - bx1 - 0.06) * frac, by + 0.17, FW.progress, true) end
      end

      -- Module and beacon slots.
      for _, p in ipairs(g.parts) do
        if p.part == "modules" then
          local n = spec.module_slots
          if n == 0 then
            text("no module slots", (p.x1 + p.x2) / 2, (p.y1 + p.y2) / 2, FW.dim, 0.65, "center")
          elseif n <= 5 then
            local sz, gap = 0.48, 0.04
            local x = (p.x1 + p.x2) / 2 - (n * sz + (n - 1) * gap) / 2
            for _ = 1, n do
              slot(x, p.y1 + 0.16, sz, c.modules and ("item/" .. c.modules) or nil)
              x = x + sz + gap
            end
          else
            slot(p.x1 + 0.3, p.y1 + 0.16, 0.48, c.modules and ("item/" .. c.modules) or nil)
            text("× " .. n, p.x1 + 0.95, (p.y1 + p.y2) / 2, COLORS.text, 0.75, "left")
          end
        elseif p.part == "beacons" then
          local bc = c.beacons
          local cy = (p.y1 + p.y2) / 2
          if not spec.beacons_ok then
            text("no beacons", (p.x1 + p.x2) / 2, cy, FW.dim, 0.65, "center")
          else
            local n = bc and bc.count or 0
            text(n .. " ×", p.x1 + 0.75, cy, n > 0 and COLORS.text or FW.dim, 0.8, "right")
            local beacon = catalog.beacon()
            slot(p.x1 + 0.9, p.y1 + 0.16, 0.48, beacon and ("entity/" .. beacon.name) or nil)
            slot(p.x1 + 1.42, p.y1 + 0.16, 0.48, (n > 0 and bc.module) and ("item/" .. bc.module) or nil)
          end
        end
      end

      -- Inputs and outputs.
      for _, p in ipairs(g.parts) do
        if p.part == "in" then
          local port = cr and cr.inputs[p.res]
          local state, line2, color = nil, catalog.res_name(p.res), nil
          if port and (port.shortfall or 0) > 1e-6 then
            state, line2, color = "short", "short " .. fmt.rate(port.shortfall, p.res), COLORS.short
          elseif port and not port.wired and (port.import or 0) > 1e-6 then
            color = COLORS.import
          end
          tile(p, p.res, fmt.rate(port and port.rate or 0, p.res), line2, color, false, state)
          dot(p.port.x, p.port.y, FW.light)
        elseif p.part == "out" then
          local port = cr and cr.outputs[p.res]
          local state, line2, color = nil, catalog.res_name(p.res), nil
          if t and t.kind == "rate" and t.product == p.res then
            state, color = "target", COLORS.border_target
          elseif port and (port.surplus or 0) > 1e-6 then
            state, line2, color = "spare", "spare " .. fmt.rate(port.surplus, p.res), COLORS.spare
          end
          tile(p, p.res, fmt.rate(port and port.rate or 0, p.res), line2, color, true, state)
          dot(p.port.x, p.port.y, FW.light)
        end
      end

      -- Status, worded and coloured as in a machine's own window.
      local fy = (g.footer_top + g.b) / 2
      local right = "build " .. build .. " × [entity=" .. spec.machine .. "]"
      if short_res then
        status_line(g, fy, "status_not_working", "Missing ingredients",
          { "", board.rich(short_res) .. " ", catalog.res_name(short_res) }, STATUS.short[2], right)
      elseif t and t.kind == "limit" and machines >= t.value - 1e-6 then
        status_line(g, fy, "status_yellow", "Limited", "to " .. fmt.count(t.value) .. " machines", STATUS.limited[2], right)
      elseif machines < 1e-9 then
        status_line(g, fy, "status_inactive", "Idle", "nothing asks for its output", STATUS.idle[2], right)
      elseif spare then
        status_line(g, fy, "status_yellow", "Working", "with spare output", STATUS.limited[2], right)
      else
        status_line(g, fy, "status_working", "Working", nil, STATUS.target[2], right)
      end
    else
      rect(c.x, c.y, c.x + layout.CARD_W, c.y + 2, COLORS.short_edge, false, 2)
      text("Missing recipe: " .. tostring(c.recipe), c.x + 0.4, c.y + 1, COLORS.short, 1)
    end
  end

  board.place_hotspots(plan, specs)
end

-- ---------------------------------------------------------------------------
-- Belts and pipes as real entities. Rebuilt only when the layout changes.

local DIR = { defines.direction.east, defines.direction.south, defines.direction.west, defines.direction.north }
local BACK = { defines.direction.west, defines.direction.north, defines.direction.east, defines.direction.south }

local function ensure_chunks(surface, o, x1, y1, x2, y2)
  local need = false
  for cx = math.floor((o.x + x1) / 32), math.floor((o.x + x2) / 32) do
    for cy = math.floor((o.y + y1) / 32), math.floor((o.y + y2) / 32) do
      if not surface.is_chunk_generated({ cx, cy }) then
        surface.request_to_generate_chunks({ x = cx * 32 + 16, y = cy * 32 + 16 }, 0)
        need = true
      end
    end
  end
  if need then surface.force_generate_chunk_requests() end
end

function board.destroy_links(plan_id)
  if storage.link_runs then storage.link_runs[plan_id] = nil end
  for _, e in ipairs((storage.link_ents or {})[plan_id] or {}) do
    if e.valid then e.destroy() end
  end
  if storage.link_ents then storage.link_ents[plan_id] = nil end
  if storage.link_sig then storage.link_sig[plan_id] = nil end
end

-- Items ride each link's belts, spaced by how full the belt runs: a belt at
-- its full rate is packed (4 items per lane per tile), a trickle shows an item
-- every couple of tiles. The belts run; board.run_belts keeps them flowing by
-- feeding items in at the start and taking them off at the end.
local FULL_SPACING, MAX_SPACING = 0.25, 2.0

local function belt_spacing(L, flows)
  local cap = (L.kind.items_per_s or 0) * L.mult
  local f = cap > 0 and (L.rate or flows[L.wire.id] or 0) / cap or 0
  if f <= 0 then return MAX_SPACING end
  return math.max(FULL_SPACING, math.min(MAX_SPACING, FULL_SPACING / f))
end

local function load_link(L, ents, flows)
  local kind, name = string.match(L.wire.res, "^([^/]+)/(.+)$")
  if L.fluid then
    for _, e in ipairs(ents) do
      pcall(function() e.insert_fluid({ name = name, amount = 50 }) end)
    end
    return
  end
  if kind ~= "item" or not prototypes.item[name] then return end
  local spacing = belt_spacing(L, flows)
  local carry = { 0, spacing / 2 } -- stagger the two lanes
  for _, e in ipairs(ents) do
    for lane = 1, 2 do
      local ok, line = pcall(function() return e.get_transport_line(lane) end)
      if ok and line then
        local len = line.line_length
        local x = carry[lane]
        while x < len do
          line.insert_at(x, { name = name, count = 1 })
          x = x + spacing
        end
        carry[lane] = x - len
      end
    end
  end
end

--- Keeps every link's belt moving: feed items in at the first tile at the
--- link's spacing, take them off the last tile (the card "uses" them).
--- Called every RUN_EVERY ticks.
board.RUN_EVERY = 6

local function feed(line, name)
  pcall(function() line.insert_at_back({ name = name, count = 1 }) end)
end

function board.run_belts()
  for _, runs in pairs(storage.link_runs or {}) do
    for _, r in ipairs(runs) do
      if r.first.valid and r.last.valid then
        r.acc = r.acc + r.speed * board.RUN_EVERY
        local n = 0
        while r.feed ~= false and r.acc >= r.spacing and n < 8 do
          r.acc = r.acc - r.spacing
          n = n + 1
          r.lane = 3 - r.lane -- alternate lanes, so both fill evenly
          feed(r.first.get_transport_line(r.lane), r.item)
        end
        if r.drain then
          for lane = 1, 2 do r.last.get_transport_line(lane).clear() end
        end
      end
    end
  end
end

function board.place_links(plan, laid, failed)
  storage.link_ents = storage.link_ents or {}
  storage.link_sig = storage.link_sig or {}
  storage.link_runs = storage.link_runs or {}
  local flows = (storage.results[plan.id] or {}).wires or {}
  local sig = links.signature(laid, failed)
  for _, L in ipairs(laid) do
    if not L.fluid then sig = sig .. "|d" .. L.wire.id .. "=" .. string.format("%.2f", belt_spacing(L, flows)) end
  end
  if storage.link_sig[plan.id] == sig and storage.link_ents[plan.id] then return end
  board.destroy_links(plan.id)
  local list, runs = {}, {}
  storage.link_ents[plan.id] = list
  storage.link_sig[plan.id] = sig
  storage.link_runs[plan.id] = runs
  if #laid == 0 then return end
  local surface = board.surface()
  local o = board.origin(plan)
  local x1, y1, x2, y2 = math.huge, math.huge, -math.huge, -math.huge
  for _, L in ipairs(laid) do
    for _, t in ipairs(L.path) do
      x1, y1, x2, y2 = math.min(x1, t.x), math.min(y1, t.y), math.max(x2, t.x), math.max(y2, t.y)
    end
  end
  if x1 == math.huge then return end
  ensure_chunks(surface, o, x1, y1, x2, y2)
  for _, L in ipairs(laid) do
    local link_ents = {}
    for _, sp in ipairs(L.splitters or {}) do
      if sp.name then
        local e = surface.create_entity({ name = sp.name, force = "neutral", create_build_effect_smoke = false,
          position = { x = o.x + sp.x, y = o.y + sp.y }, direction = DIR[sp.dir] })
        if e then
          -- Trunk items stay on the trunk; the branch belt is fed at its own rate.
          pcall(function() e.splitter_output_priority = sp.trunk_side end)
          e.destructible, e.minable_flag, e.rotatable, e.operable = false, false, false, false
          list[#list + 1] = e
        end
      end
    end
    for _, t in ipairs(L.path) do
      if t.kind == "split" then goto next_tile end
      local params = { force = "neutral", create_build_effect_smoke = false,
        position = { x = o.x + t.x + 0.5, y = o.y + t.y + 0.5 } }
      if L.fluid then
        if t.kind == "line" then
          params.name = L.kind.name
        else
          params.name = L.kind.underground
          -- A pipe-to-ground's open side faces its direction: back along the
          -- run at the entrance, forward at the exit.
          params.direction = t.kind == "in" and BACK[t.dir] or DIR[t.dir]
        end
      else
        if t.kind == "line" then
          params.name = L.kind.name
        else
          params.name = L.kind.underground
          params.type = t.kind == "in" and "input" or "output"
        end
        params.direction = DIR[t.dir]
      end
      local e = surface.create_entity(params)
      if e then
        e.destructible = false
        e.minable_flag = false
        e.rotatable = false
        e.operable = false
        list[#list + 1] = e
        link_ents[#link_ents + 1] = e
      end
      ::next_tile::
    end
    load_link(L, link_ents, flows)
    local item = string.match(L.wire.res, "^item/(.+)$")
    if not L.fluid and item and prototypes.item[item] and #link_ents > 0 then
      local spacing = belt_spacing(L, flows)
      runs[#runs + 1] = {
        first = link_ents[1], last = link_ents[#link_ents], item = item,
        speed = (L.kind.items_per_s or 15) / 480, -- tiles per tick
        -- Two lanes, alternated: each lane gets an item every `spacing` tiles.
        spacing = spacing / 2, acc = 0, lane = 1,
        -- Every link is fed at its own rate; a merge hands its items on.
        feed = L.fed ~= false,
        drain = L.drains ~= false,
      }
    end
  end
end

-- ---------------------------------------------------------------------------
-- Hover hotspots: invisible entities over each control, so the game tells us
-- what is under the cursor (on_selected_entity_changed) and draws its
-- selection brackets there.

function board.place_hotspots(plan, specs)
  storage.hot = storage.hot or {}
  for _, e in ipairs(storage.hot[plan.id] or {}) do
    if e.valid then e.destroy() end
  end
  local list = {}
  storage.hot[plan.id] = list
  local surface = board.surface()
  local o = board.origin(plan)
  for _, c in ipairs(plan.cards) do
    local spec = specs[c.id]
    if spec then
      local g = layout.geometry(c, spec)
      local cx, cy = math.floor((o.x + (g.l + g.r) / 2) / 32), math.floor((o.y + (g.t + g.b) / 2) / 32)
      if not surface.is_chunk_generated({ cx, cy }) then
        surface.request_to_generate_chunks({ x = o.x + g.l, y = o.y + g.t }, 1)
        surface.force_generate_chunk_requests()
      end
      for _, p in ipairs(g.parts) do
        local hot = layout.HOTSPOTS[p.hot]
        if hot then
          local e = surface.create_entity({
            name = hot.name, force = "neutral", create_build_effect_smoke = false,
            position = { x = o.x + (p.x1 + p.x2) / 2, y = o.y + (p.y1 + p.y2) / 2 },
          })
          if e then
            e.destructible = false
            e.minable_flag = false
            list[#list + 1] = e
          end
        end
      end
    end
  end
end

function board.destroy_hotspots(plan_id)
  for _, e in ipairs((storage.hot or {})[plan_id] or {}) do
    if e.valid then e.destroy() end
  end
  if storage.hot then storage.hot[plan_id] = nil end
end

--- The hover popup: a frame round the part under the cursor and a short
--- list of what the wheel and clicks do there. Only that player sees it.
function board.draw_hover(player, plan, card, part_geom, h, card_right)
  local s = board.session(player.index)
  destroy_ids(s.hover_ids)
  s.hover_ids = {}
  if not (plan and card and part_geom and h) then return end
  local surface = board.surface()
  local o = board.origin(plan)
  local function P(x, y) return { x = o.x + x, y = o.y + y } end
  local function keep(obj) s.hover_ids[#s.hover_ids + 1] = obj.id end
  keep(rendering.draw_rectangle({ surface = surface, color = COLORS.select, filled = false, width = 2,
    left_top = P(part_geom.x1 - 0.08, part_geom.y1 - 0.08), right_bottom = P(part_geom.x2 + 0.08, part_geom.y2 + 0.08),
    players = { player } }))
  -- Popup to the right of the part.
  local x = (card_right or part_geom.x2) + 0.6
  local y = part_geom.y1
  local lh = 0.55
  local h_total = 0.9 + #h.lines * lh + 0.2
  local w = 11
  keep(rendering.draw_rectangle({ surface = surface, color = COLORS.popup, filled = true,
    left_top = P(x, y), right_bottom = P(x + w, y + h_total), players = { player } }))
  keep(rendering.draw_rectangle({ surface = surface, color = COLORS.popup_edge, filled = false, width = 1,
    left_top = P(x, y), right_bottom = P(x + w, y + h_total), players = { player } }))
  keep(rendering.draw_text({ text = h.title, surface = surface, target = P(x + 0.3, y + 0.45), color = COLORS.text,
    scale = 0.85, vertical_alignment = "middle", font = "default-bold", use_rich_text = true, players = { player } }))
  for i, l in ipairs(h.lines) do
    local ly = y + 0.95 + (i - 0.5) * lh
    if l[1] ~= "" then
      keep(rendering.draw_text({ text = l[1], surface = surface, target = P(x + 0.3, ly), color = COLORS.select,
        scale = 0.75, vertical_alignment = "middle", font = "default-bold", players = { player } }))
    end
    keep(rendering.draw_text({ text = l[2], surface = surface, target = P(x + 3.2, ly), color = COLORS.text,
      scale = 0.75, vertical_alignment = "middle", players = { player } }))
  end
end

--- Per-player highlights: the selected card, a card being moved, a wire being drawn.
function board.draw_overlay(player)
  local s = board.session(player.index)
  destroy_ids(s.overlay)
  s.overlay = {}
  local plan = board.plan_of(player)
  if not plan or not s.on_board then return end
  local surface = board.surface()
  local o = board.origin(plan)
  local function P(x, y) return { x = o.x + x, y = o.y + y } end
  local specs = board.specs(plan)

  local function frame(card, color, dashed)
    local spec = specs[card.id]
    if not spec then return end
    local l, t, r, b = layout.box(card, spec)
    local obj = rendering.draw_rectangle({
      surface = surface, color = color, filled = false, width = 4,
      left_top = P(l - 0.2, t - 0.2), right_bottom = P(r + 0.2, b + 0.2), players = { player },
    })
    s.overlay[#s.overlay + 1] = obj.id
    if dashed then
      local txt = rendering.draw_text({
        text = "Click where this card should go", surface = surface, target = P(l, t - 0.7),
        color = color, scale = 1.1, players = { player },
      })
      s.overlay[#s.overlay + 1] = txt.id
    end
  end

  local sel = s.selected and plan_lib.card(plan, s.selected)
  if sel then frame(sel, COLORS.select, false) end
  local mov = s.moving and plan_lib.card(plan, s.moving)
  if mov then frame(mov, COLORS.pending, true) end
  if s.wire then
    local from = plan_lib.card(plan, s.wire.from)
    local spec = from and specs[from.id]
    if spec then
      local x, y = layout.port_point(from, spec, "out", s.wire.res)
      if x then
        local c = rendering.draw_circle({ surface = surface, color = COLORS.pending, radius = 0.35, width = 4, filled = false, target = P(x, y), players = { player } })
        local t = rendering.draw_text({
          text = "Click an input " .. rich(s.wire.res) .. " on another card to connect", surface = surface,
          target = P(x + 0.5, y - 0.8), color = COLORS.pending, scale = 1.1, players = { player }, use_rich_text = true,
        })
        s.overlay[#s.overlay + 1] = c.id
        s.overlay[#s.overlay + 1] = t.id
      end
    end
  end
end

function board.clear_overlay(player)
  local s = board.session(player.index)
  destroy_ids(s.overlay)
  s.overlay = {}
end

-- ---------------------------------------------------------------------------
-- Solving

function board.resolve(plan)
  local force = board.force_of(plan)
  local result = solver.solve(plan, function(card) return catalog.spec(card, force) end)
  storage.results[plan.id] = result
  return result
end

function board.destroy_plan_drawing(plan_id)
  board.destroy_hotspots(plan_id)
  board.destroy_links(plan_id)
  destroy_ids(storage.render[plan_id])
  storage.render[plan_id] = nil
  storage.results[plan_id] = nil
end

-- ---------------------------------------------------------------------------
-- Making the board feel like an editor rather than the map

board.TOOL = "ffp-board-tool"
local FLOOR = "lab-dark-1"
local HUD = { "show_quickbar", "show_minimap", "show_research_info", "show_alert_gui",
  "show_hotkey_suggestions", "show_crafting_queue", "show_pins_gui", "show_surface_list",
  "show_shortcut_bar", "show_tool_bar" }

--- One flat tile everywhere instead of the lab checkerboard.
function board.floor(surface, area)
  local tiles = {}
  for x = area.left_top.x, area.right_bottom.x - 1 do
    for y = area.left_top.y, area.right_bottom.y - 1 do
      tiles[#tiles + 1] = { name = FLOOR, position = { x, y } }
    end
  end
  surface.set_tiles(tiles, false)
end

function board.floor_all()
  local surface = game.get_surface(board.SURFACE)
  if not surface then return end
  for chunk in surface.get_chunks() do
    board.floor(surface, chunk.area)
  end
end

local function hide_hud(player, s)
  local view = player.game_view_settings
  s.hud = {}
  for _, k in ipairs(HUD) do
    s.hud[k] = view[k]
    view[k] = false
  end
  player.game_view_settings = view
end

--- After a mod update, hide HUD parts this version added (players already on the board).
function board.refresh_hud(player)
  local s = board.session(player.index)
  if not (s.on_board and s.hud) then return end
  local view = player.game_view_settings
  for _, k in ipairs(HUD) do
    if s.hud[k] == nil then
      s.hud[k] = view[k]
      view[k] = false
    end
  end
  player.game_view_settings = view
end

local function restore_hud(player, s)
  if not s.hud then return end
  local view = player.game_view_settings
  for k, v in pairs(s.hud) do view[k] = v end
  player.game_view_settings = view
  s.hud = nil
end

--- The board tool lives in the cursor while on the board: it turns presses and
--- drags into selection events, which is how a mod sees a drag.
function board.give_tool(player)
  local stack = player.cursor_stack
  if stack and not stack.valid_for_read then
    stack.set_stack({ name = board.TOOL, count = 1 })
  end
end

function board.holding_tool(player)
  local stack = player.cursor_stack
  return stack and stack.valid_for_read and stack.name == board.TOOL
end

local function take_tool(player)
  if board.holding_tool(player) then player.cursor_stack.clear() end
end

-- ---------------------------------------------------------------------------
-- Zoom. On the board the wheel belongs to the cards (as in the GTNH planner):
-- the game's own zoom is held still and the mod zooms when the wheel is over
-- empty space.

local ZOOM_MIN, ZOOM_MAX, ZOOM_STEP = 0.1, 3, 1.18

local function hold_zoom(player, z)
  player.set_zoom_limits(defines.controllers.god, {
    closest = { zoom = z }, furthest = { zoom = z }, furthest_game_view = { zoom = ZOOM_MIN },
  })
  player.zoom = z
end

function board.zoom_step(player, dir)
  local s = board.session(player.index)
  local z = s.zoom or player.zoom or 1
  z = dir > 0 and z * ZOOM_STEP or z / ZOOM_STEP
  z = math.max(ZOOM_MIN, math.min(ZOOM_MAX, z))
  s.zoom = z
  hold_zoom(player, z)
end

local function lock_zoom(player, s)
  s.zoom = math.max(ZOOM_MIN, math.min(ZOOM_MAX, player.zoom or 1))
  hold_zoom(player, s.zoom)
end

local function release_zoom(player, s)
  if s.zoom then
    player.set_zoom_limits(defines.controllers.god, {})
    s.zoom = nil
  end
end

-- ---------------------------------------------------------------------------
-- Live drag preview (only the dragging player sees it)

function board.clear_preview(player)
  local s = board.session(player.index)
  destroy_ids(s.preview)
  s.preview = nil
end

--- @param drag table { card = id, part = "header"|"in"|"out", res, start = {x,y} } in plan coordinates
--- @param at table cursor in plan coordinates
function board.update_preview(player, plan, drag, at)
  local s = board.session(player.index)
  local card = plan_lib.card(plan, drag.card)
  local spec = card and catalog.spec(card, board.force_of(plan))
  if not spec then return end
  local o = board.origin(plan)
  local function P(x, y) return { x = o.x + x, y = o.y + y } end
  local surface = board.surface()
  local objs = {}
  for i, id in ipairs(s.preview or {}) do objs[i] = rendering.get_object_by_id(id) end

  if drag.part == "header" then
    local l, t, r, b = layout.box(card, spec)
    -- The same snapping the drop uses, so the outline is exactly where the card lands.
    local dx = layout.snap(card.x + (at.x - drag.start.x)) - card.x
    local dy = layout.snap(card.y + (at.y - drag.start.y)) - card.y
    local lt, rb = P(l + dx, t + dy), P(r + dx, b + dy)
    if objs[1] and objs[1].valid then
      objs[1].left_top, objs[1].right_bottom = lt, rb
    else
      board.clear_preview(player)
      local box = rendering.draw_rectangle({ surface = surface, color = COLORS.pending, filled = false, width = 3,
        left_top = lt, right_bottom = rb, players = { player } })
      s.preview = { box.id }
    end
  else
    local x, y = layout.port_point(card, spec, drag.part, drag.res)
    if not x then return end
    local from, to = P(x, y), P(at.x, at.y)
    if objs[1] and objs[1].valid then
      objs[1].to = to
    else
      board.clear_preview(player)
      local color = string.sub(drag.res, 1, 6) == "fluid/" and COLORS.wire_fluid or COLORS.wire_item
      local line = rendering.draw_line({ surface = surface, color = color, width = 3, from = from, to = to,
        players = { player }, dash_length = 0.4, gap_length = 0.2 })
      s.preview = { line.id }
    end
  end
end

-- ---------------------------------------------------------------------------
-- Visiting the board

function board.on_board(player)
  local s = storage.players[player.index]
  return s and s.on_board and player.surface.name == board.SURFACE
end

function board.enter(player, plan)
  local s = board.session(player.index)
  local surface = board.surface()
  if not s.on_board then
    if player.controller_type == defines.controllers.remote then player.exit_remote_view() end
    s.back = {
      controller = player.controller_type,
      character = player.character,
      surface = player.surface.index,
      position = player.position,
    }
    local ch = player.character
    if ch and ch.valid then
      s.back.destructible = ch.destructible
      ch.destructible = false
    end
    if player.controller_type ~= defines.controllers.god then
      player.set_controller({ type = defines.controllers.god })
    end
    hide_hud(player, s)
    lock_zoom(player, s)
  end
  s.on_board = true
  s.plan_id = plan.id
  s.selected, s.moving, s.wire = nil, nil, nil
  local o = board.origin(plan)
  local cx, cy = 0, 0
  if #plan.cards > 0 then
    local minx, miny, maxx, maxy = math.huge, math.huge, -math.huge, -math.huge
    for _, c in ipairs(plan.cards) do
      minx, miny = math.min(minx, c.x), math.min(miny, c.y)
      maxx, maxy = math.max(maxx, c.x + layout.CARD_W), math.max(maxy, c.y + 6)
    end
    cx, cy = (minx + maxx) / 2, (miny + maxy) / 2
  end
  player.teleport({ x = o.x + cx, y = o.y + cy }, surface)
  if not storage.results[plan.id] then board.resolve(plan) end
  if not storage.render[plan.id] then board.draw(plan) end
  board.give_tool(player)
  board.draw_overlay(player)
end

--- Returns the player to where they were. Safe to call when not on the board.
function board.leave(player)
  local s = board.session(player.index)
  board.clear_overlay(player)
  board.clear_preview(player)
  board.draw_hover(player, nil)
  s.hint = nil
  local back = s.back
  local was_on = s.on_board
  -- Off the board first, so clearing the cursor doesn't hand the tool back.
  s.on_board, s.plan_id, s.selected, s.moving, s.wire, s.back, s.drag = false, nil, nil, nil, nil, nil, nil
  if was_on then take_tool(player) end
  restore_hud(player, s)
  release_zoom(player, s)
  if not back then return end
  local ch = back.character
  if ch and ch.valid then
    if back.destructible ~= nil then ch.destructible = back.destructible end
    player.set_controller({ type = defines.controllers.character, character = ch })
    return
  end
  local surface = game.get_surface(back.surface) or game.surfaces[1]
  player.teleport(back.position or { 0, 0 }, surface)
  if back.controller and back.controller ~= defines.controllers.god
    and back.controller ~= defines.controllers.character
    and back.controller ~= defines.controllers.remote then
    pcall(function() player.set_controller({ type = back.controller }) end)
  end
  if back.controller == defines.controllers.character then
    player.print("Factory Flow Planner: your character was no longer there, so you are in god mode.")
  end
end

-- ---------------------------------------------------------------------------
-- Hit testing

--- @return table|nil card, table|nil hit, table local_position
function board.pick(plan, position)
  local o = board.origin(plan)
  local lx, ly = position.x - o.x, position.y - o.y
  local force = board.force_of(plan)
  for i = #plan.cards, 1, -1 do
    local c = plan.cards[i]
    local spec = catalog.spec(c, force)
    if spec then
      local hit = layout.hit(c, spec, lx, ly)
      if hit then return c, hit, { x = lx, y = ly } end
    end
  end
  return nil, nil, { x = lx, y = ly }
end

return board
