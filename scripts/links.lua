-- Lays out every link of a plan as belts (items) or pipes (fluids) on the tile
-- grid. Pure Lua: the belt and pipe kinds come in as a "kit" read from the
-- game's prototypes, so modded belts work and this is tested outside the game.
--
-- kit = {
--   belts = { { name, underground, items_per_s, reach } ... } slowest first,
--   pipe = { name, underground, reach } | nil,
-- }

local layout = require("scripts.layout")
local router = require("scripts.router")

local links = {}

local key = router.key

--- The slowest belt that carries the rate, or the fastest and how many of it.
function links.pick_belt(kit, per_s)
  local belts = kit.belts
  if #belts == 0 then return nil, 1 end
  for _, b in ipairs(belts) do
    if per_s <= b.items_per_s * (1 + 1e-9) then return b, 1 end
  end
  local fastest = belts[#belts]
  return fastest, math.ceil(per_s / fastest.items_per_s - 1e-9)
end

--- @param plan table
--- @param spec_of fun(card): table|nil
--- @param flows table wire id -> rate per second
--- @param kit table
--- @return table laid: list of { wire, fluid, path, merged_into, kind = belt|pipe entry, mult, start_tile }
--- @return table failed: list of wires that found no route (drawn as lines instead)
--- @param prev table|nil the previous result ({ laid = ... }): links whose ends,
---   item and belt tier are unchanged, and whose tiles are still clear, keep their
---   route; only the others are routed again (around the kept ones).
function links.lay(plan, spec_of, flows, kit, prev)
  local geo, blocked = {}, {}
  local minx, miny, maxx, maxy = math.huge, math.huge, -math.huge, -math.huge
  for _, c in ipairs(plan.cards) do
    local spec = spec_of(c)
    if spec then
      local l, t, r, b = layout.box(c, spec)
      geo[c.id] = { card = c, spec = spec, l = l, t = t, r = r, b = b }
      for x = math.floor(l), math.ceil(r) - 1 do
        for y = math.floor(t), math.ceil(b) - 1 do blocked[key(x, y)] = true end
      end
      minx, miny = math.min(minx, l), math.min(miny, t)
      maxx, maxy = math.max(maxx, r), math.max(maxy, b)
    end
  end
  local laid, failed = {}, {}
  if minx == math.huge then return laid, failed end
  local bounds = { math.floor(minx) - 14, math.floor(miny) - 14, math.ceil(maxx) + 14, math.ceil(maxy) + 14 }

  local occ = {} -- tile key -> { from_g, to_g, fluid }

  local wires = {}
  for _, w in ipairs(plan.wires) do wires[#wires + 1] = w end
  table.sort(wires, function(a, b) return a.id < b.id end)

  -- Every link's first and last tile is reserved before any routing, so a
  -- link laid earlier can never block another's way in or out.
  local reserved = {} -- tile key -> { from_g?, to_g?, fluid }
  for _, w in ipairs(wires) do
    local A, B = geo[w.from], geo[w.to]
    if A and B then
      local ax, ay = layout.port_point(A.card, A.spec, "out", w.res)
      local bx, by = layout.port_point(B.card, B.spec, "in", w.res)
      if ax and bx then
        local fluid = string.sub(w.res, 1, 6) == "fluid/"
        local ks, kg = key(math.ceil(ax) - 1, math.floor(ay)), key(math.floor(bx), math.floor(by))
        -- Port tiles sit half under the card edge: the belt runs in under the card.
        blocked[ks], blocked[kg] = nil, nil
        -- Reserve the tile under the edge and the one just outside it.
        local sx0, sy0 = math.ceil(ax) - 1, math.floor(ay)
        local gx0, gy0 = math.floor(bx), math.floor(by)
        for _, k in ipairs({ ks, key(sx0 + 1, sy0) }) do
          reserved[k] = reserved[k] or { from_g = w.from .. "|" .. w.res, fluid = fluid }
        end
        for _, k in ipairs({ kg, key(gx0 - 1, gy0) }) do
          reserved[k] = reserved[k] or { to_g = w.to .. "|" .. w.res, fluid = fluid }
        end
      end
    end
  end

  -- Total rate leaving each output and entering each input: a trunk carries all of it.
  local from_sum, to_sum = {}, {}
  for _, w in ipairs(wires) do
    local f = flows[w.id] or 0
    local fg, tg = w.from .. "|" .. w.res, w.to .. "|" .. w.res
    from_sum[fg] = (from_sum[fg] or 0) + f
    to_sum[tg] = (to_sum[tg] or 0) + f
  end
  local from_laid, to_laid = {}, {} -- group -> laid entries (belts only), for splitters
  local split_used = {}              -- trunk tiles that already hold a splitter

  -- The first link out of an output and into an input is its trunk, sized for
  -- everything along it; the others carry their own rate.
  local first_from, first_to = {}, {}
  for _, w in ipairs(wires) do
    local fg, tg = w.from .. "|" .. w.res, w.to .. "|" .. w.res
    first_from[fg] = first_from[fg] or w.id
    first_to[tg] = first_to[tg] or w.id
  end
  local function tier_rate(w)
    local fg, tg = w.from .. "|" .. w.res, w.to .. "|" .. w.res
    if first_from[fg] == w.id and first_to[tg] == w.id then
      return math.max(from_sum[fg] or 0, to_sum[tg] or 0)
    end
    return flows[w.id] or 0
  end

  --- What a link's route depends on besides its surroundings.
  local function wire_key(w)
    local A, B = geo[w.from], geo[w.to]
    if not (A and B) then return nil end
    local ax, ay = layout.port_point(A.card, A.spec, "out", w.res)
    local bx, by = layout.port_point(B.card, B.spec, "in", w.res)
    if not (ax and bx) then return nil end
    local tier, mult = "pipe", 1
    if string.sub(w.res, 1, 6) ~= "fluid/" then
      local b
      b, mult = links.pick_belt(kit, tier_rate(w))
      tier = b and b.name or "none"
    end
    return w.res .. "|" .. ax .. "," .. ay .. ">" .. bx .. "," .. by .. "|" .. tier .. "x" .. mult
  end

  -- Keep the routes that are still valid.
  local reused = {}
  if prev and prev.laid then
    local by_wire = {}
    for _, L in ipairs(prev.laid) do by_wire[L.wire.id] = L end
    local cand = {}
    for _, w in ipairs(wires) do
      local L = by_wire[w.id]
      local k = L and wire_key(w)
      if L and k and L.key == k then
        local fg, tg = w.from .. "|" .. w.res, w.to .. "|" .. w.res
        local ok = true
        local function clear(x, y)
          local kk = key(x, y)
          if blocked[kk] then return false end
          local r = reserved[kk]
          if r and r.from_g ~= fg and r.to_g ~= tg then return false end
          return true
        end
        for _, t in ipairs(L.path) do
          if not clear(t.x, t.y) then ok = false break end
        end
        for _, a in ipairs(L.attach or {}) do
          if not clear(a.sx, a.sy) then ok = false end
        end
        if ok then cand[w.id] = { w = w, L = L } end
      end
    end
    -- A link hanging off a trunk's splitter is kept only if that trunk is.
    local changed = true
    while changed do
      changed = false
      for id, c in pairs(cand) do
        for _, a in ipairs(c.L.attach or {}) do
          if not cand[a.trunk] then cand[id] = nil; changed = true break end
        end
      end
    end
    -- Copy the kept routes (splitter marks are re-applied below from the kept branches).
    for _, w in ipairs(wires) do
      local c = cand[w.id]
      if c then
        local path = {}
        for _, t in ipairs(c.L.path) do
          path[#path + 1] = { x = t.x, y = t.y, dir = t.dir, kind = t.kind == "split" and "line" or t.kind }
        end
        local L = {}
        for k2, v in pairs(c.L) do L[k2] = v end
        L.path, L.wire = path, w
        reused[w.id] = L
      end
    end
    for _, L in pairs(reused) do
      for _, a in ipairs(L.attach or {}) do
        local trunk = reused[a.trunk]
        for _, t in ipairs(trunk.path) do
          if t.x == a.tx and t.y == a.ty then t.kind = "split" end
        end
        split_used[key(a.tx, a.ty)] = true
      end
    end
    for _, w in ipairs(wires) do
      local L = reused[w.id]
      if L then
        local fg, tg = w.from .. "|" .. w.res, w.to .. "|" .. w.res
        for _, t in ipairs(L.path) do occ[key(t.x, t.y)] = { from_g = fg, to_g = tg, fluid = L.fluid } end
        for _, a in ipairs(L.attach or {}) do occ[key(a.sx, a.sy)] = { from_g = fg, to_g = tg, fluid = false } end
        if not L.fluid then
          from_laid[fg] = from_laid[fg] or {}
          table.insert(from_laid[fg], L)
          to_laid[tg] = to_laid[tg] or {}
          table.insert(to_laid[tg], L)
        end
      end
    end
  end

  --- Straight stretches of laid trunks where a splitter fits: the trunk tile T
  --- (fed straight from behind, leaving straight ahead) and a free tile S beside it.
  local function splitter_slots(entries, passable, want)
    local slots = {}
    for _, L in ipairs(entries or {}) do
      local path = L.path
      for i = 2, #path - 1 do
        local prev, t, nxt = path[i - 1], path[i], path[i + 1]
        local d = t.dir
        if t.kind == "line" and prev.kind ~= "in" and prev.dir == d and not split_used[key(t.x, t.y)]
          and prev.x == t.x - router.DX[d] and prev.y == t.y - router.DY[d]
          and nxt.x == t.x + router.DX[d] and nxt.y == t.y + router.DY[d] then
          for _, side in ipairs({ 1, -1 }) do
            local pd = router.rot(d, side)
            local sx, sy = t.x + router.DX[pd], t.y + router.DY[pd]
            -- Branch: leaves from the splitter's free side. Merge: arrives at it from behind.
            local ex, ey
            if want == "branch" then ex, ey = sx + router.DX[d], sy + router.DY[d]
            else ex, ey = sx - router.DX[d], sy - router.DY[d] end
            if passable(sx, sy) == 0 and passable(ex, ey) == 0 then
              slots[#slots + 1] = { ex, ey, d = d, out = d, cost = 0,
                meta = { trunk = L, t = t, sx = sx, sy = sy, d = d, side = side } }
            end
          end
        end
      end
    end
    return slots
  end

  for _, w in ipairs(wires) do
    if reused[w.id] then
      reused[w.id].rate = tier_rate(w)
      laid[#laid + 1] = reused[w.id]
      goto continue
    end
    local A, B = geo[w.from], geo[w.to]
    local ax, ay, bx, by
    if A then ax, ay = layout.port_point(A.card, A.spec, "out", w.res) end
    if B then bx, by = layout.port_point(B.card, B.spec, "in", w.res) end
    if not (ax and bx) then goto continue end
    do
      local fluid = string.sub(w.res, 1, 6) == "fluid/"
      local from_g, to_g = w.from .. "|" .. w.res, w.to .. "|" .. w.res
      local branching = not fluid and from_laid[from_g] ~= nil
      local merging = not fluid and to_laid[to_g] ~= nil
      local rate = tier_rate(w)
      local entry, mult
      if fluid then
        entry, mult = kit.pipe, 1
      else
        entry, mult = links.pick_belt(kit, rate)
      end
      if not entry then failed[#failed + 1] = w; goto continue end

      local sx, sy = math.ceil(ax) - 1, math.floor(ay)
      local gx, gy = math.floor(bx), math.floor(by)
      local share_trunk = true -- pipes and fallbacks share a trunk tile by tile
      local avoid = {}         -- splitter side tiles this route must not run over

      local function other(r)
        return r and r.from_g ~= from_g and r.to_g ~= to_g
      end
      local function passable(x, y)
        local k = key(x, y)
        if blocked[k] or avoid[k] then return nil end
        local o = occ[k]
        if o then
          if share_trunk and o.from_g == from_g then return 0.2 end
          return nil
        end
        if other(reserved[k]) then return nil end
        if fluid then
          for d = 1, 4 do
            local nk = key(x + router.DX[d], y + router.DY[d])
            local n = occ[nk]
            if n and n.fluid and n.from_g ~= from_g and n.to_g ~= to_g then return nil end
            local r = reserved[nk]
            if r and r.fluid and other(r) and not occ[nk] then return nil end
          end
        end
        return 0
      end
      local function merge(x, y)
        local o = occ[key(x, y)]
        return o ~= nil and o.to_g == to_g and o.from_g ~= from_g
      end
      local function no_jump_from(x, y) return occ[key(x, y)] ~= nil end

      -- Splitters: start from a trunk of the same output, end at a trunk into the same input.
      local starts, goals, use_merge = nil, nil, merge
      if branching then
        share_trunk = false
        local slots = splitter_slots(from_laid[from_g], passable, "branch")
        if #slots > 0 then starts = slots else share_trunk = true end
      end
      if merging then
        local was = share_trunk
        share_trunk = false
        local slots = splitter_slots(to_laid[to_g], passable, "merge")
        share_trunk = was
        if #slots > 0 then goals = slots; use_merge = nil end
      end
      for _, list in ipairs({ starts or {}, goals or {} }) do
        for _, sl in ipairs(list) do avoid[key(sl.meta.sx, sl.meta.sy)] = true end
      end

      local path, merged, smeta, gmeta = router.route({
        starts = starts or { { sx, sy, d = 1, cost = 0 } },
        goals = goals or { { gx, gy, out = 1 } },
        passable = passable, merge = use_merge,
        no_jump_from = no_jump_from, max_jump = entry.reach, bounds = bounds,
      })
      if not path then failed[#failed + 1] = w; goto continue end

      local splitters, attach = {}, {}
      for _, m in ipairs({ smeta or false, gmeta or false }) do
        if m then
          attach[#attach + 1] = { trunk = m.trunk.wire.id, tx = m.t.x, ty = m.t.y, sx = m.sx, sy = m.sy }
          -- The splitter takes the trunk tile's place: that belt isn't built.
          m.t.kind = "split"
          split_used[key(m.t.x, m.t.y)] = true
          occ[key(m.sx, m.sy)] = { from_g = from_g, to_g = to_g, fluid = false }
          -- side 1: the free tile is on the right of travel, so the trunk is the left lane pair.
          splitters[#splitters + 1] = {
            x = (m.t.x + m.sx) / 2 + 0.5, y = (m.t.y + m.sy) / 2 + 0.5, dir = m.d,
            name = m.trunk.kind.splitter, trunk_side = m.side == 1 and "left" or "right",
          }
        end
      end

      local new_tiles = {}
      for _, t in ipairs(path) do
        local k = key(t.x, t.y)
        if not occ[k] then
          occ[k] = { from_g = from_g, to_g = to_g, fluid = fluid }
          new_tiles[#new_tiles + 1] = t
        end
      end
      local L = {
        wire = w, fluid = fluid, path = new_tiles, merged_into = merged, kind = entry, mult = mult,
        rate = rate, splitters = splitters, attach = attach, key = wire_key(w),
        fed = true,                              -- every link is fed at its own rate (planner splitters don't split)
        drains = smeta ~= nil or (gmeta == nil and merged == nil), -- a merge hands its items on
        start_tile = { path[1].x, path[1].y },
      }
      if gmeta then L.drains = false end
      laid[#laid + 1] = L
      if not fluid then
        from_laid[from_g] = from_laid[from_g] or {}
        table.insert(from_laid[from_g], L)
        to_laid[to_g] = to_laid[to_g] or {}
        table.insert(to_laid[to_g], L)
      end
    end
    ::continue::
  end
  return laid, failed
end

--- One link's layout, so its entities are rebuilt only when it changes.
function links.link_signature(L)
  local parts = { L.kind.name, tostring(L.mult) }
  for _, t in ipairs(L.path) do parts[#parts + 1] = t.x .. "," .. t.y .. t.kind .. t.dir end
  for _, sp in ipairs(L.splitters or {}) do parts[#parts + 1] = "S" .. sp.x .. "," .. sp.y .. sp.dir .. tostring(sp.name) end
  return table.concat(parts, ";")
end

--- A short signature of a layout, so entities are only rebuilt when it changes.
function links.signature(laid, failed)
  local parts = {}
  for _, L in ipairs(laid) do
    parts[#parts + 1] = L.wire.id .. ":" .. L.kind.name .. ":" .. L.mult
    for _, sp in ipairs(L.splitters or {}) do parts[#parts + 1] = "S" .. sp.x .. "," .. sp.y .. sp.dir .. tostring(sp.name) end
    for _, t in ipairs(L.path) do parts[#parts + 1] = t.x .. "," .. t.y .. t.kind .. t.dir end
  end
  for _, w in ipairs(failed) do parts[#parts + 1] = "f" .. w.id end
  return table.concat(parts, ";")
end

return links
