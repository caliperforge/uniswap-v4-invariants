# Design notes

Companion to the README and coverage map. Reads as an engineering note for a
reviewer who is deciding whether to adopt or fund the harness. Nothing here
overrides the README, the coverage map, or the case READMEs; if a claim in
this file drifts from any of them, primary source wins.

## 1. What this is

A defender-side invariant test harness for Uniswap v4 hooks, running against
the real `v4-core` `PoolManager` (pinned submodule, no mocks, no forks). Four
recurring hook bug classes ship as same-source clean/planted twin pairs, and
CI runs both legs on every commit. The clean twin encodes what a correctly
written hook does; the planted twin encodes a single-hunk seeded specification
violation on that same source. Every invariant here has a standing receipt in
CI that it catches the class it claims to catch.

## 2. Why these four classes first

Selection was driven by three inputs, in this order.

First, the coverage map (`docs/coverage_map.md`). Each candidate class was
checked against six free public comparators (Uniswap v4-core / v4-periphery
suites, OpenZeppelin `uniswap-hooks`, Hacken's `uni-v4-hooks-checker`,
BlockSec HookScan, `hunterinvariants/v4-hook-invariants`, Recon-Fuzz chimera)
at pinned commits. Classes where every comparator was empty or partial were
prioritized; classes where a comparator already ships a directly matching
property test were deprioritized for the first cut and named as prior art
wherever they are relevant.

Second, the registry applicability count. The map's §5 reports numbers from a
parse of Uniswap's public 253-hook registry: 17% of deployed hooks read
`hookData` (union of author flag and description signals), 65% opt into at
least one return-delta callback (v4-mechanical custom accounting, a superset
of Bunni-shaped bespoke accounting), 37% carry the dynamic-fee flag, 53%
carry at least one liquidity-modification callback, and 98% carry at least
one swap callback. 90% of the deployed surface carries no linked audit URL.
Classes that touched a meaningful share of the deployed surface got in.

Third, hook-specific shape. The four shipped classes all live on the v4
surface itself, not on generic Solidity primitives that happen to sit inside
a hook. H1 (identity trust from `hookData`) and H2 (fee authorization from
`hookData`) live on the opaque `bytes hookData` parameter the caller
controls. H3 (flash-accounting settlement) lives on the currency-delta
contract with the `PoolManager` that v4 requires every unlock consumer to
satisfy. B1 (custom-accounting conservation) lives on the internal share and
idle-balance accounting a return-delta hook maintains alongside the pool.

The four classes therefore pass three tests together: they are recurring on
the deployed surface, they are shapes native to v4 rather than generic to
Solidity, and no comparator ships a directly matching property test for any
of them at the pinned commits. Adjacent runtime guards and boilerplate
reducers exist for some (v4-core's unlock-time revert on unsettled delta
covers a slice of H3; OpenZeppelin bases reduce the surface for H2 and B1);
the coverage map records which cells are empty, which are partial, and which
are covered elsewhere, with a file-level citation per non-empty cell.

## 3. The clean/planted twin discipline

Every case ships as two hooks that share their source except for one
single-hunk diff. The clean twin passes the invariant suite; the planted
twin, carrying the seeded specification violation, fails it with an explicit
`INVARIANT VIOLATED <marker>` string. Both twins run in CI on every commit.

The reason for this discipline is short: a check that has never been seen to
fire is an unproven check. A green-only test suite tells a reviewer that the
properties held on the code that ran, not that the properties would fire on
code that violated them. The planted twin is the standing receipt that the
invariant is not vacuous. When the clean twin passes and the planted twin
fails with the expected marker on the same commit, both legs make sense;
when either leg drifts, the drift shows up as red in the next CI run.

Per-case scorecards under `docs/scorecards/` record the exact `forge test`
output on both legs at each case's landing commit, so a reviewer can inspect
the receipt without running the suite locally.

## 4. Defender-side framing, as a design decision

The harness is a set of invariants a defender runs pre-deploy. Planted twins
are seeded specification-violation regressions on our own synthetic hooks;
each carries a wrong-source, wrong-direction, or wrong-step in a code path
the same file's clean twin gets right. The repository ships no adversary
model, no extraction ledger, and no named-target reproduction. Regression
sequences assert on the `INVARIANT VIOLATED <marker>` string and stop at the
first violation.

This is stated once as a design decision so a reviewer does not have to
reconstruct it from the code. An internal framing register keeps the
wording consistent across cases, tickets, and READMEs.

## 5. Deliberately out of scope

The harness is not an audit, and it does not act as a runtime guard on a
deployed hook. Discovering unknown bug classes is a separate problem this
repository does not attempt. On any given hook it catches the class the
invariant encodes, at the sizes and sequence depths the CI suite exercises,
and nothing else. A clean-twin green run tells an adopter that the encoded
properties hold on their hook at those sizes; it does not clear the hook of
any class this repository has not encoded.

The one-shot caveats in the main README apply here in full. H3's honest
sizing is that the real `PoolManager` already reverts on an unsettled delta
at unlock time, so H3's delta is to catch pre-deploy what mainnet would
revert. The B1 case is a regression fixture for the custom-accounting
conservation class, not a reproduction of any specific real-world incident.

## 6. What comes next

M2 and M3 add more classes on the same real-v4 surface, under the same twin
discipline and the same coverage-map accounting. Selection for M2 leans on
adopter input: an adopting hook team's own top-priority class is a stronger
signal than any internal ranking. The planned classes named in
`docs/coverage_map.md` (dynamic-fee override misuse, return-delta routing,
liquidity-modification reentrancy) are the current shortlist for later cuts,
pending adopter feedback. Sequencing tracks the repository's internal
resubmission roadmap.
