// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {MugiCrewToken} from "../../src/game/MugiCrewToken.sol";

/// @notice Full-code crew token for the IMD route; no proxy or delegatecall.
/// @dev Configuration and the only mint happen in the base constructor.
/// Neither an initializer nor a privileged mint/freeze/burn capability exists.
contract MugiIMDCrewToken is MugiCrewToken {
    constructor(uint8 crew_, address hook_, uint256 initialSupply_)
        MugiCrewToken(crew_, hook_, initialSupply_)
    {}
}
