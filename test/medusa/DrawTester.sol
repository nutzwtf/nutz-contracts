// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {CryticAsserts} from "chimera/CryticAsserts.sol";
import {DrawTargets} from "./DrawTargets.sol";

/// @dev Medusa's entry point for the Draw: `medusa fuzz --target-contracts DrawTester`. The only fuzzer besides
///      forge that can run this one: its geth ships the EIP-2537 precompiles the verifier calls.
contract DrawTester is DrawTargets, CryticAsserts {
    /// @dev forge-std's marker. forge's size report (`forge build --sizes`) exempts a contract whose ABI has `IS_TEST` or
    ///      `IS_SCRIPT`; without it the tester counts as deployable code and the Distributor's and the Converter's
    ///      trip the EIP-170 gate. Medusa disables the size check (`codeSizeCheckDisabled`) and never calls a pure
    ///      function (`testViewMethods: false`); the forge wrapper targets explicit selectors.
    function IS_TEST() external pure returns (bool) {
        return true;
    }

    constructor() {
        setup();
    }
}
