// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {IPonsV2BondingCurve} from "../../../src/interfaces/pons/IPonsV2BondingCurve.sol";
import {MockPonsEscrow} from "./MockPonsEscrow.sol";

/// @dev Stand-in for a pre-graduation PonsV2BondingCurve with an ETH quote. The test sets the pending fee and
///      tax balances and deals the curve the ETH behind them. `sweepFees` follows the real creator-side path:
///      only the creator fee recipient (the real curve's `deployer`) may call it; the protocol keeps its share of
///      the fees; the rest plus the whole tax is credited to the creator's escrow balance. A switch makes it
///      revert instead, standing in for the buyback case the creator is not allowed to sweep.
contract MockPonsCurve is IPonsV2BondingCurve {
    error NotFeeSweepOperator();
    error SweepReverts();

    uint256 private constant BPS = 10_000;

    MockPonsEscrow public immutable ESCROW;
    address public immutable CREATOR;

    uint256 public quoteFeeBalance;
    uint256 public creatorTaxBalance;
    uint256 public protocolFeeShareBps;
    bool public sweepReverts;

    constructor(MockPonsEscrow escrow, address creator) {
        ESCROW = escrow;
        CREATOR = creator;
    }

    receive() external payable {}

    function setBalances(uint256 fee, uint256 tax) external {
        quoteFeeBalance = fee;
        creatorTaxBalance = tax;
    }

    function setProtocolFeeShareBps(uint256 bps) external {
        protocolFeeShareBps = bps;
    }

    function setSweepReverts(bool r) external {
        sweepReverts = r;
    }

    function sweepFees(uint256) external {
        if (msg.sender != CREATOR) revert NotFeeSweepOperator();
        if (sweepReverts) revert SweepReverts();
        uint256 fee = quoteFeeBalance;
        uint256 tax = creatorTaxBalance;
        if (fee == 0 && tax == 0) return;
        quoteFeeBalance = 0;
        creatorTaxBalance = 0;
        ESCROW.credit{value: fee - fee * protocolFeeShareBps / BPS + tax}(CREATOR);
    }
}
