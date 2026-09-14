// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

/// @notice What the Converter needs from the Distributor: the two funding entry points, the Acorn pull and the
///         Signer-set floor on the ETH→USDG rate.
interface INutzDistributor {
    /// @notice Records one Sweep's Reward Tokens for `epochId` and pulls them from the caller.
    function notifyEpochFunding(uint256 epochId, uint256[5] calldata amounts, uint256 acornUsdg) external;

    /// @notice Releases the whole Acorn pool to the caller for conversion, once per draw.
    function pullAcorn(uint256 drawId) external;

    /// @notice Records the converted Acorn pool for `drawId` and pulls it from the caller.
    function notifyDrawFunding(uint256 drawId, uint256[5] calldata amounts) external;

    /// @return Lower bound on raw USDG (6 decimals) per 1 ETH; the Converter's floor for the ETH→USDG Leg.
    function minUsdgPerEth() external view returns (uint256);
}
