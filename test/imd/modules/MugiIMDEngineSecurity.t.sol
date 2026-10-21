// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {PoolManager} from "v4-core/src/PoolManager.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta} from "v4-core/src/types/BeforeSwapDelta.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {MugiIMDEngineFactory} from "../../../src/imd/MugiIMDEngineFactory.sol";
import {MugiIMDV4Engine} from "../../../src/imd/modules/MugiIMDV4Engine.sol";

contract MugiIMDEngineTestToken is ERC20 {
    constructor() ERC20("Engine test token", "TEST") {}
    function mint(address to, uint256 value) external { _mint(to, value); }
}

/// @dev Test-only callback harness; production authorization is in MugiIMDGameHook.
contract MugiIMDEngineTestHook {
    IPoolManager public immutable poolManager;
    MugiIMDV4Engine public engine;
    bool public attemptReentry;
    bool public reentrySucceeded;
    bytes public reentryResult;

    constructor(IPoolManager manager) { poolManager = manager; }
    function setEngine(MugiIMDV4Engine value) external { engine = value; }
    function setAttemptReentry(bool value) external { attemptReentry = value; }

    receive() external payable {
        if (attemptReentry) {
            (reentrySucceeded, reentryResult) = address(engine).call(abi.encodeCall(engine.collectFees, (0)));
        }
    }

    modifier onlyEngineCallback(address sender) {
        require(msg.sender == address(poolManager) && sender == address(engine), "unexpected callback");
        _;
    }

    function beforeInitialize(address sender, PoolKey calldata, uint160)
        external view onlyEngineCallback(sender) returns (bytes4)
    { return IHooks.beforeInitialize.selector; }

    function beforeAddLiquidity(address sender, PoolKey calldata, IPoolManager.ModifyLiquidityParams calldata, bytes calldata)
        external view onlyEngineCallback(sender) returns (bytes4)
    { return IHooks.beforeAddLiquidity.selector; }

    function beforeRemoveLiquidity(address sender, PoolKey calldata, IPoolManager.ModifyLiquidityParams calldata, bytes calldata)
        external view onlyEngineCallback(sender) returns (bytes4)
    { return IHooks.beforeRemoveLiquidity.selector; }

    function beforeSwap(address sender, PoolKey calldata, IPoolManager.SwapParams calldata, bytes calldata)
        external view onlyEngineCallback(sender) returns (bytes4, BeforeSwapDelta, uint24)
    { return (IHooks.beforeSwap.selector, BeforeSwapDelta.wrap(0), 0); }

    function afterSwap(address sender, PoolKey calldata, IPoolManager.SwapParams calldata, BalanceDelta, bytes calldata)
        external view onlyEngineCallback(sender) returns (bytes4, int128)
    { return (IHooks.afterSwap.selector, 0); }
}

