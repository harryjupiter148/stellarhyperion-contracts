# EVM governance and claim gas budgets

The Foundry regression suite reports router gas for timelock queue/execute, normal inbound
delivery, hostile-recipient claim parking, and normal or hostile claim settlement. It adds 16
governance actions and grows the inbound fixture to 32 claims. A separate settlement fixture
starts with 32 normal-recipient claims and four hostile-recipient claims, and reports batches of
10 or two respectively. Governance execution also has a separate fixture with 16 proposals queued
and matured before the measured test. Hostile cases use the local frozen-recipient token fixture.

The direct run without `--gas-report` provides the authoritative `gasleft` measurements for
cold storage and subsequent shared warmth. Foundry 1.5.1 changes measured call costs when gas
reporting is enabled; that mode is recorded separately and does not establish storage warmth.
These figures measure the local fixture, not transaction fees or live-chain estimates.

Coverage uses instrumentation and minimum IR optimization, so its gas costs do not represent
the production profile. In that explicit Foundry coverage context, the tests retain every
functional, status, balance, liability and warmth assertion and report measured gas, but do not
compare it with production gas ceilings. Ordinary tests, gas reports and snapshots continue to
enforce the unchanged calibrated ceilings. No test is skipped.

Each case has a fixed measured baseline: the larger observed direct or report-mode cost, rounded
up to the next 1,000 gas. The enforced ceiling adds the unchanged 25% tolerance. This bounds both
supported test modes while retaining the direct cold/warm evidence separately. Fixture changes
or production code changes require fresh measurements under the pinned profile.

| Case                                           | Direct gas | Report-mode gas | Baseline gas | Enforced ceiling |
| ---------------------------------------------- | ---------: | --------------: | -----------: | ---------------: |
| Queue action, cold first record                |     97,447 |         119,163 |      120,000 |          150,000 |
| Queue action, shared warm after 16             |     83,650 |         116,666 |      117,000 |          146,250 |
| Execute persisted action, cold first           |     42,041 |          63,245 |       64,000 |           80,000 |
| Execute persisted action, shared warm after 16 |     28,241 |          60,745 |       61,000 |           76,250 |
| Normal inbound, cold first                     |    116,454 |         117,642 |      118,000 |          147,500 |
| Normal inbound, shared warm                    |     68,755 |          98,031 |       99,000 |          123,750 |
| Hostile inbound parking, cold first            |    261,245 |         287,633 |      288,000 |          360,000 |
| Hostile inbound parking, shared warm after 32  |    196,167 |         253,431 |      254,000 |          317,500 |
| Normal settlement of 10, cold first            |    359,136 |         331,080 |      360,000 |          450,000 |
| Normal settlement of 10, shared warm           |    329,249 |         328,593 |      330,000 |          412,500 |
| Hostile settlement of 2, cold first            |     96,536 |         115,360 |      116,000 |          145,000 |
| Hostile settlement of 2, shared warm           |     83,037 |         112,861 |      113,000 |          141,250 |

The settlement fixture parks and funds its claims in `setUp`, before the measured test, so claim
settlement has persisted storage values rather than cheap writes to records created earlier in
the same test. Immediately before each first measured case, `vm.cool` clears account and storage
warmth for the router, token, recovery manager and provenance child. It changes no contract state.
Normal recipients have a nonzero balance at test entry for both batches.

Each second settlement batch uses different claim records that remain cold, while the router,
token and manager reuse shared state warmed by the first batch. Shared writes also have the normal
cost of repeat writes within one transaction. Both batches use equal sizes and the same recipient
behavior; assertions check their settlement status, funded liabilities and that shared warmth
reduces gas. Hostile settlement preserves all claim liabilities and unsettled records.

The governance execution fixture persists queued proposals in `setUp`, including their packed
timestamps and initial fee state. Cooling a proposal queued earlier in the same test would leave
cheap dirty storage writes and would not model a later execution transaction. Its first execution
starts cold; subsequent distinct proposal records stay cold while role, fee and other shared
state become warm.

The queue-growth and inbound fixture clears access warmth before each first queue, normal
delivery and parked-claim measurement. Subsequent growth cases share warmed state but use fresh
per-action, per-message or per-claim slots. Fixture funding, approvals, state cooling and persisted
action/claim setup are outside the measured section, which starts immediately before each router call.

Reproduce the measurements and assertions from the repository root with:

```sh
cd evm && forge test --match-contract 'Router.*GasBudgetTest' -vv
```

The auxiliary contract gas report runs the same five regression tests and ceilings:

```sh
cd evm && forge test --match-contract 'Router.*GasBudgetTest' --gas-report -vv
```

The budget suite uses the default Foundry profile pinned in `evm/foundry.toml`: Solidity 0.8.28,
Cancun, optimizer enabled with 50 runs, and `via_ir = true`. Do not compare reports from a
different compiler or optimizer profile against these ceilings.

This adds no selector, storage field, or wire-format change, so it requires no router migration or
protocol parity update. The EVM remains development-only; the active deployment remains Stellar
Testnet outbound ITS/CCTP. Passing local gas budgets is not deployment or activation evidence.
