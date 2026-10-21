// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {MugiCrewToken} from "../../src/game/MugiCrewToken.sol";
import {MugiReserveMath} from "../../src/game/MugiReserveMath.sol";
import {MugiIMDCrewToken} from "../../src/imd/MugiIMDCrewToken.sol";

contract MugiAlwaysRejectingTokenHook {
    fallback() external {
        revert("A token must never call its hook");
    }
}

contract MugiIMDCrewTokenTest is Test {
    address private constant ALICE = address(0xA11CE);
    address private constant BOB = address(0xB0B);
    address private constant SPENDER = address(0x5EED);
    uint256 private constant INITIAL = 1e24;
    uint64 private constant GENESIS = 1000;
    MugiIMDCrewToken private token;

    function setUp() public {
        vm.warp(GENESIS);
        token = new MugiIMDCrewToken(0, address(this), INITIAL);
    }

    function testConstructorCreatesWholeFiniteReserveAndNoEarlierHistory() public view {
        uint256 cap = token.reserveCap();
        assertEq(token.initialSupply(), INITIAL);
        assertEq(token.totalSupply(), cap);
        assertEq(token.balanceOf(address(this)), cap);
        assertEq(token.hook(), address(this));
        assertEq(token.characterId(), 0);
        assertEq(token.crewId(), 0);
        assertEq(token.name(), "Luffy");
        assertEq(token.symbol(), "MLFY");
        assertEq(token.decimals(), 18);
        assertEq(token.totalSupplyBefore(0), 0);
        assertEq(token.totalSupplyBefore(GENESIS), 0);
        assertEq(token.balanceBefore(address(this), GENESIS), 0);
        assertEq(token.totalSupplyBefore(GENESIS + 1), cap);
        assertEq(token.balanceBefore(address(this), GENESIS + 1), cap);
        assertEq(token.balanceBefore(ALICE, type(uint64).max), 0);
    }

    function testStaticConstructorPreservesAllCanonicalCrewNamesAndSymbols() public {
        string[10] memory names = ["Luffy", "Zoro", "Nami", "Usopp", "Sanji", "Chopper", "Robin", "Franky", "Brook", "Jinbe"];
        string[10] memory symbols = ["MLFY", "MZRO", "MNMI", "MUSP", "MSNJ", "MCHP", "MRBN", "MFRK", "MBRK", "MJNB"];
        for (uint8 crew; crew < 10; ++crew) {
            MugiIMDCrewToken canonical = new MugiIMDCrewToken(crew, address(this), INITIAL);
            assertEq(canonical.name(), names[crew]);
            assertEq(canonical.symbol(), symbols[crew]);
            assertEq(canonical.characterId(), crew);
            assertEq(canonical.crewId(), crew);
        }
    }

    function testConstructorAcceptsPredeterminedUndeployedHook() public {
        address predicted = address(0xF0702E);
        assertEq(predicted.code.length, 0);
        MugiIMDCrewToken future = new MugiIMDCrewToken(9, predicted, INITIAL);
        assertEq(future.hook(), predicted);
        assertEq(future.balanceOf(predicted), future.reserveCap());
    }

    function testInvalidConstructorConfigurationRejects() public {
        vm.expectRevert(MugiCrewToken.InvalidCrewConfiguration.selector);
        new MugiIMDCrewToken(0, address(0), INITIAL);
        vm.expectRevert(MugiCrewToken.InvalidCrewConfiguration.selector);
        new MugiIMDCrewToken(10, address(this), INITIAL);
        vm.expectRevert(MugiReserveMath.InvalidInitialSupply.selector);
        new MugiIMDCrewToken(0, address(this), 999);
        vm.expectRevert(MugiReserveMath.InvalidInitialSupply.selector);
        new MugiIMDCrewToken(0, address(this), 1e36 + 1);
    }

    function testTransfersAndBurnDoNotCallRevertingOrBrokenHook() public {
        address rejecting = address(new MugiAlwaysRejectingTokenHook());
        MugiIMDCrewToken independent = new MugiIMDCrewToken(2, rejecting, INITIAL);
        vm.prank(rejecting);
        independent.transfer(ALICE, 100 ether);
        vm.startPrank(ALICE);
        independent.transfer(BOB, 20 ether);
        independent.approve(SPENDER, 30 ether);
        vm.stopPrank();
        vm.prank(SPENDER);
        independent.transferFrom(ALICE, BOB, 30 ether);
        vm.etch(rejecting, hex"fe");
        vm.startPrank(BOB);
        independent.transfer(ALICE, 10 ether);
        independent.burn(5 ether);
        vm.stopPrank();
        assertEq(independent.balanceOf(ALICE), 60 ether);
        assertEq(independent.balanceOf(BOB), 35 ether);
        assertEq(independent.totalSupply(), independent.reserveCap() - 5 ether);
    }

    function testRemovedMintInitializerAndArbitraryBurnSelectorsAreUnavailable() public {
        uint256 cap = token.totalSupply();
        (bool minted,) = address(token).call(abi.encodeWithSignature("mint(address,uint256)", ALICE, 1 ether));
        assertFalse(minted, "reserve holder cannot mint");
        token.transfer(ALICE, 10 ether);
        (bool burned,) = address(token).call(abi.encodeWithSignature("burn(address,uint256)", ALICE, 1 ether));
        assertFalse(burned, "reserve holder cannot burn another wallet");
        (bool initialized,) = address(token).call(
            abi.encodeWithSignature("initialize(string,string,uint8,address)", "Changed", "BAD", 1, ALICE)
        );
        assertFalse(initialized);
        vm.prank(ALICE);
        (minted,) = address(token).call(abi.encodeWithSignature("mint(address,uint256)", ALICE, 1 ether));
        assertFalse(minted);
        assertEq(token.totalSupply(), cap);
        assertEq(token.balanceOf(ALICE), 10 ether);
    }

    function testReserveHolderHasNoAuthorityOverOtherBalances() public {
        uint256 cap = token.totalSupply();
        token.transfer(ALICE, cap);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, address(this), 0, 1));
        token.burn(1);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, address(this), 0, 1)
        );
        token.transferFrom(ALICE, address(this), 1);
        assertEq(token.balanceOf(ALICE), cap);
        vm.prank(ALICE);
        token.burn(cap);
        assertEq(token.totalSupply(), 0);
        assertEq(token.reserveCap(), cap);
    }

    function testSameTimestampGenesisAndTransfersUseEndOfTimestampBalance() public {
        token.transfer(ALICE, 100 ether);
        vm.prank(ALICE);
        token.transfer(BOB, 40 ether);
        vm.prank(BOB);
        token.transfer(ALICE, 10 ether);
        assertEq(token.balanceBefore(ALICE, GENESIS), 0);
        assertEq(token.balanceBefore(BOB, GENESIS), 0);
        assertEq(token.balanceBefore(ALICE, GENESIS + 1), 70 ether);
        assertEq(token.balanceBefore(BOB, GENESIS + 1), 30 ether);
        assertEq(token.balanceBefore(address(this), GENESIS + 1), token.reserveCap() - 100 ether);
    }

    function testStrictCutoffExcludesEveryExactCutoffTransferAndBurn() public {
        vm.warp(1500);
        token.transfer(ALICE, 100 ether);
        vm.warp(2000);
        vm.startPrank(ALICE);
        token.transfer(BOB, 40 ether);
        token.burn(10 ether);
        vm.stopPrank();
        vm.prank(BOB);
        token.transfer(ALICE, 5 ether);
        assertEq(token.balanceBefore(ALICE, 2000), 100 ether);
        assertEq(token.balanceBefore(BOB, 2000), 0);
        assertEq(token.totalSupplyBefore(2000), token.reserveCap());
        assertEq(token.balanceBefore(ALICE, 2001), 55 ether);
        assertEq(token.balanceBefore(BOB, 2001), 35 ether);
        assertEq(token.totalSupplyBefore(2001), token.reserveCap() - 10 ether);
        vm.warp(3000);
        vm.prank(ALICE);
        token.transfer(BOB, 55 ether);
        assertEq(token.balanceBefore(ALICE, 2000), 100 ether, "later ownership must not rewrite cutoff");
        assertEq(token.balanceBefore(ALICE, 2001), 55 ether);
    }

    function testTransferFromCheckpointsBothWalletsAndFiniteAllowance() public {
        vm.warp(1500);
        token.transfer(ALICE, 100 ether);
        vm.prank(ALICE);
        token.approve(SPENDER, 30 ether);
        vm.warp(2000);
        vm.prank(SPENDER);
        token.transferFrom(ALICE, BOB, 20 ether);
        assertEq(token.allowance(ALICE, SPENDER), 10 ether);
        assertEq(token.balanceBefore(ALICE, 2000), 100 ether);
        assertEq(token.balanceBefore(BOB, 2000), 0);
        assertEq(token.balanceBefore(ALICE, 2001), 80 ether);
        assertEq(token.balanceBefore(BOB, 2001), 20 ether);
        assertEq(token.totalSupplyBefore(2001), token.reserveCap());
    }

    function testInfiniteAllowanceAndFailedTransferPreserveHistory() public {
        token.transfer(ALICE, 10 ether);
        vm.prank(ALICE);
        token.approve(SPENDER, type(uint256).max);
        vm.warp(2000);
        vm.prank(SPENDER);
        token.transferFrom(ALICE, BOB, 10 ether);
        assertEq(token.allowance(ALICE, SPENDER), type(uint256).max);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, ALICE, 0, 1));
        vm.prank(SPENDER);
        token.transferFrom(ALICE, BOB, 1);
        assertEq(token.balanceBefore(ALICE, 2000), 10 ether);
        assertEq(token.balanceBefore(ALICE, 2001), 0);
        assertEq(token.balanceBefore(BOB, 2001), 10 ether);
    }

    function testBurnHistoryTracksMultipleTimestampsAndCoalescesSameTimestamp() public {
        uint256 cap = token.totalSupply();
        vm.warp(1500);
        token.transfer(ALICE, 100 ether);
        vm.startPrank(ALICE);
        token.burn(20 ether);
        token.burn(30 ether);
        vm.warp(2000);
        token.burn(50 ether);
        vm.stopPrank();
        assertEq(token.totalSupplyBefore(1500), cap);
        assertEq(token.totalSupplyBefore(1501), cap - 50 ether);
        assertEq(token.totalSupplyBefore(2000), cap - 50 ether);
        assertEq(token.totalSupplyBefore(2001), cap - 100 ether);
        assertEq(token.balanceBefore(ALICE, 1500), 0);
        assertEq(token.balanceBefore(ALICE, 1501), 50 ether);
        assertEq(token.balanceBefore(ALICE, 2000), 50 ether);
        assertEq(token.balanceBefore(ALICE, 2001), 0);
    }

    function testZeroAndSelfTransfersDoNotChangeHistoricalOwnership() public {
        token.transfer(ALICE, 5 ether);
        vm.warp(2000);
        vm.startPrank(ALICE);
        token.transfer(ALICE, 5 ether);
        token.transfer(BOB, 0);
        token.burn(0);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, ALICE, 5 ether, 6 ether));
        token.transfer(ALICE, 6 ether);
        vm.stopPrank();
        assertEq(token.balanceBefore(ALICE, 2000), 5 ether);
        assertEq(token.balanceBefore(ALICE, 2001), 5 ether);
        assertEq(token.balanceBefore(BOB, 2001), 0);
        assertEq(token.totalSupply(), token.reserveCap());
    }

    function testRejectsZeroTransferAndApprovalDestinations() public {
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(0)));
        token.transfer(address(0), 0);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidSpender.selector, address(0)));
        token.approve(address(0), 1);
    }

    function testFuzzHistoricalReadsMatchRecordedBeforeStates(uint256 entropy) public {
        address[3] memory wallets = [address(this), ALICE, BOB];
        uint64[16] memory cutoffs;
        uint256[3][16] memory balances;
        uint256[16] memory supplies;
        uint64 now_ = GENESIS;
        for (uint256 i; i < 16; ++i) {
            entropy = uint256(keccak256(abi.encode(entropy, i)));
            now_ += uint64(1 + entropy % 3);
            vm.warp(now_);
            cutoffs[i] = now_;
            supplies[i] = token.totalSupply();
            for (uint256 j; j < 3; ++j) balances[i][j] = token.balanceOf(wallets[j]);
            address from = wallets[entropy % 3];
            address to = wallets[(entropy >> 8) % 3];
            uint256 amount = (entropy >> 16) % (token.balanceOf(from) + 1);
            vm.startPrank(from);
            if (i % 4 == 0) token.burn(amount);
            else token.transfer(to, amount);
            // Repeated writes at this same timestamp must still be excluded.
            token.burn(token.balanceOf(from) / 11);
            vm.stopPrank();
        }
        for (uint256 i; i < 16; ++i) {
            assertEq(token.totalSupplyBefore(cutoffs[i]), supplies[i]);
            for (uint256 j; j < 3; ++j) {
                assertEq(token.balanceBefore(wallets[j], cutoffs[i]), balances[i][j]);
            }
        }
    }

    function testFuzzFiniteReserveCoversMaxReinforcementsAndConversions(uint256 initial, uint256 order) public view {
        initial = bound(initial, 1000, 1e36);
        uint256 cap = MugiReserveMath.reserveFor(initial);
        uint256 maxAddition = uint256(uint128(type(int128).max));
        uint256[10] memory mass;
        uint256[10] memory released;
        bool[10] memory alive;
        for (uint256 i; i < 10; ++i) {
            mass[i] = initial;
            released[i] = initial;
            alive[i] = true;
        }
        for (uint256 round; round < 9; ++round) {
            order = uint256(keccak256(abi.encode(order, round)));
            uint256 loser = order % 10;
            while (!alive[loser]) loser = (loser + 1) % 10;
            alive[loser] = false;
            uint256 divisor = 4 * (9 - round);
            // Even rounding every recipient upward each round fits the cap.
            uint256 conversion = (3 * mass[loser] + divisor - 1) / divisor;
            mass[loser] = 0;
            for (uint256 i; i < 10; ++i) {
                if (!alive[i]) continue;
                mass[i] += conversion + maxAddition;
                released[i] += conversion + maxAddition;
                assertLt(released[i], cap);
            }
        }
        // Packed history and ledger's 1e18 scaling both remain safely representable.
        assertLt(cap, type(uint192).max);
        assertLt(cap, type(uint256).max / 1e18);
    }
}
