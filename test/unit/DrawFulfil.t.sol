// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {NutzDraw} from "../../src/NutzDraw.sol";
import {DrawBase} from "../harness/DrawBase.sol";

/// @dev Draw spec §6: fulfilment of a draw committed to the recorded quicknet round 1000 (spec §13), every revert
///      on the way, and the finality of the Seed.
contract DrawFulfilTest is DrawBase {
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

    /// @dev A single-byte tamper (sampled over the 48 x 255 index/mask pairs) is refused as `InvalidSignature`,
    ///      whether it hits the flag bits, the pairing check or the precompile's point check. A rejected point
    ///      burns all the gas forwarded, hence the cap.
    function testFuzz_fulfill_tamperedByte_reverts(uint8 index, uint8 mask) public {
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
}
