# @noindex
from pathlib import Path
import sys

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / ".validation-deps"))

from lupa import LuaRuntime

failures = []
for test in sorted((ROOT / "tests").glob("*.lua")):
    if test.name == "host_smoke.lua":
        continue
    print("RUN", test.name, flush=True)
    lua = LuaRuntime(unpack_returned_tuples=True)
    lua.execute(
        "package.path = %s .. ';' .. package.path"
        % repr((str(ROOT / "ReaRoll/?.lua") + ";" + str(ROOT / "ReaRoll/?/init.lua")).replace("\\", "/"))
    )
    try:
        lua.execute(test.read_text(encoding="utf-8"))
    except Exception as error:
        failures.append(test.name)
        print("FAIL", test.name, str(error), flush=True)

print("Failed tests:", ", ".join(failures) if failures else "none", flush=True)
sys.exit(bool(failures))
