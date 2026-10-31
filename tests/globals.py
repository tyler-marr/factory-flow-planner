"""Reports names a mod file uses that are neither locals nor known Factorio/Lua globals.
Catches typos that would only fail when that line runs in game.

    pip install luaparser
    python3 tests/globals.py
"""
import sys, glob, os
from luaparser import ast, astnodes
ALLOWED = set("""require pairs ipairs math string table type tostring tonumber pcall error assert next select setmetatable getmetatable
rawget rawset unpack print storage game script defines prototypes helpers rendering data settings log serpent""".split())
found = False
ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
for f in sorted(f for f in glob.glob(os.path.join(ROOT, "**", "*.lua"), recursive=True) if os.sep + "tests" + os.sep not in f):
    tree = ast.parse(open(f).read())
    scopes = [set()]
    bad = set()
    class V(ast.ASTVisitor): pass
    def walk(node, scope):
        if isinstance(node, (astnodes.Goto, astnodes.Label)):
            return
        if isinstance(node, astnodes.Invoke):  # obj:method(args): the method name isn't a variable
            walk(node.source, scope)
            for a in node.args: walk(a, scope)
            return
        if isinstance(node, astnodes.LocalAssign):
            for v in node.values or []: walk(v, scope)
            for t in node.targets: scope.add(t.id)
            return
        if isinstance(node, astnodes.LocalFunction):
            scope.add(node.name.id); inner = set(scope) | {a.id for a in node.args if isinstance(a, astnodes.Name)}
            walk(node.body, inner); return
        if isinstance(node, (astnodes.Function, astnodes.AnonymousFunction, astnodes.Method)):
            inner = set(scope) | {a.id for a in node.args if isinstance(a, astnodes.Name)}
            if isinstance(node, astnodes.Method): inner.add("self")
            walk(node.body, inner); return
        if isinstance(node, (astnodes.Fornum,)):
            walk(node.start, scope); walk(node.stop, scope); walk(node.step, scope)
            walk(node.body, set(scope) | {node.target.id}); return
        if isinstance(node, astnodes.Forin):
            for e in node.iter: walk(e, scope)
            walk(node.body, set(scope) | {t.id for t in node.targets}); return
        if isinstance(node, astnodes.Block):
            inner = set(scope)
            for s in node.body: walk(s, inner)
            return
        if isinstance(node, astnodes.Index):
            walk(node.value, scope)
            if node.notation == astnodes.IndexNotation.SQUARE: walk(node.idx, scope)
            return
        if isinstance(node, astnodes.Name):
            if node.id not in scope and node.id not in ALLOWED: bad.add(node.id)
            return
        if isinstance(node, astnodes.Field):
            if getattr(node, "between_brackets", False): walk(node.key, scope)
            walk(node.value, scope); return
        if isinstance(node, astnodes.Node):
            for k, v in vars(node).items():
                if k.startswith("_") or k in ("comments",): continue
                if isinstance(v, list):
                    for x in v:
                        if isinstance(x, astnodes.Node): walk(x, scope)
                elif isinstance(v, astnodes.Node): walk(v, scope)
    walk(tree.body, set())
    print(os.path.relpath(f, ROOT), "->", sorted(bad) or "clean")
    found = found or bool(bad)

sys.exit(1 if found else 0)
