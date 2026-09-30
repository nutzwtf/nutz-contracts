// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {BLS2} from "../../src/vendor/bls/BLS2.sol";
import {BlsFixtures} from "../harness/BlsFixtures.sol";

/// @dev The verifier, called exactly as `NutzDraw._verify` calls it, against real drand quicknet rounds and against
///      the negatives noble-curves built around round 1000. Differential: every fixture carries noble's accept or
///      reject decision, and the Solidity result must equal it; each negative also names the rejection path the
///      library must take and whether G1ADD (no subgroup check) accepts the point. Security-review ticket 03,
///      items 3 to 5.
contract BlsQuicknetTest is BlsFixtures {
    uint256 internal constant MIN_ROUNDS = 500;
    uint256 internal constant MIN_NEGATIVES = 40;
    /// @dev quicknet's newest round on 2026-09-14 was above 32,180,000; the spread must reach the present.
    uint256 internal constant SPREAD_FLOOR = 32_000_000;

    // ---- positives: real rounds ----

    function test_rounds_atLeast500Distinct_spreadOverHistory_allVerify() public view {
        Round[] memory r = loadRounds();
        assertGe(r.length, MIN_ROUNDS, "fixture count");
        assertEq(r[0].round, 1, "starts at the first round");
        assertGe(r[r.length - 1].round, SPREAD_FLOOR, "reaches recent rounds");
        for (uint256 i = 0; i < r.length; i++) {
            string memory label = string.concat("round ", vm.toString(r[i].round));
            if (i > 0) assertGt(r[i].round, r[i - 1].round, "distinct, ascending");
            assertTrue(r[i].nobleAccepts, string.concat(label, ": noble accepted it"));
            assertEq(r[i].signature.length, 48, string.concat(label, ": compressed G1"));
            assertEq(sha256(r[i].signature), r[i].randomness, string.concat(label, ": randomness"));
            (bool ok, bool callOk) = h.verify(uint64(r[i].round), r[i].signature);
            assertTrue(callOk, string.concat(label, ": pairing precompile call"));
            assertTrue(ok, string.concat(label, ": pairing check"));
        }
    }

    /// @dev The same point through the uncompressed unmarshal verifies too; the top-bits negatives differ from it by
    ///      one bit.
    function test_control_uncompressedSignatureVerifies() public view {
        (, Control memory c) = loadNegatives();
        assertTrue(c.nobleAccepts);
        assertTrue(same(c.encoding, "uncompressed"));
        assertEq(c.point.length, 96);
        assertEq(outcome(c.encoding, c.point, c.round, c.dst), ACCEPTED);
    }

    // ---- negatives: differential against noble, per rejection path ----

    function test_negatives_rejectedOnTheExpectedPath_asNobleRejects() public view {
        (Negative[] memory c,) = loadNegatives();
        assertGe(c.length, MIN_NEGATIVES, "fixture count");
        for (uint256 i = 0; i < c.length; i++) {
            assertFalse(c[i].nobleAccepts, string.concat(c[i].name, ": noble rejects"));
            string memory got = outcome(c[i].encoding, c[i].point, c[i].round, c[i].dst);
            assertEq(got, c[i].solidity, string.concat(c[i].name, ": rejection path"));
        }
    }

    /// @dev G1ADD validates field elements and the curve equation but not the subgroup: a point on the curve and
    ///      outside G1 passes it and must fail at the pairing, a point off the curve or with a field element >= p fails
    ///      both, infinity passes both.
    function test_negatives_g1AddSeparatesOffCurveFromOffSubgroup() public view {
        (Negative[] memory c,) = loadNegatives();
        uint256 checked;
        for (uint256 i = 0; i < c.length; i++) {
            if (same(c[i].g1add, "n/a")) {
                assertTrue(_startsWith(c[i].solidity, "revert:"), "n/a only where unmarshalling reverts");
                continue;
            }
            checked++;
            BLS2.PointG1 memory p =
                same(c[i].encoding, "compressed") ? h.decompress(c[i].point) : h.unmarshal(c[i].point);
            (bool ok, BLS2.PointG1 memory sum) = h.g1AddIdentity(p);
            assertEq(ok ? "ok" : "fails", c[i].g1add, string.concat(c[i].name, ": G1ADD"));
            if (ok) {
                assertEq(keccak256(abi.encode(sum)), keccak256(abi.encode(p)), "P + O == P");
                if (same(c[i].category, "offSubgroup")) {
                    assertEq(c[i].solidity, CALL_FAILS, "outside G1 fails at the pairing, not before");
                }
            } else {
                assertEq(c[i].solidity, CALL_FAILS, "what G1ADD rejects, the pairing rejects");
            }
        }
        assertGe(checked, MIN_NEGATIVES / 2, "most negatives reach a precompile");
    }

    /// @dev Every rejection class the ticket lists is present, so a generator change cannot silently drop one.
    function test_negatives_coverEveryClass() public view {
        (Negative[] memory c,) = loadNegatives();
        string[10] memory classes = [
            "offCurve",
            "offSubgroup",
            "fieldOverflow",
            "topBits",
            "infinity",
            "flags",
            "negated",
            "wrongRound",
            "wrongDst",
            "wrongKey"
        ];
        string[4] memory paths = [REVERT_NOT_COMPRESSED, REVERT_INFINITY, CALL_FAILS, PAIRING_FALSE];
        for (uint256 k = 0; k < classes.length; k++) {
            assertGt(_count(c, classes[k], true), 0, string.concat("class ", classes[k]));
        }
        for (uint256 k = 0; k < paths.length; k++) {
            assertGt(_count(c, paths[k], false), 0, string.concat("path ", paths[k]));
        }
        // the two infinity encodings take different paths
        bool canonical;
        bool eip;
        for (uint256 i = 0; i < c.length; i++) {
            if (!same(c[i].category, "infinity")) continue;
            if (same(c[i].encoding, "compressed") && c[i].point[0] == 0xc0) {
                canonical = same(c[i].solidity, REVERT_INFINITY);
            }
            if (same(c[i].encoding, "uncompressed") && keccak256(c[i].point) == keccak256(new bytes(96))) {
                eip = same(c[i].solidity, PAIRING_FALSE);
            }
        }
        assertTrue(canonical, "0xc0 || 0^47 reverts in the library");
        assertTrue(eip, "the all-zero point is a valid pairing input that fails the check");
    }

    function _count(Negative[] memory c, string memory needle, bool byCategory) internal pure returns (uint256 n) {
        for (uint256 i = 0; i < c.length; i++) {
            if (same(byCategory ? c[i].category : c[i].solidity, needle)) n++;
        }
    }

    function _startsWith(string memory s, string memory prefix) internal pure returns (bool) {
        bytes memory a = bytes(s);
        bytes memory b = bytes(prefix);
        if (a.length < b.length) return false;
        for (uint256 i = 0; i < b.length; i++) {
            if (a[i] != b[i]) return false;
        }
        return true;
    }
}
