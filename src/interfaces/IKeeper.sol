// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

/// @notice The Keeper address a Signers contract exposes. Split out so the Distributor's public `keeper` variable
///         (declared in Signers) can satisfy `INutzDistributor.keeper()` through one shared base.
interface IKeeper {
    /// @return The scheduled operator: the only caller of the Keeper-gated actions.
    function keeper() external view returns (address);
}
