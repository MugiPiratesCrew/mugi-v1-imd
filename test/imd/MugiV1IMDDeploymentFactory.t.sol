// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {PoolManager} from "v4-core/src/PoolManager.sol";
import {MugiIMDGameHook as MugiGameHook} from "../../src/imd/MugiIMDGameHook.sol";
import {MugiIMDAccountingFactory} from "../../src/imd/MugiIMDAccountingFactory.sol";
import {MugiIMDEngineFactory} from "../../src/imd/MugiIMDEngineFactory.sol";
import {MugiIMDCrewFactory} from "../../src/imd/MugiIMDCrewFactory.sol";
import {MugiIMDCrewToken} from "../../src/imd/MugiIMDCrewToken.sol";
import {MugiIMDLedger} from "../../src/imd/modules/MugiIMDLedger.sol";
import {MugiIMDV4Engine} from "../../src/imd/modules/MugiIMDV4Engine.sol";
import {MugiCrewToken} from "../../src/game/MugiCrewToken.sol";
import {MugiVRFAdapter} from "../../src/game/MugiVRFAdapter.sol";
import {MugiAirdrop} from "../../src/game/MugiAirdrop.sol";
import {MugiV1IMDDeploymentFactory} from "../../src/imd/MugiV1IMDDeploymentFactory.sol";

contract MugiIMDDeploymentCoordinatorStub {}

