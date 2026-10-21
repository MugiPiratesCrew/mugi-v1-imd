// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import {MugiCrewToken} from "./MugiCrewToken.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @notice Fixed, preminted airdrop. Social verification remains an external attestation.
contract MugiAirdrop {
    uint256 public constant AUTOMATIC_LAUNCH_REGISTRATIONS = 100;
    address public immutable hook;
    address public immutable attestor;
    uint256 public immutable initialSupply;
    address[10] public tokens;
    uint256[10] public registrations;
    uint256[10] public allocation;
    mapping(address => uint8) public crewPlusOne;
    mapping(address => bool) public claimed;
    mapping(address => bytes32) public socialIdByAccount;
    mapping(bytes32 => bool) public usedSocialId;
    uint64 public launchedAt;
    bytes32 public immutable DOMAIN_SEPARATOR;
    bytes32 public constant REGISTRATION_TYPEHASH =
        keccak256("Registration(address account,uint8 crew,bytes32 socialId,uint64 deadline)");
    bytes32 public constant CLAIM_TYPEHASH =
        keccak256("Claim(address account,uint8 crew,bytes32 socialId,uint64 deadline)");
    error InvalidAirdrop();
    event Registered(address indexed account, uint8 indexed crew, bytes32 socialId);
    event Claimed(address indexed account, uint8 indexed crew, uint256 amount);

    constructor(address hook_, address attestor_, uint256 initialSupply_, address[10] memory tokens_) {
        if (hook_ == address(0) || attestor_ == address(0) || initialSupply_ < 1000) revert InvalidAirdrop();
        for (uint8 i; i < 10; ++i) {
            if (tokens_[i] == address(0)) revert InvalidAirdrop();
            for (uint8 j; j < i; ++j) {
                if (tokens_[i] == tokens_[j]) revert InvalidAirdrop();
            }
        }
        hook = hook_;
        attestor = attestor_;
        initialSupply = initialSupply_;
        tokens = tokens_;
        DOMAIN_SEPARATOR = keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256("Mugi Airdrop"),
                keccak256("1"),
                block.chainid,
                address(this)
            )
        );
    }

    function register(uint8 crew, bytes32 socialId, uint64 deadline, bytes calldata signature) external {
        if (
            launchedAt != 0 || crew >= 10 || crewPlusOne[msg.sender] != 0 || socialId == 0 || usedSocialId[socialId]
                || block.timestamp > deadline
        ) revert InvalidAirdrop();
        bytes32 digest = MessageHashUtils.toTypedDataHash(
            DOMAIN_SEPARATOR, keccak256(abi.encode(REGISTRATION_TYPEHASH, msg.sender, crew, socialId, deadline))
        );
        if (ECDSA.recover(digest, signature) != attestor) revert InvalidAirdrop();
        crewPlusOne[msg.sender] = crew + 1;
        socialIdByAccount[msg.sender] = socialId;
        usedSocialId[socialId] = true;
        ++registrations[crew];
        emit Registered(msg.sender, crew, socialId);
    }

    function launch() external {
        if (msg.sender != hook || launchedAt != 0 || block.timestamp == 0) revert InvalidAirdrop();
        launchedAt = uint64(block.timestamp);
        for (uint8 i; i < 10; ++i) {
            uint256 count = registrations[i];
            uint256 share = count == 0 ? 0 : (initialSupply / 20) / count;
            uint256 cap = initialSupply / 1000;
            allocation[i] = share < cap ? share : cap;
        }
    }

    /// @notice Read-only automatic-launch condition used by the permissionless
    /// hook launch call: enough verified registrations or the seven-day deadline.
    function launchEligible(uint64 configuredAt) external view returns (bool) {
        if (launchedAt != 0 || configuredAt == 0) return false;
        if (block.timestamp >= configuredAt + 7 days) return true;
        uint256 total;
        for (uint8 i; i < 10; ++i) total += registrations[i];
        return total >= AUTOMATIC_LAUNCH_REGISTRATIONS;
    }

    /// @notice Retire only this contract's unclaimed allocation after the window.
    /// Holder balances are never burnable by the game or its owner.
    function retireRemaining() external {
        if (msg.sender != hook || launchedAt == 0 || block.timestamp < launchedAt + 22 hours) revert InvalidAirdrop();
        for (uint8 i; i < 10; ++i) {
            MugiCrewToken token = MugiCrewToken(tokens[i]);
            token.burn(token.balanceOf(address(this)));
        }
    }

    /// @notice The separate claim attestation confirms the required second social
    /// action. A registration signature cannot authorize a claim.
    function claim(uint64 deadline, bytes calldata signature) external {
        uint8 encoded = crewPlusOne[msg.sender];
        if (launchedAt == 0 || block.timestamp >= launchedAt + 22 hours || encoded == 0 || claimed[msg.sender]) {
            revert InvalidAirdrop();
        }
        uint8 crew = encoded - 1;
        uint256 amount = allocation[crew];
        if (amount == 0 || block.timestamp > deadline) revert InvalidAirdrop();
        bytes32 digest = MessageHashUtils.toTypedDataHash(
            DOMAIN_SEPARATOR,
            keccak256(abi.encode(CLAIM_TYPEHASH, msg.sender, crew, socialIdByAccount[msg.sender], deadline))
        );
        if (ECDSA.recover(digest, signature) != attestor) revert InvalidAirdrop();
        claimed[msg.sender] = true;
        if (!IERC20(tokens[crew]).transfer(msg.sender, amount)) revert InvalidAirdrop();
        emit Claimed(msg.sender, crew, amount);
    }
}
