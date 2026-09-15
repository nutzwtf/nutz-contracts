// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {IKeeper} from "./IKeeper.sol";

/// @notice What the Converter and the Draw contract need from the Distributor: the two funding entry points, the
///         Acorn pull, the Signer-set floor on the ETH→USDG rate, the current Unix week and, through IKeeper, the
///         Keeper.
interface INutzDistributor is IKeeper {
    /// @notice Records one Sweep's Reward Tokens for `epochId` and pulls them from the caller.
    function notifyEpochFunding(uint256 epochId, uint256[5] calldata amounts, uint256 acornUsdg) external;

    /// @notice Releases the whole Acorn pool to the caller for conversion, once per draw.
    function pullAcorn(uint256 drawId) external;

    /// @notice Records the converted Acorn pool for `drawId` and pulls it from the caller.
    function notifyDrawFunding(uint256 drawId, uint256[5] calldata amounts) external;

    /// @return Lower bound on raw USDG (6 decimals) per 1 ETH; the Converter's floor for the ETH→USDG Leg.
    function minUsdgPerEth() external view returns (uint256);

    /// @return The Unix week `block.timestamp` falls in; a Draw Root can only be posted for an earlier week.
    function currentDraw() external view returns (uint256);
}
