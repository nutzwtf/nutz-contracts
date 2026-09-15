// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {Test} from "forge-std/Test.sol";
import {BlsVerifierHarness} from "../harness/BlsVerifierHarness.sol";

/// @dev The vendored BLS12-381 verifier against the recorded drand quicknet vectors (draw spec §9, §13), through the
///      local prague EVM's EIP-2537 precompiles.
contract BlsVerifierTest is Test {
    uint64 internal constant ROUND = 1000;
    bytes internal constant SIGNATURE =
        hex"b44679b9a59af2ec876b1a6b1ad52ea9b1615fc3982b19576350f93447cb1125e342b73a8dd2bacbe47e4b6b63ed5e39";
    bytes32 internal constant RANDOMNESS = 0xfe290beca10872ef2fb164d2aa4442de4566183ec51c56ff3cd603d930e54fdd;
    bytes internal constant PUBLIC_KEY_COMPRESSED = hex"83cf0f2896adee7eb8b5f01fcad3912212c437e0073e911fb90022d3e760183c8c4b450b6a0a6c3ac6a5776a2d106451"
        hex"0d1fec758c921cc22b0e17e63aaf4bcb5ed66304de9cf809bd274ca73bab4af5a6e9c76a4bc09e76eae8991ef5ece45a";

    // (p - 1) / 2 for the BLS12-381 base field, split like the library's limbs (16 high bytes, 32 low bytes).
    uint128 internal constant P_MINUS_ONE_HALF_HI = 0x0680447a8e5ff9a692c6e9ed90d2eb35;
    uint256 internal constant P_MINUS_ONE_HALF_LO = 0xd91dd2e13ce144afd9cc34a83dac3d8907aaffffac54ffffee7fbfffffffeaaa;

    // Three times one verify (134,556 gas): enough for a real signature, small enough to bound a rejected point.
    uint256 internal constant VERIFY_GAS_CAP = 400_000;
    bytes32 internal constant NOT_COMPRESSED =
        keccak256(abi.encodeWithSignature("Error(string)", "Invalid G1 point: not compressed"));
    bytes32 internal constant INFINITY =
        keccak256(abi.encodeWithSignature("Error(string)", "unsupported: point at infinity"));

    BlsVerifierHarness internal h;

    function setUp() public {
        h = new BlsVerifierHarness();
    }

    function test_vector_round1000_verifies() public view {
        (bool ok, bool callOk) = h.verify(ROUND, SIGNATURE);
        assertTrue(callOk, "pairing precompile call");
        assertTrue(ok, "pairing check");
        assertEq(sha256(SIGNATURE), RANDOMNESS, "drand randomness is sha256(signature)");
    }

    function test_vector_againstRound1001_fails() public view {
        (bool ok, bool callOk) = h.verify(ROUND + 1, SIGNATURE);
        assertTrue(callOk, "pairing precompile call");
        assertFalse(ok, "pairing check");
    }

    function test_wrongDst_fails() public view {
        (bool ok, bool callOk) = h.verifyWithDst("BLS_SIG_BLS12381G1_XMD:SHA-256_SSWU_RO_POP_", ROUND, SIGNATURE);
        assertTrue(callOk, "pairing precompile call");
        assertFalse(ok, "pairing check");
    }

    /// @dev A single-byte tamper (sampled over the 48 x 255 index/mask pairs) either fails the pairing check, or
    ///      makes the pairing precompile reject the point (callOk false), or is rejected while unmarshalling when it
    ///      hits the two flag bits. A rejected point burns all the gas forwarded to the precompile, hence the cap.
    function testFuzz_tamperedByte_fails(uint8 index, uint8 mask) public view {
        index = uint8(bound(index, 0, 47));
        mask = uint8(bound(mask, 1, 255));
        bytes memory tampered = SIGNATURE;
        tampered[index] = bytes1(uint8(tampered[index]) ^ mask);
        try h.verify{gas: VERIFY_GAS_CAP}(ROUND, tampered) returns (bool ok, bool callOk) {
            assertFalse(ok && callOk, "tampered signature verified");
        } catch (bytes memory reason) {
            bytes32 r = keccak256(reason);
            assertTrue(r == NOT_COMPRESSED || r == INFINITY, "unexpected revert");
        }
    }

    function test_signatureTooShort_reverts() public {
        bytes memory short = SIGNATURE;
        assembly {
            mstore(short, 47)
        }
        vm.expectRevert(bytes("Invalid G1 bytes length"));
        h.verify(ROUND, short);
    }

    function test_signatureTooLong_reverts() public {
        vm.expectRevert(bytes("Invalid G1 bytes length"));
        h.verify(ROUND, bytes.concat(SIGNATURE, hex"00"));
    }

    /// @dev The eight hard-coded limbs, re-compressed by the zcash rule, equal drand's published key.
    function test_publicKey_compressesToSpec() public view {
        assertEq(compressG2(h.marshalPublicKey()), PUBLIC_KEY_COMPRESSED);
    }

    /// @dev zcash BLS12-381 serialisation: x1 || x0 with the top three bits of the first byte as flags. Compressed
    ///      flag set, infinity flag clear, sign flag set when y1 > (p - 1) / 2, or y1 == 0 and y0 > (p - 1) / 2.
    function compressG2(bytes memory uncompressed) internal pure returns (bytes memory out) {
        assertEq(uncompressed.length, 192, "uncompressed G2 length");
        (uint128 y1Hi, uint256 y1Lo) = limbs(uncompressed, 96);
        (uint128 y0Hi, uint256 y0Lo) = limbs(uncompressed, 144);
        bool sign = gtHalf(y1Hi, y1Lo) || (y1Hi == 0 && y1Lo == 0 && gtHalf(y0Hi, y0Lo));
        out = new bytes(96);
        for (uint256 i = 0; i < 96; i++) {
            out[i] = uncompressed[i];
        }
        out[0] = bytes1(uint8(out[0]) | 0x80 | (sign ? 0x20 : 0x00));
    }

    function limbs(bytes memory m, uint256 offset) internal pure returns (uint128 hi, uint256 lo) {
        assembly {
            hi := shr(128, mload(add(add(m, 0x20), offset)))
            lo := mload(add(add(m, 0x30), offset))
        }
    }

    function gtHalf(uint128 hi, uint256 lo) internal pure returns (bool) {
        return hi > P_MINUS_ONE_HALF_HI || (hi == P_MINUS_ONE_HALF_HI && lo > P_MINUS_ONE_HALF_LO);
    }
}
