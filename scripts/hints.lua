-- What each card control does, worded for the part under the cursor and its
-- current value. Shown in the hover popup on the board and in the toolbar.

local catalog = require("scripts.catalog")
local plan_lib = require("scripts.plan")
local fmt = require("scripts.fmt")

local hints = {}

local function rich(res)
  local kind, name = string.match(res, "^([^/]+)/(.+)$")
  return "[" .. kind .. "=" .. name .. "]"
end

--- @return table { title = LocalisedString, lines = { { key, text } } }
function hints.for_part(plan, card, hit, result, force)
  fmt.use(plan.units, catalog.transport_kit())
  local _, _, unit = fmt.step_unit()
  local steps = "+-1" .. unit .. ", Ctrl +-10, Shift +-100"
  local cr = result and result.cards[card.id]
  local part = hit.part
  if plan_lib.is_panel(card) then
    if part == "in" or part == "out" then
      local it
      for _, x in ipairs(card.items) do if x.res == hit.res then it = x end end
      local port = cr and (cr.inputs[hit.res] or cr.outputs[hit.res])
      local rule = it and it.rule == "upto" and " (up to " .. fmt.rate(it.value, hit.res) .. ")"
        or it and it.rule == "exact" and " (exactly " .. fmt.rate(it.value, hit.res) .. ")" or " (any amount)"
      local source = card.kind == "source"
      return {
        title = { "", rich(hit.res) .. " ", catalog.res_name(hit.res), "  " .. fmt.rate(port and port.rate or 0, hit.res) .. rule },
        lines = {
          { "Scroll", source and ("cap it: " .. steps) or ("ask for exactly: " .. steps) },
          { "", "down to zero: any amount" },
          { "Drag", source and "onto an input to wire it" or "from an output here to wire it" },
          { "Right-click", "unwire" },
        },
      }
    end
    return { title = card.kind == "source" and "Supply panel" or "Output panel",
      lines = { { "Drag", "move" }, { "Click", "settings" }, { "Drop a port here", "add that item" } } }
  end

  local spec = catalog.spec(card, force)
  if part == "count" then
    local t = card.target
    local now = fmt.count(cr and cr.machines or 0)
    local rule = t and t.kind == "limit" and ", up to " .. fmt.count(t.value)
      or t and t.kind == "machines" and ", exactly " .. fmt.count(t.value) or ", any number"
    return {
      title = "Machines: " .. now .. " running" .. rule,
      lines = {
        { "Scroll", "Any > Up to what runs > one more or fewer" },
        { "", "Ctrl +-10   Shift x2 or /2" },
        { "Click", "Any > Up to > Exactly" },
        { "Right-click", "back to Any" },
      },
    }
  elseif part == "machine" then
    local list = catalog.machines_for(card.recipe)
    local idx = 1
    for i, m in ipairs(list) do if spec and m.name == spec.machine then idx = i end end
    local ent = spec and prototypes.entity[spec.machine]
    return {
      title = { "", "[entity=" .. (spec and spec.machine or "") .. "] ", ent and ent.localised_name or "?",
        "  (" .. idx .. " of " .. #list .. ")" },
      lines = { { "Scroll / Click", "next machine" }, { "Right-click", "previous" } },
    }
  elseif part == "modules" then
    local title
    if not spec or spec.module_slots == 0 then
      title = "This machine has no module slots"
    elseif card.modules and prototypes.item[card.modules] then
      title = { "", "Modules: " .. spec.module_slots .. " x [item=" .. card.modules .. "] ", prototypes.item[card.modules].localised_name }
    else
      title = "Modules: none (" .. spec.module_slots .. " slots)"
    end
    return { title = title, lines = { { "Scroll / Click", "next module, in every slot" }, { "Right-click", "previous" } } }
  elseif part == "beacons" then
    local b = card.beacons
    local title
    if not (spec and spec.beacons_ok) then
      title = "This machine can't take beacons"
    elseif b and (b.count or 0) > 0 and b.module then
      title = { "", "Beacons: " .. b.count .. " with [item=" .. b.module .. "] ", prototypes.item[b.module].localised_name }
    else
      title = "Beacons: none"
    end
    return {
      title = title,
      lines = {
        { "Scroll / Click", "one more beacon (Ctrl +4)" },
        { "Right-click", "one fewer" },
        { "Shift+Scroll", "change the beacon module" },
      },
    }
  elseif part == "out" then
    local port = cr and cr.outputs[hit.res]
    local t = card.target
    local is_target = t and t.kind == "rate" and t.product == hit.res
    return {
      title = { "", rich(hit.res) .. " ", catalog.res_name(hit.res), "  " .. fmt.rate(port and port.rate or 0, hit.res)
        .. (is_target and " (target)" or "") },
      lines = {
        { "Scroll", "set a target: " .. steps },
        { "Click / Drag", "wire it to an input" },
        { "Drag to space", "add a recipe that uses it" },
        { "Right-click", "unwire" },
      },
    }
  elseif part == "in" then
    local port = cr and cr.inputs[hit.res]
    local extra = ""
    if port and (port.shortfall or 0) > 1e-6 then extra = "  short " .. fmt.rate(port.shortfall, hit.res)
    elseif port and not port.wired then extra = " (from outside)" end
    return {
      title = { "", rich(hit.res) .. " ", catalog.res_name(hit.res), "  " .. fmt.rate(port and port.rate or 0, hit.res) .. extra },
      lines = {
        { "Click", "pick what makes it" },
        { "Drag", "to an output to wire it" },
        { "Drag to space", "add a recipe that makes it" },
        { "Right-click", "unwire" },
      },
    }
  end
  local proto = catalog.recipe(card.recipe)
  return { title = proto and proto.localised_name or card.recipe, lines = { { "Drag", "move" }, { "Click", "settings" } } }
end

--- One line for the toolbar.
function hints.flat(h)
  local parts = { "" , h.title, "   " }
  for i, l in ipairs(h.lines) do
    if l[1] ~= "" then
      parts[#parts + 1] = (i > 1 and "  ·  " or "") .. "[font=default-bold]" .. l[1] .. "[/font] " .. l[2]
    else
      parts[#parts + 1] = " " .. l[2]
    end
  end
  return parts
end

return hints
