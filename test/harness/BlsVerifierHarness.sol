// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {BLS2} from "../../src/vendor/bls/BLS2.sol";
import {BLS12_G1ADD} from "../../src/vendor/bls/Precompiles.sol";

/// @dev Exposes the vendored BLS12-381 verifier through external calls, with the drand quicknet public key hard-coded
///      the way NutzDraw carries it, so the unit tests can measure one verify, catch the library's reverts and drive
///      every internal step (expand_message_xmd, hash_to_curve, both unmarshals, the pairing, one precompile) with
///      the standard vectors under test/fixtures/bls/. Same recipe as upstream's `QuicknetRegistry` demo.
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

    // ---- NutzDraw's recipe ----

    /// @return ok the pairing check passed
    /// @return callOk the pairing precompile call itself succeeded (false for a point off the curve or subgroup)
    function verify(uint64 round, bytes calldata signature) external view returns (bool ok, bool callOk) {
        return verifyWithDst(DST, round, signature);
    }

    /// @dev Exactly `NutzDraw._verify` with the DST as a parameter: 48-byte compressed signature.
    function verifyWithDst(bytes memory dst, uint64 round, bytes memory signature)
        public
        view
        returns (bool ok, bool callOk)
    {
        return verifyPoint(dst, round, BLS2.g1UnmarshalCompressed(signature));
    }

    /// @dev The same check on a 96-byte uncompressed signature (`BLS2.g1Unmarshal`, no flag bits, no masking).
    function verifyUncompressed(bytes memory dst, uint64 round, bytes memory signature)
        external
        view
        returns (bool ok, bool callOk)
    {
        return verifyPoint(dst, round, BLS2.g1Unmarshal(signature));
    }

    function verifyPoint(bytes memory dst, uint64 round, BLS2.PointG1 memory sig)
        public
        view
        returns (bool ok, bool callOk)
    {
        BLS2.PointG1 memory message = BLS2.hashToPoint(dst, abi.encodePacked(sha256(abi.encodePacked(round))));
        return BLS2.verifySingle(sig, publicKey(), message);
    }

    // ---- the steps on their own ----

    function expandMsg(bytes memory dst, bytes memory message, uint8 nBytes) external pure returns (bytes memory) {
        return BLS2.expandMsg(dst, message, nBytes);
    }

    /// @return the affine point as 96 bytes, x || y, 48-byte big-endian field elements
    function hashToPoint(bytes memory dst, bytes memory message) external view returns (bytes memory) {
        return BLS2.g1Marshal(BLS2.hashToPoint(dst, message));
    }

    function decompress(bytes memory compressed) external view returns (BLS2.PointG1 memory) {
        return BLS2.g1UnmarshalCompressed(compressed);
    }

    function unmarshal(bytes memory uncompressed) external pure returns (BLS2.PointG1 memory) {
        return BLS2.g1Unmarshal(uncompressed);
    }

    /// @dev G1ADD(point, infinity) through the EIP-2537 precompile: it validates the field elements and the curve
    ///      equation but not the subgroup, so it separates "off the curve" from "on the curve, outside G1".
    /// @return ok the precompile accepted the point
    /// @return sum the precompile's output, equal to `point` when `ok`
    function g1AddIdentity(BLS2.PointG1 memory point) external view returns (bool ok, BLS2.PointG1 memory sum) {
        bytes memory input = bytes.concat(_fieldElements(point), new bytes(128));
        (bool success, bytes memory out) = address(uint160(BLS12_G1ADD)).staticcall{gas: 100_000}(input);
        if (!success || out.length != 128) return (false, sum);
        return (true, _fromFieldElements(out));
    }

    /// @dev Raw call to one precompile address with a gas cap: a rejected input burns everything forwarded.
    function callPrecompile(uint256 precompile, bytes calldata input, uint256 gasCap)
        external
        view
        returns (bool ok, bytes memory out)
    {
        return address(uint160(precompile)).staticcall{gas: gasCap}(input);
    }

    // ---- EIP-2537 field element layout: 64 bytes each, 16 zero bytes then the 48-byte value ----

    function _fieldElements(BLS2.PointG1 memory p) internal pure returns (bytes memory) {
        return abi.encode(uint256(p.x_hi), p.x_lo, uint256(p.y_hi), p.y_lo);
    }

    function _fromFieldElements(bytes memory out) internal pure returns (BLS2.PointG1 memory p) {
        (uint256 xHi, uint256 xLo, uint256 yHi, uint256 yLo) = abi.decode(out, (uint256, uint256, uint256, uint256));
        p = BLS2.PointG1({x_hi: uint128(xHi), x_lo: xLo, y_hi: uint128(yHi), y_lo: yLo});
    }
}
