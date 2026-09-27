# Geomean contracts

Geomean (GEOM) is a fixed-supply ERC-20. GeomeanOracleHook records standard and
truncated tick cumulatives for Uniswap v4 pools and exposes geometric mean prices
through mean ticks. This repository delivers the contract implementation, tests,
vendored dependencies, and ABI exports for the contract stage.

## Build and check

```sh
forge build
forge test
forge fmt --check
python3 tools/export_abis.py
```

Foundry pins Solidity **0.8.26**, Cancun, optimizer enabled with 200 runs, and
`bytecode_hash = "none"`. Dependencies are ordinary files in `lib/`; neither
submodules nor installation commands are needed. With the pinned compiler already
installed, build and tests work without network access. FFI and filesystem cheatcode
permissions are not enabled. Tests use fresh local PoolManagers, explicit inputs,
and no RPC, wallet, or environment configuration.

## Contracts and deployment parameters

| Parameter | Value |
| --- | --- |
| Network | Sepolia, chain ID 11155111 |
| Token artifact | `src/Geomean.sol:Geomean` |
| Token constructor arguments | None |
| Name / symbol / decimals | Geomean / GEOM / 18 |
| Supply | 1,000,000,000 GEOM = `1000000000000000000000000000` base units |
| Initial holder | Entire supply minted once to `msg.sender`, the deploying factory |
| Hook artifact | `src/GeomeanOracleHook.sol:GeomeanOracleHook` |
| Hook constructor | One `IPoolManager` argument (ABI type `address`) |
| Sepolia PoolManager literal | `0xE03A1074c86CFeDd5C142C4F04F1a1536e203543` |
| Enabled callbacks | `afterInitialize`, `beforeSwap` |
| Hook address flags / mask | `0x1080` / `0x3FFF` |
| Truncation limit | `MAX_ABS_TICK_DELTA = 9116`, literal in the base constructor call |
| Launch pool | currency0 = native ETH (`address(0)`), currency1 = deployed GEOM |
| Pool parameters | LP fee 3000 (0.30%), tick spacing 60 |

The token has no mint, burn, owner, pause, upgrade, or fee interface. The hook has
no admin or upgrade interface. All callbacks inherit `BaseHook`'s PoolManager
authorization. Every return-delta flag is disabled; beforeSwap returns zero
deltas and no fee override. The hook neither receives nor settles swap funds.
It ignores sender identity and hookData, so no router or claimed user receives
special treatment. HookData is unauthenticated and confers no authorization.

The constructor validates the address bits. The launch factory must mine a
CREATE2 salt using its **actual CREATE2 deployer address**, the final creation
bytecode, and the ABI-encoded PoolManager literal. Compilation changes or different
constructor arguments require mining again. The constructor accepts a manager
argument for local testing; services must enforce the listed Sepolia deployment
parameter. It does not prove a supplied address is a genuine PoolManager.

The supplied launch harness is retained with GEOM replacing its generic test token.
It opens at tick 138000 and seeds the supply below that price, between ticks
-887220 and 138000. Seeding consumes only GEOM, with less than 1 gwei of token dust
left by liquidity rounding. The pool holds no ETH before its first buy. These
are harness/factory launch assumptions, not constraints imposed by the hook.

## Oracle semantics

The hook extends the template's OpenZeppelin Panoptic `BaseOracleHook` unchanged.
Initialization writes observation zero and starts a one-slot ring. The first swap
at a new timestamp records the **pre-swap** pool tick. Further swaps at that
timestamp do not write again. Sepolia gives every block one timestamp, so there is
at most one observation per pool per block, including the initialization block.

For elapsed seconds `dt`, current tick `t`, and previous truncated tick `p`, a write
adds `t * dt` to the standard cumulative and
`clamp(t, p - 9116, p + 9116) * dt` to the truncated cumulative. The truncated tick
becomes that clamped value. The limit is per observation, not per second. Reads
between writes extrapolate both series using the current pool tick and the same
clamp without modifying storage. Historical reads interpolate stored cumulatives.

