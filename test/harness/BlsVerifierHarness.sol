// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {BLS2} from "../../src/vendor/bls/BLS2.sol";

/// @dev Exposes the vendored BLS12-381 verifier through external calls, with the drand quicknet public key hard-coded
///      the way NutzDraw will carry it, so the unit tests can measure one verify and catch the library's reverts.
///      Same recipe as upstream's `QuicknetRegistry` demo.
contract BlsVerifierHarness {
    bytes public constant DST = "BLS_SIG_BLS12381G1_XMD:SHA-256_SSWU_RO_NUL_";

    /// @dev drand quicknet public key, uncompressed, in `BLS2.PointG2` limb order (x1, x0, y1, y0; 16 high bytes then
    ///      32 low bytes each). Derived from the compressed key in the draw spec §13 with py_ecc (decompress_G2) and
    ///      re-compressed in the tests.
    function publicKey() public pure returns (BLS2.PointG2 memory) {
        return BLS2.PointG2({
            x1_hi: 0x03cf0f2896adee7eb8b5f01fcad39122,
            x1_lo: 0x12c437e0073e911fb90022d3e760183c8c4b450b6a0a6c3ac6a5776a2d106451,
            x0_hi: 0x0d1fec758c921cc22b0e17e63aaf4bcb,
            x0_lo: 0x5ed66304de9cf809bd274ca73bab4af5a6e9c76a4bc09e76eae8991ef5ece45a,
            y1_hi: 0x01a714f2edb74119a2f2b0d5a7c75ba9,
            y1_lo: 0x02d163700a61bc224ededd8e63aef7be1aaf8e93d7a9718b047ccddb3eb5d68b,
            y0_hi: 0x0e5db2b6bfbb01c867749cadffca88b3,
            y0_lo: 0x6c24f3012ba09fc4d3022c5c37dce0f977d3adb5d183c7477c442b1f04515273
        });
    }

    function marshalPublicKey() external pure returns (bytes memory) {
        return BLS2.g2Marshal(publicKey());
    }

    /// @return ok the pairing check passed
    /// @return callOk the pairing precompile call itself succeeded (false for a point off the curve or subgroup)
    function verify(uint64 round, bytes calldata signature) external view returns (bool ok, bool callOk) {
        return verifyWithDst(DST, round, signature);
    }

    function verifyWithDst(bytes memory dst, uint64 round, bytes memory signature)
        public
        view
        returns (bool ok, bool callOk)
    {
        BLS2.PointG1 memory sig = BLS2.g1UnmarshalCompressed(signature);
        BLS2.PointG1 memory message = BLS2.hashToPoint(dst, abi.encodePacked(sha256(abi.encodePacked(round))));
        return BLS2.verifySingle(sig, publicKey(), message);
    }
}
