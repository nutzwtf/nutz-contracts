// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {MockERC20} from "./MockERC20.sol";

/// @dev A token whose `transfer` reports failure by returning `false` instead of reverting, the pre-0.4.22 style
///      `_tryTransfer` handles beside reverts and empty returns.
contract MockFalseReturnERC20 is MockERC20 {
    bool public refusing;

    constructor() MockERC20("FALSE", "FALSE") {}

    function setRefusing(bool r) external {
        refusing = r;
    }

    function transfer(address to, uint256 value) public override returns (bool) {
        if (refusing) return false;
        return super.transfer(to, value);
    }
}

/// @dev A token whose `transfer` returns no data at all (USDT-style). Written out by hand rather than derived from
///      MockERC20 because Solidity cannot override `transfer` with a different return type; only the IERC20
///      surface the Distributor uses.
contract MockNoReturnERC20 {
    mapping(address account => uint256) public balanceOf;
    mapping(address owner => mapping(address spender => uint256)) public allowance;

    function mint(address to, uint256 value) external {
        balanceOf[to] += value;
    }

    function approve(address spender, uint256 value) external returns (bool) {
        allowance[msg.sender][spender] = value;
        return true;
    }

    function transferFrom(address from, address to, uint256 value) external returns (bool) {
        allowance[from][msg.sender] -= value;
        balanceOf[from] -= value;
        balanceOf[to] += value;
        return true;
    }

    function transfer(address to, uint256 value) external {
        balanceOf[msg.sender] -= value;
        balanceOf[to] += value;
    }
}
