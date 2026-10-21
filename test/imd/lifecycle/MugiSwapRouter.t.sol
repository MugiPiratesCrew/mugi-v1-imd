// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

// IMD modular regression adapted from v1/test/game/MugiSwapRouter.t.sol.
// Exercises CALL-module custody with the same season/accounting assertions.

import {MugiGameTestBase} from "./MugiGameHook.t.sol";
import {MugiIMDGameHook as MugiGameHook} from "../../../src/imd/MugiIMDGameHook.sol";
import {MugiIMDSwapRouter as MugiSwapRouter} from "../../../src/imd/MugiIMDSwapRouter.sol";
import {MugiCrewToken} from "../../../src/game/MugiCrewToken.sol";
import {PoolManager} from "v4-core/src/PoolManager.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {TransientStateLibrary} from "v4-core/src/libraries/TransientStateLibrary.sol";

contract RouterRecipient {
    MugiSwapRouter private immutable router;
    MugiCrewToken private immutable token;
    bool public attemptReentry;
    bool public rejectEth;
    bool public reentrySucceeded;
    bytes4 public reentryError;

    constructor(MugiSwapRouter router_, MugiCrewToken token_) { router = router_; token = token_; }

    function sell(uint256 amount, bool attack, bool reject) external returns (uint256) {
        attemptReentry = attack;
        rejectEth = reject;
        token.approve(address(router), amount);
        return router.sell(0, amount, 1, type(uint64).max);
    }

    receive() external payable {
        require(!rejectEth, "recipient rejects ETH");
        if (attemptReentry) {
            (bool success, bytes memory result) = address(router).call{value: 1}(
                abi.encodeCall(router.buy, (0, 0, type(uint64).max))
            );
            reentrySucceeded = success;
            if (result.length >= 4) reentryError = bytes4(result);
        }
    }
}

contract UnsolicitedRouterUnlock {
    MugiSwapRouter private immutable router;
    IPoolManager private immutable manager;
    bool public succeeded;
    bytes4 public errorSelector;

    constructor(MugiSwapRouter router_) { router = router_; manager = router_.poolManager(); }

    function attack() external payable { manager.unlock(bytes("")); }

    function unlockCallback(bytes calldata) external returns (bytes memory) {
        require(msg.sender == address(manager));
        (bool success, bytes memory result) = address(router).call{value: 1}(
            abi.encodeCall(router.buy, (0, 0, type(uint64).max))
        );
        succeeded = success;
        if (result.length >= 4) errorSelector = bytes4(result);
        return bytes("");
    }
}

