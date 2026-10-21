#!/usr/bin/env python3
"""Read-only review of already-built Mugi production artifacts; never compiles.

Run only after the reviewed full suite completes. Outputs JSON to stdout and
fails closed on stale sources, missing artifacts, unexpected ABIs or capabilities.
All file reads are local. `cast keccak` performs local hashing only.
"""
import argparse
import contextlib
import datetime
import hashlib
import importlib.util
import io
import json
from pathlib import Path
import re
import sys

sys.dont_write_bytecode = True

DEPLOYED = [
    ("MugiIMDCrewFactory", "factory", 1),
    ("MugiV1IMDDeploymentFactory", "factory", 1),
    ("MugiIMDAccountingFactory", "factory", 1),
    ("MugiIMDEngineFactory", "factory", 1),
    ("MugiIMDCrewToken", "descendant", 10),
    ("MugiIMDGameHook", "descendant", 1),
    ("MugiIMDSwapRouter", "descendant", 1),
    ("MugiVRFAdapter", "descendant", 1),
    ("MugiIMDVerifier", "descendant", 1),
    ("MugiAirdrop", "descendant", 1),
    ("MugiIMDLedger", "descendant", 1),
    ("MugiIMDBuybacks", "descendant", 1),
    ("MugiIMDPriceOracle", "descendant", 1),
    ("MugiIMDV4Engine", "descendant", 1),
]
SCOPE = DEPLOYED + [("MugiCrewToken", "inherited base token; not separately deployed", 0)]
FORBIDDEN = {
    "mint", "mintTo", "mintBatch", "mintFor", "mintForMigration",
    "pause", "unpause", "setPaused", "setPause", "setPauseUntil",
    "freeze", "unfreeze", "setFrozen", "freezeTransfers", "freezeWallet",
    "setTransfersEnabled", "enableTransfers", "disableTransfers", "setTradingEnabled",
    "setTransferGate", "initialize", "initializeSeason", "configure", "bindAccounting",
    "bindEngine", "bindModules", "setLedger", "setEngine", "setExcluded", "setPolicy",
}
TOKEN_FUNCTIONS = {
    "name", "symbol", "decimals", "crewId", "totalSupply", "balanceOf", "balanceBefore",
    "totalSupplyBefore", "allowance", "approve", "transfer", "transferFrom", "burn",
    "reserveFor", "hook", "characterId", "initialSupply", "reserveCap",
}


def static_slots(item):
    typ = item["type"]
    array = re.fullmatch(r"(.*)\[([0-9]*)\]", typ)
    if array:
        assert array[2], f"Dynamic constructor array: {typ}"
        count = int(array[2])
        assert count > 0
        return count * static_slots({**item, "type": array[1]})
    if typ == "tuple":
        return sum(static_slots(x) for x in item["components"])
    assert re.fullmatch(r"address|bool|u?int(?:[0-9]+)?|bytes(?:[1-9]|[12][0-9]|3[0-2])", typ), \
        f"Unsupported or dynamic constructor type: {typ}"
    return 1


def canonical(item):
    typ = item["type"]
    if typ.startswith("tuple"):
        return "(" + ",".join(canonical(x) for x in item["components"]) + ")" + typ[5:]
    return typ


def strip_comments(source):
    # Keep string literals intact while removing only Solidity comments.
    return re.sub(r'"(?:\\.|[^"\\])*"|\'(?:\\.|[^\'\\])*\'|//[^\n]*|/\*[\s\S]*?\*/',
                  lambda m: "" if m[0].startswith(("//", "/*")) else m[0], source)


def body(source, name):
    pattern = r"\bconstructor\s*\(" if name == "constructor" else r"\bfunction\s+" + re.escape(name) + r"\s*\("
    match = re.search(pattern, source)
    assert match, f"Missing reviewed function: {name}"
    start = source.index("{", match.end())
    level = 1
    cursor = start + 1
    while level:
        assert cursor < len(source), f"Unbalanced function: {name}"
        level += (source[cursor] == "{") - (source[cursor] == "}")
        cursor += 1
    return source[start + 1:cursor - 1]


def compact(text):
    return re.sub(r"\s+", "", text)


