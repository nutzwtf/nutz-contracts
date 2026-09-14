// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {Test, console} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {NutzDistributor} from "../../src/NutzDistributor.sol";
import {NutzConverter} from "../../src/NutzConverter.sol";

/// @dev Uniswap v3 QuoterV2 on chain 4663 (engineering-spec §2.1 `V3_QUOTER`): the Keeper's off-chain quote,
///      called on the fork here. Not a view: it swaps and reverts inside, so it needs a real call.
interface IQuoterV2 {
    function quoteExactInput(bytes memory path, uint256 amountIn)
        external
        returns (
            uint256 amountOut,
            uint160[] memory sqrtPriceX96AfterList,
            uint32[] memory initializedTicksCrossedList,
            uint256 gasEstimate
        );
}

/// @dev Uniswap v4 Quoter on chain 4663 (engineering-spec §2.1 `V4_QUOTER`): quotes the v4 variant of the SPY Leg.
interface IV4Quoter {
    struct QuoteExactSingleParams {
        PoolKey poolKey;
        bool zeroForOne;
        uint128 exactAmount;
        bytes hookData;
    }

    function quoteExactInputSingle(QuoteExactSingleParams memory params)
        external
        returns (uint256 amountOut, uint256 gasEstimate);
}

/// @dev The hourly Sweep against the real Venues and tokens on Robinhood Chain (spec §10). The Distributor and the
///      Converter are deployed as the script does it with the addresses in script/config/robinhood.json; ETH worth
///      about $1k, $10k and $50k is dealt to the unbound Converter; one Sweep per size runs with the Keeper's policy
///      Routes (`minOut` = quote × 0.99); every Leg's realised output must sit within 1% of the v3 Quoter's figure
///      and cost at most `MAX_SLIPPAGE_BPS` against a $100 trade in the same v3 pool; the Distributor must hold
///      exactly what `Swept` reports; the Converter must hold nothing but the ETH above `MAX_SWEEP_ETH`; and every
///      Reward Token must transfer from the Distributor to a fresh EOA.
///      Routes (spec §10): v3 WETH/USDG 0.01%, SPY/USDG 0.05%, NVDA/USDG 0.05%, MU/USDG 0.3%, SPCX/USDG 0.05%, and
///      a variant with SPY on the v4 SPY/USDG (3000, 60) pool. The v4 Leg's `minOut` comes from the v4 Quoter, as
///      the Keeper would quote the Venue it routes through; its output is still held to the v3 quote and the cost
///      bound, so the fallback Venue is measured against the primary one rather than against itself.
///         Skipped unless `RPC_4663` is set (the Chainstack archive URL in .env). `FORK_BLOCK_4663` overrides the
///         pinned block; `FORK_BLOCK_4663=0` forks the latest block, which a non-archive endpoint needs.
contract ConverterForkTest is Test {
    uint256 internal constant FORK_BLOCK = 62_393_542; // 2026-09-13

    // Keeper-side facts (engineering-spec §13): not contract immutables, so not in the deploy config.
    IQuoterV2 internal constant V3_QUOTER = IQuoterV2(0x33e885eD0Ec9bF04EcfB19341582aADCb4c8A9E7);
    IV4Quoter internal constant V4_QUOTER = IV4Quoter(0x8Dc178eFB8111BB0973Dd9d722ebeFF267c98F94);

    /// @dev The Keeper's slippage policy (engineering-spec §5 `MAX_SLIPPAGE_BPS`): `minOut` = quote × 0.99, and the
    ///      realised output is asserted within the same 1% of the quote.
    uint256 internal constant SLIPPAGE_BPS = 100;
    uint256 internal constant TOLERANCE = 0.01e18; // assertApproxEqRel: 1%

    uint24 internal constant FEE_ETH_USDG = 100;
    uint24[4] internal STOCK_FEES = [uint24(500), 500, 3000, 500]; // SPY, NVDA, MU, SPCX
    uint24 internal constant V4_SPY_FEE = 3000;
    int24 internal constant V4_SPY_TICK_SPACING = 60;

    string[5] internal NAMES = ["SPY", "NVDA", "MU", "SPCX", "USDG"];

    address internal keeper = makeAddr("keeper");
    NutzDistributor internal d;
    NutzConverter internal c;

    IERC20[5] internal tok; // SPY, NVDA, MU, SPCX, USDG
    IERC20 internal usdg; // tok[4]
    IERC20 internal weth;
    address internal v3Router;
    address internal v4PoolManager;
    uint256 internal opsCap;

    /// @dev What the Keeper computes before calling `sweep`: the Slices the contract will cut from `ethIn`, the
    ///      Quoter's figure for every Leg (v3 always; the v4 Quoter's as well for the v4 SPY variant, which is what
    ///      that Route's `minOut` follows), and each Leg's cost against a $100 trade in its v3 pool.
    struct Plan {
        uint256 ethIn;
        uint256 opsAmt;
        uint256 usdgOut;
        uint256 perStock;
        uint256 cashUsdg;
        uint256 acornUsdg;
        uint256[4] stockOutV3;
        uint256[4] stockOut; // the Route's own Venue: equals stockOutV3 except for the v4 SPY variant
        uint256[5] costTenths; // tenths of a bp; [4] is ETH->USDG
        NutzConverter.Route[6] routes;
    }

    /// @dev The `Swept` event, decoded.
    struct Swept {
        uint256 ethIn;
        uint256 opsAmt;
        uint256[5] amounts;
        uint256 acornUsdg;
    }

    function setUp() public {
        string memory url = vm.envOr("RPC_4663", string(""));
        if (bytes(url).length == 0) vm.skip(true);
        uint256 blockNumber = vm.envOr("FORK_BLOCK_4663", FORK_BLOCK);
        if (blockNumber == 0) vm.createSelectFork(url);
        else vm.createSelectFork(url, blockNumber);

        (NutzConverter.Params memory p, DistributorArgs memory dp) = _load();
        vm.deal(keeper, 0);
        address predicted = vm.computeCreateAddress(address(this), vm.getNonce(address(this)) + 1);
        d = new NutzDistributor(
            p.signers,
            keeper,
            predicted,
            p.tokens,
            dp.pushGasBase,
            dp.pushGasPerLeaf,
            dp.minUsdgPerEth,
            dp.maxUsdgPerEth,
            dp.excludedBase
        );
        p.distributor = address(d);
        c = new NutzConverter(p);
        assertEq(address(c), predicted, "Converter must land on the predicted address");
    }

    // ---- the runs ----

    function test_sweep_1k_v3() public {
        _sweep(1_000, false);
    }

    function test_sweep_10k_v3() public {
        _sweep(10_000, false);
    }

    function test_sweep_50k_v3() public {
        _sweep(50_000, false);
    }

    function test_sweep_1k_spyOnV4() public {
        _sweep(1_000, true);
    }

    function test_sweep_10k_spyOnV4() public {
        _sweep(10_000, true);
    }

    function test_sweep_50k_spyOnV4() public {
        _sweep(50_000, true);
    }

    /// @dev Deals ETH worth `usd` to the Converter, sweeps it into the current Epoch with the policy Routes and
    ///      checks every post-condition of spec §10. When the deal exceeds `MAX_SWEEP_ETH` (the $50k run does at
    ///      an ETH price under $2,500) the Sweep converts the cap and leaves the rest, spec §6 step 3.
    function _sweep(uint256 usd, bool spyOnV4) internal {
        uint256 dealt = _ethWorth(usd);
        uint256 ethIn = dealt > c.MAX_SWEEP_ETH() ? c.MAX_SWEEP_ETH() : dealt;
        Plan memory plan = _plan(ethIn, spyOnV4);
        vm.deal(address(c), dealt);
        uint256 epoch = d.currentEpoch();

        vm.recordLogs();
        vm.prank(keeper);
        c.sweep(epoch, plan.routes, block.timestamp + 1 hours);
        Swept memory s = _swept(vm.getRecordedLogs());

        // every Leg ran, landed within the policy bound of its v3 quote, and cost at most the policy bound
        assertEq(s.ethIn, ethIn, "ethIn");
        assertEq(s.opsAmt, plan.opsAmt, "opsAmt");
        for (uint256 i = 0; i < 4; i++) {
            assertGt(s.amounts[i], 0, string.concat(NAMES[i], " Leg produced nothing"));
            assertApproxEqRel(s.amounts[i], plan.stockOutV3[i], TOLERANCE, string.concat(NAMES[i], " vs v3 quote"));
        }
        assertApproxEqRel(s.amounts[4], plan.cashUsdg, TOLERANCE, "Cash vs quote");
        assertApproxEqRel(s.acornUsdg, plan.acornUsdg, TOLERANCE, "Acorn vs quote");
        for (uint256 i = 0; i < 5; i++) {
            assertLe(plan.costTenths[i], SLIPPAGE_BPS * 10, string.concat(_legName(i), " costs more than the bound"));
        }

        // the Distributor holds exactly what Swept says, the Keeper got Ops, the Converter is empty
        uint256[5] memory funded = d.ledger(NutzDistributor.Kind.Epoch, epoch).funded;
        for (uint256 i = 0; i < 5; i++) {
            assertEq(funded[i], s.amounts[i], string.concat(NAMES[i], " ledger vs Swept"));
        }
        assertEq(d.acornPoolUsdg(), s.acornUsdg, "acorn pool vs Swept");
        for (uint256 i = 0; i < 4; i++) {
            assertEq(tok[i].balanceOf(address(d)), s.amounts[i], string.concat(NAMES[i], " balance vs Swept"));
        }
        assertEq(usdg.balanceOf(address(d)), s.amounts[4] + s.acornUsdg, "USDG balance vs Swept");
        assertEq(keeper.balance, s.opsAmt, "Ops");
        _assertConverterEmpty(dealt - ethIn);

        _log(usd, plan, s);
        _assertTransferableToFreshEoa(s.amounts);
    }

    // ---- the Keeper's side: quotes and Routes ----

    /// @dev ETH worth `usd` at the WETH/USDG 0.01% pool's current price for one ETH.
    function _ethWorth(uint256 usd) internal returns (uint256) {
        (uint256 usdgPerEth,,,) = V3_QUOTER.quoteExactInput(_ethUsdgPath(), 1 ether);
        return usd * 1e6 * 1e18 / usdgPerEth;
    }

    /// @dev Mirrors spec §6 steps 3–6 on the Quoter's figures: Ops from `ethIn`, the ETH→USDG quote on the rest,
    ///      the Slices, and one stock quote per Leg on `perStock`. The Routes carry `minOut` = quote × 0.99.
    ///      Every Leg's cost is quoted here, before the Sweep moves the pools.
    function _plan(uint256 ethIn, bool spyOnV4) internal returns (Plan memory plan) {
        plan.ethIn = ethIn;
        uint256 headroom = opsCap > keeper.balance ? opsCap - keeper.balance : 0;
        plan.opsAmt = ethIn * c.SPLIT_OPS_BPS() / c.BPS();
        if (plan.opsAmt > headroom) plan.opsAmt = headroom;

        (plan.usdgOut,,,) = V3_QUOTER.quoteExactInput(_ethUsdgPath(), ethIn - plan.opsAmt);
        uint256 stash = plan.usdgOut * c.SPLIT_STASH_BPS() / c.HOLDER_BPS();
        plan.cashUsdg = plan.usdgOut * c.SPLIT_CASH_BPS() / c.HOLDER_BPS();
        plan.acornUsdg = plan.usdgOut - stash - plan.cashUsdg;
        plan.perStock = stash * c.PER_STOCK_BPS() / c.BPS();
        plan.cashUsdg += stash - 4 * plan.perStock;
        plan.costTenths[4] = _costTenths(_ethUsdgPath(), ethIn - plan.opsAmt, plan.usdgOut);

        plan.routes[0] = _v3(abi.encodePacked(address(weth), FEE_ETH_USDG, address(weth)), 0); // unused: NUTZ unbound
        plan.routes[1] = _v3(_ethUsdgPath(), _floor(plan.usdgOut));
        for (uint256 i = 0; i < 4; i++) {
            (plan.stockOutV3[i],,,) = V3_QUOTER.quoteExactInput(_stockPath(i), plan.perStock);
            if (i == 0 && spyOnV4) {
                PoolKey memory key = _key(address(tok[0]), address(usdg), V4_SPY_FEE, V4_SPY_TICK_SPACING);
                (plan.stockOut[i],) = V4_QUOTER.quoteExactInputSingle(
                    IV4Quoter.QuoteExactSingleParams({
                        poolKey: key,
                        zeroForOne: Currency.unwrap(key.currency0) == address(usdg),
                        exactAmount: uint128(plan.perStock),
                        hookData: ""
                    })
                );
                plan.routes[2 + i] = NutzConverter.Route({
                    venue: v4PoolManager, minOut: _floor(plan.stockOut[i]), data: abi.encode(key)
                });
            } else {
                plan.stockOut[i] = plan.stockOutV3[i];
                plan.routes[2 + i] = _v3(_stockPath(i), _floor(plan.stockOut[i]));
            }
            plan.costTenths[i] = _costTenths(_stockPath(i), plan.perStock, plan.stockOut[i]);
        }
    }

    /// @dev "ETH->USDG" for Leg 4, "USDG->SPY" and so on for the Stock Legs, as the cost table names them.
    function _legName(uint256 i) internal view returns (string memory) {
        return i == 4 ? "ETH->USDG" : string.concat("USDG->", NAMES[i]);
    }

    function _stockPath(uint256 i) internal view returns (bytes memory) {
        return abi.encodePacked(address(usdg), STOCK_FEES[i], address(tok[i]));
    }

    function _ethUsdgPath() internal view returns (bytes memory) {
        return abi.encodePacked(address(weth), FEE_ETH_USDG, address(usdg));
    }

    function _v3(bytes memory path, uint256 minOut) internal view returns (NutzConverter.Route memory) {
        return NutzConverter.Route({venue: v3Router, minOut: minOut, data: path});
    }

    /// @dev A hookless v4 key for `a`/`b`, currencies sorted as the pool manager requires.
    function _key(address a, address b, uint24 fee, int24 tickSpacing) internal pure returns (PoolKey memory) {
        (address c0, address c1) = a < b ? (a, b) : (b, a);
        return PoolKey({
            currency0: Currency.wrap(c0),
            currency1: Currency.wrap(c1),
            fee: fee,
            tickSpacing: tickSpacing,
            hooks: IHooks(address(0))
        });
    }

    /// @dev The policy `minOut`: quote less `SLIPPAGE_BPS`.
    function _floor(uint256 quote) internal view returns (uint256) {
        return quote * (c.BPS() - SLIPPAGE_BPS) / c.BPS();
    }

    // ---- post-conditions ----

    /// @dev Decodes `Swept` from the Converter's logs and fails on any `LegSkipped`: on the real Venues every Leg
    ///      must go through.
    function _swept(Vm.Log[] memory logs) internal view returns (Swept memory s) {
        bool found;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].emitter != address(c)) continue;
            if (logs[i].topics[0] == NutzConverter.LegSkipped.selector) {
                bytes memory reason = abi.decode(logs[i].data, (bytes));
                revert(
                    string.concat("Leg ", vm.toString(uint256(logs[i].topics[1])), " skipped: ", vm.toString(reason))
                );
            }
            if (logs[i].topics[0] == NutzConverter.Swept.selector) {
                (s.ethIn, s.opsAmt, s.amounts, s.acornUsdg) =
                    abi.decode(logs[i].data, (uint256, uint256, uint256[5], uint256));
                found = true;
            }
        }
        assertTrue(found, "Swept not emitted");
    }

    /// @dev Spec §6 post-conditions: only the ETH above `MAX_SWEEP_ETH` left, no WETH, no Reward Token, and no
    ///      approval to the Distributor left open.
    function _assertConverterEmpty(uint256 ethLeft) internal view {
        assertEq(address(c).balance, ethLeft, "ETH left behind");
        assertEq(weth.balanceOf(address(c)), 0, "WETH left behind");
        for (uint256 i = 0; i < 5; i++) {
            assertEq(tok[i].balanceOf(address(c)), 0, string.concat(NAMES[i], " left behind"));
            assertEq(tok[i].allowance(address(c), address(d)), 0, string.concat(NAMES[i], " approval left open"));
        }
    }

    /// @dev Engineering-spec §9 Q2 residual: the Stock Tokens (and USDG) the Distributor now holds move to an
    ///      address that has never touched them.
    function _assertTransferableToFreshEoa(uint256[5] memory amounts) internal {
        address recipient = makeAddr("fresh-eoa");
        for (uint256 i = 0; i < 5; i++) {
            uint256 before = tok[i].balanceOf(recipient);
            vm.prank(address(d));
            assertTrue(tok[i].transfer(recipient, amounts[i]), string.concat(NAMES[i], " transfer returned false"));
            assertEq(tok[i].balanceOf(recipient) - before, amounts[i], string.concat(NAMES[i], " transfer to EOA"));
        }
    }

    // ---- the measurement (-vvv) ----

    /// @dev Prints what docs/spec/week1-fork-measurements.md records: the size, the Slices, and per Leg the quote,
    ///      the realised output, and its cost in bps against the unit price of a $100 trade in the v3 pool of that
    ///      Leg, both quoted before the Sweep (price impact for a v3 Leg; venue gap plus impact for the v4 SPY
    ///      variant).
    function _log(uint256 usd, Plan memory plan, Swept memory s) internal view {
        console.log("--- sweep of $%s: ethIn %s wei, ops %s wei", usd, plan.ethIn, plan.opsAmt);
        console.log("ETH->USDG: quote %s, cost %s bps", plan.usdgOut, _bps(plan.costTenths[4]));
        console.log("perStock %s USDG, cash %s, acorn %s", plan.perStock, s.amounts[4], s.acornUsdg);
        for (uint256 i = 0; i < 4; i++) {
            console.log(
                string.concat(_legName(i), ": quote %s, realised %s, cost vs $100 v3 trade %s bps"),
                plan.stockOut[i],
                s.amounts[i],
                _bps(plan.costTenths[i])
            );
        }
    }

    /// @dev Cost of the quote `amountOut` for `amountIn` against the unit price of a $100 trade along the v3
    ///      `path`, in tenths of a bp; zero when the reference trade is at least as large or the price was better.
    function _costTenths(bytes memory path, uint256 amountIn, uint256 amountOut) internal returns (uint256) {
        uint256 refIn = amountIn * 100 / _usdOf(path, amountIn);
        if (refIn == 0 || refIn >= amountIn) return 0;
        (uint256 refOut,,,) = V3_QUOTER.quoteExactInput(path, refIn);
        uint256 expected = refOut * amountIn / refIn;
        return expected > amountOut ? (expected - amountOut) * 100_000 / expected : 0;
    }

    /// @dev "12.3" for 123 tenths of a bp.
    function _bps(uint256 tenths) internal pure returns (string memory) {
        return string.concat(vm.toString(tenths / 10), ".", vm.toString(tenths % 10));
    }

    /// @dev Dollars in `amountIn` of the first token of `path`: USDG at face value, WETH through its own quote.
    function _usdOf(bytes memory path, uint256 amountIn) internal returns (uint256) {
        address first;
        assembly ("memory-safe") {
            first := shr(96, mload(add(path, 32)))
        }
        if (first == address(usdg)) return amountIn / 1e6 + 1;
        (uint256 usdgOut,,,) = V3_QUOTER.quoteExactInput(_ethUsdgPath(), amountIn);
        return usdgOut / 1e6 + 1;
    }

    // ---- config ----

    /// @dev The Distributor's own constructor arguments from the deploy config.
    struct DistributorArgs {
        uint256 pushGasBase;
        uint256 pushGasPerLeaf;
        uint256 minUsdgPerEth;
        uint256 maxUsdgPerEth;
        address[] excludedBase;
    }

    /// @dev Both contracts' constructor arguments from the deploy config, with test Signers and Keeper and the
    ///      Distributor's address left for `setUp` to fill in.
    function _load() internal returns (NutzConverter.Params memory p, DistributorArgs memory dp) {
        string memory json = vm.readFile(string.concat(vm.projectRoot(), "/script/config/robinhood.json"));
        dp.pushGasBase = vm.parseJsonUint(json, ".pushGasBase");
        dp.pushGasPerLeaf = vm.parseJsonUint(json, ".pushGasPerLeaf");
        dp.minUsdgPerEth = vm.parseJsonUint(json, ".minUsdgPerEth");
        dp.maxUsdgPerEth = vm.parseJsonUint(json, ".maxUsdgPerEth");
        dp.excludedBase = vm.parseJsonAddressArray(json, ".excludedBase");

        string[5] memory keys = ["spy", "nvda", "mu", "spcx", "usdg"];
        for (uint256 i = 0; i < 5; i++) {
            tok[i] = IERC20(vm.parseJsonAddress(json, string.concat(".tokens.", keys[i])));
        }
        usdg = tok[4];
        weth = IERC20(vm.parseJsonAddress(json, ".weth"));
        v3Router = vm.parseJsonAddress(json, ".v3Router");
        v4PoolManager = vm.parseJsonAddress(json, ".v4PoolManager");
        opsCap = vm.parseJsonUint(json, ".opsCapWei");

        p.signers = [makeAddr("signer-a"), makeAddr("signer-b"), makeAddr("signer-c")];
        p.keeper = keeper;
        p.tokens = tok;
        p.weth = address(weth);
        p.v3Router = v3Router;
        p.v4PoolManager = v4PoolManager;
        p.ponsFactory = vm.parseJsonAddress(json, ".ponsFactory");
        p.ponsEscrow = vm.parseJsonAddress(json, ".ponsEscrow");
        p.ponsHook = vm.parseJsonAddress(json, ".ponsHook");
        p.opsCap = opsCap;
    }
}
