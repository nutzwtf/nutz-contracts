// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {NutzDistributor} from "../../src/NutzDistributor.sol";
import {DistributorBase} from "../harness/DistributorBase.sol";
import {StorageSlots} from "../harness/StorageSlots.sol";

/// @dev Symbolic checks (`forge test --symbolic`) of the push-fee bound engineering-spec §6 "keeper key compromise"
///      relies on: whatever gas price and rate the Keeper reports, the fee taken from a Holder's USDG is at most
///      `MAX_PUSH_FEE_BPS` of it, the Keeper is paid that fee and nothing else, and the rate must sit in the
///      Signer-set range. Leaves are planted as Roots (`DistributorBase.plantFinalRoot`), so no proof constrains the
///      search. The solver never owns both sides of the cap comparison at once, and every input carries a bound far
///      past anything real (a gas price up to a million gwei, rates up to 1e30 raw USDG per ETH, 1e40 raw USDG per
///      Holder), because Z3 does not answer otherwise (docs/setup/tools.md); above the bounds the multiplications
///      revert under checked arithmetic, which is the fuzz test's territory. Stock amounts stay concrete: they never
///      enter the fee. Manual; see tools.md.
contract DistributorPushFee is DistributorBase {
    uint256 internal constant E = DEPLOY_EPOCH;
    uint256 internal constant MAX = type(uint256).max;
    uint256 internal constant GAS_PRICE_BOUND = 1e15;
    uint256 internal constant RATE_BOUND = 1e30;
    uint256 internal constant USDG_BOUND = 1e40;

    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");

    function setUp() public override {
        super.setUp();
        fundDistributorToTheMax();
    }

    /// @dev Plants `(E, alice, a)` as the single leaf of a Final Root with no binding totals.
    function plantLeaf(uint256[5] memory a) internal {
        plantFinalRoot(E, leafOf(E, alice, a));
        plantLedgerArray(E, StorageSlots.LEDGER_TOTALS, amounts(MAX, MAX, MAX, MAX, MAX));
    }

    function entryFor1(address account, uint256[5] memory a, Claim[] memory claims, uint256 index)
        internal
        view
        returns (NutzDistributor.PushEntry memory)
    {
        uint256[] memory ids = new uint256[](1);
        ids[0] = E;
        return entryFor(account, EPOCH, ids, a, claims, index);
    }

    function oneEntry(uint256[5] memory a) internal view returns (NutzDistributor.PushEntry[] memory entries) {
        entries = new NutzDistributor.PushEntry[](1);
        Claim[] memory claims = new Claim[](1);
        claims[0] = Claim(alice, a);
        entries[0] = entryFor1(alice, a, claims, 0);
    }

    // ---- the fee never exceeds MAX_PUSH_FEE_BPS of the pushed USDG; the Keeper gets the fee, no more ----

    /// @dev Any pushed USDG against a fixed fee. With the gas price free as well, the fee's `/ 1e18` and the cap's
    ///      `/ 10_000` meet in one query and Z3 does not answer; the formula is `check_push_feeFormulaAndRateRange`'s.
    function feeBoundFor(uint256 usdg, uint256 gasPriceWei) internal {
        uint256 rate = 4_000e6;
        uint256[5] memory a = amounts(1e18, 0, 2e18, 0, usdg);
        plantLeaf(a);
        NutzDistributor.PushEntry[] memory entries = oneEntry(a);
        uint256 fee = (d.PUSH_GAS_BASE() + d.PUSH_GAS_PER_LEAF()) * gasPriceWei * rate / 1e18; // concrete
        uint256 bps = d.MAX_PUSH_FEE_BPS();

        vm.prank(keeper);
        try d.pushClaims(entries, gasPriceWei, rate) {
            assertEq(tok[4].balanceOf(keeper), fee, "the Keeper received something other than the fee");
            assertLe(fee, usdg * bps / 10_000, "fee above MAX_PUSH_FEE_BPS of the pushed USDG");
            assertEq(tok[4].balanceOf(alice), usdg - fee, "Holder short-changed beyond the fee");
            assertEq(tok[0].balanceOf(alice), a[0], "Stock Tokens are not fee-bearing");
            assertEq(tok[2].balanceOf(alice), a[2]);
            assertEq(tok[0].balanceOf(keeper), 0);
            assertTrue(d.claimed(EPOCH, E, alice));
        } catch (bytes memory err) {
            assertRevertData(err, abi.encodeWithSelector(NutzDistributor.PushFeeTooHigh.selector, alice));
            assertGt(fee, usdg * bps / 10_000, "refused a fee inside the bound");
            assertEq(tok[4].balanceOf(keeper), 0, "a rejected push must pay the Keeper nothing");
            assertFalse(d.claimed(EPOCH, E, alice));
        }
    }

    /// @dev 0.1 gwei at 4,000 USDG/ETH: the unit tests' one-leaf fee of 0.056 USDG.
    function check_push_feeBound_anyUsdg_typicalGas(uint256 usdg) external {
        vm.assume(usdg <= USDG_BOUND);
        feeBoundFor(usdg, 1e8);
    }

    /// @dev 1,000 gwei: a fee of 560 USDG, so only Holders with 11,200 USDG or more are pushed.
    function check_push_feeBound_anyUsdg_spikeGas(uint256 usdg) external {
        vm.assume(usdg <= USDG_BOUND);
        feeBoundFor(usdg, 1e12);
    }

    /// @dev Any gas price, rate and Signer range at a fixed leaf: the fee is exactly the formula, in range only.
    function check_push_feeFormulaAndRateRange(
        uint256 gasPriceWei,
        uint256 usdgPerEth,
        uint256 minRate,
        uint256 maxRate
    ) external {
        vm.assume(gasPriceWei <= GAS_PRICE_BOUND && usdgPerEth <= RATE_BOUND && maxRate <= RATE_BOUND);
        vm.assume(minRate != 0 && minRate <= maxRate); // the constructor and setRateRange enforce this
        vm.store(address(d), bytes32(StorageSlots.MIN_USDG_PER_ETH), bytes32(minRate));
        vm.store(address(d), bytes32(StorageSlots.MAX_USDG_PER_ETH), bytes32(maxRate));
        uint256[5] memory a = amounts(1e18, 0, 2e18, 0, 1_000_000e6);
        plantLeaf(a);
        NutzDistributor.PushEntry[] memory entries = oneEntry(a);
        uint256 gasUnits = d.PUSH_GAS_BASE() + d.PUSH_GAS_PER_LEAF();
        uint256 cap = a[4] * d.MAX_PUSH_FEE_BPS() / 10_000;
        uint256 fee = gasUnits * gasPriceWei * usdgPerEth / 1e18; // the contract's formula, same operation order

        vm.prank(keeper);
        try d.pushClaims(entries, gasPriceWei, usdgPerEth) {
            assertTrue(usdgPerEth >= minRate && usdgPerEth <= maxRate, "rate outside the Signer-set range");
            assertLe(fee, cap);
            assertEq(tok[4].balanceOf(keeper), fee, "the Keeper received something other than the fee");
            assertEq(tok[4].balanceOf(alice), a[4] - fee);
            assertEq(tok[0].balanceOf(alice), a[0]);
            assertEq(tok[2].balanceOf(alice), a[2]);
        } catch (bytes memory err) {
            if (usdgPerEth < minRate || usdgPerEth > maxRate) {
                assertRevertData(err, abi.encodeWithSelector(NutzDistributor.RateOutOfRange.selector, usdgPerEth));
            } else {
                assertRevertData(err, abi.encodeWithSelector(NutzDistributor.PushFeeTooHigh.selector, alice));
                assertGt(fee, cap, "refused a fee inside the bound");
            }
            assertEq(tok[4].balanceOf(keeper), 0, "a rejected push must pay the Keeper nothing");
            assertFalse(d.claimed(EPOCH, E, alice));
        }
    }

    /// @dev Two Holders in one batch, any gas price and rate in the fixture's range: the Keeper is paid the sum of
    ///      the two fees and each Holder is charged its own, so a batch cannot bill one Holder for another's leaf.
    function check_push_twoEntries_keeperGetsTheSumOfFees(uint256 gasPriceWei, uint256 usdgPerEth) external {
        vm.assume(gasPriceWei <= GAS_PRICE_BOUND && usdgPerEth >= MIN_RATE && usdgPerEth <= MAX_RATE);
        Claim[] memory claims = new Claim[](2);
        claims[0] = Claim(alice, amounts(1e18, 0, 0, 0, 1_000_000e6));
        claims[1] = Claim(bob, amounts(0, 2e18, 0, 0, 5_000_000e6));
        plantFinalRoot(E, rootOf(E, claims));
        plantLedgerArray(E, StorageSlots.LEDGER_TOTALS, amounts(MAX, MAX, MAX, MAX, MAX));
        NutzDistributor.PushEntry[] memory entries = new NutzDistributor.PushEntry[](2);
        entries[0] = entryFor1(alice, claims[0].amounts, claims, 0);
        entries[1] = entryFor1(bob, claims[1].amounts, claims, 1);
        uint256 fee = (d.PUSH_GAS_BASE() + d.PUSH_GAS_PER_LEAF()) * gasPriceWei * usdgPerEth / 1e18; // per entry
        uint256 aliceCap = claims[0].amounts[4] * d.MAX_PUSH_FEE_BPS() / 10_000;

        vm.prank(keeper);
        try d.pushClaims(entries, gasPriceWei, usdgPerEth) {
            assertEq(tok[4].balanceOf(keeper), fee + fee, "the Keeper received something other than both fees");
            assertEq(tok[4].balanceOf(alice), claims[0].amounts[4] - fee, "alice charged more than her fee");
            assertEq(tok[4].balanceOf(bob), claims[1].amounts[4] - fee, "bob charged more than his fee");
            assertEq(tok[0].balanceOf(alice), 1e18);
            assertEq(tok[1].balanceOf(bob), 2e18);
        } catch (bytes memory err) {
            // alice has the smaller USDG, so hers is the entry that trips the bound; bob's would pass alone.
            assertRevertData(err, abi.encodeWithSelector(NutzDistributor.PushFeeTooHigh.selector, alice));
            assertGt(fee, aliceCap, "refused a fee inside the bound");
            assertEq(tok[4].balanceOf(keeper), 0, "a rejected batch must pay the Keeper nothing");
            assertFalse(d.claimed(EPOCH, E, bob), "one bad entry must revert the whole batch");
        }
    }
}
