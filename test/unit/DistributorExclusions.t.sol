// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {NutzDistributor} from "../../src/NutzDistributor.sol";
import {Signers} from "../../src/Signers.sol";
import {DistributorBase} from "../harness/DistributorBase.sol";

contract DistributorExclusionsTest is DistributorBase {
    address internal cex = makeAddr("cex-deposit");

    function proposeExclusion(address account) internal {
        bytes32 sh = keccak256(abi.encode(APPEND_EXCLUDED_TYPEHASH, account, d.nonce()));
        d.proposeExclusion(account, sign(KEY_B, sh), sign(KEY_C, sh));
    }

    function test_constructor_emitsTheBaseListSoTheLogStreamIsSelfSufficient() public {
        // the indexer rebuilds every Epoch's Excluded set from `ExcludedAppended` alone (engineering-spec §4.2)
        address[] memory base = new address[](2);
        base[0] = dead;
        base[1] = converter;
        vm.expectEmit();
        emit NutzDistributor.ExcludedAppended(dead);
        vm.expectEmit();
        emit NutzDistributor.ExcludedAppended(converter);
        NutzDistributor fresh = new NutzDistributor(
            [vm.addr(KEY_A), vm.addr(KEY_B), vm.addr(KEY_C)],
            keeper,
            converter,
            tokens(),
            100_000,
            40_000,
            1_000e6,
            10_000e6,
            base
        );
        assertEq(fresh.excluded().length, 2);
    }

    function test_exclusion_isAppendedAfter48h() public {
        bytes32 id = keccak256(abi.encode(APPEND_EXCLUDED_TYPEHASH, cex));
        proposeExclusion(cex);
        assertEq(d.readyAt(id), block.timestamp + 48 hours);
        assertEq(d.excluded().length, 1, "base list only until executed");

        vm.expectRevert(Signers.NotReady.selector);
        d.executeExclusion(cex);

        vm.warp(block.timestamp + 48 hours);
        vm.expectEmit(address(d));
        emit NutzDistributor.ExcludedAppended(cex);
        vm.prank(makeAddr("anyone"));
        d.executeExclusion(cex);
        address[] memory list = d.excluded();
        assertEq(list.length, 2);
        assertEq(list[0], dead);
        assertEq(list[1], cex);
    }

    function test_exclusion_duplicate_reverts_atProposeAndExecute() public {
        bytes32 sh = keccak256(abi.encode(APPEND_EXCLUDED_TYPEHASH, dead, uint256(0)));
        vm.expectRevert(abi.encodeWithSelector(NutzDistributor.AlreadyExcluded.selector, dead));
        d.proposeExclusion(dead, sign(KEY_B, sh), sign(KEY_C, sh));

        // two identical proposals cannot coexist, and a second execute finds nothing scheduled
        proposeExclusion(cex);
        vm.warp(block.timestamp + 48 hours);
        d.executeExclusion(cex);
        vm.expectRevert(Signers.NotScheduled.selector);
        d.executeExclusion(cex);
        sh = keccak256(abi.encode(APPEND_EXCLUDED_TYPEHASH, cex, d.nonce()));
        vm.expectRevert(abi.encodeWithSelector(NutzDistributor.AlreadyExcluded.selector, cex));
        d.proposeExclusion(cex, sign(KEY_B, sh), sign(KEY_C, sh));
    }

    function test_exclusion_zero_reverts() public {
        bytes32 sh = keccak256(abi.encode(APPEND_EXCLUDED_TYPEHASH, address(0), uint256(0)));
        vm.expectRevert(Signers.ZeroAddress.selector);
        d.proposeExclusion(address(0), sign(KEY_B, sh), sign(KEY_C, sh));
    }

    function test_exclusion_canBeCancelled() public {
        bytes32 id = keccak256(abi.encode(APPEND_EXCLUDED_TYPEHASH, cex));
        proposeExclusion(cex);
        bytes32 sh = keccak256(abi.encode(keccak256("Cancel(bytes32 id,uint256 nonce)"), id, d.nonce()));
        d.cancel(id, sign(KEY_A, sh), sign(KEY_B, sh));
        vm.warp(block.timestamp + 48 hours);
        vm.expectRevert(Signers.NotScheduled.selector);
        d.executeExclusion(cex);
        assertEq(d.excluded().length, 1);
    }
}
