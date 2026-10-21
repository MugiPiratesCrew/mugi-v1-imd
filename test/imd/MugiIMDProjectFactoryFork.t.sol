// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {MugiIMDGameHook as MugiGameHook} from "../../src/imd/MugiIMDGameHook.sol";
import {MugiCrewToken} from "../../src/game/MugiCrewToken.sol";
import {MugiIMDAccountingFactory} from "../../src/imd/MugiIMDAccountingFactory.sol";
import {MugiIMDV4Engine} from "../../src/imd/modules/MugiIMDV4Engine.sol";
import {MugiIMDEngineFactory} from "../../src/imd/MugiIMDEngineFactory.sol";
import {MugiIMDCrewFactory} from "../../src/imd/MugiIMDCrewFactory.sol";
import {MugiV1IMDDeploymentFactory} from "../../src/imd/MugiV1IMDDeploymentFactory.sol";

/// @dev Exact read/deploy subset of the already deployed IMD LaunchRegistry.
interface IMugiIMDLaunchRegistryFork {
    struct Artifact {
        bytes32 role;
        bytes32 name;
        address addr;
    }

    struct Launch {
        bytes32 kind;
        uint64 launchNumber;
        uint64 recordedAt;
        bytes32 sourceCommit;
        bytes32 manifestHash;
        bytes32 attestationHash;
        bytes32 verifierKey;
        string sourceRepoUrl;
    }

    function isRecorded(uint64 launchNumber) external view returns (bool);
    function artifactsOf(uint64 launchNumber) external view returns (Artifact[] memory);
}

/// @dev ABI copied from the existing Ethereum policy-27 ProjectFactory source.
interface IMugiIMDProjectFactoryFork {
    struct ContractsParams {
        uint64 launchNumber;
        bytes[] contractCreationCodes;
        bytes32[] contractNames;
        address[] expectedContracts;
        IMugiIMDLaunchRegistryFork.Launch record;
        uint256[] agentIds;
    }

    function deployer() external view returns (address);
    function registry() external view returns (IMugiIMDLaunchRegistryFork);
    function predictContract(uint64 launchNumber, uint256 index, bytes calldata code) external view returns (address);
    function launchContracts(ContractsParams calldata params) external returns (address[] memory);
}

