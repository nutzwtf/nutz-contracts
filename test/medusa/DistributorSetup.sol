// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {vm} from "chimera/Hevm.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {CompleteMerkle} from "murky/CompleteMerkle.sol";
import {NutzDistributor} from "../../src/NutzDistributor.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {MockNutzDraw} from "../mocks/MockNutzDraw.sol";
import {MerkleTrees} from "../harness/MerkleTrees.sol";
import {MedusaBase} from "./MedusaBase.sol";

/// @dev The Distributor fixture of test/harness/DistributorBase.sol with the mock Draw installed, plus the ghost
///      ledgers test/invariant/DistributorHandler.sol keeps, declared here so the properties can read what the
///      target functions write. Tokens are minted to the Converter as the actions need them, not up front.
abstract contract DistributorSetup is MedusaBase, MerkleTrees {
    NutzDistributor internal d;
    MockERC20[5] internal tok;
    MockNutzDraw internal draw;
    address internal converter;
    address internal keeper;
    address internal stranger;
    address internal dead = 0x000000000000000000000000000000000000dEaD;
    uint256[3] internal keys = [KEY_A, KEY_B, KEY_C];

    NutzDistributor.Kind internal constant EPOCH = NutzDistributor.Kind.Epoch;
    NutzDistributor.Kind internal constant DRAW = NutzDistributor.Kind.Draw;
    uint256 internal constant USDG = 4;
    uint256 internal constant DEPLOY_TS = 1_800_000_000; // epoch 500000, draw 2976
    uint256 internal constant MIN_RATE = 1_000e6;
    uint256 internal constant MAX_RATE = 10_000e6;

    bytes32 internal constant POST_ROOT_TYPEHASH =
        keccak256("PostRoot(uint8 kind,uint256 id,bytes32 root,uint256[5] totals,uint256 nonce)");
    bytes32 internal constant VOID_ROOT_TYPEHASH = keccak256("VoidRoot(uint8 kind,uint256 id,uint256 nonce)");
    bytes32 internal constant SET_DRAW_CONTRACT_TYPEHASH = keccak256("SetDrawContract(address draw,uint256 nonce)");

    // ---- ghosts ----
    uint256[5] internal ghostFunded; // every token that entered through funding (incl. acorn USDG)
    uint256[5] internal ghostClaimed; // every amount marked claimed (paid, pushed or stuck)
    uint256[5] internal ghostStuckOutstanding; // stuck recorded minus stuck collected
    uint256 internal ghostAcornPulled; // USDG that left through pullAcorn
    uint256 internal ghostVoids;
    uint256 internal ghostSkips;
    uint256 internal ghostCapRejections; // claims against an over-allocated Root that hit CapExceeded
    uint256 internal ghostAttacksRejected; // attack actions that reverted as expected

    // who the Distributor paid (observed) versus who the model says it may pay (allowed); stuck is the gap
    mapping(address => uint256[5]) internal ghostOut;
    mapping(address => uint256[5]) internal ghostAllowed;
    address[] internal recipients;
    mapping(address => bool) internal recipientSeen;

    // per-period bookkeeping so claims can be replayed against posted trees
    address[] internal actors;
    address[] internal watched; // every address a payout may reach: actors, the stranger, the Keeper, the Converter
    mapping(uint256 id => Claim[]) internal epochTree;
    mapping(uint256 id => Claim[]) internal drawTree;
    mapping(uint256 id => bool) internal epochOverAllocated; // leaves sum to more than the posted totals
    mapping(uint256 id => bool) internal drawOverAllocated;
    uint256[] internal fundedEpochs;
    uint256[] internal fundedDraws;
    mapping(uint256 id => bool) internal epochSeen;
    mapping(uint256 id => bool) internal drawSeen;
    uint256[] internal rootedEpochs; // every id that ever received a Root (voided ones keep totals == 0)
    uint256[] internal rootedDraws;
    mapping(uint256 id => bool) internal epochRooted;
    mapping(uint256 id => bool) internal drawRooted;

    struct Flag {
        NutzDistributor.Kind kind;
        uint256 id;
        address account;
    }
    Flag[] internal claimedFlags;

    function setup() internal virtual override {
        vm.warp(DEPLOY_TS);
        merkle = new CompleteMerkle();
        keeper = _addr("keeper");
        converter = _addr("converter");
        stranger = _addr("stranger");
        string[5] memory names = ["SPY", "NVDA", "MU", "SPCX", "USDG"];
        IERC20[5] memory tokens;
        for (uint256 i = 0; i < 5; i++) {
            tok[i] = new MockERC20(names[i], names[i]);
            tokens[i] = IERC20(address(tok[i]));
        }
        address[] memory excludedBase = new address[](1);
        excludedBase[0] = dead;
        d = new NutzDistributor(
            [vm.addr(KEY_A), vm.addr(KEY_B), vm.addr(KEY_C)],
            keeper,
            converter,
            tokens,
            100_000, // PUSH_GAS_BASE
            40_000, // PUSH_GAS_PER_LEAF
            MIN_RATE,
            MAX_RATE,
            excludedBase
        );
        for (uint256 i = 0; i < 5; i++) {
            vm.prank(converter);
            tok[i].approve(address(d), type(uint256).max);
        }
        // The keeper's first sweep funds the deploy epoch one hour after deploy, when it has just closed.
        vm.warp(DEPLOY_TS + 3600);

        draw = new MockNutzDraw();
        bytes32 sh = keccak256(abi.encode(SET_DRAW_CONTRACT_TYPEHASH, address(draw), d.nonce()));
        d.proposeDrawContract(address(draw), _signD(KEY_A, sh), _signD(KEY_B, sh));
        vm.warp(block.timestamp + 48 hours);
        d.executeDrawContract(address(draw));

        string[4] memory holders = ["holder-0", "holder-1", "holder-2", "holder-3"];
        for (uint256 i = 0; i < 4; i++) {
            address a = _addr(holders[i]);
            actors.push(a);
            watched.push(a);
        }
        watched.push(stranger);
        watched.push(keeper);
        watched.push(converter);
    }

    function _signD(uint256 key, bytes32 structHash) internal returns (bytes memory) {
        return _sign712(key, "NutzDistributor", address(d), structHash);
    }
}
