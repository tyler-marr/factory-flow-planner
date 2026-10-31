-- Routes one link across the board's tile grid, the way a player would lay a
-- belt or pipe: straight runs, turns, and underground hops (over other links
-- or under cards) up to the underground's real reach. Pure Lua, deterministic.
--
-- Directions: 1 east, 2 south, 3 west, 4 north.

local router = {}

router.DX = { 1, 0, -1, 0 }
router.DY = { 0, 1, 0, -1 }

local function key(x, y) return (x + 1000000) * 2000000 + (y + 1000000) end
router.key = key

local function rot(d, t) return (d - 1 + t) % 4 + 1 end
router.rot = rot
function router.back(d) return rot(d, 2) end

-- Binary heap on f, ties broken by insertion order (deterministic).
local function heap_push(h, f, seq, v)
  local n = #h + 1
  h[n] = { f, seq, v }
  while n > 1 do
    local p = math.floor(n / 2)
    local a, b = h[p], h[n]
    if a[1] < b[1] or (a[1] == b[1] and a[2] <= b[2]) then break end
    h[p], h[n] = b, a
    n = p
  end
end

local function heap_pop(h)
  local top = h[1]
  local last = table.remove(h)
  if #h > 0 then
    h[1] = last
    local n, size = 1, #h
    while true do
      local l, r, m = 2 * n, 2 * n + 1, n
      local function less(i, j) return h[i][1] < h[j][1] or (h[i][1] == h[j][1] and h[i][2] < h[j][2]) end
      if l <= size and less(l, m) then m = l end
      if r <= size and less(r, m) then m = r end
      if m == n then break end
      h[m], h[n] = h[n], h[m]
      n = m
    end
  end
  return top
end

