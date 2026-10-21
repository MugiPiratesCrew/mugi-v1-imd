// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {MugiReserveMath} from "./MugiReserveMath.sol";

/// @notice Fixed-cap crew ERC-20 with freely transferable balances and timestamp history.
/// @dev The entire reserve is created once for the constructor-bound hook. The
/// hook has no token privilege: transfers never call it, and any holder may burn
/// only their own balance. Official-pool fees and reserve releases live elsewhere.
contract MugiCrewToken is IERC20, IERC20Metadata, IERC20Errors {
    struct Checkpoint {
        uint64 timestamp;
        uint192 value;
    }

    string private _name;
    string private _symbol;
    address public immutable hook;
    uint8 public immutable characterId;
    uint256 public immutable initialSupply;
    uint256 public immutable reserveCap;
    uint256 private _totalSupply;
    mapping(address => uint256) private _balances;
    mapping(address => mapping(address => uint256)) private _allowances;
    mapping(address => Checkpoint[]) private _balanceHistory;
    Checkpoint[] private _supplyHistory;

    error InvalidCrewConfiguration();

    /// @dev No external calls or code-existence checks: the reserve holder may
    /// be a predetermined hook address whose runtime is deployed afterward.
    constructor(uint8 characterId_, address hook_, uint256 initialSupply_) {
        if (hook_ == address(0) || characterId_ >= 10) {
            revert InvalidCrewConfiguration();
        }
        string[10] memory names = ["Luffy", "Zoro", "Nami", "Usopp", "Sanji", "Chopper", "Robin", "Franky", "Brook", "Jinbe"];
        string[10] memory symbols = ["MLFY", "MZRO", "MNMI", "MUSP", "MSNJ", "MCHP", "MRBN", "MFRK", "MBRK", "MJNB"];
        _name = names[characterId_];
        _symbol = symbols[characterId_];
        characterId = characterId_;
        hook = hook_;
        initialSupply = initialSupply_;
        uint256 reserve = reserveFor(initialSupply_);
        reserveCap = reserve;
        _totalSupply = reserve;
        _balances[hook_] = reserve;
        _write(_balanceHistory[hook_], reserve);
        _write(_supplyHistory, reserve);
        emit Transfer(address(0), hook_, reserve);
    }

    /// @notice Finite reserve per crew; initialSupply is the initial pool/airdrop allocation, not this cap.
    /// @dev See MugiReserveMath for the bound and required game release limits.
    /// Unused reserves never count as player supply or circulating V2 inventory.
    function reserveFor(uint256 initialSupply_) public pure returns (uint256) {
        return MugiReserveMath.reserveFor(initialSupply_);
    }

    function name() external view returns (string memory) {
        return _name;
    }

    function symbol() external view returns (string memory) {
        return _symbol;
    }

    function decimals() external pure returns (uint8) {
        return 18;
    }

    function crewId() external view returns (uint8) {
        return characterId;
    }

    function totalSupply() external view returns (uint256) {
        return _totalSupply;
    }

    function balanceOf(address account) external view returns (uint256) {
        return _balances[account];
    }

    /// @notice Balance immediately before cutoff; all writes timestamped cutoff are excluded.
    /// @dev A future cutoff returns the latest balance and is not a final snapshot yet.
    function balanceBefore(address account, uint64 cutoff) external view returns (uint256) {
        return _before(_balanceHistory[account], cutoff);
    }

    /// @notice Supply immediately before cutoff, including earlier holder burns.
    function totalSupplyBefore(uint64 cutoff) external view returns (uint256) {
        return _before(_supplyHistory, cutoff);
    }

    function allowance(address owner, address spender) external view returns (uint256) {
        return _allowances[owner][spender];
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        if (spender == address(0)) revert ERC20InvalidSpender(address(0));
        _allowances[msg.sender][spender] = amount;
        emit Approval(msg.sender, spender, amount);
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        _transfer(msg.sender, to, amount);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        uint256 allowed = _allowances[from][msg.sender];
        if (allowed != type(uint256).max) {
            if (allowed < amount) revert ERC20InsufficientAllowance(msg.sender, allowed, amount);
            unchecked {
                _allowances[from][msg.sender] = allowed - amount;
            }
        }
        _transfer(from, to, amount);
        return true;
    }

    function burn(uint256 amount) external {
        uint256 balance = _balances[msg.sender];
        if (balance < amount) revert ERC20InsufficientBalance(msg.sender, balance, amount);
        if (amount != 0) {
            _balances[msg.sender] = balance - amount;
            _totalSupply -= amount;
            _write(_balanceHistory[msg.sender], balance - amount);
            _write(_supplyHistory, _totalSupply);
        }
        emit Transfer(msg.sender, address(0), amount);
    }

    function _transfer(address from, address to, uint256 amount) private {
        if (from == address(0)) revert ERC20InvalidSender(address(0));
        if (to == address(0)) revert ERC20InvalidReceiver(address(0));
        uint256 balance = _balances[from];
        if (balance < amount) revert ERC20InsufficientBalance(from, balance, amount);
        if (from != to && amount != 0) {
            _balances[from] = balance - amount;
            _balances[to] += amount;
            _write(_balanceHistory[from], balance - amount);
            _write(_balanceHistory[to], _balances[to]);
        }
        emit Transfer(from, to, amount);
    }

    function _write(Checkpoint[] storage history, uint256 value) private {
        uint64 timestamp = SafeCast.toUint64(block.timestamp);
        uint192 packed = SafeCast.toUint192(value);
        uint256 length = history.length;
        if (length != 0 && history[length - 1].timestamp == timestamp) history[length - 1].value = packed;
        else history.push(Checkpoint(timestamp, packed));
    }

    function _before(Checkpoint[] storage history, uint64 cutoff) private view returns (uint256) {
        uint256 low;
        uint256 high = history.length;
        while (low < high) {
            uint256 middle = low + (high - low) / 2;
            if (history[middle].timestamp < cutoff) low = middle + 1;
            else high = middle;
        }
        return low == 0 ? 0 : history[low - 1].value;
    }
}
