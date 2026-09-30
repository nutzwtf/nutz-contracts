// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ISwapRouter02} from "../../src/interfaces/ISwapRouter02.sol";

/// @dev A `SwapRouter02` stand-in that pays a preset amount of the path's output token, whatever the input. For the
///      symbolic suites: `MockSwapRouter02` prices at `amountIn * rate / 1e18`, and that division is what the solver
///      cannot see through when the amount in is symbolic; here the amount out is a free variable of its own.
///      Not a full `ISwapRouter02`: only `WETH9()` and `exactInput`, which is all the Converter calls. Meant to be
///      `vm.etch`ed over the fixture's router, so the Converter's immutable router address holds.
contract MockFixedOutRouter {
    address public WETH9;
    uint256 public amountOut;

    function set(address weth, uint256 out) external {
        WETH9 = weth;
        amountOut = out;
    }

    function exactInput(ISwapRouter02.ExactInputParams calldata params) external payable returns (uint256) {
        bytes calldata p = params.path;
        address tokenOut = address(bytes20(p[p.length - 20:]));
        IERC20(tokenOut).transfer(params.recipient, amountOut);
        return amountOut;
    }
}
