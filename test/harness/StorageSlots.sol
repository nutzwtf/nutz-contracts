// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {NutzDistributor} from "../../src/NutzDistributor.sol";

/// @dev Storage slots of the Distributor's and Converter's private state, for tests that write state directly
///      (`vm.store`) instead of reaching it through signatures and proofs: the symbolic suites need `funded`,
///      `carry`, `totals` and `claimed` to be free variables. Derived from `forge inspect <C> storageLayout`;
///      `test/unit/StorageSlots.t.sol` checks every helper against the public getters, so a layout change fails
///      there before it can misdirect a symbolic test.
library StorageSlots {
    // NutzDistributor: `Book epochBook` at 8 and `Book drawBook` at 16; a Book is
    // { mapping ledgers; mapping claimed; uint256 rootedThrough; uint256[5] carry } = 8 slots.
    uint256 internal constant EPOCH_BOOK = 8;
    uint256 internal constant DRAW_BOOK = 16;
    uint256 internal constant MIN_USDG_PER_ETH = 29;
    uint256 internal constant MAX_USDG_PER_ETH = 30;
    // NutzConverter
    uint256 internal constant OPS_CAP = 8;

    // A Ledger is { bytes32 root; uint256 rootPostedAt; bool skipped; uint256[5] funded; uint256[5] totals;
    // uint256[5] claimed } = 18 slots from its base.
    uint256 internal constant LEDGER_ROOT = 0;
    uint256 internal constant LEDGER_ROOT_POSTED_AT = 1;
    uint256 internal constant LEDGER_SKIPPED = 2;
    uint256 internal constant LEDGER_FUNDED = 3;
    uint256 internal constant LEDGER_TOTALS = 8;
    uint256 internal constant LEDGER_CLAIMED = 13;

    function book(NutzDistributor.Kind kind) internal pure returns (uint256) {
        return kind == NutzDistributor.Kind.Epoch ? EPOCH_BOOK : DRAW_BOOK;
    }

    /// @dev Base slot of `book.ledgers[id]`.
    function ledger(NutzDistributor.Kind kind, uint256 id) internal pure returns (uint256) {
        return uint256(keccak256(abi.encode(id, book(kind))));
    }

    function ledgerField(NutzDistributor.Kind kind, uint256 id, uint256 field) internal pure returns (bytes32) {
        return bytes32(ledger(kind, id) + field);
    }

    /// @dev `book.ledgers[id].funded[i]`, `.totals[i]`, `.claimed[i]`: `field` is one of the LEDGER_* array bases.
    function ledgerArray(NutzDistributor.Kind kind, uint256 id, uint256 field, uint256 i)
        internal
        pure
        returns (bytes32)
    {
        return bytes32(ledger(kind, id) + field + i);
    }

    /// @dev `book.claimed[id][account]`.
    function claimedFlag(NutzDistributor.Kind kind, uint256 id, address account) internal pure returns (bytes32) {
        return keccak256(abi.encode(account, keccak256(abi.encode(id, book(kind) + 1))));
    }

    function rootedThrough(NutzDistributor.Kind kind) internal pure returns (bytes32) {
        return bytes32(book(kind) + 2);
    }

    function carry(NutzDistributor.Kind kind, uint256 i) internal pure returns (bytes32) {
        return bytes32(book(kind) + 3 + i);
    }
}
