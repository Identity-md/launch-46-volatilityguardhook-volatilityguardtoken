#!/usr/bin/env python3
"""Export implementation ABI; --check refuses drift. Requires the pinned compiler cache."""
import json
import pathlib
import subprocess
import sys

for name in ("VolatilityGuardHook", "VolatilityGuardToken"):
    result = subprocess.check_output(["forge", "inspect", "--offline", name, "abi", "--json"], text=True)
    rendered = json.dumps(json.loads(result), indent=2) + "\n"
    path = pathlib.Path("artifacts/abis") / (name + ".json")
    if "--check" in sys.argv:
        assert path.read_text() == rendered, f"ABI drift: {path}"
    else:
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(rendered)
print("Implementation ABI exports match")
