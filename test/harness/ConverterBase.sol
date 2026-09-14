// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {NutzDistributor} from "../../src/NutzDistributor.sol";
import {NutzConverter} from "../../src/NutzConverter.sol";
import {IPonsV2LaunchFactory} from "../../src/interfaces/pons/IPonsV2LaunchFactory.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {MockWETH} from "../mocks/MockWETH.sol";
import {MockSwapRouter02} from "../mocks/MockSwapRouter02.sol";
import {MockPoolManager} from "../mocks/MockPoolManager.sol";
import {MockPonsEscrow} from "../mocks/pons/MockPonsEscrow.sol";
import {MockPonsFactory} from "../mocks/pons/MockPonsFactory.sol";
import {MockPonsCurve} from "../mocks/pons/MockPonsCurve.sol";
import {MockPonsHook} from "../mocks/pons/MockPonsHook.sol";

/// @dev Shared fixture: the Distributor and the Converter deployed the way the script does it (the Converter's
///      address predicted from the deployer's next nonce), five mock tokens, the Venue and Pons mocks, three
///      Signer keys, a Keeper, and EIP-712 signing helpers for the Converter's actions.
abstract contract ConverterBase is Test {
    uint256 internal constant KEY_A = 0xA11CE;
    uint256 internal constant KEY_B = 0xB0B;
    uint256 internal constant KEY_C = 0xCA11;
    uint256 internal constant KEY_X = 0x5717A; // not a Signer

    address internal keeper = makeAddr("keeper");
    address internal dead = 0x000000000000000000000000000000000000dEaD;

    uint256 internal constant DEPLOY_TS = 1_800_000_000; // epoch 500000, draw 2976
    uint256 internal constant OPS_CAP = 0.5 ether;

    MockERC20[5] internal tok;
    MockWETH internal weth;
    MockSwapRouter02 internal router;
    MockPoolManager internal pm;
    MockPonsEscrow internal escrow;
    MockPonsFactory internal factory;
    MockPonsHook internal hook;

    NutzDistributor internal d;
    NutzConverter internal c;

    bytes32 internal constant DOMAIN_TYPEHASH =
        keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");
    bytes32 internal constant SET_OPS_CAP_TYPEHASH = keccak256("SetOpsCap(uint256 cap,uint256 nonce)");
    bytes32 internal constant DISABLE_LEG_TYPEHASH = keccak256("DisableLeg(uint8 stock,uint256 nonce)");
    bytes32 internal constant ENABLE_LEG_TYPEHASH = keccak256("EnableLeg(uint8 stock,uint256 nonce)");
    bytes32 internal constant CANCEL_TYPEHASH = keccak256("Cancel(bytes32 id,uint256 nonce)");

    function setUp() public virtual {
        vm.warp(DEPLOY_TS);
        string[5] memory names = ["SPY", "NVDA", "MU", "SPCX", "USDG"];
        for (uint256 i = 0; i < 5; i++) {
            tok[i] = new MockERC20(names[i], names[i]);
        }
        weth = new MockWETH();
        router = new MockSwapRouter02(address(weth));
        pm = new MockPoolManager();
        escrow = new MockPonsEscrow();
        factory = new MockPonsFactory();
        hook = new MockPonsHook(escrow);

        address[] memory excludedBase = new address[](1);
        excludedBase[0] = dead;
        address predicted = vm.computeCreateAddress(address(this), vm.getNonce(address(this)) + 1);
        d = new NutzDistributor(
            signers(), keeper, predicted, tokens(), 100_000, 40_000, 1_000e6, 10_000e6, excludedBase
        );
        c = new NutzConverter(params());
        assertEq(address(c), predicted, "Converter must land on the predicted address");
    }

    // ---- fixtures ----

    function signers() internal pure returns (address[3] memory) {
        return [vm.addr(KEY_A), vm.addr(KEY_B), vm.addr(KEY_C)];
    }

    function tokens() internal view returns (IERC20[5] memory t) {
        for (uint256 i = 0; i < 5; i++) {
            t[i] = IERC20(address(tok[i]));
        }
    }

    /// @dev The constructor arguments the fixture deploys with; tests mutate a copy to probe the checks.
    function params() internal view returns (NutzConverter.Params memory p) {
        p.signers = signers();
        p.keeper = keeper;
        p.distributor = address(d);
        p.tokens = tokens();
        p.weth = address(weth);
        p.v3Router = address(router);
        p.v4PoolManager = address(pm);
        p.ponsFactory = address(factory);
        p.ponsEscrow = address(escrow);
        p.ponsHook = address(hook);
        p.opsCap = OPS_CAP;
    }

    /// @dev Registers `token` on the factory as an ETH-quoted launch naming the Converter as creator fee recipient,
    ///      with a fresh curve mock whose creator is the Converter. Returns the curve.
    function launch(address token) internal returns (MockPonsCurve curve) {
        curve = new MockPonsCurve(escrow, address(c));
        factory.setLaunchedToken(token, launchRecord(token, address(curve)));
    }

    function launchRecord(address token, address curve)
        internal
        view
        returns (IPonsV2LaunchFactory.LaunchedToken memory L)
    {
        L.token = token;
        L.curve = curve;
        L.deployer = keeper;
        L.creatorFeeRecipient = address(c);
        L.pairToken = address(0);
        L.graduationThreshold = 4 ether;
        L.poolFee = 10_000;
        L.tickSpacing = 200;
        L.creatorTaxBps = 100;
        L.phase = 0;
        L.exists = true;
    }

    // ---- Routes and post-conditions shared by the Sweep and Acorn tests ----

    /// @dev The pool fee every single-hop v3 test path names; the mock router ignores it.
    uint24 internal constant FEE = 500;

    function path(address a, address b) internal pure returns (bytes memory) {
        return abi.encodePacked(a, FEE, b);
    }

    /// @dev A single-hop v3 Route from `a` to `b` with no slippage floor.
    function v3(address a, address b) internal view returns (NutzConverter.Route memory) {
        return NutzConverter.Route({venue: address(router), minOut: 0, data: path(a, b)});
    }

    /// @dev Valid single-hop v3 Routes for all six Sweep Legs; the NUTZ Route names WETH as a stand-in, which is
    ///      never reached on an unbound Converter (tests that bind NUTZ replace it).
    function sweepRoutes() internal view returns (NutzConverter.Route[6] memory r) {
        r[0] = v3(address(weth), address(weth));
        r[1] = v3(address(weth), address(tok[4]));
        for (uint256 i = 0; i < 4; i++) {
            r[2 + i] = v3(address(tok[4]), address(tok[i]));
        }
    }

    /// @dev The post-condition of every successful Sweep and Acorn conversion: no Reward Token left behind and no
    ///      approval to the Distributor left open.
    function assertConverterEmpty() internal view {
        for (uint256 i = 0; i < 5; i++) {
            assertEq(tok[i].balanceOf(address(c)), 0, "reward token left behind");
            assertEq(tok[i].allowance(address(c), address(d)), 0, "approval left open");
        }
    }

    // ---- the Distributor's own governance, signed under its domain ----

    bytes32 internal constant SET_DRAW_CONTRACT_TYPEHASH = keccak256("SetDrawContract(address draw,uint256 nonce)");

    function signDistributor(uint256 key, bytes32 structHash) internal view returns (bytes memory) {
        bytes32 domain = keccak256(
            abi.encode(DOMAIN_TYPEHASH, keccak256("NutzDistributor"), keccak256("1"), block.chainid, address(d))
        );
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", domain, structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(key, digest);
        return abi.encodePacked(r, s, v);
    }

    /// @dev Proposes and, 48h later, executes setting the Distributor's Draw contract, signed by A and B.
    function installDrawContract(address draw) internal {
        bytes32 sh = keccak256(abi.encode(SET_DRAW_CONTRACT_TYPEHASH, draw, d.nonce()));
        d.proposeDrawContract(draw, signDistributor(KEY_A, sh), signDistributor(KEY_B, sh));
        vm.warp(block.timestamp + 48 hours);
        d.executeDrawContract(draw);
    }

    // ---- EIP-712, built independently of the contract ----

    function domainSeparator() internal view returns (bytes32) {
        return
            keccak256(
                abi.encode(DOMAIN_TYPEHASH, keccak256("NutzConverter"), keccak256("1"), block.chainid, address(c))
            );
    }

    function sign(uint256 key, bytes32 structHash) internal view returns (bytes memory) {
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", domainSeparator(), structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(key, digest);
        return abi.encodePacked(r, s, v);
    }

    function setOpsCapHash(uint256 cap, uint256 n) internal pure returns (bytes32) {
        return keccak256(abi.encode(SET_OPS_CAP_TYPEHASH, cap, n));
    }

    function disableLegHash(uint8 stock, uint256 n) internal pure returns (bytes32) {
        return keccak256(abi.encode(DISABLE_LEG_TYPEHASH, stock, n));
    }

    function enableLegHash(uint8 stock, uint256 n) internal pure returns (bytes32) {
        return keccak256(abi.encode(ENABLE_LEG_TYPEHASH, stock, n));
    }

    /// @dev The timelock queue id of enabling `stock`, as the contract derives it.
    function enableLegId(uint8 stock) internal pure returns (bytes32) {
        return keccak256(abi.encode(ENABLE_LEG_TYPEHASH, stock));
    }

    /// @dev Sets the ops cap signed by A and B at the current nonce.
    function setOpsCap(uint256 cap) internal {
        bytes32 sh = setOpsCapHash(cap, c.nonce());
        c.setOpsCap(cap, sign(KEY_A, sh), sign(KEY_B, sh));
    }

    /// @dev Disables `stock` signed by A and B at the current nonce.
    function disableLeg(uint8 stock) internal {
        bytes32 sh = disableLegHash(stock, c.nonce());
        c.disableLeg(stock, sign(KEY_A, sh), sign(KEY_B, sh));
    }

    /// @dev Proposes enabling `stock` signed by A and B at the current nonce.
    function proposeLegEnable(uint8 stock) internal {
        bytes32 sh = enableLegHash(stock, c.nonce());
        c.proposeLegEnable(stock, sign(KEY_A, sh), sign(KEY_B, sh));
    }

    /// @dev Cancels queue entry `id` signed by A and C at the current nonce.
    function cancel(bytes32 id) internal {
        bytes32 sh = keccak256(abi.encode(CANCEL_TYPEHASH, id, c.nonce()));
        c.cancel(id, sign(KEY_A, sh), sign(KEY_C, sh));
    }
}
