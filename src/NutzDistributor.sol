// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {MerkleProof} from "@openzeppelin/contracts/utils/cryptography/MerkleProof.sol";
import {Signers} from "./Signers.sol";
import {INutzDraw} from "./interfaces/INutzDraw.sol";
import {INutzDistributor} from "./interfaces/INutzDistributor.sol";

/// @title NutzDistributor
/// @notice Holds Reward Tokens between funding and payout and pays only against a posted Root.
///         Can never pay more per Epoch or Acorn Draw than was funded plus Carry.
///         No owner, no pause, no upgrade, no withdraw.
contract NutzDistributor is Signers, ReentrancyGuard, INutzDistributor {
    using SafeERC20 for IERC20;

    // ------------------------------------------------------------------ types

    /// @notice The two kinds of ledger: hourly Epochs and weekly Acorn Draws. Same code path, separate books.
    enum Kind {
        Epoch,
        Draw
    }

    /// @notice One Epoch's or one Draw's book. `rootPostedAt == 0` means no Root is posted (also after Void).
    struct Ledger {
        bytes32 root;
        uint256 rootPostedAt;
        bool skipped;
        uint256[5] funded;
        uint256[5] totals;
        uint256[5] claimed;
    }

    // -------------------------------------------------------------- constants

    uint256 public constant EPOCH = 3600;
    uint256 public constant WEEK = 604_800;
    /// @notice Dispute window: nothing is claimable until this long after a Root is posted.
    uint256 public constant CLAIM_DELAY = 30 minutes;
    /// @notice A Push may deduct at most this share of the pushed USDG as a gas fee.
    uint256 public constant MAX_PUSH_FEE_BPS = 500;
    uint8 public constant USDG = 4;

    bytes32 private constant POST_ROOT_TYPEHASH =
        keccak256("PostRoot(uint8 kind,uint256 id,bytes32 root,uint256[5] totals,uint256 nonce)");
    bytes32 private constant VOID_ROOT_TYPEHASH = keccak256("VoidRoot(uint8 kind,uint256 id,uint256 nonce)");
    bytes32 private constant SET_RATE_RANGE_TYPEHASH = keccak256("SetRateRange(uint256 min,uint256 max,uint256 nonce)");
    bytes32 private constant SET_DRAW_CONTRACT_TYPEHASH = keccak256("SetDrawContract(address draw,uint256 nonce)");
    bytes32 private constant APPEND_EXCLUDED_TYPEHASH = keccak256("AppendExcluded(address account,uint256 nonce)");

    // ------------------------------------------------------------- immutables

    /// @notice The only address allowed to fund the ledgers.
    address public immutable CONVERTER;
    IERC20 private immutable T0;
    IERC20 private immutable T1;
    IERC20 private immutable T2;
    IERC20 private immutable T3;
    IERC20 private immutable T4;
    /// @notice Gas units charged per Push entry, plus per leaf in the entry (measured on fork, fixed at deploy).
    uint256 public immutable PUSH_GAS_BASE;
    uint256 public immutable PUSH_GAS_PER_LEAF;

    /// @notice One Push: every leaf of `account` for `ids` of `kind`, settled together with one fee.
    struct PushEntry {
        address account;
        Kind kind;
        uint256[] ids;
        uint256[5][] amounts;
        bytes32[][] proofs;
    }

    /// @notice All the books of one Kind: its ledgers, per-account claim flags, high-water mark and Carry.
    struct Book {
        mapping(uint256 id => Ledger) ledgers;
        mapping(uint256 id => mapping(address account => bool)) claimed;
        uint256 rootedThrough;
        uint256[5] carry;
    }

    // ---------------------------------------------------------------- storage

    Book private epochBook;
    Book private drawBook;
    /// @notice Allocations whose transfer failed (issuer pause or blocklist), collectable via `claimStuck`.
    mapping(address account => uint256[5]) private stuckOf;
    /// @notice USDG accumulated from the Acorn Slice, released to the Converter by `pullAcorn`.
    uint256 public acornPoolUsdg;
    mapping(uint256 drawId => bool) public drawConverted;
    /// @notice The Draw contract that reports the beacon seed per draw; zero until set through the timelock.
    INutzDraw public drawContract;
    address[] private excludedList;
    /// @notice Bounds on the rate the Keeper may pass to `pushClaims`: raw USDG (6 decimals) received per 1 ETH;
    ///         fee = wei × rate / 1e18.
    uint256 public minUsdgPerEth;
    uint256 public maxUsdgPerEth;

    // ---------------------------------------------------------------- errors

    error InvalidRateRange();
    error NotConverter();
    /// @dev The period has not started yet (id beyond the current one).
    error PeriodNotOpen(uint256 id);
    /// @dev The period is at or below the rooted-through mark and can no longer be funded or rooted.
    error PeriodClosed(uint256 id);
    /// @dev A Root can only be posted for a period that has ended.
    error PeriodNotClosed(uint256 id);
    /// @dev `totals[token]` exceeds funded plus Carry for that token.
    error CapExceeded(uint256 token);
    error NoRoot(uint256 id);
    error RootIsFinal(uint256 id);
    /// @dev Only the most recently posted Root of a Kind can be voided; void later ones first.
    error NotLatestRoot(uint256 id);
    error NotFinal(uint256 id);
    error AlreadyClaimed(uint256 id, address account);
    error InvalidProof();
    error NothingStuck();
    error LengthMismatch();
    error RateOutOfRange(uint256 rate);
    /// @dev The gas fee would exceed MAX_PUSH_FEE_BPS of the account's pushed USDG; it keeps accumulating.
    error PushFeeTooHigh(address account);
    error NoDrawContract();
    /// @dev The Draw contract reports no seed for this draw yet.
    error DrawNotFulfilled(uint256 drawId);
    error NotConverted(uint256 drawId);
    error AlreadyConverted(uint256 drawId);
    error NothingToConvert();
    error AlreadyExcluded(address account);

    // ---------------------------------------------------------------- events

    event EpochFunded(uint256 indexed epochId, uint256[5] amounts, uint256 acornUsdg);
    /// @notice A funded period was passed over by a later Root; its funding rolled into Carry.
    event Skipped(Kind indexed kind, uint256 indexed id);
    /// @notice `carryIn` is the Carry available to this Root, so the verifier can reproduce the cap.
    event RootPosted(Kind indexed kind, uint256 indexed id, bytes32 root, uint256[5] totals, uint256[5] carryIn);
    event RootVoided(Kind indexed kind, uint256 indexed id);
    event Claimed(Kind indexed kind, uint256 indexed id, address indexed account, uint256[5] amounts);
    /// @notice A token transfer failed (issuer pause or blocklist); the amount waits in `stuck`.
    event Stuck(address indexed account, uint256 indexed token, uint256 amount);
    event StuckClaimed(address indexed account, uint256 indexed token, uint256 amount);
    event Pushed(address indexed account, Kind indexed kind, uint256[] ids, uint256 fee);
    event RateRangeSet(uint256 minUsdgPerEth, uint256 maxUsdgPerEth);
    event AcornPulled(uint256 indexed drawId, uint256 usdg);
    event DrawFunded(uint256 indexed drawId, uint256[5] amounts);
    event DrawContractSet(address indexed draw);
    /// @notice `account` counts as Excluded from the Epoch containing this block on; emitted for every base entry at
    ///         construction and for every executed append.
    event ExcludedAppended(address indexed account);

    // -------------------------------------------------------------- modifiers

    modifier onlyConverter() {
        if (msg.sender != CONVERTER) revert NotConverter();
        _;
    }

    // ------------------------------------------------------------ constructor

    constructor(
        address[3] memory signers_,
        address keeper_,
        address converter_,
        IERC20[5] memory tokens_,
        uint256 pushGasBase_,
        uint256 pushGasPerLeaf_,
        uint256 minRate_,
        uint256 maxRate_,
        address[] memory excludedBase_
    ) Signers("NutzDistributor", signers_, keeper_) {
        if (converter_ == address(0)) revert ZeroAddress();
        for (uint256 i = 0; i < 5; i++) {
            // forge-lint: disable-next-line(require-revert-in-loop)
            if (address(tokens_[i]) == address(0)) revert ZeroAddress();
        }
        if (minRate_ == 0 || minRate_ > maxRate_) revert InvalidRateRange();
        CONVERTER = converter_;
        (T0, T1, T2, T3, T4) = (tokens_[0], tokens_[1], tokens_[2], tokens_[3], tokens_[4]);
        PUSH_GAS_BASE = pushGasBase_;
        PUSH_GAS_PER_LEAF = pushGasPerLeaf_;
        minUsdgPerEth = minRate_;
        maxUsdgPerEth = maxRate_;
        excludedList = excludedBase_;
        // The base list is announced the same way appends are, so the indexer rebuilds any Epoch's Excluded set
        // from `ExcludedAppended` alone (engineering-spec §4.2).
        for (uint256 i = 0; i < excludedBase_.length; i++) {
            emit ExcludedAppended(excludedBase_[i]);
        }
        // The skip loop in postRoot never walks periods that predate the contract.
        epochBook.rootedThrough = currentEpoch() - 1;
        drawBook.rootedThrough = currentDraw() - 1;
    }

    // ---------------------------------------------------------------- funding

    /// @notice Records one Sweep's Reward Tokens for `epochId` and pulls them from the Converter.
    ///         Several Sweeps may fund one Epoch. `acornUsdg` is extra USDG that goes to the Acorn pool.
    function notifyEpochFunding(uint256 epochId, uint256[5] calldata amounts, uint256 acornUsdg)
        external
        nonReentrant
        onlyConverter
    {
        if (epochId > currentEpoch()) revert PeriodNotOpen(epochId);
        if (epochId <= epochBook.rootedThrough) revert PeriodClosed(epochId);
        Ledger storage L = epochBook.ledgers[epochId];
        for (uint256 i = 0; i < 5; i++) {
            L.funded[i] += amounts[i];
        }
        acornPoolUsdg += acornUsdg;
        emit EpochFunded(epochId, amounts, acornUsdg);
        for (uint256 i = 0; i < 4; i++) {
            if (amounts[i] > 0) tokens(i).safeTransferFrom(msg.sender, address(this), amounts[i]);
        }
        uint256 usdg = amounts[USDG] + acornUsdg;
        if (usdg > 0) T4.safeTransferFrom(msg.sender, address(this), usdg);
    }

    /// @notice Releases the whole Acorn pool to the Converter for conversion into Stock Tokens, once per
    ///         draw, and only after the Draw contract reports the draw's seed.
    function pullAcorn(uint256 drawId) external nonReentrant onlyConverter {
        _requireFulfilled(drawId);
        if (drawId > currentDraw()) revert PeriodNotOpen(drawId);
        if (drawId <= drawBook.rootedThrough) revert PeriodClosed(drawId);
        if (drawConverted[drawId]) revert AlreadyConverted(drawId);
        uint256 usdg = acornPoolUsdg;
        if (usdg == 0) revert NothingToConvert();
        drawConverted[drawId] = true;
        acornPoolUsdg = 0;
        emit AcornPulled(drawId, usdg);
        T4.safeTransfer(msg.sender, usdg);
    }

    /// @notice Records the converted Acorn pool (a failed leg comes back as USDG) and pulls it.
    function notifyDrawFunding(uint256 drawId, uint256[5] calldata amounts) external nonReentrant onlyConverter {
        if (!drawConverted[drawId]) revert NotConverted(drawId);
        if (drawId <= drawBook.rootedThrough) revert PeriodClosed(drawId);
        Ledger storage L = drawBook.ledgers[drawId];
        for (uint256 i = 0; i < 5; i++) {
            L.funded[i] += amounts[i];
        }
        emit DrawFunded(drawId, amounts);
        for (uint256 i = 0; i < 5; i++) {
            if (amounts[i] > 0) tokens(i).safeTransferFrom(msg.sender, address(this), amounts[i]);
        }
    }

    function _requireFulfilled(uint256 drawId) private view {
        INutzDraw draw = drawContract;
        if (address(draw) == address(0)) revert NoDrawContract();
        if (draw.seedOf(drawId) == bytes32(0)) revert DrawNotFulfilled(drawId);
    }

    // ------------------------------------------------------------------ roots

    /// @notice Posts the Root of a closed period. 2-of-3 over
    ///         `PostRoot(uint8 kind,uint256 id,bytes32 root,uint256[5] totals,uint256 nonce)`.
    ///         Roots are posted in period order; funded periods passed over are marked Skipped and their
    ///         funding rolls into Carry here. Requires `totals[i] <= funded[i] + carry[i]`; the remainder
    ///         becomes the next Carry. Claims open `CLAIM_DELAY` later.
    function postRoot(
        Kind kind,
        uint256 id,
        bytes32 root,
        uint256[5] calldata totals,
        bytes calldata sig1,
        bytes calldata sig2
    ) external nonReentrant {
        Book storage B = _book(kind);
        if (id <= B.rootedThrough) revert PeriodClosed(id);
        if (id >= _currentPeriod(kind)) revert PeriodNotClosed(id);
        if (kind == Kind.Draw) {
            if (!drawConverted[id]) revert NotConverted(id);
            _requireFulfilled(id);
        }
        _require2of3(
            keccak256(abi.encode(POST_ROOT_TYPEHASH, uint8(kind), id, root, keccak256(abi.encode(totals)), nonce)),
            sig1,
            sig2
        );

        for (uint256 x = B.rootedThrough + 1; x < id; x++) {
            _skip(kind, B, x);
        }

        Ledger storage L = B.ledgers[id];
        uint256[5] memory carryIn = B.carry;
        for (uint256 i = 0; i < 5; i++) {
            uint256 available = L.funded[i] + carryIn[i];
            // forge-lint: disable-next-line(require-revert-in-loop)
            if (totals[i] > available) revert CapExceeded(i);
            B.carry[i] = available - totals[i];
        }
        L.root = root;
        L.totals = totals;
        L.rootPostedAt = block.timestamp;
        B.rootedThrough = id;
        emit RootPosted(kind, id, root, totals, carryIn);
    }

    /// @notice Rejects the latest Root of `kind` inside its Dispute window. 2-of-3 over
    ///         `VoidRoot(uint8 kind,uint256 id,uint256 nonce)`. Carry is restored to what it was before
    ///         the Root, the period keeps its funding, and a corrected Root for the same id is posted next.
    function voidRoot(Kind kind, uint256 id, bytes calldata sig1, bytes calldata sig2) external nonReentrant {
        Book storage B = _book(kind);
        Ledger storage L = B.ledgers[id];
        if (L.rootPostedAt == 0) revert NoRoot(id);
        if (isFinal(kind, id)) revert RootIsFinal(id);
        if (id != B.rootedThrough) revert NotLatestRoot(id);
        _require2of3(keccak256(abi.encode(VOID_ROOT_TYPEHASH, uint8(kind), id, nonce)), sig1, sig2);

        // carry after post = funded + carryBefore - totals, and no later Root exists, so this is exact.
        for (uint256 i = 0; i < 5; i++) {
            B.carry[i] = B.carry[i] + L.totals[i] - L.funded[i];
        }
        delete L.root;
        delete L.totals;
        delete L.rootPostedAt;
        B.rootedThrough = id - 1;
        emit RootVoided(kind, id);
    }

    function _skip(Kind kind, Book storage B, uint256 id) private {
        Ledger storage L = B.ledgers[id];
        bool funded = false;
        for (uint256 i = 0; i < 5; i++) {
            uint256 f = L.funded[i];
            if (f > 0) {
                funded = true;
                B.carry[i] += f;
            }
        }
        if (funded) {
            L.skipped = true;
            emit Skipped(kind, id);
        }
    }

    // ----------------------------------------------------------------- claims

    /// @notice Collects `account`'s Allocation for period `id` of `kind`. Anyone may call; tokens always go
    ///         to `account`. A token whose transfer fails is recorded in `stuck` and never blocks the others.
    function claim(Kind kind, uint256 id, address account, uint256[5] calldata amounts, bytes32[] calldata proof)
        external
        nonReentrant
    {
        _settle(kind, id, account, amounts, proof);
        _payout(account, amounts);
    }

    /// @notice `claim` for several periods of one Kind in one transaction. One bad leaf reverts all.
    function claimMany(
        Kind kind,
        uint256[] calldata ids,
        address account,
        uint256[5][] calldata amounts,
        bytes32[][] calldata proofs
    ) external nonReentrant {
        if (ids.length != amounts.length || ids.length != proofs.length) {
            revert LengthMismatch();
        }
        uint256[5] memory sum = [uint256(0), 0, 0, 0, 0];
        for (uint256 k = 0; k < ids.length; k++) {
            _settle(kind, ids[k], account, amounts[k], proofs[k]);
            for (uint256 i = 0; i < 5; i++) {
                sum[i] += amounts[k][i];
            }
        }
        _payout(account, sum);
    }

    /// @notice Delivers Allocations on holders' behalf, deducting a gas fee from each holder's USDG:
    ///         `(PUSH_GAS_BASE + leaves * PUSH_GAS_PER_LEAF) * gasPriceWei * usdgPerEth / 1e18`, capped at
    ///         `MAX_PUSH_FEE_BPS` of the USDG being pushed. The fee goes to the caller, who paid the gas.
    ///         `usdgPerEth` is raw USDG (6 decimals) received per 1 ETH; fee = wei × rate / 1e18. It must lie
    ///         within the Signer-set range. One bad entry reverts the whole batch.
    // Each entry is one holder; the loop bound is the keeper's batch size (200 in practice).
    // Phase 1 settles every leaf (checks, effects, events), phase 2 pays: nothing follows an external call,
    // and the function is nonReentrant; the linter does not see the phase order across the two loops.
    // forge-lint: disable-next-item(require-revert-in-loop, calls-loop, reentrancy-events)
    // slither-disable-next-line reentrancy-no-eth
    function pushClaims(PushEntry[] calldata entries, uint256 gasPriceWei, uint256 usdgPerEth)
        external
        nonReentrant
        onlyKeeper
    {
        if (usdgPerEth < minUsdgPerEth || usdgPerEth > maxUsdgPerEth) {
            revert RateOutOfRange(usdgPerEth);
        }
        uint256[5][] memory sums = new uint256[5][](entries.length);
        uint256 totalFee = 0;
        for (uint256 n = 0; n < entries.length; n++) {
            PushEntry calldata pe = entries[n];
            if (pe.ids.length != pe.amounts.length || pe.ids.length != pe.proofs.length) revert LengthMismatch();
            uint256[5] memory sum = [uint256(0), 0, 0, 0, 0];
            for (uint256 k = 0; k < pe.ids.length; k++) {
                _settle(pe.kind, pe.ids[k], pe.account, pe.amounts[k], pe.proofs[k]);
                for (uint256 i = 0; i < 5; i++) {
                    sum[i] += pe.amounts[k][i];
                }
            }
            uint256 fee = (PUSH_GAS_BASE + pe.ids.length * PUSH_GAS_PER_LEAF) * gasPriceWei * usdgPerEth / 1e18;
            if (fee > sum[USDG] * MAX_PUSH_FEE_BPS / 10_000) revert PushFeeTooHigh(pe.account);
            sum[USDG] -= fee;
            totalFee += fee;
            sums[n] = sum;
            emit Pushed(pe.account, pe.kind, pe.ids, fee);
        }
        for (uint256 n = 0; n < entries.length; n++) {
            _payout(entries[n].account, sums[n]);
        }
        if (totalFee > 0) {
            uint256[5] memory feeOnly;
            feeOnly[USDG] = totalFee;
            _payout(msg.sender, feeOnly);
        }
    }

    /// @notice Sets the bounds on `usdgPerEth` accepted by `pushClaims` (raw USDG, 6 decimals, per 1 ETH).
    ///         Instant 2-of-3 over `SetRateRange(uint256 min,uint256 max,uint256 nonce)`.
    function setRateRange(uint256 min, uint256 max, bytes calldata sig1, bytes calldata sig2) external {
        if (min == 0 || min > max) revert InvalidRateRange();
        _require2of3(keccak256(abi.encode(SET_RATE_RANGE_TYPEHASH, min, max, nonce)), sig1, sig2);
        minUsdgPerEth = min;
        maxUsdgPerEth = max;
        emit RateRangeSet(min, max);
    }

    /// @notice Retries the transfer of `account`'s stuck amount of token `t`. Reverts, keeping the record,
    ///         if the token still refuses.
    function claimStuck(address account, uint256 t) external nonReentrant {
        uint256 amount = stuckOf[account][t];
        if (amount == 0) revert NothingStuck();
        stuckOf[account][t] = 0;
        emit StuckClaimed(account, t, amount);
        tokens(t).safeTransfer(account, amount);
    }

    /// @dev Checks-and-effects of one leaf: Final Root, unclaimed, valid proof, within totals; then marks it.
    // claimMany and pushClaims call this in a loop on purpose: one bad leaf must revert the whole batch.
    // Every caller runs all _settle calls before any _payout, inside nonReentrant, so the Claimed event
    // never follows an external call.
    // forge-lint: disable-next-item(require-revert-in-loop, reentrancy-events)
    function _settle(Kind kind, uint256 id, address account, uint256[5] calldata amounts, bytes32[] calldata proof)
        private
    {
        if (!isFinal(kind, id)) revert NotFinal(id);
        Book storage B = _book(kind);
        if (B.claimed[id][account]) revert AlreadyClaimed(id, account);
        Ledger storage L = B.ledgers[id];
        bytes32 leaf = keccak256(bytes.concat(keccak256(abi.encode(id, account, amounts))));
        if (!MerkleProof.verifyCalldata(proof, L.root, leaf)) revert InvalidProof();
        B.claimed[id][account] = true;
        for (uint256 i = 0; i < 5; i++) {
            uint256 c = L.claimed[i] + amounts[i];
            // forge-lint: disable-next-line(require-revert-in-loop)
            if (c > L.totals[i]) revert CapExceeded(i);
            L.claimed[i] = c;
        }
        emit Claimed(kind, id, account, amounts);
    }

    /// @dev Transfers each non-zero amount; a failing token lands in `stuck[account]` instead of reverting.
    // Five bounded legs, one external call each; every entry point is nonReentrant, so the Stuck event
    // emitted after the failed attempt cannot be reordered by a re-entrant call.
    // forge-lint: disable-next-item(calls-loop, reentrancy-events)
    function _payout(address account, uint256[5] memory amounts) private {
        for (uint256 i = 0; i < 5; i++) {
            uint256 amount = amounts[i];
            if (amount == 0) continue;
            if (!_tryTransfer(tokens(i), account, amount)) {
                stuckOf[account][i] += amount;
                emit Stuck(account, i, amount);
            }
        }
    }

    /// @dev `transfer` that reports failure instead of reverting: reverts, `false` returns and
    ///      empty-return tokens (treated as success) are all handled.
    // Called once per token from _payout's bounded loop; see the note there. The stuck record written after
    // a failed call is protected by nonReentrant on every entry point.
    // forge-lint: disable-next-item(calls-loop, reentrancy-no-eth)
    function _tryTransfer(IERC20 token, address to, uint256 amount) private returns (bool) {
        (bool ok, bytes memory ret) = address(token).call(abi.encodeCall(IERC20.transfer, (to, amount)));
        return ok && (ret.length == 0 || abi.decode(ret, (bool)));
    }

    // ------------------------------------------------------- governance (48h)

    /// @notice Schedules replacing the Draw contract. 2-of-3 over `SetDrawContract(address draw,uint256 nonce)`.
    function proposeDrawContract(address draw, bytes calldata sig1, bytes calldata sig2) external {
        if (draw == address(0)) revert ZeroAddress();
        _require2of3(keccak256(abi.encode(SET_DRAW_CONTRACT_TYPEHASH, draw, nonce)), sig1, sig2);
        _schedule(keccak256(abi.encode(SET_DRAW_CONTRACT_TYPEHASH, draw)));
    }

    /// @notice Executes a scheduled Draw contract change once its timelock has elapsed.
    function executeDrawContract(address draw) external {
        if (draw == address(0)) revert ZeroAddress();
        _consume(keccak256(abi.encode(SET_DRAW_CONTRACT_TYPEHASH, draw)));
        drawContract = INutzDraw(draw);
        emit DrawContractSet(draw);
    }

    /// @notice Schedules appending an Excluded address. 2-of-3 over `AppendExcluded(address account,uint256 nonce)`.
    function proposeExclusion(address account, bytes calldata sig1, bytes calldata sig2) external {
        _checkNotExcluded(account);
        _require2of3(keccak256(abi.encode(APPEND_EXCLUDED_TYPEHASH, account, nonce)), sig1, sig2);
        _schedule(keccak256(abi.encode(APPEND_EXCLUDED_TYPEHASH, account)));
    }

    /// @notice Executes a scheduled exclusion once its timelock has elapsed. Append-only, never removable.
    function executeExclusion(address account) external {
        _consume(keccak256(abi.encode(APPEND_EXCLUDED_TYPEHASH, account)));
        _checkNotExcluded(account);
        excludedList.push(account);
        emit ExcludedAppended(account);
    }

    // The list is short (pools, Pons contracts, the Vault, a few exchange deposit addresses).
    // forge-lint: disable-next-item(require-revert-in-loop)
    function _checkNotExcluded(address account) private view {
        if (account == address(0)) revert ZeroAddress();
        uint256 n = excludedList.length;
        for (uint256 i = 0; i < n; i++) {
            if (excludedList[i] == account) revert AlreadyExcluded(account);
        }
    }

    // ------------------------------------------------------------------ views

    /// @notice Amounts per token owed to `account` whose transfer failed; collectable via `claimStuck`.
    function stuck(address account) external view returns (uint256[5] memory) {
        return stuckOf[account];
    }

    /// @notice The book of one Epoch or one Draw.
    function ledger(Kind kind, uint256 id) external view returns (Ledger memory) {
        return _book(kind).ledgers[id];
    }

    function currentEpoch() public view returns (uint256) {
        return block.timestamp / EPOCH;
    }

    function currentDraw() public view returns (uint256) {
        return block.timestamp / WEEK;
    }

    /// @notice Reward token `i` in the fixed order SPY, NVDA, MU, SPCX, USDG.
    function tokens(uint256 i) public view returns (IERC20) {
        if (i == 0) return T0;
        if (i == 1) return T1;
        if (i == 2) return T2;
        if (i == 3) return T3;
        return T4;
    }

    /// @notice Highest period id whose Root or Skip has been processed for `kind`.
    function rootedThrough(Kind kind) external view returns (uint256) {
        return _book(kind).rootedThrough;
    }

    /// @notice Reward Tokens funded but not allocated, available to the next Root of `kind`.
    function carry(Kind kind) external view returns (uint256[5] memory) {
        return _book(kind).carry;
    }

    /// @notice Whether `account` has claimed its Allocation for period `id` of `kind`.
    function claimed(Kind kind, uint256 id, address account) external view returns (bool) {
        return _book(kind).claimed[id][account];
    }

    /// @notice A Root is Final once its Dispute window has closed: no longer voidable, Allocations claimable.
    function isFinal(Kind kind, uint256 id) public view returns (bool) {
        uint256 postedAt = _book(kind).ledgers[id].rootPostedAt;
        // forge-lint: disable-next-line(block-timestamp)
        return postedAt != 0 && block.timestamp >= postedAt + CLAIM_DELAY;
    }

    function _book(Kind kind) private view returns (Book storage) {
        return kind == Kind.Epoch ? epochBook : drawBook;
    }

    function _currentPeriod(Kind kind) private view returns (uint256) {
        return kind == Kind.Epoch ? currentEpoch() : currentDraw();
    }

    /// @notice Addresses whose NUTZ balance counts as zero for every rule. Append-only.
    function excluded() external view returns (address[] memory) {
        return excludedList;
    }
}
