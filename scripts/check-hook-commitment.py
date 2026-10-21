#!/usr/bin/env python3
"""Read-only validation of built constructor factories and the source-derived raw hook pin.

Run `forge build --skip test --skip script` first. This script never builds,
rewrites a manifest, creates a deployment payload, contacts a network, or sends
transactions. Stale/missing artifacts fail validation rather than being rebuilt.
"""
import argparse
import json
from pathlib import Path
import re
import subprocess

ROOT = Path(__file__).resolve().parents[1]
FACTORIES = ["MugiIMDCrewFactory", "MugiV1IMDDeploymentFactory",
             "MugiIMDAccountingFactory", "MugiIMDEngineFactory"]
HOOK = "MugiIMDGameHook"
FIELDS = ["owner", "manager", "team", "community", "v2MigrationTarget", "initialSupply",
          "ledger", "engine", "budgets", "prices", "randomnessProvider", "imdVerifier",
          "airdrop", "crewFactory"]


def keccak(data):
    return subprocess.check_output(["cast", "keccak", "0x" + data.hex()],
                                   cwd=ROOT, text=True).strip().lower()


def code(artifact, field):
    raw = artifact[field]["object"]
    assert re.fullmatch(r"0x(?:[0-9a-fA-F]{2})+", raw), "Invalid or unresolved bytecode"
    assert not artifact[field].get("linkReferences"), "Unexpected linked bytecode"
    return bytes.fromhex(raw[2:])


def constructor(artifact):
    entries = [item for item in artifact["abi"] if item["type"] == "constructor"]
    assert len(entries) == 1, "Missing constructor ABI"
    assert entries[0]["stateMutability"] == "nonpayable", "Manifest constructor must be nonpayable"
    return entries[0]["inputs"]


def load(name, hashes):
    path = ROOT / "out" / (name + ".sol") / (name + ".json")
    assert path.is_file(), f"Missing {path}; build the reviewed source first"
    artifact = json.loads(path.read_text())
    metadata = artifact["metadata"]
    settings = metadata["settings"]
    assert metadata["compiler"]["version"].startswith("0.8.26+"), "Wrong compiler"
    assert settings["evmVersion"] == "cancun", "Wrong EVM target"
    assert settings["optimizer"] == {"enabled": True, "runs": 200}, "Wrong optimizer"
    assert settings["viaIR"] is True, "viaIR required"
    assert settings["metadata"]["bytecodeHash"] == "none", "Unexpected metadata hash"
    assert settings.get("libraries", {}) == {}, "Unexpected linked libraries"
    for relative, record in metadata["sources"].items():
        source = (ROOT / relative).resolve()
        assert source.is_relative_to(ROOT), f"Source outside repository: {relative}"
        if relative not in hashes:
            assert source.is_file(), f"Missing source: {relative}"
            hashes[relative] = keccak(source.read_bytes())
        assert hashes[relative] == record["keccak256"].lower(), f"Stale artifact source: {relative}"
    assert len(code(artifact, "deployedBytecode")) <= 24_576, f"{name} exceeds EIP-170"
    return artifact


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.parse_args()  # Deliberately no mutation/generation option.
    manifest = json.loads((ROOT / "launch.json").read_text())
    cfg = json.loads((ROOT / "hook-constructor.json").read_text())
    assert manifest["kind"] == "evm_contracts"
    assert [c["contract"] for c in manifest["contracts"]] == FACTORIES, "Unexpected manifest scope/order"
    assert cfg["status"] == "partial-season-constants-not-deployable"
    assert cfg["configurationFieldOrder"] == FIELDS
    assert cfg["unresolved"] == FIELDS[6:], "Must preserve unresolved deployment bindings"
    assert cfg["chainId"] == 1
    assert re.fullmatch(r"0x[0-9a-fA-F]{40}", cfg["owner"])
    hashes = {}
    artifacts = {name: load(name, hashes) for name in [HOOK] + FACTORIES}
    hook_inputs = constructor(artifacts[HOOK])
    assert len(hook_inputs) == 1 and hook_inputs[0]["type"] == "tuple"
    components = hook_inputs[0]["components"]
    assert [item["name"] for item in components] == FIELDS
    assert [item["type"] for item in components] == ["address"] * 5 + ["uint256"] + ["address"] * 8
    hook_code = code(artifacts[HOOK], "bytecode")
    assert len(hook_code) + 14 * 32 <= 49_152, "Hook initcode exceeds EIP-3860"
    sizes = {}
    for entry in manifest["contracts"]:
        name = entry["contract"]
        artifact = artifacts[name]
        inputs = constructor(artifact)
        assert len(inputs) == 1 and inputs[0]["type"] == "address", f"{name} owner-only ABI required"
        assert entry["constructorArgs"] == [cfg["owner"]], f"{name} owner mismatch"
        creation = code(artifact, "bytecode")
        assert len(creation) + 32 <= 49_152, f"{name} initcode exceeds EIP-3860"
        sizes[name] = {"runtimeBytes": len(code(artifact, "deployedBytecode")),
                       "initcodeBytesIncludingOwner": len(creation) + 32}
    factory_source = (ROOT / "src/imd/MugiV1IMDDeploymentFactory.sol").read_text()
    assert "hookCreationCodeHash = keccak256(type(MugiGameHook).creationCode);" in factory_source
    assert "hookCreationCodeLength = type(MugiGameHook).creationCode.length;" in factory_source
    assert "keccak256(initCode[:hookCreationCodeLength]) != hookCreationCodeHash" in factory_source
    assert hook_code in code(artifacts["MugiV1IMDDeploymentFactory"], "bytecode"), "Raw hook code absent from factory initcode"
    print(json.dumps({
        "manifestMatches": True, "compiledSourcesMatch": True,
        "sourceFilesChecked": len(hashes), "manifestEntries": 4, "disclosedDescendants": 19,
        "hookRawCreationCodeHash": keccak(hook_code),
        "hookRuntimeBytes": len(code(artifacts[HOOK], "deployedBytecode")),
        "hookInitcodeBytesWithCompleteConfiguration": len(hook_code) + 14 * 32,
        "factories": sizes,
        "deploymentReady": False,
        "remaining": "Predict final module addresses, encode/review the complete 14-field hook tuple, mine its CREATE2 salt, and simulate exact authorized calls. Remote IMD admission is not established."
    }, indent=2))


if __name__ == "__main__":
    main()
