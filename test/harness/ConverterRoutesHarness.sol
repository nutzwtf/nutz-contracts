// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {NutzConverter} from "../../src/NutzConverter.sol";

/// @dev Exposes the Converter's internal Leg runner so the Route validation and the Venue adapters can be tested
///      one Leg at a time, without a Sweep around them.
contract ConverterRoutesHarness is NutzConverter {
    constructor(Params memory p) NutzConverter(p) {}

    function runLeg(Leg leg, Route calldata route, uint256 amountIn)
        external
        returns (bool ok, uint256 amountOut, bytes memory reason)
    {
        return _runLeg(leg, route, amountIn);
    }

    function priceLimits() external pure returns (uint160 down, uint160 up) {
        return (V4_PRICE_LIMIT_DOWN, V4_PRICE_LIMIT_UP);
    }

    function runLegStrict(Leg leg, Route calldata route, uint256 amountIn) external returns (uint256 amountOut) {
        return _runLegStrict(leg, route, amountIn);
    }
}
