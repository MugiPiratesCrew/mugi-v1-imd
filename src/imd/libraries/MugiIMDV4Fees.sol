// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta, toBeforeSwapDelta} from "v4-core/src/types/BeforeSwapDelta.sol";
import {FullMath} from "v4-core/src/libraries/FullMath.sol";
/// @notice Inlined fee math; there are no external library calls.
library MugiIMDV4Fees {
    uint256 private constant BPS = 10_000;
    uint256 private constant GAME_FEE_BPS = 200;
    error InvalidAmount();
    error UnexpectedDelta();
    error EthSpecifiedPartialFill();
    /// @notice Charges the ETH side when it is specified. For exact output, amountSpecified is net ETH.
    function beforeSwapFee(IPoolManager.SwapParams memory params)
        internal
        pure
        returns (BeforeSwapDelta returnDelta, uint256 fee)
    {
        if (params.amountSpecified == 0 || params.amountSpecified == type(int256).min) revert InvalidAmount();
        bool exactInput = params.amountSpecified < 0;
        if (exactInput != params.zeroForOne) return (BeforeSwapDelta.wrap(0), 0);
        uint256 specified = uint256(exactInput ? -params.amountSpecified : params.amountSpecified);
        if (specified > uint256(uint128(type(int128).max))) revert InvalidAmount();
        fee = exactInput
            ? FullMath.mulDiv(specified, GAME_FEE_BPS, BPS)
            : FullMath.mulDivRoundingUp(specified, GAME_FEE_BPS, BPS - GAME_FEE_BPS);
        if (
            fee > uint256(uint128(type(int128).max))
                || (!exactInput && specified + fee > uint256(uint128(type(int128).max)))
        ) {
            revert InvalidAmount();
        }
        returnDelta = toBeforeSwapDelta(int128(uint128(fee)), 0);
    }

    /// @notice Charges actual ETH when unspecified; validates full execution when ETH was specified.
    function afterSwapFee(IPoolManager.SwapParams memory params, BalanceDelta delta)
        internal
        pure
        returns (int128 returnDelta, uint256 fee)
    {
        bool exactInput = params.amountSpecified < 0;
        if (exactInput == params.zeroForOne) {
            (, uint256 upfrontFee) = beforeSwapFee(params);
            int256 expected = params.amountSpecified + int256(upfrontFee);
            if (int256(delta.amount0()) != expected) revert EthSpecifiedPartialFill();
            return (0, 0);
        }
        int128 ethDelta = delta.amount0();
        if (params.zeroForOne) {
            // Exact token output: gross up ETH input so fee is 2% of the total paid.
            if (ethDelta > 0) revert UnexpectedDelta();
            fee = FullMath.mulDivRoundingUp(uint256(-int256(ethDelta)), GAME_FEE_BPS, BPS - GAME_FEE_BPS);
        } else {
            // Exact token input: withhold 2% of gross ETH output.
            if (ethDelta < 0) revert UnexpectedDelta();
            fee = FullMath.mulDiv(uint256(int256(ethDelta)), GAME_FEE_BPS, BPS);
        }
        if (fee > uint256(uint128(type(int128).max))) revert InvalidAmount();
        returnDelta = int128(uint128(fee));
    }

}
