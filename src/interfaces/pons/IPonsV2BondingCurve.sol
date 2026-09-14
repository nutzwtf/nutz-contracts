// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

/// @notice What the Converter needs from a PonsV2BondingCurve before graduation. Hand-written from the
///         Sourcify-verified source (deployed per launch by the factory at 0x7eD598BcEf8bd9Edd8C97A195C6d13f40801EC7e).
interface IPonsV2BondingCurve {
    /// @notice Pays the pending quote fees and creator tax into the fee escrow. Callable by the launch deployer
    ///         only while no buyback quote is pending; otherwise restricted to Pons's sweep operator.
    /// @param minBuybackTokensOut Slippage bound for the buyback swap; irrelevant when buyback is off.
    function sweepFees(uint256 minBuybackTokensOut) external;

    /// @return Pending quote-asset trade fees not yet swept to the escrow.
    function quoteFeeBalance() external view returns (uint256);

    /// @return Pending quote-asset creator tax not yet swept to the escrow.
    function creatorTaxBalance() external view returns (uint256);
}
