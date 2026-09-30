// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {NutzDistributor} from "../../src/NutzDistributor.sol";
import {Signers} from "../../src/Signers.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {MockNutzDraw} from "../mocks/MockNutzDraw.sol";
import {CompleteMerkle} from "murky/CompleteMerkle.sol";
import {MerkleTrees} from "../harness/MerkleTrees.sol";

/// @dev Drives the Distributor through bounded actions and records ghost totals. fail_on_revert is on, so
///      every action pre-checks its preconditions; the attack actions expect their revert explicitly, so a
///      call that should have been rejected and was not fails the run. Every action records the logs of its
///      call and absorbs each `Transfer` leaving the Distributor into `ghostOut`, the ledger of who was paid.
contract DistributorHandler is Test, MerkleTrees {
    NutzDistributor internal d;
    MockERC20[5] internal tok;
    MockNutzDraw internal draw;
    address internal converter;
    address internal keeper;
    address internal stranger;
    uint256[3] internal keys;

    NutzDistributor.Kind internal constant EPOCH = NutzDistributor.Kind.Epoch;
    NutzDistributor.Kind internal constant DRAW = NutzDistributor.Kind.Draw;
    uint256 internal constant USDG = 4;
    bytes32 internal constant TRANSFER_SIG = keccak256("Transfer(address,address,uint256)");

    bytes32 internal constant DOMAIN_TYPEHASH =
        keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");
    bytes32 internal constant POST_ROOT_TYPEHASH =
        keccak256("PostRoot(uint8 kind,uint256 id,bytes32 root,uint256[5] totals,uint256 nonce)");
    bytes32 internal constant VOID_ROOT_TYPEHASH = keccak256("VoidRoot(uint8 kind,uint256 id,uint256 nonce)");

    // ---- ghosts ----
    uint256[5] public ghostFunded; // every token that entered through funding (incl. acorn USDG)
    uint256[5] public ghostClaimed; // every amount marked claimed (paid, pushed or stuck)
    uint256[5] public ghostStuckOutstanding; // stuck recorded minus stuck collected
    uint256 public ghostAcornPulled; // USDG that left through pullAcorn
    uint256 public ghostVoids;
    uint256 public ghostSkips;
    uint256 public ghostCapRejections; // claims against an over-allocated Root that hit CapExceeded
    uint256 public ghostAttacksRejected; // attack actions that reverted as expected

    // who the Distributor paid (observed) versus who the model says it may pay (allowed); stuck is the gap
    mapping(address => uint256[5]) internal ghostOut;
    mapping(address => uint256[5]) internal ghostAllowed;
    address[] public recipients;
    mapping(address => bool) internal recipientSeen;

    // per-period bookkeeping so claims can be replayed against posted trees
    address[] internal actors;
    mapping(uint256 id => Claim[]) internal epochTree;
    mapping(uint256 id => Claim[]) internal drawTree;
    mapping(uint256 id => bool) internal epochOverAllocated; // leaves sum to more than the posted totals
    mapping(uint256 id => bool) internal drawOverAllocated;
    uint256[] public fundedEpochs;
    uint256[] public fundedDraws;
    mapping(uint256 id => bool) internal epochSeen;
    mapping(uint256 id => bool) internal drawSeen;
    uint256[] public rootedEpochs; // every id that ever received a Root (voided ones keep totals == 0)
    uint256[] public rootedDraws;
    mapping(uint256 id => bool) internal epochRooted;
    mapping(uint256 id => bool) internal drawRooted;

    struct Flag {
        NutzDistributor.Kind kind;
        uint256 id;
        address account;
    }
    Flag[] public claimedFlags;

    constructor(
        NutzDistributor d_,
        MockERC20[5] memory tok_,
        MockNutzDraw draw_,
        address converter_,
        address keeper_,
        uint256[3] memory keys_,
        CompleteMerkle merkle_
    ) {
        d = d_;
        tok = tok_;
        draw = draw_;
        converter = converter_;
        keeper = keeper_;
        keys = keys_;
        merkle = merkle_;
        stranger = makeAddr("stranger");
        for (uint256 i = 0; i < 4; i++) {
            actors.push(makeAddr(string.concat("holder-", vm.toString(i))));
        }
    }

    /// @dev Records the action's logs and absorbs every Transfer out of the Distributor into ghostOut.
    modifier recordsOut() {
        vm.recordLogs();
        _;
        _absorbOut();
    }

    // ------------------------------------------------------------- actions

    function warp(uint256 secs) external {
        vm.warp(block.timestamp + bound(secs, 1, 6 hours));
    }

    function fundEpoch(uint256[5] memory a, uint256 acorn, uint256 offset) external recordsOut {
        uint256 lo = d.rootedThrough(EPOCH) + 1;
        uint256 hi = d.currentEpoch();
        uint256 id = lo + bound(offset, 0, hi - lo);
        for (uint256 i = 0; i < 5; i++) {
            a[i] = tok[i].paused() ? 0 : bound(a[i], 0, 100e18);
            if (a[i] > 0) tok[i].mint(converter, a[i]);
            ghostFunded[i] += a[i];
        }
        acorn = tok[4].paused() ? 0 : bound(acorn, 0, 20e18);
        if (acorn > 0) tok[4].mint(converter, acorn);
        ghostFunded[4] += acorn;
        vm.prank(converter);
        d.notifyEpochFunding(id, a, acorn);
        if (!epochSeen[id]) {
            epochSeen[id] = true;
            fundedEpochs.push(id);
        }
    }

    /// @dev Posts the Root of the next closed period, spending a random share of funded + carry across actors.
    ///      One run in four posts an over-allocated Root: the totals stay within the cap, but every leaf
    ///      claims the whole totals, so the leaves sum to `n` times what the Root committed to. The
    ///      Distributor accepts it (spec §6 "bad root") and must stop the claims at the totals.
    function postRoot(uint256 kindSeed, uint256 skip, uint256[5] memory spendBps, uint256 split, uint256 mode)
        external
        recordsOut
    {
        NutzDistributor.Kind kind = kindSeed % 2 == 0 ? EPOCH : DRAW;
        uint256 current = kind == EPOCH ? d.currentEpoch() : d.currentDraw();
        uint256 lo = d.rootedThrough(kind) + 1;
        if (lo >= current) {
            // nothing closed yet: let the open period end, as the Keeper would wait for it
            vm.warp(kind == EPOCH ? (lo + 1) * 3600 : (lo + 1) * 604_800);
            current = lo + 1;
        }
        uint256 id = lo + bound(skip, 0, current - 1 - lo);
        if (kind == DRAW && !_drawReady(id)) return;
        uint256[5] memory available = _available(kind, lo, id);
        uint256 n = 1 + bound(split, 0, actors.length - 1);
        bool overAllocate = mode % 4 == 0 && n > 1;
        (bytes32 root, uint256[5] memory totals) = _buildTree(kind, id, available, spendBps, n, overAllocate);
        bytes32 sh =
            keccak256(abi.encode(POST_ROOT_TYPEHASH, uint8(kind), id, root, keccak256(abi.encode(totals)), d.nonce()));
        d.postRoot(kind, id, root, totals, _sign(keys[0], sh), _sign(keys[1], sh));
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

    /// @dev Rebuilds the period's tree in handler storage with `n` actors sharing a slice of `available`.
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
            share[i] = available[i] * bound(spendBps[i], 0, 10_000) / 10_000 / n;
            totals[i] = share[i] * n;
        }
        for (uint256 k = 0; k < n; k++) {
            tree.push(Claim(actors[k], overAllocate ? totals : share));
        }
        Claim[] memory mem = tree;
        root = rootOf(id, mem);
    }

    function voidLatest(uint256 kindSeed) external recordsOut {
        NutzDistributor.Kind kind = kindSeed % 2 == 0 ? EPOCH : DRAW;
        uint256 id = d.rootedThrough(kind);
        NutzDistributor.Ledger memory L = d.ledger(kind, id);
        if (L.rootPostedAt == 0 || d.isFinal(kind, id)) return;
        bytes32 sh = keccak256(abi.encode(VOID_ROOT_TYPEHASH, uint8(kind), id, d.nonce()));
        d.voidRoot(kind, id, _sign(keys[0], sh), _sign(keys[2], sh));
        ghostVoids++;
    }

    /// @dev A valid leaf claimed by anyone: the account itself, another holder or a stranger. Tokens must
    ///      reach `account` regardless of the caller. Against an over-allocated Root the claim that would
    ///      push `claimed` past `totals` must revert CapExceeded.
    function claim(uint256 kindSeed, uint256 pick, uint256 leaf, uint256 callerSeed) external recordsOut {
        NutzDistributor.Kind kind = kindSeed % 2 == 0 ? EPOCH : DRAW;
        uint256 id = _pickRooted(kind, pick);
        if (id == 0) return;
        Claim[] memory tree = _tree(kind, id);
        if (tree.length == 0) return;
        uint256 k = _unclaimedFrom(kind, id, tree, bound(leaf, 0, tree.length - 1));
        if (k == type(uint256).max) return;
        (bool capped, uint256 t) = _wouldExceedCap(kind, id, tree[k].amounts);
        bytes32[] memory proof = proofOf(id, tree, k); // built before the prank: murky is an external call
        vm.prank(_caller(callerSeed));
        if (capped) {
            vm.expectRevert(abi.encodeWithSelector(NutzDistributor.CapExceeded.selector, t));
            d.claim(kind, id, tree[k].account, tree[k].amounts, proof);
            ghostCapRejections++;
            return;
        }
        uint256[5] memory before = _stuck(tree[k].account);
        d.claim(kind, id, tree[k].account, tree[k].amounts, proof);
        _settled(kind, id, tree[k].account, tree[k].amounts, before);
    }

    /// @dev Every unclaimed, claimable leaf of one holder across the final periods of `kind`, in one call.
    function claimMany(uint256 kindSeed, uint256 who, uint256 callerSeed) external recordsOut {
        NutzDistributor.Kind kind = kindSeed % 2 == 0 ? EPOCH : DRAW;
        address account = actors[bound(who, 0, actors.length - 1)];
        (uint256[] memory ids, uint256[5][] memory amounts, bytes32[][] memory proofs) = _claimable(kind, account);
        if (ids.length == 0) return;
        uint256[5] memory before = _stuck(account);
        vm.prank(_caller(callerSeed));
        d.claimMany(kind, ids, account, amounts, proofs);
        for (uint256 k = 0; k < ids.length; k++) {
            claimedFlags.push(Flag(kind, ids[k], account));
        }
        _settledSum(account, _sumOf(amounts), before);
    }

    /// @dev The Keeper pushes one holder's claimable leaves, taking a fee within the 5% bound; the fee is the
    ///      only token that may leave to anyone but a leaf account.
    function push(uint256 kindSeed, uint256 who, uint256 gasPriceSeed, uint256 rateSeed) external recordsOut {
        NutzDistributor.Kind kind = kindSeed % 2 == 0 ? EPOCH : DRAW;
        address account = actors[bound(who, 0, actors.length - 1)];
        (uint256[] memory ids, uint256[5][] memory amounts, bytes32[][] memory proofs) = _claimable(kind, account);
        if (ids.length == 0) return;
        uint256[5] memory sum = _sumOf(amounts);
        (uint256 gasPrice, uint256 rate, uint256 fee) = _pushFee(ids.length, sum[USDG], gasPriceSeed, rateSeed);

        NutzDistributor.PushEntry[] memory entries = new NutzDistributor.PushEntry[](1);
        entries[0] = NutzDistributor.PushEntry(account, kind, ids, amounts, proofs);
        uint256[5] memory before = _stuck(account);
        uint256[5] memory keeperBefore = _stuck(keeper);
        vm.prank(keeper);
        d.pushClaims(entries, gasPrice, rate);

        for (uint256 k = 0; k < ids.length; k++) {
            claimedFlags.push(Flag(kind, ids[k], account));
        }
        _pushed(account, sum, fee, before, keeperBefore);
    }

    /// @dev A rate inside the Signer-set range and the largest gas price whose fee stays within
    ///      MAX_PUSH_FEE_BPS of the pushed USDG (zero USDG means a zero fee).
    function _pushFee(uint256 leaves, uint256 usdg, uint256 gasPriceSeed, uint256 rateSeed)
        internal
        view
        returns (uint256 gasPrice, uint256 rate, uint256 fee)
    {
        rate = bound(rateSeed, d.minUsdgPerEth(), d.maxUsdgPerEth());
        uint256 units = d.PUSH_GAS_BASE() + leaves * d.PUSH_GAS_PER_LEAF();
        uint256 maxGasPrice = usdg * d.MAX_PUSH_FEE_BPS() / 10_000 * 1e18 / (units * rate);
        gasPrice = bound(gasPriceSeed, 0, maxGasPrice);
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

    function togglePause(uint256 t) external {
        MockERC20 token = tok[bound(t, 0, 4)];
        token.setPaused(!token.paused());
    }

    /// @dev Collecting a stuck amount adds nothing to `allowed`: the claim that stranded it already did.
    function claimStuck(uint256 who, uint256 t) external recordsOut {
        address account = who % 5 == 0 ? keeper : actors[bound(who, 0, actors.length - 1)];
        t = bound(t, 0, 4);
        uint256 amount = d.stuck(account)[t];
        if (amount == 0 || tok[t].paused()) return;
        d.claimStuck(account, t);
        ghostStuckOutstanding[t] -= amount;
    }

    function fulfillAndPull(uint256 seed) external recordsOut {
        uint256 id = d.rootedThrough(DRAW) + 1;
        if (id > d.currentDraw() || d.drawConverted(id) || d.acornPoolUsdg() == 0) return;
        for (uint256 i = 0; i < 5; i++) {
            if (tok[i].paused()) return; // the "swap" round-trip needs every token transferable
        }
        draw.setSeed(id, keccak256(abi.encode(seed, id)));
        uint256 pool = d.acornPoolUsdg();
        vm.prank(converter);
        d.pullAcorn(id);
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
        d.notifyDrawFunding(id, a);
        if (!drawSeen[id]) {
            drawSeen[id] = true;
            fundedDraws.push(id);
        }
    }

    // ------------------------------------------------------------- attacks
    // Each one must revert with the named error; none may move a token. The recorded logs prove the latter.

    /// @dev A valid leaf with one proof element flipped, or a bogus proof for a single-leaf tree.
    function attackWrongProof(uint256 kindSeed, uint256 pick, uint256 leaf, uint256 flip) external recordsOut {
        (NutzDistributor.Kind kind, uint256 id, Claim[] memory tree, uint256 k) = _target(kindSeed, pick, leaf);
        if (tree.length == 0 || d.claimed(kind, id, tree[k].account)) return;
        bytes32[] memory proof = proofOf(id, tree, k);
        if (proof.length == 0) {
            proof = new bytes32[](1);
            proof[0] = keccak256(abi.encode("bogus", flip));
        } else {
            uint256 idx = bound(flip, 0, proof.length - 1);
            proof[idx] = proof[idx] ^ bytes32(uint256(1) << (flip % 256));
        }
        vm.prank(_caller(flip));
        vm.expectRevert(NutzDistributor.InvalidProof.selector);
        d.claim(kind, id, tree[k].account, tree[k].amounts, proof);
        ghostAttacksRejected++;
    }

    /// @dev Someone else's amounts and proof presented for a different account.
    function attackForeignAccount(uint256 kindSeed, uint256 pick, uint256 leaf, uint256 who) external recordsOut {
        (NutzDistributor.Kind kind, uint256 id, Claim[] memory tree, uint256 k) = _target(kindSeed, pick, leaf);
        if (tree.length == 0) return;
        address thief = who % 2 == 0 ? stranger : actors[bound(who, 0, actors.length - 1)];
        if (thief == tree[k].account) thief = stranger;
        bytes32[] memory proof = proofOf(id, tree, k);
        bool taken = d.claimed(kind, id, thief);
        vm.prank(thief);
        if (taken) {
            vm.expectRevert(abi.encodeWithSelector(NutzDistributor.AlreadyClaimed.selector, id, thief));
        } else {
            vm.expectRevert(NutzDistributor.InvalidProof.selector);
        }
        d.claim(kind, id, thief, tree[k].amounts, proof);
        ghostAttacksRejected++;
    }

    /// @dev A valid leaf with one amount raised by one unit.
    function attackInflatedAmounts(uint256 kindSeed, uint256 pick, uint256 leaf, uint256 t) external recordsOut {
        (NutzDistributor.Kind kind, uint256 id, Claim[] memory tree, uint256 k) = _target(kindSeed, pick, leaf);
        if (tree.length == 0 || d.claimed(kind, id, tree[k].account)) return;
        uint256[5] memory a = tree[k].amounts;
        a[bound(t, 0, 4)] += 1;
        bytes32[] memory proof = proofOf(id, tree, k);
        vm.prank(_caller(t));
        vm.expectRevert(NutzDistributor.InvalidProof.selector);
        d.claim(kind, id, tree[k].account, a, proof);
        ghostAttacksRejected++;
    }

    /// @dev A leaf that was already settled, presented again with its real proof.
    function attackReplay(uint256 pick, uint256 callerSeed) external recordsOut {
        if (claimedFlags.length == 0) return;
        Flag memory f = claimedFlags[bound(pick, 0, claimedFlags.length - 1)];
        Claim[] memory tree = _tree(f.kind, f.id);
        uint256 k = _indexOf(tree, f.account);
        if (k == type(uint256).max) return; // the period was re-rooted with a tree that no longer names them
        bytes32[] memory proof = proofOf(f.id, tree, k);
        vm.prank(_caller(callerSeed));
        vm.expectRevert(abi.encodeWithSelector(NutzDistributor.AlreadyClaimed.selector, f.id, f.account));
        d.claim(f.kind, f.id, f.account, tree[k].amounts, proof);
        ghostAttacksRejected++;
    }

    /// @dev A valid leaf of the latest Root while its Dispute window is open, or of a voided Root.
    function attackNotFinal(uint256 kindSeed, uint256 leaf, uint256 callerSeed) external recordsOut {
        NutzDistributor.Kind kind = kindSeed % 2 == 0 ? EPOCH : DRAW;
        uint256 id = d.rootedThrough(kind);
        if (id == 0 || d.isFinal(kind, id)) return;
        Claim[] memory tree = _tree(kind, id);
        if (tree.length == 0) return;
        uint256 k = bound(leaf, 0, tree.length - 1);
        bytes32[] memory proof = proofOf(id, tree, k);
        vm.prank(_caller(callerSeed));
        vm.expectRevert(abi.encodeWithSelector(NutzDistributor.NotFinal.selector, id));
        d.claim(kind, id, tree[k].account, tree[k].amounts, proof);
        ghostAttacksRejected++;
    }

    /// @dev Anyone but the Keeper calling pushClaims, even with nothing to push.
    function attackPushNotKeeper(uint256 who) external recordsOut {
        address caller = who % 2 == 0 ? stranger : actors[bound(who, 0, actors.length - 1)];
        NutzDistributor.PushEntry[] memory entries;
        uint256 rate = d.minUsdgPerEth(); // read before the prank: it is an external call too
        vm.prank(caller);
        vm.expectRevert(Signers.NotKeeper.selector);
        d.pushClaims(entries, 1 gwei, rate);
        ghostAttacksRejected++;
    }

    /// @dev The Keeper pushing someone's leaves to another account.
    function attackPushForeignAccount(uint256 kindSeed, uint256 who, uint256 thiefSeed) external recordsOut {
        NutzDistributor.Kind kind = kindSeed % 2 == 0 ? EPOCH : DRAW;
        address account = actors[bound(who, 0, actors.length - 1)];
        (uint256[] memory ids, uint256[5][] memory amounts, bytes32[][] memory proofs) = _claimable(kind, account);
        if (ids.length == 0) return;
        address thief = thiefSeed % 2 == 0 ? stranger : actors[bound(thiefSeed, 0, actors.length - 1)];
        if (thief == account) thief = stranger;
        NutzDistributor.PushEntry[] memory entries = new NutzDistributor.PushEntry[](1);
        entries[0] = NutzDistributor.PushEntry(thief, kind, ids, amounts, proofs);
        uint256 rate = d.minUsdgPerEth();
        bool taken = d.claimed(kind, ids[0], thief);
        vm.prank(keeper);
        if (taken) {
            vm.expectRevert(abi.encodeWithSelector(NutzDistributor.AlreadyClaimed.selector, ids[0], thief));
        } else {
            vm.expectRevert(NutzDistributor.InvalidProof.selector);
        }
        d.pushClaims(entries, 0, rate);
        ghostAttacksRejected++;
    }

    // ------------------------------------------------------------- helpers

    function _absorbOut() internal {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 n = 0; n < logs.length; n++) {
            Vm.Log memory entry = logs[n];
            if (entry.topics.length != 3 || entry.topics[0] != TRANSFER_SIG) continue;
            if (address(uint160(uint256(entry.topics[1]))) != address(d)) continue;
            uint256 t = _tokenIndex(entry.emitter);
            if (t == type(uint256).max) continue;
            address to = address(uint160(uint256(entry.topics[2])));
            ghostOut[to][t] += abi.decode(entry.data, (uint256));
            if (!recipientSeen[to]) {
                recipientSeen[to] = true;
                recipients.push(to);
            }
        }
    }

    function _tokenIndex(address token) internal view returns (uint256) {
        for (uint256 i = 0; i < 5; i++) {
            if (address(tok[i]) == token) return i;
        }
        return type(uint256).max;
    }

    function _allow(address to, uint256[5] memory a) internal {
        for (uint256 i = 0; i < 5; i++) {
            ghostAllowed[to][i] += a[i];
        }
        if (!recipientSeen[to]) {
            recipientSeen[to] = true;
            recipients.push(to);
        }
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
        view
        returns (NutzDistributor.Kind kind, uint256 id, Claim[] memory tree, uint256 k)
    {
        kind = kindSeed % 2 == 0 ? EPOCH : DRAW;
        id = _pickFinal(kind, pick);
        if (id == 0) return (kind, id, tree, 0);
        tree = _tree(kind, id);
        if (tree.length > 0) k = bound(leaf, 0, tree.length - 1);
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

    function _pickFinal(NutzDistributor.Kind kind, uint256 pick) internal view returns (uint256) {
        uint256[] storage ids = kind == EPOCH ? fundedEpochs : fundedDraws;
        if (ids.length == 0) return 0;
        uint256 id = ids[bound(pick, 0, ids.length - 1)];
        return d.isFinal(kind, id) ? id : 0;
    }

    /// @dev A rooted period, made Final by letting its Dispute window elapse if it is still open.
    function _pickRooted(NutzDistributor.Kind kind, uint256 pick) internal returns (uint256) {
        uint256[] storage ids = kind == EPOCH ? rootedEpochs : rootedDraws;
        if (ids.length == 0) return 0;
        uint256 id = ids[bound(pick, 0, ids.length - 1)];
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

    function _sign(uint256 key, bytes32 structHash) internal view returns (bytes memory) {
        bytes32 ds = keccak256(
            abi.encode(DOMAIN_TYPEHASH, keccak256("NutzDistributor"), keccak256("1"), block.chainid, address(d))
        );
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(key, keccak256(abi.encodePacked("\x19\x01", ds, structHash)));
        return abi.encodePacked(r, s, v);
    }

    // ------------------------------------------------------------- views

    function outOf(address to) external view returns (uint256[5] memory) {
        return ghostOut[to];
    }

    function allowedOf(address to) external view returns (uint256[5] memory) {
        return ghostAllowed[to];
    }

    function recipientCount() external view returns (uint256) {
        return recipients.length;
    }

    function isLeafAccount(address who) external view returns (bool) {
        for (uint256 i = 0; i < actors.length; i++) {
            if (actors[i] == who) return true;
        }
        return false;
    }

    function keeperAddress() external view returns (address) {
        return keeper;
    }

    function converterAddress() external view returns (address) {
        return converter;
    }

    function actorCount() external view returns (uint256) {
        return actors.length;
    }

    function actor(uint256 i) external view returns (address) {
        return actors[i];
    }

    function fundedEpochCount() external view returns (uint256) {
        return fundedEpochs.length;
    }

    function fundedDrawCount() external view returns (uint256) {
        return fundedDraws.length;
    }

    function rootedEpochCount() external view returns (uint256) {
        return rootedEpochs.length;
    }

    function rootedDrawCount() external view returns (uint256) {
        return rootedDraws.length;
    }

    function claimedFlagCount() external view returns (uint256) {
        return claimedFlags.length;
    }
}
