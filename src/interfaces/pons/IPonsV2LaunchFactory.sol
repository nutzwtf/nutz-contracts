// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

/// @notice What the Converter needs from PonsV2LaunchFactory (0x7eD598BcEf8bd9Edd8C97A195C6d13f40801EC7e, chain 4663):
///         the launch record of a token. Hand-written from the Sourcify-verified source; field order is ABI order.
interface IPonsV2LaunchFactory {
    /// @dev `phase` is Pons's `GraduationPhase` enum: 0 NotGraduated, 1 Swept, 2 PoolCreated, 3 Rescued.
    struct LaunchedToken {
        address token;
        address curve;
        address deployer;
        address creatorFeeRecipient;
        address pairToken; // zero for an ETH-quoted launch
        uint256 graduationThreshold;
        uint24 poolFee;
        int24 tickSpacing;
        uint16 creatorTaxBps;
        bool buybackEnabled;
        uint8 phase;
        uint256 sweptQuote;
        uint256 sweptTokens;
        uint256 sweptAt;
        bool exists;
    }

    /// @return The launch record of `token`; every field zero and `exists == false` for a token never launched.
    function getLaunchedToken(address token) external view returns (LaunchedToken memory);
}
