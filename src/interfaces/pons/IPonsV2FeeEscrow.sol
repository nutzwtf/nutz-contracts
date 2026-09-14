// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

/// @notice What the Converter needs from PonsV2FeeEscrow (0xd3AFEB2a57f70eF218Aa82451c51B2fb0416Ac9e, chain 4663):
///         its claimable native-ETH balance and the full-balance claim. Hand-written from the Sourcify-verified source.
interface IPonsV2FeeEscrow {
    /// @return The claimable native ETH balance of `recipient`.
    function balanceOf(address recipient) external view returns (uint256);

    /// @notice Pays the caller's entire claimable native ETH balance with `call` and full gas.
    ///         Reverts `NoBalance()` when the balance is zero.
    /// @return amount The amount paid.
    function claim() external returns (uint256 amount);
}
