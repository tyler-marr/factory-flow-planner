-- Card geometry, laid out like the GTNH planner's cards. One function,
-- `geometry`, describes every part of a card; drawing, click hit-testing and
-- the hover hotspots all read it, so they always agree.
-- Pure Lua (also loaded in the data stage for the hotspot sizes).
--
-- Recipe card:
--   +------------------------------------------------------------+
--   | [icon] Recipe name                         +50% speed +10% |  header
--   | +-------------+   Machine name      +-------------+        |
--   | |icon 92/min  |   [ machine icon ]  | 8/min   icon|        |  tiles: inputs left,
--   | |   Water     |      x0.25          |   Sulfur    |        |  outputs right
--   | +-------------+      up to 1        +-------------+        |
--   | +-------------+      26 kW                                 |
--   | |icon 92/min  |  [mods x3][12 beac]                          |
--   | +-------------+                                            |
--   | SHORT of Sulfur                                   0.25 / 1 |  footer
--   +------------------------------------------------------------+
-- Panel (supply / output): a header and one tile per item.

local layout = {}

layout.GRID = 1
layout.PAD = 0.3
layout.TILE_W = 4.4
layout.TILE_H = 1.3
layout.TILE_STEP = 2.0
layout.MID_W = 5.2
layout.HEADER_H = 1.1
layout.FOOTER_H = 0.8
layout.MID_H = 4.9
layout.CARD_W = layout.PAD + layout.TILE_W + 0.2 + layout.MID_W + 0.2 + layout.TILE_W + layout.PAD
layout.PANEL_W = 7.0
layout.PANEL_HEADER_H = 1.1
layout.PANEL_TILE_W = layout.PANEL_W - 2 * layout.PAD

-- Hover hotspots: one entity prototype per kind of control, sized to it.
layout.HOTSPOTS = {
  header = { name = "ffp-hot-header", w = layout.CARD_W, h = layout.HEADER_H },
  machine = { name = "ffp-hot-machine", w = layout.MID_W - 0.2, h = 2.1 },
  count = { name = "ffp-hot-count", w = layout.MID_W - 0.2, h = 1.0 },
  modules = { name = "ffp-hot-modules", w = layout.MID_W / 2 - 0.1, h = 0.8 },
  beacons = { name = "ffp-hot-beacons", w = layout.MID_W / 2 - 0.1, h = 0.8 },
  ["in"] = { name = "ffp-hot-in", w = layout.TILE_W, h = layout.TILE_H },
  out = { name = "ffp-hot-out", w = layout.TILE_W, h = layout.TILE_H },
  panel_header = { name = "ffp-hot-panel-header", w = layout.PANEL_W, h = layout.PANEL_HEADER_H },
  supply = { name = "ffp-hot-supply", w = layout.PANEL_TILE_W, h = layout.TILE_H },
  demand = { name = "ffp-hot-demand", w = layout.PANEL_TILE_W, h = layout.TILE_H },
}

-- Cards sit on half tiles (x.5), which puts every port on a tile centre:
-- belts and pipes then line up with the ports exactly.
function layout.snap(v)
  return math.floor(v) + 0.5
end

function layout.width(spec)
  return spec.panel and layout.PANEL_W or layout.CARD_W
end

local function tiles_h(n)
  if n <= 0 then return 0 end
  return n * layout.TILE_STEP - (layout.TILE_STEP - layout.TILE_H) + 0.5
end

