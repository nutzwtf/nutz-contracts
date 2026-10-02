// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {Test, console} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {CompleteMerkle} from "murky/CompleteMerkle.sol";
import {Deploy} from "../../script/Deploy.s.sol";
import {NutzDistributor} from "../../src/NutzDistributor.sol";
import {NutzConverter} from "../../src/NutzConverter.sol";
import {MerkleTrees} from "../harness/MerkleTrees.sol";

/// @dev The push-fee gas constants measured on a fork of Robinhood Chain (nutz-platform launch ticket 02; engineering
///      spec §3.1 immutables, §3.3 `pushClaims`). The Distributor and the Converter are deployed by the deploy script
///      from script/config/robinhood.json (test Signers and Keeper); the real Stock Tokens and USDG are dealt to the
///      Converter, which funds the Epochs; a Root over 50 leaves is posted and `pushClaims` is measured for batches of
///      1, 10 and 50 one-Epoch entries, every entry five real transfers, plus one entry with five Epochs. The fit is
///      linear through the two extremes: `slope = (g50 − g1) / 49` per one-leaf entry, `PUSH_GAS_PER_LEAF` from the
///      five-Epoch entry, the rest of the slope is the per-entry overhead, and the per-transaction constant (the
///      intercept plus the 21,000 intrinsic) is amortised over a 200-entry batch (§5). The residual of the line at 10
///      entries must stay under 5%, so a chain upgrade that moves the gas fails the nightly.
///         Skipped unless `RPC_4663` is set; `FORK_BLOCK_4663` overrides the pinned block (0 = latest).
contract PushGasForkTest is Test, MerkleTrees {
    uint256 internal constant FORK_BLOCK = 78_359_281; // 2026-10-02
    uint256 internal constant BATCH = 200; // the Keeper's batch size, engineering spec §5 step 4
    uint256 internal constant LEAVES = 50;
    uint256 internal constant KEY_A = 0xA11CE;
    uint256 internal constant KEY_B = 0xB0B;
    uint256 internal constant KEY_C = 0xCA11;
    bytes32 internal constant DOMAIN_TYPEHASH =
        keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");
    bytes32 internal constant POST_ROOT_TYPEHASH =
        keccak256("PostRoot(uint8 kind,uint256 id,bytes32 root,uint256[5] totals,uint256 nonce)");
    NutzDistributor.Kind internal constant EPOCH = NutzDistributor.Kind.Epoch;

    address internal keeper = makeAddr("keeper");
    NutzDistributor internal d;
    NutzConverter internal c;
    IERC20[5] internal tok;
    uint256 internal epoch; // the deploy Epoch, funded and rooted
    Claim[] internal claims;
    uint256 internal usdgPerEth;

    function setUp() public {
        string memory url = vm.envOr("RPC_4663", string(""));
        if (bytes(url).length == 0) vm.skip(true);
        uint256 blockNumber = vm.envOr("FORK_BLOCK_4663", FORK_BLOCK);
        if (blockNumber == 0) vm.createSelectFork(url);
        else vm.createSelectFork(url, blockNumber);
        merkle = new CompleteMerkle();

        Deploy script = new Deploy();
        Deploy.Params memory p = script.load(string.concat(vm.projectRoot(), "/script/config/robinhood.json"));
        p.signers = [vm.addr(KEY_A), vm.addr(KEY_B), vm.addr(KEY_C)];
        p.keeper = keeper;
        tok = p.tokens;
        usdgPerEth = p.minUsdgPerEth;
        (d, c,) = script.deploy(p, address(script));
        epoch = d.currentEpoch();

        // 50 Holders, each owed a little of every Reward Token, so every push moves all five.
        for (uint256 i = 0; i < LEAVES; i++) {
            claims.push(Claim(makeAddr(string.concat("holder-", vm.toString(i))), _amounts(i)));
        }
        _fundAndRoot(epoch, 1);
    }

    function test_pushGas_measuresTheConstants() public {
        uint256 g1 = _push(1);
        uint256 g10 = _push(10);
        uint256 g50 = _push(50);
        uint256 g1x5 = _pushFiveEpochs(1);
        uint256 g10x5 = _pushFiveEpochs(10);

        // One-leaf entries: the hourly batch. The line through 1 and 50 is the fit; its slope is one entry's cost
        // (five transfers to a fresh account dominate it), its intercept the per-transaction constant.
        uint256 slope = (g50 - g1) / (LEAVES - 1);
        uint256 perTx = g1 - slope + 21_000;
        uint256 fitted10 = (g1 - slope) + 10 * slope;
        uint256 residualBps = (fitted10 > g10 ? fitted10 - g10 : g10 - fitted10) * 10_000 / g10;
        // Extra leaves of one entry: a cold leaf is the first claim of its Epoch in the transaction (its five
        // per-token claimed sums are fresh slots); a warm leaf follows another entry's claim of the same Epoch.
        uint256 coldLeaf = (g1x5 - g1) / 4;
        uint256 warmLeaf = ((g10x5 - g1x5) / 9 - slope) / 4;
        uint256 perEntry = slope - warmLeaf; // what the entry costs beyond its (warm) leaf
        uint256 base = perEntry + perTx / BATCH;

        console.log("fork block", vm.envOr("FORK_BLOCK_4663", FORK_BLOCK));
        console.log("gas: 1 entry", g1);
        console.log("gas: 10 entries", g10);
        console.log("gas: 50 entries", g50);
        console.log("gas: 1 entry x 5 Epochs", g1x5);
        console.log("gas: 10 entries x 5 Epochs", g10x5);
        console.log("slope per one-leaf entry", slope);
        console.log("per transaction (intercept + 21000)", perTx);
        console.log("residual at 10, bps", residualBps);
        console.log("per leaf, cold (first claim of its Epoch in the tx)", coldLeaf);
        console.log("per leaf, warm", warmLeaf);
        console.log("per entry beyond its warm leaf", perEntry);
        console.log("PUSH_GAS_BASE = per entry + per tx / 200, rounded up", _roundUp(base));
        console.log("PUSH_GAS_PER_LEAF = cold leaf, rounded up", _roundUp(coldLeaf));
        console.log("config has base / per leaf", d.PUSH_GAS_BASE(), d.PUSH_GAS_PER_LEAF());

        assertLt(residualBps, 500, "the line through 1 and 50 misses 10 by 5% or more: re-measure");
        assertLe(_roundUp(base), d.PUSH_GAS_BASE(), "the config's PUSH_GAS_BASE is below the measurement");
        assertLe(_roundUp(coldLeaf), d.PUSH_GAS_PER_LEAF(), "the config's PUSH_GAS_PER_LEAF is below the measurement");
    }

    // ---- the measurements, each on a fresh snapshot of the rooted state ----

    /// @dev `n` entries of one Epoch each, as the Keeper's hourly batch.
    function _push(uint256 n) internal returns (uint256 gas) {
        uint256 snap = vm.snapshotState();
        NutzDistributor.PushEntry[] memory entries = new NutzDistributor.PushEntry[](n);
        for (uint256 i = 0; i < n; i++) {
            entries[i] = _entry(i, 1);
        }
        gas = _measure(entries);
        vm.revertToState(snap);
    }

    /// @dev `n` entries covering five Epochs each: the per-leaf unit, cold for the first entry, warm after it.
    function _pushFiveEpochs(uint256 n) internal returns (uint256 gas) {
        uint256 snap = vm.snapshotState();
        for (uint256 k = 1; k < 5; k++) {
            _fundAndRoot(epoch + k, k + 1);
        }
        NutzDistributor.PushEntry[] memory entries = new NutzDistributor.PushEntry[](n);
        for (uint256 i = 0; i < n; i++) {
            entries[i] = _entry(i, 5);
        }
        gas = _measure(entries);
        vm.revertToState(snap);
    }

    function _measure(NutzDistributor.PushEntry[] memory entries) internal returns (uint256 gas) {
        vm.prank(keeper);
        uint256 before = gasleft();
        d.pushClaims(entries, 0.01 gwei, usdgPerEth);
        gas = before - gasleft();
        for (uint256 i = 0; i < entries.length; i++) {
            for (uint256 t = 0; t < 4; t++) {
                assertEq(tok[t].balanceOf(entries[i].account), claims[i].amounts[t] * entries[i].ids.length);
            }
        }
    }

    function _entry(uint256 index, uint256 epochs) internal view returns (NutzDistributor.PushEntry memory pe) {
        pe.account = claims[index].account;
        pe.kind = EPOCH;
        pe.ids = new uint256[](epochs);
        pe.amounts = new uint256[5][](epochs);
        pe.proofs = new bytes32[][](epochs);
        for (uint256 k = 0; k < epochs; k++) {
            pe.ids[k] = epoch + k;
            pe.amounts[k] = claims[index].amounts;
            pe.proofs[k] = proofOf(epoch + k, claims, index);
        }
    }

    // ---- funding and Roots ----

    /// @dev Deals the totals to the Converter, funds Epoch `id` through it, closes the Epoch (`k` hours after the
    ///      deploy), posts the Root and lets the Dispute window pass.
    function _fundAndRoot(uint256 id, uint256 k) internal {
        uint256[5] memory totals = totalsOf(claims);
        for (uint256 t = 0; t < 5; t++) {
            deal(address(tok[t]), address(c), tok[t].balanceOf(address(c)) + totals[t]);
            vm.prank(address(c));
            tok[t].approve(address(d), type(uint256).max);
        }
        vm.prank(address(c));
        d.notifyEpochFunding(id, totals, 0);
        vm.warp((id + 1) * 3600 + k); // the Epoch has closed
        bytes32 root = rootOf(id, claims);
        bytes32 sh =
            keccak256(abi.encode(POST_ROOT_TYPEHASH, uint8(EPOCH), id, root, keccak256(abi.encode(totals)), d.nonce()));
        d.postRoot(EPOCH, id, root, totals, _sign(KEY_A, sh), _sign(KEY_B, sh));
        vm.warp(block.timestamp + d.CLAIM_DELAY());
    }

    function _amounts(uint256 i) internal pure returns (uint256[5] memory a) {
        // 18-decimal Stock Tokens, 6-decimal USDG; distinct per Holder so no two leaves collide.
        a = [uint256(1e15) + i, 2e15 + i, 3e15 + i, 4e15 + i, 100e6 + i];
    }

    function _sign(uint256 key, bytes32 structHash) internal view returns (bytes memory) {
        bytes32 domain = keccak256(
            abi.encode(DOMAIN_TYPEHASH, keccak256("NutzDistributor"), keccak256("1"), block.chainid, address(d))
        );
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(key, keccak256(abi.encodePacked("\x19\x01", domain, structHash)));
        return abi.encodePacked(r, s, v);
    }

    function _roundUp(uint256 x) internal pure returns (uint256) {
        return (x + 4_999) / 5_000 * 5_000;
    }
}
