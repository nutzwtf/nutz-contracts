// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {stdError} from "forge-std/StdError.sol";
import {NutzDistributor} from "../../src/NutzDistributor.sol";
import {DistributorBase} from "../harness/DistributorBase.sol";
import {StorageSlots} from "../harness/StorageSlots.sol";

/// @dev Symbolic checks (`forge test --symbolic`) of the cap arithmetic engineering-spec §6 "bad root" leans on:
///      the per-Root cap in `postRoot`, its exact inverse in `voidRoot`, and the per-period cap in `_settle`. The
///      solver owns every ledger word (`funded`, `carry`, `totals`, `claimed`) and every claimed amount, written
///      straight into storage (`DistributorBase.plant*`), so no signature or proof constrains the search. Two things
///      stay concrete, for the engine's sake (docs/setup/tools.md): the period id, and `postRoot`'s `totals`, for
///      which two vectors stand in for "any". An overflow of `funded + carry` or `claimed + amount` is a `Panic`,
///      not `CapExceeded`; the oracles expect exactly what the contract does. Manual; see tools.md.
contract DistributorCaps is DistributorBase {
    uint256 internal constant E = DEPLOY_EPOCH; // the deploy Epoch is the first one postRoot accepts
    uint256 internal constant MAX = type(uint256).max;

    address internal alice = makeAddr("alice");

    function setUp() public override {
        super.setUp();
        fundDistributorToTheMax();
    }

    function storeCarry(uint256[5] memory v) internal {
        for (uint256 i = 0; i < 5; i++) {
            vm.store(address(d), StorageSlots.carry(EPOCH, i), bytes32(v[i]));
        }
    }

    // ---- postRoot: accepted iff totals[i] <= funded[i] + carry[i] for all i; the new Carry is exact ----

    /// @dev `postRoot` walks the tokens in order and reverts at the first one that overflows the sum or exceeds
    ///      it; this returns the revert the contract must produce, or empty for acceptance.
    function expectedPostRootRevert(uint256[5] memory funded, uint256[5] memory carryIn, uint256[5] memory totals)
        internal
        pure
        returns (bytes memory)
    {
        for (uint256 i = 0; i < 5; i++) {
            if (funded[i] > MAX - carryIn[i]) return stdError.arithmeticError;
            if (totals[i] > funded[i] + carryIn[i]) {
                return abi.encodeWithSelector(NutzDistributor.CapExceeded.selector, i);
            }
        }
        return "";
    }

    function postRootFor(uint256[5] memory funded, uint256[5] memory carryIn, uint256[5] memory totals) internal {
        plantLedgerArray(E, StorageSlots.LEDGER_FUNDED, funded);
        storeCarry(carryIn);
        bytes32 sh = postRootHash(EPOCH, E, keccak256("r"), totals, d.nonce());
        bytes memory sig1 = sign(KEY_A, sh);
        bytes memory sig2 = sign(KEY_B, sh);
        bytes memory expected = expectedPostRootRevert(funded, carryIn, totals);

        try d.postRoot(EPOCH, E, keccak256("r"), totals, sig1, sig2) {
            assertEq(expected.length, 0, "accepted a Root the cap rules out");
            NutzDistributor.Ledger memory L = d.ledger(EPOCH, E);
            uint256[5] memory carryOut = d.carry(EPOCH);
            for (uint256 i = 0; i < 5; i++) {
                assertEq(carryOut[i], funded[i] + carryIn[i] - totals[i], "carry is not funded + carryIn - totals");
                assertEq(L.totals[i], totals[i]);
                assertEq(L.funded[i], funded[i], "posting must not touch funding");
            }
            assertEq(d.rootedThrough(EPOCH), E);
        } catch (bytes memory err) {
            assertRevertData(err, expected);
            assertEq(d.rootedThrough(EPOCH), E - 1, "a rejected Root must leave the book untouched");
        }
    }

    function check_postRoot_capAndCarry_mixedTotals(uint256[5] calldata funded, uint256[5] calldata carryIn) external {
        postRootFor(funded, carryIn, amounts(1e18, 0, 3, 5e6, 7e17));
    }

    function check_postRoot_capAndCarry_hugeTotals(uint256[5] calldata funded, uint256[5] calldata carryIn) external {
        postRootFor(funded, carryIn, amounts(MAX / 2, MAX - 1, MAX, 1, MAX / 3));
    }

    // ---- voidRoot restores the Carry the Root consumed, exactly ----

    function voidRootFor(uint256[5] memory funded, uint256[5] memory carryIn, uint256[5] memory totals) internal {
        for (uint256 i = 0; i < 5; i++) {
            vm.assume(funded[i] <= MAX - carryIn[i]);
            vm.assume(totals[i] <= funded[i] + carryIn[i]);
        }
        plantLedgerArray(E, StorageSlots.LEDGER_FUNDED, funded);
        storeCarry(carryIn);
        postRoot(EPOCH, E, keccak256("r"), totals);
        voidRoot(EPOCH, E);

        uint256[5] memory carryOut = d.carry(EPOCH);
        NutzDistributor.Ledger memory L = d.ledger(EPOCH, E);
        for (uint256 i = 0; i < 5; i++) {
            assertEq(carryOut[i], carryIn[i], "void did not restore the carry");
            assertEq(L.totals[i], 0);
            assertEq(L.funded[i], funded[i], "voiding must keep the funding");
        }
        assertEq(L.rootPostedAt, 0);
        assertEq(d.rootedThrough(EPOCH), E - 1);
    }

    function check_voidRoot_restoresCarry_mixedTotals(uint256[5] calldata funded, uint256[5] calldata carryIn)
        external
    {
        voidRootFor(funded, carryIn, amounts(1e18, 0, 3, 5e6, 7e17));
    }

    function check_voidRoot_restoresCarry_hugeTotals(uint256[5] calldata funded, uint256[5] calldata carryIn) external {
        voidRootFor(funded, carryIn, amounts(MAX / 2, MAX - 1, MAX, 1, MAX / 3));
    }

    // ---- _settle: claimed[i] + amounts[i] > totals[i] always reverts ----

    function check_settle_perPeriodCap(uint256[5] calldata a, uint256[5] calldata totals, uint256[5] calldata claimed)
        external
    {
        plantFinalRoot(E, leafOf(E, alice, a)); // a single-leaf Root: the empty proof verifies
        plantLedgerArray(E, StorageSlots.LEDGER_TOTALS, totals);
        plantLedgerArray(E, StorageSlots.LEDGER_CLAIMED, claimed);

        bytes memory expected = "";
        for (uint256 i = 0; i < 5 && expected.length == 0; i++) {
            if (claimed[i] > MAX - a[i]) {
                expected = stdError.arithmeticError;
            } else if (claimed[i] + a[i] > totals[i]) {
                expected = abi.encodeWithSelector(NutzDistributor.CapExceeded.selector, i);
            }
        }

        try d.claim(EPOCH, E, alice, a, new bytes32[](0)) {
            assertEq(expected.length, 0, "paid a leaf that crosses the period's totals");
            NutzDistributor.Ledger memory L = d.ledger(EPOCH, E);
            for (uint256 i = 0; i < 5; i++) {
                assertEq(L.claimed[i], claimed[i] + a[i]);
                assertLe(L.claimed[i], totals[i]);
                assertEq(tok[i].balanceOf(alice) + d.stuck(alice)[i], a[i], "leaf not paid in full");
            }
            assertTrue(d.claimed(EPOCH, E, alice));
        } catch (bytes memory err) {
            assertRevertData(err, expected);
            assertFalse(d.claimed(EPOCH, E, alice), "a rejected leaf must stay claimable");
            for (uint256 i = 0; i < 5; i++) {
                assertEq(tok[i].balanceOf(alice), 0);
            }
        }
    }
}
