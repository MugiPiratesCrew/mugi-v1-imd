// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {MugiIMDLedger} from "../../../src/imd/modules/MugiIMDLedger.sol";
import {MugiIMDLedgerFixture, MugiLedgerHistoryToken} from "./MugiIMDLedgerFixture.sol";

contract MugiIMDLedgerTerminalTest is MugiIMDLedgerFixture {
    function testNormalFinalizePreservesSyncedAndLazyEscrowAndOnlyUnreservedInventoryCanLeave() public {
        _mint(0, ALICE, 8 ether);
        _mint(0, BOB, 4 ether);
        _mint(9, CAROL, 2 ether);
        for (uint8 i; i < 9; ++i) {
            _eliminate(i, 9 ether);
            if (i == 3) ledger.claimEth(ALICE); // Advance one account; Bob remains completely lazy.
        }
        (uint256[10] memory beforeAlice, uint256 aliceEth,) = ledger.previewAccount(ALICE);
        (uint256[10] memory beforeBob, uint256 bobEth,) = ledger.previewAccount(BOB);
        uint256 backing = ledger.escrowBacking(9);
        assertGt(beforeAlice[9], 0);
        assertGt(beforeBob[9], 0);
        _finalize(9);
        (uint256[10] memory afterAlice, uint256 afterAliceEth,) = ledger.previewAccount(ALICE);
        (uint256[10] memory afterBob, uint256 afterBobEth,) = ledger.previewAccount(BOB);
        assertEq(afterAlice[9], beforeAlice[9]);
        assertEq(afterBob[9], beforeBob[9]);
        assertEq(afterAliceEth, aliceEth);
        assertEq(afterBobEth, bobEth);
        assertEq(ledger.escrowBacking(9), backing);
        uint256[10] memory eligibleBefore = _eligibleSupplies();

        // Migration to a non-excluded recipient must not create eligible supply.
        _mint(9, address(this), 100 ether);
        uint256 free = MugiLedgerHistoryToken(tokens[9]).balanceOf(address(this)) - ledger.escrowBacking(9);
        _transfer(9, address(this), address(0xF00), free);
        assertEq(MugiLedgerHistoryToken(tokens[9]).balanceOf(address(this)), backing);
        _assertEligibleSupplies(eligibleBefore);
        uint256 partialClaim = beforeAlice[9] / 2;
        assertEq(ledger.claimToken(ALICE, 9, partialClaim), partialClaim);
        _transfer(9, address(this), ALICE, partialClaim);
        _assertEligibleSupplies(eligibleBefore);
        uint256[10] memory bobClaims = _claimAll(BOB);
        _assertEligibleSupplies(eligibleBefore);
        uint256[10] memory aliceClaims = _claimAll(ALICE);
        _assertEligibleSupplies(eligibleBefore);
        assertEq(bobClaims[9], beforeBob[9]);
        assertEq(aliceClaims[9] + partialClaim, beforeAlice[9]);
        assertEq(ledger.escrowBacking(9), backing - beforeAlice[9] - beforeBob[9]);
        assertEq(_claimAll(BOB)[9], 0);
        assertEq(ledger.claimEth(BOB), bobEth);
        assertEq(ledger.claimEth(BOB), 0);
        assertEq(ledger.claimEth(ALICE), aliceEth);
    }

    function testEmergencyRewardsIncludeFrozenWalletAndVirtualBalancesAndEarlierEth() public {
        _mint(0, ALICE, 8 ether);
        _mint(1, BOB, 3 ether);
        _mint(2, CAROL, 1 ether);
        _eliminate(0, 9 ether);
        // Alice has 2/3 token of each live crew in lazy virtual accounting.
        // Bob and Carol each earned 1 ETH from the previous elimination.
        assertEq(ledger.reservedEth(), 2 ether);
        uint256[10] memory eligibleBefore = _eligibleSupplies();
        _emergency(alive, 9 ether);
        (, uint256 aliceEth,) = ledger.previewAccount(ALICE);
        (, uint256 bobEth,) = ledger.previewAccount(BOB);
        (, uint256 carolEth,) = ledger.previewAccount(CAROL);
        assertEq(aliceEth, 7 ether + Math.mulDiv(1 ether, 2, 11) + Math.mulDiv(1 ether, 2, 5));
        assertEq(bobEth, 1 ether + Math.mulDiv(1 ether, 9, 11));
        assertEq(carolEth, 1.6 ether);
        assertEq(ledger.reservedEth(), 11 ether);

        // Materializing tokens after the terminal snapshot must not create another ETH share.
        uint256[10] memory claimed = _claimAll(ALICE);
        assertGt(claimed[1], 0);
        _assertEligibleSupplies(eligibleBefore);
        assertEq(ledger.claimEth(ALICE), aliceEth);
        assertEq(ledger.claimEth(ALICE), 0);
        assertEq(ledger.claimEth(BOB), bobEth);
        assertEq(ledger.claimEth(CAROL), carolEth);
        assertEq(ledger.reservedEth(), 11 ether - aliceEth - bobEth - carolEth);

        // A post-snapshot protocol transfer synchronizes its recipient first.
        _mint(1, address(this), 100 ether);
        _transfer(1, address(this), address(0xF00), 100 ether);
        _assertEligibleSupplies(eligibleBefore);
        (, uint256 lateRecipientEth,) = ledger.previewAccount(address(0xF00));
        assertEq(lateRecipientEth, 0);
    }

    function testEmergencyUnallocatedCrewSharesAndRemaindersNeverEnterPlayerReserve() public {
        _mint(0, ALICE, 100 ether);
        for (uint8 i; i < 10; ++i) {
            _mint(i, ENGINE, 1_000 ether);
            _mint(i, address(this), 1_000 ether);
        }
        _emergency(alive, 10 ether + 9);
        assertEq(ledger.reservedEth(), 1 ether);
        assertEq(ledger.claimEth(ALICE), 1 ether);
        assertEq(ledger.reservedEth(), 0);
        (, uint256 engineEth,) = ledger.previewAccount(ENGINE);
        (, uint256 hookEth,) = ledger.previewAccount(address(this));
        assertEq(engineEth, 0);
        assertEq(hookEth, 0);
    }

    function testEmergencyAfterPriorEthWithdrawalExpiresOnlyRemainingMixedRights() public {
        _mint(0, CAROL, 8 ether);
        _mint(1, ALICE, 1 ether);
        _mint(2, BOB, 1 ether);
        _eliminate(0, 9 ether);
        assertEq(ledger.claimEth(ALICE), 1 ether);
        assertEq(ledger.reservedEth(), 1 ether);
        _emergency(alive, 9 ether);
        (, uint256 aliceEth,) = ledger.previewAccount(ALICE);
        (, uint256 bobEth,) = ledger.previewAccount(BOB);
        (, uint256 carolEth,) = ledger.previewAccount(CAROL);
        assertEq(aliceEth, 0.6 ether, "already withdrawn prior reward is not restored");
        assertEq(bobEth, 1.6 ether, "unclaimed prior reward is preserved");
        assertEq(carolEth, 7.8 ether);
        assertEq(ledger.reservedEth(), 10 ether);
        assertEq(ledger.claimEth(BOB), bobEth);
        uint256 materialized = ledger.claimToken(CAROL, 1, 0.3 ether);
        _transfer(1, address(this), CAROL, materialized);
        uint256 remainingBacking = ledger.escrowBacking(1);
        (uint256 expiredEth, uint256[10] memory expiredBacking) = ledger.expireFinalClaims();
        assertEq(expiredEth, aliceEth + carolEth);
        assertEq(expiredBacking[1], remainingBacking);
        for (uint8 i; i < 10; ++i) {
            if (expiredBacking[i] != 0) _burn(i, address(this), expiredBacking[i]);
        }
        assertEq(MugiLedgerHistoryToken(tokens[1]).balanceOf(CAROL), materialized);
        (, uint256 afterExpiryEth,) = ledger.previewAccount(CAROL);
        assertEq(afterExpiryEth, 0);
        vm.expectRevert(MugiIMDLedger.InvalidClaim.selector);
        ledger.claimEth(BOB);
    }

    function testEmergencyRejectsWrongMaskAndCannotRecordAnotherTerminalOrRound() public {
        vm.expectRevert(MugiIMDLedger.InvalidRound.selector);
        _emergency(0, 1 ether);
        vm.expectRevert(MugiIMDLedger.InvalidRound.selector);
        _emergency(511, 1 ether);
        _mint(0, ALICE, 1 ether);
        _emergency(alive, 10 ether);
        vm.expectRevert(MugiIMDLedger.InvalidRound.selector);
        _emergency(alive, 10 ether);
        vm.expectRevert(MugiIMDLedger.InvalidRound.selector);
        ledger.recordElimination(0, alive, 1 ether, uint64(block.timestamp));
        vm.expectRevert(MugiIMDLedger.InvalidRound.selector);
        _finalize(0);
    }

    function testExpirationCannotResurrectSyncedOrLazyClaimsInEitherTerminalMode() public {
        _assertExpiry(false);
    }

    function testEmergencyExpirationCannotResurrectSyncedOrLazyClaims() public {
        _assertExpiry(true);
    }

    function testFuzzEagerMaterializationAndLateSyncHaveIdenticalEmergencyRights(uint8 eliminated, uint96 amount)
        public
    {
        uint8 rounds = uint8(bound(eliminated, 1, 9));
        uint256 balance = bound(uint256(amount), 1, 1e24);
        for (uint8 i; i < 10; ++i) {
            _mint(i, ALICE, balance);
            _mint(i, BOB, balance);
        }
        for (uint8 i; i < rounds; ++i) {
            _eliminate(i, uint256(i + 1) * 10 ether);
            uint256[10] memory liveSupply = _eligibleSupplies();
            _claimAll(ALICE);
            _assertEligibleSupplies(liveSupply);
        }
        // At nine eliminations this uses the tenth and final bounded event slot.
        _emergency(alive, 10 ether);
        (, uint256 eagerEth, uint256[10] memory eagerVirtual) = ledger.previewAccount(ALICE);
        (, uint256 lazyEth, uint256[10] memory lazyVirtual) = ledger.previewAccount(BOB);
        assertEq(eagerEth, lazyEth);
        assertGt(lazyEth, 0);
        for (uint8 i = rounds; i < 10; ++i) {
            uint256 eagerEffective =
                MugiLedgerHistoryToken(tokens[i]).balanceOf(ALICE) * ledger.SCALE() + eagerVirtual[i];
            uint256 lazyEffective = MugiLedgerHistoryToken(tokens[i]).balanceOf(BOB) * ledger.SCALE() + lazyVirtual[i];
            assertEq(eagerEffective, lazyEffective);
        }
        uint256 reserve = ledger.reservedEth();
        uint256[10] memory terminalSupply = _eligibleSupplies();
        _claimAll(BOB);
        _assertEligibleSupplies(terminalSupply);
        assertEq(ledger.claimEth(ALICE), eagerEth);
        assertEq(ledger.claimEth(BOB), lazyEth);
        assertEq(ledger.reservedEth(), reserve - eagerEth - lazyEth);
        assertEq(ledger.claimEth(BOB), 0);
    }

    function _assertExpiry(bool emergency) private {
        _mint(0, ALICE, 8 ether);
        _mint(0, BOB, 4 ether);
        _mint(9, ALICE, 2 ether);
        _mint(9, BOB, 1 ether);
        for (uint8 i; i < (emergency ? 3 : 9); ++i) {
            _eliminate(i, 9 ether);
        }
        if (emergency) _emergency(alive, 9 ether);
        else _finalize(9);
        ledger.claimEth(ALICE); // Synced storage, whereas Bob still has cursor zero.
        (uint256[10] memory bobTokens, uint256 bobEth,) = ledger.previewAccount(BOB);
        assertGt(bobTokens[9], 0);
        assertGt(bobEth, 0);
        (uint256[10] memory aliceTokens,,) = ledger.previewAccount(ALICE);
        uint256[10] memory eligibleBefore = _eligibleSupplies();
        uint256 materialized = ledger.claimToken(ALICE, 9, aliceTokens[9] / 2);
        assertGt(materialized, 0);
        _transfer(9, address(this), ALICE, materialized);
        _assertEligibleSupplies(eligibleBefore);
        uint256 reserved = ledger.reservedEth();
        uint256[10] memory backing;
        for (uint8 i; i < 10; ++i) {
            backing[i] = ledger.escrowBacking(i);
        }
        (uint256 expiredEth, uint256[10] memory expiredTokens) = ledger.expireFinalClaims();
        assertEq(expiredEth, reserved);
        assertEq(ledger.reservedEth(), 0);
        for (uint8 i; i < 10; ++i) {
            assertEq(expiredTokens[i], backing[i]);
            assertEq(ledger.escrowBacking(i), 0);
            assertEq(ledger.eligibleSupply(i), 0);
            if (expiredTokens[i] != 0) _burn(i, address(this), expiredTokens[i]);
            assertEq(ledger.eligibleSupply(i), 0);
        }
        // A late inventory handoff after expiry cannot revive eligible supply.
        _mint(9, address(this), 1 ether);
        _transfer(9, address(this), address(0xF00), 1 ether);
        assertEq(ledger.eligibleSupply(9), 0);
        for (uint8 i; i < 2; ++i) {
            address account = i == 0 ? ALICE : BOB;
            (uint256[10] memory claimable, uint256 ethClaim, uint256[10] memory virtualScaled) =
                ledger.previewAccount(account);
            assertEq(ethClaim, 0);
            for (uint8 crew; crew < 10; ++crew) {
                assertEq(claimable[crew], 0);
                assertEq(virtualScaled[crew], 0);
            }
            vm.expectRevert(MugiIMDLedger.InvalidClaim.selector);
            ledger.claimTokens(account);
            vm.expectRevert(MugiIMDLedger.InvalidClaim.selector);
            ledger.claimToken(account, 9, 0);
            vm.expectRevert(MugiIMDLedger.InvalidClaim.selector);
            ledger.claimEth(account);
        }
        vm.expectRevert(MugiIMDLedger.InvalidClaim.selector);
        ledger.expireFinalClaims();
    }

}
