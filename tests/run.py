"""Runs one Lua test file against the mod, outside the game.

The mod's Lua runs in Lua 5.2 (Factorio's version) through lupa, with a small
stand-in for the game API (mock_factorio.lua) and Wube's vanilla recipe data.

    python3 tests/run.py tests/test_solver.lua

Needs: pip install lupa   and the vanilla data: tests/fetch_factorio_data.sh
"""
import base64, json, os, sys, zlib

import lupa
import lupa.lua52 as L

TESTS_DIR = os.path.dirname(os.path.abspath(__file__))
MOD_ROOT = os.path.dirname(TESTS_DIR)
FACTORIO_DATA = os.environ.get("FACTORIO_DATA", os.path.join(TESTS_DIR, ".factorio-data"))


def make_runtime():
    recipes = os.path.join(FACTORIO_DATA, "base", "prototypes", "recipe.lua")
    if not os.path.exists(recipes):
        sys.exit("Vanilla game data not found at %s.\nRun tests/fetch_factorio_data.sh "
                 "(or set FACTORIO_DATA to a checkout of github.com/wube/factorio-data)." % FACTORIO_DATA)
    lua = L.LuaRuntime(unpack_returned_tuples=True)
    g = lua.globals()
    g.MOD_ROOT, g.TESTS_DIR, g.FACTORIO_DATA = MOD_ROOT, TESTS_DIR, FACTORIO_DATA
    lua.execute('package.path = MOD_ROOT .. "/?.lua;" .. TESTS_DIR .. "/?.lua;" .. package.path')
    # Vanilla recipes, straight from Wube's data files.
    lua.execute('''
RECIPES = {}
data = { extend = function(self, list) for _, r in ipairs(list) do if r.type == "recipe" then RECIPES[r.name] = r end end end }
dofile(FACTORIO_DATA .. "/base/prototypes/recipe.lua")
''')

    def lua_to_py(t):
        if L.lua_type(t) != "table":
            return t
        keys = list(t.keys())
        if keys and all(isinstance(k, int) for k in keys) and sorted(keys) == list(range(1, len(keys) + 1)):
            return [lua_to_py(t[k]) for k in sorted(keys)]
        return {str(k): lua_to_py(v) for k, v in t.items()}

    def py_to_lua(o):
        if isinstance(o, list):
            return lua.table_from({i + 1: py_to_lua(v) for i, v in enumerate(o)})
        if isinstance(o, dict):
            return lua.table_from({k: py_to_lua(v) for k, v in o.items()})
        return o

    # Stand-ins for helpers.table_to_json / encode_string and friends.
    g.py_to_json = lambda t: json.dumps(lua_to_py(t))
    g.py_from_json = lambda s: py_to_lua(json.loads(s))
    g.py_encode = lambda s: base64.b64encode(zlib.compress(s.encode())).decode()
    g.py_decode = lambda s: zlib.decompress(base64.b64decode(s)).decode()
    return lua


def run(path):
    lua = make_runtime()
    with open(path) as f:
        lua.execute(f.read())
    return lua


if __name__ == "__main__":
    run(sys.argv[1])
