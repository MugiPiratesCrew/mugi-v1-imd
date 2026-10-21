// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {MugiCrewToken} from "../../src/game/MugiCrewToken.sol";

/// @notice Full-code crew token for the IMD route; no proxy or delegatecall.
/// @dev The base constructor disables the external initializer. This constructor
/// uses the shared internal setup once and keeps minting restricted to the hook.
contract MugiIMDCrewToken is MugiCrewToken {
    constructor(string memory name_, string memory symbol_, uint8 crew_, address hook_) {
        _initializeCrew(name_, symbol_, crew_, hook_);
    }
}
