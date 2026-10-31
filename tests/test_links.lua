package.path = MOD_ROOT .. "/?.lua;" .. package.path
local layout = require("scripts.layout")
local links = require("scripts.links")
local plan_lib = require("scripts.plan")
local fails = 0
local function check(c, m) if c then print("ok   " .. m) else fails = fails + 1; print("FAIL " .. m) end end
local KIT = {
  belts = {
    { name = "transport-belt", underground = "underground-belt", items_per_s = 15, reach = 5, splitter = "ffp-planner-splitter" },
    { name = "fast-transport-belt", underground = "fast-underground-belt", items_per_s = 30, reach = 7, splitter = "ffp-planner-fast-splitter" },
    { name = "express-transport-belt", underground = "express-underground-belt", items_per_s = 45, reach = 9, splitter = "ffp-planner-express-splitter" },
  },
  pipe = { name = "pipe", underground = "pipe-to-ground", reach = 10 },
}
-- Specs by hand: ports only matter.
local SPECS = {}
local function spec_of(c)
  if c.kind then
    local ports = {}
    for _, it in ipairs(c.items) do ports[#ports + 1] = { res = it.res } end
    return { panel = true, inputs = c.kind == "sink" and ports or {}, outputs = c.kind == "source" and ports or {} }
  end
  return SPECS[c.recipe]
end
SPECS.sulfur = { inputs = { { res = "fluid/water" }, { res = "fluid/petroleum-gas" } }, outputs = { { res = "item/sulfur" } }, chips = true }
SPECS.crack = { inputs = { { res = "fluid/water" }, { res = "fluid/light-oil" } }, outputs = { { res = "fluid/petroleum-gas" } }, chips = true }
SPECS.sci = { inputs = { { res = "item/engine-unit" }, { res = "item/advanced-circuit" }, { res = "item/sulfur" } }, outputs = { { res = "item/chemical-science-pack" } }, chips = true }

local function render(plan, laid, failed)
  local grid, minx, miny, maxx, maxy = {}, 1e9, 1e9, -1e9, -1e9
  local function put(x, y, ch) grid[y] = grid[y] or {}; grid[y][x] = ch
    minx, miny, maxx, maxy = math.min(minx, x), math.min(miny, y), math.max(maxx, x), math.max(maxy, y) end
  for _, c in ipairs(plan.cards) do
    local l, t, r, b = layout.box(c, spec_of(c))
    for x = math.floor(l), math.ceil(r) - 1 do for y = math.floor(t), math.ceil(b) - 1 do put(x, y, c.kind and "P" or "#") end end
  end
  local arrows = { ">", "v", "<", "^" }
  for _, L in ipairs(laid) do
    for _, sp in ipairs(L.splitters or {}) do
      local horiz = sp.dir == 2 or sp.dir == 4
      local x0, y0 = sp.x - 0.5, sp.y - 0.5
      if horiz then put(math.floor(x0 - 0.5 + 0.5), math.floor(y0), "S"); put(math.floor(x0 + 0.5 + 0.5), math.floor(y0), "S")
      else put(math.floor(x0), math.floor(y0 - 0.5 + 0.5), "S"); put(math.floor(x0), math.floor(y0 + 0.5 + 0.5), "S") end
    end
    for _, t in ipairs(L.path) do
      if t.kind == "split" then goto skip_t end
      local ch = arrows[t.dir]
      if L.fluid then ch = (t.kind == "line") and "=" or "O" elseif t.kind ~= "line" then ch = "U" end
      put(t.x, t.y, ch)
      ::skip_t::
    end
  end
  for y = miny, maxy do
    local row = {}
    for x = minx, maxx do row[#row + 1] = grid[y] and grid[y][x] or "." end
    print("     " .. table.concat(row))
  end
end

-- The chemical science chain from the screenshot.
local p = plan_lib.new(1, "chem", 1, "me")
local sup = plan_lib.add_panel(p, "source", layout.snap(-28), layout.snap(0))
plan_lib.panel_item(sup, "fluid/water")
local crk = plan_lib.add_card(p, "crack", "x", layout.snap(-17), layout.snap(0))
local sul = plan_lib.add_card(p, "sulfur", "x", layout.snap(4), layout.snap(0))
local sci = plan_lib.add_card(p, "sci", "x", layout.snap(26), layout.snap(0))
local out = plan_lib.add_panel(p, "sink", layout.snap(48), layout.snap(0))
plan_lib.panel_item(out, "item/chemical-science-pack")
local w1 = plan_lib.add_wire(p, sup.id, crk.id, "fluid/water")
local w2 = plan_lib.add_wire(p, sup.id, sul.id, "fluid/water")
local w3 = plan_lib.add_wire(p, crk.id, sul.id, "fluid/petroleum-gas")
local w4 = plan_lib.add_wire(p, sul.id, sci.id, "item/sulfur")
local w5 = plan_lib.add_wire(p, sci.id, out.id, "item/chemical-science-pack")
local flows = { [w4.id] = 0.5, [w5.id] = 20 }
local laid, failed = links.lay(p, spec_of, flows, KIT)
render(p, laid, failed)
check(#failed == 0, "every link routed (" .. #laid .. ")")
for _, L in ipairs(laid) do
  if L.wire.id == w4.id then check(L.kind.name == "transport-belt", "30/min sulfur: yellow belt") end
  if L.wire.id == w5.id then check(L.kind.name == "fast-transport-belt", "1200/min: red belt") end
  if L.wire.id == w2.id then check(L.fluid and L.kind.name == "pipe", "water: pipe") end
end
-- Nothing overlaps a card.
local hits = 0
for _, L in ipairs(laid) do for i, t in ipairs(L.path) do
  local endpoint = (i == 1 and t.x == L.start_tile[1] and t.y == L.start_tile[2]) or (i == #L.path and not L.merged_into)
  if endpoint then goto skip end
  for _, c in ipairs(p.cards) do
    local l, tt, r, b = layout.box(c, spec_of(c))
    if t.x + 1 > l and t.x < r and t.y + 1 > tt and t.y < b then hits = hits + 1 end
  end
  ::skip::
end end
-- Ends sit half under their card's edge.
local edge_ok = true
for _, L in ipairs(laid) do
  local A = L.wire.from
  for _, c in ipairs(p.cards) do
    if c.id == A then
      local _, _, r = layout.box(c, spec_of(c))
      if not (L.start_tile[1] < r and L.start_tile[1] + 1 > r) then edge_ok = false end
    end
  end
end
check(edge_ok, "each belt starts half under its card's edge")
check(hits == 0, "no belt or pipe on a card except the ends tucked under its edge")
-- Pipes of different links never touch side by side.
local pipe_at = {}
for _, L in ipairs(laid) do if L.fluid then for _, t in ipairs(L.path) do pipe_at[t.x .. "," .. t.y] = L.wire.from .. "|" .. L.wire.res .. ">" .. L.wire.to end end end
local touch = 0
for k, owner in pairs(pipe_at) do
  local x, y = k:match("(-?%d+),(-?%d+)"); x, y = tonumber(x), tonumber(y)
  for _, d in ipairs({ { 1, 0 }, { 0, 1 } }) do
    local o = pipe_at[(x + d[1]) .. "," .. (y + d[2])]
    if o and o ~= owner then
      local same_src = o:match("^[^>]+") == owner:match("^[^>]+")
      if not same_src then touch = touch + 1 end
    end
  end
end
check(touch == 0, "pipes of different links don't touch")

-- Same chain, links added in the order that blocked the water pipe before.
local p2 = plan_lib.new(9, "chem2", 1, "me")
local sup2 = plan_lib.add_panel(p2, "source", layout.snap(-28), layout.snap(0)); plan_lib.panel_item(sup2, "fluid/water")
local crk2 = plan_lib.add_card(p2, "crack", "x", layout.snap(-17), layout.snap(0))
local sul2 = plan_lib.add_card(p2, "sulfur", "x", layout.snap(4), layout.snap(0))
local sci2 = plan_lib.add_card(p2, "sci", "x", layout.snap(26), layout.snap(0))
plan_lib.add_wire(p2, sul2.id, sci2.id, "item/sulfur")
plan_lib.add_wire(p2, crk2.id, sul2.id, "fluid/petroleum-gas")
plan_lib.add_wire(p2, sup2.id, sul2.id, "fluid/water")
plan_lib.add_wire(p2, sup2.id, crk2.id, "fluid/water")
local laid9, failed9 = links.lay(p2, spec_of, {}, KIT)
render(p2, laid9, failed9)
check(#failed9 == 0, "order doesn't matter: every link routed (" .. #laid9 .. ")")

-- Crossing: a link that has to cross another goes underground.
local q = plan_lib.new(2, "cross", 1, "me")
local a1 = plan_lib.add_card(q, "sulfur", "x", layout.snap(0), layout.snap(0))
local b1 = plan_lib.add_card(q, "sci", "x", layout.snap(30), layout.snap(12))
local a2 = plan_lib.add_card(q, "sulfur", "x", layout.snap(0), layout.snap(12))
local b2 = plan_lib.add_card(q, "sci", "x", layout.snap(30), layout.snap(-6))
plan_lib.add_wire(q, a1.id, b1.id, "item/sulfur")
plan_lib.add_wire(q, a2.id, b2.id, "item/sulfur")
local laid2, failed2 = links.lay(q, spec_of, {}, KIT)
render(q, laid2, failed2)
local under = 0
for _, L in ipairs(laid2) do for _, t in ipairs(L.path) do if t.kind ~= "line" then under = under + 1 end end end
check(#failed2 == 0 and under >= 2, "crossing links: one goes underground (" .. under .. " underground ends)")

-- Two outputs of one card to two consumers share a trunk; two producers into one input merge.
local m = plan_lib.new(3, "merge", 1, "me")
local s1 = plan_lib.add_card(m, "sulfur", "x", layout.snap(0), layout.snap(0))
local s2 = plan_lib.add_card(m, "sulfur", "x", layout.snap(0), layout.snap(14))
local c1 = plan_lib.add_card(m, "sci", "x", layout.snap(30), layout.snap(6))
plan_lib.add_wire(m, s1.id, c1.id, "item/sulfur")
plan_lib.add_wire(m, s2.id, c1.id, "item/sulfur")
local laid3, failed3 = links.lay(m, spec_of, {}, KIT)
render(m, laid3, failed3)
check(#failed3 == 0 and #laid3[2].splitters == 1 and laid3[2].drains == false, "second producer joins the first one's belt through a splitter")
check(laid3[2].splitters[1].name == "ffp-planner-splitter", "the planner's own splitter, matching the trunk's yellow belt")

-- One output feeding two cards: the second link leaves the trunk through a splitter.
local sp = plan_lib.new(4, "split", 1, "me")
local src = plan_lib.add_card(sp, "sulfur", "x", layout.snap(0), layout.snap(6))
local u1 = plan_lib.add_card(sp, "sci", "x", layout.snap(30), layout.snap(-4))
local u2 = plan_lib.add_card(sp, "sci", "x", layout.snap(30), layout.snap(16))
local wa = plan_lib.add_wire(sp, src.id, u1.id, "item/sulfur")
local wb = plan_lib.add_wire(sp, src.id, u2.id, "item/sulfur")
local laid4, failed4 = links.lay(sp, spec_of, { [wa.id] = 10, [wb.id] = 10 }, KIT)
render(sp, laid4, failed4)
check(#failed4 == 0 and #laid4[2].splitters == 1, "the branch starts at a splitter on the trunk")
check(laid4[1].kind.name == "fast-transport-belt", "the trunk carries both links (20/s): red belt")
check(laid4[2].kind.name == "transport-belt", "the branch carries its own 10/s: yellow belt")
check(laid4[2].fed and laid4[2].drains, "the branch is fed at its own rate and empties at its card")
local st = laid4[2].splitters[1]
check(st.trunk_side == "left" or st.trunk_side == "right", "the splitter knows which side is the trunk (" .. st.trunk_side .. ")")
local split_tiles = 0
for _, t in ipairs(laid4[1].path) do if t.kind == "split" then split_tiles = split_tiles + 1 end end
check(split_tiles == 1, "the splitter takes the place of one trunk belt")

-- Too much for one belt.
local _, mult = links.pick_belt(KIT, 100)
check(mult == 3, "100/s needs 3 express belts")

local t0 = os.clock()
for _ = 1, 10 do links.lay(p, spec_of, flows, KIT) end
print(string.format("     layout of the chem chain: %.1f ms", (os.clock() - t0) * 100))
print(fails == 0 and "ALL PASS" or (fails .. " FAILURES"))
