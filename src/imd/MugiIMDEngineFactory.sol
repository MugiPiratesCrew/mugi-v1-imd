// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {MugiIMDV4Engine} from "./modules/MugiIMDV4Engine.sol";

interface IMugiEngineHook {
    function poolManager() external view returns (IPoolManager);
}

/// @notice Creates one immutable LP engine per hook. Anyone may create the canonical instance.
/// @dev Manager is read from the hook to prevent a public caller poisoning its factory entry.
contract MugiIMDEngineFactory {
    mapping(address => MugiIMDV4Engine) public engines;

    error InvalidHook();
    error InvalidManager();
    event EngineCreated(address indexed hook, address indexed engine, address indexed manager);

    function deployForHook(address hook, IPoolManager manager) external returns (MugiIMDV4Engine engine) {
        if (hook.code.length == 0) revert InvalidHook();
        if (address(manager).code.length == 0 || address(IMugiEngineHook(hook).poolManager()) != address(manager)) {
            revert InvalidManager();
        }
        engine = engines[hook];
        if (address(engine) != address(0)) return engine;
        engine = new MugiIMDV4Engine{salt: bytes32(uint256(uint160(hook)))}(hook, manager);
        engines[hook] = engine;
        emit EngineCreated(hook, address(engine), address(manager));
    }
}
