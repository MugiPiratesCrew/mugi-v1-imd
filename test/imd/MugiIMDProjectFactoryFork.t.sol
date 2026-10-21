// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {MugiIMDDeploymentFixture} from "./helpers/MugiIMDDeploymentFixture.sol";
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

/// @notice Opt-in local-fork proof of the actual four-entry IMD factory call.
/// @dev The registry records factories only; nineteen separately created full-code
/// descendants are fully constructor-configured before the hook is created last.
/// No public transaction, paid IMD request, or explorer verification occurs here.
contract MugiIMDProjectFactoryForkTest is MugiIMDDeploymentFixture {
    address internal constant IMD_FACTORY = address(bytes20(hex"ff03410d0fe5fa8f7f59f743de35e333d9857120"));
    address internal constant V4_MANAGER = 0x000000000004444c5dc75cB358380D2e3dE08A90;
    address internal constant VRF_COORDINATOR = 0xD7f86b4b8Cae7D942340FF628F82735b7a20893a;

    function testMainnetFactoryRecordsFourEntriesThenConstructorCompleteGraphSeedsTenPools() public {
        string memory rpc = vm.envOr("MUGI_IMD_MAINNET_FORK_RPC", string(""));
        if (bytes(rpc).length == 0) { vm.skip(true); return; }
        uint256 pinnedBlock = vm.envOr("MUGI_IMD_MAINNET_FORK_BLOCK", uint256(0));
        if (pinnedBlock == 0) vm.createSelectFork(rpc);
        else vm.createSelectFork(rpc, pinnedBlock);
        assertEq(block.chainid, 1);
        assertGt(IMD_FACTORY.code.length, 0);
        assertGt(V4_MANAGER.code.length, 0);
        assertGt(VRF_COORDINATOR.code.length, 0);
        emit log_named_uint("Mainnet fork block", block.number);
        manager = IPoolManager(V4_MANAGER);
        coordinator = VRF_COORDINATOR;

        IMugiIMDProjectFactoryFork imd = IMugiIMDProjectFactoryFork(IMD_FACTORY);
        IMugiIMDLaunchRegistryFork registry = imd.registry();
        IMugiIMDProjectFactoryFork.ContractsParams memory p = _parameters(imd, registry);
        vm.expectRevert(bytes4(keccak256("NotDeployer()")));
        vm.prank(OWNER);
        imd.launchContracts(p);
        address imdDeployer = imd.deployer();
        uint256 start = gasleft();
        vm.prank(imdDeployer);
        address[] memory deployed = imd.launchContracts(p);
        uint256 execution = start - gasleft();
        emit log_named_uint("IMD factory batch execution gas", execution);
        assertLt(execution + 21_000 + 16 * abi.encode(p).length, 16_777_216);
        assertEq(deployed.length, 4);
        for (uint256 i; i < 4; ++i) {
            assertEq(deployed[i], p.expectedContracts[i]);
            assertLe(deployed[i].code.length, 24_576);
        }
        crewFactory = MugiIMDCrewFactory(deployed[0]);
        factory = MugiV1IMDDeploymentFactory(deployed[1]);
        accountingFactory = MugiIMDAccountingFactory(deployed[2]);
        engineFactory = MugiIMDEngineFactory(deployed[3]);
        MugiGameHook game = _deployGraph();
        _seedAndLaunch(game);
        IMugiIMDLaunchRegistryFork.Artifact[] memory artifacts = registry.artifactsOf(p.launchNumber);
        assertEq(artifacts.length, 4);
        for (uint256 i; i < 4; ++i) {
            assertEq(artifacts[i].addr, deployed[i]);
            assertEq(artifacts[i].name, p.contractNames[i]);
        }
        emit log_named_uint("Manifest factories", 4);
        emit log_named_uint("Disclosed full-code descendants", 19);
        emit log_named_uint("Official pools seeded", 10);
    }

    function _parameters(IMugiIMDProjectFactoryFork imd, IMugiIMDLaunchRegistryFork registry)
        private view returns (IMugiIMDProjectFactoryFork.ContractsParams memory p)
    {
        p.launchNumber = type(uint64).max - 1;
        while (registry.isRecorded(p.launchNumber)) --p.launchNumber;
        p.contractCreationCodes = new bytes[](4);
        p.contractNames = new bytes32[](4);
        p.expectedContracts = new address[](4);
        p.contractCreationCodes[0] = abi.encodePacked(type(MugiIMDCrewFactory).creationCode, abi.encode(OWNER));
        p.contractCreationCodes[1] = abi.encodePacked(type(MugiV1IMDDeploymentFactory).creationCode, abi.encode(OWNER));
        p.contractCreationCodes[2] = abi.encodePacked(type(MugiIMDAccountingFactory).creationCode, abi.encode(OWNER));
        p.contractCreationCodes[3] = abi.encodePacked(type(MugiIMDEngineFactory).creationCode, abi.encode(OWNER));
        p.contractNames[0] = bytes32("MugiIMDCrewFactory");
        p.contractNames[1] = bytes32("MugiV1IMDDeploymentFactory");
        p.contractNames[2] = bytes32("MugiIMDAccountingFactory");
        p.contractNames[3] = bytes32("MugiIMDEngineFactory");
        for (uint256 i; i < 4; ++i) {
            assertLe(p.contractCreationCodes[i].length, 49_152);
            p.expectedContracts[i] = imd.predictContract(p.launchNumber, i, p.contractCreationCodes[i]);
        }
        p.record = IMugiIMDLaunchRegistryFork.Launch({
            kind: bytes32("evm_contracts"), launchNumber: p.launchNumber, recordedAt: 0,
            sourceCommit: keccak256("FORK ONLY: no published source commitment"),
            manifestHash: keccak256("FORK ONLY: disclosed four-entry constructor-factory manifest"),
            attestationHash: keccak256("FORK ONLY: no remote IMD attestation"), verifierKey: bytes32(0),
            sourceRepoUrl: "local-fork-only"
        });
        p.agentIds = new uint256[](0);
    }
}
