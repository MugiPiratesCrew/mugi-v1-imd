// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {Initializable} from "@openzeppelin/contracts/proxy/utils/Initializable.sol";

interface IMugiCrewTokenHook {
    function beforeTokenTransfer(uint8 tokenId, address from, address to, uint256 amount) external;
    function afterTokenTransfer(uint8 tokenId, address from, address to, uint256 amount) external;
}

/// @notice Crew ERC-20 with immutable-after-initialization game authority. Fees
/// live in the official pool hook, never in ERC-20 transfers.
contract MugiCrewToken is IERC20, IERC20Metadata, IERC20Errors, Initializable {
    string private _name;
    string private _symbol;
    address public hook;
    uint8 public characterId;
    uint256 private _totalSupply;
    mapping(address => uint256) private _balances;
    mapping(address => mapping(address => uint256)) private _allowances;

    error NotHook();
    error InvalidCrewConfiguration();

    modifier onlyHook() {
        if (msg.sender != hook) revert NotHook();
        _;
    }

    constructor() {
        _disableInitializers();
    }

    function initialize(string calldata name_, string calldata symbol_, uint8 characterId_, address hook_)
        external
        initializer
    {
        _initializeCrew(name_, symbol_, characterId_, hook_);
    }

    /// @dev Shared one-time setup for the clone route and constructor-initialized
    /// full token deployments used by the IMD adapter. No public mint authority.
    function _initializeCrew(string memory name_, string memory symbol_, uint8 characterId_, address hook_) internal {
        if (hook != address(0)) revert InvalidCrewConfiguration();
        if (hook_.code.length == 0 || characterId_ >= 10 || bytes(name_).length == 0 || bytes(symbol_).length == 0) {
            revert InvalidCrewConfiguration();
        }
        _name = name_;
        _symbol = symbol_;
        characterId = characterId_;
        hook = hook_;
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

    function mint(address account, uint256 amount) external onlyHook {
        if (account == address(0)) revert ERC20InvalidReceiver(address(0));
        _update(address(0), account, amount);
    }

    function burn(address account, uint256 amount) external onlyHook {
        if (account == address(0)) revert ERC20InvalidSender(address(0));
        _update(account, address(0), amount);
    }

    function _transfer(address from, address to, uint256 amount) private {
        if (from == address(0)) revert ERC20InvalidSender(address(0));
        if (to == address(0)) revert ERC20InvalidReceiver(address(0));
        _update(from, to, amount);
    }

    function _update(address from, address to, uint256 amount) private {
        IMugiCrewTokenHook(hook).beforeTokenTransfer(characterId, from, to, amount);
        if (from == address(0)) {
            _totalSupply += amount;
        } else {
            uint256 balance = _balances[from];
            if (balance < amount) revert ERC20InsufficientBalance(from, balance, amount);
            unchecked {
                _balances[from] = balance - amount;
            }
        }
        if (to == address(0)) {
            _totalSupply -= amount;
        } else {
            _balances[to] += amount;
        }
        emit Transfer(from, to, amount);
        IMugiCrewTokenHook(hook).afterTokenTransfer(characterId, from, to, amount);
    }
}
