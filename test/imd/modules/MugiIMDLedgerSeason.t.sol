// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {MugiIMDLedger} from "../../../src/imd/modules/MugiIMDLedger.sol";

contract MugiSeasonBindingToken is ERC20 {
    address public hook;
    uint8 public characterId;

    constructor(address hook_, uint8 id) ERC20("Binding test", "BIND") {
        hook = hook_;
        characterId = id;
    }

    function setHook(address value) external {
        hook = value;
    }

    function setId(uint8 value) external {
        characterId = value;
    }

    function mint(address account, uint256 amount) external {
        _mint(account, amount);
    }

    function burn(address account, uint256 amount) external {
        _burn(account, amount);
    }
}

contract MugiSeasonBindingAirdrop {
    address[10] public tokens;

    constructor(address[10] memory tokens_) {
        tokens = tokens_;
    }

    function setToken(uint8 id, address token) external {
        tokens[id] = token;
    }
}

contract MugiIMDLedgerSeasonTest is Test {
    address internal constant ENGINE = address(0xE0919E);
    address internal constant MANAGER = address(0xB001);
    address internal constant TEAM = address(0x7EA);
    address internal constant COMMUNITY = address(0xC044);
    address internal constant ALICE = address(0xA11CE);
    MugiIMDLedger internal ledger;
    MugiSeasonBindingAirdrop internal airdrop;
    address[10] internal tokens;

    function setUp() public {
        ledger = new MugiIMDLedger(address(this));
        for (uint8 i; i < 10; ++i) {
            tokens[i] = address(new MugiSeasonBindingToken(address(this), i));
        }
        airdrop = new MugiSeasonBindingAirdrop(tokens);
    }

    function testSeasonInitializationExcludesAllFiveProtocolAddressesAtomically() public {
        _initialize();
        address[5] memory excluded = [MANAGER, ENGINE, address(airdrop), TEAM, COMMUNITY];
        for (uint8 i; i < 5; ++i) {
            _mint(excluded[i], 100 ether);
        }
        _mint(address(this), 100 ether);
        _mint(ALICE, 1 ether);
        assertEq(ledger.eligibleSupply(0), 1 ether * ledger.SCALE());
        ledger.emergencyFinalize(1023, 10 ether);
        assertEq(ledger.claimEth(ALICE), 1 ether);
        for (uint8 i; i < 5; ++i) {
            (, uint256 earned,) = ledger.previewAccount(excluded[i]);
            assertEq(earned, 0);
        }
        vm.expectRevert(MugiIMDLedger.InvalidConfiguration.selector);
        ledger.initialize(tokens);
    }

    function testEachCrewBindingConstraintRejectsBeforeInitializationCanStick() public {
        MugiSeasonBindingToken first = MugiSeasonBindingToken(tokens[0]);
        first.setHook(ALICE);
        vm.expectRevert(MugiIMDLedger.InvalidConfiguration.selector);
        _initialize();
        first.setHook(address(this));
        first.setId(1);
        vm.expectRevert(MugiIMDLedger.InvalidConfiguration.selector);
        _initialize();
        first.setId(0);
        first.mint(ALICE, 1);
        vm.expectRevert(MugiIMDLedger.InvalidConfiguration.selector);
        _initialize();
        first.burn(ALICE, 1);
        airdrop.setToken(0, tokens[1]);
        vm.expectRevert(MugiIMDLedger.InvalidConfiguration.selector);
        _initialize();
        airdrop.setToken(0, tokens[0]);
        _initialize();
        _mint(ALICE, 1 ether);
        assertEq(ledger.eligibleSupply(0), 1 ether * ledger.SCALE());
    }

    function _initialize() private {
        ledger.initializeSeason(tokens, address(airdrop), ENGINE, TEAM, COMMUNITY, MANAGER);
    }

    function _mint(address account, uint256 amount) private {
        ledger.beforeBalanceChange(address(0), account);
        MugiSeasonBindingToken(tokens[0]).mint(account, amount);
        ledger.afterBalanceChange(0, address(0), account, amount);
    }
}
