// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "v4-core/interfaces/callback/IUnlockCallback.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {BalanceDelta} from "v4-core/types/BalanceDelta.sol";
import {Signers} from "./Signers.sol";
import {INutzDistributor} from "./interfaces/INutzDistributor.sol";
import {ISwapRouter02} from "./interfaces/ISwapRouter02.sol";
import {IWETH9} from "./interfaces/IWETH9.sol";
import {IPonsV2LaunchFactory} from "./interfaces/pons/IPonsV2LaunchFactory.sol";
import {IPonsV2BondingCurve} from "./interfaces/pons/IPonsV2BondingCurve.sol";
import {IPonsV2FeeEscrow} from "./interfaces/pons/IPonsV2FeeEscrow.sol";
import {IPonsV2MemeHook} from "./interfaces/pons/IPonsV2MemeHook.sol";

/// @title NutzConverter
/// @notice The address Pons pays creator fees to. Once an hour it pulls what accrued, takes the Ops Slice in ETH,
///         converts the rest to USDG and Stock Tokens and funds the Distributor for one Epoch; once a week it
///         converts the Acorn pool. It never holds Reward Tokens between calls, has no owner, no withdraw, no pause,
///         no upgrade, and no way to change the Pons fee recipient. It cannot be replaced (ADR-0003): the
///         Distributor's CONVERTER is immutable, so everything that must change over the token's life is a
///         Signer-governed setter and everything else is a constant or immutable.
// ETH leaves through `sweep`: Ops to the Keeper with a plain `call{value}` and the rest as `msg.value` to a Venue,
// neither of which Aderyn's detector recognises as a withdrawal.
// aderyn-fp-next-line(contract-locks-ether)
contract NutzConverter is Signers, ReentrancyGuard, IUnlockCallback {
    using SafeERC20 for IERC20;

    // ------------------------------------------------------------------ types

    /// @notice One swap inside a Sweep, each with a fixed input and output token: NUTZ -> ETH, ETH -> USDG, and
    ///         USDG -> each Stock Token (`Spy..Spcx` map to `tokens(0..3)`).
    enum Leg {
        NutzToEth,
        EthToUsdg,
        Spy,
        Nvda,
        Mu,
        Spcx
    }

    /// @notice The Keeper's instructions for one Leg: which Venue, the slippage floor, and the Venue-specific
    ///         path (v3: the `exactInput` path bytes; v4: `abi.encode(PoolKey)`). The contract trusts nothing in
    ///         it beyond what it verifies.
    struct Route {
        address venue;
        uint256 minOut;
        bytes data;
    }

    /// @dev What `_runV4` hands the pool manager for `unlockCallback`: one exact-input swap over `key`.
    struct SwapOrder {
        PoolKey key;
        bool zeroForOne;
        uint256 amountIn;
        uint256 minOut;
    }

    /// @notice Constructor arguments, packed because there are eleven of them.
    struct Params {
        address[3] signers;
        address keeper;
        address distributor;
        IERC20[5] tokens; // SPY, NVDA, MU, SPCX, USDG; same order as the Distributor
        address weth;
        address v3Router;
        address v4PoolManager;
        address ponsFactory;
        address ponsEscrow;
        address ponsHook;
        uint256 opsCap;
    }

    // -------------------------------------------------------------- constants

    /// @notice Blast-radius cap: one Sweep converts at most this much ETH; the rest waits for the next hour.
    uint256 public constant MAX_SWEEP_ETH = 20 ether;
    /// @notice Ceiling for `opsCap`.
    uint256 public constant MAX_OPS_CAP_WEI = 5 ether;
    uint256 public constant SPLIT_STASH_BPS = 6000;
    uint256 public constant SPLIT_CASH_BPS = 2800;
    uint256 public constant SPLIT_ACORN_BPS = 1000;
    uint256 public constant SPLIT_OPS_BPS = 200;
    /// @notice Stash + Cash + Acorn: the share of a Sweep that reaches Holders.
    uint256 public constant HOLDER_BPS = 9800;
    /// @notice Each Stock Token's share of the Stash.
    uint256 public constant PER_STOCK_BPS = 2500;
    uint256 public constant BPS = 10_000;
    /// @notice The four stock Legs, indexed like `tokens(0..3)`; USDG (index 4) has no Leg.
    uint8 public constant STOCK_LEGS = 4;
    /// @dev Pons's `GraduationPhase` values the Fee pull acts on: before graduation the curve holds the fees,
    ///      after the pool exists the hook does; `Swept` (1) and `Rescued` (3) have nothing to pull.
    uint8 private constant PHASE_NOT_GRADUATED = 0;
    uint8 private constant PHASE_POOL_CREATED = 2;
    /// @dev `Leg.Spy` is the first stock Leg: stock `i` of the Circuit breaker is `Leg(FIRST_STOCK_LEG + i)`.
    uint8 internal constant FIRST_STOCK_LEG = uint8(Leg.Spy);

    /// @dev The v4 price bounds a swap may run to, one step inside TickMath's `MIN_SQRT_PRICE` and
    ///      `MAX_SQRT_PRICE` (the manager rejects the extremes themselves), so the Route's `minOut` is the only
    ///      slippage bound. Copied rather than read from the library because Slither cannot resolve a library
    ///      constant inside a function; a test pins them to the library.
    uint160 internal constant V4_PRICE_LIMIT_DOWN = 4295128739 + 1;
    uint160 internal constant V4_PRICE_LIMIT_UP = 1461446703485210103287273052203988822378723970342 - 1;
    /// @dev A v3 path is `tokenA ‖ fee ‖ tokenB ‖ …`: 20 bytes of address, then 23 bytes (3 fee + 20 address) per hop.
    uint256 private constant V3_ADDRESS_BYTES = 20;
    uint256 private constant V3_HOP_BYTES = 23;
    /// @dev `abi.encode(PoolKey)`: five static words.
    uint256 private constant V4_KEY_BYTES = 5 * 32;

    bytes32 private constant SET_OPS_CAP_TYPEHASH = keccak256("SetOpsCap(uint256 cap,uint256 nonce)");
    bytes32 private constant DISABLE_LEG_TYPEHASH = keccak256("DisableLeg(uint8 stock,uint256 nonce)");
    bytes32 private constant ENABLE_LEG_TYPEHASH = keccak256("EnableLeg(uint8 stock,uint256 nonce)");

    // ------------------------------------------------------------- immutables

    INutzDistributor public immutable DISTRIBUTOR;
    IERC20 private immutable T0;
    IERC20 private immutable T1;
    IERC20 private immutable T2;
    IERC20 private immutable T3;
    IERC20 private immutable T4;
    /// @notice The v3 path token standing in for ETH on both ends of a Leg.
    address public immutable WETH;
    ISwapRouter02 public immutable V3_ROUTER;
    IPoolManager public immutable V4_POOL_MANAGER;
    IPonsV2LaunchFactory public immutable PONS_FACTORY;
    IPonsV2FeeEscrow public immutable PONS_ESCROW;
    IPonsV2MemeHook public immutable PONS_HOOK;

    // ---------------------------------------------------------------- storage

    /// @notice Ceiling on the Keeper's ETH balance that the Ops Slice tops up to; zero turns Ops off.
    uint256 public opsCap;
    /// @notice The NUTZ token, zero until the Keeper binds it after the Pons launch.
    address public nutz;
    /// @notice The bonding curve of the bound NUTZ launch, read from the factory at bind.
    address public curve;
    /// @notice Circuit breaker per stock Leg, indexed like `tokens(0..3)`.
    bool[STOCK_LEGS] public legDisabled;

    // ---------------------------------------------------------------- errors

    error OpsCapTooHigh(uint256 cap);
    /// @dev `block.timestamp` is past the Keeper's deadline for the call.
    error DeadlinePassed();
    /// @dev The Keeper's wallet refused the Ops Slice.
    error OpsTransferFailed();
    /// @dev The Converter holds no ETH after the Fee pull and the NUTZ sale.
    error NothingToSweep();
    /// @dev The ETH -> USDG Leg paid less than the Distributor's Signer-set minimum rate allows.
    error UsdgBelowFloor(uint256 out, uint256 floor);
    /// @dev The factory has no launch of `token` naming this Converter as creator fee recipient.
    error NotOurLaunch(address token);
    /// @dev The launch is quoted in a token other than ETH; the Converter only sweeps ETH-quoted launches.
    error NotEthQuoted(address token);
    error LegAlreadyDisabled(uint8 stock);
    error LegNotDisabled(uint8 stock);
    /// @dev Only the four stock Legs (indices 0..3) can be disabled or enabled.
    error InvalidLeg(uint8 stock);
    /// @dev The v3 router wraps ETH into a different token than `WETH`, so ETH Legs could never be routed.
    error WethMismatch(address routerWeth);
    /// @dev `Leg.NutzToEth` was asked for before the Keeper bound NUTZ.
    error NutzNotBound();
    /// @dev `Route.venue` is neither the v3 router nor the v4 pool manager.
    error BadVenue(address venue);
    /// @dev A v3 path that is malformed or does not start and end with the Leg's tokens (WETH standing in for ETH).
    error BadPath();
    /// @dev A v4 key whose currencies are not exactly the Leg's tokens, or that does not decode as a `PoolKey`.
    error BadPoolKey();
    error NotPoolManager();
    /// @dev Raised inside the v4 callback, so the whole unlock reverts and the Leg is skipped: the pool delivered
    ///      less than the Route's `minOut`.
    error InsufficientOutput(uint256 amountOut, uint256 minOut);
    /// @dev Raised inside the v4 callback: the pool absorbed less than `amountIn` (liquidity ran out), which would
    ///      leave input behind; the Leg is skipped instead.
    error PartialFill(uint256 filled, uint256 amountIn);

    // ---------------------------------------------------------------- events

    /// @notice One Sweep's outcome, the indexer's input: the ETH converted (`ethIn`, at most `MAX_SWEEP_ETH`), the
    ///         Ops Slice paid, the Reward Tokens funded for the Epoch (`amounts`, USDG at index 4 is the Cash Slice
    ///         plus the share of every skipped stock Leg) and the USDG added to the Acorn pool.
    event Swept(uint256 indexed epochId, uint256 ethIn, uint256 opsAmt, uint256[5] amounts, uint256 acornUsdg);
    /// @notice The Fee pull's outcome: whether the curve or hook sweep ran and succeeded, and what the escrow paid.
    event FeesPulled(bool curveSwept, bool hookSwept, uint256 claimed);
    /// @notice Rescued NUTZ sold for ETH at the start of a Sweep.
    event NutzSold(uint256 nutzIn, uint256 ethOut);
    /// @notice The Ops Slice paid to the Keeper this Sweep; zero when its wallet is already at `opsCap`.
    event OpsFunded(uint256 amount);
    /// @notice A Leg that ran but did not swap: `reason` is the Venue's revert data, or "disabled".
    event LegSkipped(uint8 indexed leg, bytes reason);
    /// @notice One Acorn conversion's outcome: the USDG pulled from the Distributor's Acorn pool and the Reward
    ///         Tokens funded for the Acorn Draw (`amounts`, USDG at index 4 is the quartering dust plus the share
    ///         of every skipped stock Leg).
    event AcornConverted(uint256 indexed drawId, uint256 usdgIn, uint256[5] amounts);
    event NutzBound(address indexed previous, address indexed token, address curve);
    event OpsCapSet(uint256 previous, uint256 current);
    event LegDisabled(uint8 indexed stock);
    event LegEnabled(uint8 indexed stock);

    // ------------------------------------------------------------ constructor

    constructor(Params memory p) Signers("NutzConverter", p.signers, p.keeper) {
        if (
            p.distributor == address(0) || p.weth == address(0) || p.v3Router == address(0)
                || p.v4PoolManager == address(0) || p.ponsFactory == address(0) || p.ponsEscrow == address(0)
                || p.ponsHook == address(0)
        ) revert ZeroAddress();
        for (uint256 i = 0; i < 5; i++) {
            // Five fixed legs at construction; a revert here is the intent, not a wasted iteration.
            // forge-lint: disable-next-line(require-revert-in-loop)
            if (address(p.tokens[i]) == address(0)) revert ZeroAddress();
        }
        if (p.opsCap > MAX_OPS_CAP_WEI) revert OpsCapTooHigh(p.opsCap);
        // ETH Legs go through the router as `msg.value`, which it wraps into its own WETH9; the paths name `WETH`.
        // A view (STATICCALL) on a constructor argument: nothing can re-enter a contract under construction.
        // aderyn-fp-next-line(reentrancy-state-change)
        address routerWeth = ISwapRouter02(p.v3Router).WETH9();
        if (routerWeth != p.weth) revert WethMismatch(routerWeth);
        DISTRIBUTOR = INutzDistributor(p.distributor);
        (T0, T1, T2, T3, T4) = (p.tokens[0], p.tokens[1], p.tokens[2], p.tokens[3], p.tokens[4]);
        WETH = p.weth;
        V3_ROUTER = ISwapRouter02(p.v3Router);
        V4_POOL_MANAGER = IPoolManager(p.v4PoolManager);
        PONS_FACTORY = IPonsV2LaunchFactory(p.ponsFactory);
        PONS_ESCROW = IPonsV2FeeEscrow(p.ponsEscrow);
        PONS_HOOK = IPonsV2MemeHook(p.ponsHook);
        opsCap = p.opsCap;
    }

    /// @notice Accepts ETH from anyone: the escrow pays `claim()` here, and Pons's owner-only rescue pays
    ///         the recipient directly.
    receive() external payable {}

    // ------------------------------------------------------------- governance

    /// @notice Binds the NUTZ launch the Sweep pulls fees for. Keeper-only because anyone can launch a token
    ///         naming this Converter as recipient; re-bindable because a wrong bind only pauses the curve and
    ///         hook sweeps until the next one (escrow claims are keyed by caller, not by token). The launch must
    ///         exist, name this Converter as creator fee recipient and be quoted in ETH.
    function bindNutz(address token) external onlyKeeper {
        if (token == address(0)) revert ZeroAddress();
        // A view on an immutable address (STATICCALL): nothing can re-enter before the writes below.
        // aderyn-fp-next-line(reentrancy-state-change)
        IPonsV2LaunchFactory.LaunchedToken memory launch = PONS_FACTORY.getLaunchedToken(token);
        if (!launch.exists || launch.creatorFeeRecipient != address(this)) revert NotOurLaunch(token);
        if (launch.pairToken != address(0)) revert NotEthQuoted(token);
        emit NutzBound(nutz, token, launch.curve);
        nutz = token;
        curve = launch.curve;
    }

    /// @notice Sets the ceiling the Ops Slice tops the Keeper's balance up to; zero turns Ops off.
    ///         Instant 2-of-3 over `SetOpsCap(uint256 cap,uint256 nonce)`; `cap <= MAX_OPS_CAP_WEI`.
    function setOpsCap(uint256 cap, bytes calldata sig1, bytes calldata sig2) external {
        if (cap > MAX_OPS_CAP_WEI) revert OpsCapTooHigh(cap);
        _require2of3(keccak256(abi.encode(SET_OPS_CAP_TYPEHASH, cap, nonce)), sig1, sig2);
        emit OpsCapSet(opsCap, cap);
        opsCap = cap;
    }

    /// @notice The Circuit breaker: stops swapping into stock `stock` at once; its share of the Stash is paid
    ///         as USDG until the Leg is enabled again through the timelock. Instant 2-of-3 over
    ///         `DisableLeg(uint8 stock,uint256 nonce)`.
    function disableLeg(uint8 stock, bytes calldata sig1, bytes calldata sig2) external {
        _checkLeg(stock);
        if (legDisabled[stock]) revert LegAlreadyDisabled(stock);
        _require2of3(keccak256(abi.encode(DISABLE_LEG_TYPEHASH, stock, nonce)), sig1, sig2);
        legDisabled[stock] = true;
        emit LegDisabled(stock);
    }

    /// @notice Schedules enabling stock `stock` again. 2-of-3 over `EnableLeg(uint8 stock,uint256 nonce)`;
    ///         executable by anyone after `TIMELOCK` via `executeLegEnable`.
    function proposeLegEnable(uint8 stock, bytes calldata sig1, bytes calldata sig2) external {
        _checkDisabled(stock);
        _require2of3(keccak256(abi.encode(ENABLE_LEG_TYPEHASH, stock, nonce)), sig1, sig2);
        _schedule(keccak256(abi.encode(ENABLE_LEG_TYPEHASH, stock)));
    }

    /// @notice Executes a scheduled enable once its timelock has elapsed. The Leg must still be disabled.
    function executeLegEnable(uint8 stock) external {
        _checkLeg(stock);
        _consume(keccak256(abi.encode(ENABLE_LEG_TYPEHASH, stock)));
        _checkDisabled(stock);
        legDisabled[stock] = false;
        emit LegEnabled(stock);
    }

    function _checkLeg(uint8 stock) private pure {
        if (stock >= STOCK_LEGS) revert InvalidLeg(stock);
    }

    function _checkDisabled(uint8 stock) private view {
        _checkLeg(stock);
        if (!legDisabled[stock]) revert LegNotDisabled(stock);
    }

    // ------------------------------------------------------------------ sweep

    /// @notice The hourly Sweep: pull the accrued fees, sell any rescued NUTZ, take the Ops Slice in ETH, convert
    ///         the rest to USDG and Stock Tokens and fund the Distributor for `epochId`. At most `MAX_SWEEP_ETH`
    ///         per call; the excess waits for the next hour. Every Leg but ETH -> USDG is isolated: a failure
    ///         turns its share into Cash. The Distributor decides whether `epochId` is fundable.
    /// @param epochId The Epoch to fund; the Distributor requires it open and not yet rooted.
    /// @param routes One Route per Leg in enum order: NUTZ -> ETH, ETH -> USDG, then USDG -> SPY, NVDA, MU, SPCX.
    /// @param deadline The one timestamp bound for the whole call; the v3 router has none of its own.
    // `Swept` reports the outcome of the Venue and Distributor calls, so it must follow them; the function is
    // nonReentrant and `receive` is empty, so nothing can reorder the log.
    // forge-lint: disable-next-item(reentrancy-events)
    function sweep(uint256 epochId, Route[6] calldata routes, uint256 deadline) external nonReentrant onlyKeeper {
        // A sequencer can skew block.timestamp by seconds; the Keeper's deadline is minutes out.
        // forge-lint: disable-next-line(block-timestamp)
        if (block.timestamp > deadline) revert DeadlinePassed();
        if (nutz != address(0)) {
            _pullFees();
            _sellNutz(routes[0]);
        }

        uint256 ethIn = address(this).balance;
        if (ethIn > MAX_SWEEP_ETH) ethIn = MAX_SWEEP_ETH;
        if (ethIn == 0) revert NothingToSweep();
        uint256 opsAmt = _fundOps(ethIn);
        uint256 usdgOut = _ethToUsdg(routes[1], ethIn - opsAmt);

        (uint256 perStock, uint256 cashUsdg, uint256 acornUsdg) = _slice(usdgOut);
        uint256[5] memory amounts;
        for (uint8 i = 0; i < STOCK_LEGS; i++) {
            (bool bought, uint256 stockOut) = _buyStock(i, routes[FIRST_STOCK_LEG + i], perStock);
            if (bought) amounts[i] = stockOut;
            else cashUsdg += perStock;
        }
        amounts[4] = cashUsdg;

        _fundEpoch(epochId, amounts, acornUsdg);
        emit Swept(epochId, ethIn, opsAmt, amounts, acornUsdg);
    }

    /// @dev The Fee pull: credit the escrow from the curve (before graduation) or the hook (once the pool exists)
    ///      whenever Pons lets the creator do it, then claim the escrow balance. Each Pons call is gated on the
    ///      pending-fee views and wrapped in try/catch, so a Pons-side refusal never blocks the Sweep.
    // `FeesPulled` reports what the Pons calls did; see the note on `sweep`.
    // forge-lint: disable-next-item(reentrancy-events)
    function _pullFees() private {
        IPonsV2LaunchFactory.LaunchedToken memory launch = PONS_FACTORY.getLaunchedToken(nutz);
        bool curveSwept = launch.phase == PHASE_NOT_GRADUATED && _sweepCurve();
        bool hookSwept = launch.phase == PHASE_POOL_CREATED && _sweepHook(launch);
        uint256 claimed = _claimEscrow();
        emit FeesPulled(curveSwept, hookSwept, claimed);
    }

    /// @dev The creator-side curve sweep, only when something is pending. The creator may call it whenever no
    ///      buyback quote is pending, which holds while buyback is off.
    function _sweepCurve() private returns (bool swept) {
        IPonsV2BondingCurve curve_ = IPonsV2BondingCurve(curve);
        if (curve_.quoteFeeBalance() + curve_.creatorTaxBalance() > 0) {
            try curve_.sweepFees(0) {
                swept = true;
            } catch {}
        }
    }

    /// @dev The creator-side hook sweep, only when ETH is pending and every NUTZ-denominated amount and the ETH
    ///      buyback earmark are zero (Pons's own sweep operator handles those); skipped otherwise.
    function _sweepHook(IPonsV2LaunchFactory.LaunchedToken memory launch) private returns (bool swept) {
        bytes32 poolId = keccak256(
            abi.encode(
                PoolKey({
                    currency0: Currency.wrap(address(0)),
                    currency1: Currency.wrap(nutz),
                    fee: launch.poolFee,
                    tickSpacing: launch.tickSpacing,
                    hooks: IHooks(address(PONS_HOOK))
                })
            )
        );
        if (_hookHasOnlyEthPending(poolId)) {
            try PONS_HOOK.sweepPoolFees(poolId, 0, 0) {
                swept = true;
            } catch {}
        }
    }

    /// @dev Whether the hook has ETH fees or tax to pay out and nothing the creator is not allowed to sweep:
    ///      no NUTZ fees or tax and no buyback earmark in either currency.
    function _hookHasOnlyEthPending(bytes32 poolId) private view returns (bool) {
        address eth = address(0);
        if (PONS_HOOK.pendingFees(poolId, eth) + PONS_HOOK.pendingCreatorTax(poolId, eth) == 0) return false;
        return PONS_HOOK.pendingFees(poolId, nutz) == 0 && PONS_HOOK.pendingCreatorTax(poolId, nutz) == 0
            && PONS_HOOK.pendingBuyback(poolId, eth) == 0 && PONS_HOOK.pendingBuyback(poolId, nutz) == 0;
    }

    /// @dev Claims the escrow balance, which arrives as native ETH in `receive`; a refusal waits for next hour.
    function _claimEscrow() private returns (uint256 claimed) {
        if (PONS_ESCROW.balanceOf(address(this)) > 0) {
            try PONS_ESCROW.claim() returns (uint256 amount) {
                claimed = amount;
            } catch {}
        }
    }

    /// @dev Sells whatever NUTZ the Converter holds (Pons's owner-only rescue pays it here) for ETH, isolated:
    ///      on failure the NUTZ waits for the next hour.
    // Both events report the Leg's outcome; see the note on `sweep`.
    // forge-lint: disable-next-item(reentrancy-events)
    function _sellNutz(Route calldata route) private {
        uint256 nutzIn = IERC20(nutz).balanceOf(address(this));
        if (nutzIn == 0) return;
        (bool ok, uint256 ethOut, bytes memory reason) = _runLeg(Leg.NutzToEth, route, nutzIn);
        if (ok) emit NutzSold(nutzIn, ethOut);
        else emit LegSkipped(uint8(Leg.NutzToEth), reason);
    }

    /// @dev The Ops Slice: 2% of `ethIn`, but never more than tops the Keeper's balance up to `opsCap`; the
    ///      overflow stays in the Sweep and reaches Holders pro-rata.
    // The destination is `keeper`, set only through the Signers' timelock, and the caller is the Keeper itself.
    // `OpsFunded` follows the Fee pull's external calls; see the note on `sweep`. A plain call rather than
    // OpenZeppelin's `Address.sendValue`: importing that library makes Slither 0.11 unable to lower
    // `unlockCallback`, which would silently drop it from every detector.
    // forge-lint: disable-next-item(arbitrary-send-eth, reentrancy-events, low-level-calls)
    // slither-disable-next-line arbitrary-send-eth
    function _fundOps(uint256 ethIn) private returns (uint256 opsAmt) {
        uint256 keeperBalance = keeper.balance;
        uint256 headroom = opsCap > keeperBalance ? opsCap - keeperBalance : 0;
        opsAmt = ethIn * SPLIT_OPS_BPS / BPS;
        if (opsAmt > headroom) opsAmt = headroom;
        if (opsAmt > 0) {
            (bool sent,) = payable(keeper).call{value: opsAmt}("");
            if (!sent) revert OpsTransferFailed();
        }
        emit OpsFunded(opsAmt);
    }

    /// @dev The one Leg that is not isolated: a Venue failure reverts the Sweep, and so does an output under the
    ///      floor the Distributor's Signer-set minimum rate implies. That range bounds a compromised Keeper's
    ///      slippage on the 98% of the Sweep that reaches Holders; the Converter reads it, never stores it.
    function _ethToUsdg(Route calldata route, uint256 ethIn) private returns (uint256 usdgOut) {
        usdgOut = _runLegStrict(Leg.EthToUsdg, route, ethIn);
        uint256 floor = ethIn * DISTRIBUTOR.minUsdgPerEth() / 1e18;
        if (usdgOut < floor) revert UsdgBelowFloor(usdgOut, floor);
    }

    /// @dev Cuts one Sweep's USDG into the Holder Slices in the spec's exact order of rounding: Stash and Cash
    ///      by their share of the Holder total, Acorn the remainder; then the Stash into four equal stock shares,
    ///      whose rounding dust joins Cash.
    function _slice(uint256 usdgOut) private pure returns (uint256 perStock, uint256 cashUsdg, uint256 acornUsdg) {
        uint256 stashUsdg = usdgOut * SPLIT_STASH_BPS / HOLDER_BPS;
        cashUsdg = usdgOut * SPLIT_CASH_BPS / HOLDER_BPS;
        acornUsdg = usdgOut - stashUsdg - cashUsdg;
        uint256 dust;
        (perStock, dust) = _quarter(stashUsdg);
        cashUsdg += dust;
    }

    /// @dev Four equal stock shares of `usdg` and the rounding dust that stays USDG: the Sweep's Stash and the
    ///      Acorn pool are quartered the same way.
    // The rounding is the spec's (§6 step 5, §7 step 2): the indexer mirrors this formula exactly, so the share
    // is rounded first and the dust is what four shares leave, not computed in one multiplication.
    // forge-lint: disable-next-item(divide-before-multiply)
    // slither-disable-next-line divide-before-multiply
    function _quarter(uint256 usdg) private pure returns (uint256 perStock, uint256 dust) {
        perStock = usdg * PER_STOCK_BPS / BPS;
        dust = usdg - STOCK_LEGS * perStock;
    }

    /// @dev One stock Leg, honouring the Circuit breaker and isolated: a disabled or failed Leg is skipped with
    ///      its reason and its USDG share stays with the caller to pay as Cash.
    // `LegSkipped` reports the Leg's outcome; see the note on `sweep`.
    // forge-lint: disable-next-item(reentrancy-events)
    function _buyStock(uint8 stock, Route calldata route, uint256 usdgIn) private returns (bool ok, uint256 out) {
        uint8 leg = FIRST_STOCK_LEG + stock;
        if (legDisabled[stock]) {
            emit LegSkipped(leg, "disabled");
            return (ok, out);
        }
        bytes memory reason;
        (ok, out, reason) = _runLeg(Leg(leg), route, usdgIn);
        if (!ok) emit LegSkipped(leg, reason);
    }

    /// @dev Funds the Distributor for one Epoch under exact approvals, zeroed again afterwards.
    function _fundEpoch(uint256 epochId, uint256[5] memory amounts, uint256 acornUsdg) private {
        uint256 usdg = amounts[4] + acornUsdg;
        _approveFunding(amounts, usdg, true);
        DISTRIBUTOR.notifyEpochFunding(epochId, amounts, acornUsdg);
        _approveFunding(amounts, usdg, false);
    }

    /// @dev Grants the Distributor exactly `amounts[0..3]` of each Stock Token and `usdg` of USDG, or takes those
    ///      approvals back to zero; tokens with nothing to fund are not touched.
    // Five bounded legs, one approval each.
    // forge-lint: disable-next-item(calls-loop)
    function _approveFunding(uint256[5] memory amounts, uint256 usdg, bool grant) private {
        for (uint256 i = 0; i < STOCK_LEGS; i++) {
            if (amounts[i] > 0) tokens(i).forceApprove(address(DISTRIBUTOR), grant ? amounts[i] : 0);
        }
        if (usdg > 0) T4.forceApprove(address(DISTRIBUTOR), grant ? usdg : 0);
    }

    // ------------------------------------------------------------------ acorn

    /// @notice The weekly Acorn conversion: pull the Acorn pool from the Distributor, quarter it over the four
    ///         stock Legs under the same Circuit breaker and isolation rules as the Sweep, and fund the Acorn
    ///         Draw. The quartering dust and every skipped Leg's share stay USDG. The Distributor decides whether
    ///         `drawId` is convertible: once per Acorn Draw, its seed reported, the pool non-empty.
    /// @param drawId The Acorn Draw to fund; its pool is whatever accrued since the previous conversion.
    /// @param routes One Route per stock Leg in token order: USDG -> SPY, NVDA, MU, SPCX.
    /// @param deadline The one timestamp bound for the whole call; the v3 router has none of its own.
    // `AcornConverted` reports the outcome of the Venue and Distributor calls; see the note on `sweep`.
    // forge-lint: disable-next-item(reentrancy-events)
    function convertAcorn(uint256 drawId, Route[STOCK_LEGS] calldata routes, uint256 deadline)
        external
        nonReentrant
        onlyKeeper
    {
        // forge-lint: disable-next-line(block-timestamp)
        if (block.timestamp > deadline) revert DeadlinePassed();
        uint256 usdgBefore = T4.balanceOf(address(this));
        DISTRIBUTOR.pullAcorn(drawId);
        uint256 usdgIn = T4.balanceOf(address(this)) - usdgBefore;

        (uint256 perStock, uint256 usdgLeft) = _quarter(usdgIn);
        uint256[5] memory amounts;
        for (uint8 i = 0; i < STOCK_LEGS; i++) {
            (bool bought, uint256 stockOut) = _buyStock(i, routes[i], perStock);
            if (bought) amounts[i] = stockOut;
            else usdgLeft += perStock;
        }
        amounts[4] = usdgLeft;

        _fundDraw(drawId, amounts);
        emit AcornConverted(drawId, usdgIn, amounts);
    }

    /// @dev Funds the Distributor for one Acorn Draw under exact approvals, zeroed again afterwards.
    function _fundDraw(uint256 drawId, uint256[5] memory amounts) private {
        _approveFunding(amounts, amounts[4], true);
        DISTRIBUTOR.notifyDrawFunding(drawId, amounts);
        _approveFunding(amounts, amounts[4], false);
    }

    // ------------------------------------------------------------------- legs

    // `sweep` and `convertAcorn` run the four stock Legs from a bounded loop, so the linter sees every Venue call
    // and every Route check below as "inside a loop"; a bad Route reverting the whole call is the intent (spec §5).
    // forge-lint: disable-start(require-revert-in-loop, calls-loop)

    /// @dev Runs one Leg through the Venue its Route names, isolated: the Route is validated first and a bad one
    ///      reverts (a Keeper bug, not a market condition); a revert anywhere inside the Venue, a hostile hook
    ///      included, is caught and returned as `reason` with `ok == false`, and nothing has left the contract.
    ///      A zero `amountIn` is nothing to swap and succeeds with nothing out, without touching the Venue: the
    ///      real SwapRouter02 reads zero as "swap your own balance".
    function _runLeg(Leg leg, Route calldata route, uint256 amountIn)
        internal
        returns (bool ok, uint256 amountOut, bytes memory reason)
    {
        (address tokenIn, address tokenOut) = _legTokens(leg);
        if (route.venue == address(V3_ROUTER)) return _runV3(tokenIn, tokenOut, route, amountIn);
        if (route.venue == address(V4_POOL_MANAGER)) return _runV4(tokenIn, tokenOut, route, amountIn);
        revert BadVenue(route.venue);
    }

    /// @dev `_runLeg` for the Leg that must not be skipped: a Venue failure bubbles its revert data unchanged.
    function _runLegStrict(Leg leg, Route calldata route, uint256 amountIn) internal returns (uint256 amountOut) {
        (bool ok, uint256 out, bytes memory reason) = _runLeg(leg, route, amountIn);
        if (!ok) {
            // Re-raise the Venue's own revert so the Keeper sees the real cause, not a wrapper.
            assembly ("memory-safe") {
                revert(add(reason, 32), mload(reason))
            }
        }
        return out;
    }

    /// @dev v3: `route.data` is the `exactInput` path, `tokenA ‖ fee ‖ tokenB ‖ …`, which must start with the Leg's
    ///      input token and end with its output token (WETH for ETH); any number of hops in between. ETH goes in as
    ///      `msg.value` (the router wraps it); an ERC-20 goes in under an exact approval that is zeroed afterwards
    ///      whether the swap succeeded or not. The router delivers ETH output as WETH, which is unwrapped here.
    function _runV3(address tokenIn, address tokenOut, Route calldata route, uint256 amountIn)
        private
        returns (bool ok, uint256 amountOut, bytes memory reason)
    {
        bytes calldata path = route.data;
        if (path.length < V3_ADDRESS_BYTES + V3_HOP_BYTES || (path.length - V3_ADDRESS_BYTES) % V3_HOP_BYTES != 0) {
            revert BadPath();
        }
        address first = address(bytes20(path[:V3_ADDRESS_BYTES]));
        address last = address(bytes20(path[path.length - V3_ADDRESS_BYTES:]));
        if (first != _v3Token(tokenIn) || last != _v3Token(tokenOut)) revert BadPath();
        if (amountIn == 0) {
            ok = true; // nothing to swap
            return (ok, 0, "");
        }

        ISwapRouter02.ExactInputParams memory params = ISwapRouter02.ExactInputParams({
            path: path, recipient: address(this), amountIn: amountIn, amountOutMinimum: route.minOut
        });
        bool ethIn = tokenIn == address(0);
        if (!ethIn) IERC20(tokenIn).forceApprove(address(V3_ROUTER), amountIn);
        try V3_ROUTER.exactInput{value: ethIn ? amountIn : 0}(params) returns (uint256 out) {
            ok = true;
            amountOut = out;
        } catch (bytes memory err) {
            reason = err;
        }
        if (!ethIn) IERC20(tokenIn).forceApprove(address(V3_ROUTER), 0);
        if (ok && tokenOut == address(0)) IWETH9(WETH).withdraw(amountOut);
    }

    /// @dev v4: `route.data` is `abi.encode(PoolKey)`; its currencies must be exactly the Leg's tokens (ETH is the
    ///      zero currency, sorted first) and any hook is accepted, since the NUTZ pool has one. The swap happens in
    ///      `unlockCallback`; the try around `unlock` catches everything that reverts inside the manager, hooks
    ///      and the callback's own checks included.
    function _runV4(address tokenIn, address tokenOut, Route calldata route, uint256 amountIn)
        private
        returns (bool ok, uint256 amountOut, bytes memory reason)
    {
        if (route.data.length != V4_KEY_BYTES) revert BadPoolKey();
        PoolKey memory key = abi.decode(route.data, (PoolKey));
        bool zeroForOne = tokenIn < tokenOut;
        (address c0, address c1) = zeroForOne ? (tokenIn, tokenOut) : (tokenOut, tokenIn);
        if (Currency.unwrap(key.currency0) != c0 || Currency.unwrap(key.currency1) != c1) revert BadPoolKey();
        if (amountIn == 0) {
            ok = true; // nothing to swap
            return (ok, 0, "");
        }

        SwapOrder memory order = SwapOrder({key: key, zeroForOne: zeroForOne, amountIn: amountIn, minOut: route.minOut});
        try V4_POOL_MANAGER.unlock(abi.encode(order)) returns (bytes memory result) {
            ok = true;
            amountOut = abi.decode(result, (uint256));
        } catch (bytes memory err) {
            reason = err;
        }
    }

    /// @notice The v4 pool manager's callback during `unlock`: one exact-input swap with the extreme price bound on
    ///         the swap's side, the input settled (ETH as value; an ERC-20 by sync, transfer, settle) and the output
    ///         taken here. Reverts, and so fails the Leg, when the pool fills less than the whole input or delivers
    ///         less than `minOut`. Only the pool manager may call it.
    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        if (msg.sender != address(V4_POOL_MANAGER)) revert NotPoolManager();
        SwapOrder memory order = abi.decode(data, (SwapOrder));

        BalanceDelta delta = V4_POOL_MANAGER.swap(
            order.key,
            IPoolManager.SwapParams({
                zeroForOne: order.zeroForOne,
                amountSpecified: -SafeCast.toInt256(order.amountIn),
                sqrtPriceLimitX96: order.zeroForOne ? V4_PRICE_LIMIT_DOWN : V4_PRICE_LIMIT_UP
            }),
            ""
        );
        (int128 inDelta, int128 outDelta) =
            order.zeroForOne ? (delta.amount0(), delta.amount1()) : (delta.amount1(), delta.amount0());
        // The manager reports what the swap moved: input negative (owed by us), output positive (owed to us);
        // a sign the other way round (a hook paying us input, or charging us output) fails the checked casts.
        uint256 filled = SafeCast.toUint256(-int256(inDelta));
        uint256 amountOut = SafeCast.toUint256(int256(outDelta));
        if (filled != order.amountIn) revert PartialFill(filled, order.amountIn);
        if (amountOut < order.minOut) revert InsufficientOutput(amountOut, order.minOut);

        Currency cin = order.zeroForOne ? order.key.currency0 : order.key.currency1;
        Currency cout = order.zeroForOne ? order.key.currency1 : order.key.currency0;
        // `sync` names the currency the next `settle` pays; syncing native first also clears anything a hook left
        // synced during the swap, which would otherwise make a native settle revert.
        V4_POOL_MANAGER.sync(cin);
        // `settle` returns what it credited; the manager nets every currency at the end of the unlock, so a short
        // settle reverts there and the return value adds no check of its own (both triages below).
        // slither-disable-start unused-return
        if (cin.isAddressZero()) {
            // forge-lint: disable-next-line(unused-return)
            V4_POOL_MANAGER.settle{value: order.amountIn}();
        } else {
            IERC20(Currency.unwrap(cin)).safeTransfer(address(V4_POOL_MANAGER), order.amountIn);
            // forge-lint: disable-next-line(unused-return)
            V4_POOL_MANAGER.settle();
        }
        // slither-disable-end unused-return
        V4_POOL_MANAGER.take(cout, address(this), amountOut);
        return abi.encode(amountOut);
    }

    /// @dev The fixed input and output of each Leg, ETH as the zero address.
    function _legTokens(Leg leg) private view returns (address tokenIn, address tokenOut) {
        if (leg == Leg.NutzToEth) {
            if (nutz == address(0)) revert NutzNotBound();
            return (nutz, address(0));
        }
        if (leg == Leg.EthToUsdg) return (address(0), address(T4));
        return (address(T4), address(tokens(uint8(leg) - FIRST_STOCK_LEG)));
    }

    /// @dev The token a v3 path names for `token`: WETH stands in for ETH.
    function _v3Token(address token) private view returns (address) {
        return token == address(0) ? WETH : token;
    }

    // forge-lint: disable-end(require-revert-in-loop, calls-loop)

    // ------------------------------------------------------------------ views

    /// @notice Reward Token `i` in the fixed order SPY, NVDA, MU, SPCX, USDG.
    function tokens(uint256 i) public view returns (IERC20) {
        if (i == 0) return T0;
        if (i == 1) return T1;
        if (i == 2) return T2;
        if (i == 3) return T3;
        return T4;
    }
}
