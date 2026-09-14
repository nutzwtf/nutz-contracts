// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {IPonsV2MemeHook} from "../../../src/interfaces/pons/IPonsV2MemeHook.sol";
import {MockPonsEscrow} from "./MockPonsEscrow.sol";

/// @dev Stand-in for PonsV2MemeHook's fee side for ETH-quoted pools. The test registers a pool with its memecoin
///      and creator, sets the pending amounts per currency (zero address = ETH) and deals the hook the ETH behind
///      them. `sweepPoolFees` follows the real creator-side path: only the creator may call it; it reverts
///      `InternalSwapRequiresOperator` while a memecoin fee or tax or an ETH buyback is pending (the real
///      `_requiresTrustedOperator`); otherwise the protocol keeps its share of the ETH fees and the rest plus the
///      whole tax is credited to the creator's escrow balance.
contract MockPonsHook is IPonsV2MemeHook {
    error UnknownPool();
    error NotFeeSweepOperator();
    error InternalSwapRequiresOperator();

    struct Launch {
        address memecoin;
        address creator;
        bool registered;
    }

    address private constant NATIVE = address(0);
    uint256 private constant BPS = 10_000;

    MockPonsEscrow public immutable ESCROW;

    uint256 public protocolFeeShareBps;
    mapping(bytes32 => Launch) public launches;
    mapping(bytes32 => mapping(address => uint256)) public pendingFees;
    mapping(bytes32 => mapping(address => uint256)) public pendingCreatorTax;
    mapping(bytes32 => mapping(address => uint256)) public pendingBuyback;

    constructor(MockPonsEscrow escrow) {
        ESCROW = escrow;
    }

    receive() external payable {}

    function register(bytes32 poolId, address memecoin, address creator) external {
        launches[poolId] = Launch({memecoin: memecoin, creator: creator, registered: true});
    }

    function setProtocolFeeShareBps(uint256 bps) external {
        protocolFeeShareBps = bps;
    }

    function setPending(bytes32 poolId, address currency, uint256 fees, uint256 tax, uint256 buyback) external {
        pendingFees[poolId][currency] = fees;
        pendingCreatorTax[poolId][currency] = tax;
        pendingBuyback[poolId][currency] = buyback;
    }

    function sweepPoolFees(bytes32 poolId, uint256, uint256) external {
        Launch memory info = launches[poolId];
        if (!info.registered) revert UnknownPool();
        if (msg.sender != info.creator) revert NotFeeSweepOperator();
        if (
            pendingFees[poolId][info.memecoin] != 0 || pendingCreatorTax[poolId][info.memecoin] != 0
                || pendingBuyback[poolId][NATIVE] != 0
        ) revert InternalSwapRequiresOperator();

        uint256 fee = pendingFees[poolId][NATIVE];
        uint256 tax = pendingCreatorTax[poolId][NATIVE];
        if (fee == 0 && tax == 0) return;
        pendingFees[poolId][NATIVE] = 0;
        pendingCreatorTax[poolId][NATIVE] = 0;
        ESCROW.credit{value: fee - fee * protocolFeeShareBps / BPS + tax}(info.creator);
    }
}