contract MugiIMDEngineSecurityTest is Test {
    uint256 internal constant LP_TOKENS = 950_000 ether;
    address internal constant HOOK = address(0x123400002aEc);
    PoolManager internal manager;
    MugiIMDEngineFactory internal factory;
    MugiIMDV4Engine internal engine;
    MugiIMDEngineTestHook internal hook;
    MugiIMDEngineTestToken internal token;

    function setUp() public {
        manager = new PoolManager(address(this));
        MugiIMDEngineTestHook template = new MugiIMDEngineTestHook(manager);
        vm.etch(HOOK, address(template).code);
        hook = MugiIMDEngineTestHook(payable(HOOK));
        factory = new MugiIMDEngineFactory();
        engine = factory.deployForHook(HOOK, manager);
        hook.setEngine(engine);
        token = new MugiIMDEngineTestToken();
        vm.deal(address(this), 10 ether);
        vm.deal(HOOK, 10 ether);
    }

    function testFactoryRejectsWrongManagerWithoutPoisoningCanonicalEntry() public {
        MugiIMDEngineFactory otherFactory = new MugiIMDEngineFactory();
        PoolManager wrongManager = new PoolManager(address(this));
        vm.prank(address(0xBAD));
        vm.expectRevert(MugiIMDEngineFactory.InvalidManager.selector);
        otherFactory.deployForHook(HOOK, wrongManager);
        assertEq(address(otherFactory.engines(HOOK)), address(0));
        vm.prank(address(0xBAD));
        MugiIMDV4Engine canonical = otherFactory.deployForHook(HOOK, manager);
        assertEq(address(canonical.manager()), address(manager));
        assertEq(canonical.hook(), HOOK);
        assertEq(address(otherFactory.deployForHook(HOOK, manager)), address(canonical));
        assertEq(address(factory.deployForHook(HOOK, manager)), address(engine));
    }

    function testCounterfactualConstructorDoesNotCallDependencyAddresses() public {
        MugiIMDV4Engine future = new MugiIMDV4Engine(address(0x1111), IPoolManager(address(0x2222)));
        assertEq(future.hook(), address(0x1111));
        assertEq(address(future.manager()), address(0x2222));
        vm.expectRevert(MugiIMDV4Engine.InvalidHook.selector);
        new MugiIMDV4Engine(address(0), manager);
        vm.expectRevert(MugiIMDV4Engine.InvalidManager.selector);
        new MugiIMDV4Engine(HOOK, IPoolManager(address(0)));
    }

    function testAllEconomicMutatorsRejectNonHookCaller() public {
        vm.expectRevert(MugiIMDV4Engine.Unauthorized.selector);
        engine.registerInitialPool(0, address(token), LP_TOKENS, 1 ether);
        vm.expectRevert(MugiIMDV4Engine.Unauthorized.selector);
        engine.registerPool(0, address(token), 3000, 60, uint160(1 << 96));
        vm.expectRevert(MugiIMDV4Engine.Unauthorized.selector);
        engine.addLiquidity(0, 1, 0, 0);
        vm.expectRevert(MugiIMDV4Engine.Unauthorized.selector);
        engine.removeLiquidity(0, 0, 0);
        vm.expectRevert(MugiIMDV4Engine.Unauthorized.selector);
        engine.collectFees(0);
        vm.expectRevert(MugiIMDV4Engine.Unauthorized.selector);
        engine.buy(0, 1 ether, 0, 0);
    }

    function testCallbackCannotBeInjectedEvenByManagerWithoutPendingUnlock() public {
        vm.expectRevert(MugiIMDV4Engine.UnauthorizedCallback.selector);
        engine.unlockCallback(hex"1234");
        vm.prank(address(manager));
        vm.expectRevert(MugiIMDV4Engine.UnauthorizedCallback.selector);
        engine.unlockCallback(hex"1234");
    }

    function testSeedRefundsUnusedInputsAndPreservesPriorEngineBalances() public {
        vm.prank(HOOK);
        uint128 liquidity = engine.registerInitialPool(0, address(token), LP_TOKENS, 1 ether);
        token.mint(address(engine), LP_TOKENS + 7 ether);
        vm.deal(address(engine), 3 ether);
        uint256 priorHookEth = HOOK.balance;
        vm.prank(HOOK);
        MugiIMDV4Engine.LiquidityResult memory result =
            engine.addLiquidity{value: 2 ether}(0, liquidity, 2 ether, LP_TOKENS);
        assertEq(address(engine).balance, 3 ether);
        assertEq(token.balanceOf(address(engine)), 7 ether);
        assertEq(HOOK.balance, priorHookEth - result.ethPrincipal);
        assertEq(token.balanceOf(HOOK), LP_TOKENS - result.tokenPrincipal);
        assertEq(engine.positionLiquidity(0), liquidity);
        assertEq(address(engine.poolKey(0).hooks), HOOK);
        assertEq(result.ethFees, 0);
        assertEq(result.tokenFees, 0);
    }

    function testPartialBuyPaysHookAndRefundsUnusedEth() public {
        _seed();
        vm.deal(address(engine), 3 ether);
        (, int24 tick,) = engine.getPoolState(0);
        uint256 priorHookEth = HOOK.balance;
        uint256 priorHookTokens = token.balanceOf(HOOK);
        vm.prank(HOOK);
        (uint256 spent, uint256 bought) = engine.buy{value: 1 ether}(
            0, 1 ether, 1, TickMath.getSqrtPriceAtTick(tick - 10)
        );
        assertGt(spent, 0);
        assertLt(spent, 1 ether);
        assertGt(bought, 0);
        assertEq(priorHookEth - HOOK.balance, spent);
        assertEq(token.balanceOf(HOOK) - priorHookTokens, bought);
        assertEq(address(engine).balance, 3 ether);
        assertEq(token.balanceOf(address(engine)), 0);
    }

    function testRefundCallbackCannotReenterPositionOperations() public {
        vm.prank(HOOK);
        uint128 liquidity = engine.registerInitialPool(0, address(token), LP_TOKENS, 1 ether);
        token.mint(address(engine), LP_TOKENS);
        hook.setAttemptReentry(true);
        vm.prank(HOOK);
        engine.addLiquidity{value: 2 ether}(0, liquidity, 2 ether, LP_TOKENS);
        assertFalse(hook.reentrySucceeded());
        assertEq(hook.reentryResult(), abi.encodeWithSelector(MugiIMDV4Engine.UnlockInProgress.selector));
        assertEq(engine.positionLiquidity(0), liquidity);
    }

    function testRemovePaysHookAndLeavesNoPositionOrNewBalancesInEngine() public {
        _seed();
        uint256 priorHookEth = HOOK.balance;
        uint256 priorHookTokens = token.balanceOf(HOOK);
        vm.prank(HOOK);
        MugiIMDV4Engine.LiquidityResult memory result = engine.removeLiquidity(0, 0, 0);
        assertEq(engine.positionLiquidity(0), 0);
        assertEq(HOOK.balance - priorHookEth, result.ethPrincipal + result.ethFees);
        assertEq(token.balanceOf(HOOK) - priorHookTokens, result.tokenPrincipal + result.tokenFees);
        assertEq(address(engine).balance, 0);
        assertEq(token.balanceOf(address(engine)), 0);
    }

    function _seed() private {
        vm.prank(HOOK);
        uint128 liquidity = engine.registerInitialPool(0, address(token), LP_TOKENS, 1 ether);
        token.mint(address(engine), LP_TOKENS);
        vm.prank(HOOK);
        engine.addLiquidity{value: 1 ether}(0, liquidity, 1 ether, LP_TOKENS);
    }
}
