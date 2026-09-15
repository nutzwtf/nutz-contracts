// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {IKeeper} from "../../src/interfaces/IKeeper.sol";

/// @dev Stand-in for the Distributor as the Draw contract sees it: the Keeper (settable, so a rotation can be
///      played) and the current Unix week, computed the way the real Distributor does.
contract MockDistributor is IKeeper {
    uint256 public constant WEEK = 604_800;

    address public override keeper;

    constructor(address keeper_) {
        keeper = keeper_;
    }

    function setKeeper(address keeper_) external {
        keeper = keeper_;
    }

    function currentDraw() external view returns (uint256) {
        return block.timestamp / WEEK;
    }
}