/// @notice Opt-in fork proof against IMD's real factory and Uniswap's real manager.
/// @dev Only local fork state is changed. IMD's deployer is impersonated for the
/// factory transaction; this is not proof of remote agent admission, payment,
/// Explorer indexing or VRF fulfillment. No wallet key is used or transaction
/// broadcast. A missing RPC marks the test skipped rather than claiming success.
contract MugiIMDProjectFactoryForkTest is Test {
    address internal constant IMD_FACTORY = address(bytes20(hex"ff03410d0fe5fa8f7f59f743de35e333d9857120"));
    address internal constant V4_MANAGER = 0x000000000004444c5dc75cB358380D2e3dE08A90;
    address internal constant VRF_COORDINATOR = 0xD7f86b4b8Cae7D942340FF628F82735b7a20893a;
    address internal constant OWNER = address(0xC011EC70);
    address internal constant TEAM = address(0x7EA0);
    address internal constant COMMUNITY = address(0xC0FFEE);
    uint256 internal constant SUPPLY = 1_000_000 ether;

    function testMainnetFactoryRecordsFourEntriesThenChildrenSeedTenPoolsAndLaunch() public {
        string memory rpc = vm.envOr("MUGI_IMD_MAINNET_FORK_RPC", string(""));
        if (bytes(rpc).length == 0) {
            vm.skip(true);
            return;
        }
        uint256 pinnedBlock = vm.envOr("MUGI_IMD_MAINNET_FORK_BLOCK", uint256(0));
        if (pinnedBlock == 0) vm.createSelectFork(rpc);
        else vm.createSelectFork(rpc, pinnedBlock);
        assertEq(block.chainid, 1, "Ethereum mainnet fork required");
        assertGt(IMD_FACTORY.code.length, 0, "IMD factory absent at fork block");
        assertGt(V4_MANAGER.code.length, 0, "V4 manager absent at fork block");
        assertGt(VRF_COORDINATOR.code.length, 0, "VRF coordinator absent at fork block");
        emit log_named_uint("Mainnet fork block", block.number);

        IMugiIMDProjectFactoryFork imd = IMugiIMDProjectFactoryFork(IMD_FACTORY);
        IMugiIMDLaunchRegistryFork registry = imd.registry();
        bytes memory hookCode = abi.encodePacked(
            type(MugiGameHook).creationCode,
            abi.encode(OWNER, IPoolManager(V4_MANAGER), TEAM, COMMUNITY, address(0), SUPPLY)
        );
        IMugiIMDProjectFactoryFork.ContractsParams memory p = _parameters(imd, registry, hookCode);

        // A regular owner cannot skip the actual IMD deployer authorization.
        vm.expectRevert(bytes4(keccak256("NotDeployer()")));
        vm.prank(OWNER);
        imd.launchContracts(p);

        address imdDeployer = imd.deployer();
        vm.prank(imdDeployer);
        address[] memory deployed = imd.launchContracts(p);
        assertEq(deployed.length, 4);
        assertEq(deployed[0], p.expectedContracts[0]);
        assertEq(deployed[1], p.expectedContracts[1]);
        _assertArtifacts(registry, p.launchNumber, deployed);

        MugiIMDCrewFactory crews = MugiIMDCrewFactory(deployed[0]);
        MugiV1IMDDeploymentFactory deployment = MugiV1IMDDeploymentFactory(deployed[1]);
        assertEq(deployment.owner(), OWNER);
        assertEq(address(deployment.crewFactory()), address(crews));
        assertEq(deployment.hookInitCodeHash(), keccak256(hookCode));
        assertLe(deployed[0].code.length, 24_576);
        assertLe(deployed[1].code.length, 24_576);

        bytes32 salt = _mine(deployment);
        vm.prank(OWNER);
        MugiGameHook game = deployment.deployHook(salt, hookCode);
        assertEq(game.owner(), OWNER);
        assertEq(address(game.poolManager()), V4_MANAGER);
        assertEq(uint160(address(game)) & 0x3fff, 0x2aec);

        MugiIMDAccountingFactory.Modules memory modules = MugiIMDAccountingFactory(deployed[2]).deployForHook(address(game));
        MugiIMDEngineFactory engines = MugiIMDEngineFactory(deployed[3]);
        MugiIMDV4Engine engine = engines.deployForHook(address(game), game.poolManager());
        vm.prank(OWNER);
        game.bindAccounting(modules.ledger, modules.budgets, modules.prices, engine);

        // Real coordinator code is bound, but this test does not request VRF.
        // Subscription/key data below is synthetic and grants no live service.
        vm.startPrank(OWNER);
        deployment.deployModules(_configuration());
        game.configure(
            deployment.allTokens(), deployment.airdrop(), address(deployment.vrf()), address(deployment.imdVerifier())
        );
        vm.stopPrank();

        vm.deal(OWNER, 10 ether);
        vm.startPrank(OWNER);
        for (uint8 crew; crew < 10; ++crew) game.seedPool{value: 1 ether}(crew);
        vm.stopPrank();
        assertEq(game.seededMask(), 1023);
        for (uint8 crew; crew < 10; ++crew) {
            MugiCrewToken token = MugiCrewToken(deployment.tokens(crew));
            assertEq(token.hook(), address(game));
            assertEq(token.characterId(), crew);
            assertEq(token.totalSupply(), SUPPLY);
            assertGt(address(token).code.length, 45, "crew must be full code, not ERC1167 clone");
            assertLe(address(token).code.length, 24_576);
        }

        vm.warp(uint256(game.configuredAt()) + 7 days);
        vm.prank(address(0xB0B));
        game.launch();
        assertEq(uint8(game.phase()), uint8(MugiGameHook.Phase.Live));
        assertEq(deployment.airdrop().launchedAt(), block.timestamp);

        // More than eight child addresses exist, but the actual IMD registry
        // remains the four explicit manifest artifacts: no automatic indexing.
        _assertArtifacts(registry, p.launchNumber, deployed);
        emit log_named_uint("IMD recorded manifest entries", 4);
        emit log_named_uint("Full-code crew tokens deployed", 10);
        emit log_named_uint("V4 pools seeded", 10);
        emit log_named_uint("Fork-only initial LP funding", 10 ether);
    }

    function _parameters(
        IMugiIMDProjectFactoryFork imd,
        IMugiIMDLaunchRegistryFork registry,
        bytes memory hookCode
    ) private view returns (IMugiIMDProjectFactoryFork.ContractsParams memory p) {
        p.launchNumber = type(uint64).max - 1;
        while (registry.isRecorded(p.launchNumber)) --p.launchNumber;
        p.contractCreationCodes = new bytes[](4);
        p.contractNames = new bytes32[](4);
        p.expectedContracts = new address[](4);
        p.contractCreationCodes[0] = type(MugiIMDCrewFactory).creationCode;
        p.expectedContracts[0] = imd.predictContract(p.launchNumber, 0, p.contractCreationCodes[0]);
        p.contractCreationCodes[1] = abi.encodePacked(
            type(MugiV1IMDDeploymentFactory).creationCode,
            abi.encode(OWNER, MugiIMDCrewFactory(p.expectedContracts[0]), keccak256(hookCode))
        );
        p.expectedContracts[1] = imd.predictContract(p.launchNumber, 1, p.contractCreationCodes[1]);
        p.contractCreationCodes[2] = type(MugiIMDAccountingFactory).creationCode;
        p.contractCreationCodes[3] = type(MugiIMDEngineFactory).creationCode;
        p.expectedContracts[2] = imd.predictContract(p.launchNumber, 2, p.contractCreationCodes[2]);
        p.expectedContracts[3] = imd.predictContract(p.launchNumber, 3, p.contractCreationCodes[3]);
        p.contractNames[2] = bytes32("MugiIMDAccountingFactory");
        p.contractNames[3] = bytes32("MugiIMDEngineFactory");
        p.contractNames[0] = bytes32("MugiIMDCrewFactory");
        p.contractNames[1] = bytes32("MugiV1IMDDeploymentFactory");
        p.record = IMugiIMDLaunchRegistryFork.Launch({
            kind: bytes32("evm_contracts"),
            launchNumber: p.launchNumber,
            recordedAt: 0,
            sourceCommit: keccak256("FORK ONLY: no published source commitment"),
            manifestHash: keccak256("FORK ONLY: four-entry manifest"),
            attestationHash: keccak256("FORK ONLY: no IMD remote attestation"),
            verifierKey: bytes32(0),
            sourceRepoUrl: "local-fork-only"
        });
        p.agentIds = new uint256[](0);
    }

    function _assertArtifacts(
        IMugiIMDLaunchRegistryFork registry,
        uint64 launchNumber,
        address[] memory deployed
    ) private view {
        IMugiIMDLaunchRegistryFork.Artifact[] memory artifacts = registry.artifactsOf(launchNumber);
        assertEq(artifacts.length, 4);
        assertEq(artifacts[0].addr, deployed[0]);
        assertEq(artifacts[1].addr, deployed[1]);
        assertEq(artifacts[2].addr, deployed[2]);
        assertEq(artifacts[3].addr, deployed[3]);
        assertEq(artifacts[0].name, bytes32("MugiIMDCrewFactory"));
        assertEq(artifacts[1].name, bytes32("MugiV1IMDDeploymentFactory"));
    }

    function _mine(MugiV1IMDDeploymentFactory deployment) private view returns (bytes32 salt) {
        bytes32 initHash = deployment.hookInitCodeHash();
        for (uint256 nonce; nonce < 1_000_000; ++nonce) {
            salt = bytes32(nonce);
            address predicted = address(
                uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), address(deployment), salt, initHash))))
            );
            if ((uint160(predicted) & 0x3fff) == 0x2aec) return salt;
        }
        revert("hook salt not found");
    }

    function _configuration()
        private
        pure
        returns (MugiV1IMDDeploymentFactory.ModuleConfiguration memory c)
    {
        c.airdropAttestor = address(0xA771);
        c.vrfCoordinator = VRF_COORDINATOR;
        c.vrfKeyHash = bytes32(uint256(1));
        c.vrfSubscriptionId = 1;
        c.vrfCallbackGasLimit = 300_000;
        c.vrfNativePayment = true;
        c.imdVerifierOwner = OWNER;
        c.imdOracleSigner = address(0x0A11CE);
        c.imdMinimumPanel = 5;
        c.imdMinimumQuorum = 4;
        c.imdMaximumAge = 1 hours;
        c.seasonId = 1;
    }
}
