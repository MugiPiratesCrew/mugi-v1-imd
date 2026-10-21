// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {MugiIMDCrewToken} from "./MugiIMDCrewToken.sol";
import {MugiIMDDeploymentAddresses} from "./libraries/MugiIMDDeploymentAddresses.sol";

/// @notice Owner-bound, single-season creation of ten fully configured tokens.
/// @dev CREATE nonces 1..10 are independent of the future hook's address and
/// initcode, breaking the constructor-dependency cycle without an initializer.
contract MugiIMDCrewFactory {
    address public immutable owner;
    address public hook;
    address[10] public tokens;

    error Unauthorized();
    error InvalidConfiguration();
    error AlreadyDeployed();
    event CrewSetDeployed(address indexed hook, uint256 initialSupply, address[10] tokens);

    constructor(address owner_) {
        if (owner_ == address(0)) revert InvalidConfiguration();
        owner = owner_;
    }

    function predictCrewSet() public view returns (address[10] memory) {
        return MugiIMDDeploymentAddresses.crews(address(this));
    }

    function deployCrewSet(address futureHook, uint256 initialSupply) external returns (address[10] memory result) {
        if (msg.sender != owner) revert Unauthorized();
        if (hook != address(0)) revert AlreadyDeployed();
        if (futureHook == address(0)) revert InvalidConfiguration();
        hook = futureHook;
        for (uint8 crew; crew < 10; ++crew) {
            result[crew] = address(new MugiIMDCrewToken(crew, futureHook, initialSupply));
            assert(result[crew] == MugiIMDDeploymentAddresses.child(address(this), crew + 1));
        }
        tokens = result;
        emit CrewSetDeployed(futureHook, initialSupply, result);
    }

    function allTokens() external view returns (address[10] memory) { return tokens; }
}
