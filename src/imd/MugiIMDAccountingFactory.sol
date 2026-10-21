// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {MugiIMDLedger} from "./modules/MugiIMDLedger.sol";
import {MugiIMDBuybacks} from "./modules/MugiIMDBuybacks.sol";
import {MugiIMDPriceOracle} from "./modules/MugiIMDPriceOracle.sol";

/// @notice Deploys immutable, hook-authorized accounting modules after hook creation.
/// @dev No assets or admin rights are held here. Anyone may create the canonical
/// set for a hook; only that hook can mutate it. Hook owner binds the set once.
contract MugiIMDAccountingFactory {
    struct Modules {
        MugiIMDLedger ledger;
        MugiIMDBuybacks budgets;
        MugiIMDPriceOracle prices;
    }
    mapping(address => Modules) public modules;
    error InvalidHook();
    event ModulesCreated(address indexed hook, address ledger, address budgets, address prices);

    function deployForHook(address hook) external returns (Modules memory result) {
        if (hook.code.length == 0) revert InvalidHook();
        result = modules[hook];
        if (address(result.ledger) != address(0)) return result;
        bytes32 salt = bytes32(uint256(uint160(hook)));
        result.ledger = new MugiIMDLedger{salt: salt}(hook);
        result.budgets = new MugiIMDBuybacks{salt: salt}(hook);
        result.prices = new MugiIMDPriceOracle{salt: salt}(hook);
        modules[hook] = result;
        emit ModulesCreated(hook, address(result.ledger), address(result.budgets), address(result.prices));
    }
}
