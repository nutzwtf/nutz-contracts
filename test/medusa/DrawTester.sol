// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {CryticAsserts} from "chimera/CryticAsserts.sol";
import {DrawTargets} from "./DrawTargets.sol";

/// @dev Medusa's entry point for the Draw: `medusa fuzz --target-contracts DrawTester`. The only fuzzer besides
///      forge that can run this one: its geth ships the EIP-2537 precompiles the verifier calls.
contract DrawTester is DrawTargets, CryticAsserts {
    constructor() {
        setup();
    }
}
