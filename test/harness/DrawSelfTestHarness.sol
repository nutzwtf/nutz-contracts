// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {NutzDraw} from "../../src/NutzDraw.sol";
import {BLS2} from "../../src/vendor/bls/BLS2.sol";

/// @dev A Draw whose key is a valid G2 point that is not quicknet's (the BLS12-381 G2 generator), so the self-test
///      pairing fails cleanly. A point off the curve would fail too, but the precompile then burns all the gas it
///      is handed, which the constructor cannot bound.
contract NutzDrawWrongKey is NutzDraw {
    constructor(address distributor) NutzDraw(distributor) {}

    function _publicKey() internal pure override returns (BLS2.PointG2 memory) {
        return BLS2.PointG2({
            x1_hi: 0x13e02b6052719f607dacd3a088274f65,
            x1_lo: 0x596bd0d09920b61ab5da61bbdc7f5049334cf11213945d57e5ac7d055d042b7e,
            x0_hi: 0x024aa2b2f08f0a91260805272dc51051,
            x0_lo: 0xc6e47ad4fa403b02b4510b647ae3d1770bac0326a805bbefd48056c8c121bdb8,
            y1_hi: 0x13fa4d4a0ad8b1ce186ed5061789213d,
            y1_lo: 0x993923066dddaf1040bc3ff59f825c78df74f2d75467e25e0f55f8a00fa030ed,
            y0_hi: 0x0d1b3cc2c7027888be51d9ef691d77bc,
            y0_lo: 0xb679afda66c73f17f9ee3837a55024f78c71363275a75d75d86bab79f74782aa
        });
    }
}

/// @dev A Draw whose self-test vector pairs the round-1000 signature with round 1001.
contract NutzDrawWrongVector is NutzDraw {
    constructor(address distributor) NutzDraw(distributor) {}

    function _selfTestVector() internal pure override returns (uint64 round, bytes memory signature) {
        return (VECTOR_ROUND + 1, VECTOR_SIG);
    }
}
