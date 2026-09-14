// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {INutzDraw} from "../../src/interfaces/INutzDraw.sol";

/// @dev Stand-in for NutzDraw: the test sets the seed a draw would get from its Beacon fulfilment.
contract MockNutzDraw is INutzDraw {
    mapping(uint256 => bytes32) private seeds;

    function setSeed(uint256 drawId, bytes32 seed) external {
        seeds[drawId] = seed;
    }

    function seedOf(uint256 drawId) external view returns (bytes32) {
        return seeds[drawId];
    }
}
