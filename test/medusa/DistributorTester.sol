// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {CryticAsserts} from "chimera/CryticAsserts.sol";
import {DistributorTargets} from "./DistributorTargets.sol";

/// @dev Medusa's entry point for the Distributor: `medusa fuzz --target-contracts DistributorTester`. The
///      constructor is the fixture; every public function is an action; every `property_*` a check.
contract DistributorTester is DistributorTargets, CryticAsserts {
    constructor() {
        setup();
    }
}
