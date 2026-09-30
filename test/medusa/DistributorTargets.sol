// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {vm} from "chimera/Hevm.sol";
import {NutzDistributor} from "../../src/NutzDistributor.sol";
import {Signers} from "../../src/Signers.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {DistributorProperties} from "./DistributorProperties.sol";

/// @dev test/invariant/DistributorHandler.sol written against the cheatcodes Medusa has. Same actions, same
///      bounds, same ghosts; three substitutions: `bound` is Chimera's `between`; `expectRevert` is try/catch
///      with the revert data compared in full; and the ledger of who was paid, which the forge handler reads from
///      the `Transfer` logs of each call, comes from the balances of every address a payout may reach, taken
///      before and after each paying call (`_snapOut` / `_absorbOut`): the Distributor's balance drop must equal
///      what those addresses gained, so a token reaching anyone else fails the call. Every call that must go
///      through is wrapped in try/catch and an unexpected revert trips an assertion, which is what
///      `fail_on_revert` does under forge.
abstract contract DistributorTargets is DistributorProperties {
    /// @dev Token balances around one paying call: the Distributor's and every watched address's.
    struct OutSnap {
        uint256[5] dist;
        uint256[5][] w;
    }

    // ------------------------------------------------------------- actions

    function warp(uint256 secs) public {
        vm.warp(block.timestamp + between(secs, 1, 6 hours));
    }

    function fundEpoch(uint256[5] memory a, uint256 acorn, uint256 offset) public {
        uint256 lo = d.rootedThrough(EPOCH) + 1;
        uint256 hi = d.currentEpoch();
        uint256 id = lo + between(offset, 0, hi - lo);
        for (uint256 i = 0; i < 5; i++) {
            a[i] = tok[i].paused() ? 0 : between(a[i], 0, 100e18);
            if (a[i] > 0) tok[i].mint(converter, a[i]);
            ghostFunded[i] += a[i];
        }
        acorn = tok[USDG].paused() ? 0 : between(acorn, 0, 20e18);
        if (acorn > 0) tok[USDG].mint(converter, acorn);
        ghostFunded[USDG] += acorn;
        vm.prank(converter);
        try d.notifyEpochFunding(id, a, acorn) {}
        catch (bytes memory err) {
            _unexpected("notifyEpochFunding", err);
        }
        if (!epochSeen[id]) {
            epochSeen[id] = true;
            fundedEpochs.push(id);
        }
    }

    /// @dev The most periods one Root may skip. A Draw Root has to wait a week, and every such wait lets 168
    ///      Epochs pile up; `postRoot` skips them in a loop the handler mirrors in `_available`, and under
    ///      Medusa's 30M gas per call that loop ran out of gas past ~600 periods (forge gives a call ~2^30).
    ///      The Keeper posts hourly, so a Root skipping days is already far past anything real.
    uint256 internal constant MAX_SKIP = 48;

    /// @dev Posts the Root of the next closed period, spending a random share of funded + carry across actors.
    ///      One run in four posts an over-allocated Root: the totals stay within the cap, but every leaf
    ///      claims the whole totals, so the leaves sum to `n` times what the Root committed to. The
    ///      Distributor accepts it (spec §6 "bad root") and must stop the claims at the totals.
    function postRoot(uint256 kindSeed, uint256 skip, uint256[5] memory spendBps, uint256 split, uint256 mode) public {
        NutzDistributor.Kind kind = kindSeed % 2 == 0 ? EPOCH : DRAW;
        uint256 current = kind == EPOCH ? d.currentEpoch() : d.currentDraw();
        uint256 lo = d.rootedThrough(kind) + 1;
        if (lo >= current) {
            // nothing closed yet: let the open period end, as the Keeper would wait for it
            vm.warp(kind == EPOCH ? (lo + 1) * 3600 : (lo + 1) * 604_800);
            current = lo + 1;
        }
        uint256 id = lo + between(skip, 0, _min(current - 1 - lo, MAX_SKIP));
        if (kind == DRAW && !_drawReady(id)) return;
        uint256[5] memory available = _available(kind, lo, id);
        uint256 n = 1 + between(split, 0, actors.length - 1);
        bool overAllocate = mode % 4 == 0 && n > 1;
        (bytes32 root, uint256[5] memory totals) = _buildTree(kind, id, available, spendBps, n, overAllocate);
        bytes32 sh =
            keccak256(abi.encode(POST_ROOT_TYPEHASH, uint8(kind), id, root, keccak256(abi.encode(totals)), d.nonce()));
        bytes memory sig1 = _signD(keys[0], sh);
        bytes memory sig2 = _signD(keys[1], sh);
        try d.postRoot(kind, id, root, totals, sig1, sig2) {}
        catch (bytes memory err) {
            _unexpected("postRoot", err);
        }
        if (kind == EPOCH) {
            epochOverAllocated[id] = overAllocate;
            if (!epochRooted[id]) {
                epochRooted[id] = true;
                rootedEpochs.push(id);
            }
        } else {
            drawOverAllocated[id] = overAllocate;
            if (!drawRooted[id]) {
                drawRooted[id] = true;
                rootedDraws.push(id);
            }
        }
    }

    /// @dev funded[id] + carry + the funding of every period about to be skipped; counts the skips.
    function _available(NutzDistributor.Kind kind, uint256 lo, uint256 id) internal returns (uint256[5] memory av) {
        av = d.carry(kind);
        for (uint256 x = lo; x <= id; x++) {
            NutzDistributor.Ledger memory L = d.ledger(kind, x);
            bool any = false;
            for (uint256 i = 0; i < 5; i++) {
                av[i] += L.funded[i];
                any = any || L.funded[i] > 0;
            }
            if (x < id && any) ghostSkips++;
        }
    }

    /// @dev Rebuilds the period's tree in storage with `n` actors sharing a slice of `available`.
    ///      Over-allocated: every leaf carries the whole totals instead of its share.
    function _buildTree(
        NutzDistributor.Kind kind,
        uint256 id,
        uint256[5] memory available,
        uint256[5] memory spendBps,
        uint256 n,
        bool overAllocate
    ) internal returns (bytes32 root, uint256[5] memory totals) {
        Claim[] storage tree = kind == EPOCH ? epochTree[id] : drawTree[id];
        while (tree.length > 0) {
            tree.pop();
        }
        uint256[5] memory share;
        for (uint256 i = 0; i < 5; i++) {
            share[i] = available[i] * between(spendBps[i], 0, 10_000) / 10_000 / n;
            totals[i] = share[i] * n;
        }
        for (uint256 k = 0; k < n; k++) {
            tree.push(Claim(actors[k], overAllocate ? totals : share));
        }
        Claim[] memory mem = tree;
        root = rootOf(id, mem);
    }

    function voidLatest(uint256 kindSeed) public {
        NutzDistributor.Kind kind = kindSeed % 2 == 0 ? EPOCH : DRAW;
        uint256 id = d.rootedThrough(kind);
        NutzDistributor.Ledger memory L = d.ledger(kind, id);
        if (L.rootPostedAt == 0 || d.isFinal(kind, id)) return;
        bytes32 sh = keccak256(abi.encode(VOID_ROOT_TYPEHASH, uint8(kind), id, d.nonce()));
        bytes memory sig1 = _signD(keys[0], sh);
        bytes memory sig2 = _signD(keys[2], sh);
        try d.voidRoot(kind, id, sig1, sig2) {}
        catch (bytes memory err) {
            _unexpected("voidRoot", err);
        }
        ghostVoids++;
    }

    /// @dev A valid leaf claimed by anyone: the account itself, another holder or a stranger. Tokens must
    ///      reach `account` regardless of the caller. Against an over-allocated Root the claim that would
    ///      push `claimed` past `totals` must revert CapExceeded.
    function claim(uint256 kindSeed, uint256 pick, uint256 leaf, uint256 callerSeed) public {
        NutzDistributor.Kind kind = kindSeed % 2 == 0 ? EPOCH : DRAW;
        uint256 id = _pickRooted(kind, pick);
        if (id == 0) return;
        Claim[] memory tree = _tree(kind, id);
        if (tree.length == 0) return;
        uint256 k = _unclaimedFrom(kind, id, tree, between(leaf, 0, tree.length - 1));
        if (k == type(uint256).max) return;
        (bool capped, uint256 token) = _wouldExceedCap(kind, id, tree[k].amounts);
        bytes32[] memory proof = proofOf(id, tree, k); // built before the prank: murky is an external call
        if (capped) {
            _refusedClaim(
                _caller(callerSeed),
                kind,
                id,
                tree[k].account,
                tree[k].amounts,
                proof,
                abi.encodeWithSelector(NutzDistributor.CapExceeded.selector, token)
            );
            ghostCapRejections++;
            return;
        }
        uint256[5] memory before = _stuck(tree[k].account);
        OutSnap memory s = _snapOut();
        vm.prank(_caller(callerSeed));
        try d.claim(kind, id, tree[k].account, tree[k].amounts, proof) {}
        catch (bytes memory err) {
            _unexpected("claim", err);
        }
        _absorbOut(s);
        _settled(kind, id, tree[k].account, tree[k].amounts, before);
    }

    /// @dev Every unclaimed, claimable leaf of one holder across the final periods of `kind`, in one call.
    function claimMany(uint256 kindSeed, uint256 who, uint256 callerSeed) public {
        NutzDistributor.Kind kind = kindSeed % 2 == 0 ? EPOCH : DRAW;
        address account = actors[between(who, 0, actors.length - 1)];
        (uint256[] memory ids, uint256[5][] memory amounts, bytes32[][] memory proofs) = _claimable(kind, account);
        if (ids.length == 0) return;
        uint256[5] memory before = _stuck(account);
        OutSnap memory s = _snapOut();
        vm.prank(_caller(callerSeed));
        try d.claimMany(kind, ids, account, amounts, proofs) {}
        catch (bytes memory err) {
            _unexpected("claimMany", err);
        }
        _absorbOut(s);
        for (uint256 k = 0; k < ids.length; k++) {
            claimedFlags.push(Flag(kind, ids[k], account));
        }
        _settledSum(account, _sumOf(amounts), before);
    }

    /// @dev The Keeper pushes one holder's claimable leaves, taking a fee within the 5% bound; the fee is the
    ///      only token that may leave to anyone but a leaf account.
    function push(uint256 kindSeed, uint256 who, uint256 gasPriceSeed, uint256 rateSeed) public {
        NutzDistributor.Kind kind = kindSeed % 2 == 0 ? EPOCH : DRAW;
        address account = actors[between(who, 0, actors.length - 1)];
        (uint256[] memory ids, uint256[5][] memory amounts, bytes32[][] memory proofs) = _claimable(kind, account);
        if (ids.length == 0) return;
        PushPlan memory p;
        p.entries = new NutzDistributor.PushEntry[](1);
        p.entries[0] = NutzDistributor.PushEntry(account, kind, ids, amounts, proofs);
        p.sum = _sumOf(amounts);
        (p.gasPrice, p.rate, p.fee) = _pushFee(ids.length, p.sum[USDG], gasPriceSeed, rateSeed);
        p.before = _stuck(account);
        p.keeperBefore = _stuck(keeper);
        _pushOne(p);
        for (uint256 k = 0; k < ids.length; k++) {
            claimedFlags.push(Flag(kind, ids[k], account));
        }
        _pushed(account, p.sum, p.fee, p.before, p.keeperBefore);
    }

    /// @dev One push call and its arguments, kept together so `push` stays within the stack.
    struct PushPlan {
        NutzDistributor.PushEntry[] entries;
        uint256 gasPrice;
        uint256 rate;
        uint256 fee;
        uint256[5] sum;
        uint256[5] before;
        uint256[5] keeperBefore;
    }

    function _pushOne(PushPlan memory p) internal {
        OutSnap memory s = _snapOut();
        vm.prank(keeper);
        try d.pushClaims(p.entries, p.gasPrice, p.rate) {}
        catch (bytes memory err) {
            _unexpected("pushClaims", err);
        }
        _absorbOut(s);
    }

    /// @dev A rate inside the Signer-set range and the largest gas price whose fee stays within
    ///      MAX_PUSH_FEE_BPS of the pushed USDG (zero USDG means a zero fee).
    function _pushFee(uint256 leaves, uint256 usdg, uint256 gasPriceSeed, uint256 rateSeed)
        internal
        returns (uint256 gasPrice, uint256 rate, uint256 fee)
    {
        rate = between(rateSeed, d.minUsdgPerEth(), d.maxUsdgPerEth());
        uint256 units = d.PUSH_GAS_BASE() + leaves * d.PUSH_GAS_PER_LEAF();
        uint256 maxGasPrice = usdg * d.MAX_PUSH_FEE_BPS() / 10_000 * 1e18 / (units * rate);
        gasPrice = between(gasPriceSeed, 0, maxGasPrice);
        fee = units * gasPrice * rate / 1e18;
    }

    /// @dev Bookkeeping after a push: the account may receive its sum minus the fee, the Keeper the fee.
    function _pushed(
        address account,
        uint256[5] memory sum,
        uint256 fee,
        uint256[5] memory before,
        uint256[5] memory keeperBefore
    ) internal {
        for (uint256 i = 0; i < 5; i++) {
            ghostClaimed[i] += sum[i];
        }
        sum[USDG] -= fee;
        _allow(account, sum);
        uint256[5] memory feeOnly;
        feeOnly[USDG] = fee;
        _allow(keeper, feeOnly);
        _stuckDelta(account, before);
        _stuckDelta(keeper, keeperBefore);
    }

    function _sumOf(uint256[5][] memory amounts) internal pure returns (uint256[5] memory sum) {
        for (uint256 k = 0; k < amounts.length; k++) {
            for (uint256 i = 0; i < 5; i++) {
                sum[i] += amounts[k][i];
            }
        }
    }

    function togglePause(uint256 t_) public {
        MockERC20 token = tok[between(t_, 0, 4)];
        token.setPaused(!token.paused());
    }

    /// @dev Collecting a stuck amount adds nothing to `allowed`: the claim that stranded it already did.
    function claimStuck(uint256 who, uint256 t_) public {
        address account = who % 5 == 0 ? keeper : actors[between(who, 0, actors.length - 1)];
        t_ = between(t_, 0, 4);
        uint256 amount = d.stuck(account)[t_];
        if (amount == 0 || tok[t_].paused()) return;
        OutSnap memory s = _snapOut();
        try d.claimStuck(account, t_) {}
        catch (bytes memory err) {
            _unexpected("claimStuck", err);
        }
        _absorbOut(s);
        ghostStuckOutstanding[t_] -= amount;
    }

    function fulfillAndPull(uint256 seed) public {
        uint256 id = d.rootedThrough(DRAW) + 1;
        if (id > d.currentDraw() || d.drawConverted(id) || d.acornPoolUsdg() == 0) return;
        for (uint256 i = 0; i < 5; i++) {
            if (tok[i].paused()) return; // the "swap" round-trip needs every token transferable
        }
        draw.setSeed(id, keccak256(abi.encode(seed, id)));
        uint256 pool = d.acornPoolUsdg();
        OutSnap memory s = _snapOut();
        vm.prank(converter);
        try d.pullAcorn(id) {}
        catch (bytes memory err) {
            _unexpected("pullAcorn", err);
        }
        _absorbOut(s);
        ghostAcornPulled += pool;
        uint256[5] memory poolOnly;
        poolOnly[USDG] = pool;
        _allow(converter, poolOnly);
        // the Converter "swaps" the pool into stocks and returns it, minus one leg kept as USDG
        uint256[5] memory a;
        a[0] = pool / 4;
        a[1] = pool / 4;
        a[2] = pool / 4;
        a[4] = pool - 3 * (pool / 4);
        for (uint256 i = 0; i < 5; i++) {
            tok[i].mint(converter, a[i]);
            ghostFunded[i] += a[i];
        }
        vm.prank(converter);
        try d.notifyDrawFunding(id, a) {}
        catch (bytes memory err) {
            _unexpected("notifyDrawFunding", err);
        }
        if (!drawSeen[id]) {
            drawSeen[id] = true;
            fundedDraws.push(id);
        }
    }

    // ------------------------------------------------------------- attacks
    // Each one must revert with the named error; a reverted call moves nothing, so no balance check is needed.

    /// @dev A valid leaf with one proof element flipped, or a bogus proof for a single-leaf tree.
    function attackWrongProof(uint256 kindSeed, uint256 pick, uint256 leaf, uint256 flip) public {
        (NutzDistributor.Kind kind, uint256 id, Claim[] memory tree, uint256 k) = _target(kindSeed, pick, leaf);
        if (tree.length == 0 || d.claimed(kind, id, tree[k].account)) return;
        bytes32[] memory proof = proofOf(id, tree, k);
        if (proof.length == 0) {
            proof = new bytes32[](1);
            proof[0] = keccak256(abi.encode("bogus", flip));
        } else {
            uint256 idx = between(flip, 0, proof.length - 1);
            proof[idx] = proof[idx] ^ bytes32(uint256(1) << (flip % 256));
        }
        _refusedClaim(
            _caller(flip),
            kind,
            id,
            tree[k].account,
            tree[k].amounts,
            proof,
            abi.encodeWithSelector(NutzDistributor.InvalidProof.selector)
        );
    }

    /// @dev Someone else's amounts and proof presented for a different account.
    function attackForeignAccount(uint256 kindSeed, uint256 pick, uint256 leaf, uint256 who) public {
        (NutzDistributor.Kind kind, uint256 id, Claim[] memory tree, uint256 k) = _target(kindSeed, pick, leaf);
        if (tree.length == 0) return;
        address thief = who % 2 == 0 ? stranger : actors[between(who, 0, actors.length - 1)];
        if (thief == tree[k].account) thief = stranger;
        bytes32[] memory proof = proofOf(id, tree, k);
        bytes memory expected = d.claimed(kind, id, thief)
            ? abi.encodeWithSelector(NutzDistributor.AlreadyClaimed.selector, id, thief)
            : abi.encodeWithSelector(NutzDistributor.InvalidProof.selector);
        _refusedClaim(thief, kind, id, thief, tree[k].amounts, proof, expected);
    }

    /// @dev A valid leaf with one amount raised by one unit.
    function attackInflatedAmounts(uint256 kindSeed, uint256 pick, uint256 leaf, uint256 t_) public {
        (NutzDistributor.Kind kind, uint256 id, Claim[] memory tree, uint256 k) = _target(kindSeed, pick, leaf);
        if (tree.length == 0 || d.claimed(kind, id, tree[k].account)) return;
        uint256[5] memory a = tree[k].amounts;
        a[between(t_, 0, 4)] += 1;
        bytes32[] memory proof = proofOf(id, tree, k);
        _refusedClaim(
            _caller(t_),
            kind,
            id,
            tree[k].account,
            a,
            proof,
            abi.encodeWithSelector(NutzDistributor.InvalidProof.selector)
        );
    }

    /// @dev A leaf that was already settled, presented again with its real proof.
    function attackReplay(uint256 pick, uint256 callerSeed) public {
        if (claimedFlags.length == 0) return;
        Flag memory f = claimedFlags[between(pick, 0, claimedFlags.length - 1)];
        Claim[] memory tree = _tree(f.kind, f.id);
        uint256 k = _indexOf(tree, f.account);
        if (k == type(uint256).max) return; // the period was re-rooted with a tree that no longer names them
        bytes32[] memory proof = proofOf(f.id, tree, k);
        _refusedClaim(
            _caller(callerSeed),
            f.kind,
            f.id,
            f.account,
            tree[k].amounts,
            proof,
            abi.encodeWithSelector(NutzDistributor.AlreadyClaimed.selector, f.id, f.account)
        );
    }

    /// @dev A valid leaf of the latest Root while its Dispute window is open, or of a voided Root.
    function attackNotFinal(uint256 kindSeed, uint256 leaf, uint256 callerSeed) public {
        NutzDistributor.Kind kind = kindSeed % 2 == 0 ? EPOCH : DRAW;
        uint256 id = d.rootedThrough(kind);
        if (id == 0 || d.isFinal(kind, id)) return;
        Claim[] memory tree = _tree(kind, id);
        if (tree.length == 0) return;
        uint256 k = between(leaf, 0, tree.length - 1);
        bytes32[] memory proof = proofOf(id, tree, k);
        _refusedClaim(
            _caller(callerSeed),
            kind,
            id,
            tree[k].account,
            tree[k].amounts,
            proof,
            abi.encodeWithSelector(NutzDistributor.NotFinal.selector, id)
        );
    }

    /// @dev Anyone but the Keeper calling pushClaims, even with nothing to push.
    function attackPushNotKeeper(uint256 who) public {
        address caller = who % 2 == 0 ? stranger : actors[between(who, 0, actors.length - 1)];
        NutzDistributor.PushEntry[] memory entries;
        uint256 rate = d.minUsdgPerEth(); // read before the prank: it is an external call too
        vm.prank(caller);
        try d.pushClaims(entries, 1 gwei, rate) {
            t(false, "a non-Keeper push went through");
        } catch (bytes memory err) {
            t(_reverted(err, abi.encodeWithSelector(Signers.NotKeeper.selector)), "non-Keeper push: wrong error");
        }
        ghostAttacksRejected++;
    }

    /// @dev The Keeper pushing someone's leaves to another account.
    function attackPushForeignAccount(uint256 kindSeed, uint256 who, uint256 thiefSeed) public {
        NutzDistributor.Kind kind = kindSeed % 2 == 0 ? EPOCH : DRAW;
        address account = actors[between(who, 0, actors.length - 1)];
        (uint256[] memory ids, uint256[5][] memory amounts, bytes32[][] memory proofs) = _claimable(kind, account);
        if (ids.length == 0) return;
        address thief = thiefSeed % 2 == 0 ? stranger : actors[between(thiefSeed, 0, actors.length - 1)];
        if (thief == account) thief = stranger;
        NutzDistributor.PushEntry[] memory entries = new NutzDistributor.PushEntry[](1);
        entries[0] = NutzDistributor.PushEntry(thief, kind, ids, amounts, proofs);
        uint256 rate = d.minUsdgPerEth();
        bytes memory expected = d.claimed(kind, ids[0], thief)
            ? abi.encodeWithSelector(NutzDistributor.AlreadyClaimed.selector, ids[0], thief)
            : abi.encodeWithSelector(NutzDistributor.InvalidProof.selector);
        vm.prank(keeper);
        try d.pushClaims(entries, 0, rate) {
            t(false, "a push to a foreign account went through");
        } catch (bytes memory err) {
            t(_reverted(err, expected), "foreign-account push: wrong error");
        }
        ghostAttacksRejected++;
    }

    // ------------------------------------------------------------- helpers

    /// @dev `caller` claims `a` for `account` and must be refused with exactly `expected`.
    function _refusedClaim(
        address caller,
        NutzDistributor.Kind kind,
        uint256 id,
        address account,
        uint256[5] memory a,
        bytes32[] memory proof,
        bytes memory expected
    ) internal {
        vm.prank(caller);
        try d.claim(kind, id, account, a, proof) {
            t(false, "an invalid claim went through");
        } catch (bytes memory err) {
            t(_reverted(err, expected), "invalid claim: wrong error");
        }
        ghostAttacksRejected++;
    }

    /// @dev A call the model says must succeed reverted: the run fails, the reason names the call and the error.
    function _unexpected(string memory what, bytes memory err) internal {
        t(false, _unexpectedReason(what, err));
    }

    function _snapOut() internal view returns (OutSnap memory s) {
        s.w = new uint256[5][](watched.length);
        for (uint256 i = 0; i < 5; i++) {
            s.dist[i] = tok[i].balanceOf(address(d));
            for (uint256 k = 0; k < watched.length; k++) {
                s.w[k][i] = tok[i].balanceOf(watched[k]);
            }
        }
    }

    /// @dev Absorbs every token that left the Distributor since `s` into ghostOut, by who gained it; a drop
    ///      that no watched address accounts for means a token reached someone the model does not know.
    function _absorbOut(OutSnap memory s) internal {
        for (uint256 i = 0; i < 5; i++) {
            uint256 after_ = tok[i].balanceOf(address(d));
            t(after_ <= s.dist[i], "the Distributor gained tokens inside a payout");
            uint256 out = s.dist[i] - after_;
            uint256 seen = 0;
            for (uint256 k = 0; k < watched.length; k++) {
                uint256 b = tok[i].balanceOf(watched[k]);
                t(b >= s.w[k][i], "a watched address lost tokens inside a payout");
                uint256 gain = b - s.w[k][i];
                if (gain == 0) continue;
                ghostOut[watched[k]][i] += gain;
                seen += gain;
                _noteRecipient(watched[k]);
            }
            eq(seen, out, "tokens left the Distributor to an address the model does not watch");
        }
    }

    function _noteRecipient(address to) internal {
        if (!recipientSeen[to]) {
            recipientSeen[to] = true;
            recipients.push(to);
        }
    }

    function _allow(address to, uint256[5] memory a) internal {
        for (uint256 i = 0; i < 5; i++) {
            ghostAllowed[to][i] += a[i];
        }
        _noteRecipient(to);
    }

    /// @dev Bookkeeping after one settled leaf: claimed, allowed, stuck delta, flag.
    function _settled(
        NutzDistributor.Kind kind,
        uint256 id,
        address account,
        uint256[5] memory a,
        uint256[5] memory stuckBefore
    ) internal {
        claimedFlags.push(Flag(kind, id, account));
        _settledSum(account, a, stuckBefore);
    }

    function _settledSum(address account, uint256[5] memory sum, uint256[5] memory stuckBefore) internal {
        for (uint256 i = 0; i < 5; i++) {
            ghostClaimed[i] += sum[i];
        }
        _allow(account, sum);
        _stuckDelta(account, stuckBefore);
    }

    function _stuckDelta(address account, uint256[5] memory before) internal {
        uint256[5] memory after_ = _stuck(account);
        for (uint256 i = 0; i < 5; i++) {
            ghostStuckOutstanding[i] += after_[i] - before[i];
        }
    }

    /// @dev Whether settling `a` against period `id` would push `claimed` past `totals`, and on which token.
    function _wouldExceedCap(NutzDistributor.Kind kind, uint256 id, uint256[5] memory a)
        internal
        view
        returns (bool, uint256)
    {
        NutzDistributor.Ledger memory L = d.ledger(kind, id);
        for (uint256 i = 0; i < 5; i++) {
            if (L.claimed[i] + a[i] > L.totals[i]) return (true, i);
        }
        return (false, 0);
    }

    /// @dev `account`'s unclaimed leaves across the final periods of `kind` that would not hit the cap.
    function _claimable(NutzDistributor.Kind kind, address account)
        internal
        view
        returns (uint256[] memory ids, uint256[5][] memory amounts, bytes32[][] memory proofs)
    {
        uint256[] storage funded = kind == EPOCH ? fundedEpochs : fundedDraws;
        ids = new uint256[](funded.length);
        amounts = new uint256[5][](funded.length);
        proofs = new bytes32[][](funded.length);
        uint256 n = 0;
        for (uint256 x = 0; x < funded.length; x++) {
            uint256 id = funded[x];
            if (!d.isFinal(kind, id) || d.claimed(kind, id, account)) continue;
            Claim[] memory tree = _tree(kind, id);
            uint256 k = _indexOf(tree, account);
            if (k == type(uint256).max) continue;
            (bool capped,) = _wouldExceedCap(kind, id, tree[k].amounts);
            if (capped) continue;
            ids[n] = id;
            amounts[n] = tree[k].amounts;
            proofs[n] = proofOf(id, tree, k);
            n++;
        }
        assembly ("memory-safe") {
            mstore(ids, n)
            mstore(amounts, n)
            mstore(proofs, n)
        }
    }

    function _target(uint256 kindSeed, uint256 pick, uint256 leaf)
        internal
        returns (NutzDistributor.Kind kind, uint256 id, Claim[] memory tree, uint256 k)
    {
        kind = kindSeed % 2 == 0 ? EPOCH : DRAW;
        id = _pickFinal(kind, pick);
        if (id == 0) return (kind, id, tree, 0);
        tree = _tree(kind, id);
        if (tree.length > 0) k = between(leaf, 0, tree.length - 1);
    }

    function _tree(NutzDistributor.Kind kind, uint256 id) internal view returns (Claim[] memory) {
        return kind == EPOCH ? epochTree[id] : drawTree[id];
    }

    function _indexOf(Claim[] memory tree, address account) internal pure returns (uint256) {
        for (uint256 k = 0; k < tree.length; k++) {
            if (tree[k].account == account) return k;
        }
        return type(uint256).max;
    }

    function _caller(uint256 seed) internal view returns (address) {
        return seed % 3 == 0 ? stranger : actors[seed % actors.length];
    }

    function _drawReady(uint256 id) internal view returns (bool) {
        return d.drawConverted(id) && draw.seedOf(id) != bytes32(0);
    }

    function _pickFinal(NutzDistributor.Kind kind, uint256 pick) internal returns (uint256) {
        uint256[] storage ids = kind == EPOCH ? fundedEpochs : fundedDraws;
        if (ids.length == 0) return 0;
        uint256 id = ids[between(pick, 0, ids.length - 1)];
        return d.isFinal(kind, id) ? id : 0;
    }

    /// @dev A rooted period, made Final by letting its Dispute window elapse if it is still open.
    function _pickRooted(NutzDistributor.Kind kind, uint256 pick) internal returns (uint256) {
        uint256[] storage ids = kind == EPOCH ? rootedEpochs : rootedDraws;
        if (ids.length == 0) return 0;
        uint256 id = ids[between(pick, 0, ids.length - 1)];
        NutzDistributor.Ledger memory L = d.ledger(kind, id);
        if (L.rootPostedAt == 0) return 0; // voided and not re-posted
        if (!d.isFinal(kind, id)) vm.warp(L.rootPostedAt + d.CLAIM_DELAY());
        return id;
    }

    /// @dev The first unclaimed leaf at or after `start`, wrapping around; max if every leaf is claimed.
    function _unclaimedFrom(NutzDistributor.Kind kind, uint256 id, Claim[] memory tree, uint256 start)
        internal
        view
        returns (uint256)
    {
        for (uint256 x = 0; x < tree.length; x++) {
            uint256 k = (start + x) % tree.length;
            if (!d.claimed(kind, id, tree[k].account)) return k;
        }
        return type(uint256).max;
    }

    function _stuck(address account) internal view returns (uint256[5] memory) {
        return d.stuck(account);
    }

    function _min(uint256 a, uint256 b) internal pure returns (uint256) {
        return a < b ? a : b;
    }
}
