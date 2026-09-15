// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Deploy} from "../../script/Deploy.s.sol";
import {NutzDistributor} from "../../src/NutzDistributor.sol";
import {NutzConverter} from "../../src/NutzConverter.sol";
import {NutzDraw} from "../../src/NutzDraw.sol";

/// @dev The Acorn Draw on Robinhood Chain's state (draw spec §9 fork): the three contracts come from the deploy
///      script, the Draw's constructor self-test included; the Signers wire the Draw into the Distributor through
///      the 48-hour timelock; the Keeper requests the Acorn Draw of the week that ended last Thursday; the round's real
///      quicknet signature, fetched from api.drand.sh when this test was written and hard-coded below, fulfils it;
///      the Seed equals the `randomness` drand published; and `pullAcorn` releases the real USDG only once that
///      Seed exists. The EIP-2537 calls run in Foundry's prague EVM here, as in the unit tests: a fork replays the
///      chain's state, not its node. The chain's own precompiles are exercised by the constructor self-test the day
///      the script broadcasts (engineering-spec §10).
///
///      Clock: the fork state is pinned at `FORK_BLOCK`, whose timestamp is `FORK_TS` (2026-09-14 00:47:25 UTC,
///      Unix week 2958). The committed round is `roundAt(FORK_TS + LEAD)`, so the request is made at exactly
///      `FORK_TS` whatever block the state comes from (`FORK_BLOCK_4663` changes the state, never the clock).
///      Deploy and wiring happen a week earlier, in week 2957, because the Distributor closes every week before the
///      one it is deployed in (`rootedThrough = currentDraw() - 1`): the first Acorn Draw a Distributor can pay is the
///      week it was deployed in, drawn on the following Sunday as `currentDraw() - 1`.
///         Skipped unless `RPC_4663` is set (the Chainstack archive URL in .env). `FORK_BLOCK_4663` overrides the
///         pinned block; `FORK_BLOCK_4663=0` forks the latest block, which a non-archive endpoint needs.
contract DrawForkTest is Test {
    uint256 internal constant FORK_BLOCK = 62_393_542;
    uint256 internal constant FORK_TS = 1_789_346_845;

    /// @dev quicknet round `(FORK_TS + 10 minutes - GENESIS) / 3 + 1`, its signature and `randomness` as published
    ///      at api.drand.sh/52db9ba70e0cc0f6eaf7803dd07447a1f5477735fd3f661792ba94600c84e971/public/32181360.
    uint64 internal constant ROUND = 32_181_360;
    bytes internal constant SIGNATURE =
        hex"882db8599d2694ef6e206202ff84e2a84369d7be6f801e27192e0ead069d6eabf75ddef9a33e3999da66d39904b862ca";
    bytes32 internal constant RANDOMNESS = 0x20d1bcb7b5037346c305e92077deb212053692108f87a451a12a730cfa5b305f;

    /// @dev quicknet's round-1000 signature: a valid G1 point that is not the signature of `ROUND`.
    bytes internal constant OTHER_ROUND_SIGNATURE =
        hex"b44679b9a59af2ec876b1a6b1ad52ea9b1615fc3982b19576350f93447cb1125e342b73a8dd2bacbe47e4b6b63ed5e39";

    uint256 internal constant ACORN_USDG = 1_000e6; // USDG has 6 decimals

    uint256 internal constant KEY_A = 0xA11CE;
    uint256 internal constant KEY_B = 0xB0B;
    uint256 internal constant KEY_C = 0xCA11;
    bytes32 internal constant DOMAIN_TYPEHASH =
        keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");
    bytes32 internal constant SET_DRAW_CONTRACT_TYPEHASH = keccak256("SetDrawContract(address draw,uint256 nonce)");

    address internal keeper = makeAddr("keeper");
    address internal stranger = makeAddr("stranger");
    NutzDistributor internal d;
    NutzConverter internal c;
    NutzDraw internal draw;
    IERC20 internal usdg;
    uint256 internal drawId; // the week the contracts were deployed in

    function setUp() public {
        string memory url = vm.envOr("RPC_4663", string(""));
        if (bytes(url).length == 0) vm.skip(true);
        uint256 blockNumber = vm.envOr("FORK_BLOCK_4663", FORK_BLOCK);
        if (blockNumber == 0) vm.createSelectFork(url);
        else vm.createSelectFork(url, blockNumber);

        // launch week: deploy, wire the Draw behind the timelock, and let one Sweep fund the Acorn pool
        vm.warp(FORK_TS - 7 days);
        Deploy script = new Deploy();
        Deploy.Params memory p = script.load(string.concat(vm.projectRoot(), "/script/config/robinhood.json"));
        p.signers = [vm.addr(KEY_A), vm.addr(KEY_B), vm.addr(KEY_C)];
        p.keeper = keeper;
        usdg = p.tokens[4];
        (d, c, draw) = script.deploy(p, address(script));
        drawId = d.currentDraw();
        _installDrawContract();
        _fundAcornPool();

        // the next week (the pinned block is its Monday): the Acorn Draw of `drawId` is requested as `currentDraw() - 1`
        vm.warp(FORK_TS);
        assertEq(d.currentDraw() - 1, drawId, "the launch week is the one drawn next Sunday");
    }

    function test_deploy_wiresTheDrawBehindTheTimelock() public view {
        assertEq(address(draw.DISTRIBUTOR()), address(d), "the Draw names the Distributor");
        assertEq(address(d.drawContract()), address(draw), "the Distributor names the Draw");
        assertEq(d.acornPoolUsdg(), ACORN_USDG, "the Acorn pool waits for the draw");
    }

    function test_draw_requestFulfilAndPullAcorn_endToEnd() public {
        vm.prank(keeper);
        draw.requestDraw(drawId, keccak256("tickets"), 42);
        (,, uint64 round, bytes32 seed) = draw.draws(drawId);
        assertEq(round, ROUND, "the committed round is the one whose signature is recorded below");
        assertEq(seed, 0);

        // the pool stays put until the Seed exists
        vm.prank(address(c));
        vm.expectRevert(abi.encodeWithSelector(NutzDistributor.DrawNotFulfilled.selector, drawId));
        d.pullAcorn(drawId);

        vm.warp(FORK_TS + draw.LEAD());
        vm.prank(stranger);
        vm.expectEmit(address(draw));
        emit NutzDraw.DrawFulfilled(drawId, ROUND, RANDOMNESS, stranger);
        draw.fulfill(drawId, SIGNATURE);
        assertEq(draw.seedOf(drawId), RANDOMNESS, "the Seed is the randomness drand published for the round");

        uint256 before = usdg.balanceOf(address(c));
        vm.prank(address(c));
        d.pullAcorn(drawId);
        assertEq(usdg.balanceOf(address(c)) - before, ACORN_USDG, "the whole pool reached the Converter");
        assertEq(d.acornPoolUsdg(), 0, "the pool is empty");
        assertTrue(d.drawConverted(drawId), "the draw is marked converted");
    }

    function test_fulfill_rejectsAnotherRoundsSignature() public {
        vm.prank(keeper);
        draw.requestDraw(drawId, keccak256("tickets"), 42);
        vm.warp(FORK_TS + draw.LEAD());
        vm.prank(stranger);
        vm.expectRevert(NutzDraw.InvalidSignature.selector);
        draw.fulfill(drawId, OTHER_ROUND_SIGNATURE);
        assertEq(draw.seedOf(drawId), 0);
    }

    // ---- fixtures ----

    /// @dev Engineering-spec §10: the Signers propose the Draw on deploy day and anyone executes it 48 hours later.
    function _installDrawContract() internal {
        bytes32 sh = keccak256(abi.encode(SET_DRAW_CONTRACT_TYPEHASH, address(draw), d.nonce()));
        d.proposeDrawContract(address(draw), _sign(KEY_A, sh), _sign(KEY_B, sh));
        vm.warp(block.timestamp + d.TIMELOCK());
        d.executeDrawContract(address(draw));
    }

    /// @dev One Sweep's Acorn Slice, as the Converter reports it: USDG dealt to the Converter and pushed into the
    ///      Distributor for the current Epoch with an empty Reward Token row.
    function _fundAcornPool() internal {
        deal(address(usdg), address(c), ACORN_USDG);
        uint256[5] memory zero5;
        vm.startPrank(address(c));
        usdg.approve(address(d), ACORN_USDG);
        d.notifyEpochFunding(d.currentEpoch(), zero5, ACORN_USDG);
        vm.stopPrank();
    }

    function _sign(uint256 key, bytes32 structHash) internal view returns (bytes memory) {
        bytes32 domain = keccak256(
            abi.encode(DOMAIN_TYPEHASH, keccak256("NutzDistributor"), keccak256("1"), block.chainid, address(d))
        );
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(key, keccak256(abi.encodePacked("\x19\x01", domain, structHash)));
        return abi.encodePacked(r, s, v);
    }
}
