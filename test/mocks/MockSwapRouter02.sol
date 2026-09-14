// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ISwapRouter02} from "../../src/interfaces/ISwapRouter02.sol";

/// @dev Stand-in for SwapRouter02's `exactInput`. Swaps the first token of the path for the last at a fixed rate
///      per output token (`amountOut = amountIn × rate / 1e18`), paid from the router's own inventory, which the
///      test seeds. Native ETH is accepted as input when the path starts with `WETH9` and `msg.value == amountIn`,
///      as on the real router; otherwise the input is pulled with `transferFrom` and the allowance the caller had
///      granted is recorded per input token, so tests can check exact approvals. WETH output is delivered as WETH,
///      never unwrapped. A per-output-token switch makes the swap revert, standing in for any failure inside the Venue.
contract MockSwapRouter02 is ISwapRouter02 {
    error NoRate(address tokenOut);
    error VenueReverts(address tokenOut);
    error WrongValue();
    error BadPath();

    address private immutable WETH;

    mapping(address => uint256) public rate; // output units per 1e18 input units, keyed by output token
    mapping(address => bool) public reverts; // keyed by output token
    mapping(address => uint256) public allowanceSeen; // keyed by input token; the allowance at the last pull

    constructor(address weth) {
        WETH = weth;
    }

    receive() external payable {}

    // forge-lint: disable-next-line(mixed-case-function)
    function WETH9() external view returns (address) {
        return WETH;
    }

    function setRate(address tokenOut, uint256 r) external {
        rate[tokenOut] = r;
    }

    function setReverts(address tokenOut, bool r) external {
        reverts[tokenOut] = r;
    }

    function exactInput(ExactInputParams calldata params) external payable returns (uint256 amountOut) {
        bytes calldata p = params.path;
        if (p.length < 43 || (p.length - 20) % 23 != 0) revert BadPath();
        address tokenIn = address(bytes20(p[:20]));
        address tokenOut = address(bytes20(p[p.length - 20:]));

        if (reverts[tokenOut]) revert VenueReverts(tokenOut);
        uint256 r = rate[tokenOut];
        if (r == 0) revert NoRate(tokenOut);

        if (msg.value > 0) {
            if (tokenIn != WETH || msg.value != params.amountIn) revert WrongValue();
        } else {
            allowanceSeen[tokenIn] = IERC20(tokenIn).allowance(msg.sender, address(this));
            IERC20(tokenIn).transferFrom(msg.sender, address(this), params.amountIn);
        }

        amountOut = params.amountIn * r / 1e18;
        require(amountOut >= params.amountOutMinimum, "Too little received"); // the real router's string
        IERC20(tokenOut).transfer(params.recipient, amountOut);
    }
}
