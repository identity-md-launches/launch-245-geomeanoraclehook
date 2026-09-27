# Contract ABI reference

`abi/Geomean.json` and `abi/GeomeanOracleHook.json` are complete JSON ABI arrays
exported from Solidity 0.8.26 build artifacts. Regenerate after any contract change:

```sh
forge build
python3 tools/export_abis.py
```

## Geomean

Constructor: `constructor()`; mints exactly `1_000_000_000 * 10**18` units to its caller.
Standard ERC-20 metadata, balances, allowances, `transfer`, `approve`, and
`transferFrom` are available. `TOTAL_SUPPLY()` returns the fixed issue size.
Transfers emit `Transfer`; approvals emit `Approval`. Errors use OpenZeppelin's
ERC-6093 errors. There is no post-construction mint or burn endpoint.

## GeomeanOracleHook

Constructor: `constructor(address manager)`; the address is typed `IPoolManager`
in Solidity. It calls `BaseOracleHook(9116)` and inherits address validation.

| Function | Result / use |
| --- | --- |
| `consult(bytes32 poolId, uint32 secondsAgo)` | `(int24 meanTick, int24 truncatedMeanTick)`; both floor-rounded |
| `observe(uint32[] secondsAgos, bytes32 poolId)` | `(int56[] standard, int56[] truncated)` in the caller's input order |
| `observationState(bytes32 poolId)` | `(uint16 index, uint16 cardinality, uint16 cardinalityNext)` |
| `stateById(bytes32 poolId)` | The inherited getter for the same state tuple |
| `observationsById(bytes32 poolId, uint256 index)` | `(uint32 blockTimestamp, int24 prevTruncatedTick, int56 tickCumulative, int56 tickCumulativeTruncated, bool initialized)` |
| `increaseObservationCardinalityNext(uint16 n, bytes32 poolId)` | Permissionless storage preallocation; no return value |
| `MAX_ABS_TICK_DELTA()` | `int24`, 9116 |
| `poolManager()` | Immutable manager address |
| `getHookPermissions()` | Fourteen booleans; only afterInitialize and beforeSwap are true |

`PoolId` is `keccak256(abi.encode(currency0, currency1, fee, tickSpacing, hooks))`
using the exact ordered PoolKey, with currency fields and hooks ABI-encoded as
addresses. Native ETH is `address(0)`; no WETH address is substituted.

Example ages for one mean: `[3600, 0]`. For a full one-hour chart, batch ages such
as `[3600, 3540, ..., 60, 0]` into a single call, then use adjacent cumulative
differences. Both series are returned by the same call. A window including an
unavailable sample reverts the whole batch.

`IncreaseObservationCardinalityNext(bytes32 indexed underlyingPoolId, uint16 old,
uint16 new)` emits only when the requested capacity increases. It reports requested
capacity, not the amount of historical data or time coverage.

Expected errors:

- `ZeroWindow()`: consult requested zero seconds.
- `PoolNotInitialized()`: consult or growth names an uninitialized oracle pool.
- `TargetPredatesOldestObservation(uint32 oldestTimestamp, uint32 targetTimestamp)`:
  a requested sample is older than retained history.
- `NotPoolManager()`: an unauthorized caller invoked a callback.
- `HookAddressNotValid(address)`: constructor address bits do not match permissions.
- `HookNotImplemented()`: the manager directly called a disabled callback.

The full inherited IHooks callback ABI is exported for tooling compatibility.
Only the enabled callbacks are used by v4; applications should use the read and
growth functions above. No callback should be invoked directly by a user.
