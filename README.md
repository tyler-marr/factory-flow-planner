# Factory Flow Planner

A flowchart production planner that runs inside Factorio 2.1. Put recipes on a board as cards,
link them with real belts and pipes, give one a target, and it works out how many machines of
each kind you need, the rates along every link, power, and what's left over.

Recipes, machines, modules, beacons, belts, icons and research productivity all come from the
running game, so **modded content works** with no setup. Plans belong to your team, and several
players can work on one plan at once.

## Using it

Open the plans with the **Factory Flow Planner** shortcut button or `Ctrl + Shift + P`, then make
or open a plan. You're taken to a planning board. Your character stays where it was, protected,
until you come back.

**Building a flow**

- **Add a recipe** with the recipe slot at the top of the side panel. Its card appears where you're looking.
- **Click an input** to pick a recipe that makes it. The new card is placed and linked.
- **Drag from an output to an input** to link them, or onto empty space to add a recipe that uses it.
- **Drag a card's title** to move it.
- **Right-click a port** to clear its target or rate restriction; right-click again (or with none set) to unlink it.

**Hover over any part of a card** to see what scrolling and clicking do there.

| Part | Scroll | Click / right-click |
|---|---|---|
| Machine count | Any > Up to what runs > ±1 (Ctrl ±10, Shift ×2/÷2) | Cycle Any, Up to, Exactly / Any |
| Machine | Next / previous machine | Next / previous |
| Modules | Next / previous module, in every slot | Next / previous |
| Beacons | ±1 beacon (Ctrl ±4). Shift: change the beacon module | One more / fewer |
| An output's rate | Set a target: ±1, Ctrl ±10, Shift ±100 in the shown unit | Start a link / clear its target (unlink if none) |
| A supply / output panel item | Cap it (Up to) / ask for Exactly | / clear the rate (unlink if none) |

**Supply** and **output** panels hold things entering or leaving the plan. Each item can be Any,
Up to or Exactly a rate.

**The side panel** shows total power and machines to build, then inputs, outputs, shortfalls,
internal flows, and every machine type with the cards using it (click one to go to it).
Its buttons: add recipe, supply panel, output panel, belts or lines, plans, export, and back to
the game. **Show rates as** switches between items per second, minute or hour, or fractions of any belt.

**Links** are real belts and pipes, routed round cards and each other, going underground to
cross. Each belt is the slowest tier that carries its rate, and items move along it at that rate.
Splits and merges use *planner splitters*: copies of the game's splitters that show each belt's
planned rate instead of splitting 50/50.

**Sharing:** everyone on your force sees the same plans. **Export** gives a string, and
**Import** in the plans window opens one as a new plan.

## Limits

- No quality, mining drills, offshore pumps or power generation cards yet. Raw resources show as
  inputs from outside the plan, or use a supply panel.
- Fluid temperatures are ignored.
- Modules fill every slot with one kind. Beacons assume one beacon type and don't add their own power.
- Requires Factorio 2.1.22 or newer.

## Contributing

Forks and pull requests are welcome. The mod is plain Lua with no build step: link or copy this
folder into your Factorio `mods` folder as `factory-flow-planner` to run it.

**Tests** run the mod's real Lua outside the game (Lua 5.2 via `lupa`), against a small
stand-in for the game API and Wube's published vanilla data:

```sh
pip install lupa luaparser pillow
./tests/fetch_factorio_data.sh    # clones github.com/wube/factorio-data into tests/.factorio-data
python3 tests/run_all.py          # every test file
python3 tests/globals.py          # catches misspelt names before they fail in game
python3 tests/render_preview.py preview.png   # draws a sample board without the game
```

They run on every push via GitHub Actions. The mock can't show how things look in the game,
so check visual changes in game too.

**Releasing:** bump `version` in `info.json`, add a section to `changelog.txt`, then
`python3 tools/package.py` builds `dist/factory-flow-planner_<version>.zip` for the mod portal.
Pushing a tag `v<version>` builds the same zip and attaches it to a GitHub release.

### How it fits together

| File | Role |
|---|---|
| `scripts/catalog.lua` | Reads recipes, machines, modules, beacons, belts and splitters from the game's prototypes. |
| `scripts/recipe_math.lua` | Per-craft amounts (chance, productivity) and crafts per second per machine. |
| `scripts/solver.lua`, `scripts/lp.lua` | Builds and solves a linear program for the plan. Pure Lua and deterministic (multiplayer-safe). |
| `scripts/router.lua`, `scripts/links.lua` | Lays links out as belts and pipes on the tile grid: A*, undergrounds, splitters, belt tiers. |
| `scripts/layout.lua` | Card geometry, shared by drawing, clicks and hover hotspots. |
| `scripts/board.lua` | The board surface, drawing cards with the rendering API, belt entities, zoom. |
| `scripts/gui.lua`, `scripts/hints.lua` | Side panel, inspector, picker, plans window, hover hints. |
| `scripts/plan.lua` | The plan data model and its export string. |
| `control.lua` | Events: clicks, drags, the wheel, windows. |
| `data.lua`, `data-final-fixes.lua` | Hotkeys, the board tool, hover hotspots, planner splitters. |

## Credits

The card layout, scroll controls and solver approach follow
[GTNH Factory Flow](https://github.com/jackwrichards/gtnh-factory-flow) and its in-game planner for
GregTech: New Horizons (MIT). No code was taken from them; this is a separate implementation for Factorio.

## License

MIT. See [LICENSE](LICENSE).
