// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @notice CREATE predictions for fresh, single-season factories.
/// @dev No constructor creates children. Fixed nonces 1..127 use one-byte canonical RLP.
library MugiIMDDeploymentAddresses {
    function child(address factory, uint8 nonce) internal pure returns (address) {
        require(factory != address(0) && nonce != 0 && nonce < 128, "invalid CREATE prediction");
        return address(uint160(uint256(keccak256(abi.encodePacked(hex"d694", factory, bytes1(nonce))))));
    }

    function crews(address factory) internal pure returns (address[10] memory tokens) {
        for (uint8 i; i < 10; ++i) tokens[i] = child(factory, i + 1);
    }
}
