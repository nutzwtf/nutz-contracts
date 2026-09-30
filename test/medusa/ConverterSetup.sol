// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {vm} from "chimera/Hevm.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolId} from "v4-core/types/PoolId.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {NutzConverter} from "../../src/NutzConverter.sol";
import {NutzDistributor} from "../../src/NutzDistributor.sol";
import {IPonsV2LaunchFactory} from "../../src/interfaces/pons/IPonsV2LaunchFactory.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {MockWETH} from "../mocks/MockWETH.sol";
import {MockSwapRouter02} from "../mocks/MockSwapRouter02.sol";
import {MockPoolManager} from "../mocks/MockPoolManager.sol";
import {MockNutzDraw} from "../mocks/MockNutzDraw.sol";
import {MockPonsEscrow} from "../mocks/pons/MockPonsEscrow.sol";
import {MockPonsFactory} from "../mocks/pons/MockPonsFactory.sol";
import {MockPonsCurve} from "../mocks/pons/MockPonsCurve.sol";
import {MockPonsHook} from "../mocks/pons/MockPonsHook.sol";
import {MedusaBase, vmNonce} from "./MedusaBase.sol";

/// @dev The Converter fixture of test/harness/ConverterBase.sol (the Distributor and the Converter deployed the
///      way the script does it, the Converter's address predicted from this contract's next nonce) with the mock
///      Draw installed and the Venue inventories, the NUTZ launch and the opening rates that
///      test/invariant/ConverterHandler.sol sets up; plus its ghosts and the records of the last Sweep and the
///      last Acorn conversion, measured from state (docs/setup/tools.md says what that leaves out).
abstract contract ConverterSetup is MedusaBase {
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
    address internal stranger;
    address internal dead = 0x000000000000000000000000000000000000dEaD;
    uint256[3] internal keys = [KEY_A, KEY_B, KEY_C];

    NutzDistributor.Kind internal constant EPOCH = NutzDistributor.Kind.Epoch;
    NutzDistributor.Kind internal constant DRAW = NutzDistributor.Kind.Draw;
    address internal constant ETH = address(0);
    uint24 internal constant FEE = 500;
    uint256 internal constant INVENTORY = 1e33; // more than any run can draw from a Venue
    uint256 internal constant DEPLOY_TS = 1_800_000_000; // epoch 500000, draw 2976
    uint256 internal constant OPS_CAP = 0.5 ether;

    bytes32 internal constant SET_OPS_CAP_TYPEHASH = keccak256("SetOpsCap(uint256 cap,uint256 nonce)");
    bytes32 internal constant DISABLE_LEG_TYPEHASH = keccak256("DisableLeg(uint8 stock,uint256 nonce)");
    bytes32 internal constant ENABLE_LEG_TYPEHASH = keccak256("EnableLeg(uint8 stock,uint256 nonce)");
    bytes32 internal constant CANCEL_TYPEHASH = keccak256("Cancel(bytes32 id,uint256 nonce)");
    bytes32 internal constant SET_KEEPER_TYPEHASH = keccak256("SetKeeper(address keeper,uint256 nonce)");
    bytes32 internal constant SET_DRAW_CONTRACT_TYPEHASH = keccak256("SetDrawContract(address draw,uint256 nonce)");

    // ---- the NUTZ launch, registered at setup and bound by an action ----
    MockERC20 internal nutzToken;
    MockPonsCurve internal curve;
    IPonsV2LaunchFactory.LaunchedToken internal launch;
    uint24 internal constant NUTZ_POOL_FEE = 10_000;
    int24 internal constant NUTZ_TICK_SPACING = 200;

    // ---- what one call did, measured from the state around it ----

    struct SweepRecord {
        uint256 count; // Sweeps so far; zero means no record yet
        // ETH the Converter had to sweep: its balance before the call, plus what the Fee pull brought in (the
        // ETH the escrow, the curve and the hook lost to it), plus what the NUTZ sale paid (the mocks pay
        // `amountIn * rate / 1e18`, so the sale of everything held is sized from the rate of the Venue routed).
        uint256 balanceBefore;
        uint256 balanceAfter;
        uint256 claimed;
        uint256 saleOut;
        uint256 ethIn; // B, as balanceBefore - balanceAfter
        uint256 opsAmt; // what the Keeper gained
        uint256 opsCap; // at the time of the Sweep
        uint256 keeperAfter;
        uint256[5] fundedDelta; // the Epoch ledger's change
        uint256 acornPoolDelta;
        uint256 distributorUsdgBefore;
        uint256 distributorUsdgAfter;
    }

    struct AcornRecord {
        uint256 count; // conversions so far; zero means no record yet
        uint256 usdgIn; // the pool's drop
        uint256[5] fundedDelta; // the Acorn Draw ledger's change
        uint256 distributorUsdgBefore;
        uint256 distributorUsdgAfter;
    }

    SweepRecord internal sweepRecord;
    AcornRecord internal acornRecord;

    // ---- ghosts ----
    // ETH put into the system by the fixture and the actions (Venue inventories, direct sends, escrow credits,
    // curve and hook accruals, the Keeper's wallet): what the eight addresses ETH may sit at must add up to.
    uint256 internal ghostEthDealt;
    uint256 internal ghostDisabledLegSwaps; // stock token movements while its Leg was disabled
    // Sweeps that found no ETH and no escrow credit and lived on the Fee pull and the NUTZ sale alone. A coverage
    // counter, not a property's input: it shows the path is driven.
    uint256 internal ghostFeeOnlySweeps;
    bool[4] internal ghostDisabled; // the Circuit breaker as `disable` and `executeEnable` left it
    uint256 internal ghostStrangerMoves; // calls by a non-Keeper that did not revert

    uint256[] internal fundedEpochs;
    uint256[] internal fundedDraws;
    mapping(uint256 id => bool) internal epochSeen;
    mapping(uint256 id => bool) internal drawSeen;

    function setup() internal virtual override {
        vm.warp(DEPLOY_TS);
        keeper = _addr("keeper");
        stranger = _addr("stranger");
        string[5] memory names = ["SPY", "NVDA", "MU", "SPCX", "USDG"];
        IERC20[5] memory tokens;
        for (uint256 i = 0; i < 5; i++) {
            tok[i] = new MockERC20(names[i], names[i]);
            tokens[i] = IERC20(address(tok[i]));
        }
        weth = new MockWETH();
        router = new MockSwapRouter02(address(weth));
        pm = new MockPoolManager();
        escrow = new MockPonsEscrow();
        factory = new MockPonsFactory();
        hook = new MockPonsHook(escrow);

        address[] memory excludedBase = new address[](1);
        excludedBase[0] = dead;
        address predicted = _createAddress(address(this), vmNonce.getNonce(address(this)) + 1);
        d = new NutzDistributor(
            [vm.addr(KEY_A), vm.addr(KEY_B), vm.addr(KEY_C)],
            keeper,
            predicted,
            tokens,
            100_000,
            40_000,
            1_000e6,
            10_000e6,
            excludedBase
        );
        NutzConverter.Params memory p;
        p.signers = [vm.addr(KEY_A), vm.addr(KEY_B), vm.addr(KEY_C)];
        p.keeper = keeper;
        p.distributor = address(d);
        p.tokens = tokens;
        p.weth = address(weth);
        p.v3Router = address(router);
        p.v4PoolManager = address(pm);
        p.ponsFactory = address(factory);
        p.ponsEscrow = address(escrow);
        p.ponsHook = address(hook);
        p.opsCap = OPS_CAP;
        c = new NutzConverter(p);
        require(address(c) == predicted, "Converter must land on the predicted address");

        draw = new MockNutzDraw();
        bytes32 sh = keccak256(abi.encode(SET_DRAW_CONTRACT_TYPEHASH, address(draw), d.nonce()));
        d.proposeDrawContract(address(draw), _signD(KEY_A, sh), _signD(KEY_B, sh));
        vm.warp(block.timestamp + 48 hours);
        d.executeDrawContract(address(draw));

        // Venue inventories: every Reward Token, ETH for v4 output, and WETH for v3 ETH output. The WETH is
        // deposited by this contract and handed over: under Medusa a prank changes `msg.sender` but the value
        // still comes from the caller's balance, so `prank(router); deposit{value}` cannot work there.
        for (uint256 i = 0; i < 5; i++) {
            tok[i].mint(address(router), INVENTORY);
            tok[i].mint(address(pm), INVENTORY);
        }
        vm.deal(address(pm), INVENTORY);
        vm.deal(address(this), INVENTORY);
        ghostEthDealt = 2 * INVENTORY;
        weth.deposit{value: INVENTORY}();
        weth.transfer(address(router), INVENTORY);

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

    // ------------------------------------------------------------- signing

    function _signC(uint256 key, bytes32 structHash) internal returns (bytes memory) {
        return _sign712(key, "NutzConverter", address(c), structHash);
    }

    function _signD(uint256 key, bytes32 structHash) internal returns (bytes memory) {
        return _sign712(key, "NutzDistributor", address(d), structHash);
    }

    // ------------------------------------------------------------- routes

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

    /// @dev The Pons pool id of the NUTZ launch, as the hook keys its pending fees.
    function _nutzPoolId() internal view returns (bytes32) {
        return PoolId.unwrap(_key(0).toId());
    }

    // ------------------------------------------------------------- views the properties share

    /// @dev The ETH held by the three contracts a Leg can pay ETH to or draw it from.
    function _venueEth() internal view returns (uint256) {
        return address(router).balance + address(pm).balance + address(weth).balance;
    }

    /// @dev The ETH the Fee pull can hand the Converter: the escrow's, the curve's and the hook's balances.
    function _feeSourceEth() internal view returns (uint256) {
        return address(escrow).balance + address(curve).balance + address(hook).balance;
    }

    /// @dev Everywhere ETH may sit in this system: the Converter, the fee sources, the Venues and the Keeper.
    function _systemEth() internal view returns (uint256) {
        return address(c).balance + _feeSourceEth() + _venueEth() + keeper.balance;
    }
}
