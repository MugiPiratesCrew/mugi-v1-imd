// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {SignatureChecker} from "@openzeppelin/contracts/utils/cryptography/SignatureChecker.sol";
import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";

/// @notice Verifies an explicitly pinned IMD v2 bytes32 answer for one Mugi consumer.
/// @dev This is a signature/policy adapter, not an IMD requester or a trading agent. The
/// consumer MUST consume each plan hash once and bind its own round, budget and deadline.
/// Wire format checked against IMD's canonical reference on 2026-10-11:
/// https://api.imd.fun/reads/skill/oracle-consumer
/// reference digest: 631ce64ce79c3d883d4c3f388a2bd5785efb04efe39ffe1a275e3b262166e7a8
contract MugiIMDVerifier is Ownable {
    struct Attestation {
        bytes32 requestId;
        uint256 chainId;
        bytes32 questionHash;
        uint8 answerType;
        bytes answer;
        uint256 figure;
        uint64 fromBlock;
        uint64 toBlock;
        bytes32 blockHash;
        bytes32 panelJobId;
        uint16 panelSize;
        uint16 quorum;
        uint16 agreed;
        uint64 issuedAt;
        uint64 expiresAt;
    }

    struct RequestPolicy {
        bytes32 questionHash;
        bytes32 planHash;
        uint64 validUntil;
        bool active;
    }

    bytes32 public constant ATTESTATION_TYPEHASH = keccak256(
        "OracleAttestation(bytes32 requestId,uint256 chainId,bytes32 questionHash,uint8 answerType,bytes answer,uint256 figure,uint64 fromBlock,uint64 toBlock,bytes32 blockHash,bytes32 panelJobId,uint16 panelSize,uint16 quorum,uint16 agreed,uint64 issuedAt,uint64 expiresAt)"
    );
    bytes32 private constant DOMAIN_TYPEHASH =
        keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");

    address public immutable trustedConsumer;
    // Trust is fixed for this season. Governance can pin/revoke requests but
    // cannot substitute its own signer or weaken the accepted evidence policy.
    // A contract signer may itself be upgradeable; its trust remains external.
    address public immutable oracleSigner;
    uint16 public immutable minimumPanelSize;
    uint16 public immutable minimumQuorum;
    uint64 public immutable maximumAge;
    mapping(bytes32 => RequestPolicy) public requests;

    error InvalidConfiguration();
    error RequestAlreadyPinned();
    event PolicyUpdated(address indexed oracleSigner, uint16 minimumPanelSize, uint16 minimumQuorum, uint64 maximumAge);
    event RequestPinned(
        bytes32 indexed requestId, bytes32 indexed questionHash, bytes32 indexed planHash, uint64 validUntil
    );
    event RequestRevoked(bytes32 indexed requestId);

    constructor(address owner_, address signer_, address consumer_, uint16 panelSize_, uint16 quorum_, uint64 maxAge_)
        Ownable(owner_)
    {
        if (consumer_ == address(0) || signer_ == address(0) || panelSize_ < 2
            || quorum_ < 2 || quorum_ > panelSize_ || maxAge_ == 0) revert InvalidConfiguration();
        trustedConsumer = consumer_;
        oracleSigner = signer_;
        minimumPanelSize = panelSize_;
        minimumQuorum = quorum_;
        maximumAge = maxAge_;
        emit PolicyUpdated(signer_, panelSize_, quorum_, maxAge_);
    }

    /// @notice Governance pins the exact admitted request and expected canonical plan.
    /// @dev A pin is NOT authorization: a fresh signature is still mandatory. Revoked ids
    /// cannot be repinned. Pin absolute-window question hashes from the admitted request.
    function pinRequest(bytes32 requestId, bytes32 questionHash, bytes32 planHash, uint64 validUntil)
        external
        onlyOwner
    {
        if (
            requestId == bytes32(0) || questionHash == bytes32(0) || planHash == bytes32(0)
                || validUntil <= block.timestamp
        ) revert InvalidConfiguration();
        if (requests[requestId].questionHash != bytes32(0)) revert RequestAlreadyPinned();
        requests[requestId] = RequestPolicy(questionHash, planHash, validUntil, true);
        emit RequestPinned(requestId, questionHash, planHash, validUntil);
    }

    function revokeRequest(bytes32 requestId) external onlyOwner {
        requests[requestId].active = false;
        emit RequestRevoked(requestId);
    }

    /// @notice proof = abi.encode(Attestation, bytes signature).
    /// @dev Invalid ABI reverts; well-formed invalid proofs return false. This view is
    /// deliberately repeatable; replay is prevented by the consumer's plan lifecycle.
    function verify(bytes32 planHash, bytes calldata proof, address consumer) external view returns (bool) {
        if (consumer != trustedConsumer) return false;
        (Attestation memory a, bytes memory signature) = abi.decode(proof, (Attestation, bytes));
        RequestPolicy memory p = requests[a.requestId];
        if (!p.active || p.planHash != planHash || p.questionHash != a.questionHash || block.timestamp > p.validUntil) {
            return false;
        }
        if (
            a.chainId != block.chainid || a.answerType != 2 || a.answer.length != 32
                || abi.decode(a.answer, (bytes32)) != planHash
        ) return false;
        // Unlike the general IMD consumer, Mugi admits no future-issued trading approval.
        if (
            a.issuedAt > block.timestamp || a.expiresAt < block.timestamp || a.expiresAt < a.issuedAt
                || block.timestamp - a.issuedAt > maximumAge
        ) return false;
        if (
            a.panelSize < minimumPanelSize || a.quorum < minimumQuorum || a.quorum > a.panelSize || a.agreed < a.quorum
                || a.agreed > a.panelSize
        ) return false;
        if (a.fromBlock > a.toBlock || a.toBlock > block.number || a.panelJobId == bytes32(0)) return false;
        return SignatureChecker.isValidSignatureNow(oracleSigner, _digest(a), signature);
    }

    /// @notice Public digest supports independent SDK conformance checks, including other answer types.
    function attestationDigest(Attestation calldata a) external view returns (bytes32) {
        return _digest(a);
    }

    function domainSeparator() public view returns (bytes32) {
        return keccak256(
            abi.encode(DOMAIN_TYPEHASH, keccak256("IdentityMD Oracle"), keccak256("2"), block.chainid, trustedConsumer)
        );
    }

    function _digest(Attestation memory a) private view returns (bytes32) {
        bytes32 structHash = keccak256(
            bytes.concat(
                abi.encode(
                    ATTESTATION_TYPEHASH,
                    a.requestId,
                    a.chainId,
                    a.questionHash,
                    a.answerType,
                    keccak256(a.answer),
                    a.figure,
                    a.fromBlock
                ),
                abi.encode(
                    a.toBlock, a.blockHash, a.panelJobId, a.panelSize, a.quorum, a.agreed, a.issuedAt, a.expiresAt
                )
            )
        );
        return MessageHashUtils.toTypedDataHash(domainSeparator(), structHash);
    }

}
