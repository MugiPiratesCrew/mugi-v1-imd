// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;
import {PoolManager} from "v4-core/src/PoolManager.sol";
import {MugiIMDDeploymentFixture} from "./helpers/MugiIMDDeploymentFixture.sol";
import {MugiIMDGameHook} from "../../src/imd/MugiIMDGameHook.sol";
import {MugiV1IMDDeploymentFactory} from "../../src/imd/MugiV1IMDDeploymentFactory.sol";
contract MugiTerminalConfigurationTest is MugiIMDDeploymentFixture {
    function setUp() public { vm.warp(1 days); manager = new PoolManager(address(this)); _newFactories(); }
    function _reject(MugiIMDGameHook.Configuration memory c) private {
        bytes memory code = _hookCode(c);
        bytes32 salt = _mine(keccak256(code));
        address futureHook = _deployBeforeHook(code, salt);
        assertEq(uint160(futureHook) & 0x3fff, 0x2aec, "valid hook address flags");
        vm.prank(OWNER);
        vm.expectRevert(MugiV1IMDDeploymentFactory.DeploymentFailed.selector);
        factory.deployHook(code);
        assertEq(futureHook.code.length, 0);
    }
    function testZeroV2ReceiverCannotCreateHook() public {
        MugiIMDGameHook.Configuration memory c = _hookConfiguration(); c.v2MigrationTarget = address(0); _reject(c);
    }
    function testOwnerCannotBeCommunityDestination() public {
        MugiIMDGameHook.Configuration memory c = _hookConfiguration(); c.community = OWNER; _reject(c);
    }
    function testTeamCannotBeCommunityDestination() public {
        MugiIMDGameHook.Configuration memory c = _hookConfiguration(); c.community = TEAM; _reject(c);
    }
    function testNonzeroFutureV2ContractCanBePinnedBeforeItsDeployment() public {
        MugiIMDGameHook.Configuration memory c = _hookConfiguration(); c.v2MigrationTarget = address(0xABC123);
        assertEq(c.v2MigrationTarget.code.length, 0);
        bytes memory code = _hookCode(c); bytes32 salt = _mine(keccak256(code)); _deployBeforeHook(code, salt);
        vm.prank(OWNER); MugiIMDGameHook game = factory.deployHook(code);
        assertEq(game.v2MigrationTarget(), c.v2MigrationTarget);
    }
}
