// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {MugiIMDLedger} from "../../../src/imd/modules/MugiIMDLedger.sol";

/// @dev Independent, deliberately linear history oracle for ledger tests. Production
/// tokens have their own binary-search checkpoint tests. No callbacks are made.
contract MugiLedgerHistoryToken is ERC20 {
    struct Point { uint64 timestamp; uint256 value; }
    mapping(address => Point[]) private balances;
    Point[] private supplies;

    constructor() ERC20("Historical ledger fixture", "HLF") {}
    function mint(address account, uint256 amount) external { _mint(account, amount); }
    function burn(address account, uint256 amount) external { _burn(account, amount); }
    function balanceBefore(address account, uint64 cutoff) external view returns (uint256) {
        return _before(balances[account], cutoff);
    }
    function totalSupplyBefore(uint64 cutoff) external view returns (uint256) { return _before(supplies, cutoff); }
    function _before(Point[] storage points, uint64 cutoff) private view returns (uint256 value) {
        for (uint256 i; i < points.length; ++i) {
            if (points[i].timestamp >= cutoff) break;
            value = points[i].value;
        }
    }
    function _update(address from, address to, uint256 amount) internal override {
        super._update(from, to, amount);
        uint64 timestamp = uint64(block.timestamp);
        if (from != address(0)) balances[from].push(Point(timestamp, balanceOf(from)));
        if (to != address(0) && to != from) balances[to].push(Point(timestamp, balanceOf(to)));
        if (from == address(0) || to == address(0)) supplies.push(Point(timestamp, totalSupply()));
    }
}

abstract contract MugiIMDLedgerFixture is Test {
    address internal constant ALICE = address(0xA11CE);
    address internal constant BOB = address(0xB0B);
    address internal constant CAROL = address(0xCA201);
    address internal constant ENGINE = address(0xE0919E);
    address internal constant AIRDROP = address(0xA12D20);
    address internal constant MANAGER = address(0xB001);
    address internal constant TEAM = address(0x7EA);
    address internal constant COMMUNITY = address(0xC044);
    MugiIMDLedger internal ledger;
    address[10] internal tokens;
    uint16 internal alive = 1023;

    function setUp() public virtual {
        vm.warp(100);
        for (uint8 i; i < 10; ++i) tokens[i] = address(new MugiLedgerHistoryToken());
        ledger = new MugiIMDLedger(_configuration());
    }

    function _configuration() internal view returns (MugiIMDLedger.Configuration memory c) {
        c = MugiIMDLedger.Configuration({
            hook: address(this), token0: tokens[0], token1: tokens[1], token2: tokens[2], token3: tokens[3],
            token4: tokens[4], token5: tokens[5], token6: tokens[6], token7: tokens[7], token8: tokens[8], token9: tokens[9],
            airdrop: AIRDROP, engine: ENGINE, team: TEAM, community: COMMUNITY, manager: MANAGER
        });
    }

    function _nextCutoff() internal returns (uint64 cutoff) {
        // viaIR may cache TIMESTAMP across cheatcode warps in a single test call.
        cutoff = uint64(vm.getBlockTimestamp() + 1);
        vm.warp(uint256(cutoff) + 1);
    }

    function _eliminate(uint8 loser, uint256 reward) internal {
        _eliminateAt(loser, reward, _nextCutoff());
    }

    function _eliminateAt(uint8 loser, uint256 reward, uint64 cutoff) internal {
        (uint256[10] memory reserveRequired, uint256 oldBacking) =
            ledger.recordElimination(loser, alive, reward, cutoff);
        alive &= ~(uint16(1) << loser);
        if (oldBacking != 0) _burn(loser, address(this), oldBacking);
        // Test funding only: production earmarks an existing preminted reserve.
        for (uint8 i; i < 10; ++i) {
            if (reserveRequired[i] != 0) _mint(i, address(this), reserveRequired[i]);
        }
    }

    function _finalize(uint8 survivor) internal { ledger.finalizeMigration(survivor, _nextCutoff()); }
    function _emergency(uint16 mask, uint256 value) internal { ledger.emergencyFinalize(mask, value, _nextCutoff()); }

    function _claimAll(address account) internal returns (uint256[10] memory amounts) {
        amounts = ledger.claimTokens(account);
        for (uint8 i; i < 10; ++i) {
            if (amounts[i] != 0) _transfer(i, address(this), account, amounts[i]);
        }
    }

    function _mint(uint8 crew, address account, uint256 amount) internal {
        MugiLedgerHistoryToken(tokens[crew]).mint(account, amount);
    }

    function _burn(uint8 crew, address account, uint256 amount) internal {
        MugiLedgerHistoryToken(tokens[crew]).burn(account, amount);
    }

    function _transfer(uint8 crew, address from, address to, uint256 amount) internal {
        vm.prank(from);
        MugiLedgerHistoryToken(tokens[crew]).transfer(to, amount);
    }

    function _eligibleSupplies() internal view returns (uint256[10] memory supplies) {
        for (uint8 i; i < 10; ++i) supplies[i] = ledger.eligibleSupply(i);
    }

    function _assertEligibleSupplies(uint256[10] memory expected) internal view {
        for (uint8 i; i < 10; ++i) assertEq(ledger.eligibleSupply(i), expected[i]);
    }
}
