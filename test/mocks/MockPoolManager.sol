// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "v4-core/interfaces/callback/IUnlockCallback.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolId} from "v4-core/types/PoolId.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {BalanceDelta, toBalanceDelta} from "v4-core/types/BalanceDelta.sol";
import {SafeCast} from "v4-core/libraries/SafeCast.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";

/// @dev Stand-in for the v4 PoolManager's swap path: `unlock` calls the locker back, `swap` fills an exact-input
///      order at a fixed rate per pool id and direction (`amountOut = amountIn × rate / 1e18`) from the manager's own
///      inventory, which the test seeds, and `sync` / `settle` / `take` move value with the real sign convention
///      (negative delta: the locker owes the manager; positive: the manager owes the locker). Every currency touched
///      must net to zero by the end of the unlock, as on the real manager. A per-key switch makes `swap` revert,
///      standing in for a hostile hook or any other failure inside the Venue. The mock has no price, so of the real
///      price-limit checks it keeps only the bounds: a limit at or beyond the extreme on the swap's side (zero
///      included) reverts `PriceLimitOutOfBounds`. A per-key, per-direction `maxFill` caps how much input one swap
///      absorbs, standing in for liquidity running out before the exact-input order is filled (the real manager then
///      stops at the price limit and reports the smaller input in the delta); zero means unlimited. Not a full
///      `IPoolManager`: the Converter reaches it through that interface at the address, and only these functions
///      exist.
contract MockPoolManager {
    error AlreadyUnlocked();
    error ManagerLocked();
    error CurrencyNotSettled();
    error PoolNotInitialized();
    error PoolReverts();
    error ExactOutputUnsupported();
    error NonzeroNativeValue();
    error PriceLimitOutOfBounds(uint160 sqrtPriceLimitX96);

    mapping(PoolId => mapping(bool zeroForOne => uint256)) public rate; // output units per 1e18 input units
    mapping(PoolId => bool) public reverts;
    mapping(PoolId => mapping(bool zeroForOne => uint256)) public maxFill; // most input one swap absorbs; 0 = no cap

    bool private unlocked;
    Currency private synced;
    bool private hasSynced;
    uint256 private reservesBefore;
    mapping(Currency => int256) private delta;
    Currency[] private touched;

    modifier onlyWhenUnlocked() {
        if (!unlocked) revert ManagerLocked();
        _;
    }

    function setRate(PoolKey calldata key, bool zeroForOne, uint256 r) external {
        rate[key.toId()][zeroForOne] = r;
    }

    function setReverts(PoolKey calldata key, bool r) external {
        reverts[key.toId()] = r;
    }

    function setMaxFill(PoolKey calldata key, bool zeroForOne, uint256 cap) external {
        maxFill[key.toId()][zeroForOne] = cap;
    }

    function unlock(bytes calldata data) external returns (bytes memory result) {
        if (unlocked) revert AlreadyUnlocked();
        unlocked = true;
        result = IUnlockCallback(msg.sender).unlockCallback(data);
        for (uint256 i = 0; i < touched.length; i++) {
            if (delta[touched[i]] != 0) revert CurrencyNotSettled();
        }
        delete touched;
        unlocked = false;
    }

    function swap(PoolKey memory key, IPoolManager.SwapParams memory params, bytes calldata)
        external
        onlyWhenUnlocked
        returns (BalanceDelta swapDelta)
    {
        PoolId id = key.toId();
        if (reverts[id]) revert PoolReverts();
        if (params.amountSpecified >= 0) revert ExactOutputUnsupported();
        uint160 limit = params.sqrtPriceLimitX96;
        if (params.zeroForOne ? limit <= TickMath.MIN_SQRT_PRICE : (limit == 0 || limit >= TickMath.MAX_SQRT_PRICE)) {
            revert PriceLimitOutOfBounds(limit);
        }
        uint256 r = rate[id][params.zeroForOne];
        if (r == 0) revert PoolNotInitialized();

        uint256 amountIn = uint256(-params.amountSpecified);
        uint256 cap = maxFill[id][params.zeroForOne];
        if (cap != 0 && amountIn > cap) amountIn = cap;
        uint256 amountOut = amountIn * r / 1e18;
        (Currency cin, Currency cout) =
            params.zeroForOne ? (key.currency0, key.currency1) : (key.currency1, key.currency0);
        _account(cin, -int256(amountIn));
        _account(cout, int256(amountOut));

        int128 inDelta = -SafeCast.toInt128(amountIn);
        int128 outDelta = SafeCast.toInt128(amountOut);
        swapDelta = params.zeroForOne ? toBalanceDelta(inDelta, outDelta) : toBalanceDelta(outDelta, inDelta);
    }

    function sync(Currency currency) external {
        synced = currency;
        hasSynced = !currency.isAddressZero();
        reservesBefore = hasSynced ? currency.balanceOfSelf() : 0;
    }

    function settle() external payable onlyWhenUnlocked returns (uint256 paid) {
        if (!hasSynced) {
            paid = msg.value;
            _account(Currency.wrap(address(0)), int256(paid));
        } else {
            if (msg.value != 0) revert NonzeroNativeValue();
            paid = synced.balanceOfSelf() - reservesBefore;
            _account(synced, int256(paid));
            hasSynced = false;
        }
    }

    function take(Currency currency, address to, uint256 amount) external onlyWhenUnlocked {
        _account(currency, -int256(amount));
        currency.transfer(to, amount);
    }

    function _account(Currency currency, int256 change) private {
        if (delta[currency] == 0) touched.push(currency);
        delta[currency] += change;
    }
}
