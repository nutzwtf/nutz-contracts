// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {NutzDistributor} from "../../src/NutzDistributor.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {CompleteMerkle} from "murky/CompleteMerkle.sol";
import {MerkleTrees} from "./MerkleTrees.sol";

/// @dev Shared fixture: a deployed Distributor, five mock tokens, a funded Converter, EIP-712 signing helpers.
abstract contract DistributorBase is Test, MerkleTrees {
    uint256 internal constant KEY_A = 0xA11CE;
    uint256 internal constant KEY_B = 0xB0B;
    uint256 internal constant KEY_C = 0xCA11;

    address internal keeper = makeAddr("keeper");
    address internal converter = makeAddr("converter");
    address internal dead = 0x000000000000000000000000000000000000dEaD;

    MockERC20[5] internal tok;
    NutzDistributor internal d;

    uint256 internal constant DEPLOY_TS = 1_800_000_000; // epoch 500000, draw 2976
    uint256 internal constant DEPLOY_EPOCH = 500_000;

    NutzDistributor.Kind internal constant EPOCH = NutzDistributor.Kind.Epoch;
    NutzDistributor.Kind internal constant DRAW = NutzDistributor.Kind.Draw;

    bytes32 internal constant DOMAIN_TYPEHASH =
        keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");
    bytes32 internal constant POST_ROOT_TYPEHASH =
        keccak256("PostRoot(uint8 kind,uint256 id,bytes32 root,uint256[5] totals,uint256 nonce)");
    bytes32 internal constant VOID_ROOT_TYPEHASH = keccak256("VoidRoot(uint8 kind,uint256 id,uint256 nonce)");
    bytes32 internal constant SET_RATE_RANGE_TYPEHASH =
        keccak256("SetRateRange(uint256 min,uint256 max,uint256 nonce)");
    bytes32 internal constant SET_DRAW_CONTRACT_TYPEHASH = keccak256("SetDrawContract(address draw,uint256 nonce)");
    bytes32 internal constant APPEND_EXCLUDED_TYPEHASH = keccak256("AppendExcluded(address account,uint256 nonce)");

    uint256 internal constant DEPLOY_DRAW = 2_976;

    function setUp() public virtual {
        vm.warp(DEPLOY_TS);
        merkle = new CompleteMerkle();
        string[5] memory names = ["SPY", "NVDA", "MU", "SPCX", "USDG"];
        for (uint256 i = 0; i < 5; i++) {
            tok[i] = new MockERC20(names[i], names[i]);
        }
        address[] memory excludedBase = new address[](1);
        excludedBase[0] = dead;
        d = new NutzDistributor(
            [vm.addr(KEY_A), vm.addr(KEY_B), vm.addr(KEY_C)],
            keeper,
            converter,
            tokens(),
            100_000, // PUSH_GAS_BASE
            40_000, // PUSH_GAS_PER_LEAF
            1_000e6, // min raw USDG (6 decimals) per ETH
            10_000e6, // max raw USDG (6 decimals) per ETH
            excludedBase
        );
        for (uint256 i = 0; i < 5; i++) {
            tok[i].mint(converter, 1_000_000e18);
            vm.prank(converter);
            tok[i].approve(address(d), type(uint256).max);
        }
        // The keeper's first sweep funds the deploy epoch one hour after deploy, when it has just closed.
        vm.warp(DEPLOY_TS + 3600);
    }

    // ---- fixtures ----

    function tokens() internal view returns (IERC20[5] memory t) {
        for (uint256 i = 0; i < 5; i++) {
            t[i] = IERC20(address(tok[i]));
        }
    }

    function amounts(uint256 a, uint256 b, uint256 c, uint256 e, uint256 u) internal pure returns (uint256[5] memory) {
        return [a, b, c, e, u];
    }

    function zero5() internal pure returns (uint256[5] memory z) {}

    function fund(uint256 epochId, uint256[5] memory a, uint256 acorn) internal {
        vm.prank(converter);
        d.notifyEpochFunding(epochId, a, acorn);
    }

    /// @dev Advances time so that `epochId` has just closed.
    function closeEpoch(uint256 epochId) internal {
        vm.warp((epochId + 1) * 3600);
    }

    /// @dev Funds `epochId` with exactly the totals, posts the Root, and closes the Dispute window.
    function fundPostFinalize(uint256 epochId, Claim[] memory claims) internal returns (bytes32 root) {
        fund(epochId, totalsOf(claims), 0);
        root = rootOf(epochId, claims);
        postRoot(EPOCH, epochId, root, totalsOf(claims));
        vm.warp(block.timestamp + 30 minutes);
    }

    // ---- EIP-712, built independently of the contract ----

    function domainSeparator() internal view returns (bytes32) {
        return
            keccak256(
                abi.encode(DOMAIN_TYPEHASH, keccak256("NutzDistributor"), keccak256("1"), block.chainid, address(d))
            );
    }

    function sign(uint256 key, bytes32 structHash) internal view returns (bytes memory) {
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", domainSeparator(), structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(key, digest);
        return abi.encodePacked(r, s, v);
    }

    function postRootHash(NutzDistributor.Kind kind, uint256 id, bytes32 root, uint256[5] memory totals, uint256 n)
        internal
        pure
        returns (bytes32)
    {
        return keccak256(abi.encode(POST_ROOT_TYPEHASH, uint8(kind), id, root, keccak256(abi.encode(totals)), n));
    }

    function voidRootHash(NutzDistributor.Kind kind, uint256 id, uint256 n) internal pure returns (bytes32) {
        return keccak256(abi.encode(VOID_ROOT_TYPEHASH, uint8(kind), id, n));
    }

    /// @dev Voids a Root signed by A and C at the current nonce.
    function voidRoot(NutzDistributor.Kind kind, uint256 id) internal {
        bytes32 sh = voidRootHash(kind, id, d.nonce());
        d.voidRoot(kind, id, sign(KEY_A, sh), sign(KEY_C, sh));
    }

    /// @dev Proposes and, 48h later, executes setting the Draw contract.
    function installDrawContract(address draw) internal {
        bytes32 sh = keccak256(abi.encode(SET_DRAW_CONTRACT_TYPEHASH, draw, d.nonce()));
        d.proposeDrawContract(draw, sign(KEY_A, sh), sign(KEY_B, sh));
        vm.warp(block.timestamp + 48 hours);
        d.executeDrawContract(draw);
    }

    /// @dev Advances time so that draw `drawId` has just closed.
    function closeDraw(uint256 drawId) internal {
        vm.warp((drawId + 1) * 604_800);
    }

    /// @dev One Push entry for `account` covering `ids` of `kind` with identical amounts per leaf.
    function entryFor(
        address account,
        NutzDistributor.Kind kind,
        uint256[] memory ids,
        uint256[5] memory a,
        Claim[] memory claims,
        uint256 index
    ) internal view returns (NutzDistributor.PushEntry memory pe) {
        pe.account = account;
        pe.kind = kind;
        pe.ids = ids;
        pe.amounts = new uint256[5][](ids.length);
        pe.proofs = new bytes32[][](ids.length);
        for (uint256 k = 0; k < ids.length; k++) {
            pe.amounts[k] = a;
            pe.proofs[k] = proofOf(ids[k], claims, index);
        }
    }

    /// @dev Posts a Root signed by A and B at the current nonce.
    function postRoot(NutzDistributor.Kind kind, uint256 id, bytes32 root, uint256[5] memory totals) internal {
        bytes32 sh = postRootHash(kind, id, root, totals, d.nonce());
        d.postRoot(kind, id, root, totals, sign(KEY_A, sh), sign(KEY_B, sh));
    }
}
