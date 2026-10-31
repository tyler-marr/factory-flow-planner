package.path = MOD_ROOT .. "/?.lua;" .. package.path
local protos = {}
data = { extend = function(self, list) for _, p in ipairs(list) do protos[#protos + 1] = p end end }
dofile(MOD_ROOT .. "/data.lua")
data.raw = { splitter = {
  splitter = { type = "splitter", name = "splitter", flags = { "placeable-neutral", "player-creation" }, minable = { mining_time = 0.1, result = "splitter" }, speed = 0.03125, next_upgrade = "fast-splitter" },
  ["modded-splitter"] = { type = "splitter", name = "modded-splitter", flags = { "player-creation" }, speed = 0.2 },
} }
package.loaded["util"] = { table = { deepcopy = function(o)
  local function cp(x) if type(x) ~= "table" then return x end local r = {} for k, v in pairs(x) do r[k] = cp(v) end return r end
  return cp(o) end } }
dofile(MOD_ROOT .. "/data-final-fixes.lua")
local planner = {}
for _, p in ipairs(protos) do if p.type == "splitter" then planner[p.name] = p end end
local ps = planner["ffp-planner-splitter"]
assert(ps and ps.hidden and ps.minable == nil and ps.next_upgrade == nil, "planner splitter copy")
for _, f in ipairs(ps.flags) do assert(f ~= "player-creation") end
assert(planner["ffp-planner-modded-splitter"], "modded splitters are copied too")
print("ok   planner splitters copied from every splitter (vanilla and modded), hidden and not minable")
local kinds = {}
for _, p in ipairs(protos) do
  assert(p.type and p.name, "prototype without type/name")
  kinds[p.type] = (kinds[p.type] or 0) + 1
  if p.type == "simple-entity-with-owner" then
    local sb = p.selection_box
    assert(sb[1][1] < 0 and sb[2][2] > 0)
  end
end
for k, n in pairs(kinds) do print(k, n) end
