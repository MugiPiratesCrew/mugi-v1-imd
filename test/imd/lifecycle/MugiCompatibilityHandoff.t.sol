// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {MugiGameTestBase} from "./MugiGameHook.t.sol";
import {MugiIMDGameHook} from "../../../src/imd/MugiIMDGameHook.sol";
import {MugiCrewToken} from "../../../src/game/MugiCrewToken.sol";
import {PoolManager} from "v4-core/src/PoolManager.sol";

contract HandoffReceiver {
    bool public reject;
    uint256 public receivedEth;
    uint256 public receivedTokens;
    address public receivedToken;
    uint8 public receivedCrew;
    function setReject(bool value) external { reject = value; }
    function receiveV1Finale(uint8 survivor, address token, uint256 amount) external payable {
        require(!reject, "receiver rejected");
        require(MugiCrewToken(token).balanceOf(address(this)) >= amount, "inventory missing");
        receivedCrew = survivor;
        receivedToken = token;
        receivedTokens = amount;
        receivedEth = msg.value;
    }
}

contract MugiCompatibilityHandoffTest is MugiGameTestBase {
    function setUp() public {
        vm.warp(1_800_000_000);
        _setup(new PoolManager(address(this)));
    }

    // The production constructor may leave V2 unselected until its code exists.
    function _migrationTarget() internal pure override returns (address) { return address(0); }

    function testCutoffAndKnownLoserTransfersDoNotMoveOrDuplicateConversion() public {
        _fundTreasure(0);
        uint256 beforeBalance = MugiCrewToken(crew[0]).balanceOf(ALICE);
        vm.warp(game.nextCutoff());
        vm.prank(ALICE);
        MugiCrewToken(crew[0]).transfer(address(0xDEAD1), beforeBalance / 2);
        game.requestElimination();
        randomness.fulfill(game.pendingRequest(), 0);
        vm.prank(ALICE);
        MugiCrewToken(crew[0]).transfer(address(0xDEAD2), beforeBalance - beforeBalance / 2);
        game.settleRound(1);
        vm.prank(address(0xDEAD1));
        MugiCrewToken(crew[0]).transfer(address(0xDEAD2), beforeBalance / 2);
        game.settleRound(10);
        (uint256[10] memory alice,,) = game.previewAccount(ALICE);
        (uint256[10] memory early,,) = game.previewAccount(EARLY);
        (uint256[10] memory receiver1, uint256 reward1,) = game.previewAccount(address(0xDEAD1));
        (uint256[10] memory receiver2, uint256 reward2,) = game.previewAccount(address(0xDEAD2));
        assertGt(alice[1], 0);
        for (uint8 i; i < 10; ++i) {
            assertEq(alice[i], early[i], "original cutoff owner retains conversion");
            assertEq(receiver1[i], 0);
            assertEq(receiver2[i], 0);
        }
        assertEq(reward1 + reward2, 0);
        vm.prank(ALICE);
        game.claimTokens();
        (uint256[10] memory claimed,,) = game.previewAccount(ALICE);
        for (uint8 i; i < 10; ++i) assertEq(claimed[i], 0);
        _assertSolvent();
    }

    function _finishSeason() private {
        for (uint8 i; i < 9; ++i) {
            _fundTreasure(i);
            _round(0);
            assertEq(game.unreleasedReserve(i), 0, "defeated reserve retired");
        }
        uint256 unused = game.unreleasedReserve(9);
        uint256 supplyBefore = MugiCrewToken(crew[9]).totalSupply();
        vm.warp(game.nextCutoff());
        game.finalize();
        assertEq(game.unreleasedReserve(9), 0);
        assertEq(MugiCrewToken(crew[9]).totalSupply(), supplyBefore - unused);
        _assertSolvent();
    }

    function testV2HandoffPreservesPlayerEthAndTokensAndRetiresUnusedSupply() public {
        _finishSeason();
        HandoffReceiver receiver = new HandoffReceiver();
        uint256 ethReserved = game.reservedPlayerEth();
        uint256 tokenReserved = game.escrowBacking(9);
        uint256 eligible = game.eligibleSupply(9);
        uint256 ethToV2 = address(game).balance - game.teamEth() - ethReserved;
        uint256 tokensToV2 = MugiCrewToken(crew[9]).balanceOf(address(game)) - tokenReserved;
        (uint256[10] memory beforeTokens, uint256 beforeEth,) = game.previewAccount(ALICE);
        assertGt(beforeTokens[9], 0);
        assertGt(beforeEth, 0);
        vm.prank(BOB);
        vm.expectRevert(MugiIMDGameHook.Unauthorized.selector);
        game.migrateToV2(address(receiver));
        game.migrateToV2(address(receiver));
        assertTrue(game.migrated());
        assertEq(receiver.receivedCrew(), 9);
        assertEq(receiver.receivedToken(), crew[9]);
        assertEq(receiver.receivedEth(), ethToV2);
        assertEq(receiver.receivedTokens(), tokensToV2);
        assertEq(address(game).balance, game.teamEth() + ethReserved);
        assertEq(MugiCrewToken(crew[9]).balanceOf(address(game)), tokenReserved);
        (uint256[10] memory afterTokens, uint256 afterEth,) = game.previewAccount(ALICE);
        assertEq(afterTokens[9], beforeTokens[9]);
        assertEq(afterEth, beforeEth);
        vm.startPrank(ALICE);
        game.claimTokens();
        assertEq(game.claimEth(payable(ALICE)), beforeEth);
        MugiCrewToken(crew[9]).transfer(BOB, beforeTokens[9]);
        vm.stopPrank();
        assertEq(game.eligibleSupply(9), eligible, "terminal denominator frozen");
        vm.expectRevert(MugiIMDGameHook.InvalidState.selector);
        game.migrateToV2(address(receiver));
        _assertSolvent();
    }

    function testRejectingV2ReceiverRollsBackAllTransfersAndAllowsRetry() public {
        _finishSeason();
        HandoffReceiver receiver = new HandoffReceiver();
        receiver.setReject(true);
        uint256 ethBefore = address(game).balance;
        uint256 tokensBefore = MugiCrewToken(crew[9]).balanceOf(address(game));
        vm.expectRevert(bytes("receiver rejected"));
        game.migrateToV2(address(receiver));
        assertFalse(game.migrated());
        assertEq(address(game).balance, ethBefore);
        assertEq(MugiCrewToken(crew[9]).balanceOf(address(game)), tokensBefore);
        assertEq(MugiCrewToken(crew[9]).balanceOf(address(receiver)), 0);
        receiver.setReject(false);
        game.migrateToV2(address(receiver));
        assertTrue(game.migrated());
        _assertSolvent();
    }
}
