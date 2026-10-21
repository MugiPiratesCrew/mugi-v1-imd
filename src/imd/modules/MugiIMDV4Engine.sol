// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta} from "v4-core/src/types/BeforeSwapDelta.sol";
import {MugiIMDV4Fees} from "../libraries/MugiIMDV4Fees.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {SqrtPriceMath} from "v4-core/src/libraries/SqrtPriceMath.sol";
import {FullMath} from "v4-core/src/libraries/FullMath.sol";
import {FixedPoint96} from "v4-core/src/libraries/FixedPoint96.sol";
import {Pool as V4Pool} from "v4-core/src/libraries/Pool.sol";

/// @notice Immutable CALL-based V4 execution module. LP positions belong to this module.
/// @dev Only the bound hook may mutate positions. Every payout goes directly to the hook;
/// inputs are prefunded per call and unused inputs are returned without spending prior balances.
contract MugiIMDV4Engine {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    uint8 private constant CREW_COUNT = 10;

    struct Pool {
        PoolKey key;
        int24 tickLower;
        int24 tickUpper;
        uint128 liquidity;
        bool registered;
    }

    struct State {
        mapping(uint8 => Pool) pools;
        mapping(bytes32 => uint8) crewPlusOneByPool;
        mapping(address => bool) registeredToken;
        bytes32 pendingUnlock;
        bool unlocking;
    }

    /// @dev Principal values are unsigned: spent for additions, received for removals.
    /// Fees are always received and must be booked independently even if netted against an addition.
    struct LiquidityResult {
        uint128 liquidity;
        uint256 ethPrincipal;
        uint256 tokenPrincipal;
        uint256 ethFees;
        uint256 tokenFees;
    }

    enum Operation {
        Add,
        Collect,
        Remove,
        Buy
    }

    struct Action {
        Operation operation;
        uint8 crew;
        uint128 liquidity;
        uint256 amount0;
        uint256 amount1;
        uint160 sqrtPriceLimitX96;
    }

    error Unauthorized();
    error InvalidHook();
    error EthTransferFailed();
    error InvalidManager();
    error InvalidPool();
    error UnknownPool();
    error InvalidAmount();
    error PriceOutsideRange();
    error SlippageExceeded();
    error UnexpectedDelta();
    error UnauthorizedCallback();
    error UnlockInProgress();
    error UnlockNotConsumed();
    error TokenTransferFailed();

    address public immutable hook;
    IPoolManager public immutable manager;
    State private self;
    bool private operating;

    constructor(address hook_, IPoolManager manager_) {
        if (hook_ == address(0)) revert InvalidHook();
        if (address(manager_) == address(0)) revert InvalidManager();
        hook = hook_;
        manager = manager_;
    }

    modifier onlyHook() {
        if (msg.sender != hook) revert Unauthorized();
        if (operating) revert UnlockInProgress();
        operating = true;
        _;
        operating = false;
    }

    function registerPool(
        uint8 crew,
        address token,
        uint24 lpFee,
        int24 tickSpacing,
        uint160 sqrtPriceX96
    ) external onlyHook returns (PoolId id) {
        return _registerPool(crew, token, lpFee, tickSpacing, sqrtPriceX96);
    }

    /// @notice Initializes the canonical 0.3% full-range pool and calculates the seed position.
    /// @dev Same rounding and token-cap adjustment as the original hook's seedPool path.
    function registerInitialPool(uint8 crew, address token, uint256 lpTokens, uint256 ethAmount)
        external
        onlyHook
        returns (uint128 liquidity)
    {
        if (lpTokens == 0 || ethAmount == 0) revert InvalidAmount();
        uint256 ratioX192 = FullMath.mulDiv(lpTokens, uint256(1) << 192, ethAmount);
        uint256 root = Math.sqrt(ratioX192);
        if (root > type(uint160).max) revert InvalidPool();
        _registerPool(crew, token, 3000, 60, uint160(root));
        uint256 requiredTokens;
        (liquidity,, requiredTokens) = quoteLiquidityForEth(crew, ethAmount);
        if (requiredTokens > lpTokens) liquidity = uint128(FullMath.mulDiv(liquidity, lpTokens, requiredTokens));
    }

    function _registerPool(
        uint8 crew,
        address token,
        uint24 lpFee,
        int24 tickSpacing,
        uint160 sqrtPriceX96
    ) private returns (PoolId id) {
        if (
            crew >= CREW_COUNT || token.code.length == 0 || self.pools[crew].registered || self.registeredToken[token]
                || lpFee >= 1_000_000 || tickSpacing <= 0 || tickSpacing > type(int16).max
                || address(manager) == address(0)
        ) revert InvalidPool();
        Pool storage pool = self.pools[crew];
        pool.key = PoolKey(Currency.wrap(address(0)), Currency.wrap(token), lpFee, tickSpacing, IHooks(hook));
        pool.tickLower = TickMath.minUsableTick(tickSpacing);
        pool.tickUpper = TickMath.maxUsableTick(tickSpacing);
        if (
            sqrtPriceX96 <= TickMath.getSqrtPriceAtTick(pool.tickLower)
                || sqrtPriceX96 >= TickMath.getSqrtPriceAtTick(pool.tickUpper)
        ) revert PriceOutsideRange();
        pool.registered = true;
        self.registeredToken[token] = true;
        id = pool.key.toId();
        self.crewPlusOneByPool[PoolId.unwrap(id)] = crew + 1;
        // Hook callbacks authenticate this module as the only allowed LP operator.
        manager.initialize(pool.key, sqrtPriceX96);
    }

    function poolKey(uint8 crew) public view returns (PoolKey memory) {
        return _pool(crew).key;
    }

    function poolId(uint8 crew) public view returns (PoolId) {
        return _pool(crew).key.toId();
    }

    /// @notice Validates the complete key, including currencies, fee, spacing and hook address.
    function crewForPool(PoolKey memory key) public view returns (uint8 crew) {
        uint8 encoded = self.crewPlusOneByPool[PoolId.unwrap(key.toId())];
        if (encoded == 0) revert UnknownPool();
        return encoded - 1;
    }

    function getPoolState(uint8 crew)
        public
        view
        returns (uint160 sqrtPriceX96, int24 tick, uint128 liquidity)
    {
        PoolId id = _pool(crew).key.toId();
        (sqrtPriceX96, tick,,) = manager.getSlot0(id);
        liquidity = manager.getLiquidity(id);
    }

    function positionLiquidity(uint8 crew) public view returns (uint128) {
        return _pool(crew).liquidity;
    }

    /// @notice Hook-ABI read alias; keeps aggregation in the bound execution module.
    function poolState(uint8 crew) external view returns (uint160, int24, uint128) {
        return getPoolState(crew);
    }

    function beforeSwapFee(IPoolManager.SwapParams calldata params)
        external pure returns (BeforeSwapDelta, uint256)
    { return MugiIMDV4Fees.beforeSwapFee(params); }

    function afterSwapFee(IPoolManager.SwapParams calldata params, BalanceDelta delta)
        external pure returns (int128, uint256)
    { return MugiIMDV4Fees.afterSwapFee(params, delta); }

    /// @notice Exact v4 full-range token requirements, rounded up to cover settlement.
    /// @dev Returns zero when the whole requested addition is mathematically unexecutable.
    /// The controller retains that ETH rather than blocking the remaining season settlement.
    function quoteLiquidityForEth(uint8 crew, uint256 ethBudget)
        public
        view
        returns (uint128 liquidity, uint256 ethUsed, uint256 tokensNeeded)
    {
        Pool storage pool = _pool(crew);
        PoolId id = pool.key.toId();
        (uint160 price,,,) = manager.getSlot0(id);
        uint160 lower = TickMath.getSqrtPriceAtTick(pool.tickLower);
        uint160 upper = TickMath.getSqrtPriceAtTick(pool.tickUpper);
        if (ethBudget == 0 || price <= lower || price >= upper) return (0, 0, 0);
        (uint128 lowerGross,) = manager.getTickLiquidity(id, pool.tickLower);
        (uint128 upperGross,) = manager.getTickLiquidity(id, pool.tickUpper);
        uint128 gross = lowerGross > upperGross ? lowerGross : upperGross;
        uint128 tickMaximum = V4Pool.tickSpacingToMaxLiquidityPerTick(pool.key.tickSpacing);
        if (gross >= tickMaximum) return (0, 0, 0);
        uint128 capacity = tickMaximum - gross;
        uint128 positionCapacity = type(uint128).max - pool.liquidity;
        if (capacity > positionCapacity) capacity = positionCapacity;
        if (capacity > uint128(type(int128).max)) capacity = uint128(type(int128).max);
        // Reject oversized budgets before mulDiv: even its 256-bit quotient can otherwise overflow.
        if (ethBudget > SqrtPriceMath.getAmount0Delta(price, upper, capacity, true)) return (0, 0, 0);
        uint256 intermediate = FullMath.mulDiv(price, upper, FixedPoint96.Q96);
        uint256 amount = FullMath.mulDiv(ethBudget, intermediate, upper - price);
        if (amount == 0 || amount > capacity) return (0, 0, 0);
        liquidity = uint128(amount);
        ethUsed = SqrtPriceMath.getAmount0Delta(price, upper, liquidity, true);
        tokensNeeded = SqrtPriceMath.getAmount1Delta(lower, price, liquidity, true);
        // PoolManager stores each currency's principal delta in an int128.
        if (ethUsed > uint256(uint128(type(int128).max)) || tokensNeeded > uint256(uint128(type(int128).max))) {
            return (0, 0, 0);
        }
        if (ethUsed > ethBudget) revert SlippageExceeded();
    }

    /// @notice Hook sends maxEth and pretransfers maxTokens immediately before calling.
    function addLiquidity(uint8 crew, uint128 liquidity, uint256 maxEth, uint256 maxTokens)
        external
        payable
        onlyHook
        returns (LiquidityResult memory result)
    {
        Pool storage pool = _pool(crew);
        if (msg.value != maxEth || liquidity == 0 || liquidity > uint128(type(int128).max)) revert InvalidAmount();
        IERC20 token = IERC20(Currency.unwrap(pool.key.currency1));
        uint256 tokenBalance = token.balanceOf(address(this));
        if (tokenBalance < maxTokens) revert InvalidAmount();
        uint256 priorTokens = tokenBalance - maxTokens;
        uint256 priorEth = address(this).balance - msg.value;
        result = abi.decode(_run(Action(Operation.Add, crew, liquidity, maxEth, maxTokens, 0)), (LiquidityResult));
        uint256 remaining = token.balanceOf(address(this));
        if (remaining < priorTokens) revert UnexpectedDelta();
        if (remaining != priorTokens && !token.transfer(hook, remaining - priorTokens)) revert TokenTransferFailed();
        _refundEth(priorEth);
    }

    function collectFees(uint8 crew) external onlyHook returns (uint256 ethFees, uint256 tokenFees) {
        if (_pool(crew).liquidity == 0) return (0, 0);
        LiquidityResult memory result =
            abi.decode(_run(Action(Operation.Collect, crew, 0, 0, 0, 0)), (LiquidityResult));
        return (result.ethFees, result.tokenFees);
    }

    function removeLiquidity(uint8 crew, uint256 minEth, uint256 minTokens)
        external
        onlyHook
        returns (LiquidityResult memory result)
    {
        uint128 liquidity = _pool(crew).liquidity;
        if (liquidity == 0) revert InvalidAmount();
        return
            abi.decode(_run(Action(Operation.Remove, crew, liquidity, minEth, minTokens, 0)), (LiquidityResult));
    }

    /// @notice Acquires tokens into the hook. Caller must subsequently burn them.
    /// @dev Partial fills are allowed here; the budget must be charged by actual ethSpent.
    function buy(uint8 crew, uint256 ethBudget, uint256 minTokens, uint160 sqrtPriceLimitX96)
        external
        payable
        onlyHook
        returns (uint256 ethSpent, uint256 tokenOut)
    {
        _pool(crew);
        if (msg.value != ethBudget || ethBudget == 0 || ethBudget > uint256(uint128(type(int128).max))) {
            revert InvalidAmount();
        }
        uint256 priorEth = address(this).balance - msg.value;
        if (sqrtPriceLimitX96 == 0) sqrtPriceLimitX96 = TickMath.MIN_SQRT_PRICE + 1;
        (ethSpent, tokenOut) = abi.decode(
            _run(Action(Operation.Buy, crew, 0, ethBudget, minTokens, sqrtPriceLimitX96)), (uint256, uint256)
        );
        _refundEth(priorEth);
    }

    /// @dev Only the exact pending PoolManager unlock callback can consume an operation.
    function unlockCallback(bytes calldata data) external returns (bytes memory result) {
        if (
            msg.sender != address(manager) || !operating || !self.unlocking || self.pendingUnlock == bytes32(0)
                || keccak256(data) != self.pendingUnlock
        ) revert UnauthorizedCallback();
        self.pendingUnlock = bytes32(0);
        Action memory action = abi.decode(data, (Action));
        Pool storage pool = _pool(action.crew);
        if (action.operation == Operation.Buy) return _buy(pool, action);
        return _modify(pool, action);
    }

    function _run(Action memory action) private returns (bytes memory result) {
        if (self.unlocking) revert UnlockInProgress();
        bytes memory data = abi.encode(action);
        self.unlocking = true;
        self.pendingUnlock = keccak256(data);
        result = manager.unlock(data);
        if (self.pendingUnlock != bytes32(0)) revert UnlockNotConsumed();
        self.unlocking = false;
    }

    function _modify(Pool storage pool, Action memory action) private returns (bytes memory) {
        int256 change;
        if (action.operation == Operation.Add) change = int256(uint256(action.liquidity));
        else if (action.operation == Operation.Remove) change = -int256(uint256(action.liquidity));
        (BalanceDelta delta, BalanceDelta fees) = manager
            .modifyLiquidity(
                pool.key,
                IPoolManager.ModifyLiquidityParams(pool.tickLower, pool.tickUpper, change, bytes32(0)),
                bytes("")
            );
        if (fees.amount0() < 0 || fees.amount1() < 0) revert UnexpectedDelta();
        int256 principal0 = int256(delta.amount0()) - int256(fees.amount0());
        int256 principal1 = int256(delta.amount1()) - int256(fees.amount1());
        LiquidityResult memory result;
        result.liquidity = action.liquidity;
        result.ethFees = uint256(int256(fees.amount0()));
        result.tokenFees = uint256(int256(fees.amount1()));
        if (action.operation == Operation.Add) {
            if (principal0 > 0 || principal1 > 0) revert UnexpectedDelta();
            result.ethPrincipal = uint256(-principal0);
            result.tokenPrincipal = uint256(-principal1);
            if (result.ethPrincipal > action.amount0 || result.tokenPrincipal > action.amount1) {
                revert SlippageExceeded();
            }
            pool.liquidity += action.liquidity;
        } else {
            if (principal0 < 0 || principal1 < 0) revert UnexpectedDelta();
            result.ethPrincipal = uint256(principal0);
            result.tokenPrincipal = uint256(principal1);
            if (result.ethPrincipal < action.amount0 || result.tokenPrincipal < action.amount1) {
                revert SlippageExceeded();
            }
            if (action.operation == Operation.Remove) pool.liquidity -= action.liquidity;
        }
        _settle(pool.key.currency0, delta.amount0());
        _settle(pool.key.currency1, delta.amount1());
        return abi.encode(result);
    }

    function _buy(Pool storage pool, Action memory action) private returns (bytes memory) {
        BalanceDelta delta = manager
            .swap(pool.key, IPoolManager.SwapParams(true, -int256(action.amount0), action.sqrtPriceLimitX96), bytes(""));
        if (delta.amount0() > 0 || delta.amount1() < 0) revert UnexpectedDelta();
        uint256 spent = uint256(-int256(delta.amount0()));
        uint256 received = uint256(int256(delta.amount1()));
        if (spent > action.amount0 || received < action.amount1 || received == 0) revert SlippageExceeded();
        _settle(pool.key.currency0, delta.amount0());
        _settle(pool.key.currency1, delta.amount1());
        return abi.encode(spent, received);
    }

    function _settle(Currency currency, int128 delta) private {
        if (delta > 0) {
            manager.take(currency, hook, uint256(int256(delta)));
        } else if (delta < 0) {
            uint256 amount = uint256(-int256(delta));
            if (Currency.unwrap(currency) == address(0)) {
                // sync is public and its transient state may have been set by an earlier caller.
                manager.sync(currency);
                manager.settle{value: amount}();
            } else {
                manager.sync(currency);
                if (!IERC20(Currency.unwrap(currency)).transfer(address(manager), amount)) {
                    revert TokenTransferFailed();
                }
                manager.settle();
            }
        }
    }

    function _refundEth(uint256 priorEth) private {
        uint256 balance = address(this).balance;
        if (balance < priorEth) revert UnexpectedDelta();
        uint256 refund = balance - priorEth;
        if (refund != 0) {
            (bool ok,) = payable(hook).call{value: refund}("");
            if (!ok) revert EthTransferFailed();
        }
    }

    function _pool(uint8 crew) private view returns (Pool storage pool) {
        pool = self.pools[crew];
        if (!pool.registered) revert UnknownPool();
    }
}