contract MugiSwapRouterTest is MugiGameTestBase {
    using TransientStateLibrary for IPoolManager;
    MugiSwapRouter private playerRouter;

    function setUp() public {
        vm.warp(1_800_000_000);
        _setup(new PoolManager(address(this)));
        playerRouter = new MugiSwapRouter(game);
        vm.deal(ALICE, 10 ether);
    }

    function testBuyUsesOfficialPoolPaysBothFeesAndDeliversDirectlyToHolder() public {
        assertEq(address(playerRouter.hook()), address(game));
        assertEq(address(playerRouter.poolManager()), address(manager));
        uint256 tokensBefore = MugiCrewToken(crew[0]).balanceOf(ALICE);
        uint256 eligibleBefore = game.eligibleSupply(0);
        vm.prank(ALICE);
        uint256 output = playerRouter.buy{value: 1 ether}(0, 1, uint64(block.timestamp));
        assertGt(output, 0);
        assertEq(ALICE.balance, 9 ether);
        assertEq(MugiCrewToken(crew[0]).balanceOf(ALICE), tokensBefore + output);
        assertEq(game.eligibleSupply(0), eligibleBefore + output * 95_126_814_720);
        assertEq(game.ownBurnBudget(0), 0.01 ether);
        assertEq(game.treasure(0), 0.01 ether);
        game.collectTeamFees(0);
        assertGt(game.teamEth(), 0, "the ordinary router must pay the LP fee too");
        _assertNoCustody(0);
        _assertSolvent();
    }

    function testSellDebitsActualTokensAndReceivesNetEthWithNoRouterInventory() public {
        uint256 input = 100 ether;
        uint256 tokensBefore = MugiCrewToken(crew[0]).balanceOf(ALICE);
        uint256 ethBefore = ALICE.balance;
        vm.startPrank(ALICE);
        MugiCrewToken(crew[0]).approve(address(playerRouter), input);
        uint256 output = playerRouter.sell(0, input, 1, uint64(block.timestamp));
        vm.stopPrank();
        assertGt(output, 0);
        assertEq(ALICE.balance, ethBefore + output);
        assertEq(MugiCrewToken(crew[0]).balanceOf(ALICE), tokensBefore - input);
        assertEq(MugiCrewToken(crew[0]).allowance(ALICE, address(playerRouter)), 0);
        uint256 fees = game.ownBurnBudget(0) + game.treasure(0);
        uint256 gross = output + fees;
        assertEq(fees, gross * 2 / 100);
        assertEq(game.ownBurnBudget(0), fees / 2);
        game.collectTeamFees(0);
        assertGt(game.teamTokens(0), 0);
        _assertNoCustody(0);
        _assertSolvent();
    }

    function testBuyMinimumOutputFailureRevertsPaymentAndBothFeeBuckets() public {
        uint256 beforeTokens = MugiCrewToken(crew[0]).balanceOf(ALICE);
        (uint160 beforePrice,,) = game.poolState(0);
        vm.prank(ALICE);
        vm.expectRevert(MugiSwapRouter.InsufficientOutput.selector);
        playerRouter.buy{value: 1 ether}(0, type(uint256).max, uint64(block.timestamp));
        assertEq(ALICE.balance, 10 ether);
        assertEq(MugiCrewToken(crew[0]).balanceOf(ALICE), beforeTokens);
        assertEq(game.unredeemedGameFees(), 0);
        (uint160 afterPrice,,) = game.poolState(0);
        assertEq(afterPrice, beforePrice);
        _assertNoCustody(0);
    }

    function testSellMinimumOutputFailurePreservesAllowanceAndBalances() public {
        uint256 beforeTokens = MugiCrewToken(crew[0]).balanceOf(ALICE);
        vm.startPrank(ALICE);
        MugiCrewToken(crew[0]).approve(address(playerRouter), 100 ether);
        vm.expectRevert(MugiSwapRouter.InsufficientOutput.selector);
        playerRouter.sell(0, 100 ether, type(uint256).max, uint64(block.timestamp));
        vm.stopPrank();
        assertEq(ALICE.balance, 10 ether);
        assertEq(MugiCrewToken(crew[0]).balanceOf(ALICE), beforeTokens);
        assertEq(MugiCrewToken(crew[0]).allowance(ALICE, address(playerRouter)), 100 ether);
        assertEq(game.unredeemedGameFees(), 0);
        _assertNoCustody(0);
    }

    function testSalesRequireUsersOwnApprovalAndCannotSpendAnotherWallet() public {
        vm.startPrank(BOB);
        MugiCrewToken(crew[0]).approve(address(playerRouter), type(uint256).max);
        vm.stopPrank();
        uint256 aliceTokens = MugiCrewToken(crew[0]).balanceOf(ALICE);
        vm.prank(ALICE);
        vm.expectRevert();
        playerRouter.sell(0, 100 ether, 1, uint64(block.timestamp));
        assertEq(MugiCrewToken(crew[0]).balanceOf(ALICE), aliceTokens);
        assertEq(game.unredeemedGameFees(), 0);
        // A router approval is not an approval of another caller's transferFrom.
        vm.prank(ALICE);
        MugiCrewToken(crew[0]).approve(address(playerRouter), type(uint256).max);
        vm.prank(BOB);
        vm.expectRevert();
        playerRouter.sell(0, 100 ether, 1, uint64(block.timestamp));
        assertEq(MugiCrewToken(crew[0]).balanceOf(ALICE), aliceTokens);
        _assertNoCustody(0);
    }

    function testBuyAndSellRejectExpiredDeadlines() public {
        vm.prank(ALICE);
        vm.expectRevert(MugiSwapRouter.DeadlineExpired.selector);
        playerRouter.buy{value: 1 ether}(0, 1, uint64(block.timestamp - 1));
        vm.prank(ALICE);
        vm.expectRevert(MugiSwapRouter.DeadlineExpired.selector);
        playerRouter.sell(0, 100 ether, 1, uint64(block.timestamp - 1));
        assertEq(game.unredeemedGameFees(), 0);
    }

    function testRejectsInvalidCrewAndUnsafeInputBounds() public {
        vm.expectRevert(MugiSwapRouter.InvalidCrew.selector);
        playerRouter.buy{value: 1}(10, 0, uint64(block.timestamp));
        vm.expectRevert(MugiSwapRouter.InvalidCrew.selector);
        playerRouter.sell(10, 1, 0, uint64(block.timestamp));
        vm.expectRevert(MugiSwapRouter.InvalidAmount.selector);
        playerRouter.buy(0, 0, uint64(block.timestamp));
        vm.expectRevert(MugiSwapRouter.InvalidAmount.selector);
        playerRouter.sell(0, 0, 0, uint64(block.timestamp));
        vm.expectRevert(MugiSwapRouter.InvalidAmount.selector);
        playerRouter.sell(0, uint256(uint128(type(int128).max)) + 1, 0, uint64(block.timestamp));
        vm.expectRevert(MugiSwapRouter.InvalidConfiguration.selector);
        new MugiSwapRouter(MugiGameHook(payable(address(1))));
    }

    function testUnsolicitedCallbacksRejectedIncludingManagerWithoutPendingTrade() public {
        vm.expectRevert(MugiSwapRouter.UnauthorizedCallback.selector);
        playerRouter.unlockCallback(bytes(""));
        vm.prank(address(manager));
        vm.expectRevert(MugiSwapRouter.UnauthorizedCallback.selector);
        playerRouter.unlockCallback(abi.encode(ALICE, uint8(0), true, 1 ether, 0));
        assertEq(game.unredeemedGameFees(), 0);
    }

    function testThirdPartyManagerUnlockCannotUseRouter() public {
        UnsolicitedRouterUnlock attacker = new UnsolicitedRouterUnlock(playerRouter);
        attacker.attack{value: 1}();
        assertFalse(attacker.succeeded());
        assertEq(attacker.errorSelector(), MugiSwapRouter.ReentrantCall.selector);
        assertEq(game.unredeemedGameFees(), 0);
        assertFalse(manager.isUnlocked());
    }

    function testEthRecipientCannotReenterDuringSellSettlement() public {
        RouterRecipient recipient = new RouterRecipient(playerRouter, MugiCrewToken(crew[0]));
        vm.prank(ALICE);
        MugiCrewToken(crew[0]).transfer(address(recipient), 100 ether);
        uint256 output = recipient.sell(100 ether, true, false);
        assertGt(output, 0);
        assertEq(address(recipient).balance, output);
        assertFalse(recipient.reentrySucceeded());
        assertEq(recipient.reentryError(), MugiSwapRouter.ReentrantCall.selector);
        assertEq(MugiCrewToken(crew[0]).balanceOf(address(recipient)), 0);
        _assertNoCustody(0);
    }

    function testRejectingEthRecipientRollsBackWholeSale() public {
        RouterRecipient recipient = new RouterRecipient(playerRouter, MugiCrewToken(crew[0]));
        vm.prank(ALICE);
        MugiCrewToken(crew[0]).transfer(address(recipient), 100 ether);
        vm.expectRevert();
        recipient.sell(100 ether, false, true);
        assertEq(MugiCrewToken(crew[0]).balanceOf(address(recipient)), 100 ether);
        assertEq(address(recipient).balance, 0);
        assertEq(game.unredeemedGameFees(), 0);
        _assertNoCustody(0);
    }

    function testForcedEthCannotBeWithdrawnByNextBuyerOrSeller() public {
        vm.deal(address(playerRouter), 3 ether);
        vm.startPrank(ALICE);
        playerRouter.buy{value: 1 ether}(0, 1, uint64(block.timestamp));
        assertEq(address(playerRouter).balance, 3 ether);
        assertEq(ALICE.balance, 9 ether);
        MugiCrewToken(crew[0]).approve(address(playerRouter), 100 ether);
        playerRouter.sell(0, 100 ether, 1, uint64(block.timestamp));
        vm.stopPrank();
        assertEq(address(playerRouter).balance, 3 ether);
        assertEq(MugiCrewToken(crew[0]).balanceOf(address(playerRouter)), 0);
        (bool accepted,) = address(playerRouter).call{value: 1}(bytes(""));
        assertFalse(accepted, "unrequested ETH is rejected");
    }

    function testOfficialHookPauseCutoffAndEliminationCannotBeBypassed() public {
        vm.startPrank(ALICE);
        MugiCrewToken(crew[0]).approve(address(playerRouter), type(uint256).max);
        vm.stopPrank();
        game.setPaused(true);
        vm.prank(ALICE);
        vm.expectRevert();
        playerRouter.buy{value: 1 ether}(0, 1, type(uint64).max);
        game.setPaused(false);
        vm.warp(game.nextCutoff());
        vm.prank(ALICE);
        vm.expectRevert();
        playerRouter.sell(0, 100 ether, 1, type(uint64).max);
        _round(0);
        vm.prank(ALICE);
        vm.expectRevert();
        playerRouter.buy{value: 1 ether}(0, 1, type(uint64).max);
        vm.prank(ALICE);
        assertGt(playerRouter.buy{value: 1 ether}(1, 1, type(uint64).max), 0);
        _assertNoCustody(1);
    }

    function testFuzzNormalTradesPreserveCustodyAndChargeGameFees(uint96 amount) public {
        uint256 input = bound(uint256(amount), 1e12, 2 ether);
        uint256 tokensBefore = MugiCrewToken(crew[0]).balanceOf(ALICE);
        vm.startPrank(ALICE);
        uint256 purchased = playerRouter.buy{value: input}(0, 1, type(uint64).max);
        assertEq(game.unredeemedGameFees(), input * 2 / 100);
        uint256 sellInput = purchased / 2;
        MugiCrewToken(crew[0]).approve(address(playerRouter), sellInput);
        uint256 received = playerRouter.sell(0, sellInput, 1, type(uint64).max);
        vm.stopPrank();
        assertEq(MugiCrewToken(crew[0]).balanceOf(ALICE), tokensBefore + purchased - sellInput);
        assertEq(ALICE.balance, 10 ether - input + received);
        _assertNoCustody(0);
        _assertSolvent();
    }

    function _assertNoCustody(uint8 id) private view {
        assertEq(address(playerRouter).balance, 0);
        assertEq(MugiCrewToken(crew[id]).balanceOf(address(playerRouter)), 0);
        assertEq(manager.currencyDelta(address(playerRouter), game.poolKey(id).currency0), 0);
        assertEq(manager.currencyDelta(address(playerRouter), game.poolKey(id).currency1), 0);
        assertFalse(manager.isUnlocked());
    }
}
