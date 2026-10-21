// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {MugiIMDGameHook as MugiGameHook} from "./MugiIMDGameHook.sol";
import {MugiIMDCrewFactory} from "./MugiIMDCrewFactory.sol";
import {MugiAirdrop} from "../../src/game/MugiAirdrop.sol";
import {MugiVRFAdapter} from "../../src/game/MugiVRFAdapter.sol";
import {MugiIMDVerifier} from "../../src/game/MugiIMDVerifier.sol";
import {MugiIMDSwapRouter as MugiSwapRouter} from "./MugiIMDSwapRouter.sol";

/// @notice Staged deployment factory intended for an IMD contracts-only manifest.
/// @dev IMD deploys this factory and the crew factory. The owner subsequently
/// supplies the exact committed hook initcode with an offchain-mined CREATE2
/// salt, then deploys the supporting modules. The initial wallet owns the hook,
/// with two-step transfer available. Its current owner configures, seeds, aborts
/// or migrates directly.
/// This contract never owns the hook, receives LP funds or forwards admin calls.
/// Hook creation code is supplied as calldata to avoid embedding it in this
/// contract's runtime, where it would exceed the EIP-170 size limit.
contract MugiV1IMDDeploymentFactory {
    struct ModuleConfiguration {
        address airdropAttestor;
        address vrfCoordinator;
        bytes32 vrfKeyHash;
        uint256 vrfSubscriptionId;
        uint32 vrfCallbackGasLimit;
        bool vrfNativePayment;
        address imdVerifierOwner;
        address imdOracleSigner;
        uint16 imdMinimumPanel;
        uint16 imdMinimumQuorum;
        uint64 imdMaximumAge;
        uint256 seasonId;
    }

    address public immutable owner;
    MugiIMDCrewFactory public immutable crewFactory;
    bytes32 public immutable hookInitCodeHash;
    MugiGameHook public hook;
    MugiSwapRouter public router;
    MugiVRFAdapter public vrf;
    MugiIMDVerifier public imdVerifier;
    MugiAirdrop public airdrop;
    bool public modulesDeployed;
    address[10] public tokens;

    error Unauthorized();
    error InvalidConfiguration();
    error InvalidHookInitCode();
    error DeploymentFailed();
    error HookAlreadyDeployed();
    error ModulesUnavailable();

    event HookDeployed(address indexed hook, address indexed owner, bytes32 indexed salt, bytes32 initCodeHash);
    event ModulesDeployed(
        address indexed hook,
        uint256 indexed seasonId,
        address router,
        address vrf,
        address verifier,
        address airdrop,
        address[10] tokens
    );

    /// @dev Only static constructor ABI types are used in the IMD manifest.
    constructor(address owner_, MugiIMDCrewFactory crewFactory_, bytes32 hookInitCodeHash_) {
        if (owner_ == address(0) || address(crewFactory_) == address(0) || hookInitCodeHash_ == bytes32(0)) {
            revert InvalidConfiguration();
        }
        owner = owner_;
        crewFactory = crewFactory_;
        hookInitCodeHash = hookInitCodeHash_;
    }

    modifier onlyOwner() {
        if (msg.sender != owner) revert Unauthorized();
        _;
    }

    modifier onlyModuleOwner() {
        MugiGameHook currentHook = hook;
        address controller = address(currentHook) == address(0) ? owner : currentHook.owner();
        if (msg.sender != controller) revert Unauthorized();
        _;
    }

    function predictHook(bytes32 salt) public view returns (address) {
        return
            address(uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), address(this), salt, hookInitCodeHash)))));
    }

    /// @notice Deploys one hook with precisely the initcode committed at IMD deployment.
    /// @dev Call with an offchain-mined salt satisfying the V4 hook permission bits.
    function deployHook(bytes32 salt, bytes calldata initCode) external onlyOwner returns (MugiGameHook deployedHook) {
        if (address(hook) != address(0)) revert HookAlreadyDeployed();
        if (keccak256(initCode) != hookInitCodeHash || initCode.length > 49_152) revert InvalidHookInitCode();
        bytes memory code = initCode;
        address deployed;
        assembly ("memory-safe") {
            deployed := create2(0, add(code, 0x20), mload(code), salt)
        }
        if (deployed == address(0)) revert DeploymentFailed();
        deployedHook = MugiGameHook(payable(deployed));
        if (deployedHook.owner() != owner) revert InvalidConfiguration();
        hook = deployedHook;
        emit HookDeployed(deployed, owner, salt, hookInitCodeHash);
    }

    /// @notice Creates the ten crew tokens and the four immutable season modules.
    /// @dev All creations revert together if a module is misconfigured. The
    /// owner can correct the supplied configuration and retry without losing
    /// the already deployed hook. No pool capital is accepted or needed here.
    function deployModules(ModuleConfiguration calldata c) external onlyModuleOwner {
        MugiGameHook deployedHook = hook;
        if (address(deployedHook) == address(0) || modulesDeployed) revert ModulesUnavailable();
        if (address(crewFactory).code.length == 0) revert InvalidConfiguration();
        modulesDeployed = true;
        address[10] memory crewTokens = crewFactory.deployCrewSet(address(deployedHook), c.seasonId);
        router = new MugiSwapRouter(deployedHook);
        vrf = new MugiVRFAdapter(
            address(deployedHook),
            c.vrfCoordinator,
            c.vrfKeyHash,
            c.vrfSubscriptionId,
            c.vrfCallbackGasLimit,
            c.vrfNativePayment
        );
        imdVerifier = new MugiIMDVerifier(
            c.imdVerifierOwner,
            c.imdOracleSigner,
            address(deployedHook),
            c.imdMinimumPanel,
            c.imdMinimumQuorum,
            c.imdMaximumAge
        );
        airdrop = new MugiAirdrop(address(deployedHook), c.airdropAttestor, deployedHook.initialSupply(), crewTokens);
        tokens = crewTokens;
        emit ModulesDeployed(
            address(deployedHook),
            c.seasonId,
            address(router),
            address(vrf),
            address(imdVerifier),
            address(airdrop),
            crewTokens
        );
    }

    function allTokens() external view returns (address[10] memory) {
        return tokens;
    }
}
