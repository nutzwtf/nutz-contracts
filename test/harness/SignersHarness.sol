// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {Signers} from "../../src/Signers.sol";

/// @dev Minimal concrete Signers so the abstract contract can be tested through its public seams.
contract SignersHarness is Signers {
    bytes32 private constant PING_TYPEHASH = keccak256("Ping(uint256 value,uint256 nonce)");

    uint256 public lastPing;
    uint256 public keeperCalls;

    constructor(address[3] memory signers_, address keeper_) Signers("SignersHarness", signers_, keeper_) {}

    /// @dev An instant 2-of-3 action, to test verification independently of any real action.
    function ping(uint256 value, bytes calldata sig1, bytes calldata sig2) external {
        _require2of3(keccak256(abi.encode(PING_TYPEHASH, value, nonce)), sig1, sig2);
        lastPing = value;
    }

    function keeperOnly() external onlyKeeper {
        keeperCalls++;
    }
}