`consult(poolId, secondsAgo)` divides each cumulative difference over
`[now - secondsAgo, now]` by the window and rounds toward negative infinity.
It rejects a zero window, an uninitialized pool, or history older than the oldest
retained observation. `observe(secondsAgos, poolId)` is the inherited batch read;
zero is a valid sample age there. Pool state and history are independent per PoolId.
Other pools may use the hook; clients must select the factory's exact launch PoolId.

The implementation follows the base's modular uint32 timestamps and int56
cumulatives. Chronology must be monotonic, with history spanning less than 2^32
seconds (about 136 years); multiple timestamp wraps without discarding old history
are outside the oracle's model. Cumulative differences intentionally use unchecked
int56 subtraction; a valid tick multiplied by any uint32 window fits in int56.

Truncation slows responses to large tick movements. It does **not** prevent
manipulation sustained across blocks, guarantee market accuracy, or measure
liquidity. Both series may be misleading in thin or empty pools. The first swap in
a block records the previous price, and a price move is reflected over elapsed time
on subsequent reads/writes. Swap success assumes a functioning PoolManager and
sufficient transaction gas; the oracle adds no policy rejection to valid swaps.

## History operations and frontend handoff

Anyone may call `increaseObservationCardinalityNext(n, poolId)` and pay for storage
preallocation. Growth cannot shrink the ring and is limited by the uint16 API to
65535 slots. Large increases can exceed a transaction's gas budget; use modest
increments and estimate gas. A failed increase rolls back atomically. Swap writes
touch a constant number of slots, independent of the requested capacity.

From the initial one-slot ring, growth takes effect on the next write at a new
timestamp. In a partially filled larger ring, it waits until the writer reaches
the current final index. `cardinality` measures capacity, including preallocated
but uninitialized slots, and does not prove that a time window is available. Growth
does not restore overwritten history. With capacity one, each new write discards
the previous sample; an operator should grow the buffer early.

ABIs and call details are in [docs/abi](docs/abi) and [docs/ABI.md](docs/ABI.md).
For each 1h, 6h, or 24h chart window, a frontend can make one batched `observe` call
with all required sample ages for both series. For adjacent ages `a > b`, compute
the floor of `(cumulative[b] - cumulative[a]) / (a - b)` separately for each series.
For ETH and GEOM (both 18 decimals), `1.0001 ** meanTick` is GEOM per ETH;
its reciprocal is ETH per GEOM. Prices are ratios, not fiat valuations.
Use precise arithmetic for cumulative differences and floor negative divisions.

Read `observationState` before offering history or growth controls. Display
"not enough history" for `TargetPredatesOldestObservation`, and distinguish other
RPC failures. Zero state means the pool has not initialized this hook. The
inherited `observe([0], unknownPoolId)` may return zero cumulatives, so clients must
check initialization instead of treating that as price history. PoolManager swap
events and the growth event support refreshing the chart; observations have no
separate write event. Use a consistent block tag for related RPC reads.

## Handoff responsibilities

The separate manifest contribution writes `launch.json` using the constructor
and pool parameters above. Its hook `constructorArgs` must contain the PoolManager
address literal only; 9116 is source configuration, not another constructor argument.
Services own policy and signed artifact linkage, source publication, attestation,
admission, factory deployment, and verification of the live pool and deployed
bytecode. They must confirm token receipt and seeding, mine the address, and check
Sepolia's live manager before deployment.

An independent contributor must review the accepted contracts and manifest before
release. [docs/REVIEW_HANDOFF.md](docs/REVIEW_HANDOFF.md) maps the required adversarial
areas to local evidence and remaining checks. These implementation tests are not
an independent audit. Live fork rehearsal, deployment, and the static chart website
(`lab-twap-oracle-hook`, `dist/index.html`) belong to subsequent service/frontend
stages and are not claimed as completed here. Operators should monitor history
coverage, arrange permissionless capacity growth, and communicate truncation lag.

Dependency provenance is recorded in [docs/DEPENDENCIES.md](docs/DEPENDENCIES.md).
