#!/usr/bin/env python3
"""Export the compiled production ABIs. Run forge build first; no network is used."""

import json
from pathlib import Path


root = Path(__file__).resolve().parents[1]
destination = root / "docs" / "abi"
destination.mkdir(parents=True, exist_ok=True)
for contract in ("Geomean", "GeomeanOracleHook"):
    artifact = root / "out" / f"{contract}.sol" / f"{contract}.json"
    abi = json.loads(artifact.read_text())["abi"]
    (destination / f"{contract}.json").write_text(json.dumps(abi, indent=2) + "\n")
    print(f"Exported docs/abi/{contract}.json")
