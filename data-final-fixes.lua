-- Planner splitters: a copy of every splitter in the game (vanilla, Space Age,
-- modded), used only on the board. They look the same but are marked as the
-- planner's own: hidden, not minable, not placeable, not blueprintable. On the
-- board their output priority keeps the trunk's items on the trunk, and each
-- branch belt is fed at its own planned rate, so uneven splits look uneven.
local util = require("util")

local copies = {}
for name, sp in pairs(data.raw["splitter"] or {}) do
  if string.sub(name, 1, 4) ~= "ffp-" then
    local c = util.table.deepcopy(sp)
    c.name = "ffp-planner-" .. name
    c.localised_name = { "entity-name.ffp-planner-splitter", sp.localised_name or { "entity-name." .. name } }
    c.localised_description = { "entity-description.ffp-planner-splitter-description" }
    c.hidden = true
    c.hidden_in_factoriopedia = true
    c.minable = nil
    c.placeable_by = nil
    c.next_upgrade = nil
    c.fast_replaceable_group = nil
    c.factoriopedia_alternative = nil
    local flags = {}
    for _, f in ipairs(c.flags or {}) do
      if f ~= "player-creation" then flags[#flags + 1] = f end
    end
    for _, f in ipairs({ "not-blueprintable", "not-deconstructable", "not-upgradable", "not-on-map", "no-copy-paste" }) do
      flags[#flags + 1] = f
    end
    c.flags = flags
    copies[#copies + 1] = c
  end
end
if #copies > 0 then data:extend(copies) end
