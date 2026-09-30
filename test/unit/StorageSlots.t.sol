// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {NutzDistributor} from "../../src/NutzDistributor.sol";
import {DistributorBase} from "../harness/DistributorBase.sol";
import {StorageSlots} from "../harness/StorageSlots.sol";

/// @dev Pins `StorageSlots` to the contracts' real layout: every slot the symbolic suites write is read back
///      through a public getter here, and a value written through the contract is found at the computed slot.
contract StorageSlotsTest is DistributorBase {
    function store(bytes32 slot, uint256 v) internal {
        vm.store(address(d), slot, bytes32(v));
    }

    function test_slots_ledgerFields_matchTheGetter() public {
        uint256 e = DEPLOY_EPOCH + 7;
        NutzDistributor.Kind[2] memory kinds = [EPOCH, DRAW];
        for (uint256 k = 0; k < 2; k++) {
            store(StorageSlots.ledgerField(kinds[k], e, StorageSlots.LEDGER_ROOT), uint256(keccak256("root")));
            store(StorageSlots.ledgerField(kinds[k], e, StorageSlots.LEDGER_ROOT_POSTED_AT), 1234);
            store(StorageSlots.ledgerField(kinds[k], e, StorageSlots.LEDGER_SKIPPED), 1);
            for (uint256 i = 0; i < 5; i++) {
                store(StorageSlots.ledgerArray(kinds[k], e, StorageSlots.LEDGER_FUNDED, i), 100 + i);
                store(StorageSlots.ledgerArray(kinds[k], e, StorageSlots.LEDGER_TOTALS, i), 200 + i);
                store(StorageSlots.ledgerArray(kinds[k], e, StorageSlots.LEDGER_CLAIMED, i), 300 + i);
            }
            NutzDistributor.Ledger memory L = d.ledger(kinds[k], e);
            assertEq(L.root, keccak256("root"));
            assertEq(L.rootPostedAt, 1234);
            assertTrue(L.skipped);
            for (uint256 i = 0; i < 5; i++) {
                assertEq(L.funded[i], 100 + i);
                assertEq(L.totals[i], 200 + i);
                assertEq(L.claimed[i], 300 + i);
            }
        }
    }

    function test_slots_bookFields_matchTheGetters() public {
        for (uint256 i = 0; i < 5; i++) {
            store(StorageSlots.carry(EPOCH, i), 10 + i);
            store(StorageSlots.carry(DRAW, i), 20 + i);
        }
        store(StorageSlots.rootedThrough(EPOCH), 42);
        store(StorageSlots.rootedThrough(DRAW), 43);
        for (uint256 i = 0; i < 5; i++) {
            assertEq(d.carry(EPOCH)[i], 10 + i);
            assertEq(d.carry(DRAW)[i], 20 + i);
        }
        assertEq(d.rootedThrough(EPOCH), 42);
        assertEq(d.rootedThrough(DRAW), 43);

        address who = makeAddr("who");
        store(StorageSlots.claimedFlag(EPOCH, 5, who), 1);
        assertTrue(d.claimed(EPOCH, 5, who));
        assertFalse(d.claimed(DRAW, 5, who));
        store(StorageSlots.claimedFlag(DRAW, 5, who), 1);
        assertTrue(d.claimed(DRAW, 5, who));
    }

    function test_slots_rateBounds_matchTheGetters() public {
        store(bytes32(StorageSlots.MIN_USDG_PER_ETH), 7);
        store(bytes32(StorageSlots.MAX_USDG_PER_ETH), 9);
        assertEq(d.minUsdgPerEth(), 7);
        assertEq(d.maxUsdgPerEth(), 9);
    }

    /// @dev The other direction: what the contract writes lands where the library says.
    function test_slots_contractWrites_landOnTheComputedSlots() public {
        uint256 e = DEPLOY_EPOCH;
        fund(e, amounts(1, 2, 3, 4, 5), 0);
        for (uint256 i = 0; i < 5; i++) {
            assertEq(
                uint256(vm.load(address(d), StorageSlots.ledgerArray(EPOCH, e, StorageSlots.LEDGER_FUNDED, i))), i + 1
            );
        }
        postRoot(EPOCH, e, keccak256("r"), amounts(1, 1, 1, 1, 1));
        assertEq(vm.load(address(d), StorageSlots.ledgerField(EPOCH, e, StorageSlots.LEDGER_ROOT)), keccak256("r"));
        assertEq(uint256(vm.load(address(d), StorageSlots.carry(EPOCH, 4))), 4);
        assertEq(uint256(vm.load(address(d), StorageSlots.rootedThrough(EPOCH))), e);
    }
}
