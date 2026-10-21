// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {MugiIMDGameHook as MugiGameHook} from "../../../src/imd/MugiIMDGameHook.sol";
import {MugiCrewToken} from "../../../src/game/MugiCrewToken.sol";
import {MugiIMDCrewFactory} from "../../../src/imd/MugiIMDCrewFactory.sol";
import {MugiIMDAccountingFactory} from "../../../src/imd/MugiIMDAccountingFactory.sol";
import {MugiIMDEngineFactory} from "../../../src/imd/MugiIMDEngineFactory.sol";
import {MugiIMDLedger} from "../../../src/imd/modules/MugiIMDLedger.sol";
import {MugiV1IMDDeploymentFactory} from "../../../src/imd/MugiV1IMDDeploymentFactory.sol";

/// @dev Real CREATE/CREATE2 deployment fixture. No vm.etch and no production setters.
abstract contract MugiIMDDeploymentFixture is Test {
    address internal constant OWNER = address(0xC011EC70);
    address internal constant TEAM = address(0x7EA0);
    address internal constant COMMUNITY = address(0xC0FFEE);
    uint256 internal constant SUPPLY = 1_000_000 ether;
    IPoolManager internal manager;
    address internal coordinator = address(0xCAFE);
    MugiIMDCrewFactory internal crewFactory;
    MugiIMDAccountingFactory internal accountingFactory;
    MugiIMDEngineFactory internal engineFactory;
    MugiV1IMDDeploymentFactory internal factory;

    function _newFactories() internal {
        crewFactory = new MugiIMDCrewFactory(OWNER);
        accountingFactory = new MugiIMDAccountingFactory(OWNER);
        engineFactory = new MugiIMDEngineFactory(OWNER);
        factory = new MugiV1IMDDeploymentFactory(OWNER);
    }

    function _hookConfiguration() internal view returns (MugiGameHook.Configuration memory c) {
        MugiIMDAccountingFactory.Modules memory accounting = accountingFactory.predictModules();
        MugiV1IMDDeploymentFactory.Modules memory modules = factory.predictModules();
        c = MugiGameHook.Configuration({
            owner: OWNER, manager: address(manager), team: TEAM, community: COMMUNITY,
            v2MigrationTarget: address(0), initialSupply: SUPPLY,
            ledger: address(accounting.ledger), engine: engineFactory.predictEngine(),
            budgets: address(accounting.budgets), prices: address(accounting.prices),
            randomnessProvider: modules.vrf, imdVerifier: modules.imdVerifier,
            airdrop: modules.airdrop, crewFactory: address(crewFactory)
        });
    }

    function _hookCode(MugiGameHook.Configuration memory c) internal pure returns (bytes memory) {
        return abi.encodePacked(type(MugiGameHook).creationCode, abi.encode(c));
    }

    function _mine(bytes32 hash) internal view returns (bytes32 salt) {
        for (uint256 nonce; nonce < 1_000_000; ++nonce) {
            salt = bytes32(nonce);
            if ((uint160(factory.predictHook(salt, hash)) & 0x3fff) == 0x2aec) return salt;
        }
        revert("hook salt not found");
    }

    function _moduleConfiguration() internal view returns (MugiV1IMDDeploymentFactory.ModuleConfiguration memory c) {
        c.airdropAttestor = address(0xA771);
        c.vrfCoordinator = coordinator;
        c.vrfKeyHash = bytes32(uint256(1));
        c.vrfSubscriptionId = 1;
        c.vrfCallbackGasLimit = 300_000;
        c.vrfNativePayment = true;
        c.imdVerifierOwner = OWNER;
        c.imdOracleSigner = address(0xA11CE);
        c.imdMinimumPanel = 5;
        c.imdMinimumQuorum = 4;
        c.imdMaximumAge = 1 hours;
        c.manager = address(manager);
        c.crewFactory = address(crewFactory);
        c.initialSupply = SUPPLY;
    }

    function _ledgerConfiguration(address futureHook) internal view returns (MugiIMDLedger.Configuration memory c) {
        address[10] memory t = crewFactory.predictCrewSet();
        c = MugiIMDLedger.Configuration({
            hook: futureHook,
            token0: t[0], token1: t[1], token2: t[2], token3: t[3], token4: t[4],
            token5: t[5], token6: t[6], token7: t[7], token8: t[8], token9: t[9],
            airdrop: factory.predictModules().airdrop, engine: engineFactory.predictEngine(),
            team: TEAM, community: COMMUNITY, manager: address(manager)
        });
    }

    function _deployBeforeHook(bytes memory code, bytes32 salt) internal returns (address futureHook) {
        futureHook = factory.predictHook(salt, keccak256(code));
        assertEq(futureHook.code.length, 0);
        vm.startPrank(OWNER);
        factory.deployModules(salt, keccak256(code), _moduleConfiguration());
        crewFactory.deployCrewSet(futureHook, SUPPLY);
        engineFactory.deployForHook(futureHook, manager);
        accountingFactory.deployForHook(_ledgerConfiguration(futureHook));
        vm.stopPrank();
        assertEq(futureHook.code.length, 0, "modules must be complete before hook creation");
    }

    function _deployGraph() internal returns (MugiGameHook game) {
        bytes memory code = _hookCode(_hookConfiguration());
        bytes32 salt = _mine(keccak256(code));
        address futureHook = _deployBeforeHook(code, salt);
        vm.prank(OWNER);
        game = factory.deployHook(code);
        assertEq(address(game), futureHook);
        _assertBindings(game);
    }

    function _assertBindings(MugiGameHook game) internal view {
        assertEq(game.owner(), OWNER);
        assertEq(address(game.poolManager()), address(manager));
        assertEq(uint160(address(game)) & 0x3fff, 0x2aec);
        assertEq(game.ledger().hook(), address(game));
        assertEq(game.budgets().hook(), address(game));
        assertEq(game.prices().hook(), address(game));
        assertEq(game.engine().hook(), address(game));
        assertEq(address(game.engine().manager()), address(manager));
        assertEq(game.randomnessProvider(), address(factory.vrf()));
        assertEq(factory.vrf().hook(), address(game));
        assertEq(factory.imdVerifier().trustedConsumer(), address(game));
        assertEq(address(factory.router().hook()), address(game));
        assertEq(address(factory.router().poolManager()), address(manager));
        assertEq(factory.airdrop().hook(), address(game));
        address[10] memory predicted = crewFactory.predictCrewSet();
        for (uint8 crew; crew < 10; ++crew) {
            MugiCrewToken token = MugiCrewToken(game.tokens(crew));
            assertEq(address(token), predicted[crew]);
            assertEq(factory.tokens(crew), predicted[crew]);
            assertEq(crewFactory.tokens(crew), predicted[crew]);
            assertEq(factory.airdrop().tokens(crew), predicted[crew]);
            assertEq(token.hook(), address(game));
            assertEq(token.characterId(), crew);
            assertEq(token.balanceOf(address(game)), token.reserveCap());
            assertEq(game.unreleasedReserve(crew), token.reserveCap());
            assertEq(game.ledger().eligibleSupply(crew), 0);
            assertLe(address(token).code.length, 24_576);
            assertGt(address(token).code.length, 45, "full code token required");
        }
    }

    function _seedAndLaunch(MugiGameHook game) internal {
        vm.deal(OWNER, 20 ether);
        vm.startPrank(OWNER);
        for (uint8 crew; crew < 10; ++crew) game.seedPool{value: 1 ether}(crew);
        vm.stopPrank();
        assertEq(game.seededMask(), 1023);
        vm.warp(uint256(game.configuredAt()) + 7 days);
        vm.prank(address(0xB0B));
        game.launch();
        assertEq(uint8(game.phase()), uint8(MugiGameHook.Phase.Live));
        assertEq(factory.airdrop().launchedAt(), block.timestamp);
    }
}