--- @param a table {
---   starts = { { x, y, d = dir, cost = n, meta = any } },  -- where the link may begin, moving in d
---   goals = { { x, y, out = dir, meta = any } },           -- tiles the link may end on, its last belt pointing out
---   (or start = {x, y} / goal = {x, y}: one start moving east, one goal pointing east)
---   passable = fun(x, y): number|nil,     -- nil: can't stand here; else extra cost
---   merge = fun(x, y): boolean,           -- stepping into this tile joins an existing link (sideload fallback)
---   no_jump_from = fun(x, y): boolean,    -- tiles an underground may not start on
---   max_jump = integer, bounds = {x1, y1, x2, y2}, limit = integer
--- }
--- @return table|nil path: list of { x, y, dir, kind = "line" | "in" | "out" }
--- @return table|nil merged_into {x, y}, any start_meta, any goal_meta
function router.route(a)
  local starts = a.starts or { { a.start[1], a.start[2], d = 1, cost = 0 } }
  local goal_list = a.goals or { { a.goal[1], a.goal[2], out = 1 } }
  local b = a.bounds
  local max_jump = math.max(1, a.max_jump or 4)
  local limit = a.limit or 60000

  local goals = {}
  for _, gl in ipairs(goal_list) do
    local k = key(gl[1], gl[2])
    goals[k] = goals[k] or {}
    table.insert(goals[k], gl)
  end

  local function inb(x, y) return x >= b[1] and x <= b[3] and y >= b[2] and y <= b[4] end
  local function h(x, y)
    local best = math.huge
    for _, gl in ipairs(goal_list) do
      local v = math.abs(x - gl[1]) + math.abs(y - gl[2])
      if v < best then best = v end
    end
    return best
  end

  -- State: tile, direction we arrived moving in, and whether we just came out
  -- of an underground (an exit can't turn).
  local function sid(x, y, d, ex) return key(x, y) * 8 + (d - 1) * 2 + (ex and 1 or 0) end

  local g, parent, info = {}, {}, {}
  local heap, seq = {}, 0
  for _, st in ipairs(starts) do
    if a.passable(st[1], st[2]) ~= nil then
      local s0 = sid(st[1], st[2], st.d, false)
      local c = st.cost or 0
      if g[s0] == nil or c < g[s0] then
        g[s0] = c
        info[s0] = { x = st[1], y = st[2], d = st.d, ex = false, start = st }
        seq = seq + 1
        heap_push(heap, c + h(st[1], st[2]), seq, s0)
      end
    end
  end
  local closed = {}
  local found, found_goal
  local expanded = 0

  while #heap > 0 do
    local top = heap_pop(heap)
    local s = top[3]
    if not closed[s] then
      closed[s] = true
      expanded = expanded + 1
      if expanded > limit then break end
      local st = info[s]
      if st.merge then found = s break end
      local x, y, d, ex = st.x, st.y, st.d, st.ex
      for _, gl in ipairs(goals[key(x, y)] or {}) do
        -- Its last belt points `out`: we must not have arrived moving the opposite way,
        -- and an underground exit can't turn.
        if d ~= router.back(gl.out) and (not ex or d == gl.out) then
          found, found_goal = s, gl
          break
        end
      end
      if found then break end
      local base = g[s]
      local function relax(nx, ny, nd, nex, cost, move)
        local ns = sid(nx, ny, nd, nex)
        local ng = base + cost
        if g[ns] == nil or ng < g[ns] - 1e-9 then
          g[ns] = ng
          parent[ns] = { s, move, nd }
          info[ns] = { x = nx, y = ny, d = nd, ex = nex }
          seq = seq + 1
          heap_push(heap, ng + h(nx, ny), seq, ns)
        end
      end
      for _, t in ipairs(ex and { 0 } or { 0, 1, -1 }) do
        local nd = rot(d, t)
        local nx, ny = x + router.DX[nd], y + router.DY[nd]
        if inb(nx, ny) then
          if a.merge and a.merge(nx, ny) then
            -- Joining a link that already feeds the same input (sideload).
            local ns = sid(nx, ny, nd, false) + 0.5
            local ng = base + 1
            if g[ns] == nil or ng < g[ns] then
              g[ns] = ng
              parent[ns] = { s, "step", nd }
              info[ns] = { x = nx, y = ny, d = nd, ex = false, merge = true }
              seq = seq + 1
              heap_push(heap, ng, seq, ns)
            end
          else
            local extra = a.passable(nx, ny)
            if extra ~= nil then relax(nx, ny, nd, false, 1 + (t ~= 0 and 0.4 or 0) + extra, "step") end
          end
        end
      end
      -- Underground hop straight ahead. Not from an exit, nor from a shared trunk tile.
      if not ex and not (a.no_jump_from and a.no_jump_from(x, y)) then
        for k = 2, max_jump do
          local nx, ny = x + k * router.DX[d], y + k * router.DY[d]
          if not inb(nx, ny) then break end
          local extra = a.passable(nx, ny)
          if extra ~= nil and not (a.merge and a.merge(nx, ny)) then
            relax(nx, ny, d, true, 4 + k + extra, "jump")
          end
        end
      end
    end
  end
  if not found then return nil end

  -- Walk back: each transition fixes the outgoing direction of the tile it left.
  local chain = {}
  local s = found
  while s do
    chain[#chain + 1] = s
    local p = parent[s]
    s = p and p[1] or nil
  end
  local path = {}
  local merged_into
  local start_meta = info[chain[#chain]].start and info[chain[#chain]].start.meta
  for i = #chain, 1, -1 do
    local st = info[chain[i]]
    local nxt = chain[i - 1]
    if st.merge then
      merged_into = { st.x, st.y }
    else
      local entry = { x = st.x, y = st.y, kind = "line" }
      if nxt then
        local p = parent[nxt]
        entry.dir = p[3]
        if p[2] == "jump" then entry.kind = "in" end
      else
        entry.dir = found_goal and found_goal.out or 1
      end
      if st.ex then entry.kind = "out"; entry.dir = st.d end
      path[#path + 1] = entry
    end
  end
  return path, merged_into, start_meta, found_goal and found_goal.meta
end

return router
