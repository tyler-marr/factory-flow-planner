-- Turns a plan (cards, panels, wires) into a linear program and reads the answer back.
-- Pure Lua: per-card recipe numbers come in through `spec_of`, so this file
-- never touches the game API and is tested outside the game.
--
-- Variables (all rates per second):
--   x_c      crafts per second of recipe card c
--   f_w      flow on wire w
--   s        surplus leaving a recipe output nobody takes (free on the card's goal output)
--   m        supply entering a recipe input from outside: a free import on an unwired
--            port, a heavily penalised shortfall on a wired one
--   u        what a supply panel item hands out
--   sp       supply an Exactly panel item has to give that nobody takes
--   sh       what an output panel item with a set rate is short of
--   sl       slack under an "up to" limit
-- Rows:
--   recipe output:   s + sum(f out) - x * yield = 0
--   recipe input:    m + sum(f in)  - x * need  = 0
--   rate target:     x * yield = rate
--   machines:        x = n * crafts_per_machine          (Exactly)
--   limit:           x + sl = n * crafts_per_machine     (Up to)
--   supply item:     sp + sum(f out) - u = 0, and u = R (Exactly) or u + sl = R (Up to)
--   output item:     sum(f in) + sh = R (Exactly) or sum(f in) + sl = R (Up to)
-- Objective: shortfall >> surplus >> machines.

local lp = require("scripts.lp")

local solver = {}

local COST_SHORTFALL = 1e4
local COST_SURPLUS = 1
local COST_MACHINE = 1e-3
-- A goal output nobody takes is almost free: cheaper than running any recipe
-- card to use it up, but dearer than an output panel taking it.
local COST_GOAL_SPARE = 1e-7

local function merge_ports(list)
  local out, index = {}, {}
  for _, p in ipairs(list or {}) do
    if p.amount == nil or p.amount > 0 then
      local k = index[p.res]
      if k then
        out[k].amount = (out[k].amount or 0) + (p.amount or 0)
      else
        out[#out + 1] = { res = p.res, amount = p.amount }
        index[p.res] = #out
      end
    end
  end
  return out
end

--- The output a target is set on is the plan's goal.
local function goal_of(card, outputs)
  local t = card.target
  if not t then return nil end
  if t.kind == "rate" then return t.product end
  if t.kind == "machines" then return outputs[1] and outputs[1].res end
  return nil
end

--- @param plan table
--- @param spec_of fun(card: table): table|nil
---   recipe card: { inputs, outputs, cpm, power_w }
---   panel:       { panel = true, inputs | outputs = { { res } } }
function solver.solve(plan, spec_of)
  local result = {
    status = "optimal", cards = {}, wires = {},
    imports = {}, surplus = {}, products = {}, shortfall = {},
    power_w = 0, warnings = {},
  }

  local nvars = 0
  local function newvar() nvars = nvars + 1; return nvars end
  local costs, rows = {}, {}
  local has_target = false

  local entries, order = {}, {}
  for _, card in ipairs(plan.cards) do
    local spec = spec_of(card)
    if spec and spec.panel then
      local e = { card = card, spec = spec, panel = true, inputs = merge_ports(spec.inputs), outputs = merge_ports(spec.outputs) }
      entries[card.id] = e
      order[#order + 1] = e
    elseif spec and spec.cpm and spec.cpm > 0 then
      local e = { card = card, spec = spec, inputs = merge_ports(spec.inputs), outputs = merge_ports(spec.outputs) }
      e.x = newvar()
      costs[e.x] = COST_MACHINE / spec.cpm
      entries[card.id] = e
      order[#order + 1] = e
    else
      result.warnings[#result.warnings + 1] = { card = card.id, text = "unknown-recipe" }
    end
  end

  -- Wires, grouped by the port at each end. A wire whose ends no longer
  -- carry its resource is ignored (the recipe changed under it).
  local function has_port(list, res)
    for _, p in ipairs(list) do if p.res == res then return true end end
    return false
  end
  local wires_out, wires_in, wire_vars = {}, {}, {}
  for _, w in ipairs(plan.wires) do
    local a, b = entries[w.from], entries[w.to]
    if a and b and has_port(a.outputs, w.res) and has_port(b.inputs, w.res) then
      local v = newvar()
      wire_vars[#wire_vars + 1] = { wire = w, var = v }
      local ko, ki = w.from .. "|" .. w.res, w.to .. "|" .. w.res
      wires_out[ko] = wires_out[ko] or {}
      table.insert(wires_out[ko], v)
      wires_in[ki] = wires_in[ki] or {}
      table.insert(wires_in[ki], v)
    end
  end

  local function panel_rule(card, res)
    for _, it in ipairs(card.items or {}) do
      if it.res == res then return it.rule, it.value end
    end
  end

  for _, e in ipairs(order) do
    local id = e.card.id
    e.vars = {}
    if e.panel and e.card.kind == "source" then
      for _, p in ipairs(e.outputs) do
        local u, sp = newvar(), newvar()
        local rule, value = panel_rule(e.card, p.res)
        costs[sp] = rule == "exact" and COST_SURPLUS or 0
        local coefs = { [sp] = 1, [u] = -1 }
        for _, f in ipairs(wires_out[id .. "|" .. p.res] or {}) do coefs[f] = 1 end
        rows[#rows + 1] = { coefs = coefs, rhs = 0, basis_hint = sp }
        if rule == "exact" and value then
          rows[#rows + 1] = { coefs = { [u] = 1 }, rhs = value }
        elseif rule == "upto" and value then
          local sl = newvar()
          rows[#rows + 1] = { coefs = { [u] = 1, [sl] = 1 }, rhs = value, basis_hint = sl }
        end
        e.vars[p.res] = { u = u, sp = sp }
      end
    elseif e.panel then -- sink
      for _, p in ipairs(e.inputs) do
        local rule, value = panel_rule(e.card, p.res)
        local fl = wires_in[id .. "|" .. p.res] or {}
        local v = {}
        if rule == "exact" and value then
          local sh = newvar()
          costs[sh] = COST_SHORTFALL
          local coefs = { [sh] = 1 }
          for _, f in ipairs(fl) do coefs[f] = 1 end
          rows[#rows + 1] = { coefs = coefs, rhs = value, basis_hint = sh }
          v.sh = sh
          has_target = true
        elseif rule == "upto" and value then
          local sl = newvar()
          local coefs = { [sl] = 1 }
          for _, f in ipairs(fl) do coefs[f] = 1 end
          rows[#rows + 1] = { coefs = coefs, rhs = value, basis_hint = sl }
        end
        v.flows = fl
        e.vars[p.res] = v
      end
    else
      local goal = goal_of(e.card, e.outputs)
      e.out_vars, e.in_vars = {}, {}
      for _, p in ipairs(e.outputs) do
        local s = newvar()
        costs[s] = p.res == goal and COST_GOAL_SPARE or COST_SURPLUS
        e.out_vars[p.res] = s
        local coefs = { [s] = 1, [e.x] = -p.amount }
        for _, f in ipairs(wires_out[id .. "|" .. p.res] or {}) do coefs[f] = 1 end
        rows[#rows + 1] = { coefs = coefs, rhs = 0, basis_hint = s }
      end
      for _, p in ipairs(e.inputs) do
        local m = newvar()
        local wired = wires_in[id .. "|" .. p.res] ~= nil
        costs[m] = wired and COST_SHORTFALL or 0
        e.in_vars[p.res] = { var = m, wired = wired }
        local coefs = { [m] = 1, [e.x] = -p.amount }
        for _, f in ipairs(wires_in[id .. "|" .. p.res] or {}) do coefs[f] = 1 end
        rows[#rows + 1] = { coefs = coefs, rhs = 0, basis_hint = m }
      end
      local t = e.card.target
      if t and t.value and t.value >= 0 then
        if t.kind == "machines" then
          rows[#rows + 1] = { coefs = { [e.x] = 1 }, rhs = t.value * e.spec.cpm }
          has_target = true
        elseif t.kind == "limit" then
          local sl = newvar()
          rows[#rows + 1] = { coefs = { [e.x] = 1, [sl] = 1 }, rhs = t.value * e.spec.cpm, basis_hint = sl }
        elseif t.kind == "rate" then
          local yield
          for _, p in ipairs(e.outputs) do
            if p.res == t.product then yield = p.amount end
          end
          if yield then
            rows[#rows + 1] = { coefs = { [e.x] = yield }, rhs = t.value }
            has_target = true
          else
            result.warnings[#result.warnings + 1] = { card = e.card.id, text = "target-product-missing" }
          end
        end
      end
    end
  end
  if not has_target then result.status = "no_target" end

  local sol = lp.solve(nvars, costs, rows)
  if sol.status ~= "optimal" then result.status = sol.status end
  local x = sol.x or {}
  local function val(v) local n = v and x[v] or 0; if n < 0 then n = 0 end; return n end
  local function add(map, res, amount)
    if amount > 1e-9 then map[res] = (map[res] or 0) + amount end
  end

  for _, wv in ipairs(wire_vars) do result.wires[wv.wire.id] = val(wv.var) end

  for _, e in ipairs(order) do
    if e.panel and e.card.kind == "source" then
      local cr = { panel = true, inputs = {}, outputs = {} }
      for _, p in ipairs(e.outputs) do
        local v = e.vars[p.res]
        local u, sp = val(v.u), val(v.sp)
        cr.outputs[p.res] = { rate = u - sp, surplus = sp }
        add(result.imports, p.res, u - sp)
        add(result.surplus, p.res, sp)
      end
      result.cards[e.card.id] = cr
    elseif e.panel then
      local cr = { panel = true, inputs = {}, outputs = {} }
      for _, p in ipairs(e.inputs) do
        local v = e.vars[p.res]
        local taken = 0
        for _, f in ipairs(v.flows) do taken = taken + val(f) end
        local sh = val(v.sh)
        cr.inputs[p.res] = { rate = taken, shortfall = sh, wired = #v.flows > 0 }
        add(result.products, p.res, taken)
        add(result.shortfall, p.res, sh)
      end
      result.cards[e.card.id] = cr
    else
      local rate = val(e.x)
      local machines = rate / e.spec.cpm
      local power = machines * (e.spec.power_w or 0)
      result.power_w = result.power_w + power
      local cr = { rate = rate, machines = machines, power_w = power, inputs = {}, outputs = {} }
      local goal = goal_of(e.card, e.outputs)
      for _, p in ipairs(e.outputs) do
        local s = val(e.out_vars[p.res])
        if p.res == goal then
          cr.outputs[p.res] = { rate = rate * p.amount, product = s }
          add(result.products, p.res, s)
        else
          cr.outputs[p.res] = { rate = rate * p.amount, surplus = s }
          add(result.surplus, p.res, s)
        end
      end
      for _, p in ipairs(e.inputs) do
        local iv = e.in_vars[p.res]
        local m = val(iv.var)
        local port = { rate = rate * p.amount, wired = iv.wired }
        if iv.wired then
          port.shortfall = m
          add(result.shortfall, p.res, m)
        else
          port.import = m
          add(result.imports, p.res, m)
        end
        cr.inputs[p.res] = port
      end
      result.cards[e.card.id] = cr
    end
  end
  return result
end

return solver
