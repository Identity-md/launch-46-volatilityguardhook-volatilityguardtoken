# Independent source review

A separate read-only reviewer examined the contracts, bootstrap math and tests during this assignment. No files were changed by the reviewer, no keys were provided, and no transactions were broadcast. This is a bounded contributor review, not a professional audit or a launch approval.

Findings:

- Medium operational/documentation limitation: volume is a leaky bucket. A 300-second interval can consume initial capacity plus refill; restricted capacity refills in 75 seconds. Architecture documentation explicitly states these semantics and does not promise a strict sliding-window cap.
- Low test gap: manager-impersonated callback-order tests did not cover an actual hostile token during settlement. Added `Reentrancy.t.sol` using a hostile token that attempts to forge a hook callback and recursively unlock the real PoolManager while settling. Both attempts fail and the authorized swap completes. This does not prove all possible malicious-token behavior safe.
- Informational: sampled EWMA can miss intraperiod reversals. Documented in the threat model.

The reviewer confirmed immutable permissions, manager authentication, zero hook deltas, per-pool state, bounded history scans, rollback, permissionless checkpoints, LP exits and native bootstrap calculations. Its independent targeted run at review time passed 15 tests (two fuzz tests at 256 runs); this predates added edge/reentrancy tests. Final builder counts are separately reported in validation.md.

No canonical launch.json was supplied to this assignment. Review of source AND canonical manifest, signed artifact linkage and subsequent publication/deployment verification remains with the assigned independent reviewer and services. No synthetic manifest fields, policy signatures, deployment receipt, GitHub URL or successful admission are invented here.

Follow-up review confirmed the final leaky-bucket documentation and bounded hostile-token test, independently rerunning that test: 1 passed, 0 failed (whole-test gas 1,324,590). No concrete action-ID or original-router ABI layout defect was identified. The cap denominator is intentionally delegated to canonical service policy rather than invented by this source assignment. Canonical-manifest review remains outstanding.
