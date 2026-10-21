#!/usr/bin/env python3
"""Rebuild the hook and check its public constructor commitment. No network writes."""
import argparse
import json
from pathlib import Path
import re
import subprocess

ROOT = Path(__file__).resolve().parents[1]


def run(*args):
    return subprocess.check_output(args, cwd=ROOT, text=True).strip()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--write-manifest", action="store_true",
                        help="Update only launch.json's hook commitment after rebuilding")
    args = parser.parse_args()
    cfg = json.loads((ROOT / "hook-constructor.json").read_text())
    settings = json.loads(run("forge", "config", "--json"))
    expected = {"solc": "0.8.26", "evm_version": "cancun", "optimizer": True,
                "optimizer_runs": 200, "via_ir": True, "bytecode_hash": "none"}
    for key, value in expected.items():
        assert settings[key] == value, f"Unexpected compiler setting {key}"
    def inspect_hex(field):
        raw = run("forge", "inspect", cfg["contract"], field, "--json")
        value = raw if raw.startswith("0x") else json.loads(raw)
        assert re.fullmatch(r"0x(?:[0-9a-fA-F]{2})+", value), "Unresolved or invalid bytecode"
        return value
    bytecode = inspect_hex("bytecode")
    runtime = inspect_hex("deployedBytecode")
    assert bytecode.startswith("0x") and len(bytecode) > 2
    assert (len(runtime) - 2) // 2 <= 24576, "Hook runtime exceeds EIP-170"
    encoded = run("cast", "abi-encode", "constructor(address,address,address,address,address,uint256)",
                  cfg["owner"], cfg["poolManager"], cfg["teamTreasury"],
                  cfg["communityTreasury"], cfg["v2MigrationTarget"], cfg["initialSupply"])
    initcode = bytecode + encoded[2:]
    assert (len(initcode) - 2) // 2 <= 49152, "Hook initcode exceeds EIP-3860"
    digest = run("cast", "keccak", initcode)
    manifest_path = ROOT / "launch.json"
    manifest = json.loads(manifest_path.read_text())
    deployment = next(c for c in manifest["contracts"] if c["contract"] == "MugiV1IMDDeploymentFactory")
    assert deployment["constructorArgs"][0].lower() == cfg["owner"].lower()
    if args.write_manifest:
        deployment["constructorArgs"][2] = digest
        manifest_path.write_text(json.dumps(manifest, indent=2) + "\n")
    assert deployment["constructorArgs"][2] == digest, "Manifest hook hash differs; review before updating"
    print(json.dumps({"hookInitCodeHash": digest, "constructor": cfg, "compiler": expected,
                      "runtimeBytes": (len(runtime) - 2) // 2,
                      "initcodeBytes": (len(initcode) - 2) // 2,
                      "manifestMatches": True}, indent=2))


if __name__ == "__main__":
    main()
