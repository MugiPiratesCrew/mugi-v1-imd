// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {MugiIMDCrewToken} from "./MugiIMDCrewToken.sol";

/// @notice Deterministic full-code ten-token deployment for the IMD route.
/// @dev No implementation contract or proxy is used. A duplicate request returns
/// the same set, so third parties cannot change an owner's predicted crew set.
contract MugiIMDCrewFactory {
    mapping(address hook => mapping(uint256 seasonId => address[10] tokens)) private _crewSets;

    error InvalidHook();
    event CrewSetDeployed(address indexed hook, uint256 indexed seasonId, address[10] tokens);

    function deployCrewSet(address hook, uint256 seasonId) external returns (address[10] memory tokens) {
        if (hook.code.length == 0) revert InvalidHook();
        tokens = _crewSets[hook][seasonId];
        if (tokens[0] != address(0)) return tokens;
        (string[10] memory names, string[10] memory symbols) = _metadata();
        for (uint8 crew; crew < 10; ++crew) {
            tokens[crew] = address(
                new MugiIMDCrewToken{salt: _salt(hook, seasonId, crew)}(names[crew], symbols[crew], crew, hook)
            );
        }
        _crewSets[hook][seasonId] = tokens;
        emit CrewSetDeployed(hook, seasonId, tokens);
    }

    function crewSet(address hook, uint256 seasonId) external view returns (address[10] memory) {
        return _crewSets[hook][seasonId];
    }

    function predictCrewSet(address hook, uint256 seasonId) external view returns (address[10] memory tokens) {
        (string[10] memory names, string[10] memory symbols) = _metadata();
        for (uint8 crew; crew < 10; ++crew) {
            bytes32 initHash = keccak256(
                abi.encodePacked(
                    type(MugiIMDCrewToken).creationCode, abi.encode(names[crew], symbols[crew], crew, hook)
                )
            );
            tokens[crew] = address(
                uint160(
                    uint256(
                        keccak256(abi.encodePacked(bytes1(0xff), address(this), _salt(hook, seasonId, crew), initHash))
                    )
                )
            );
        }
    }

    function _metadata() private pure returns (string[10] memory names, string[10] memory symbols) {
        names = ["Luffy", "Zoro", "Nami", "Usopp", "Sanji", "Chopper", "Robin", "Franky", "Brook", "Jinbe"];
        symbols = ["MLFY", "MZRO", "MNMI", "MUSP", "MSNJ", "MCHP", "MRBN", "MFRK", "MBRK", "MJNB"];
    }

    function _salt(address hook, uint256 seasonId, uint8 crew) private pure returns (bytes32) {
        return keccak256(abi.encode("MUGI_IMD_CREW", hook, seasonId, crew));
    }
}
