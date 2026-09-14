// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

/// @notice What the Distributor needs from the Draw contract: the seed of a fulfilled Acorn Draw.
interface INutzDraw {
    /// @return seed keccak256 of the drand signature for the committed round; zero until fulfilled.
    function seedOf(uint256 drawId) external view returns (bytes32 seed);
}
