# Validation evidence

Final builder validation on 2026-09-18 UTC, Foundry 1.7.1 (`4072e48705af9d93e3c0f6e29e93b5e9a40caed8`), solc 0.8.26, Cancun, optimizer 200, metadata disabled. Offline commands use the installed Solidity compiler toolchain; all imported Solidity dependencies are delivered. No FFI, filesystem permissions, RPC, deployed helper, or secrets are used by tests.

| Check | Actual result |
|---|---|
| `forge build --offline` | Pass; lint warnings remain, described below |
| `forge test --offline` | 28 passed, 0 failed, 0 skipped, 5 suites |
| Fuzz | 3 functions, 256 cases each (768 generated cases); seed 0x76676c |
| Invariant | 2 invariants, each 64 runs × 64 depth = 4096 calls; handler catches rejected swaps |
| Stress | 160 real-manager alternating swaps with advancing timestamps; ring remains 16 entries |
| Supplied protected checks | 9 passed (3 hook, 6 token), 0 failed, 0 skipped; separate run |
| `forge fmt --check` | Pass after second formatting pass |
| ABI export comparison | Both implementation ABI files match forge inspect |
| Vendor verification | 177 delivered files match SHA-256 inventory after final formatting; contents also compared to pinned upstream tarballs |

The 28 delivered tests consist of 19 guard tests, 5 token tests, 1 native bootstrap test, 1 hostile-token test and 2 stateful invariants. Raw outputs: [tests](evidence/tests.txt), [gas report](evidence/gas-report.txt), [build](evidence/build.txt), [protected checks](evidence/protected-tests.txt). The protected files were copied unchanged into temporary test/scratch paths, supplied exact compiled creation code and configured Sepolia manager address/4288 flags/18 decimals, run, then removed. Protected manager etching tests only permissions/runtime/authentication; real lifecycle tests use a normally deployed manager. These builder results are evidence, not independent service acceptance.

Coverage includes real manager settlement and balance conservation; both exact-input and exact-output directions; zero/oversized requests; arbitrary pool fee isolation; initialization at extreme sqrt prices; ignored caller identities; unauthorized enabled callbacks; callback order and wrong PoolId; failed-trade rollback; opposite-direction split volume; timed refill; EWMA and historical tick integral; ring boundary retention and overwrite; stale reset, deterministic recovery and LP exits; numerical low-liquidity refusal; allowance and fixed supply; token-only bootstrap and reverse-liquidity dependency. Stateful invariants assert token conservation including manager inventory and hook non-custody, ring/count/EWMA/debt caps. The invariant handler catches rejected swaps, so its reported zero handler reverts does **not** mean every generated trade succeeded. It does not exhaustively prove all pool states or all ERC20 behaviors.

Observed gas, not deployment spending estimates:

- Hook deployment: 1,605,540 gas, 8,752 creation-bytecode bytes excluding constructor args; 8,011 runtime bytes (below EIP-170).
- Token deployment: 363,304 gas; 1,425 creation bytes; 1,317 runtime bytes.
- Gas-report direct beforeSwap samples: maximum 120,798; afterSwap maximum 32,963. These small direct-call samples include negative tests and are **not** exhaustive worst-case callback bounds. Nested full swaps include manager, storage, settlement and router overhead; consult raw gas report/trace when estimating a real transaction.
- Native seed/buy/sell/exit whole-test: 923,287 gas. Hostile-token whole-test: 1,324,590 gas.
- Ring stress whole-test is roughly 20 million gas across 160 operations, not one production swap.

No protocol-level callback gas ceiling is promised. The test router and all mocks are local harnesses; production uses existing periphery. Factory deployment, salt search, contributor escrow and production periphery costs are absent from these figures. The service must independently estimate the complete authorized launch under the 0.3 Sepolia ETH spending cap.

Failures and repairs during development: splitting test fixtures initially omitted an inherited using directive (compiler failure, repaired); the first formatter pass was not a fixed point for three test files (second pass repaired, rechecked). No behavioral test failure remains. Lint reports timestamp dependence and narrowing casts. Timestamp dependence is intrinsic to this oracle and recovery model; casts are bounded by caps, core tick bounds and practical timestamp range, but this is not a formal proof. No static analyzer or formal verification was run.

Independent source review and follow-up are recorded in [review.md](review.md). Canonical-manifest review and launch acceptance are not complete in this assignment because that artifact belongs to the separate control-plane assignment. Official documentation confirms the requested Sepolia manager address; live RPC/explorer requests were forbidden (HTTP 403), so no live bytecode comparison, fork rehearsal, deployed-source verification, publication URL, transaction receipt, funded-wallet or launch success is asserted. Internal TWAP drift, intra-sample reversals, budget griefing, JIT liquidity, sandwiching within bounds and token incompatibilities remain explicit limitations.
