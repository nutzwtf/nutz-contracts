// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

/// @notice What the Converter needs from WETH9 (0x0Bd7D308f8E1639FAb988df18A8011f41EAcAD73, chain 4663): unwrapping
///         what a v3 Leg delivers as WETH when the Leg's output is ETH.
interface IWETH9 {
    /// @notice Burns `amount` WETH from the caller and pays it the same amount of ETH.
    function withdraw(uint256 amount) external;
}
