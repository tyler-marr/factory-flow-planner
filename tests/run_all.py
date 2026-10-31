"""Runs every test file and fails if any check fails or any test errors."""
import glob, io, os, subprocess, sys

TESTS_DIR = os.path.dirname(os.path.abspath(__file__))
failed = []
for path in sorted(glob.glob(os.path.join(TESTS_DIR, "test_*.lua"))):
    name = os.path.basename(path)
    proc = subprocess.run([sys.executable, os.path.join(TESTS_DIR, "run.py"), path], capture_output=True, text=True)
    out = proc.stdout + proc.stderr
    bad = proc.returncode != 0 or "FAIL" in out
    checks = out.count("\nok ") + out.startswith("ok ")
    print(("FAIL " if bad else "pass ") + name + "  (" + str(checks) + " checks)")
    if bad:
        failed.append(name)
        print("\n".join("    " + line for line in out.splitlines() if "FAIL" in line or "Error" in line or "error" in line)[:4000])
sys.exit(1 if failed else 0)
