# Architecture and threat model

VGL is an ordinary fixed-supply ERC20: 18 decimals, 10^27 base units (one billion tokens), minted once to its constructor caller. Transfers have no tax, wallet cap, lock, pausing, owner, upgrade, or mint selector. Infinite allowances remain unchanged. The factory/service implements allocation and contributor escrow policy; the token does not impersonate those controls.

The hook accepts any ordered v4 currency pair, including native currency zero. It never reads decimals, transfers assets, settles debts, takes funds, creates claims, calls routers, or alters fees. Its only external reads are immutable PoolManager `extsload` calls via pinned StateLibrary. Unsupported fee-on-transfer/rebasing/blocklisted currencies can still violate core settlement assumptions: arbitrary addresses does not imply compatibility with every token behavior.

Each full PoolId owns an independent Guard containing timestamps, cumulative tick integral, 16 observations, EWMA, mode and consumed volume budget. Enabled flags are afterInitialize (4096), beforeSwap (128), afterSwap (64): **4288 / 0x10c0**. All other flags, including every return-delta bit and LP callback, are false. Constructor validates the deployed address bits; there is no virtual bypass. The configured immutable manager must have code. Production construction must bind the canonical Sepolia manager through service verification; generic manager injection is intentionally available for local tests.

All three enabled callbacks authenticate `msg.sender`; neither `sender` nor `hookData` grants identity or privileges. PoolKey.hooks must equal this hook. A global pending record binds a before/after swap pair to its PoolId, captures pre-swap price/liquidity/reference/limit, and rejects nested callbacks and checkpoints during that pair. The record is cleared after accounting. Later settlement occurs in PoolManager; its unlock/debt invariants remain authoritative. Router and token callbacks cannot fabricate manager authentication. This is not a general ban on composable core operations during unlock.

## Oracle and limits

The tick integral advances using the previous post-swap tick for the elapsed seconds, before assigning the current tick. Multiple swaps in one timestamp cannot manufacture elapsed oracle time. An observation is written at most once per 30 seconds. The 16-entry ring retains at least 450 seconds when full; scans visit at most 16 entries. The TWAP targets 300 seconds, choosing the newest retained predecessor at or before that cutoff, or the oldest available observation during warmup. Sparse observations can lengthen the window (up to approximately 1200 seconds between stale resets); a boundary never discards the sole historical reference. Negative tick means round toward negative infinity. With no elapsed sample history the reference is the current initialized tick. This is an internal geometric-price TWAP, not an external fair-value oracle. `status` returns stored checkpoint state, not an automatically refreshed live quote.

At most once per 30 seconds EWMA becomes `floor((7*old + min(abs(tick-sampleTick),2000))/8)`. Units are ticks, an absolute-movement volatility proxy, not annualized standard deviation or variance. Intermediate reversals can cancel; callers choose observation timing subject to the 30s minimum. Timestamp and sampling manipulation remain limitations.

NORMAL permits a tick distance of `min(200,40+2*EWMA)`. Other modes permit 30. Both pre-price versus historical reference, and post-price versus the captured reference and pre-price, must satisfy the limit. One tick represents a factor of 1.0001 in raw currency1/currency0 price. Bounds are symmetric in log price, not exactly symmetric percentages. Exact input has negative amountSpecified; exact output has positive. Either direction works. Requested magnitude is limited to int128.max and zero is rejected. Core's partial fills remain possible; router-level min output/max input and deadline are still essential.

Volume uses realized core BalanceDelta, including gross input fees, rather than requested size or caller identity. For pre-price S (Q96) and absolute base-unit deltas a0,a1:

```
v0 = ceil(a0*S/2^96)
v1 = ceil(a1*2^96/S)
L = min(preLiquidity, postLiquidity), except a zero preLiquidity uses postLiquidity
cost = ceil(max(v0,v1)*10^6/L)
```

Each quantity v is in liquidity units. Intermediate and final rounding are upward, so tiny split trades pay at least as much rounding overhead. FullMath avoids multiplication overflow; extreme ratios that cannot fit its result revert safely. PostLiquidity must be at least 1000. Nonzero preLiquidity below 1000 refuses swaps. Zero preLiquidity is allowed only subject to valid postLiquidity and all price and volume limits, permitting token-only range entry. A distant or empty range cannot be jumped past the price limits. The raw liquidity minimum is a numerical floor, not a dollar liquidity guarantee.

The rolling budget is specifically a **leaky bucket**, not a strict sliding-window sum. Before each swap/checkpoint, debt decays by `floor(elapsed*20000/300)` ppm, never below zero; each successful swap adds cost. NORMAL capacity is 20,000 ppm; other modes 5,000 ppm. Refill is the same in every mode. Thus a normal 300s interval can consume approximately 40,000 ppm including initial burst and replenishment, and a full restricted bucket refills in 75s. Timestamp splitting loses fractional refill; opposite-direction trades, wallets, routers and hookData all consume the same debt without netting. Same-block splitting cannot refresh it. This is a depth-normalized gross-flow limiter, not a fixed raw-token volume ceiling. Adding liquidity can make subsequent volume cheaper; JIT liquidity is not prevented.

## State and liveness

Initialization always records WARMUP without requiring liquidity. A refresh after more than 900 seconds without a successful refresh resets the ring at the unchanged core price and enters GUARDED. Low active liquidity, EWMA >100, or spot/reference separation >200 is unhealthy: GUARDED and a restarted healthy timer. Healthy WARMUP reaches NORMAL after 120s; healthy GUARDED reaches RECOVERY after 120s; healthy RECOVERY reaches NORMAL after a further 120s. Recovery is permissionless and deterministic, driven by successful swaps or `checkpoint(key)` calls. Recovery history can mature while idle. Guarded modes still admit small bounded swaps, rather than imposing a discretionary shutdown. After low liquidity is restored, call checkpoint and allow the timers to mature.

A reverting swap rolls back the manager trade, integral changes, budget and pending record. **A rejected trade does not persist a breaker transition or event.** Anyone may checkpoint separately to persist observable stale/low-liquidity/volatility health. A one-off rejected attack does not permanently halt other users. LP additions, fee collection and exits have no hook gate in any mode, including zero liquidity. Core token transfer failures or out-of-range price protections can still prevent swaps; these are not withdrawal locks.

## Residual risks

Internal price manipulation, gradual TWAP drift, sandwiches inside limits, ordering/MEV, validator timestamps, permissionless consumption of the shared budget, token failures, sudden LP withdrawals, front-run initialization and JIT liquidity remain possible. Attackers can impose trading delays; LPs retain core exits. An LP's inventory is the first-loss asset exposed to adverse selection and price changes; VGL holders have no redemption claim on treasury or LP assets. There is no peg, guaranteed exit value, total MEV protection, yield promise, discretionary admin, or rescue mechanism.

Work per hook call is constant except at most two scans of 16 observations and fixed storage reads/writes. PoolManager itself may traverse initialized ticks; hook bounded work is not a universal gas cap for a routed transaction. Compiler integer checks reject overflow. Stored cumulative int128 is ample for int24 ticks over uint64-era timestamps. No privileged maintenance is required.
