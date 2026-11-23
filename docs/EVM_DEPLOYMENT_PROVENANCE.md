# EVM deployment and provenance

The normal production build uses Solidity `0.8.28+commit.7893614a`, Cancun, optimizer enabled
with 50 runs and `viaIR=true`. Deployment and verification read these settings from the
actual compiled artifact metadata; environment labels alone cannot certify the build.
Foundry uses the same profile locally and in CI, with additional CI fuzz and invariant runs.

The ordinary full build measured the following sizes with this two-child recovery implementation.
Initcode includes the actual constructor arguments: 192 bytes for the router, none for provenance,
and 32 bytes for the recovery manager.

| Contract             | Runtime bytes | Deployment initcode bytes |
| -------------------- | ------------: | ------------------------: |
| HyperionRouter       |        24,552 |                    42,728 |
| OutboundProvenance   |        12,155 |                    12,243 |
| TokenRecoveryManager |         4,249 |                     4,524 |

The router has 24 bytes of runtime headroom. Rebuild and remeasure all three contracts after
source changes and before deployment; preserve the 24,576-byte EIP-170 runtime and
49,152-byte EIP-3860 initcode limits.

## Immutable support contracts

The router constructor creates `OutboundProvenance` at CREATE nonce `1` and
`TokenRecoveryManager` at nonce `2`. Both children are immutably bound to their creating router.
The provenance child handles read-only action validation, typed hashing/recovery, quotes,
exact outbound amounts, address parsing, refusal classification and historical records. The
recovery manager tracks outstanding claim liabilities and owns the separate timelocked
accidental-token recovery surface; it cannot transfer tokens itself. Only the creating router
can write child accounting, and the router accepts recovery callbacks only from its manager.

The deployment record includes each child's address and runtime code hash. Deployment and
verification derive both addresses from the router address and CREATE nonce, check deployed code,
and confirm each child's `ROUTER` binding. The manager uses the router's admin/guardian roles and
current timelock delay; it introduces no independent privileged key.

The existing router selectors and return schemas remain available. `completeTokenRecovery` is
an additive manager-only callback; recovery scheduling and reads are on the separate manager.
`checkDestination` uses a static call to the provenance child's unchanged pure Stellar parser;
its ABI mutability remains `view`. It forwards the exact fixed 96-byte account/key/muxed-id tuple
and full validation errors without a second ABI codec. The method is external, so return forwarding
cannot terminate an internal Solidity caller.
`quoteV2`, `quoteAll` and `outboundRecord` perform static calls and forward the child's exact ABI return or
revert bytes through a documented memory-safe assembly block, avoiding an extra decode and
encode of the destination strings.

`quoteV2` is declared `external` so forwarding its return data cannot terminate an internal
Solidity caller. Its external selector and return schema are unchanged. Derived contracts must
use an external call instead of an unqualified internal `quoteV2(...)` call.

## Historical storage and atomic accounting

Each successful outbound call commits one record containing the authenticated sender,
token, actual gross debit, fee, net amount, route, adapter, destination and provider reference.
Only the creating router can commit. Nonce zero and replacement of an existing record fail;
an absent nonce returns a zero-valued record. Records are append-only and have no pruning
or migration endpoint.

Storage grows with successful dispatch count. Each record has nine fixed storage slots;
each destination string of at least 32 bytes adds `ceil(length / 32)` data slots. Short strings
fit in their fixed slot. The test destination uses a short chain name and a 56-byte Stellar
address, requiring eleven slots per record. Storage writes add per-transfer gas, while
retrieval adds one static call; quote and action validation also add calls to the immutable
module and its router state getters. Gas measurements should distinguish first/cold calls
from later calls in the same transaction.

The current ordinary full-suite and focused router gas reports both measure deployment of the
router and its two children. The direct provenance fixture measures standalone child deployment
and its minimal commit; the dispatch fixture measures the child read and two outbound calls.
Those outbound calls occur in one test transaction and include mock provider accounting and
provenance. The table labels each report's scope; these are local fixture measurements, rather
than a live-chain fee quote. Nested child creation is included in the router deployment cost.

| Measurement                                                   |       Gas |
| ------------------------------------------------------------- | --------: |
| Router deployment, including both children (full and focused) | 9,132,656 |
| Direct child deployment in the append-only test               | 2,679,886 |
| First outbound in the conservation fixture                    |   721,202 |
| Subsequent outbound in the same test                          |   489,536 |
| Router historical-record read, maximum (full suite)           |    31,390 |
| Child historical-record read, maximum (dispatch fixture)      |    26,207 |
| Successful child commit, maximum in the minimal record test   |   105,691 |

Reproduce these reports with `FOUNDRY_GAS_REPORTS='["HyperionRouter","OutboundProvenance"]'
forge test --match-test test_provenanceStorageGasCostIsMeasuredPerDispatch --gas-report -vv`
and `FOUNDRY_GAS_REPORTS='["OutboundProvenance"]' forge test --match-contract
OutboundProvenanceTest --gas-report -vv` from `evm`. The minimal commit fixture has fewer
populated fields and shorter strings than a successful router dispatch; its direct child read
maximum is 21,763 gas. Its standalone child deployment costs 2,679,886 gas and 12,243 bytes of
initcode. A nested child creation shown as zero in a report is already included in the router’s
deployment accounting, and is not a zero-cost deployment.

Exact token accounting checks sender debit, router receipt, treasury fee, adapter receipt,
inbound pull and successful claim payout. Decimal dust remains with the sender. Dispatch,
record commit, events and native refund share one EVM transaction, so a downstream failure
or failed direct refund reverts all of them, including nonces and flow allowance. Conservation
tests count aliased addresses once and cover both paid rails, retained dust, native remainder
and deliberately injected mismatches.

This layout applies to a fresh, nonupgradeable router deployment. It does not migrate records
or state from an existing router. `_queuedAdapterCodeHash` uses the former private provenance
mapping position in that fresh layout, with subsequent router slots retained; an in-place
upgrade or storage migration would require a separate design and review.

## Adapter identity limits

Queueing an adapter requires deployed code, an exact canonical `ROUTER()` address, the
requested `route()` and a canonical boolean from `supportsChain(string)`. A discoverable
nonzero `implementation()` is rejected. The router captures runtime code hash at queueing,
checks it again at execution, records the installed hash and checks it before outbound use.

Runtime hash verifies the deployed shell. It cannot reveal an ERC-1967 implementation slot
or certify hidden proxy upgrade controls: a regression test changes the implementation while
preserving shell code hash. Admission therefore requires independent review of candidate
implementation, mutability and governance. A passing shell hash alone is insufficient
activation evidence.

## Verification

Run `forge build --sizes`, `forge test` and `npm run lint` from `evm`, using the pinned
toolchain. `RouterAdapterIdentityTest`, `OutboundProvenanceTest`,
`RouterProvenanceConservationTest`, `RouterTransferIntentTest` and the deployment script
regressions exercise these boundaries. `script/anvil-e2e.sh` additionally rehearses actual
local deployment, timelock execution, artifact/chain verification, deterministic provider
failure and retry on both rails, and a CCTP transfer. Local rehearsal does not activate a live
EVM route.
