// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {BLS12_G1ADD, BLS12_PAIRING_CHECK, BLS12_MAP_FP_TO_G1} from "../../src/vendor/bls/Precompiles.sol";
import {BlsFixtures} from "../harness/BlsFixtures.sol";

/// @dev The EIP-2537 test vectors (ethereum/EIPs assets/eip-2537, every file but the two multi-megabyte MSM ones)
///      against the precompile addresses the vendored library names, in the local prague EVM. Positives must return
///      the expected bytes exactly; every `fail-*` vector must make the precompile error. Security-review ticket 03,
///      item 2. `scripts/bls-precompiles-live.sh` runs the same fixture against the chain's own node.
contract BlsEip2537Test is BlsFixtures {
    uint256 internal constant POSITIVES = 65;
    uint256 internal constant FAILS = 81;
    uint256 internal constant G1MSM = 0x0c;
    uint256 internal constant G2ADD = 0x0d;
    uint256 internal constant G2MSM = 0x0e;
    uint256 internal constant MAP_FP2_TO_G2 = 0x11;
    /// @dev Enough for the largest positive (an eight-pair pairing check is about 300k).
    uint256 internal constant POSITIVE_GAS_CAP = 5_000_000;
    /// @dev A rejected input burns everything forwarded; the cap bounds the test, not the precompile.
    uint256 internal constant FAIL_GAS_CAP = 500_000;

    function test_positives_returnExpectedOutput() public view {
        (EipPositive[] memory v,) = loadEip2537();
        assertEq(v.length, POSITIVES, "fixture count");
        for (uint256 i = 0; i < v.length; i++) {
            (bool ok, bytes memory out) = h.callPrecompile(v[i].precompile, v[i].input, POSITIVE_GAS_CAP);
            assertTrue(ok, string.concat(v[i].name, ": precompile errored"));
            assertEq(out, v[i].expected, v[i].name);
        }
    }

    function test_failVectors_makeThePrecompileError() public view {
        (, EipFail[] memory v) = loadEip2537();
        assertEq(v.length, FAILS, "fixture count");
        for (uint256 i = 0; i < v.length; i++) {
            (bool ok, bytes memory out) = h.callPrecompile(v[i].precompile, v[i].input, FAIL_GAS_CAP);
            assertFalse(ok, string.concat(v[i].name, ": expected error '", v[i].expectedError, "'"));
            assertEq(out.length, 0, string.concat(v[i].name, ": an errored precompile returns no data"));
        }
    }

    /// @dev Every address the fixture targets is one of the seven EIP-2537 precompiles, and the three the library
    ///      calls (Precompiles.sol) each have positives and fails in the fixture.
    function test_fixture_coversTheLibrarysPrecompiles() public view {
        (EipPositive[] memory pos, EipFail[] memory fail) = loadEip2537();
        uint256[7] memory positives;
        uint256[7] memory fails;
        for (uint256 i = 0; i < pos.length; i++) {
            positives[_slot(pos[i].precompile)]++;
        }
        for (uint256 i = 0; i < fail.length; i++) {
            fails[_slot(fail[i].precompile)]++;
        }
        assertEq(BLS12_G1ADD, 0x0b, "Precompiles.sol G1ADD");
        assertEq(BLS12_PAIRING_CHECK, 0x0f, "Precompiles.sol PAIRING_CHECK");
        assertEq(BLS12_MAP_FP_TO_G1, 0x10, "Precompiles.sol MAP_FP_TO_G1");
        uint256[3] memory used = [BLS12_G1ADD, BLS12_PAIRING_CHECK, BLS12_MAP_FP_TO_G1];
        for (uint256 i = 0; i < used.length; i++) {
            assertGt(positives[_slot(used[i])], 0, "positives for a precompile the library calls");
            assertGt(fails[_slot(used[i])], 0, "fails for a precompile the library calls");
        }
        // the other four are covered too (mul_* stands in for the MSM positives)
        assertGt(positives[_slot(G1MSM)] * fails[_slot(G1MSM)], 0, "G1MSM");
        assertGt(positives[_slot(G2ADD)] * fails[_slot(G2ADD)], 0, "G2ADD");
        assertGt(positives[_slot(G2MSM)] * fails[_slot(G2MSM)], 0, "G2MSM");
        assertGt(positives[_slot(MAP_FP2_TO_G2)] * fails[_slot(MAP_FP2_TO_G2)], 0, "MAP_FP2_TO_G2");
    }

    /// @dev The EIP fact the negatives lean on: G1ADD accepts a point outside G1 (it checks the field elements and
    ///      the curve equation only), while the pairing check rejects it. Both are upstream vectors.
    function test_g1AddHasNoSubgroupCheck_pairingDoes() public view {
        (EipPositive[] memory pos, EipFail[] memory fail) = loadEip2537();
        bool addSeen;
        bool pairingSeen;
        for (uint256 i = 0; i < pos.length; i++) {
            if (!same(pos[i].name, "bls_g1add_g1_not_in_correct_subgroup+g1")) continue;
            addSeen = true;
            assertEq(pos[i].precompile, BLS12_G1ADD);
            (bool ok, bytes memory out) = h.callPrecompile(pos[i].precompile, pos[i].input, POSITIVE_GAS_CAP);
            assertTrue(ok, "G1ADD accepts a point outside the subgroup");
            assertEq(out, pos[i].expected);
        }
        for (uint256 i = 0; i < fail.length; i++) {
            if (!same(fail[i].name, "bls_pairing_e(G1_not_in_correct_subgroup,G2)")) continue;
            pairingSeen = true;
            assertEq(fail[i].precompile, BLS12_PAIRING_CHECK);
            (bool ok,) = h.callPrecompile(fail[i].precompile, fail[i].input, FAIL_GAS_CAP);
            assertFalse(ok, "the pairing check rejects a point outside the subgroup");
        }
        assertTrue(addSeen && pairingSeen, "both upstream vectors present");
    }

    function _slot(uint256 precompile) internal pure returns (uint256) {
        assertTrue(precompile >= 0x0b && precompile <= 0x11, "an EIP-2537 address");
        return precompile - 0x0b;
    }
}
