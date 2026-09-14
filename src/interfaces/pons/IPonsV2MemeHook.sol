// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

/// @notice What the Converter needs from PonsV2MemeHook (0xE5e702641Ea86F4ae6cC3cDaeD2B886f976Be044, chain 4663) after
///         graduation. Hand-written from the Sourcify-verified source. Pool ids are v4 `PoolId`s, passed as bytes32;
///         a currency is the token address, or zero for native ETH.
interface IPonsV2MemeHook {
    /// @notice Converts pending memecoin fees to quote and pays the quote fees and creator tax into the fee escrow.
    ///         The launch creator may call it only when no memecoin fee or tax and no quote buyback is pending;
    ///         otherwise restricted to Pons's sweep operator.
    function sweepPoolFees(bytes32 poolId, uint256 minConversionQuoteOut, uint256 minBuybackTokensOut) external;

    /// @return amount Trade fees accrued in `currency` and not yet swept; includes the buyback earmark.
    function pendingFees(bytes32 poolId, address currency) external view returns (uint256 amount);

    /// @return amount Creator tax accrued in `currency` and not yet swept.
    function pendingCreatorTax(bytes32 poolId, address currency) external view returns (uint256 amount);

    /// @return amount The slice of `pendingFees` earmarked for buyback-and-lock.
    function pendingBuyback(bytes32 poolId, address currency) external view returns (uint256 amount);
}
