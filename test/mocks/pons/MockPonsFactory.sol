// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {IPonsV2LaunchFactory} from "../../../src/interfaces/pons/IPonsV2LaunchFactory.sol";

/// @dev Stand-in for PonsV2LaunchFactory: the test sets the launch record a token would have.
///      An unset token reads back with `exists == false`, as on the real factory.
contract MockPonsFactory is IPonsV2LaunchFactory {
    mapping(address => LaunchedToken) private launches;

    function setLaunchedToken(address token, LaunchedToken calldata launch) external {
        launches[token] = launch;
    }

    function getLaunchedToken(address token) external view returns (LaunchedToken memory) {
        return launches[token];
    }
}
