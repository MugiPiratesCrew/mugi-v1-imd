// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {MugiIMDLedger} from "../../../src/imd/modules/MugiIMDLedger.sol";
import {MugiIMDLedgerFixture} from "./MugiIMDLedgerFixture.sol";

contract MugiIMDLedgerSeasonTest is MugiIMDLedgerFixture {
    function testConstructorFixesAllProtocolExclusionsWithoutInitialization() public {
        address[7] memory excluded = [MANAGER, ENGINE, AIRDROP, TEAM, COMMUNITY, address(this), address(ledger)];
        for (uint8 i; i < 7; ++i) _mint(0, excluded[i], 100 ether);
        _mint(0, ALICE, 1 ether);
        assertEq(ledger.eligibleSupply(0), 1 ether * ledger.SCALE());
        _emergency(alive, 10 ether);
        assertEq(ledger.claimEth(ALICE), 1 ether);
        for (uint8 i; i < 7; ++i) {
            (, uint256 earned,) = ledger.previewAccount(excluded[i]);
            assertEq(earned, 0);
        }
    }

    function testConstructorWorksBeforeAnyDependencyCodeExists() public {
        MugiIMDLedger.Configuration memory c;
        c.hook = address(1001);
        c.token0 = address(2000); c.token1 = address(2001); c.token2 = address(2002); c.token3 = address(2003);
        c.token4 = address(2004); c.token5 = address(2005); c.token6 = address(2006); c.token7 = address(2007);
        c.token8 = address(2008); c.token9 = address(2009);
        c.airdrop = address(3000); c.engine = address(3001); c.team = address(3002);
        c.community = address(3003); c.manager = address(3004);
        MugiIMDLedger futureDependencies = new MugiIMDLedger(c);
        assertEq(futureDependencies.hook(), c.hook);
        assertEq(futureDependencies.reservedEth(), 0);
        assertEq(futureDependencies.escrowBacking(0), 0);
    }

    function testDuplicateTreasuryAddressesAreSubtractedOnlyOnce() public {
        MugiIMDLedger.Configuration memory c = _configuration();
        c.community = c.team;
        ledger = new MugiIMDLedger(c);
        _mint(0, TEAM, 100 ether);
        _mint(0, ALICE, 1 ether);
        assertEq(ledger.eligibleSupply(0), 1 ether * ledger.SCALE());
        _emergency(alive, 10 ether);
        assertEq(ledger.claimEth(ALICE), 1 ether);
    }

    function testConstructorRejectsZeroOrDuplicateTokensAndTokenProtocolRoleCollision() public {
        MugiIMDLedger.Configuration memory c = _configuration();
        c.token0 = address(0);
        vm.expectRevert(MugiIMDLedger.InvalidConfiguration.selector);
        new MugiIMDLedger(c);
        c = _configuration();
        c.token9 = c.token0;
        vm.expectRevert(MugiIMDLedger.InvalidConfiguration.selector);
        new MugiIMDLedger(c);
        c = _configuration();
        c.token0 = c.engine;
        vm.expectRevert(MugiIMDLedger.InvalidConfiguration.selector);
        new MugiIMDLedger(c);
        c = _configuration();
        c.hook = address(0);
        vm.expectRevert(MugiIMDLedger.InvalidConfiguration.selector);
        new MugiIMDLedger(c);
        c = _configuration();
        c.manager = address(0);
        vm.expectRevert(MugiIMDLedger.InvalidConfiguration.selector);
        new MugiIMDLedger(c);
    }
}
