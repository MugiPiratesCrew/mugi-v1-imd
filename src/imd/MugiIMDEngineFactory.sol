// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {MugiIMDV4Engine} from "./modules/MugiIMDV4Engine.sol";
import {MugiIMDDeploymentAddresses} from "./libraries/MugiIMDDeploymentAddresses.sol";

/// @notice Creates one complete engine for an already predicted hook address.
contract MugiIMDEngineFactory {
    address public immutable owner;
    MugiIMDV4Engine public engine;

    error Unauthorized();
    error InvalidConfiguration();
    error AlreadyDeployed();
    event EngineCreated(address indexed hook, address indexed engine, address indexed manager);

    constructor(address owner_) {
        if (owner_ == address(0)) revert InvalidConfiguration();
        owner = owner_;
    }

    function predictEngine() public view returns (address) {
        return MugiIMDDeploymentAddresses.child(address(this), 1);
    }

    function deployForHook(address futureHook, IPoolManager manager) external returns (MugiIMDV4Engine result) {
        if (msg.sender != owner) revert Unauthorized();
        if (address(engine) != address(0)) revert AlreadyDeployed();
        result = new MugiIMDV4Engine(futureHook, manager);
        assert(address(result) == predictEngine());
        engine = result;
        emit EngineCreated(futureHook, address(result), address(manager));
    }
}
