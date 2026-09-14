// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {Test} from "forge-std/Test.sol";
import {NutzDistributor} from "../../src/NutzDistributor.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {MockNutzDraw} from "../mocks/MockNutzDraw.sol";
import {CompleteMerkle} from "murky/CompleteMerkle.sol";
import {MerkleTrees} from "../harness/MerkleTrees.sol";

/// @dev Drives the Distributor through bounded, always-succeeding actions and records ghost totals.
///      fail_on_revert is on, so every action must pre-check its own preconditions.
contract DistributorHandler is Test, MerkleTrees {
    NutzDistributor internal d;
    MockERC20[5] internal tok;
    MockNutzDraw internal draw;
    address internal converter;
    address internal keeper;
    uint256[3] internal keys;

    NutzDistributor.Kind internal constant EPOCH = NutzDistributor.Kind.Epoch;
    NutzDistributor.Kind internal constant DRAW = NutzDistributor.Kind.Draw;

    bytes32 internal constant DOMAIN_TYPEHASH =
        keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");
    bytes32 internal constant POST_ROOT_TYPEHASH =
        keccak256("PostRoot(uint8 kind,uint256 id,bytes32 root,uint256[5] totals,uint256 nonce)");
    bytes32 internal constant VOID_ROOT_TYPEHASH = keccak256("VoidRoot(uint8 kind,uint256 id,uint256 nonce)");

    // ---- ghosts ----
    uint256[5] public ghostFunded; // every token that entered through funding (incl. acorn USDG)
    uint256[5] public ghostClaimed; // every amount marked claimed (paid or stuck)
    uint256[5] public ghostStuckOutstanding; // stuck recorded minus stuck collected
    uint256 public ghostAcornPulled; // USDG that left through pullAcorn
    uint256 public ghostVoids;
    uint256 public ghostSkips;

    // per-period bookkeeping so claims can be replayed against posted trees
    address[] internal actors;
    mapping(uint256 id => Claim[]) internal epochTree;
    mapping(uint256 id => Claim[]) internal drawTree;
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
        for (uint256 i = 0; i < 4; i++) {
            actors.push(makeAddr(string.concat("holder-", vm.toString(i))));
        }
    }

    // ------------------------------------------------------------- actions

    function warp(uint256 secs) external {
        vm.warp(block.timestamp + bound(secs, 1, 6 hours));
    }

    function fundEpoch(uint256[5] memory a, uint256 acorn, uint256 offset) external {
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
    function postRoot(uint256 kindSeed, uint256 skip, uint256[5] memory spendBps, uint256 split) external {
        NutzDistributor.Kind kind = kindSeed % 2 == 0 ? EPOCH : DRAW;
        uint256 current = kind == EPOCH ? d.currentEpoch() : d.currentDraw();
        uint256 lo = d.rootedThrough(kind) + 1;
        if (lo >= current) return; // nothing closed yet
        uint256 id = lo + bound(skip, 0, current - 1 - lo);
        if (kind == DRAW && !_drawReady(id)) return;
        uint256[5] memory available = _available(kind, lo, id);
        uint256 n = 1 + bound(split, 0, actors.length - 1);
        (bytes32 root, uint256[5] memory totals) = _buildTree(kind, id, available, spendBps, n);
        bytes32 sh =
            keccak256(abi.encode(POST_ROOT_TYPEHASH, uint8(kind), id, root, keccak256(abi.encode(totals)), d.nonce()));
        d.postRoot(kind, id, root, totals, _sign(keys[0], sh), _sign(keys[1], sh));
        if (kind == EPOCH && !epochRooted[id]) {
            epochRooted[id] = true;
            rootedEpochs.push(id);
        }
        if (kind == DRAW && !drawRooted[id]) {
            drawRooted[id] = true;
            rootedDraws.push(id);
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
    function _buildTree(
        NutzDistributor.Kind kind,
        uint256 id,
        uint256[5] memory available,
        uint256[5] memory spendBps,
        uint256 n
    ) internal returns (bytes32 root, uint256[5] memory totals) {
        Claim[] storage tree = kind == EPOCH ? epochTree[id] : drawTree[id];
        while (tree.length > 0) {
            tree.pop();
        }
        for (uint256 k = 0; k < n; k++) {
            uint256[5] memory a;
            for (uint256 i = 0; i < 5; i++) {
                a[i] = available[i] * bound(spendBps[i], 0, 10_000) / 10_000 / n;
                totals[i] += a[i];
            }
            tree.push(Claim(actors[k], a));
        }
        Claim[] memory mem = tree;
        root = rootOf(id, mem);
    }

    function voidLatest(uint256 kindSeed) external {
        NutzDistributor.Kind kind = kindSeed % 2 == 0 ? EPOCH : DRAW;
        uint256 id = d.rootedThrough(kind);
        NutzDistributor.Ledger memory L = d.ledger(kind, id);
        if (L.rootPostedAt == 0 || d.isFinal(kind, id)) return;
        bytes32 sh = keccak256(abi.encode(VOID_ROOT_TYPEHASH, uint8(kind), id, d.nonce()));
        d.voidRoot(kind, id, _sign(keys[0], sh), _sign(keys[2], sh));
        ghostVoids++;
    }

    function claim(uint256 kindSeed, uint256 pick, uint256 leaf) external {
        NutzDistributor.Kind kind = kindSeed % 2 == 0 ? EPOCH : DRAW;
        uint256 id = _pickFinal(kind, pick);
        if (id == 0) return;
        Claim[] memory tree = kind == EPOCH ? epochTree[id] : drawTree[id];
        if (tree.length == 0) return;
        uint256 k = bound(leaf, 0, tree.length - 1);
        if (d.claimed(kind, id, tree[k].account)) return;
        uint256[5] memory before = _stuck(tree[k].account);
        d.claim(kind, id, tree[k].account, tree[k].amounts, proofOf(id, tree, k));
        uint256[5] memory after_ = _stuck(tree[k].account);
        for (uint256 i = 0; i < 5; i++) {
            ghostClaimed[i] += tree[k].amounts[i];
            ghostStuckOutstanding[i] += after_[i] - before[i];
        }
        claimedFlags.push(Flag(kind, id, tree[k].account));
    }

    function togglePause(uint256 t) external {
        MockERC20 token = tok[bound(t, 0, 4)];
        token.setPaused(!token.paused());
    }

    function claimStuck(uint256 who, uint256 t) external {
        address account = actors[bound(who, 0, actors.length - 1)];
        t = bound(t, 0, 4);
        uint256 amount = d.stuck(account)[t];
        if (amount == 0 || tok[t].paused()) return;
        d.claimStuck(account, t);
        ghostStuckOutstanding[t] -= amount;
    }

    function fulfillAndPull(uint256 seed) external {
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

    // ------------------------------------------------------------- helpers

    function _drawReady(uint256 id) internal view returns (bool) {
        return d.drawConverted(id) && draw.seedOf(id) != bytes32(0);
    }

    function _pickFinal(NutzDistributor.Kind kind, uint256 pick) internal view returns (uint256) {
        uint256[] storage ids = kind == EPOCH ? fundedEpochs : fundedDraws;
        if (ids.length == 0) return 0;
        uint256 id = ids[bound(pick, 0, ids.length - 1)];
        return d.isFinal(kind, id) ? id : 0;
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
