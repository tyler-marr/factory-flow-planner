-- Two-phase simplex for: minimize c.x subject to A x = b, x >= 0.
-- Pure Lua 5.2, no game API, so it runs the same on every client (lockstep
-- multiplayer) and can be tested outside the game.
--
-- Rows: { coefs = { [var] = value, ... }, rhs = number, basis_hint = var? }
-- basis_hint names a variable whose column is +1 in this row and 0 in every
-- other row; such rows start feasible without an artificial variable, which
-- keeps phase 1 tiny for planner models (every port row has its own slack).

local lp = {}

local EPS = 1e-9

local function pivot(T, z, rows_n, pr, pc, basis)
  local prow = T[pr]
  local pv = prow[pc]
  -- Normalise the pivot row and collect its non-zero columns once.
  local nz = {}
  for j, v in pairs(prow) do
    if v ~= 0 then
      local nv = v / pv
      if math.abs(nv) < 1e-15 then
        prow[j] = nil
      else
        prow[j] = nv
        nz[#nz + 1] = j
      end
    else
      prow[j] = nil
    end
  end
  prow[pc] = 1
  table.sort(nz) -- fixed order: identical floating point results on every machine

  local function eliminate(row)
    local f = row[pc]
    if f == nil or f == 0 then return end
    for k = 1, #nz do
      local j = nz[k]
      local nv = (row[j] or 0) - f * prow[j]
      if math.abs(nv) < 1e-13 then row[j] = nil else row[j] = nv end
    end
    row[pc] = nil
  end

  for r = 1, rows_n do
    if r ~= pr then eliminate(T[r]) end
  end
  eliminate(z)
  basis[pr] = pc
end

-- Runs simplex iterations on the tableau with objective row z.
-- z[j] is the reduced cost of column j, z.rhs (key "rhs" not used) handled via column 0.
local function iterate(T, z, rows_n, ncols, basis, banned, max_iter)
  local iter = 0
  while true do
    iter = iter + 1
    if iter > max_iter then return "iteration_limit" end
    local use_bland = iter > 50 + 4 * rows_n
    -- Entering column: most negative reduced cost (Dantzig), Bland's rule late on.
    local pc, best = nil, -EPS
    for j = 1, ncols do
      if not banned[j] then
        local v = z[j]
        if v and v < best then
          if use_bland then pc = j; break end
          best, pc = v, j
        end
      end
    end
    if not pc then return "optimal" end
    -- Leaving row: minimum ratio, ties to the lowest basis variable.
    local pr, ratio = nil, math.huge
    for r = 1, rows_n do
      local a = T[r][pc]
      if a and a > EPS then
        local q = (T[r][0] or 0) / a
        if q < ratio - EPS or (math.abs(q - ratio) <= EPS and pr and basis[r] < basis[pr]) then
          ratio, pr = q, r
        end
      end
    end
    if not pr then return "unbounded" end
    pivot(T, z, rows_n, pr, pc, basis)
  end
end

--- @param nvars integer number of structural variables (1..nvars)
--- @param costs table [var] = cost (missing = 0)
--- @param rows table list of rows (see top)
--- @return table { status = "optimal"|"infeasible"|"unbounded"|"iteration_limit", x = {[var]=value}, objective = number }
function lp.solve(nvars, costs, rows, opts)
  opts = opts or {}
  local max_iter = opts.max_iter or 20000
  local T, basis = {}, {}
  local rows_n = #rows
  local ncols = nvars
  local art_first = nvars + 1
  local banned = {}

  -- Column 0 holds the right-hand side.
  for r = 1, rows_n do
    local src = rows[r]
    local row = {}
    local sign = (src.rhs or 0) < 0 and -1 or 1
    for j, v in pairs(src.coefs) do
      if v ~= 0 then row[j] = sign * v end
    end
    row[0] = sign * (src.rhs or 0)
    local hint = src.basis_hint
    if hint and row[hint] == 1 then
      basis[r] = hint
    elseif hint and row[hint] == -1 and row[0] == 0 then
      -- A zero-rhs row may be negated freely.
      for j, v in pairs(row) do row[j] = -v end
      row[0] = 0
      basis[r] = hint
    else
      ncols = ncols + 1
      row[ncols] = 1
      basis[r] = ncols
    end
    T[r] = row
  end

  -- Phase 1: minimise the sum of artificials.
  local has_art = ncols >= art_first
  if has_art then
    local z = {}
    for r = 1, rows_n do
      if basis[r] >= art_first then
        for j, v in pairs(T[r]) do
          if j < art_first then z[j] = (z[j] or 0) - v end
        end
      end
    end
    local status = iterate(T, z, rows_n, ncols, basis, banned, max_iter)
    if status ~= "optimal" then return { status = status, x = {} } end
    if -(z[0] or 0) > 1e-7 * math.max(1, rows_n) then
      return { status = "infeasible", x = {} }
    end
    -- Drive remaining artificials out of the basis; drop redundant rows.
    local r = 1
    while r <= rows_n do
      if basis[r] >= art_first then
        local pc
        for j = 1, nvars do
          local v = T[r][j]
          if v and math.abs(v) > 1e-9 then pc = j; break end
        end
        if pc then
          pivot(T, {}, rows_n, r, pc, basis)
          r = r + 1
        else
          table.remove(T, r)
          table.remove(basis, r)
          rows_n = rows_n - 1
        end
      else
        r = r + 1
      end
    end
    for j = art_first, ncols do
      banned[j] = true
      for rr = 1, rows_n do T[rr][j] = nil end
    end
  end

  -- Phase 2: real costs, reduced against the current basis.
  local z = {}
  for j, c in pairs(costs) do
    if c ~= 0 then z[j] = c end
  end
  for r = 1, rows_n do
    local cb = costs[basis[r]] or 0
    if cb ~= 0 then
      for j, v in pairs(T[r]) do
        z[j] = (z[j] or 0) - cb * v
      end
    end
  end
  for r = 1, rows_n do z[basis[r]] = nil end
  local status = iterate(T, z, rows_n, ncols, basis, banned, max_iter)

  local x = {}
  for r = 1, rows_n do
    local b = basis[r]
    if b <= nvars then
      local v = T[r][0] or 0
      if math.abs(v) < 1e-10 then v = 0 end
      x[b] = v
    end
  end
  local obj = 0
  for j, c in pairs(costs) do obj = obj + c * (x[j] or 0) end
  return { status = status, x = x, objective = obj }
end

return lp
