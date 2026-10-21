// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {MugiIMDLedger} from "./modules/MugiIMDLedger.sol";
import {MugiIMDBuybacks} from "./modules/MugiIMDBuybacks.sol";
import {MugiIMDPriceOracle} from "./modules/MugiIMDPriceOracle.sol";
import {MugiIMDDeploymentAddresses} from "./libraries/MugiIMDDeploymentAddresses.sol";

/// @notice Creates one fully constructor-configured accounting graph.
/// @dev No assets, hook authority, setters or postdeployment binding are held here.
contract MugiIMDAccountingFactory {
    struct Modules {
        MugiIMDLedger ledger;
        MugiIMDBuybacks budgets;
        MugiIMDPriceOracle prices;
    }
    address public immutable owner;
    Modules public modules;

    error Unauthorized();
    error InvalidConfiguration();
    error AlreadyDeployed();
    event ModulesCreated(address indexed hook, address ledger, address budgets, address prices);

    constructor(address owner_) {
        if (owner_ == address(0)) revert InvalidConfiguration();
        owner = owner_;
    }

    function predictModules() public view returns (Modules memory result) {
        result.ledger = MugiIMDLedger(MugiIMDDeploymentAddresses.child(address(this), 1));
        result.budgets = MugiIMDBuybacks(MugiIMDDeploymentAddresses.child(address(this), 2));
        result.prices = MugiIMDPriceOracle(MugiIMDDeploymentAddresses.child(address(this), 3));
    }

    function deployForHook(MugiIMDLedger.Configuration calldata c) external returns (Modules memory result) {
        if (msg.sender != owner) revert Unauthorized();
        if (address(modules.ledger) != address(0)) revert AlreadyDeployed();
        result.ledger = new MugiIMDLedger(c);
        result.budgets = new MugiIMDBuybacks(c.hook);
        result.prices = new MugiIMDPriceOracle(c.hook);
        Modules memory predicted = predictModules();
        assert(address(result.ledger) == address(predicted.ledger));
        assert(address(result.budgets) == address(predicted.budgets));
        assert(address(result.prices) == address(predicted.prices));
        modules = result;
        emit ModulesCreated(c.hook, address(result.ledger), address(result.budgets), address(result.prices));
    }
}
