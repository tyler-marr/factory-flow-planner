-- Reproduces the crash: a save made by 0.4.0 with the player on the board,
-- loaded with this version (on_configuration_changed with an old toolbar).
package.path = MOD_ROOT .. "/?.lua;" .. package.path
local mock = dofile(TESTS_DIR .. "/mock_factorio.lua")
dofile(MOD_ROOT .. "/control.lua")
local H = mock.handlers
local board = require("scripts.board")
local P1 = mock.players[1]
H.init()
H["ffp-toggle"]({ player_index = 1 })
H[defines.events.on_gui_click]({ player_index = 1, element = mock.find(P1.gui.screen, function(el) return el.tags and el.tags.ffp == "new-plan" end) })
local plan = storage.plans[1]
plan.cards[1] = { id = 1, recipe = "electronic-circuit", machine = "assembling-machine-2", x = 3, y = 2 } -- old, off-tile position
plan.next_id = 2
-- Swap the toolbar for one shaped like 0.4.0's (no Links button, no version tag).
if P1.gui.top.ffp_toolbar then P1.gui.top.ffp_toolbar.destroy() end
local old = P1.gui.top.add({ type = "frame", name = "ffp_toolbar", direction = "vertical" })
local row = old.add({ type = "flow", name = "row", direction = "horizontal" })
row.add({ type = "label", name = "title" })
old.add({ type = "label", name = "totals" })
old.add({ type = "label", name = "hint" })
local ok, err = pcall(H.config, {})
print(ok and "ok   on_configuration_changed runs with an old toolbar" or ("FAIL " .. tostring(err)))
print((P1.gui.top.ffp_toolbar == nil and mock.find(P1.gui.screen, function(el) return el.tags and el.tags.ffp == "toggle-links" end))
  and "ok   old toolbar removed; links toggle is in the side panel" or "FAIL old toolbar still there")
print((plan.cards[1].x == 3.5 and plan.cards[1].y == 2.5) and "ok   old card moved onto the tile grid" or "FAIL card not snapped")
-- And refreshing an old toolbar outside a config change rebuilds it too.
if P1.gui.top.ffp_toolbar then P1.gui.top.ffp_toolbar.destroy() end
local old2 = P1.gui.top.add({ type = "frame", name = "ffp_toolbar", direction = "vertical" })
old2.add({ type = "flow", name = "row" })
local ok2, err2 = pcall(require("scripts.gui").toolbar_update, P1)
print((ok2 and P1.gui.top.ffp_toolbar == nil) and "ok   an old toolbar is cleared" or ("FAIL " .. tostring(err2)))
