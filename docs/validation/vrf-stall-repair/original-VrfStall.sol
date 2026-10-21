// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {PoolManager} from "v4-core/src/PoolManager.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {MugiIMDGameHook} from "src/imd/MugiIMDGameHook.sol";
import {MugiIMDCrewFactory} from "src/imd/MugiIMDCrewFactory.sol";
import {MugiIMDAccountingFactory} from "src/imd/MugiIMDAccountingFactory.sol";
import {MugiIMDEngineFactory} from "src/imd/MugiIMDEngineFactory.sol";
import {MugiAirdrop} from "src/game/MugiAirdrop.sol";

/// @dev Stands in for a Chainlink VRF request that is accepted but never fulfilled
/// (subscription underfunded past the request expiry, consumer removed, or the
/// subscription cancelled). It records requests and never calls back.
contract SilentRandomness {
    uint256 public requests;
    function requestRandomness() external returns (uint256) { return ++requests; }
}

contract VrfStallTest is Test {
    uint256 internal constant SUPPLY = 1_000_000 ether;
    address internal constant TEAM = address(0x7EA0);
    address internal constant COMMUNITY = address(0xC000);
    MugiIMDGameHook internal game;
    SilentRandomness internal randomness;

    receive() external payable {}

    function setUp() public {
        vm.deal(address(this), 1_000 ether);
        IPoolManager manager = new PoolManager(address(this));
        address hookAddress = address(uint160(0x1234000000) | uint160(0x2aec));
        deployCodeTo(
            "MugiIMDGameHook.sol:MugiIMDGameHook",
            abi.encode(address(this), manager, TEAM, COMMUNITY, address(0), SUPPLY),
            hookAddress
        );
        game = MugiIMDGameHook(payable(hookAddress));
        MugiIMDAccountingFactory.Modules memory m = new MugiIMDAccountingFactory().deployForHook(hookAddress);
        game.bindAccounting(m.ledger, m.budgets, m.prices, new MugiIMDEngineFactory().deployForHook(hookAddress, manager));
        address[10] memory crew = new MugiIMDCrewFactory().deployCrewSet(hookAddress, 1);
        MugiAirdrop airdrop = new MugiAirdrop(hookAddress, address(0xA77E57), SUPPLY, crew);
        randomness = new SilentRandomness();
        game.configure(crew, airdrop, address(randomness), address(0));
        for (uint8 i; i < 10; ++i) game.seedPool{value: 1 ether}(i);
        vm.warp(block.timestamp + 7 days);
        game.launch();
    }

    function testUnfulfilledRandomnessCanBeRequestedAgain() public {
        vm.warp(game.nextCutoff());
        game.requestElimination();
        assertEq(uint8(game.phase()), uint8(MugiIMDGameHook.Phase.AwaitingRandomness));

        // The VRF request is never fulfilled. Thirty days later the season must still
        // have a way forward; today every path is closed and ~10 ETH of LP is locked.
        vm.warp(block.timestamp + 30 days);
        (bool retried,) = address(game).call(abi.encodeCall(MugiIMDGameHook.requestElimination, ()));
        assertTrue(retried, "stalled VRF request leaves the season permanently in AwaitingRandomness");
        assertEq(randomness.requests(), 2);
    }
}