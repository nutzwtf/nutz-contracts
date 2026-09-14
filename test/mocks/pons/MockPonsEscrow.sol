// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {IPonsV2FeeEscrow} from "../../../src/interfaces/pons/IPonsV2FeeEscrow.sol";

/// @dev Stand-in for PonsV2FeeEscrow's native-ETH side: anyone credits a recipient with the ETH they attach;
///      the recipient claims its whole balance, paid with `call` and full gas, exactly like the real escrow.
contract MockPonsEscrow is IPonsV2FeeEscrow {
    error NoBalance();
    error TransferFailed();

    mapping(address => uint256) public balanceOf;

    function credit(address recipient) external payable {
        balanceOf[recipient] += msg.value;
    }

    function claim() external returns (uint256 amount) {
        amount = balanceOf[msg.sender];
        if (amount == 0) revert NoBalance();
        balanceOf[msg.sender] = 0;
        (bool sent,) = payable(msg.sender).call{value: amount}("");
        if (!sent) revert TransferFailed();
    }
}
