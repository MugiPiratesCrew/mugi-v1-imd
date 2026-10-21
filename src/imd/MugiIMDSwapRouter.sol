// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {TransientStateLibrary} from "v4-core/src/libraries/TransientStateLibrary.sol";
import {MugiIMDGameHook as MugiGameHook} from "./MugiIMDGameHook.sol";

/// @notice Exact-input player trades through this season's official native-ETH pools.
/// @dev Ordinary swaps pay both the pool LP fee and the hook's game fee. This router
/// has no fee exemption, operator authority, custody, configurable recipient or owner.
contract MugiIMDSwapRouter is IUnlockCallback {
    using SafeERC20 for IERC20;
    using TransientStateLibrary for IPoolManager;

    MugiGameHook public immutable hook;
    IPoolManager public immutable poolManager;
    bool private entered;
    bytes32 private expectedCallback;

    struct Trade {
        address account;
        uint8 crew;
        bool buy;
        uint256 input;
        uint256 minimumOutput;
    }

    error InvalidConfiguration();
    error InvalidAmount();
    error InvalidCrew();
    error DeadlineExpired();
    error UnauthorizedCallback();
    error ReentrantCall();
    error UnexpectedDelta();
    error InsufficientOutput();
    error RefundFailed();

    event Swap(address indexed account, uint8 indexed crew, bool buy, uint256 input, uint256 output);

    constructor(MugiGameHook hook_, IPoolManager manager) {
        if (address(hook_) == address(0) || address(manager) == address(0)) revert InvalidConfiguration();
        hook = hook_;
        poolManager = manager;
    }

    modifier guarded() {
        if (entered || poolManager.isUnlocked()) revert ReentrantCall();
        entered = true;
        _;
        entered = false;
    }

    /// @param minTokens Minimum net tokens received after pool and game fees.
    function buy(uint8 crew, uint256 minTokens, uint64 deadline) external payable guarded returns (uint256 tokensOut) {
        _validate(crew, msg.value, deadline);
        uint256 spent;
        (spent, tokensOut) = _trade(Trade(msg.sender, crew, true, msg.value, minTokens));
        // The current hook rejects partially filled ETH-input swaps. Account only
        // for this call's value so forced ETH can never subsidize a different user.
        if (spent < msg.value) {
            (bool refunded,) = payable(msg.sender).call{value: msg.value - spent}("");
            if (!refunded) revert RefundFailed();
        }
        emit Swap(msg.sender, crew, true, spent, tokensOut);
    }

    /// @param tokenInput Maximum token input; only the actual filled input is pulled.
    /// @param minEth Minimum native ETH received after pool and game fees.
    function sell(uint8 crew, uint256 tokenInput, uint256 minEth, uint64 deadline)
        external guarded returns (uint256 ethOut)
    {
        _validate(crew, tokenInput, deadline);
        uint256 spent;
        (spent, ethOut) = _trade(Trade(msg.sender, crew, false, tokenInput, minEth));
        emit Swap(msg.sender, crew, false, spent, ethOut);
    }

    function _validate(uint8 crew, uint256 input, uint64 deadline) private view {
        if (block.timestamp > deadline) revert DeadlineExpired();
        if (crew >= 10) revert InvalidCrew();
        if (input == 0 || input > uint256(uint128(type(int128).max))) revert InvalidAmount();
    }

    function _trade(Trade memory trade) private returns (uint256 spent, uint256 output) {
        bytes memory data = abi.encode(trade);
        expectedCallback = keccak256(data);
        (spent, output) = abi.decode(poolManager.unlock(data), (uint256, uint256));
        if (expectedCallback != bytes32(0)) revert UnauthorizedCallback();
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        if (msg.sender != address(poolManager) || !entered || expectedCallback == bytes32(0)
            || keccak256(data) != expectedCallback) revert UnauthorizedCallback();
        expectedCallback = bytes32(0);
        Trade memory trade = abi.decode(data, (Trade));
        // The caller cannot supply a pool, token, hook, manager or payment recipient.
        PoolKey memory key = hook.poolKey(trade.crew);
        if (Currency.unwrap(key.currency0) != address(0) || Currency.unwrap(key.currency1) != hook.tokens(trade.crew)
            || address(key.hooks) != address(hook)) revert InvalidConfiguration();
        BalanceDelta delta = poolManager.swap(key, IPoolManager.SwapParams({
            zeroForOne: trade.buy,
            amountSpecified: -int256(trade.input),
            sqrtPriceLimitX96: trade.buy ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
        }), bytes(""));
        int128 inputDelta = trade.buy ? delta.amount0() : delta.amount1();
        int128 outputDelta = trade.buy ? delta.amount1() : delta.amount0();
        if (inputDelta >= 0 || outputDelta <= 0) revert UnexpectedDelta();
        uint256 spent = uint256(-int256(inputDelta));
        uint256 output = uint256(int256(outputDelta));
        if (spent > trade.input) revert UnexpectedDelta();
        if (output < trade.minimumOutput) revert InsufficientOutput();
        if (trade.buy) {
            // Reset any previous ERC20 sync before a native settlement.
            poolManager.sync(key.currency0);
            if (poolManager.settle{value: spent}() != spent) revert UnexpectedDelta();
            poolManager.take(key.currency1, trade.account, output);
        } else {
            poolManager.sync(key.currency1);
            IERC20(Currency.unwrap(key.currency1)).safeTransferFrom(trade.account, address(poolManager), spent);
            if (poolManager.settle() != spent) revert UnexpectedDelta();
            poolManager.take(key.currency0, trade.account, output);
        }
        return abi.encode(spent, output);
    }
}
