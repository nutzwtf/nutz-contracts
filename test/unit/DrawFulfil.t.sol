// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {NutzDraw} from "../../src/NutzDraw.sol";
import {DrawBase} from "../harness/DrawBase.sol";
import {BlsFixtures} from "../harness/BlsFixtures.sol";

/// @dev Draw spec §6: fulfilment of a draw committed to the recorded quicknet round 1000 (spec §13), every revert
///      on the way, and the finality of the Seed; then the same contract against the committed BLS fixtures (504 real
///      rounds, 41 noble-built rejects), security-review ticket 03.
contract DrawFulfilTest is DrawBase, BlsFixtures {
    uint256 internal id;

    function setUp() public override {
        super.setUp();
        id = openDrawId();
    }

    /// @dev Commits `id` to round 1000 and moves the clock to the start of that round.
    function requestAndWaitForVectorRound() internal {
        request(id);
        assertEq(committedRound(id), VECTOR_ROUND);
        vm.warp(VECTOR_DUE_TS);
    }

    // ---- reverts ----

    function test_fulfill_notRequested_reverts() public {
        vm.expectRevert(abi.encodeWithSelector(NutzDraw.DrawNotRequested.selector, id));
        draw.fulfill(id, VECTOR_SIG);
    }

    function test_fulfill_beforeTheRound_reverts() public {
        request(id);
        vm.expectRevert(abi.encodeWithSelector(NutzDraw.RoundNotDue.selector, VECTOR_ROUND, VECTOR_REQUEST_ROUND));
        draw.fulfill(id, VECTOR_SIG);

        vm.warp(VECTOR_DUE_TS - 1);
        vm.expectRevert(abi.encodeWithSelector(NutzDraw.RoundNotDue.selector, VECTOR_ROUND, VECTOR_ROUND - 1));
        draw.fulfill(id, VECTOR_SIG);
    }

    function test_fulfill_signatureTooShort_reverts() public {
        requestAndWaitForVectorRound();
        bytes memory short = VECTOR_SIG;
        assembly {
            mstore(short, 47)
        }
        vm.expectRevert(NutzDraw.InvalidSignature.selector);
        draw.fulfill(id, short);
    }

    function test_fulfill_signatureTooLong_reverts() public {
        requestAndWaitForVectorRound();
        vm.expectRevert(NutzDraw.InvalidSignature.selector);
        draw.fulfill(id, bytes.concat(VECTOR_SIG, hex"00"));
    }

    function test_fulfill_signatureOfAnotherRound_reverts() public {
        request(id);
        request(id - 1); // same second: commits to round 1001
        assertEq(committedRound(id - 1), VECTOR_ROUND + 1);
        vm.warp(VECTOR_DUE_TS + PERIOD);
        vm.expectRevert(NutzDraw.InvalidSignature.selector);
        draw.fulfill(id - 1, VECTOR_SIG);
    }

    /// @dev A single-byte tamper (sampled over the 48 x 255 index/mask pairs) is refused as `InvalidSignature`, and
    ///      the verifier underneath refused it on the one path the flipped bits dictate: the flag screen (`_wellFormed`
    ///      catches what the unmarshal would revert on), the pairing check (sign bit alone: -sig) or the pairing
    ///      precompile rejecting the point (any change to x). A rejected point burns all the gas forwarded, hence the
    ///      cap.
    function testFuzz_fulfill_tamperedByte_revertsOnTheExpectedPath(uint8 index, uint8 mask) public {
        index = uint8(bound(index, 0, 47));
        mask = uint8(bound(mask, 1, 255));
        requestAndWaitForVectorRound();
        bytes memory tampered = VECTOR_SIG;
        tampered[index] = bytes1(uint8(tampered[index]) ^ mask);

        (bool ok, bytes memory reason) =
            address(draw).call{gas: FULFIL_GAS_CAP}(abi.encodeCall(draw.fulfill, (id, tampered)));
        assertFalse(ok, "tampered signature accepted");
        assertEq(reason, abi.encodePacked(NutzDraw.InvalidSignature.selector));
        assertEq(draw.seedOf(id), bytes32(0));
        assertEq(
            outcome("compressed", tampered, VECTOR_ROUND, string(draw.DST())),
            expectedTamperOutcome(index, mask),
            "the verifier's rejection path"
        );
    }

    function test_fulfill_uncompressedFlag_reverts() public {
        requestAndWaitForVectorRound();
        bytes memory flagged = VECTOR_SIG;
        flagged[0] = flagged[0] & 0x7f; // compressed flag cleared
        vm.expectRevert(NutzDraw.InvalidSignature.selector);
        draw.fulfill(id, flagged);
    }

    function test_fulfill_infinityFlag_reverts() public {
        requestAndWaitForVectorRound();
        bytes memory flagged = VECTOR_SIG;
        flagged[0] = flagged[0] | 0x40; // infinity flag set
        vm.expectRevert(NutzDraw.InvalidSignature.selector);
        draw.fulfill(id, flagged);
    }

    // ---- success and finality ----

    function test_fulfill_vector_storesRandomness_andNamesFulfiller() public {
        requestAndWaitForVectorRound();
        vm.expectEmit(address(draw));
        emit NutzDraw.DrawFulfilled(id, VECTOR_ROUND, RANDOMNESS, stranger);
        fulfil(id, VECTOR_SIG);

        assertEq(draw.seedOf(id), RANDOMNESS, "drand's published randomness for round 1000");
        (bytes32 root, uint256 count, uint64 round, bytes32 seed) = draw.draws(id);
        assertEq(root, ROOT);
        assertEq(count, COUNT);
        assertEq(round, VECTOR_ROUND);
        assertEq(seed, RANDOMNESS);
        assertEq(draw.lastRound(), VECTOR_ROUND);
    }

    function test_fulfill_lateIsFine() public {
        request(id);
        vm.warp(VECTOR_DUE_TS + 30 days);
        fulfil(id, VECTOR_SIG);
        assertEq(draw.seedOf(id), RANDOMNESS);
    }

    function test_fulfill_twice_reverts() public {
        requestAndWaitForVectorRound();
        fulfil(id, VECTOR_SIG);
        vm.expectRevert(abi.encodeWithSelector(NutzDraw.AlreadyFulfilled.selector, id));
        draw.fulfill(id, VECTOR_SIG);
    }

    function test_requestDraw_afterFulfil_reverts() public {
        requestAndWaitForVectorRound();
        fulfil(id, VECTOR_SIG);
        vm.prank(keeper);
        vm.expectRevert(abi.encodeWithSelector(NutzDraw.AlreadyFulfilled.selector, id));
        draw.requestDraw(id, keccak256("other tickets"), COUNT);
        assertEq(draw.seedOf(id), RANDOMNESS, "the Seed is final");
    }

    function test_fulfill_otherDrawsUnaffected() public {
        request(id);
        request(id - 1);
        vm.warp(VECTOR_DUE_TS);
        fulfil(id, VECTOR_SIG);
        assertEq(draw.seedOf(id - 1), bytes32(0));
        vm.expectRevert(abi.encodeWithSelector(NutzDraw.RoundNotDue.selector, VECTOR_ROUND + 1, VECTOR_ROUND));
        draw.fulfill(id - 1, VECTOR_SIG);
    }

    // ---- the committed BLS fixtures through the contract itself ----

    /// @dev Every round in test/fixtures/bls/quicknet-rounds.json fulfils a draw committed to it: the clock is set so
    ///      the request lands on exactly that round, and the Seed equals the `randomness` drand published.
    function test_fulfill_fixtureRounds_seedIsDrandsRandomness() public {
        Round[] memory r = loadRounds();
        assertGe(r.length, 500, "fixture count");
        for (uint256 i = 0; i < r.length; i++) {
            uint256 drawId = i + 1; // any id below currentDraw(); the rounds ascend, so lastRound never blocks
            uint64 round = uint64(r[i].round);
            commitTo(draw, drawId, round);
            vm.expectEmit(address(draw));
            emit NutzDraw.DrawFulfilled(drawId, round, r[i].randomness, stranger);
            fulfil(draw, drawId, r[i].signature);
            assertEq(draw.seedOf(drawId), r[i].randomness, string.concat("round ", vm.toString(round)));
        }
    }

    /// @dev Every negative under the Draw's DST is refused as `InvalidSignature` by a fresh Draw committed to the
    ///      round the case names, whatever path the verifier took underneath (the fixture says which, and the
    ///      BlsQuicknet suite pins it). 96-byte points fail the length screen. Cases under another DST cannot be
    ///      driven through the contract, whose DST is a constant; BlsQuicknet covers them.
    function test_fulfill_fixtureNegatives_revertInvalidSignature() public {
        (Negative[] memory c,) = loadNegatives();
        assertGe(c.length, 40, "fixture count");
        uint256 driven;
        for (uint256 i = 0; i < c.length; i++) {
            if (!same(c[i].dst, string(draw.DST()))) continue;
            driven++;
            NutzDraw fresh = new NutzDraw(address(dist));
            commitTo(fresh, id, uint64(c[i].round));
            (bool ok, bytes memory reason) =
                address(fresh).call{gas: FULFIL_GAS_CAP}(abi.encodeCall(fresh.fulfill, (id, c[i].point)));
            assertFalse(ok, string.concat(c[i].name, ": accepted"));
            assertEq(reason, abi.encodePacked(NutzDraw.InvalidSignature.selector), c[i].name);
            assertEq(fresh.seedOf(id), bytes32(0), c[i].name);
            if (c[i].point.length == 48) {
                assertEq(outcome(c[i].encoding, c[i].point, c[i].round, c[i].dst), c[i].solidity, c[i].name);
            }
        }
        assertGe(driven, 30, "most negatives are under the Draw's DST");
    }

    /// @dev Requests `drawId` on `d` at the instant whose committed round is `round`, then moves the clock to the
    ///      start of that round.
    function commitTo(NutzDraw d, uint256 drawId, uint64 round) internal {
        uint256 due = GENESIS + (uint256(round) - 1) * PERIOD;
        vm.warp(due - LEAD);
        vm.prank(keeper);
        d.requestDraw(drawId, ROOT, COUNT);
        assertEq(committedRound(d, drawId), round, "committed to the fixture's round");
        vm.warp(due);
    }

    function fulfil(NutzDraw d, uint256 drawId, bytes memory signature) internal {
        vm.prank(stranger);
        d.fulfill(drawId, signature);
    }

    function committedRound(NutzDraw d, uint256 drawId) internal view returns (uint64 round) {
        (,, round,) = d.draws(drawId);
    }
}
