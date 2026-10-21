// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {MugiIMDLedger} from "../../../src/imd/modules/MugiIMDLedger.sol";
import {MugiIMDLedgerFixture, MugiLedgerHistoryToken} from "./MugiIMDLedgerFixture.sol";

contract MugiIMDLedgerSecurityTest is MugiIMDLedgerFixture {
    function testPremintedProtocolInventoryIsExcludedWithoutAnyTokenCallback() public {
        _mint(0, address(this), 100 ether);
        _mint(0, address(ledger), 7 ether);
        _mint(0, ENGINE, 50 ether);
        _mint(0, ALICE, 2 ether);
        assertEq(ledger.eligibleSupply(0), 2 ether * ledger.SCALE());
        _transfer(0, address(this), ALICE, 1 ether);
        assertEq(ledger.eligibleSupply(0), 3 ether * ledger.SCALE());
        _transfer(0, ALICE, ENGINE, 2 ether);
        assertEq(ledger.eligibleSupply(0), 1 ether * ledger.SCALE());
        _burn(0, ALICE, 1 ether);
        assertEq(ledger.eligibleSupply(0), 0);
    }

    function testAllRemainingLedgerMutatorsRejectOutsideCaller() public {
        vm.startPrank(ALICE);
        vm.expectRevert(MugiIMDLedger.Unauthorized.selector);
        ledger.recordElimination(0, 1023, 1 ether, 100);
        vm.expectRevert(MugiIMDLedger.Unauthorized.selector);
        ledger.finalizeMigration(0, 100);
        vm.expectRevert(MugiIMDLedger.Unauthorized.selector);
        ledger.emergencyFinalize(1023, 1 ether, 100);
        vm.expectRevert(MugiIMDLedger.Unauthorized.selector);
        ledger.claimTokens(ALICE);
        vm.expectRevert(MugiIMDLedger.Unauthorized.selector);
        ledger.claimToken(ALICE, 0, 1 ether);
        vm.expectRevert(MugiIMDLedger.Unauthorized.selector);
        ledger.claimEth(ALICE);
        vm.expectRevert(MugiIMDLedger.Unauthorized.selector);
        ledger.expireFinalClaims();
        vm.stopPrank();
    }

    function testRemovedInitializationReclassificationAndCallbackSelectorsAreUnavailableEvenToHook() public {
        (bool ok,) = address(ledger).call(abi.encodeWithSignature("initialize(address[10])", tokens));
        assertFalse(ok);
        (ok,) = address(ledger).call(abi.encodeWithSignature(
            "initializeSeason(address[10],address,address,address,address,address)",
            tokens, AIRDROP, ENGINE, TEAM, COMMUNITY, MANAGER
        ));
        assertFalse(ok);
        (ok,) = address(ledger).call(abi.encodeWithSignature("setExcluded(address,bool)", ALICE, true));
        assertFalse(ok);
        (ok,) = address(ledger).call(abi.encodeWithSignature("beforeBalanceChange(address,address)", ALICE, BOB));
        assertFalse(ok);
        (ok,) = address(ledger).call(abi.encodeWithSignature(
            "afterBalanceChange(uint8,address,address,uint256)", uint8(0), ALICE, BOB, 1
        ));
        assertFalse(ok);
    }

    function testExcludedProtocolInventoryCannotCaptureEliminationRewards() public {
        _mint(0, address(this), 1e30);
        _mint(0, ENGINE, 50 ether);
        _mint(0, ALICE, 2 ether);
        _mint(1, address(this), 1e30);
        _mint(1, ENGINE, 50 ether);
        _mint(1, ALICE, 1 ether);
        _eliminate(0, 9 ether);
        (, uint256 hookRewards,) = ledger.previewAccount(address(this));
        (, uint256 engineRewards,) = ledger.previewAccount(ENGINE);
        (, uint256 playerRewards,) = ledger.previewAccount(ALICE);
        assertEq(hookRewards, 0);
        assertEq(engineRewards, 0);
        assertEq(playerRewards, 1 ether);
        (uint256[10] memory claimable,,) = ledger.previewAccount(ALICE);
        assertEq(claimable[1], uint256(1 ether) / 6);
        (uint256[10] memory protocolClaimable,,) = ledger.previewAccount(address(this));
        assertEq(protocolClaimable[1], 0);
    }

    function testCutoffCannotBeFutureRepeatedOrEarlierThanPriorAccountingEvent() public {
        _mint(0, ALICE, 1 ether);
        vm.expectRevert(MugiIMDLedger.InvalidRound.selector);
        ledger.recordElimination(0, alive, 0, 0);
        vm.expectRevert(MugiIMDLedger.InvalidRound.selector);
        ledger.recordElimination(0, alive, 0, uint64(block.timestamp + 1));
        _eliminate(0, 0); // cutoff101, recorded102.
        vm.expectRevert(MugiIMDLedger.InvalidRound.selector);
        ledger.recordElimination(1, alive, 0, 101);
        vm.expectRevert(MugiIMDLedger.InvalidRound.selector);
        ledger.recordElimination(1, alive, 0, 102);
        _eliminate(1, 0);
    }

    function testMaterializationAtOrAfterProposedCutoffCannotBeReusedAsAnEarlierVirtualSnapshot() public {
        _mint(0, ALICE, 12 ether);
        _eliminate(0, 0);
        vm.warp(110);
        uint256 amount = ledger.claimToken(ALICE, 1, 1 ether);
        _transfer(1, address(this), ALICE, amount);
        vm.warp(120);
        vm.expectRevert(MugiIMDLedger.InvalidRound.selector);
        ledger.recordElimination(1, alive, 0, 109);
        vm.expectRevert(MugiIMDLedger.InvalidRound.selector);
        ledger.recordElimination(1, alive, 0, 110);
        _eliminateAt(1, 0, 111);
    }

    function testZeroTokenClaimsAndEthSynchronizationDoNotChangeVirtualSnapshotTiming() public {
        _mint(0, ALICE, 12 ether);
        _mint(1, ALICE, 1 ether);
        _eliminate(0, 9 ether);
        vm.warp(120);
        ledger.claimToken(ALICE, 1, 0);
        assertEq(ledger.claimEth(ALICE), 1 ether);
        // Token materialization was zero; ETH-only synchronization cannot invalidate cutoff110.
        _eliminateAt(1, 0, 110);
    }
}
