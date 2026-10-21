// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {MugiCrewToken} from "../../src/game/MugiCrewToken.sol";

/// @notice Full-code crew token for the IMD route; no proxy or delegatecall.
/// @dev All token configuration occurs in the base constructor. No external
/// initializer exists; minting remains restricted to the game hook.
contract MugiIMDCrewToken is MugiCrewToken {
    constructor(string memory name_, string memory symbol_, uint8 crew_, address hook_)
        MugiCrewToken(name_, symbol_, crew_, hook_)
    {}
}
