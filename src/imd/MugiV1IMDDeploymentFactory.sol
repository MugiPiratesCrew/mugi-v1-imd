// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {MugiIMDGameHook as MugiGameHook} from "./MugiIMDGameHook.sol";
import {MugiIMDCrewFactory} from "./MugiIMDCrewFactory.sol";
import {MugiIMDDeploymentAddresses} from "./libraries/MugiIMDDeploymentAddresses.sol";
import {MugiAirdrop} from "../game/MugiAirdrop.sol";
import {MugiVRFAdapter} from "../game/MugiVRFAdapter.sol";
import {MugiIMDVerifier} from "../game/MugiIMDVerifier.sol";
import {MugiIMDSwapRouter as MugiSwapRouter} from "./MugiIMDSwapRouter.sol";

/// @notice Owner-bound factory for one graph of constructor-complete applications.
/// @dev The four IMD manifest factories receive only their immutable owner at
/// construction. Child CREATE addresses are independent of hook initcode. After
/// calculating that graph, the owner supplies its exact hook hash/salt while
/// creating the router, VRF, verifier and airdrop; the hook is created last.
/// These are application-creation operations, not application initializers.
/// All nineteen descendants and these later transactions must be disclosed to
/// IMD; a four-entry registry record is not deployment of the entire game.
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
        address manager;
        address crewFactory;
        uint256 initialSupply;
    }

    struct Modules {
        address router;
        address vrf;
        address imdVerifier;
        address airdrop;
    }

    address public immutable owner;
    bytes32 public immutable hookCreationCodeHash;
    uint256 public immutable hookCreationCodeLength;
    MugiIMDCrewFactory public crewFactory;
    IPoolManager public poolManager;
    uint256 public initialSupply;
    bytes32 public hookInitCodeHash;
    bytes32 public hookSalt;
    address public plannedHook;
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
    event ModulesDeployed(address indexed futureHook, bytes32 indexed initCodeHash, bytes32 salt,
        address router, address vrf, address verifier, address airdrop, address[10] tokens);

    /// @dev No dependency calls, code checks, or child creations. Hook creation
    /// code is included only in this initcode to pin its hash, never in runtime.
    constructor(address owner_) {
        if (owner_ == address(0)) revert InvalidConfiguration();
        owner = owner_;
        hookCreationCodeHash = keccak256(type(MugiGameHook).creationCode);
        hookCreationCodeLength = type(MugiGameHook).creationCode.length;
    }

    modifier onlyOwner() {
        if (msg.sender != owner) revert Unauthorized();
        _;
    }

    function predictModules() public view returns (Modules memory result) {
        result.router = MugiIMDDeploymentAddresses.child(address(this), 1);
        result.vrf = MugiIMDDeploymentAddresses.child(address(this), 2);
        result.imdVerifier = MugiIMDDeploymentAddresses.child(address(this), 3);
        result.airdrop = MugiIMDDeploymentAddresses.child(address(this), 4);
    }

    function predictHook(bytes32 salt, bytes32 initCodeHash) public view returns (address) {
        return address(uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), address(this), salt, initCodeHash)))));
    }

    /// @notice Creates all four modules with their final future-hook binding.
    /// @dev A failed constructor reverts the whole call, including nonce changes.
    /// The commitment cannot be reset or replaced after successful creation.
    function deployModules(bytes32 salt, bytes32 initCodeHash, ModuleConfiguration calldata c) external onlyOwner {
        if (modulesDeployed) revert ModulesUnavailable();
        if (initCodeHash == bytes32(0) || c.manager == address(0) || c.crewFactory == address(0)
            || c.initialSupply < 1000 || c.initialSupply > 1e36) revert InvalidConfiguration();
        address futureHook = predictHook(salt, initCodeHash);
        if ((uint160(futureHook) & 0x3fff) != 0x2aec) revert InvalidConfiguration();
        modulesDeployed = true;
        hookSalt = salt;
        hookInitCodeHash = initCodeHash;
        plannedHook = futureHook;
        crewFactory = MugiIMDCrewFactory(c.crewFactory);
        poolManager = IPoolManager(c.manager);
        initialSupply = c.initialSupply;
        address[10] memory crewTokens = MugiIMDDeploymentAddresses.crews(c.crewFactory);
        tokens = crewTokens;
        router = new MugiSwapRouter(MugiGameHook(payable(futureHook)), IPoolManager(c.manager));
        vrf = new MugiVRFAdapter(futureHook, c.vrfCoordinator, c.vrfKeyHash,
            c.vrfSubscriptionId, c.vrfCallbackGasLimit, c.vrfNativePayment);
        imdVerifier = new MugiIMDVerifier(c.imdVerifierOwner, c.imdOracleSigner,
            futureHook, c.imdMinimumPanel, c.imdMinimumQuorum, c.imdMaximumAge);
        airdrop = new MugiAirdrop(futureHook, c.airdropAttestor, c.initialSupply, crewTokens);
        Modules memory predicted = predictModules();
        assert(address(router) == predicted.router && address(vrf) == predicted.vrf
            && address(imdVerifier) == predicted.imdVerifier && address(airdrop) == predicted.airdrop);
        emit ModulesDeployed(futureHook, initCodeHash, salt, address(router), address(vrf),
            address(imdVerifier), address(airdrop), crewTokens);
    }

    /// @notice Creates only the pinned hook implementation with committed constructor arguments.
    /// @dev No setter, arbitrary runtime, proxy or delegatecall path exists.
    function deployHook(bytes calldata initCode) external onlyOwner returns (MugiGameHook deployedHook) {
        if (!modulesDeployed) revert ModulesUnavailable();
        if (address(hook) != address(0)) revert HookAlreadyDeployed();
        if (initCode.length != hookCreationCodeLength + 14 * 32 || initCode.length > 49_152
            || keccak256(initCode) != hookInitCodeHash
            || keccak256(initCode[:hookCreationCodeLength]) != hookCreationCodeHash) revert InvalidHookInitCode();
        MugiGameHook.Configuration memory c = abi.decode(initCode[hookCreationCodeLength:], (MugiGameHook.Configuration));
        if (c.owner != owner || c.manager != address(poolManager) || c.crewFactory != address(crewFactory)
            || c.initialSupply != initialSupply || c.randomnessProvider != address(vrf)
            || c.imdVerifier != address(imdVerifier) || c.airdrop != address(airdrop)
            || crewFactory.hook() != plannedHook || c.ledger.code.length == 0 || c.engine.code.length == 0
            || c.budgets.code.length == 0 || c.prices.code.length == 0) revert InvalidConfiguration();
        bytes memory code = initCode;
        bytes32 salt = hookSalt;
        address deployed;
        assembly ("memory-safe") { deployed := create2(0, add(code, 0x20), mload(code), salt) }
        if (deployed == address(0) || deployed != plannedHook) revert DeploymentFailed();
        deployedHook = MugiGameHook(payable(deployed));
        hook = deployedHook;
        emit HookDeployed(deployed, owner, salt, hookInitCodeHash);
    }

    function allTokens() external view returns (address[10] memory) { return tokens; }
}
