// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @dev Wire-compatible subset of Chainlink VRF v2.5's official interface:
/// https://github.com/smartcontractkit/chainlink-brownie-contracts/blob/main/contracts/src/v0.8/vrf/dev/interfaces/IVRFCoordinatorV2Plus.sol
interface IMugiVRFCoordinator {
    struct RandomWordsRequest {
        bytes32 keyHash;
        uint256 subId;
        uint16 requestConfirmations;
        uint32 callbackGasLimit;
        uint32 numWords;
        bytes extraArgs;
    }
    function requestRandomWords(RandomWordsRequest calldata request) external returns (uint256 requestId);
}

interface IMugiRandomnessReceiver {
    function receiveRandomness(uint256 requestId, uint256 word) external;
}

/// @notice One immutable Chainlink v2.5 source for a Mugi season, with no reroll path.
/// @dev Fulfillment stores the word before attempting the small hook callback. If that
/// call fails, anyone may relay the SAME stored word. Never calls a swap or settlement.
contract MugiVRFAdapter {
    struct Request {
        uint256 word;
        bool requested;
        bool ready;
        bool delivered;
    }

    address public immutable hook;
    IMugiVRFCoordinator public immutable coordinator;
    bytes32 public immutable keyHash;
    uint256 public immutable subscriptionId;
    uint32 public immutable callbackGasLimit;
    bool public immutable nativePayment;
    // Daily rounds can wait for a deeper confirmation buffer; this is not a finality guarantee.
    uint16 public constant REQUEST_CONFIRMATIONS = 64;
    uint32 public constant NUM_WORDS = 1;
    // Official VRFV2PlusClient ExtraArgsV1 selector, followed by abi.encode(bool).
    bytes4 public constant EXTRA_ARGS_V1_TAG = bytes4(keccak256("VRF ExtraArgsV1"));
    uint256 public activeRequestId;
    bool private requesting;
    mapping(uint256 => Request) public requests;
    /// @notice First on-chain storage time, used by the hook's fixed timeout.
    /// A deferred callback never changes this time or requests a replacement word.
    mapping(uint256 => uint64) public fulfilledAt;

    error InvalidConfiguration();
    error OnlyHook();
    error OnlyCoordinator();
    error RequestPending();
    error InvalidRequest();
    error AlreadyFulfilled();
    error InvalidWords();
    error DeliveryUnavailable();
    event RandomnessRequested(uint256 indexed requestId);
    event RandomnessStored(uint256 indexed requestId, uint256 word);
    event RandomnessDelivered(uint256 indexed requestId);
    event DeliveryDeferred(uint256 indexed requestId);

    constructor(
        address hook_,
        address coordinator_,
        bytes32 keyHash_,
        uint256 subscriptionId_,
        uint32 callbackGasLimit_,
        bool nativePayment_
    ) {
        if (
            hook_.code.length == 0 || coordinator_.code.length == 0 || keyHash_ == bytes32(0) || subscriptionId_ == 0
                || callbackGasLimit_ < 200_000 || callbackGasLimit_ > 2_500_000
        ) {
            revert InvalidConfiguration();
        }
        hook = hook_;
        coordinator = IMugiVRFCoordinator(coordinator_);
        keyHash = keyHash_;
        subscriptionId = subscriptionId_;
        callbackGasLimit = callbackGasLimit_;
        nativePayment = nativePayment_;
    }

    function requestRandomness() external returns (uint256 requestId) {
        if (msg.sender != hook) revert OnlyHook();
        if (activeRequestId != 0 || requesting) revert RequestPending();
        requesting = true;
        requestId = coordinator.requestRandomWords(
            IMugiVRFCoordinator.RandomWordsRequest({
                keyHash: keyHash,
                subId: subscriptionId,
                requestConfirmations: REQUEST_CONFIRMATIONS,
                callbackGasLimit: callbackGasLimit,
                numWords: NUM_WORDS,
                extraArgs: abi.encodeWithSelector(EXTRA_ARGS_V1_TAG, nativePayment)
            })
        );
        if (requestId == 0 || requests[requestId].requested) revert InvalidRequest();
        requesting = false;
        requests[requestId].requested = true;
        activeRequestId = requestId;
        emit RandomnessRequested(requestId);
    }

    function rawFulfillRandomWords(uint256 requestId, uint256[] calldata randomWords) external {
        if (msg.sender != address(coordinator)) revert OnlyCoordinator();
        Request storage r = requests[requestId];
        if (!r.requested || requestId != activeRequestId) revert InvalidRequest();
        if (r.ready) revert AlreadyFulfilled();
        if (randomWords.length != 1) revert InvalidWords();
        r.word = randomWords[0]; // Zero is a valid VRF word.
        r.ready = true;
        fulfilledAt[requestId] = uint64(block.timestamp);
        emit RandomnessStored(requestId, randomWords[0]);
        _deliver(requestId, r);
    }

    function retryDelivery(uint256 requestId) external {
        Request storage r = requests[requestId];
        if (!r.ready || r.delivered || requestId != activeRequestId) revert DeliveryUnavailable();
        _deliver(requestId, r);
    }

    function _deliver(uint256 requestId, Request storage r) private {
        // Reserve enough callback gas to record delivery, even if the receiver exhausts
        // its allowance. The hook's callback must only store state, never settle pools.
        if (gasleft() < 70_000) {
            emit DeliveryDeferred(requestId);
            return;
        }
        uint256 deliveryGas = gasleft() - 40_000;
        r.delivered = true;
        (bool success,) =
            hook.call{gas: deliveryGas}(abi.encodeCall(IMugiRandomnessReceiver.receiveRandomness, (requestId, r.word)));
        if (success) {
            activeRequestId = 0;
            emit RandomnessDelivered(requestId);
        } else {
            r.delivered = false;
            emit DeliveryDeferred(requestId);
        }
    }
}