--- Everything about where a card's parts are, in plan coordinates.
--- parts: list of { part, res?, x1, y1, x2, y2, hot = hotspot kind, port = {x, y}? }
function layout.geometry(card, spec)
  local l, t = card.x, card.y
  local parts = {}
  local g = { parts = parts }
  local function add(p) parts[#parts + 1] = p; return p end

  if spec.panel then
    local n = math.max(#(spec.inputs or {}), #(spec.outputs or {}))
    local h = layout.PANEL_HEADER_H + tiles_h(math.max(n, 1))
    local r = l + layout.PANEL_W
    g.l, g.t, g.r, g.b = l, t, r, t + h
    add({ part = "header", x1 = l, y1 = t, x2 = r, y2 = t + layout.PANEL_HEADER_H, hot = "panel_header" })
    local source = card.kind == "source"
    local list = source and spec.outputs or spec.inputs
    for i, p in ipairs(list) do
      local y1 = t + layout.PANEL_HEADER_H + 0.25 + (i - 1) * layout.TILE_STEP
      add({
        part = source and "out" or "in", res = p.res, index = i,
        x1 = l + layout.PAD, y1 = y1, x2 = r - layout.PAD, y2 = y1 + layout.TILE_H,
        hot = source and "supply" or "demand",
        port = { x = source and r or l, y = y1 + layout.TILE_H / 2 },
      })
    end
    g.empty_y = t + layout.PANEL_HEADER_H + 0.25 + layout.TILE_H / 2
    return g
  end

  local n = math.max(#spec.inputs, #spec.outputs)
  local body_h = math.max(layout.MID_H, tiles_h(n))
  local r = l + layout.CARD_W
  local bt = t + layout.HEADER_H
  g.l, g.t, g.r = l, t, r
  g.body_top = bt
  g.footer_top = bt + body_h
  g.b = g.footer_top + layout.FOOTER_H

  add({ part = "header", x1 = l, y1 = t, x2 = r, y2 = bt, hot = "header" })
  local mx1 = l + layout.PAD + layout.TILE_W + 0.2
  local mx2 = mx1 + layout.MID_W
  g.mid_x1, g.mid_x2, g.mid_cx = mx1, mx2, (mx1 + mx2) / 2
  -- The middle block sits at the top of the body.
  add({ part = "machine", x1 = mx1 + 0.1, y1 = bt + 0.1, x2 = mx2 - 0.1, y2 = bt + 2.2, hot = "machine" })
  add({ part = "count", x1 = mx1 + 0.1, y1 = bt + 2.2, x2 = mx2 - 0.1, y2 = bt + 3.2, hot = "count" })
  g.power_y = bt + 3.45
  add({ part = "modules", x1 = mx1 + 0.05, y1 = bt + 3.85, x2 = g.mid_cx - 0.05, y2 = bt + 4.65, hot = "modules" })
  add({ part = "beacons", x1 = g.mid_cx + 0.05, y1 = bt + 3.85, x2 = mx2 - 0.05, y2 = bt + 4.65, hot = "beacons" })

  for i, p in ipairs(spec.inputs) do
    local y1 = bt + 0.25 + (i - 1) * layout.TILE_STEP
    add({
      part = "in", res = p.res, index = i,
      x1 = l + layout.PAD, y1 = y1, x2 = l + layout.PAD + layout.TILE_W, y2 = y1 + layout.TILE_H,
      hot = "in", port = { x = l, y = y1 + layout.TILE_H / 2 },
    })
  end
  for i, p in ipairs(spec.outputs) do
    local y1 = bt + 0.25 + (i - 1) * layout.TILE_STEP
    add({
      part = "out", res = p.res, index = i,
      x1 = r - layout.PAD - layout.TILE_W, y1 = y1, x2 = r - layout.PAD, y2 = y1 + layout.TILE_H,
      hot = "out", port = { x = r, y = y1 + layout.TILE_H / 2 },
    })
  end
  return g
end

--- Bounding box of a card: left, top, right, bottom.
function layout.box(card, spec)
  local g = layout.geometry(card, spec)
  return g.l, g.t, g.r, g.b
end

--- Where a wire attaches: inputs on the left edge, outputs on the right.
function layout.port_point(card, spec, side, res)
  for _, p in ipairs(layout.geometry(card, spec).parts) do
    if p.part == side and p.res == res then return p.port.x, p.port.y, p.index end
  end
end

--- What is under (px, py) on this card. nil when outside it, else
--- { part = "header" | "count" | "machine" | "modules" | "beacons" | "in" | "out" | "body", res?, index? }
function layout.hit(card, spec, px, py)
  local g = layout.geometry(card, spec)
  if px < g.l or px > g.r or py < g.t or py > g.b then return nil end
  for _, p in ipairs(g.parts) do
    if px >= p.x1 and px <= p.x2 and py >= p.y1 and py <= p.y2 then
      return { part = p.part, res = p.res, index = p.index }
    end
  end
  -- The tile's port dot sits on the card edge: count the margin beside a tile as the tile.
  for _, p in ipairs(g.parts) do
    if p.port and py >= p.y1 and py <= p.y2 and math.abs(px - p.port.x) <= layout.PAD + 0.05 then
      return { part = p.part, res = p.res, index = p.index }
    end
  end
  return { part = "body" }
end

--- Parts that belong to the card itself (dragging them moves the card).
function layout.is_card_part(part)
  return part ~= "in" and part ~= "out"
end

--- Orthogonal route from an output port to an input port.
--- Returns a list of points and the point to hang the rate label on.
function layout.route(x1, y1, x2, y2, low_y)
  if x2 >= x1 + 1.5 then
    -- Turn just before the card being fed, so the wire doesn't cut across
    -- cards in between.
    local mid = math.max(x1 + 0.75, x2 - 1.5)
    return { { x1, y1 }, { mid, y1 }, { mid, y2 }, { x2, y2 } }, { mid, (y1 + y2) / 2 }
  end
  -- Backwards (a loop or a consumer to the left): go round underneath.
  local a, b = x1 + 0.75, x2 - 0.75
  local y = low_y or math.max(y1, y2) + 2
  return { { x1, y1 }, { a, y1 }, { a, y }, { b, y }, { b, y2 }, { x2, y2 } }, { (a + b) / 2, y }
end

--- First free spot for a card of this spec near (x, y), moving down in steps.
function layout.free_spot(cards, spec_of, spec, x, y)
  x, y = layout.snap(x), layout.snap(y)
  local _, _, w, h = layout.box({ x = 0, y = 0, kind = spec.panel and "source" or nil }, spec)
  for _ = 1, 200 do
    local clash = false
    for _, c in ipairs(cards) do
      local cs = spec_of(c)
      if cs then
        local l, t, r, b = layout.box(c, cs)
        if x < r + 1 and x + w > l - 1 and y < b + 1 and y + h > t - 1 then
          clash = true
          y = layout.snap(b + 1.5)
          break
        end
      end
    end
    if not clash then return x, y end
  end
  return x, y
end

return layout
