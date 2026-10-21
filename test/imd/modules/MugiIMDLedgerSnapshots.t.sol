// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {MugiIMDLedgerFixture} from "./MugiIMDLedgerFixture.sol";

contract MugiIMDLedgerSnapshotsTest is MugiIMDLedgerFixture {
    function testCutoffTransfersBurnsAndKnownLoserSalesCannotMovePastRewardsOrConversion() public {
        _mint(0, ALICE, 12 ether);
        _mint(1, BOB, 3 ether);
        _mint(1, address(this), 100 ether);
        uint64 cutoff = 110;
        vm.warp(cutoff);
        // These are ordinary successful ERC20 operations at the exact cutoff.
        _transfer(0, ALICE, CAROL, 4 ether);
        _burn(0, ALICE, 8 ether);
        _transfer(1, BOB, CAROL, 3 ether);
        _transfer(1, address(this), CAROL, 100 ether);
        vm.warp(120); // VRF and settlement may arrive much later.
        _eliminateAt(0, 9 ether, cutoff);
        (uint256[10] memory aliceClaims, uint256 aliceEth,) = ledger.previewAccount(ALICE);
        (uint256[10] memory carolClaims, uint256 carolEth,) = ledger.previewAccount(CAROL);
        (, uint256 bobEth,) = ledger.previewAccount(BOB);
        for (uint8 i = 1; i < 10; ++i) {
            assertEq(aliceClaims[i], 1 ether);
            assertEq(carolClaims[i], 0);
        }
        assertEq(aliceEth, 0);
        assertEq(carolEth, 0);
        assertEq(bobEth, 1 ether);
        assertEq(ledger.reservedEth(), 1 ether);
        assertEq(ledger.eligibleSupply(1), 104 ether * ledger.SCALE());

        // Dead receipts still transfer. Their new owner cannot obtain the original conversion.
        _transfer(0, CAROL, BOB, 4 ether);
        assertEq(ledger.eligibleSupply(0), 0);
        _eliminate(1, 8 ether);
        (aliceClaims, aliceEth,) = ledger.previewAccount(ALICE);
        (carolClaims, carolEth,) = ledger.previewAccount(CAROL);
        (uint256[10] memory bobClaims,,) = ledger.previewAccount(BOB);
        for (uint8 i = 2; i < 10; ++i) {
            assertEq(aliceClaims[i], 1.09375 ether);
            assertEq(carolClaims[i], 9.65625 ether);
            assertEq(bobClaims[i], 0);
            assertEq(ledger.escrowBacking(i), 10.75 ether);
        }
        assertEq(aliceEth, 8 ether);
        assertEq(carolEth, 0);
    }

    function testTransfersBeforeCutoffMoveFutureEntitlementsToTheActualCutoffOwner() public {
        _mint(0, ALICE, 12 ether);
        _mint(1, ALICE, 3 ether);
        vm.warp(109);
        _transfer(0, ALICE, BOB, 12 ether);
        _transfer(1, ALICE, CAROL, 3 ether);
        vm.warp(120);
        _eliminateAt(0, 9 ether, 110);
        (uint256[10] memory aliceClaims, uint256 aliceEth,) = ledger.previewAccount(ALICE);
        (uint256[10] memory bobClaims,,) = ledger.previewAccount(BOB);
        (, uint256 carolEth,) = ledger.previewAccount(CAROL);
        assertEq(aliceClaims[1], 0);
        assertEq(aliceEth, 0);
        assertEq(bobClaims[1], 1 ether);
        assertEq(carolEth, 1 ether);
    }

    function testPartialMaterializationAndTransferBeforeNextCutoffNeverDoubleCountWalletAndVirtual() public {
        _mint(0, ALICE, 12 ether);
        _mint(1, BOB, 1 ether);
        _eliminate(0, 0);
        vm.warp(105);
        uint256 claimedPart = ledger.claimToken(ALICE, 1, 0.4 ether);
        _transfer(1, address(this), ALICE, claimedPart);
        _transfer(1, ALICE, CAROL, claimedPart);
        assertEq(ledger.eligibleSupply(1), 2 ether * ledger.SCALE());
        _eliminate(2, 8 ether);
        (, uint256 aliceEth, uint256[10] memory aliceVirtual) = ledger.previewAccount(ALICE);
        (, uint256 bobEth,) = ledger.previewAccount(BOB);
        (, uint256 carolEth,) = ledger.previewAccount(CAROL);
        assertEq(aliceEth, 7.3 ether);
        assertEq(bobEth, 0.5 ether);
        assertEq(carolEth, 0.2 ether);
        assertEq(aliceVirtual[1], 0.69375 ether * ledger.SCALE());
        assertEq(ledger.reservedEth(), 8 ether);
        uint256[10] memory before = _eligibleSupplies();
        _claimAll(ALICE);
        _assertEligibleSupplies(before);
        assertEq(ledger.claimEth(ALICE), 7.3 ether);
        assertEq(ledger.claimEth(BOB), 0.5 ether);
        assertEq(ledger.claimEth(CAROL), 0.2 ether);
        assertEq(ledger.reservedEth(), 0);
    }

    function testEmergencyUnwindUsesOriginalCutoffEvenAfterTransfersDuringLongRecoveryDelay() public {
        _mint(0, ALICE, 12 ether);
        _mint(1, BOB, 1 ether);
        _eliminate(0, 9 ether);
        vm.warp(110);
        _transfer(1, BOB, CAROL, 1 ether);
        _mint(2, ENGINE, 100 ether);
        _transfer(2, ENGINE, CAROL, 100 ether);
        vm.warp(110 + 7 days);
        ledger.emergencyFinalize(alive, 9 ether, 110);
        (, uint256 aliceEth,) = ledger.previewAccount(ALICE);
        (, uint256 bobEth,) = ledger.previewAccount(BOB);
        (, uint256 carolEth,) = ledger.previewAccount(CAROL);
        assertEq(aliceEth, 8.5 ether);
        assertEq(bobEth, 1.5 ether);
        assertEq(carolEth, 0);
        assertEq(ledger.eligibleSupply(1), 2 ether * ledger.SCALE());
        assertEq(ledger.eligibleSupply(2), 1 ether * ledger.SCALE());
        uint256[10] memory terminal = _eligibleSupplies();
        uint256[10] memory materialized = _claimAll(ALICE);
        _transfer(1, ALICE, CAROL, materialized[1]);
        _burn(2, CAROL, 100 ether);
        _assertEligibleSupplies(terminal);
        assertEq(ledger.claimEth(ALICE), aliceEth);
        assertEq(ledger.claimEth(BOB), bobEth);
        assertEq(ledger.claimEth(CAROL), 0);
    }

    function testFuzzAfterCutoffTransferCannotSellOrDuplicateConversion(uint96 rawBalance, uint96 rawTransfer) public {
        uint256 balance = bound(uint256(rawBalance), 1, 1e24);
        uint256 amount = bound(uint256(rawTransfer), 0, balance);
        _mint(0, ALICE, balance);
        _mint(1, BOB, 1 ether);
        vm.warp(110);
        _transfer(0, ALICE, BOB, amount);
        vm.warp(120);
        _eliminateAt(0, 9 ether, 110);
        (uint256[10] memory aliceClaims,, uint256[10] memory aliceVirtual) = ledger.previewAccount(ALICE);
        (uint256[10] memory bobClaims, uint256 bobEth,) = ledger.previewAccount(BOB);
        for (uint8 i = 1; i < 10; ++i) {
            assertEq(aliceVirtual[i], balance * ledger.SCALE() / 12);
            assertEq(aliceClaims[i], balance / 12);
            assertEq(bobClaims[i], 0);
            assertEq(ledger.escrowBacking(i), balance / 12 + (balance % 12 == 0 ? 0 : 1));
        }
        assertEq(bobEth, 1 ether);
        assertEq(ledger.claimEth(ALICE), 0);
        assertEq(ledger.claimEth(BOB), 1 ether);
        assertEq(ledger.reservedEth(), 0);
    }
}
