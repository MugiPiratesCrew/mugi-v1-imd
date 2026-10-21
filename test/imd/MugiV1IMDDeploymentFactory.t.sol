// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {PoolManager} from "v4-core/src/PoolManager.sol";
import {MugiIMDDeploymentFixture} from "./helpers/MugiIMDDeploymentFixture.sol";
import {MugiIMDGameHook as MugiGameHook} from "../../src/imd/MugiIMDGameHook.sol";
import {MugiIMDCrewFactory} from "../../src/imd/MugiIMDCrewFactory.sol";
import {MugiIMDAccountingFactory} from "../../src/imd/MugiIMDAccountingFactory.sol";
import {MugiIMDEngineFactory} from "../../src/imd/MugiIMDEngineFactory.sol";
import {MugiV1IMDDeploymentFactory} from "../../src/imd/MugiV1IMDDeploymentFactory.sol";
import {MugiVRFAdapter} from "../../src/game/MugiVRFAdapter.sol";
import {MugiIMDLedger} from "../../src/imd/modules/MugiIMDLedger.sol";

contract MugiV1IMDDeploymentFactoryTest is MugiIMDDeploymentFixture {
    function setUp() public {
        vm.warp(1 days);
        manager = new PoolManager(address(this));
        _newFactories();
    }

    function testCompleteConstructorGraphSeedsAllPoolsAndLaunchesWithoutInitializers() public {
        MugiGameHook game = _deployGraph();
        _seedAndLaunch(game);
    }

    function testFactoriesPinSourceHaveNoChildrenAtConstructionAndFitEvmLimits() public view {
        assertEq(factory.hookCreationCodeHash(), keccak256(type(MugiGameHook).creationCode));
        assertEq(factory.hookCreationCodeLength(), type(MugiGameHook).creationCode.length);
        assertEq(vm.getNonce(address(factory)), 1);
        assertEq(vm.getNonce(address(crewFactory)), 1);
        assertEq(vm.getNonce(address(accountingFactory)), 1);
        assertEq(vm.getNonce(address(engineFactory)), 1);
        assertLe(address(factory).code.length, 24_576);
        assertLe(address(crewFactory).code.length, 24_576);
        assertLe(address(accountingFactory).code.length, 24_576);
        assertLe(address(engineFactory).code.length, 24_576);
        assertLe(type(MugiV1IMDDeploymentFactory).creationCode.length + 32, 49_152);
        assertLe(type(MugiIMDCrewFactory).creationCode.length + 32, 49_152);
        assertLe(type(MugiIMDAccountingFactory).creationCode.length + 32, 49_152);
        assertLe(type(MugiIMDEngineFactory).creationCode.length + 32, 49_152);
    }

    function testFactoryCreationBatchHasConservativeGasHeadroom() public {
        uint256 start = gasleft();
        _newFactories();
        uint256 execution = start - gasleft();
        uint256 calldataUpperBound = 16 * (type(MugiIMDCrewFactory).creationCode.length
            + type(MugiIMDAccountingFactory).creationCode.length + type(MugiIMDEngineFactory).creationCode.length
            + type(MugiV1IMDDeploymentFactory).creationCode.length + 4 * 32);
        emit log_named_uint("Four factory creation execution gas", execution);
        assertLt(execution + calldataUpperBound + 100_000, 16_777_216);
    }

    function testEveryDescendantCreationCallFitsSeparateTransactionGasCap() public {
        bytes memory code = _hookCode(_hookConfiguration());
        bytes32 salt = _mine(keccak256(code));
        address futureHook = factory.predictHook(salt, keccak256(code));
        MugiV1IMDDeploymentFactory.ModuleConfiguration memory moduleConfig = _moduleConfiguration();
        MugiIMDLedger.Configuration memory ledgerConfig = _ledgerConfiguration(futureHook);
        vm.startPrank(OWNER);
        uint256 start = gasleft();
        factory.deployModules(salt, keccak256(code), moduleConfig);
        _assertTransactionGas("Four service module creations", start - gasleft(), 4 + 16 * 32);
        start = gasleft();
        crewFactory.deployCrewSet(futureHook, SUPPLY);
        _assertTransactionGas("Ten crew token creations", start - gasleft(), 4 + 2 * 32);
        start = gasleft();
        engineFactory.deployForHook(futureHook, manager);
        _assertTransactionGas("Engine creation", start - gasleft(), 4 + 2 * 32);
        start = gasleft();
        accountingFactory.deployForHook(ledgerConfig);
        _assertTransactionGas("Three accounting module creations", start - gasleft(), 4 + 16 * 32);
        start = gasleft();
        factory.deployHook(code);
        _assertTransactionGas("Hook creation", start - gasleft(), 4 + 2 * 32 + code.length + 32);
        vm.stopPrank();
    }

    function _assertTransactionGas(string memory label, uint256 execution, uint256 calldataBytes) private {
        emit log_named_uint(label, execution);
        // Treat every calldata byte as nonzero and leave additional overhead.
        assertLt(execution + 21_000 + 16 * calldataBytes + 100_000, 16_777_216);
    }

    function testUnauthorizedCallersCannotConsumeAnyPredictedAddress() public {
        bytes memory code = _hookCode(_hookConfiguration());
        bytes32 salt = _mine(keccak256(code));
        address futureHook = factory.predictHook(salt, keccak256(code));
        MugiIMDLedger.Configuration memory ledgerConfig = _ledgerConfiguration(futureHook);
        MugiV1IMDDeploymentFactory.ModuleConfiguration memory moduleConfig = _moduleConfiguration();
        vm.startPrank(address(0xBAD));
        vm.expectRevert(MugiIMDCrewFactory.Unauthorized.selector);
        crewFactory.deployCrewSet(futureHook, SUPPLY);
        vm.expectRevert(MugiIMDAccountingFactory.Unauthorized.selector);
        accountingFactory.deployForHook(ledgerConfig);
        vm.expectRevert(MugiIMDEngineFactory.Unauthorized.selector);
        engineFactory.deployForHook(futureHook, manager);
        vm.expectRevert(MugiV1IMDDeploymentFactory.Unauthorized.selector);
        factory.deployModules(salt, keccak256(code), moduleConfig);
        vm.expectRevert(MugiV1IMDDeploymentFactory.Unauthorized.selector);
        factory.deployHook(code);
        vm.stopPrank();
        assertEq(vm.getNonce(address(factory)), 1);
        assertEq(vm.getNonce(address(crewFactory)), 1);
        assertEq(vm.getNonce(address(accountingFactory)), 1);
        assertEq(vm.getNonce(address(engineFactory)), 1);
    }

    function testConstructorFailureRollsBackModuleCommitmentAndCreateNonces() public {
        bytes memory code = _hookCode(_hookConfiguration());
        bytes32 salt = _mine(keccak256(code));
        MugiV1IMDDeploymentFactory.ModuleConfiguration memory c = _moduleConfiguration();
        c.vrfCallbackGasLimit = 1;
        vm.prank(OWNER);
        vm.expectRevert(MugiVRFAdapter.InvalidConfiguration.selector);
        factory.deployModules(salt, keccak256(code), c);
        assertFalse(factory.modulesDeployed());
        assertEq(factory.plannedHook(), address(0));
        assertEq(factory.hookInitCodeHash(), bytes32(0));
        assertEq(vm.getNonce(address(factory)), 1);
        assertEq(factory.predictModules().router.code.length, 0);
        vm.prank(OWNER);
        factory.deployModules(salt, keccak256(code), _moduleConfiguration());
        assertEq(vm.getNonce(address(factory)), 5);
    }

    function testHookRequiresAllFourOwnModulesAndCrewCreationAndExactCommittedCode() public {
        bytes memory code = _hookCode(_hookConfiguration());
        bytes32 salt = _mine(keccak256(code));
        vm.prank(OWNER);
        vm.expectRevert(MugiV1IMDDeploymentFactory.ModulesUnavailable.selector);
        factory.deployHook(code);
        vm.prank(OWNER);
        factory.deployModules(salt, keccak256(code), _moduleConfiguration());
        vm.prank(OWNER);
        vm.expectRevert(MugiV1IMDDeploymentFactory.InvalidConfiguration.selector);
        factory.deployHook(code);
        address futureHook = factory.plannedHook();
        vm.prank(OWNER);
        crewFactory.deployCrewSet(futureHook, SUPPLY);
        bytes memory wrong = bytes.concat(code, hex"00");
        vm.prank(OWNER);
        vm.expectRevert(MugiV1IMDDeploymentFactory.InvalidHookInitCode.selector);
        factory.deployHook(wrong);
        assertEq(address(factory.hook()), address(0));
    }

    function testEvenCommittedArbitraryCreationCodeCannotReplacePinnedImplementation() public {
        bytes memory wrong = new bytes(type(MugiGameHook).creationCode.length + 14 * 32);
        bytes32 salt = _mine(keccak256(wrong));
        vm.prank(OWNER);
        factory.deployModules(salt, keccak256(wrong), _moduleConfiguration());
        address futureHook = factory.plannedHook();
        vm.prank(OWNER);
        crewFactory.deployCrewSet(futureHook, SUPPLY);
        vm.prank(OWNER);
        vm.expectRevert(MugiV1IMDDeploymentFactory.InvalidHookInitCode.selector);
        factory.deployHook(wrong);
        assertEq(factory.plannedHook().code.length, 0);
    }

    function testHookConfigurationCannotSubstituteFactoryModuleOrOwner() public {
        MugiGameHook.Configuration memory c = _hookConfiguration();
        c.randomnessProvider = address(0xBAD);
        bytes memory code = _hookCode(c);
        bytes32 salt = _mine(keccak256(code));
        _deployBeforeHook(code, salt);
        vm.prank(OWNER);
        vm.expectRevert(MugiV1IMDDeploymentFactory.InvalidConfiguration.selector);
        factory.deployHook(code);
    }

    function testMismatchedLedgerTokenBindingRejectsFirstPoolSeed() public {
        _assertMismatchedLedgerRejected(true);
    }

    function testMismatchedLedgerExclusionBindingRejectsFirstPoolSeed() public {
        _assertMismatchedLedgerRejected(false);
    }

    function _assertMismatchedLedgerRejected(bool changeToken) private {
        bytes memory code = _hookCode(_hookConfiguration());
        bytes32 salt = _mine(keccak256(code));
        address futureHook = factory.predictHook(salt, keccak256(code));
        MugiIMDLedger.Configuration memory ledgerConfig = _ledgerConfiguration(futureHook);
        if (changeToken) ledgerConfig.token0 = address(0xBAD);
        else ledgerConfig.manager = address(0xBAD);
        vm.deal(OWNER, 2 ether);
        vm.startPrank(OWNER);
        factory.deployModules(salt, keccak256(code), _moduleConfiguration());
        crewFactory.deployCrewSet(futureHook, SUPPLY);
        engineFactory.deployForHook(futureHook, manager);
        accountingFactory.deployForHook(ledgerConfig);
        MugiGameHook game = factory.deployHook(code);
        vm.expectRevert(MugiGameHook.InvalidConfiguration.selector);
        game.seedPool{value: 1 ether}(0);
        vm.stopPrank();
        assertEq(game.seededMask(), 0);
        assertEq(address(game).balance, 0);
    }

    function testSingleSeasonCommitmentsCannotBeReplacedAfterSuccess() public {
        MugiGameHook game = _deployGraph();
        bytes memory code = _hookCode(_hookConfiguration());
        MugiIMDLedger.Configuration memory ledgerConfig = _ledgerConfiguration(address(game));
        MugiV1IMDDeploymentFactory.ModuleConfiguration memory moduleConfig = _moduleConfiguration();
        bytes32 salt = factory.hookSalt();
        vm.startPrank(OWNER);
        vm.expectRevert(MugiIMDCrewFactory.AlreadyDeployed.selector);
        crewFactory.deployCrewSet(address(game), SUPPLY);
        vm.expectRevert(MugiIMDAccountingFactory.AlreadyDeployed.selector);
        accountingFactory.deployForHook(ledgerConfig);
        vm.expectRevert(MugiIMDEngineFactory.AlreadyDeployed.selector);
        engineFactory.deployForHook(address(game), manager);
        vm.expectRevert(MugiV1IMDDeploymentFactory.ModulesUnavailable.selector);
        factory.deployModules(salt, keccak256(code), moduleConfig);
        vm.expectRevert(MugiV1IMDDeploymentFactory.HookAlreadyDeployed.selector);
        factory.deployHook(code);
        vm.stopPrank();
    }
}
