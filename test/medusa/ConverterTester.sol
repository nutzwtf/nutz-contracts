// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {CryticAsserts} from "chimera/CryticAsserts.sol";
import {ConverterTargets} from "./ConverterTargets.sol";

/// @dev Medusa's entry point for the Converter: `medusa fuzz --target-contracts ConverterTester`.
contract ConverterTester is ConverterTargets, CryticAsserts {
    constructor() {
        setup();
    }
}
