# VolatilityGuard Lab

Standalone Sepolia contract source submission: immutable `VolatilityGuardHook` and fixed-supply `VolatilityGuardToken` (VGL). No website, IPFS upload, deployed helper, keys, or worker broadcast.

```sh
forge build --offline
forge test --offline
forge fmt --check
python3 scripts/check_vendor.py
python3 scripts/export_abis.py --check
```

Toolchain: Foundry 1.7.1, Solidity 0.8.26 (installed in the verifier's compiler cache), Cancun, optimizer 200, no CBOR metadata, `bytecode_hash = "none"`. Solidity dependencies are vendored as ordinary files, pinned in `docs/dependencies.json`. No FFI, filesystem cheatcode permissions, submodules, package manager, or test RPC dependency. Formatting excludes unmodified vendor files. `src/BootstrapMath.sol` and `src/HookFlags.sol` are internal libraries, not launch deployments.

Read [architecture and threat model](docs/architecture.md), [integration and launch handoff](docs/integration.md), [validation evidence](docs/validation.md), and [independent source review](docs/review.md). Exported implementation ABIs are in `artifacts/abis/`.

This assignment submits source for acceptance. The separate control-plane assignment supplies `launch.json`. Its independent canonical-manifest review, accepted publication, signed artifact linkage, attestation, admission, verified factory deployment, and operator assessment are service responsibilities. Nothing here asserts those future steps passed.