contract MugiV1IMDDeploymentFactoryTest is Test {
    address internal constant OWNER = address(0xC011EC70);
    address internal constant TEAM = address(0x7EA0);
    address internal constant COMMUNITY = address(0xC0FFEE);
    address internal constant ATTESTOR = address(0xA771);
    address internal constant ORACLE_SIGNER = address(0x0A11CE);
    address internal constant NEXT_OWNER = address(0x0B0B);
    uint256 internal constant SUPPLY = 1_000_000 ether;

    PoolManager internal manager;
    MugiIMDCrewFactory internal crewFactory;
    MugiIMDAccountingFactory internal accountingFactory;
    MugiIMDEngineFactory internal engineFactory;
    MugiV1IMDDeploymentFactory internal factory;
    MugiIMDDeploymentCoordinatorStub internal coordinator;
    bytes internal hookInitCode;
    bytes32 internal hookSalt;

    function setUp() public {
        manager = new PoolManager(address(this));
        coordinator = new MugiIMDDeploymentCoordinatorStub();
        crewFactory = new MugiIMDCrewFactory();
        accountingFactory = new MugiIMDAccountingFactory();
        engineFactory = new MugiIMDEngineFactory();
        hookInitCode = _hookInitCode(OWNER);
        factory = new MugiV1IMDDeploymentFactory(OWNER, crewFactory, keccak256(hookInitCode));
        hookSalt = _mine(factory);
    }

    function testStaticManifestEntriesMeetEthereumCodeSizeLimits() public view {
        assertLe(address(factory).code.length, 24_576);
        assertLe(address(crewFactory).code.length, 24_576);
        assertLe(type(MugiV1IMDDeploymentFactory).creationCode.length + 96, 49_152);
        assertLe(type(MugiIMDCrewFactory).creationCode.length, 49_152);
        assertLe(hookInitCode.length, 49_152);
    }

    function testConstructorCanRehearseWithoutExternalContracts() public {
        MugiV1IMDDeploymentFactory emptyChainCandidate =
            new MugiV1IMDDeploymentFactory(OWNER, MugiIMDCrewFactory(address(0x1234)), keccak256(hookInitCode));
        assertEq(emptyChainCandidate.owner(), OWNER);
        assertEq(address(emptyChainCandidate.crewFactory()), address(0x1234));
        assertEq(address(emptyChainCandidate.hook()), address(0));
        bytes32 salt = _mine(emptyChainCandidate);
        vm.prank(OWNER);
        emptyChainCandidate.deployHook(salt, hookInitCode);
        MugiV1IMDDeploymentFactory.ModuleConfiguration memory c = _configuration();
        vm.expectRevert(MugiV1IMDDeploymentFactory.InvalidConfiguration.selector);
        vm.prank(OWNER);
        emptyChainCandidate.deployModules(c);
    }

    function testHookUsesCommittedCodeAndMinedAddressAndKeepsWalletOwner() public {
        address predicted = factory.predictHook(hookSalt);
        vm.prank(OWNER);
        MugiGameHook game = factory.deployHook(hookSalt, hookInitCode);
        assertEq(address(game), predicted);
        assertEq(game.owner(), OWNER);
        assertEq(address(game.poolManager()), address(manager));
        assertEq(game.initialSupply(), SUPPLY);
        assertEq(uint160(address(game)) & 0x3fff, 0x2aec);
        assertEq(address(factory.hook()), address(game));
        assertLe(address(game).code.length, 24_576);
    }

    function testOnlyOwnerCanDeployHookOrModules() public {
        vm.expectRevert(MugiV1IMDDeploymentFactory.Unauthorized.selector);
        factory.deployHook(hookSalt, hookInitCode);
        vm.expectRevert(MugiV1IMDDeploymentFactory.Unauthorized.selector);
        factory.deployModules(_configuration());
    }

    function testChangedHookInitCodeIsRejected() public {
        bytes memory changed = bytes.concat(hookInitCode, hex"00");
        vm.expectRevert(MugiV1IMDDeploymentFactory.InvalidHookInitCode.selector);
        vm.prank(OWNER);
        factory.deployHook(hookSalt, changed);
        assertEq(address(factory.hook()), address(0));
    }

    function testCommittedHookWithDifferentOwnerRollsBack() public {
        bytes memory wrongOwnerCode = _hookInitCode(address(0xBAD));
        MugiV1IMDDeploymentFactory other = new MugiV1IMDDeploymentFactory(OWNER, crewFactory, keccak256(wrongOwnerCode));
        bytes32 salt = _mine(other);
        address predicted = other.predictHook(salt);
        vm.expectRevert(MugiV1IMDDeploymentFactory.InvalidConfiguration.selector);
        vm.prank(OWNER);
        other.deployHook(salt, wrongOwnerCode);
        assertEq(address(other.hook()), address(0));
        assertEq(predicted.code.length, 0);
    }

    function testHookCannotBeDeployedTwice() public {
        _deployHook();
        vm.expectRevert(MugiV1IMDDeploymentFactory.HookAlreadyDeployed.selector);
        vm.prank(OWNER);
        factory.deployHook(hookSalt, hookInitCode);
    }

    function testModulesRequireHookAndCannotBeDeployedTwice() public {
        MugiV1IMDDeploymentFactory.ModuleConfiguration memory c = _configuration();
        vm.expectRevert(MugiV1IMDDeploymentFactory.ModulesUnavailable.selector);
        vm.prank(OWNER);
        factory.deployModules(c);
        _deployHook();
        vm.prank(OWNER);
        factory.deployModules(c);
        vm.expectRevert(MugiV1IMDDeploymentFactory.ModulesUnavailable.selector);
        vm.prank(OWNER);
        factory.deployModules(c);
    }

    function testBadModuleConfigurationRollsBackAndCanBeRetried() public {
        MugiGameHook game = _deployHook();
        MugiV1IMDDeploymentFactory.ModuleConfiguration memory c = _configuration();
        c.vrfCallbackGasLimit = 1;
        vm.expectRevert(MugiVRFAdapter.InvalidConfiguration.selector);
        vm.prank(OWNER);
        factory.deployModules(c);
        assertFalse(factory.modulesDeployed());
        assertEq(address(factory.router()), address(0));
        address[10] memory rolledBackTokens = crewFactory.crewSet(address(game), c.seasonId);
        assertEq(rolledBackTokens[0], address(0));
        c.vrfCallbackGasLimit = 300_000;
        vm.prank(OWNER);
        factory.deployModules(c);
        assertTrue(factory.modulesDeployed());
    }

    function testAllTenTokensAndModulesBindToHookAndWalletCanConfigure() public {
        MugiGameHook game = _deployComplete();
        assertEq(game.owner(), OWNER);
        assertEq(factory.vrf().hook(), address(game));
        assertEq(factory.imdVerifier().trustedConsumer(), address(game));
        assertEq(factory.imdVerifier().owner(), OWNER);
        assertEq(address(factory.router().hook()), address(game));
        assertEq(factory.airdrop().hook(), address(game));
        assertEq(address(game.airdrop()), address(factory.airdrop()));
        assertEq(game.randomnessProvider(), address(factory.vrf()));
        assertEq(game.imdVerifier(), address(factory.imdVerifier()));
        for (uint8 crew; crew < 10; ++crew) {
            MugiCrewToken token = MugiCrewToken(factory.tokens(crew));
            assertEq(token.hook(), address(game));
            assertEq(token.characterId(), crew);
            assertEq(token.totalSupply(), 0);
            assertEq(factory.airdrop().tokens(crew), address(token));
            assertEq(game.tokens(crew), address(token));
            assertGt(address(token).code.length, 45);
            assertLe(address(token).code.length, 24_576);
        }
    }

    function testFullCrewTokensCannotReinitializeOrBeMintedByOwner() public {
        MugiGameHook game = _deployComplete();
        for (uint8 crew; crew < 10; ++crew) {
            MugiCrewToken token = MugiCrewToken(factory.tokens(crew));
            (bool initialized, bytes memory result) = address(token).call(
                abi.encodeWithSignature("initialize(string,string,uint8,address)", "Changed", "BAD", crew, address(game))
            );
            assertFalse(initialized);
            assertEq(result.length, 0, "initializer selector must be absent");
            assertEq(token.hook(), address(game));
            assertEq(token.characterId(), crew);
            vm.expectRevert(MugiCrewToken.NotHook.selector);
            vm.prank(OWNER);
            token.mint(OWNER, 1 ether);
        }
    }

    function testCrewSetPredictionAndIdempotence() public {
        MugiGameHook game = _deployHook();
        address[10] memory predicted = crewFactory.predictCrewSet(address(game), 1);
        address[10] memory first = crewFactory.deployCrewSet(address(game), 1);
        address[10] memory again = crewFactory.deployCrewSet(address(game), 1);
        for (uint8 crew; crew < 10; ++crew) {
            assertEq(predicted[crew], first[crew]);
            assertEq(again[crew], first[crew]);
        }
        vm.prank(OWNER);
        factory.deployModules(_configuration());
        assertEq(factory.tokens(0), first[0]);
    }

    function testModulesDeploymentGasBelowEthereumTransactionCap() public {
        _deployHook();
        MugiV1IMDDeploymentFactory.ModuleConfiguration memory c = _configuration();
        vm.prank(OWNER);
        uint256 beforeGas = gasleft();
        factory.deployModules(c);
        uint256 used = beforeGas - gasleft();
        emit log_named_uint("deployModules execution gas", used);
        // Includes a buffer for transaction intrinsic gas and calldata.
        assertLt(used + 100_000, 16_777_216);
    }

    function testOwnerSeedsAllTenPoolsAndReceivesPrelaunchRefundDirectly() public {
        MugiGameHook game = _deployComplete();
        vm.deal(OWNER, 10 ether);
        vm.startPrank(OWNER);
        for (uint8 crew; crew < 10; ++crew) {
            game.seedPool{value: 1 ether}(crew);
        }
        assertEq(game.seededMask(), 1023);
        assertEq(OWNER.balance, 0);
        vm.expectRevert(MugiGameHook.InvalidState.selector);
        game.setPaused(true); // Setup cannot consume a live-round pause allowance.
        game.abortPrelaunch();
        vm.stopPrank();
        assertEq(uint8(game.phase()), uint8(MugiGameHook.Phase.Aborted));
        assertApproxEqAbs(OWNER.balance, 10 ether, 20);
        assertEq(address(factory).balance, 0);
        assertEq(address(game).balance, 0);
    }

    function testConfiguredDeploymentCanLaunchPermissionlesslyAfterSevenDays() public {
        MugiGameHook game = _deployComplete();
        vm.deal(OWNER, 10 ether);
        vm.startPrank(OWNER);
        for (uint8 crew; crew < 10; ++crew) {
            game.seedPool{value: 1 ether}(crew);
        }
        vm.stopPrank();
        vm.warp(game.configuredAt() + 7 days);
        vm.prank(address(0xB0B));
        game.launch();
        assertEq(uint8(game.phase()), uint8(MugiGameHook.Phase.Live));
    }

    function testCanonicalAccountingAndEngineBindingRemainHookAuthorized() public {
        MugiGameHook game = _deployComplete();
        MugiIMDAccountingFactory.Modules memory modules = accountingFactory.deployForHook(address(game));
        MugiIMDV4Engine canonicalEngine = engineFactory.engines(address(game));
        assertEq(address(game.ledger()), address(modules.ledger));
        assertEq(address(game.budgets()), address(modules.budgets));
        assertEq(address(game.prices()), address(modules.prices));
        assertEq(address(game.engine()), address(canonicalEngine));
        assertEq(modules.ledger.hook(), address(game));
        assertEq(modules.budgets.hook(), address(game));
        assertEq(modules.prices.hook(), address(game));
        assertEq(canonicalEngine.hook(), address(game));
        assertEq(address(canonicalEngine.manager()), address(manager));
    }

    function testOutsiderCannotBindCanonicalModulesBeforeOwner() public {
        MugiGameHook game = _deployHook();
        MugiIMDAccountingFactory.Modules memory modules = accountingFactory.deployForHook(address(game));
        MugiIMDV4Engine canonicalEngine = engineFactory.deployForHook(address(game), manager);
        vm.expectRevert(MugiGameHook.Unauthorized.selector);
        game.bindAccounting(modules.ledger, modules.budgets, modules.prices, canonicalEngine);
        assertEq(address(game.ledger()), address(0));
        vm.prank(OWNER);
        game.bindAccounting(modules.ledger, modules.budgets, modules.prices, canonicalEngine);
        assertEq(address(game.engine()), address(canonicalEngine));
    }

    function testOwnerCannotBindLedgerBelongingToDifferentHook() public {
        MugiGameHook game = _deployHook();
        MugiIMDAccountingFactory.Modules memory modules = accountingFactory.deployForHook(address(game));
        MugiIMDV4Engine canonicalEngine = engineFactory.deployForHook(address(game), manager);
        MugiIMDLedger wrongLedger = new MugiIMDLedger(address(0xBEEF));
        vm.expectRevert(MugiGameHook.InvalidConfiguration.selector);
        vm.prank(OWNER);
        game.bindAccounting(wrongLedger, modules.budgets, modules.prices, canonicalEngine);
        assertEq(address(game.ledger()), address(0));
    }

    function testAccountingCannotBeReboundAfterConfiguration() public {
        MugiGameHook game = _deployComplete();
        MugiIMDAccountingFactory.Modules memory modules = accountingFactory.deployForHook(address(game));
        MugiIMDV4Engine canonicalEngine = engineFactory.engines(address(game));
        vm.expectRevert(MugiGameHook.InvalidConfiguration.selector);
        vm.prank(OWNER);
        game.bindAccounting(modules.ledger, modules.budgets, modules.prices, canonicalEngine);
        assertEq(address(game.ledger()), address(modules.ledger));
    }

    function testConfigurationRequiresAccountingBindingFirst() public {
        MugiGameHook game = _deployHook();
        MugiV1IMDDeploymentFactory.ModuleConfiguration memory c = _configuration();
        vm.prank(OWNER);
        factory.deployModules(c);
        address[10] memory crewTokens = factory.allTokens();
        MugiAirdrop drop = factory.airdrop();
        address vrf = address(factory.vrf());
        address verifier = address(factory.imdVerifier());
        vm.expectRevert(MugiGameHook.InvalidConfiguration.selector);
        vm.prank(OWNER);
        game.configure(crewTokens, drop, vrf, verifier);
        assertEq(game.tokens(0), address(0));
    }

    function testOutsiderCannotWithdrawSeededPositionFromEngine() public {
        MugiGameHook game = _deployComplete();
        vm.deal(OWNER, 1 ether);
        vm.prank(OWNER);
        game.seedPool{value: 1 ether}(0);
        MugiIMDV4Engine canonicalEngine = game.engine();
        uint128 beforeLiquidity = canonicalEngine.positionLiquidity(0);
        assertGt(beforeLiquidity, 0);
        vm.expectRevert(MugiIMDV4Engine.Unauthorized.selector);
        canonicalEngine.removeLiquidity(0, 0, 0);
        assertEq(canonicalEngine.positionLiquidity(0), beforeLiquidity);
    }

    function testOwnershipNominationDoesNotMovePrivileges() public {
        MugiGameHook game = _deployHook();
        vm.prank(OWNER);
        game.transferOwnership(NEXT_OWNER);
        assertEq(game.owner(), OWNER);
        assertEq(game.pendingOwner(), NEXT_OWNER);
        vm.expectRevert(MugiGameHook.Unauthorized.selector);
        vm.prank(NEXT_OWNER);
        game.setPaused(false);
        vm.prank(OWNER);
        game.setPaused(false);
        assertFalse(game.paused());
    }

    function testOnlyNominatedWalletCanAcceptOwnership() public {
        MugiGameHook game = _deployHook();
        vm.expectRevert(MugiGameHook.Unauthorized.selector);
        game.acceptOwnership();
        vm.prank(OWNER);
        game.transferOwnership(NEXT_OWNER);
        vm.expectRevert(MugiGameHook.Unauthorized.selector);
        vm.prank(OWNER);
        game.acceptOwnership();
        vm.expectRevert(MugiGameHook.Unauthorized.selector);
        vm.prank(address(0xBAD));
        game.acceptOwnership();
        vm.prank(NEXT_OWNER);
        game.acceptOwnership();
        assertEq(game.owner(), NEXT_OWNER);
        assertEq(game.pendingOwner(), address(0));
        vm.expectRevert(MugiGameHook.Unauthorized.selector);
        vm.prank(NEXT_OWNER);
        game.acceptOwnership();
    }

    function testOldOwnerLosesPauseAndRefundAuthorityAfterAcceptedHandover() public {
        MugiGameHook game = _deployComplete();
        vm.deal(OWNER, 1 ether);
        vm.prank(OWNER);
        game.seedPool{value: 1 ether}(0);
        vm.prank(OWNER);
        game.transferOwnership(NEXT_OWNER);
        vm.prank(NEXT_OWNER);
        game.acceptOwnership();
        vm.expectRevert(MugiGameHook.Unauthorized.selector);
        vm.prank(OWNER);
        game.setPaused(true);
        vm.expectRevert(MugiGameHook.Unauthorized.selector);
        vm.prank(OWNER);
        game.abortPrelaunch();
        vm.startPrank(NEXT_OWNER);
        game.setPaused(false);
        game.abortPrelaunch();
        vm.stopPrank();
        assertApproxEqAbs(NEXT_OWNER.balance, 1 ether, 2);
        assertEq(OWNER.balance, 0);
        assertEq(uint8(game.phase()), uint8(MugiGameHook.Phase.Aborted));
    }

    function testOwnerCanReplaceAndCancelNominationButCannotNominateZeroOrSelf() public {
        MugiGameHook game = _deployHook();
        vm.expectRevert(MugiGameHook.Unauthorized.selector);
        game.transferOwnership(NEXT_OWNER);
        vm.expectRevert(MugiGameHook.Unauthorized.selector);
        game.cancelOwnershipTransfer();
        vm.startPrank(OWNER);
        vm.expectRevert(MugiGameHook.InvalidConfiguration.selector);
        game.transferOwnership(address(0));
        vm.expectRevert(MugiGameHook.InvalidConfiguration.selector);
        game.transferOwnership(OWNER);
        game.transferOwnership(NEXT_OWNER);
        game.transferOwnership(address(0xCA11));
        vm.stopPrank();
        vm.expectRevert(MugiGameHook.Unauthorized.selector);
        vm.prank(NEXT_OWNER);
        game.acceptOwnership();
        vm.prank(OWNER);
        game.cancelOwnershipTransfer();
        assertEq(game.pendingOwner(), address(0));
        vm.expectRevert(MugiGameHook.Unauthorized.selector);
        vm.prank(address(0xCA11));
        game.acceptOwnership();
        assertEq(game.owner(), OWNER);
    }

    function testModuleDeploymentFollowsCurrentHookOwnerAfterEarlyHandover() public {
        MugiGameHook game = _deployHook();
        vm.prank(OWNER);
        game.transferOwnership(NEXT_OWNER);
        vm.prank(NEXT_OWNER);
        game.acceptOwnership();
        MugiV1IMDDeploymentFactory.ModuleConfiguration memory c = _configuration();
        c.imdVerifierOwner = NEXT_OWNER;
        vm.expectRevert(MugiV1IMDDeploymentFactory.Unauthorized.selector);
        vm.prank(OWNER);
        factory.deployModules(c);
        vm.prank(NEXT_OWNER);
        factory.deployModules(c);
        assertTrue(factory.modulesDeployed());
        assertEq(factory.owner(), OWNER); // Historical bootstrap identity is not continuing authority.
        assertEq(factory.imdVerifier().owner(), NEXT_OWNER);
        assertEq(factory.airdrop().hook(), address(game));
    }

    function testOwnershipHandoverPreservesExistingModuleAndTokenBindings() public {
        MugiGameHook game = _deployComplete();
        address ledgerBefore = address(game.ledger());
        address budgetsBefore = address(game.budgets());
        address oracleBefore = address(game.prices());
        address engineBefore = address(game.engine());
        vm.prank(OWNER);
        game.transferOwnership(NEXT_OWNER);
        vm.prank(NEXT_OWNER);
        game.acceptOwnership();
        assertEq(address(game.ledger()), ledgerBefore);
        assertEq(address(game.budgets()), budgetsBefore);
        assertEq(address(game.prices()), oracleBefore);
        assertEq(address(game.engine()), engineBefore);
        assertEq(game.ledger().hook(), address(game));
        assertEq(game.budgets().hook(), address(game));
        assertEq(game.prices().hook(), address(game));
        assertEq(game.engine().hook(), address(game));
        assertEq(factory.vrf().hook(), address(game));
        assertEq(factory.imdVerifier().trustedConsumer(), address(game));
        assertEq(factory.imdVerifier().owner(), OWNER); // Separately owned verifier requires its own handover.
        assertEq(game.teamTreasury(), TEAM);
        assertEq(game.communityTreasury(), COMMUNITY);
        for (uint8 crew; crew < 10; ++crew) assertEq(MugiCrewToken(game.tokens(crew)).hook(), address(game));
    }

    function _deployHook() internal returns (MugiGameHook game) {
        vm.prank(OWNER);
        game = factory.deployHook(hookSalt, hookInitCode);
    }

    function _deployComplete() internal returns (MugiGameHook game) {
        game = _deployHook();
        MugiIMDAccountingFactory.Modules memory modules = accountingFactory.deployForHook(address(game));
        MugiIMDV4Engine canonicalEngine = engineFactory.deployForHook(address(game), game.poolManager());
        vm.prank(OWNER);
        game.bindAccounting(modules.ledger, modules.budgets, modules.prices, canonicalEngine);
        MugiV1IMDDeploymentFactory.ModuleConfiguration memory c = _configuration();
        vm.prank(OWNER);
        factory.deployModules(c);
        address[10] memory crewTokens = factory.allTokens();
        MugiAirdrop drop = factory.airdrop();
        address vrf = address(factory.vrf());
        address verifier = address(factory.imdVerifier());
        vm.prank(OWNER);
        game.configure(crewTokens, drop, vrf, verifier);
    }

    function _configuration() internal view returns (MugiV1IMDDeploymentFactory.ModuleConfiguration memory c) {
        c.airdropAttestor = ATTESTOR;
        c.vrfCoordinator = address(coordinator);
        c.vrfKeyHash = bytes32(uint256(1));
        c.vrfSubscriptionId = 1;
        c.vrfCallbackGasLimit = 300_000;
        c.vrfNativePayment = true;
        c.imdVerifierOwner = OWNER;
        c.imdOracleSigner = ORACLE_SIGNER;
        c.imdMinimumPanel = 5;
        c.imdMinimumQuorum = 4;
        c.imdMaximumAge = 3600;
        c.seasonId = 1;
    }

    function _hookInitCode(address hookOwner) internal view returns (bytes memory) {
        return abi.encodePacked(
            type(MugiGameHook).creationCode, abi.encode(hookOwner, manager, TEAM, COMMUNITY, address(0), SUPPLY)
        );
    }

    /// @dev This loop is test-side tooling only; production deployment has no salt search.
    function _mine(MugiV1IMDDeploymentFactory deployedFactory) internal view returns (bytes32) {
        for (uint256 i; i < 1_000_000; ++i) {
            bytes32 salt = bytes32(i);
            if ((uint160(deployedFactory.predictHook(salt)) & 0x3fff) == 0x2aec) return salt;
        }
        revert("salt not found");
    }
}
