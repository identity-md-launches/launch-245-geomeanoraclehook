# Vendored dependency provenance

The source input is the canonical
[Identity-md/univ4hook-start-template](https://github.com/Identity-md/univ4hook-start-template/tree/8254234c70e74de59f32ad6ff524da59a59aa52a)
at commit `8254234c70e74de59f32ad6ff524da59a59aa52a`.
`template-pin.json` records that commit and the downloaded archive's SHA-256.
All files from its `lib/` tree are ordinary vendored files. No git submodules or
network downloads are required to resolve Solidity imports. Repository metadata,
GitHub automation, environment files, and node_modules are not imported.

The template bundles forge-std and OpenZeppelin uniswap-hooks, including v4-core,
v4-periphery, OpenZeppelin Contracts, solmate, and nested dependencies. The template
commit pins the actual source bytes; no newer package release is substituted.
The oracle implementation and its Oracle library are used without modifications:

- `lib/uniswap-hooks/src/oracles/panoptic/BaseOracleHook.sol`
- `lib/uniswap-hooks/src/oracles/panoptic/libraries/Oracle.sol`
- `lib/uniswap-hooks/src/base/BaseHook.sol`

The launch test harness derives from `test/BaseHookTest.sol` in that same commit;
its generic token is replaced by the actual GEOM token and its artifact name is
updated. Root remappings additionally expose the bare `v4-core/` and
`v4-periphery/` names used by the protected checks. SPDX notices in vendored source
remain intact; original upstream licenses apply to their respective files.
