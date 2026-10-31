"""Builds the release zip the mod portal expects: dist/<name>_<version>.zip,
holding one folder <name>_<version>/ with the mod's files (no tests or tools).

    python3 tools/package.py
"""
import json, os, sys, zipfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
EXCLUDE_DIRS = {".git", ".github", "tests", "tools", "dist", "__pycache__"}
EXCLUDE_FILES = {".gitignore", ".DS_Store"}

info = json.load(open(os.path.join(ROOT, "info.json")))
base = "%s_%s" % (info["name"], info["version"])
os.makedirs(os.path.join(ROOT, "dist"), exist_ok=True)
out = os.path.join(ROOT, "dist", base + ".zip")

with zipfile.ZipFile(out, "w", zipfile.ZIP_DEFLATED) as z:
    for dirpath, dirnames, filenames in os.walk(ROOT):
        dirnames[:] = sorted(d for d in dirnames if d not in EXCLUDE_DIRS and not d.startswith("."))
        for f in sorted(filenames):
            if f in EXCLUDE_FILES or f.endswith(".zip"):
                continue
            full = os.path.join(dirpath, f)
            rel = os.path.relpath(full, ROOT)
            z.write(full, base + "/" + rel.replace(os.sep, "/"))
print(out)
