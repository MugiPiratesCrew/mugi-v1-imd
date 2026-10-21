// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {MugiIMDLedger} from "../../../src/imd/modules/MugiIMDLedger.sol";

contract MugiIMDLedgerTestToken is ERC20 {
    constructor() ERC20("Ledger test token", "TEST") {}
    function mint(address account, uint256 amount) external { _mint(account, amount); }
}

contract MugiIMDLedgerSecurityTest is Test {
    address internal constant ALICE = address(0xA11CE);
    address internal constant ENGINE = address(0xE0919E);
    MugiIMDLedger internal ledger;
    address[10] internal tokens;

    function setUp() public {
        ledger = new MugiIMDLedger(address(this));
        for (uint8 crew; crew < 10; ++crew) tokens[crew] = address(new MugiIMDLedgerTestToken());
        ledger.initialize(tokens);
        ledger.setExcluded(ENGINE, true);
    }

    function testCallBoundaryPreservesHookAndEngineInventoryExclusion() public {
        _mint(0, address(this), 100 ether);
        _mint(0, address(ledger), 7 ether);
        _mint(0, ENGINE, 50 ether);
        _mint(0, ALICE, 2 ether);
        assertEq(ledger.eligibleSupply(0), 2 ether * ledger.SCALE());

        ledger.beforeBalanceChange(address(this), ALICE);
        MugiIMDLedgerTestToken(tokens[0]).transfer(ALICE, 1 ether);
        ledger.afterBalanceChange(0, address(this), ALICE, 1 ether);
        assertEq(ledger.eligibleSupply(0), 3 ether * ledger.SCALE());
        assertEq(MugiIMDLedgerTestToken(tokens[0]).balanceOf(address(this)), 99 ether);
    }

    function testLedgerCannotReclassifyHookOrItsOwnAddressAsEligible() public {
        vm.expectRevert(MugiIMDLedger.InvalidConfiguration.selector);
        ledger.setExcluded(address(this), false);
        vm.expectRevert(MugiIMDLedger.InvalidConfiguration.selector);
        ledger.setExcluded(address(ledger), false);
        vm.expectRevert(MugiIMDLedger.InvalidConfiguration.selector);
        ledger.setExcluded(address(0), false);
    }

    function testAllLedgerMutatorsRejectOutsideCaller() public {
        vm.startPrank(ALICE);
        vm.expectRevert(MugiIMDLedger.Unauthorized.selector);
        ledger.initialize(tokens);
        vm.expectRevert(MugiIMDLedger.Unauthorized.selector);
        ledger.setExcluded(ALICE, true);
        vm.expectRevert(MugiIMDLedger.Unauthorized.selector);
        ledger.beforeBalanceChange(ALICE, ENGINE);
        vm.expectRevert(MugiIMDLedger.Unauthorized.selector);
        ledger.afterBalanceChange(0, ALICE, ENGINE, 1 ether);
        vm.expectRevert(MugiIMDLedger.Unauthorized.selector);
        ledger.recordElimination(0, 1023, 1 ether);
        vm.expectRevert(MugiIMDLedger.Unauthorized.selector);
        ledger.finalizeMigration(0);
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

    function testExcludedProtocolInventoryCannotCaptureEliminationRewards() public {
        _mint(0, address(this), 100 ether);
        _mint(0, ENGINE, 50 ether);
        _mint(0, ALICE, 2 ether);
        _mint(1, address(this), 100 ether);
        _mint(1, ENGINE, 50 ether);
        _mint(1, ALICE, 1 ether);
        ledger.recordElimination(0, 1023, 9 ether);
        (, uint256 hookRewards,) = ledger.previewAccount(address(this));
        (, uint256 engineRewards,) = ledger.previewAccount(ENGINE);
        (, uint256 playerRewards,) = ledger.previewAccount(ALICE);
        assertEq(hookRewards, 0);
        assertEq(engineRewards, 0);
        assertEq(playerRewards, 1 ether); // One of nine survivor shares belongs wholly to its eligible holder.
        (uint256[10] memory claimable,,) = ledger.previewAccount(ALICE);
        assertGt(claimable[1], 0);
        (uint256[10] memory protocolClaimable,,) = ledger.previewAccount(address(this));
        assertEq(protocolClaimable[1], 0);
    }

    function _mint(uint8 crew, address account, uint256 amount) private {
        ledger.beforeBalanceChange(address(0), account);
        MugiIMDLedgerTestToken(tokens[crew]).mint(account, amount);
        ledger.afterBalanceChange(crew, address(0), account, amount);
    }
}
