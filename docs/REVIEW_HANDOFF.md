# Implementation evidence for independent review

This is an implementation handoff, not an independent review or deployment approval.
The separate reviewer should inspect the final source, dependencies, compiler
configuration, ABI exports, and manifest. Services supply policy and signed artifact
linkage; their absence at the source stage is not a constructor or authorization
defect. Concrete disagreements in code, arguments, permissions, or pool configuration
remain findings.

| Required attack area | Local evidence | Independent review focus |
| --- | --- | --- |
| Truncation arithmetic | Wide-int256 reference fuzzing over full v4 ticks, arbitrary uint32 elapsed time, and int56 cumulatives; full-range real manager swaps both ways | Ensure tick differences cannot wrap int24 for valid v4 ticks; distinguish per-write limits from time limits and multi-block manipulation |
| Negative rounding | Real negative-price pool produces -302/3, expected -101; exact negative quotients are unchanged | Both consult outputs must floor, including fractional negative means |
| uint32 wrap | Real swaps on both sides of 2^32; interpolation, oldest-history rejection; uint32-window and cumulative-overflow fuzzing | One-wrap chronology assumptions, modular cumulative subtraction, long inactive pools |
| beforeSwap reverting | Token-only seed and first buy; buy/sell/withdraw; huge price moves; exact-input/output settlement comparisons; failed settlement rollback | Manager-only entry, no data decoding or admin dependencies, zero deltas/override, legitimate manager and gas assumptions |
| Growth griefing | Failed low-gas growth rolls back; third-party growth, no shrink, ring overwrite and delayed expansion; 1024-slot buffer writes stay below 100000 gas | Caller's storage costs, atomic OOG failure, constant-work swaps, 65535-slot bound, read cost and partial initialization |

Additional checks cover fixed token supply and authorization failures, all fourteen
permission flags, actual CREATE2 deployment and bad-address rejection, pool history
isolation, standard/truncated hand calculations, same-block observation suppression,
runtime size, and forbidden opcodes in compiled runtime. Production inherits the
unmodified OpenZeppelin BaseOracleHook callbacks; the test-only cumulative injector
is under `test/` and is not a deployment artifact.

The local baseline check can be reproduced using the supplied protected tests with
only environment-provided creation code, flags, decimals, and manager substituted
by this build's constants. Scratch copies are not shipped. This does not replace
the contributor network's own admission checks against its attested creation code.

Before release, the independent reviewer/services should verify the actual factory's
init code and mined salt, the Sepolia manager and factory lifecycle on a fork, the
exact manifest arguments, and the accepted artifacts. Review history growth plans
for 1h/6h/24h chart coverage. Cardinality starts at one and is not a time guarantee.
No live deployment, production fork result, independent review, or service signature
is asserted by this repository.
