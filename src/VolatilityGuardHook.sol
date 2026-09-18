// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "v4-core/src/types/BeforeSwapDelta.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {FullMath} from "v4-core/src/libraries/FullMath.sol";

/// @notice Immutable pool-local risk limits. No custody, fee overrides, identities or admin.
contract VolatilityGuardHook {
    using StateLibrary for IPoolManager;
    uint160 public constant FLAGS = (1 << 12) | (1 << 7) | (1 << 6);
    uint256 public constant WINDOW = 300;
    uint256 public constant STALE = 900;
    uint128 public constant MIN_LIQUIDITY = 1000;
    uint256 private constant Q96 = 1 << 96;
    IPoolManager public immutable poolManager;
    enum Mode {
        NORMAL,
        WARMUP,
        GUARDED,
        RECOVERY
    }

    struct Observation {
        uint64 time;
        int128 cumulative;
    }

    struct Guard {
        uint64 last;
        uint64 sampleTime;
        uint64 since;
        uint64 volumeTime;
        int24 tick;
        int24 sampleTick;
        uint24 ewma;
        uint8 head;
        uint8 count;
        Mode mode;
        int128 cumulative;
        uint32 used;
        bool initialized;
        Observation[16] observations;
    }

    struct Pending {
        PoolId id;
        uint160 price;
        uint128 liquidity;
        int24 tick;
        int24 referenceTick;
        uint24 limit;
        bool active;
    }
    mapping(PoolId => Guard) private guards;
    Pending private pending;
    error Unauthorized();
    error InvalidManager();
    error InvalidPool();
    error Uninitialized();
    error CallbackOrder();
    error InvalidAmount();
    error LowLiquidity();
    error PriceDeviation(uint256 deviation, uint256 limit);
    error VolumeBudget(uint256 used, uint256 cap);
    event ModeChanged(PoolId indexed id, Mode mode);
    event Observed(PoolId indexed id, int24 tick, int24 twap, uint24 ewma);

    constructor(IPoolManager manager) {
        if (address(manager) == address(0) || address(manager).code.length == 0) revert InvalidManager();
        poolManager = manager;
        Hooks.validateHookPermissions(IHooks(address(this)), getHookPermissions());
    }

    modifier onlyManager() {
        if (msg.sender != address(poolManager)) revert Unauthorized();
        _;
    }

    function getHookPermissions() public pure returns (Hooks.Permissions memory p) {
        p.afterInitialize = true;
        p.beforeSwap = true;
        p.afterSwap = true;
    }

    function afterInitialize(address, PoolKey calldata key, uint160, int24 tick) external onlyManager returns (bytes4) {
        _key(key);
        if (pending.active) revert CallbackOrder();
        Guard storage g = guards[key.toId()];
        if (g.initialized) revert InvalidPool();
        g.initialized = true;
        _reset(g, tick);
        g.mode = Mode.WARMUP;
        emit ModeChanged(key.toId(), g.mode);
        return IHooks.afterInitialize.selector;
    }

    /// @notice Anyone may persist a health transition, including after a reverted swap.
    function checkpoint(PoolKey calldata key) external {
        _key(key);
        if (pending.active) revert CallbackOrder();
        (, int24 tick,,) = poolManager.getSlot0(key.toId());
        _refresh(key.toId(), tick, poolManager.getLiquidity(key.toId()));
    }

    function beforeSwap(address, PoolKey calldata key, SwapParams calldata params, bytes calldata)
        external
        onlyManager
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        _key(key);
        if (pending.active) revert CallbackOrder();
        // Manager accounting is int128; reject pathological requests before taking absolute values.
        if (
            params.amountSpecified == 0 || params.amountSpecified > type(int128).max
                || params.amountSpecified < -int256(type(int128).max)
        ) revert InvalidAmount();
        PoolId id = key.toId();
        (uint160 price, int24 tick,,) = poolManager.getSlot0(id);
        uint128 liquidity = poolManager.getLiquidity(id);
        _refresh(id, tick, liquidity);
        Guard storage g = guards[id];
        uint24 limit = g.mode == Mode.NORMAL ? uint24(_min(200, 40 + uint256(g.ewma) * 2)) : 30;
        int24 refTick = _twap(g);
        _check(tick, refTick, limit);
        if (liquidity != 0 && liquidity < MIN_LIQUIDITY) revert LowLiquidity();
        pending = Pending(id, price, liquidity, tick, refTick, limit, true);
        return (IHooks.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
    }

    function afterSwap(address, PoolKey calldata key, SwapParams calldata params, BalanceDelta delta, bytes calldata)
        external
        onlyManager
        returns (bytes4, int128)
    {
        _key(key);
        PoolId id = key.toId();
        Pending memory p = pending;
        if (!p.active || PoolId.unwrap(p.id) != PoolId.unwrap(id)) revert CallbackOrder();
        (, int24 tick,,) = poolManager.getSlot0(id);
        _check(tick, p.referenceTick, p.limit);
        _check(tick, p.tick, p.limit);
        uint128 liquidity = poolManager.getLiquidity(id);
        if (liquidity < MIN_LIQUIDITY) revert LowLiquidity();
        if (p.liquidity != 0 && p.liquidity < liquidity) liquidity = p.liquidity;
        int128 d0 = delta.amount0();
        int128 d1 = delta.amount1();
        if (params.zeroForOne ? (d0 > 0 || d1 < 0) : (d1 > 0 || d0 < 0)) revert InvalidAmount();
        uint256 v0 = FullMath.mulDivRoundingUp(_abs(d0), p.price, Q96);
        uint256 v1 = FullMath.mulDivRoundingUp(_abs(d1), Q96, p.price);
        uint256 cost = FullMath.mulDivRoundingUp(v0 > v1 ? v0 : v1, 1e6, liquidity);
        Guard storage g = guards[id];
        uint256 cap = g.mode == Mode.NORMAL ? 20_000 : 5_000;
        uint256 used = uint256(g.used) + cost;
        if (used > cap) revert VolumeBudget(used, cap);
        g.used = uint32(used);
        // Integrals were advanced using the pre-swap tick. Post-swap tick applies only to future time.
        g.tick = tick;
        delete pending;
        return (IHooks.afterSwap.selector, 0);
    }

    function status(PoolId id) external view returns (Mode mode, uint24 ewma, uint32 used, int24 twap, uint8 count) {
        Guard storage g = guards[id];
        if (!g.initialized) revert Uninitialized();
        return (g.mode, g.ewma, g.used, _twap(g), g.count);
    }

    function _key(PoolKey calldata key) private view {
        if (address(key.hooks) != address(this)) revert InvalidPool();
    }

    function _reset(Guard storage g, int24 tick) private {
        g.last = uint64(block.timestamp);
        g.sampleTime = g.last;
        g.since = g.last;
        g.tick = tick;
        g.sampleTick = tick;
        g.cumulative = 0;
        g.head = 0;
        g.count = 1;
        g.observations[0] = Observation(g.last, 0);
        g.ewma = 0;
    }

    function _refresh(PoolId id, int24 tick, uint128 liquidity) private {
        Guard storage g = guards[id];
        if (!g.initialized) revert Uninitialized();
        uint256 elapsed = block.timestamp - g.last;
        uint256 refill = (block.timestamp - g.volumeTime) * 20_000 / WINDOW;
        g.used = refill >= g.used ? 0 : uint32(g.used - refill);
        g.volumeTime = uint64(block.timestamp);
        if (elapsed > STALE) {
            _reset(g, tick);
            _mode(id, g, Mode.GUARDED);
        } else {
            g.cumulative += int128(int256(g.tick) * int256(elapsed));
            g.last = uint64(block.timestamp);
            g.tick = tick;
            if (block.timestamp - g.sampleTime >= 30) {
                uint256 movement = _distance(tick, g.sampleTick);
                g.ewma = uint24((uint256(g.ewma) * 7 + _min(movement, 2000)) / 8);
                g.sampleTick = tick;
                g.sampleTime = g.last;
                g.head = (g.head + 1) % 16;
                if (g.count < 16) ++g.count;
                g.observations[g.head] = Observation(g.last, g.cumulative);
            }
        }
        int24 mean = _twap(g);
        bool unhealthy = liquidity < MIN_LIQUIDITY || g.ewma > 100 || _distance(tick, mean) > 200;
        if (unhealthy) {
            _mode(id, g, Mode.GUARDED);
            g.since = uint64(block.timestamp);
        } else if (block.timestamp - g.since >= 120) {
            if (g.mode == Mode.GUARDED) _mode(id, g, Mode.RECOVERY);
            else if (g.mode == Mode.RECOVERY || g.mode == Mode.WARMUP) _mode(id, g, Mode.NORMAL);
        }
        emit Observed(id, tick, mean, g.ewma);
    }

    function _mode(PoolId id, Guard storage g, Mode mode) private {
        if (g.mode != mode) {
            g.mode = mode;
            g.since = uint64(block.timestamp);
            emit ModeChanged(id, mode);
        }
    }

    // Target a 300-second window, retaining its predecessor rather than discarding
    // history at the boundary. With sparse calls this is a longer, conservative window.
    function _twap(Guard storage g) private view returns (int24) {
        Observation memory best = g.observations[g.head];
        uint256 cutoff = g.last > WINDOW ? g.last - WINDOW : 0;
        bool predecessor;
        for (uint256 i; i < g.count; ++i) {
            Observation memory o = g.observations[i];
            if (o.time <= cutoff) {
                if (!predecessor || o.time > best.time) best = o;
                predecessor = true;
            } else if (!predecessor && o.time < best.time) {
                best = o;
            }
        }
        uint256 duration = g.last - best.time;
        if (duration == 0) return g.tick;
        int256 sum = int256(g.cumulative) - best.cumulative;
        int256 mean = sum / int256(duration);
        if (sum < 0 && sum % int256(duration) != 0) --mean;
        return int24(mean);
    }

    function _check(int24 tick, int24 referenceTick, uint256 limit) private pure {
        uint256 diff = _distance(tick, referenceTick);
        if (diff > limit) revert PriceDeviation(diff, limit);
    }

    function _distance(int24 a, int24 b) private pure returns (uint256) {
        return _abs(int256(a) - b);
    }

    function _abs(int256 value) private pure returns (uint256) {
        return uint256(value < 0 ? -value : value);
    }

    function _min(uint256 a, uint256 b) private pure returns (uint256) {
        return a < b ? a : b;
    }
}
