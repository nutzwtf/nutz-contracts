// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {NutzConverter} from "../../src/NutzConverter.sol";
import {ConverterBase} from "../harness/ConverterBase.sol";
import {StorageSlots} from "../harness/StorageSlots.sol";
import {MockFixedOutRouter} from "../mocks/MockFixedOutRouter.sol";

/// @dev Symbolic check (`forge test --symbolic`) of the Sweep's split: the Ops Slice never exceeds 2% of the swept
///      ETH nor tops the Keeper's wallet above `opsCap`, a Sweep never converts more than `MAX_SWEEP_ETH`, and the
///      USDG floor `ethIn * minUsdgPerEth / 1e18` cannot overflow for any rate the Signers could plausibly set. The
///      solver owns the Converter's ETH balance, the Keeper's balance, `opsCap` and the Distributor's
///      `minUsdgPerEth`, one or two at a time; the Venue pays a fixed amount and the four stock Legs are disabled,
///      since neither enters the split. Runs only with `--symbolic`; see docs/setup/tools.md.
contract ConverterSplit is ConverterBase {
    /// @dev `(ethIn - ops) * minUsdgPerEth` overflows from about 5.79e57 raw USDG per ETH (2^256 / 20 ETH); the
    ///      check covers every rate below 1e57, forty orders of magnitude past any price, and documents the rest.
    uint256 internal constant MIN_RATE_BOUND = 1e57;
    /// @dev Bounds that keep the checked-multiplication guards inside the engine's interval reasoning (see
    ///      DistributorPushFee.t.sol): 1e30 wei is a trillion ETH.
    uint256 internal constant BALANCE_BOUND = 1e30;

    MockFixedOutRouter internal venue;

    function setUp() public override {
        super.setUp();
        // The Venue pays a free amount instead of `amountIn * rate / 1e18`: that division is what Z3 cannot see
        // through once `amountIn` is symbolic. Etched over the fixture's router so the Converter's immutable holds.
        vm.etch(address(router), type(MockFixedOutRouter).runtimeCode);
        venue = MockFixedOutRouter(address(router));
        tok[4].mint(address(venue), type(uint256).max - tok[4].totalSupply());
        for (uint8 i = 0; i < 4; i++) {
            disableLeg(i);
        }
    }

    // ---- Ops Slice <= 2% and <= opsCap headroom; ethIn <= MAX_SWEEP_ETH; the floor product cannot overflow ----
    //
    // One symbolic quantity through one division per check (docs/setup/tools.md): the Venue pays a fixed amount,
    // the floor is switched off (a zero rate, which the setter forbids but the check does not need) while the split
    // is under test, and the split is pinned (opsCap 0) while the floor is.

    uint256 internal constant USDG_OUT = 3_000e6;

    /// @dev Runs one Sweep and asserts what holds on every path.
    function sweepFor(uint256 balance, uint256 keeperBefore, uint256 opsCap, uint256 minRate) internal {
        vm.deal(address(c), balance);
        vm.deal(keeper, keeperBefore);
        vm.store(address(c), bytes32(StorageSlots.OPS_CAP), bytes32(opsCap));
        vm.store(address(d), bytes32(StorageSlots.MIN_USDG_PER_ETH), bytes32(minRate));
        venue.set(address(weth), USDG_OUT);
        uint256 maxSweep = c.MAX_SWEEP_ETH();
        uint256 ethIn = balance > maxSweep ? maxSweep : balance;
        // Built before the prank: `currentEpoch()` is an external call and would consume it.
        uint256 epochId = d.currentEpoch();
        NutzConverter.Route[6] memory routes = sweepRoutes();

        vm.prank(keeper);
        try c.sweep(epochId, routes, block.timestamp) {
            uint256 ops = keeper.balance - keeperBefore;
            assertLe(ops, ethIn * c.SPLIT_OPS_BPS() / c.BPS(), "Ops Slice above 2% of the swept ETH");
            assertLe(
                keeper.balance, keeperBefore > opsCap ? keeperBefore : opsCap, "ops topped the Keeper above opsCap"
            );
            assertEq(address(c).balance, balance - ethIn, "swept more than MAX_SWEEP_ETH, or left ETH unswept");
            assertGe(USDG_OUT, (ethIn - ops) * minRate / 1e18, "accepted a Venue payment under the floor");
            assertEq(tok[4].balanceOf(address(c)), 0, "USDG left in the Converter");
        } catch (bytes memory err) {
            // The only admissible revert is the Venue paying under the Signer-set floor: a Panic would be the overflow.
            assertEq(bytes4(err), NutzConverter.UsdgBelowFloor.selector, "sweep reverted for another reason");
            // Only the floor checks can land here, and they run with opsCap 0, so the Slice the floor saw was zero.
            assertEq(opsCap, 0, "a floor revert in a check that pays an Ops Slice: the oracle below assumes none");
            assertLt(USDG_OUT, ethIn * minRate / 1e18, "floor rejected a Venue payment at or above it");
            assertEq(keeper.balance, keeperBefore, "a reverted Sweep must not pay the Keeper");
        }
    }

    /// @dev The 2% formula over any balance up to the cap, at a headroom that never binds (an empty Keeper wallet,
    ///      0.5 ETH cap: 2% of 20 ETH is 0.4 ETH) and at one that binds from 0.5 ETH swept on (0.01 ETH left to
    ///      the cap). The headroom is fixed here because `ethIn * SPLIT_OPS_BPS / BPS` against a free `opsCap - balance`
    ///      is another query Z3 does not answer; the headroom logic over free values is the two checks below.
    function check_sweep_opsSlice_anyBalance_headroomOpen(uint256 balance) external {
        vm.assume(balance != 0 && balance <= c.MAX_SWEEP_ETH()); // zero is NothingToSweep, before any arithmetic
        sweepFor(balance, 0, OPS_CAP, 0);
    }

    function check_sweep_opsSlice_anyBalance_headroomBinds(uint256 balance) external {
        vm.assume(balance != 0 && balance <= c.MAX_SWEEP_ETH());
        sweepFor(balance, OPS_CAP - 0.01 ether, OPS_CAP, 0);
    }

    /// @dev The cap and the headroom logic: balances over MAX_SWEEP_ETH sweep exactly MAX_SWEEP_ETH, and the split
    ///      holds for any Keeper balance and opsCap. Two concrete balances: with the balance free the engine cannot
    ///      see `min(balance, cap)` before `ethIn * SPLIT_OPS_BPS` and hands the overflow guard to Z3, which does not answer.
    function check_sweep_capsEthIn_justOver(uint256 keeperBefore, uint256 opsCap) external {
        vm.assume(keeperBefore <= BALANCE_BOUND && opsCap <= c.MAX_OPS_CAP_WEI());
        sweepFor(c.MAX_SWEEP_ETH() + 1, keeperBefore, opsCap, 0);
    }

    function check_sweep_capsEthIn_trillionEth(uint256 keeperBefore, uint256 opsCap) external {
        vm.assume(keeperBefore <= BALANCE_BOUND && opsCap <= c.MAX_OPS_CAP_WEI());
        sweepFor(BALANCE_BOUND, keeperBefore, opsCap, 0);
    }

    /// @dev The floor against any swept amount at the fixture's rate; no Ops Slice (opsCap 0).
    function check_sweep_floor_anyBalance(uint256 balance) external {
        vm.assume(balance != 0 && balance <= c.MAX_SWEEP_ETH());
        sweepFor(balance, 0, 0, 1_000e6);
    }

    /// @dev The floor product for any rate up to MIN_RATE_BOUND at a full MAX_SWEEP_ETH Sweep, the largest `ethIn`
    ///      the product can see; no Ops Slice (opsCap 0).
    function check_sweep_floor_anyRate(uint256 minRate) external {
        vm.assume(minRate != 0 && minRate <= MIN_RATE_BOUND); // setRateRange enforces the first half
        sweepFor(c.MAX_SWEEP_ETH(), 0, 0, minRate);
    }
}
