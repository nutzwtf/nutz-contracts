// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {vm} from "chimera/Hevm.sol";
import {NutzConverter} from "../../src/NutzConverter.sol";
import {NutzDistributor} from "../../src/NutzDistributor.sol";
import {ConverterProperties} from "./ConverterProperties.sol";

/// @dev test/invariant/ConverterHandler.sol under Medusa: the same actions and bounds, with `bound` as Chimera's
///      `between`, `recordLogs` gone and every Sweep and Acorn conversion measured from the balances and ledgers
///      around the call (`Snapshot`, `_measureSweep`, `_measureAcorn`). `_poke` and the two Keeper calls keep the
///      prank right before the call: Medusa spends a prank on the next call, a cheatcode included, so no view
///      may sit between them.
abstract contract ConverterTargets is ConverterProperties {
    /// @dev The state a Sweep or Acorn conversion is measured against.
    struct Snapshot {
        uint256 converterEth;
        uint256 feeSourceEth;
        uint256 keeperEth;
        uint256 nutzHeld;
        uint256[5] funded; // the Epoch's or Acorn Draw's ledger
        uint256 acornPool;
        uint256 distributorUsdg;
        uint256[4] distributorStock;
        bool[4] disabled; // the Circuit breaker as the call saw it
        uint256 opsCap; // Sweeps only
        uint256 nutzSaleOut; // Sweeps only: what selling everything held would pay on the Venue routed
    }

    // ------------------------------------------------------------- actions

    function warp(uint256 secs) public {
        vm.warp(block.timestamp + between(secs, 1 minutes, 1 days));
    }

    /// @dev ETH paid straight to the Converter, as Pons's owner-only rescue does.
    function receiveEth(uint256 amount) public {
        amount = between(amount, 0, 30 ether);
        if (amount == 0) return;
        vm.deal(address(this), amount);
        (bool ok,) = address(c).call{value: amount}("");
        t(ok, "receive refused");
        ghostEthDealt += amount;
    }

    /// @dev The Keeper's wallet balance moves outside the Converter: it pays gas, or gets topped up by hand.
    function keeperWalletMoves(uint256 balance) public {
        balance = between(balance, 0, 1 ether);
        ghostEthDealt = ghostEthDealt - keeper.balance + balance;
        vm.deal(keeper, balance);
    }

    /// @dev Reprices one Leg on one Venue. ETH -> USDG stays inside the Distributor's floor so a Sweep can
    ///      always find a Route; any other Leg may lose its rate entirely, which the Venue reports as a revert.
    function setRate(uint256 leg, bool v4, uint256 rate) public {
        leg = between(leg, 0, 5);
        if (leg == 0) rate = between(rate, 0, 1e15);
        else if (leg == 1) rate = between(rate, d.minUsdgPerEth(), 10 * d.maxUsdgPerEth());
        else rate = between(rate, 0, 1e30);
        _setRate(leg, v4, rate);
    }

    /// @dev Flips the failure switch of one Leg's output on one Venue.
    function setFailure(uint256 leg, bool v4, bool on) public {
        leg = between(leg, 0, 5);
        if (v4) pm.setReverts(_key(leg), on);
        else router.setReverts(_v3Out(leg), on);
    }

    // ---- governance ----

    /// @dev The Circuit breaker, signed by two Signers; a no-op when the Leg is already disabled.
    function disable(uint256 stockSeed) public {
        uint8 stock = uint8(between(stockSeed, 0, 3));
        if (c.legDisabled(stock)) return;
        bytes32 sh = keccak256(abi.encode(DISABLE_LEG_TYPEHASH, stock, c.nonce()));
        bytes memory sig1 = _signC(keys[0], sh);
        bytes memory sig2 = _signC(keys[1], sh);
        try c.disableLeg(stock, sig1, sig2) {}
        catch (bytes memory err) {
            _unexpected("disableLeg", err);
        }
        ghostDisabled[stock] = true;
    }

    /// @dev Schedules enabling a disabled Leg; an expired proposal is cancelled first, a live one left alone.
    function proposeEnable(uint256 stockSeed) public {
        uint8 stock = uint8(between(stockSeed, 0, 3));
        if (!c.legDisabled(stock)) return;
        bytes32 id = keccak256(abi.encode(ENABLE_LEG_TYPEHASH, stock));
        uint256 ready = c.readyAt(id);
        if (ready != 0) {
            if (block.timestamp <= ready + c.PROPOSAL_TTL()) return;
            bytes32 ch = keccak256(abi.encode(CANCEL_TYPEHASH, id, c.nonce()));
            bytes memory c1 = _signC(keys[0], ch);
            bytes memory c2 = _signC(keys[2], ch);
            try c.cancel(id, c1, c2) {}
            catch (bytes memory err) {
                _unexpected("cancel", err);
            }
        }
        bytes32 sh = keccak256(abi.encode(ENABLE_LEG_TYPEHASH, stock, c.nonce()));
        bytes memory sig1 = _signC(keys[1], sh);
        bytes memory sig2 = _signC(keys[2], sh);
        try c.proposeLegEnable(stock, sig1, sig2) {}
        catch (bytes memory err) {
            _unexpected("proposeLegEnable", err);
        }
    }

    /// @dev Executes a scheduled enable once its timelock has elapsed and before it expires; anyone may.
    function executeEnable(uint256 stockSeed) public {
        uint8 stock = uint8(between(stockSeed, 0, 3));
        uint256 ready = c.readyAt(keccak256(abi.encode(ENABLE_LEG_TYPEHASH, stock)));
        if (ready == 0 || block.timestamp < ready || block.timestamp > ready + c.PROPOSAL_TTL()) return;
        try c.executeLegEnable(stock) {}
        catch (bytes memory err) {
            _unexpected("executeLegEnable", err);
        }
        ghostDisabled[stock] = false;
    }

    function setOpsCap(uint256 cap) public {
        cap = between(cap, 0, c.MAX_OPS_CAP_WEI());
        bytes32 sh = keccak256(abi.encode(SET_OPS_CAP_TYPEHASH, cap, c.nonce()));
        bytes memory sig1 = _signC(keys[0], sh);
        bytes memory sig2 = _signC(keys[2], sh);
        try c.setOpsCap(cap, sig1, sig2) {}
        catch (bytes memory err) {
            _unexpected("setOpsCap", err);
        }
    }

    // ---- NUTZ ----

    /// @dev The Keeper binds the launch; once is enough, and every Sweep before it runs unbound.
    function bindNutz() public {
        if (_nutzBound()) return;
        address token = address(nutzToken);
        vm.prank(keeper);
        try c.bindNutz(token) {}
        catch (bytes memory err) {
            _unexpected("bindNutz", err);
        }
    }

    /// @dev NUTZ paid to the Converter, as Pons's owner-only pool rescue does; it waits until bound and sold.
    function receiveNutz(uint256 amount) public {
        amount = between(amount, 0, 1e24);
        if (amount > 0) nutzToken.mint(address(c), amount);
    }

    /// @dev Moves the launch through Pons's phases; only 0 (curve) and 2 (hook) have anything to pull.
    function setPhase(uint256 phase) public {
        launch.phase = uint8(between(phase, 0, 3));
        factory.setLaunchedToken(address(nutzToken), launch);
    }

    /// @dev Creator fees and tax accrue on the curve, with the ETH behind them.
    function accrueCurveFees(uint256 fee, uint256 tax) public {
        fee = between(fee, 0, 1 ether);
        tax = between(tax, 0, 0.1 ether);
        curve.setBalances(curve.quoteFeeBalance() + fee, curve.creatorTaxBalance() + tax);
        vm.deal(address(curve), address(curve).balance + fee + tax);
        ghostEthDealt += fee + tax;
    }

    /// @dev Fees and tax accrue on the hook in ETH, with the ETH behind them, and sometimes something the creator
    ///      may not sweep: NUTZ-denominated fees or an ETH buyback earmark, which gate the hook sweep off.
    function accrueHookFees(uint256 fee, uint256 tax, uint256 nutzFees, uint256 buyback) public {
        bytes32 poolId = _nutzPoolId();
        fee = between(fee, 0, 1 ether);
        tax = between(tax, 0, 0.1 ether);
        buyback = between(buyback, 0, 3) == 0 ? between(buyback, 1, 0.1 ether) : 0;
        hook.setPending(
            poolId, ETH, hook.pendingFees(poolId, ETH) + fee, hook.pendingCreatorTax(poolId, ETH) + tax, buyback
        );
        hook.setPending(poolId, address(nutzToken), between(nutzFees, 0, 3) == 0 ? between(nutzFees, 1, 1e21) : 0, 0, 0);
        vm.deal(address(hook), address(hook).balance + fee + tax);
        ghostEthDealt += fee + tax;
    }

    /// @dev ETH credited to the Converter's escrow balance, as the Pons sweep operator would.
    function creditEscrow(uint256 amount) public {
        amount = between(amount, 0, 5 ether);
        if (amount == 0) return;
        vm.deal(address(this), amount);
        escrow.credit{value: amount}(address(c));
        ghostEthDealt += amount;
    }

    /// @dev One Keeper Sweep into any fundable Epoch, each Leg routed over the Venue its bit in `venueMask`
    ///      picks. Skipped when neither Venue can run ETH -> USDG. A Converter holding no ETH and no escrow credit
    ///      may still have a Sweep in it: what the Fee pull and the NUTZ sale bring in, which Pons's gates and the
    ///      NUTZ rate decide inside the contract. Such a Sweep is tried whenever those sources are non-empty, and
    ///      `NothingToSweep` is the one revert accepted from it.
    function sweep(uint256 offset, uint256 venueMask) public {
        bool heldNothing = address(c).balance + (_nutzBound() ? escrow.balanceOf(address(c)) : 0) == 0;
        if (heldNothing && !(_nutzBound() && _mayRaiseEth())) return;
        (bool usable, bool ethUsdgV4) = _ethUsdgVenue(venueMask & 2 != 0);
        if (!usable) return;
        uint256 lo = d.rootedThrough(EPOCH) + 1;
        uint256 epochId = lo + between(offset, 0, d.currentEpoch() - lo);

        NutzConverter.Route[6] memory routes;
        routes[0] = _route(0, venueMask & 1 != 0);
        routes[1] = _route(1, ethUsdgV4);
        for (uint256 i = 2; i < 6; i++) {
            routes[i] = _route(i, venueMask & (1 << i) != 0);
        }

        Snapshot memory s = _snapshot(EPOCH, epochId);
        s.opsCap = c.opsCap();
        s.nutzSaleOut = _nutzSaleOut(s.nutzHeld, venueMask & 1 != 0);
        vm.prank(keeper);
        try c.sweep(epochId, routes, block.timestamp) {}
        catch (bytes memory err) {
            t(heldNothing && bytes4(err) == NutzConverter.NothingToSweep.selector, "sweep reverted");
            return;
        }
        if (heldNothing) ghostFeeOnlySweeps++;
        _measureSweep(s, epochId);
        if (!epochSeen[epochId]) {
            epochSeen[epochId] = true;
            fundedEpochs.push(epochId);
        }
    }

    /// @dev One Keeper Acorn conversion of any open, unconverted Acorn Draw, its seed reported first, each
    ///      stock Leg routed over the Venue its bit in `venueMask` picks. Skipped when the pool is empty or
    ///      every open Draw is converted.
    function convertAcorn(uint256 pick, uint256 venueMask, uint256 seed) public {
        if (d.acornPoolUsdg() == 0) return;
        uint256 drawId = _openDraw(pick);
        if (drawId == 0) return;
        if (draw.seedOf(drawId) == bytes32(0)) draw.setSeed(drawId, keccak256(abi.encode(seed, drawId)));

        NutzConverter.Route[4] memory routes;
        for (uint256 i = 0; i < 4; i++) {
            routes[i] = _route(2 + i, venueMask & (1 << i) != 0);
        }
        Snapshot memory s = _snapshot(DRAW, drawId);
        vm.prank(keeper);
        try c.convertAcorn(drawId, routes, block.timestamp) {}
        catch (bytes memory err) {
            _unexpected("convertAcorn", err);
        }
        _measureAcorn(s, drawId);
        if (!drawSeen[drawId]) {
            drawSeen[drawId] = true;
            fundedDraws.push(drawId);
        }
    }

    /// @dev A stranger tries the Keeper's entry points (`sweep`, `convertAcorn`, `bindNutz`), the Venue callback,
    ///      and the Signer actions that move or guard value (`disableLeg`, `proposeLegEnable`, `cancel`,
    ///      `setOpsCap`, `setKeeper`) with one real Signer signature and one that is not a Signer's; anything that
    ///      does not revert is counted. `executeLegEnable` is left out: anyone may call it, and this harness does.
    ///      Signer rotation is not tried: it moves no value and `SignersTest` covers its signatures.
    function strangerPokes(uint256 stockSeed) public {
        uint8 stock = uint8(between(stockSeed, 0, 3));
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
        _poke(abi.encodeCall(c.disableLeg, (stock, _signC(keys[0], sh), _signC(strangerKey, sh))));
        sh = keccak256(abi.encode(SET_OPS_CAP_TYPEHASH, 0, c.nonce()));
        _poke(abi.encodeCall(c.setOpsCap, (0, _signC(strangerKey, sh), _signC(keys[1], sh))));
        sh = keccak256(abi.encode(ENABLE_LEG_TYPEHASH, stock, c.nonce()));
        _poke(abi.encodeCall(c.proposeLegEnable, (stock, _signC(keys[2], sh), _signC(strangerKey, sh))));
        bytes32 id = keccak256(abi.encode(ENABLE_LEG_TYPEHASH, stock));
        sh = keccak256(abi.encode(CANCEL_TYPEHASH, id, c.nonce()));
        _poke(abi.encodeCall(c.cancel, (id, _signC(strangerKey, sh), _signC(keys[0], sh))));
        sh = keccak256(abi.encode(SET_KEEPER_TYPEHASH, stranger, c.nonce()));
        _poke(abi.encodeCall(c.setKeeper, (stranger, _signC(keys[1], sh), _signC(strangerKey, sh))));
    }

    /// @dev One call to the Converter as the stranger, counted if it goes through. The prank sits right before the
    ///      call, so no view in the arguments can consume it.
    function _poke(bytes memory data) internal {
        vm.prank(stranger);
        (bool ok,) = address(c).call(data);
        if (ok) ghostStrangerMoves++;
    }

    // ------------------------------------------------------------- measuring

    function _snapshot(NutzDistributor.Kind kind, uint256 id) internal view returns (Snapshot memory s) {
        s.converterEth = address(c).balance;
        s.feeSourceEth = _feeSourceEth();
        s.keeperEth = keeper.balance;
        s.nutzHeld = nutzToken.balanceOf(address(c));
        s.funded = d.ledger(kind, id).funded;
        s.acornPool = d.acornPoolUsdg();
        s.distributorUsdg = tok[4].balanceOf(address(d));
        for (uint256 i = 0; i < 4; i++) {
            s.distributorStock[i] = tok[i].balanceOf(address(d));
            s.disabled[i] = c.legDisabled(i);
        }
    }

    /// @dev The Sweep's record from the state around it. The Fee pull's take is what the fee sources lost; the
    ///      NUTZ sale, which sells everything held or nothing, paid `nutzSaleOut` when the NUTZ is gone; B is the
    ///      Converter's balance drop once both are added.
    function _measureSweep(Snapshot memory s, uint256 epochId) internal {
        SweepRecord memory r;
        r.count = sweepRecord.count + 1;
        uint256 feeSourceAfter = _feeSourceEth();
        t(feeSourceAfter <= s.feeSourceEth, "the fee sources gained ETH inside a Sweep");
        r.claimed = s.feeSourceEth - feeSourceAfter;
        if (s.nutzHeld > 0 && nutzToken.balanceOf(address(c)) == 0) r.saleOut = s.nutzSaleOut;
        r.balanceBefore = s.converterEth + r.claimed + r.saleOut;
        r.balanceAfter = address(c).balance;
        t(r.balanceAfter <= r.balanceBefore, "the Converter gained ETH inside a Sweep");
        r.ethIn = r.balanceBefore - r.balanceAfter;
        t(keeper.balance >= s.keeperEth, "the Keeper lost ETH inside a Sweep");
        r.opsAmt = keeper.balance - s.keeperEth;
        r.opsCap = s.opsCap;
        r.keeperAfter = keeper.balance;
        r.fundedDelta = _fundedDelta(EPOCH, epochId, s);
        r.acornPoolDelta = d.acornPoolUsdg() - s.acornPool;
        r.distributorUsdgBefore = s.distributorUsdg;
        r.distributorUsdgAfter = tok[4].balanceOf(address(d));
        sweepRecord = r;
    }

    function _measureAcorn(Snapshot memory s, uint256 drawId) internal {
        AcornRecord memory r;
        r.count = acornRecord.count + 1;
        r.usdgIn = s.acornPool - d.acornPoolUsdg();
        r.fundedDelta = _fundedDelta(DRAW, drawId, s);
        r.distributorUsdgBefore = s.distributorUsdg;
        r.distributorUsdgAfter = tok[4].balanceOf(address(d));
        acornRecord = r;
    }

    /// @dev The ledger's change since `s`, checked against the Stock Tokens the Distributor actually received
    ///      (the USDG side is a property, since the Acorn pull moves USDG the other way), and the Circuit
    ///      breaker check every Sweep and conversion gets: a disabled Leg's stock must not have moved.
    function _fundedDelta(NutzDistributor.Kind kind, uint256 id, Snapshot memory s)
        internal
        returns (uint256[5] memory delta)
    {
        uint256[5] memory fundedAfter = d.ledger(kind, id).funded;
        for (uint256 i = 0; i < 5; i++) {
            delta[i] = fundedAfter[i] - s.funded[i];
        }
        for (uint256 i = 0; i < 4; i++) {
            uint256 received = tok[i].balanceOf(address(d)) - s.distributorStock[i];
            eq(received, delta[i], "the Distributor's stock balance does not match its ledger");
            if (s.disabled[i] && received != 0) ghostDisabledLegSwaps++;
        }
    }

    /// @dev What the NUTZ -> ETH Leg pays for `nutzIn` on the Venue `v4` picks, as the mocks price it.
    function _nutzSaleOut(uint256 nutzIn, bool v4) internal view returns (uint256) {
        uint256 rate = v4 ? pm.rate(_key(0).toId(), _zeroForOne(0)) : router.rate(address(weth));
        return nutzIn * rate / 1e18;
    }

    /// @dev A call the model says must succeed reverted: the run fails, the reason names the call and the error.
    function _unexpected(string memory what, bytes memory err) internal {
        t(false, _unexpectedReason(what, err));
    }

    /// @dev An open Acorn Draw not yet converted, searched from `pick` round the open range; zero when none.
    function _openDraw(uint256 pick) internal returns (uint256) {
        uint256 lo = d.rootedThrough(DRAW) + 1;
        uint256 n = d.currentDraw() - lo + 1;
        uint256 start = between(pick, 0, n - 1);
        for (uint256 k = 0; k < n; k++) {
            uint256 id = lo + (start + k) % n;
            if (!d.drawConverted(id)) return id;
        }
        return 0;
    }

    /// @dev Whether the Keeper has bound the NUTZ launch; the Converter's zero address means not yet.
    function _nutzBound() internal view returns (bool) {
        return c.nutz() != address(0);
    }

    /// @dev Whether the Fee pull or the NUTZ sale has anything to work with: NUTZ to sell, or ETH fees and tax
    ///      pending on the curve or the hook. Whether the contract actually gets ETH out of them is its own call.
    function _mayRaiseEth() internal view returns (bool) {
        if (nutzToken.balanceOf(address(c)) > 0) return true;
        if (curve.quoteFeeBalance() + curve.creatorTaxBalance() > 0) return true;
        return hook.pendingFees(_nutzPoolId(), ETH) + hook.pendingCreatorTax(_nutzPoolId(), ETH) > 0;
    }

    /// @dev The Venue for ETH -> USDG: the one asked for unless its USDG output is switched to fail, then the
    ///      other; neither when both fail.
    function _ethUsdgVenue(bool preferV4) internal view returns (bool usable, bool v4) {
        bool v3Fails = router.reverts(address(tok[4]));
        bool v4Fails = pm.reverts(_key(1).toId());
        if (preferV4 ? !v4Fails : v3Fails && !v4Fails) return (true, true);
        if (!v3Fails) return (true, false);
        return (false, false);
    }
}