def reviewed_token_checks(root):
    source = strip_comments((root / "src/game/MugiCrewToken.sol").read_text())
    wrapper = strip_comments((root / "src/imd/MugiIMDCrewToken.sol").read_text())
    assert re.search(r"contract\s+MugiCrewToken\s+is\s+IERC20\s*,\s*IERC20Metadata\s*,\s*IERC20Errors\s*\{", source)
    assert re.search(r"contract\s+MugiIMDCrewToken\s+is\s+MugiCrewToken\s*\{", wrapper)
    assert not re.search(r"\bfunction\b|\bassembly\b|\bdelegatecall\b", wrapper)
    assert not re.search(r"\bassembly\b|\bdelegatecall\b|\bselfdestruct\b|\.call\b|\.staticcall\b|\.code\b", source)
    writes = re.findall(r"\b_totalSupply\s*(\+=|-=|=(?!=)|\+\+|--|\*=|/=)", source)
    assert writes == ["=", "-="], f"Unexpected supply writes: {writes}"
    assert "_totalSupply = reserve;" in body(source, "constructor")
    assert "_totalSupply -= amount;" in body(source, "burn")
    reviewed = {
        "transfer": "_transfer(msg.sender, to, amount); return true;",
        "transferFrom": """uint256 allowed = _allowances[from][msg.sender];
            if (allowed != type(uint256).max) {
                if (allowed < amount) revert ERC20InsufficientAllowance(msg.sender, allowed, amount);
                unchecked { _allowances[from][msg.sender] = allowed - amount; }
            }
            _transfer(from, to, amount); return true;""",
        "burn": """uint256 balance = _balances[msg.sender];
            if (balance < amount) revert ERC20InsufficientBalance(msg.sender, balance, amount);
            if (amount != 0) {
                _balances[msg.sender] = balance - amount;
                _totalSupply -= amount;
                _write(_balanceHistory[msg.sender], balance - amount);
                _write(_supplyHistory, _totalSupply);
            }
            emit Transfer(msg.sender, address(0), amount);""",
        "_transfer": """if (from == address(0)) revert ERC20InvalidSender(address(0));
            if (to == address(0)) revert ERC20InvalidReceiver(address(0));
            uint256 balance = _balances[from];
            if (balance < amount) revert ERC20InsufficientBalance(from, balance, amount);
            if (from != to && amount != 0) {
                _balances[from] = balance - amount;
                _balances[to] += amount;
                _write(_balanceHistory[from], balance - amount);
                _write(_balanceHistory[to], _balances[to]);
            }
            emit Transfer(from, to, amount);""",
    }
    for name, expected in reviewed.items():
        assert compact(body(source, name)) == compact(expected), f"Token function changed from reviewed semantics: {name}"
    write_body = body(source, "_write")
    assert not re.search(r"\bhook\b|\bowner\b|\bpaused\b|\bfrozen\b|\.call\b|\.staticcall\b", write_body)
    assert not re.search(r"\bhook\s*\.", source), "Token calls into hook"
    return {
        "supplyWrites": {"constructor": "assign fixed reserve", "burn": "subtract caller-owned amount"},
        "transferAndTransferFrom": "exact reviewed standard balance/allowance semantics; no hook or lifecycle gate",
        "tokenHookPrivilege": False,
        "sourceSha256": hashlib.sha256((root / "src/game/MugiCrewToken.sol").read_bytes()).hexdigest(),
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", type=Path, default=Path(__file__).resolve().parents[1])
    args = parser.parse_args()
    root = args.root.resolve()
    checker_file = root / "scripts/check-hook-commitment.py"
    spec = importlib.util.spec_from_file_location("mugi_readonly_commitment", checker_file)
    checker = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(checker)
    assert checker.ROOT == root
    captured = io.StringIO()
    original_argv = sys.argv
    try:
        sys.argv = [str(checker_file)]
        with contextlib.redirect_stdout(captured):
            checker.main()
    finally:
        sys.argv = original_argv
    commitment = json.loads(captured.getvalue())
    hashes = {}
    rows = []
    constructor_shapes = {
        "MugiIMDCrewToken": ["uint8", "address", "uint256"],
        "MugiCrewToken": ["uint8", "address", "uint256"],
        "MugiAirdrop": ["address", "address", "uint256", "address[10]"],
        "MugiVRFAdapter": ["address", "address", "bytes32", "uint256", "uint32", "bool"],
        "MugiIMDVerifier": ["address", "address", "address", "uint16", "uint16", "uint64"],
        "MugiIMDSwapRouter": ["address", "address"],
        "MugiIMDV4Engine": ["address", "address"],
        "MugiIMDBuybacks": ["address"],
        "MugiIMDPriceOracle": ["address"],
    }
    for name, role, instances in SCOPE:
        artifact = checker.load(name, hashes)
        inputs = checker.constructor(artifact)
        if role == "factory":
            assert [x["type"] for x in inputs] == ["address"]
        elif name in constructor_shapes:
            assert [x["type"] for x in inputs] == constructor_shapes[name], f"Unexpected constructor: {name}"
        elif name == "MugiIMDGameHook":
            assert len(inputs) == 1 and inputs[0]["type"] == "tuple"
            assert [x["name"] for x in inputs[0]["components"]] == checker.FIELDS
        elif name == "MugiIMDLedger":
            assert len(inputs) == 1 and inputs[0]["type"] == "tuple"
            assert [x["name"] for x in inputs[0]["components"]] == ["hook"] + [f"token{i}" for i in range(10)] + ["airdrop", "engine", "team", "community", "manager"]
            assert [x["type"] for x in inputs[0]["components"]] == ["address"] * 16
        slots = sum(static_slots(x) for x in inputs)
        assert 0 < slots <= 16, f"Constructor exceeds 16 static ABI words: {name}: {slots}"
        creation = checker.code(artifact, "bytecode")
        runtime = checker.code(artifact, "deployedBytecode")
        init_bytes = len(creation) + slots * 32
        assert len(runtime) <= 24_576 and init_bytes <= 49_152, f"Deployment size exceeded: {name}"
        functions = [x for x in artifact["abi"] if x["type"] == "function"]
        bad = sorted({x["name"] for x in functions} & FORBIDDEN)
        assert not bad, f"Removed capability present in {name}: {bad}"
        signatures = sorted(x["name"] + "(" + ",".join(canonical(v) for v in x["inputs"]) + ")" for x in functions)
        methods = artifact.get("methodIdentifiers")
        assert isinstance(methods, dict) and set(methods) == set(signatures), f"Compiled methodIdentifiers missing/mismatch: {name}"
        if name in {"MugiIMDCrewToken", "MugiCrewToken"}:
            assert {x["name"] for x in functions} == TOKEN_FUNCTIONS, f"Unexpected token authority surface: {name}"
            assert not any(x["type"] in {"fallback", "receive"} for x in artifact["abi"])
        rows.append({
            "contract": name, "role": role, "instances": instances,
            "runtimeBytes": len(runtime), "runtimeHeadroomBytes": 24_576 - len(runtime),
            "rawCreationBytes": len(creation), "constructorStaticWords": slots,
            "constructorInputs": inputs, "initcodeBytesIncludingArguments": init_bytes,
            "initcodeHeadroomBytes": 49_152 - init_bytes, "nonpayableConstructor": True,
            "creationCodeHash": checker.keccak(creation),
            "artifactSha256": hashlib.sha256((root / "out" / (name + ".sol") / (name + ".json")).read_bytes()).hexdigest(),
            "functionSelectors": dict(sorted(methods.items())), "forbiddenFunctionsFound": bad,
        })
    token_review = reviewed_token_checks(root)
    expected_creations = {
        "MugiIMDCrewFactory": ["MugiIMDCrewToken"],
        "MugiV1IMDDeploymentFactory": ["MugiIMDSwapRouter", "MugiVRFAdapter", "MugiIMDVerifier", "MugiAirdrop"],
        "MugiIMDAccountingFactory": ["MugiIMDLedger", "MugiIMDBuybacks", "MugiIMDPriceOracle"],
        "MugiIMDEngineFactory": ["MugiIMDV4Engine"],
    }
    for name, expected in expected_creations.items():
        source = strip_comments((root / "src/imd" / (name + ".sol")).read_text())
        aliases = {alias: original for original, alias in re.findall(r"\b(\w+)\s+as\s+(\w+)", source)}
        created = [aliases.get(item, item) for item in re.findall(r"\bnew\s+(\w+)\s*\(", source)]
        assert created == expected, f"Unexpected descendant creation surface: {name}: {created}"
        ctor = body(source, "constructor")
        assert not re.search(r"\bnew\b|\.code\b|\.call\b|\.staticcall\b|\.delegatecall\b", ctor)
    crew_source = strip_comments((root / "src/imd/MugiIMDCrewFactory.sol").read_text())
    assert "crew < 10" in crew_source and "new MugiIMDCrewToken(crew, futureHook, initialSupply)" in crew_source
    main_source = strip_comments((root / "src/imd/MugiV1IMDDeploymentFactory.sol").read_text())
    assert "create2(" in main_source
    report = {
        "reviewedAtUtc": datetime.datetime.now(datetime.timezone.utc).isoformat(),
        "root": str(root), "artifactTypesChecked": len(rows), "deployedContractTypes": len(DEPLOYED),
        "factoryTypes": 4, "descendantTypes": 10, "descendantInstances": 19,
        "compiledSourcesMatch": True, "sourceFilesChecked": len(hashes),
        "allProductionSizesValid": True, "allConstructorsStaticNonpayableAtMost16Words": True,
        "policyCapabilitiesRemoved": True,
        "policyCheckScope": "Reviewed ABI/source removal of postconstructor crew mint, token transfer freeze, owner pause and application initialization/configuration APIs. This is not remote policy admission or a complete security audit.",
        "forbiddenFunctionNamesChecked": sorted(FORBIDDEN), "tokenSourceChecks": token_review,
        "hookRawCreationCodeHash": commitment["hookRawCreationCodeHash"],
        "commitmentCheck": commitment, "contracts": rows,
        "remainingDisclosures": [
            "19 descendants require five owner creation transactions after four manifest factory creations; applications have final constructor bindings.",
            "Constructor premint reserve is not circulating supply; deterministic reserve releases remain part of V1 economics.",
            "Official-pool lifecycle gates remain, but crew ERC20 holder transfers have no lifecycle freeze or owner pause.",
            "Hook poolManager.mint creates Uniswap ERC6909 native-fee claims, not additional crew ERC20 supply.",
            "Owner seeding, prelaunch abort refund, ownership transfer, and verifier request pin/revoke remain disclosed authority. V2 handoff is permissionless to the constructor-pinned receiver, with a fixed community fallback after 30 days.",
            "This report performs no network reads, public deployment, payment, explorer source verification or IMD admission.",
        ],
    }
    print(json.dumps(report, indent=2))


if __name__ == "__main__":
    main()
