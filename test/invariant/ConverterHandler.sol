// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolId} from "v4-core/types/PoolId.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {NutzConverter} from "../../src/NutzConverter.sol";
import {NutzDistributor} from "../../src/NutzDistributor.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {MockWETH} from "../mocks/MockWETH.sol";
import {MockSwapRouter02} from "../mocks/MockSwapRouter02.sol";
import {MockPoolManager} from "../mocks/MockPoolManager.sol";
import {MockNutzDraw} from "../mocks/MockNutzDraw.sol";
import {MockPonsEscrow} from "../mocks/pons/MockPonsEscrow.sol";
import {MockPonsFactory} from "../mocks/pons/MockPonsFactory.sol";
import {MockPonsCurve} from "../mocks/pons/MockPonsCurve.sol";
import {MockPonsHook} from "../mocks/pons/MockPonsHook.sol";
import {IPonsV2LaunchFactory} from "../../src/interfaces/pons/IPonsV2LaunchFactory.sol";

/// @dev Drives the Converter through bounded, always-succeeding actions (spec §9): ETH and NUTZ arriving, Venue
///      rates and per-token failure switches, the Circuit breaker, the ops cap, Sweeps and Acorn conversions
///      with valid Routes over either Venue. fail_on_revert is on, so every action pre-checks its own
///      preconditions. What one Sweep or Acorn conversion did is measured here, from the balances around the
///      call and the token `Transfer` logs inside it, and kept in a record the invariants read back.
contract ConverterHandler is Test {
    NutzConverter internal c;
    NutzDistributor internal d;
    MockERC20[5] internal tok;
    MockWETH internal weth;
    MockSwapRouter02 internal router;
    MockPoolManager internal pm;
    MockPonsEscrow internal escrow;
    MockPonsFactory internal factory;
    MockPonsHook internal hook;
    MockNutzDraw internal draw;
    address internal keeper;
    uint256[3] internal keys;

    NutzDistributor.Kind internal constant EPOCH = NutzDistributor.Kind.Epoch;
    NutzDistributor.Kind internal constant DRAW = NutzDistributor.Kind.Draw;
    address internal constant ETH = address(0);
    uint24 internal constant FEE = 500;
    uint256 internal constant INVENTORY = 1e33; // more than any run can draw from a Venue

    bytes32 internal constant DOMAIN_TYPEHASH =
        keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");
    bytes32 internal constant SET_OPS_CAP_TYPEHASH = keccak256("SetOpsCap(uint256 cap,uint256 nonce)");
    bytes32 internal constant DISABLE_LEG_TYPEHASH = keccak256("DisableLeg(uint8 stock,uint256 nonce)");
    bytes32 internal constant ENABLE_LEG_TYPEHASH = keccak256("EnableLeg(uint8 stock,uint256 nonce)");
    bytes32 internal constant CANCEL_TYPEHASH = keccak256("Cancel(bytes32 id,uint256 nonce)");
    bytes32 internal constant SET_KEEPER_TYPEHASH = keccak256("SetKeeper(address keeper,uint256 nonce)");

    // ---- what one call did, measured around it ----

    /// @dev Where USDG moved inside one call, read from its `Transfer` logs.
    struct UsdgFlows {
        uint256 fromVenues; // paid to the Converter by a Venue: the ETH -> USDG Leg's output
        uint256 toVenues; // paid by the Converter to a Venue: the stock Legs' input
        uint256 toDistributor; // funded
        uint256 fromDistributor; // the Acorn pull
    }

    struct SweepRecord {
        uint256 count; // Sweeps so far; zero means no record yet
        // ETH the Converter held once the Fee pull and the NUTZ sale were done: the balance before the call plus
        // `FeesPulled.claimed` and `NutzSold.ethOut`, the contract's own report of what those two brought in. A
        // misreport would not hide here: `ghostEthArrived` is fed the same two figures, and the ETH conservation
        // invariant checks it against the balance the chain actually holds.
        uint256 balanceBefore;
        uint256 balanceAfter;
        uint256 ethIn; // B, from `Swept`
        uint256 opsAmt;
        uint256 opsCap; // at the time of the Sweep
        uint256 keeperBefore;
        uint256 keeperAfter;
        uint256 ethToVenues; // what the Venues gained, net of the NUTZ sale's proceeds
        UsdgFlows usdg;
        uint256[5] amounts; // from `Swept`
        uint256 acornUsdg;
        uint256[5] fundedDelta; // the Epoch ledger's change
        uint256 acornPoolDelta;
    }

    struct AcornRecord {
        uint256 count; // conversions so far; zero means no record yet
        uint256 usdgIn; // from `AcornConverted`
        UsdgFlows usdg;
        uint256[5] amounts; // from `AcornConverted`
        uint256[5] fundedDelta; // the Acorn Draw ledger's change
    }

    SweepRecord internal sweepRecord;
    AcornRecord internal acornRecord;

    // ---- ghosts ----
    uint256 public ghostEthArrived; // direct sends, escrow claims and NUTZ sale proceeds
    uint256 public ghostEthSwept; // Σ Swept.ethIn
    uint256[5] public ghostSweptAmounts; // Σ Swept.amounts
    uint256 public ghostAcornAdded; // Σ Swept.acornUsdg
    uint256 public ghostAcornPulled; // Σ AcornConverted.usdgIn
    uint256[5] public ghostAcornAmounts; // Σ AcornConverted.amounts
    uint256 public ghostDisabledLegSwaps; // stock token movements while its Leg was disabled
    // Legs whose `LegSkipped(leg, "disabled")` disagreed with the Circuit breaker as the call saw it
    uint256 public ghostDisabledSkipsWrong;
    // Sweeps that found no ETH and no escrow credit and lived on the Fee pull and the NUTZ sale alone. A coverage
    // counter, not an invariant's input: it shows the path is driven (a temporary `== 0` assertion fails at once).
    uint256 public ghostFeeOnlySweeps;
    bool[4] public ghostDisabled; // the Circuit breaker as `disable` and `executeEnable` left it
    uint256 public ghostStrangerMoves; // calls by a non-Keeper that did not revert

    uint256[] public fundedEpochs;
    uint256[] public fundedDraws;
    mapping(uint256 id => bool) internal epochSeen;
    mapping(uint256 id => bool) internal drawSeen;
    address internal stranger = makeAddr("stranger");

    // ---- the NUTZ launch, registered at construction and bound by an action ----
    MockERC20 internal nutzToken;
    MockPonsCurve internal curve;
    IPonsV2LaunchFactory.LaunchedToken internal launch;
    uint24 internal constant NUTZ_POOL_FEE = 10_000;
    int24 internal constant NUTZ_TICK_SPACING = 200;

    /// @dev Everything the fixture deployed, handed over in one struct.
    struct Fixture {
        NutzConverter c;
        NutzDistributor d;
        MockERC20[5] tok;
        MockWETH weth;
        MockSwapRouter02 router;
        MockPoolManager pm;
        MockPonsEscrow escrow;
        MockPonsFactory factory;
        MockPonsHook hook;
        MockNutzDraw draw;
        address keeper;
        uint256[3] keys;
    }

    constructor(Fixture memory f) {
        c = f.c;
        d = f.d;
        tok = f.tok;
        weth = f.weth;
        router = f.router;
        pm = f.pm;
        escrow = f.escrow;
        factory = f.factory;
        hook = f.hook;
        draw = f.draw;
        keeper = f.keeper;
        keys = f.keys;

        // Venue inventories: every Reward Token, ETH for v4 output, and WETH for v3 ETH output.
        for (uint256 i = 0; i < 5; i++) {
            tok[i].mint(address(router), INVENTORY);
            tok[i].mint(address(pm), INVENTORY);
        }
        vm.deal(address(pm), INVENTORY);
        vm.deal(address(router), INVENTORY);
        vm.prank(address(router));
        weth.deposit{value: INVENTORY}();

        // The NUTZ launch: ETH-quoted, this Converter as creator fee recipient, the curve's creator likewise,
        // the hook's pool registered under the id the Converter rebuilds; the protocol keeps 10% of fees.
        nutzToken = new MockERC20("NUTZ", "NUTZ");
        curve = new MockPonsCurve(escrow, address(c));
        launch.token = address(nutzToken);
        launch.curve = address(curve);
        launch.deployer = keeper;
        launch.creatorFeeRecipient = address(c);
        launch.graduationThreshold = 4 ether;
        launch.poolFee = NUTZ_POOL_FEE;
        launch.tickSpacing = NUTZ_TICK_SPACING;
        launch.creatorTaxBps = 100;
        launch.exists = true;
        factory.setLaunchedToken(address(nutzToken), launch);
        hook.register(_nutzPoolId(), address(nutzToken), address(c));
        curve.setProtocolFeeShareBps(1000);
        hook.setProtocolFeeShareBps(1000);

        // Opening rates: 1e18 NUTZ -> 1e12 wei; 1 ETH -> 3,000 USDG; SPY $500, NVDA $100, MU $250, SPCX $10.
        uint256[6] memory rates = [uint256(1e12), 3_000e6, 2e27, 1e28, 4e27, 1e29];
        for (uint256 leg = 0; leg < 6; leg++) {
            _setRate(leg, false, rates[leg]);
            _setRate(leg, true, rates[leg]);
        }
    }

    // ------------------------------------------------------------- actions

    function warp(uint256 secs) external {
        vm.warp(block.timestamp + bound(secs, 1 minutes, 1 days));
    }

    /// @dev ETH paid straight to the Converter, as Pons's owner-only rescue does.
    function receiveEth(uint256 amount) external {
        amount = bound(amount, 0, 30 ether);
        if (amount == 0) return;
        vm.deal(address(this), amount);
        (bool ok,) = address(c).call{value: amount}("");
        require(ok, "receive refused");
        ghostEthArrived += amount;
    }

    /// @dev The Keeper's wallet balance moves outside the Converter: it pays gas, or gets topped up by hand.
    function keeperWalletMoves(uint256 balance) external {
        vm.deal(keeper, bound(balance, 0, 1 ether));
    }

    /// @dev Reprices one Leg on one Venue. ETH -> USDG stays inside the Distributor's floor so a Sweep can
    ///      always find a Route; any other Leg may lose its rate entirely, which the Venue reports as a revert.
    function setRate(uint256 leg, bool v4, uint256 rate) external {
        leg = bound(leg, 0, 5);
        if (leg == 0) rate = bound(rate, 0, 1e15);
        else if (leg == 1) rate = bound(rate, d.minUsdgPerEth(), 10 * d.maxUsdgPerEth());
        else rate = bound(rate, 0, 1e30);
        _setRate(leg, v4, rate);
    }

    /// @dev Flips the failure switch of one Leg's output on one Venue.
    function setFailure(uint256 leg, bool v4, bool on) external {
        leg = bound(leg, 0, 5);
        if (v4) pm.setReverts(_key(leg), on);
        else router.setReverts(_v3Out(leg), on);
    }

    // ---- governance ----

    /// @dev The Circuit breaker, signed by two Signers; a no-op when the Leg is already disabled.
    function disable(uint256 stockSeed) external {
        uint8 stock = uint8(bound(stockSeed, 0, 3));
        if (c.legDisabled(stock)) return;
        bytes32 sh = keccak256(abi.encode(DISABLE_LEG_TYPEHASH, stock, c.nonce()));
        c.disableLeg(stock, _sign(keys[0], sh), _sign(keys[1], sh));
        ghostDisabled[stock] = true;
    }

    /// @dev Schedules enabling a disabled Leg; an expired proposal is cancelled first, a live one left alone.
    function proposeEnable(uint256 stockSeed) external {
        uint8 stock = uint8(bound(stockSeed, 0, 3));
        if (!c.legDisabled(stock)) return;
        bytes32 id = keccak256(abi.encode(ENABLE_LEG_TYPEHASH, stock));
        uint256 ready = c.readyAt(id);
        if (ready != 0) {
            if (block.timestamp <= ready + c.PROPOSAL_TTL()) return;
            bytes32 ch = keccak256(abi.encode(CANCEL_TYPEHASH, id, c.nonce()));
            c.cancel(id, _sign(keys[0], ch), _sign(keys[2], ch));
        }
        bytes32 sh = keccak256(abi.encode(ENABLE_LEG_TYPEHASH, stock, c.nonce()));
        c.proposeLegEnable(stock, _sign(keys[1], sh), _sign(keys[2], sh));
    }

    /// @dev Executes a scheduled enable once its timelock has elapsed and before it expires; anyone may.
    function executeEnable(uint256 stockSeed) external {
        uint8 stock = uint8(bound(stockSeed, 0, 3));
        uint256 ready = c.readyAt(keccak256(abi.encode(ENABLE_LEG_TYPEHASH, stock)));
        if (ready == 0 || block.timestamp < ready || block.timestamp > ready + c.PROPOSAL_TTL()) return;
        c.executeLegEnable(stock);
        ghostDisabled[stock] = false;
    }

    function setOpsCap(uint256 cap) external {
        cap = bound(cap, 0, c.MAX_OPS_CAP_WEI());
        bytes32 sh = keccak256(abi.encode(SET_OPS_CAP_TYPEHASH, cap, c.nonce()));
        c.setOpsCap(cap, _sign(keys[0], sh), _sign(keys[2], sh));
    }

    // ---- NUTZ ----

    /// @dev The Keeper binds the launch; once is enough, and every Sweep before it runs unbound.
    function bindNutz() external {
        if (_nutzBound()) return;
        vm.prank(keeper);
        c.bindNutz(address(nutzToken));
    }

    /// @dev NUTZ paid to the Converter, as Pons's owner-only pool rescue does; it waits until bound and sold.
    function receiveNutz(uint256 amount) external {
        amount = bound(amount, 0, 1e24);
        if (amount > 0) nutzToken.mint(address(c), amount);
    }

    /// @dev Moves the launch through Pons's phases; only 0 (curve) and 2 (hook) have anything to pull.
    function setPhase(uint256 phase) external {
        launch.phase = uint8(bound(phase, 0, 3));
        factory.setLaunchedToken(address(nutzToken), launch);
    }

    /// @dev Creator fees and tax accrue on the curve, with the ETH behind them.
    function accrueCurveFees(uint256 fee, uint256 tax) external {
        fee = bound(fee, 0, 1 ether);
        tax = bound(tax, 0, 0.1 ether);
        curve.setBalances(curve.quoteFeeBalance() + fee, curve.creatorTaxBalance() + tax);
        vm.deal(address(curve), address(curve).balance + fee + tax);
    }

    /// @dev Fees and tax accrue on the hook in ETH, with the ETH behind them, and sometimes something the creator
    ///      may not sweep: NUTZ-denominated fees or an ETH buyback earmark, which gate the hook sweep off.
    function accrueHookFees(uint256 fee, uint256 tax, uint256 nutzFees, uint256 buyback) external {
        bytes32 poolId = _nutzPoolId();
        fee = bound(fee, 0, 1 ether);
        tax = bound(tax, 0, 0.1 ether);
        buyback = bound(buyback, 0, 3) == 0 ? bound(buyback, 1, 0.1 ether) : 0;
        hook.setPending(
            poolId, ETH, hook.pendingFees(poolId, ETH) + fee, hook.pendingCreatorTax(poolId, ETH) + tax, buyback
        );
        hook.setPending(poolId, address(nutzToken), bound(nutzFees, 0, 3) == 0 ? bound(nutzFees, 1, 1e21) : 0, 0, 0);
        vm.deal(address(hook), address(hook).balance + fee + tax);
    }

    /// @dev ETH credited to the Converter's escrow balance, as the Pons sweep operator would.
    function creditEscrow(uint256 amount) external {
        amount = bound(amount, 0, 5 ether);
        if (amount == 0) return;
        vm.deal(address(this), amount);
        escrow.credit{value: amount}(address(c));
    }

    /// @dev One Keeper Sweep into any fundable Epoch, each Leg routed over the Venue its bit in `venueMask`
    ///      picks. Skipped when neither Venue can run ETH -> USDG. A Converter holding no ETH and no escrow credit
    ///      may still have a Sweep in it: what the Fee pull and the NUTZ sale bring in, which Pons's gates and the
    ///      NUTZ rate decide inside the contract. Such a Sweep is tried whenever those sources are non-empty, and
    ///      `NothingToSweep` is the one revert accepted from it.
    function sweep(uint256 offset, uint256 venueMask) external {
        bool heldNothing = address(c).balance + (_nutzBound() ? escrow.balanceOf(address(c)) : 0) == 0;
        if (heldNothing && !(_nutzBound() && _mayRaiseEth())) return;
        (bool usable, bool ethUsdgV4) = _ethUsdgVenue(venueMask & 2 != 0);
        if (!usable) return;
        uint256 lo = d.rootedThrough(EPOCH) + 1;
        uint256 epochId = lo + bound(offset, 0, d.currentEpoch() - lo);

        NutzConverter.Route[6] memory routes;
        routes[0] = _route(0, venueMask & 1 != 0);
        routes[1] = _route(1, ethUsdgV4);
        for (uint256 i = 2; i < 6; i++) {
            routes[i] = _route(i, venueMask & (1 << i) != 0);
        }

        Snapshot memory s = _snapshot(EPOCH, epochId);
        SweepRecord memory r;
        r.count = sweepRecord.count + 1;
        r.opsCap = c.opsCap();
        r.keeperBefore = keeper.balance;

        vm.recordLogs();
        vm.prank(keeper);
        try c.sweep(epochId, routes, block.timestamp) {}
        catch (bytes memory err) {
            vm.getRecordedLogs();
            require(heldNothing && bytes4(err) == NutzConverter.NothingToSweep.selector, "sweep reverted");
            return;
        }
        if (heldNothing) ghostFeeOnlySweeps++;
        (uint256 claimed, uint256 ethOut) = _readSweepLogs(r, s.disabled);

        r.balanceBefore = s.converterEth + claimed + ethOut;
        r.balanceAfter = address(c).balance;
        r.keeperAfter = keeper.balance;
        r.ethToVenues = _venueEth() + ethOut - s.venueEth;
        uint256[5] memory fundedAfter = d.ledger(EPOCH, epochId).funded;
        for (uint256 i = 0; i < 5; i++) {
            r.fundedDelta[i] = fundedAfter[i] - s.funded[i];
            ghostSweptAmounts[i] += r.amounts[i];
        }
        r.acornPoolDelta = d.acornPoolUsdg() - s.acornPool;
        sweepRecord = r;

        ghostEthArrived += claimed + ethOut;
        ghostEthSwept += r.ethIn;
        ghostAcornAdded += r.acornUsdg;
        if (!epochSeen[epochId]) {
            epochSeen[epochId] = true;
            fundedEpochs.push(epochId);
        }
    }

    /// @dev One Keeper Acorn conversion of any open, unconverted Acorn Draw, its seed reported first, each
    ///      stock Leg routed over the Venue its bit in `venueMask` picks. Skipped when the pool is empty or
    ///      every open Draw is converted.
    function convertAcorn(uint256 pick, uint256 venueMask, uint256 seed) external {
        if (d.acornPoolUsdg() == 0) return;
        uint256 drawId = _openDraw(pick);
        if (drawId == 0) return;
        if (draw.seedOf(drawId) == bytes32(0)) draw.setSeed(drawId, keccak256(abi.encode(seed, drawId)));

        NutzConverter.Route[4] memory routes;
        for (uint256 i = 0; i < 4; i++) {
            routes[i] = _route(2 + i, venueMask & (1 << i) != 0);
        }
        Snapshot memory s = _snapshot(DRAW, drawId);
        AcornRecord memory r;
        r.count = acornRecord.count + 1;

        vm.recordLogs();
        vm.prank(keeper);
        c.convertAcorn(drawId, routes, block.timestamp);
        _readAcornLogs(r, s.disabled);

        uint256[5] memory fundedAfter = d.ledger(DRAW, drawId).funded;
        for (uint256 i = 0; i < 5; i++) {
            r.fundedDelta[i] = fundedAfter[i] - s.funded[i];
            ghostAcornAmounts[i] += r.amounts[i];
        }
        acornRecord = r;
        ghostAcornPulled += r.usdgIn;
        if (!drawSeen[drawId]) {
            drawSeen[drawId] = true;
            fundedDraws.push(drawId);
        }
    }

    /// @dev A stranger tries the Keeper's entry points (`sweep`, `convertAcorn`, `bindNutz`), the Venue callback,
    ///      and the Signer actions that move or guard value (`disableLeg`, `proposeLegEnable`, `cancel`,
    ///      `setOpsCap`, `setKeeper`) with one real Signer signature and one that is not a Signer's; anything that
    ///      does not revert is counted. `executeLegEnable` is left out: anyone may call it, and this handler does.
    ///      Signer rotation is not tried: it moves no value and `SignersTest` covers its signatures.
    function strangerPokes(uint256 stockSeed) external {
        uint8 stock = uint8(bound(stockSeed, 0, 3));
        NutzConverter.Route[6] memory r6;
        NutzConverter.Route[4] memory r4;
        for (uint256 i = 0; i < 6; i++) {
            r6[i] = _route(i, false);
            if (i >= 2) r4[i - 2] = r6[i];
        }
        _poke(abi.encodeCall(c.sweep, (d.currentEpoch(), r6, block.timestamp)));
        _poke(abi.encodeCall(c.convertAcorn, (d.currentDraw(), r4, block.timestamp)));
        NutzConverter.SwapOrder memory order =
            NutzConverter.SwapOrder({key: _key(1), zeroForOne: true, amountIn: address(c).balance, minOut: 0});
        _poke(abi.encodeCall(c.unlockCallback, (abi.encode(order))));
        _poke(abi.encodeCall(c.bindNutz, (address(nutzToken))));

        uint256 strangerKey = uint256(keccak256("stranger"));
        bytes32 sh = keccak256(abi.encode(DISABLE_LEG_TYPEHASH, stock, c.nonce()));
        _poke(abi.encodeCall(c.disableLeg, (stock, _sign(keys[0], sh), _sign(strangerKey, sh))));
        sh = keccak256(abi.encode(SET_OPS_CAP_TYPEHASH, 0, c.nonce()));
        _poke(abi.encodeCall(c.setOpsCap, (0, _sign(strangerKey, sh), _sign(keys[1], sh))));
        sh = keccak256(abi.encode(ENABLE_LEG_TYPEHASH, stock, c.nonce()));
        _poke(abi.encodeCall(c.proposeLegEnable, (stock, _sign(keys[2], sh), _sign(strangerKey, sh))));
        bytes32 id = keccak256(abi.encode(ENABLE_LEG_TYPEHASH, stock));
        sh = keccak256(abi.encode(CANCEL_TYPEHASH, id, c.nonce()));
        _poke(abi.encodeCall(c.cancel, (id, _sign(strangerKey, sh), _sign(keys[0], sh))));
        sh = keccak256(abi.encode(SET_KEEPER_TYPEHASH, stranger, c.nonce()));
        _poke(abi.encodeCall(c.setKeeper, (stranger, _sign(keys[1], sh), _sign(strangerKey, sh))));
    }

    /// @dev One call to the Converter as the stranger, counted if it goes through. The prank sits right before the
    ///      call, so no view in the arguments can consume it.
    function _poke(bytes memory data) internal {
        vm.prank(stranger);
        (bool ok,) = address(c).call(data);
        if (ok) ghostStrangerMoves++;
    }

    // ------------------------------------------------------------- measuring

    /// @dev The state a Sweep or Acorn conversion is measured against.
    struct Snapshot {
        uint256 converterEth;
        uint256 venueEth;
        uint256[5] funded; // the Epoch's or Acorn Draw's ledger
        uint256 acornPool;
        bool[4] disabled; // the Circuit breaker as the call saw it
    }

    function _snapshot(NutzDistributor.Kind kind, uint256 id) internal view returns (Snapshot memory s) {
        s.converterEth = address(c).balance;
        s.venueEth = _venueEth();
        s.funded = d.ledger(kind, id).funded;
        s.acornPool = d.acornPoolUsdg();
        for (uint256 i = 0; i < 4; i++) {
            s.disabled[i] = c.legDisabled(i);
        }
    }

    /// @dev Reads the Sweep's own events into the record, over the tally every call gets.
    function _readSweepLogs(SweepRecord memory r, bool[4] memory disabled)
        internal
        returns (uint256 claimed, uint256 ethOut)
    {
        Vm.Log[] memory logs = _tallyCall(r.usdg, disabled);
        for (uint256 i = 0; i < logs.length; i++) {
            Vm.Log memory log = logs[i];
            if (log.emitter != address(c)) continue;
            if (log.topics[0] == NutzConverter.Swept.selector) {
                (r.ethIn, r.opsAmt, r.amounts, r.acornUsdg) =
                    abi.decode(log.data, (uint256, uint256, uint256[5], uint256));
            } else if (log.topics[0] == NutzConverter.FeesPulled.selector) {
                (,, claimed) = abi.decode(log.data, (bool, bool, uint256));
            } else if (log.topics[0] == NutzConverter.NutzSold.selector) {
                (, ethOut) = abi.decode(log.data, (uint256, uint256));
            }
        }
    }

    /// @dev Reads the conversion's own event into the record, over the tally every call gets.
    function _readAcornLogs(AcornRecord memory r, bool[4] memory disabled) internal {
        Vm.Log[] memory logs = _tallyCall(r.usdg, disabled);
        for (uint256 i = 0; i < logs.length; i++) {
            Vm.Log memory log = logs[i];
            if (log.emitter == address(c) && log.topics[0] == NutzConverter.AcornConverted.selector) {
                (r.usdgIn, r.amounts) = abi.decode(log.data, (uint256, uint256[5]));
            }
        }
    }

    /// @dev What every Sweep and Acorn conversion is measured on: the token `Transfer`s inside the call go into
    ///      the flows, and the Circuit breaker's `LegSkipped(leg, "disabled")` skips are checked against the flags
    ///      the call saw, both ways: every disabled Leg skipped as such, no enabled Leg so skipped. Returns the
    ///      logs for the caller's own events.
    function _tallyCall(UsdgFlows memory f, bool[4] memory disabled) internal returns (Vm.Log[] memory logs) {
        logs = vm.getRecordedLogs();
        bool[4] memory skipped;
        for (uint256 i = 0; i < logs.length; i++) {
            Vm.Log memory log = logs[i];
            if (log.emitter != address(c)) _tallyTransfer(log, f, disabled);
            else if (log.topics[0] == NutzConverter.LegSkipped.selector) _noteDisabledSkip(log, skipped);
        }
        for (uint256 i = 0; i < 4; i++) {
            if (disabled[i] != skipped[i]) ghostDisabledSkipsWrong++;
        }
    }

    /// @dev Marks the stock of a `LegSkipped(leg, "disabled")`; a skip for any other reason is a Venue failure.
    function _noteDisabledSkip(Vm.Log memory log, bool[4] memory skipped) internal pure {
        uint256 leg = uint256(log.topics[1]);
        if (leg < 2) return; // the NUTZ -> ETH and ETH -> USDG Legs have no Circuit breaker
        bytes memory reason = abi.decode(log.data, (bytes));
        if (keccak256(reason) == keccak256("disabled")) skipped[leg - 2] = true;
    }

    /// @dev Adds one token `Transfer` inside a call to the flows: USDG between the Converter and a Venue or
    ///      the Distributor, either way; and counts any movement of a stock whose Leg was disabled.
    function _tallyTransfer(Vm.Log memory log, UsdgFlows memory f, bool[4] memory disabled) internal {
        if (log.topics.length != 3 || log.topics[0] != IERC20.Transfer.selector) return;
        for (uint256 i = 0; i < 4; i++) {
            if (log.emitter == address(tok[i]) && disabled[i]) ghostDisabledLegSwaps++;
        }
        if (log.emitter != address(tok[4])) return;
        address from = address(uint160(uint256(log.topics[1])));
        address to = address(uint160(uint256(log.topics[2])));
        uint256 value = abi.decode(log.data, (uint256));
        if (to == address(c) && _isVenue(from)) f.fromVenues += value;
        if (from == address(c) && _isVenue(to)) f.toVenues += value;
        if (from == address(c) && to == address(d)) f.toDistributor += value;
        if (from == address(d) && to == address(c)) f.fromDistributor += value;
    }

    /// @dev An open Acorn Draw not yet converted, searched from `pick` round the open range; zero when none.
    function _openDraw(uint256 pick) internal view returns (uint256) {
        uint256 lo = d.rootedThrough(DRAW) + 1;
        uint256 n = d.currentDraw() - lo + 1;
        uint256 start = bound(pick, 0, n - 1);
        for (uint256 k = 0; k < n; k++) {
            uint256 id = lo + (start + k) % n;
            if (!d.drawConverted(id)) return id;
        }
        return 0;
    }

    /// @dev The ETH held by the three contracts a Leg can pay ETH to or draw it from.
    function _venueEth() internal view returns (uint256) {
        return address(router).balance + address(pm).balance + address(weth).balance;
    }

    function _isVenue(address a) internal view returns (bool) {
        return a == address(router) || a == address(pm);
    }

    /// @dev Whether the Keeper has bound the NUTZ launch; the Converter's zero address means not yet.
    function _nutzBound() internal view returns (bool) {
        return c.nutz() != address(0);
    }

    /// @dev The Pons pool id of the NUTZ launch, as the hook keys its pending fees.
    function _nutzPoolId() internal view returns (bytes32) {
        return PoolId.unwrap(_key(0).toId());
    }

    /// @dev Whether the Fee pull or the NUTZ sale has anything to work with: NUTZ to sell, or ETH fees and tax
    ///      pending on the curve or the hook. Whether the contract actually gets ETH out of them is its own call.
    function _mayRaiseEth() internal view returns (bool) {
        if (nutzToken.balanceOf(address(c)) > 0) return true;
        if (curve.quoteFeeBalance() + curve.creatorTaxBalance() > 0) return true;
        return hook.pendingFees(_nutzPoolId(), ETH) + hook.pendingCreatorTax(_nutzPoolId(), ETH) > 0;
    }

    // ------------------------------------------------------------- routes

    /// @dev The Venue for ETH -> USDG: the one asked for unless its USDG output is switched to fail, then the
    ///      other; neither when both fail.
    function _ethUsdgVenue(bool preferV4) internal view returns (bool usable, bool v4) {
        bool v3Fails = router.reverts(address(tok[4]));
        bool v4Fails = pm.reverts(_key(1).toId());
        if (preferV4 ? !v4Fails : v3Fails && !v4Fails) return (true, true);
        if (!v3Fails) return (true, false);
        return (false, false);
    }

    /// @dev A valid Route for Leg `leg` over the chosen Venue, with no slippage floor.
    function _route(uint256 leg, bool v4) internal view returns (NutzConverter.Route memory) {
        if (v4) return NutzConverter.Route({venue: address(pm), minOut: 0, data: abi.encode(_key(leg))});
        return
            NutzConverter.Route({
                venue: address(router), minOut: 0, data: abi.encodePacked(_v3In(leg), FEE, _v3Out(leg))
            });
    }

    /// @dev The currencies Leg `leg` sells and buys, in the Converter's Leg order: NUTZ -> ETH, ETH -> USDG, then
    ///      USDG -> each stock. ETH is the zero address, as v4 has it; v3 sees it as WETH.
    function _legTokens(uint256 leg) internal view returns (address tokenIn, address tokenOut) {
        if (leg == 0) return (address(nutzToken), ETH);
        if (leg == 1) return (ETH, address(tok[4]));
        return (address(tok[4]), address(tok[leg - 2]));
    }

    /// @dev The v4 key of Leg `leg`: NUTZ/ETH over the Pons pool, every other pair over a plain pool.
    function _key(uint256 leg) internal view returns (PoolKey memory) {
        (address tokenIn, address tokenOut) = _legTokens(leg);
        (address c0, address c1) = tokenIn < tokenOut ? (tokenIn, tokenOut) : (tokenOut, tokenIn);
        if (leg == 0) {
            return PoolKey({
                currency0: Currency.wrap(c0),
                currency1: Currency.wrap(c1),
                fee: NUTZ_POOL_FEE,
                tickSpacing: NUTZ_TICK_SPACING,
                hooks: IHooks(address(hook))
            });
        }
        return PoolKey({
            currency0: Currency.wrap(c0), currency1: Currency.wrap(c1), fee: 3000, tickSpacing: 60, hooks: IHooks(ETH)
        });
    }

    function _v3In(uint256 leg) internal view returns (address) {
        (address tokenIn,) = _legTokens(leg);
        return tokenIn == ETH ? address(weth) : tokenIn;
    }

    function _v3Out(uint256 leg) internal view returns (address) {
        (, address tokenOut) = _legTokens(leg);
        return tokenOut == ETH ? address(weth) : tokenOut;
    }

    /// @dev Whether the v4 swap of Leg `leg` is currency0 -> currency1: it sells the lower-sorted currency.
    function _zeroForOne(uint256 leg) internal view returns (bool) {
        (address tokenIn, address tokenOut) = _legTokens(leg);
        return tokenIn < tokenOut;
    }

    function _setRate(uint256 leg, bool v4, uint256 rate) internal {
        if (v4) pm.setRate(_key(leg), _zeroForOne(leg), rate);
        else router.setRate(_v3Out(leg), rate);
    }

    // ------------------------------------------------------------- signing

    function _sign(uint256 key, bytes32 structHash) internal view returns (bytes memory) {
        bytes32 ds = keccak256(
            abi.encode(DOMAIN_TYPEHASH, keccak256("NutzConverter"), keccak256("1"), block.chainid, address(c))
        );
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(key, keccak256(abi.encodePacked("\x19\x01", ds, structHash)));
        return abi.encodePacked(r, s, v);
    }

    // ------------------------------------------------------------- views

    function lastSweep() external view returns (SweepRecord memory) {
        return sweepRecord;
    }

    function lastAcorn() external view returns (AcornRecord memory) {
        return acornRecord;
    }

    function fundedEpochCount() external view returns (uint256) {
        return fundedEpochs.length;
    }

    function fundedDrawCount() external view returns (uint256) {
        return fundedDraws.length;
    }

    function ghostSweptAmount(uint256 i) external view returns (uint256) {
        return ghostSweptAmounts[i];
    }

    function ghostAcornAmount(uint256 i) external view returns (uint256) {
        return ghostAcornAmounts[i];
    }
}
