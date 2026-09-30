// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {BLS2} from "../../src/vendor/bls/BLS2.sol";
import {BlsFixtures} from "../harness/BlsFixtures.sol";

/// @dev The vendored library's `expandMsg` and `hashToPoint` against the RFC 9380 vectors (K.1 expand_message_xmd
///      with SHA-256, J.9.1 BLS12381G1_XMD:SHA-256_SSWU_RO_), copied from the cfrg poc/vectors into
///      test/fixtures/bls/. Security-review ticket 03, item 1.
contract BlsRfc9380Test is BlsFixtures {
    uint256 internal constant XMD_VECTORS = 20; // 10 per DST: five messages x two output lengths
    uint256 internal constant H2C_VECTORS = 5;

    // ---- expand_message_xmd ----

    function test_expandMsg_matchesRfc9380() public view {
        XmdVector[] memory v = loadXmd();
        assertEq(v.length, XMD_VECTORS, "fixture count");
        uint256 shortDst;
        for (uint256 i = 0; i < v.length; i++) {
            if (v[i].dst.length <= 255) {
                assertEq(v[i].dstReduced, v[i].dst, "no reduction under 256 bytes");
                shortDst++;
            }
            assertLe(v[i].lenInBytes, type(uint8).max, "the library takes a uint8 length");
            bytes memory got = h.expandMsg(v[i].dstReduced, v[i].msg, uint8(v[i].lenInBytes));
            assertEq(got, v[i].uniformBytes, string.concat("vector ", vm.toString(i)));
        }
        assertEq(shortDst, XMD_VECTORS / 2, "half the vectors use the 38-byte DST");
    }

    /// @dev RFC 9380 §5.3.3 replaces a DST over 255 bytes with `H("H2C-OVERSIZE-DST-" || DST)`; the library does not
    ///      implement the reduction and refuses the raw DST with its own error instead. The fixture carries both forms:
    ///      the raw one must revert, the reduced one is what `test_expandMsg_matchesRfc9380` feeds in.
    function test_expandMsg_oversizeDst_revertsInvalidDSTLength() public {
        XmdVector[] memory v = loadXmd();
        uint256 oversize;
        for (uint256 i = 0; i < v.length; i++) {
            if (v[i].dst.length <= 255) continue;
            oversize++;
            assertEq(v[i].dst.length, 256, "the RFC's long DST");
            assertEq(v[i].dstReduced.length, 32, "sha256 output");
            vm.expectRevert(abi.encodeWithSelector(BLS2.InvalidDSTLength.selector, v[i].dst));
            h.expandMsg(v[i].dst, v[i].msg, uint8(v[i].lenInBytes));
        }
        assertEq(oversize, XMD_VECTORS / 2, "half the vectors use the 256-byte DST");
    }

    // ---- hash_to_curve ----

    function test_hashToPoint_matchesRfc9380() public view {
        H2cVector[] memory v = loadH2c();
        assertEq(v.length, H2C_VECTORS, "fixture count");
        for (uint256 i = 0; i < v.length; i++) {
            assertEq(v[i].px.length, 48, "x is one field element");
            assertEq(v[i].py.length, 48, "y is one field element");
            bytes memory got = h.hashToPoint(v[i].dst, v[i].msg);
            assertEq(got, bytes.concat(v[i].px, v[i].py), string.concat("vector ", vm.toString(i)));
        }
    }
}
