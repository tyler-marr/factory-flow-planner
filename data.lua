data:extend({
  {
    type = "custom-input",
    name = "ffp-toggle",
    key_sequence = "CONTROL + SHIFT + P",
    action = "lua",
    consuming = "game-only",
  },
  -- Board clicks. They never consume the click, so the game behaves as usual;
  -- the script ignores them unless the player is on the board and not on a window.
  {
    type = "custom-input",
    name = "ffp-click",
    key_sequence = "",
    linked_game_control = "open-gui",
    consuming = "none",
  },
  {
    type = "custom-input",
    name = "ffp-right-click",
    key_sequence = "",
    linked_game_control = "mine",
    consuming = "none",
  },
  -- The wheel over a card part changes it (count, machine, modules, beacons,
  -- a rate). Plain notches follow the player's zoom keys; Ctrl and Shift give
  -- bigger steps. Nothing is consumed: off the board the game zooms as usual.
  { type = "custom-input", name = "ffp-wheel-up", key_sequence = "", linked_game_control = "zoom-in", consuming = "none" },
  { type = "custom-input", name = "ffp-wheel-down", key_sequence = "", linked_game_control = "zoom-out", consuming = "none" },
  { type = "custom-input", name = "ffp-wheel-up-ctrl", key_sequence = "CONTROL + mouse-wheel-up", consuming = "none" },
  { type = "custom-input", name = "ffp-wheel-down-ctrl", key_sequence = "CONTROL + mouse-wheel-down", consuming = "none" },
  { type = "custom-input", name = "ffp-wheel-up-shift", key_sequence = "SHIFT + mouse-wheel-up", consuming = "none" },
  { type = "custom-input", name = "ffp-wheel-down-shift", key_sequence = "SHIFT + mouse-wheel-down", consuming = "none" },
  -- Held in the cursor on the board. It selects nothing; the mod only reads
  -- where a drag starts and ends (and where it is while it moves).
  -- The board uses the plain arrow pointer, not the selection crosshair.
  { type = "mouse-cursor", name = "ffp-arrow", system_cursor = "arrow" },
  {
    type = "selection-tool",
    name = "ffp-board-tool",
    -- Invisible: the game draws the held item's icon by the cursor.
    icon = "__factory-flow-planner__/graphics/blank-64.png",
    icon_size = 64,
    mouse_cursor = "ffp-arrow",
    flags = { "only-in-cursor", "not-stackable", "spawnable" },
    hidden = true,
    subgroup = "other",
    stack_size = 1,
    send_pre_selection_events = true,
    -- The game's own drag rectangle snaps to whole tiles and would mislead:
    -- it is invisible, and the board draws the card's outline instead.
    select = { border_color = { 0, 0, 0, 0 }, mode = { "nothing" }, cursor_box_type = "entity" },
    alt_select = { border_color = { 0, 0, 0, 0 }, mode = { "nothing" }, cursor_box_type = "entity" },
  },
  {
    type = "shortcut",
    name = "ffp-shortcut",
    order = "f[factory-flow-planner]",
    action = "lua",
    associated_control_input = "ffp-toggle",
    icon = "__factory-flow-planner__/graphics/shortcut-x56.png",
    icon_size = 56,
    small_icon = "__factory-flow-planner__/graphics/shortcut-x24.png",
    small_icon_size = 24,
  },
})

-- Hover hotspots: invisible entities laid over each card control. Hovering one
-- shows the game's selection brackets and its tooltip says what the wheel and
-- clicks do there. Sizes come from the same layout the board draws.
local layout = require("scripts.layout")
for kind, hot in pairs(layout.HOTSPOTS) do
  data:extend({
    {
      type = "simple-entity-with-owner",
      name = hot.name,
      localised_name = { "ffp-hot." .. kind },
      localised_description = { "ffp-hot-description." .. kind },
      icon = "__factory-flow-planner__/graphics/shortcut-x56.png",
      icon_size = 56,
      hidden = true,
      flags = { "placeable-neutral", "placeable-off-grid", "not-on-map", "not-blueprintable", "not-deconstructable",
        "not-flammable", "no-copy-paste", "not-upgradable", "not-in-kill-statistics", "not-repairable",
        "not-rotatable", "hide-alt-info", "not-in-made-in" },
      collision_mask = { layers = {} },
      selection_box = { { -hot.w / 2, -hot.h / 2 }, { hot.w / 2, hot.h / 2 } },
      selection_priority = 60,
      allow_copy_paste = false,
      remove_decoratives = "false",
      picture = { filename = "__factory-flow-planner__/graphics/empty.png", size = 1 },
    },
  })
end
