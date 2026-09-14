// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

/// @notice What the Converter needs from Uniswap's SwapRouter02 (0xcaf681a66d020601342297493863e78c959e5cb2, chain 4663):
///         the multi-hop exact-input swap. Unlike the v3 SwapRouter, `ExactInputParams` carries no deadline.
interface ISwapRouter02 {
    struct ExactInputParams {
        bytes path; // tokenA ‖ fee ‖ tokenB ‖ … ; 20 + n × 23 bytes
        address recipient;
        uint256 amountIn;
        uint256 amountOutMinimum;
    }

    /// @notice Swaps `amountIn` of the first token in `path` for as much as possible of the last one.
    ///         Payable: when `msg.value == amountIn` and the path starts with `WETH9`, the router wraps the ETH itself.
    function exactInput(ExactInputParams calldata params) external payable returns (uint256 amountOut);

    /// @return The WETH the router wraps native ETH into.
    function WETH9() external view returns (address);
}
