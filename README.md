# uniswap-v4-invariants

[![ci](https://github.com/caliperforge/uniswap-v4-invariants/actions/workflows/ci.yml/badge.svg)](https://github.com/caliperforge/uniswap-v4-invariants/actions/workflows/ci.yml)
[![bring-your-hook](https://github.com/caliperforge/uniswap-v4-invariants/actions/workflows/bring-your-hook.yml/badge.svg)](https://github.com/caliperforge/uniswap-v4-invariants/actions/workflows/bring-your-hook.yml)

Stateful invariant test harness for Uniswap v4 hooks, running against
the real `v4-core` PoolManager (pinned submodule, no mocks, no forks).
Four hook bug classes ship as same-source clean/planted twins: the
clean twin passes the invariant suite, the planted twin (a single-hunk
mutation on the seeded specification violation) fails it with an
explicit `INVARIANT VIOLATED <marker>` string. Both twins run in CI on
every commit, so the harness carries standing proof that each property
catches the class it claims to catch. Bring-your-hook takes an author
from clone to a fuzz-walked hook against the real `PoolManager` in
under an hour.

## What this is, and what it is not

- **This is** a regression suite for a curated list of recurring
  v4-hook failure modes, encoded as stateful multi-operation invariants
  and shipped as clean/planted twin pairs, adoptable by a hook team via
  `test/bring-your-hook/`.
- **This is not** an audit, a runtime guard, or a discovery engine for
  unknown bug classes. It replaces none of the free tools listed below.
  A clean-twin green run tells a hook team that our encoded properties
  hold on their hook; it does not clear their hook of a class we have
  not encoded.
- **What the harness supplies for free on any hook** (`clean` leg,
  every commit): the real v4 `PoolManager` deployed in-test, a hooked
  pool seeded through the standard flag-encoded address, a fuzz walk
  of swaps and liquidity churn, and the settlement-liveness checks the
  invariant base bakes in. Business-logic properties that a hook is
  supposed to satisfy are the hook author's to state; the base makes
  stating them a few overrides per property.

## What is already free

The v4 hook-testing landscape has real, useful, free public tooling.
Before adopting anything here, a team should know what each of these
covers, and this repo's coverage map (`docs/coverage_map.md`) cites
every claim to a file at a pinned commit.

- **Uniswap `v4-core` and `v4-periphery` suites.** Extensive unit and
  stateless-fuzz tests protect the `PoolManager` and periphery. Neither
  repo contains any Foundry stateful invariant test (GitHub code search
  for `StdInvariant`: 0 results in each). The point of these suites is
  the core, not any given third-party hook's logic.
- **OpenZeppelin `uniswap-hooks`.** Audited secure base contracts
  (`BaseHook`, `BaseCustomAccounting`, four fee bases, general-purpose
  hooks, `CurrencySettler`) plus per-contract unit tests. It removes
  the boilerplate class of hook bugs by construction; it does not check
  trust decisions a hook makes with caller-supplied `hookData` or the
  correctness of bespoke accounting, and it ships no invariant tests.
- **Hacken `uni-v4-hooks-checker`.** Generic conformance and
  access-control checker for any deployed hook (point it at an address,
  it introspects the permission bitmap, dynamically selects suites, and
  runs them against a real `PoolManager`). Its fuzzing is single
  operation stateless, and it demonstrates its checks on a well-behaved
  example rather than proving they fire on broken ones. Excellent
  adoption ergonomics.
- **BlockSec `HookScan`.** Static analyzer targeting four documented
  detector categories (public-hook, public-callback, upgradable,
  suicidal). Complementary; by construction it cannot see a
  multi-operation rounding accumulation or a semantic trust error in
  `hookData` whose sink looks benign.
- **Recon-Fuzz `chimera`.** Property-suite scaffolding portable across
  Foundry, echidna, medusa, and halmos. It is scaffolding; it ships no
  v4-hook properties.
- **`hunterinvariants/v4-hook-invariants`.** Six paired safe/broken v4
  hook invariants against real v4-core (unguarded callback, bricked LP
  withdrawal, value-leaking round trip, dynamic fee past cap, delayed
  fee honeypot, swap liveness). Two are additionally fuzzed. Two-way
  proof discipline (safe passes, broken fails) is not a distinction of
  this repo; hunterinvariants publishes it in the same ecosystem, and
  the coverage map records where their properties and ours do and do
  not overlap.

**What we add, in one paragraph.** Uniswap v4's own test suites protect
the `PoolManager`, not the logic hook authors write on top of it. The
OpenZeppelin library removes boilerplate hook bugs by construction but
cannot check trust decisions made with caller-supplied `hookData` or
the correctness of bespoke accounting, and it ships no invariant tests.
Hacken's checker runs useful generic conformance and access-control
checks against any deployed hook, but its fuzzing is single-operation,
and it demonstrates its checks on a well-behaved example rather than
proving they fire on broken ones. None of this covers the class that
drained $8.3M from Bunni, a multi-operation rounding accumulation in
the hook system's own accounting, after that team had already run both
Foundry fuzzing and Medusa. What this repo adds is narrow and specific:
a public atlas of recurring v4-hook bug classes, each encoded as a
stateful multi-operation invariant running against real v4-core, and
each shipped as a clean/planted twin pair in CI, so there is a
standing, reproducible receipt that every property catches the bug
class it claims to catch instead of an unfalsified green checkmark.

The atlas encodes known classes with proof of detection. It is not a
claim that this suite would have found Bunni ahead of time, and it is
not a claim that any property here is the first of its shape in the
ecosystem. Both would be over-claims; the coverage map and case
READMEs make neither.

## Coverage map, excerpt

Full artifact and pinned citations: `docs/coverage_map.md`. Columns
are the six free comparators above; rows are recurring v4-hook bug
classes; `covered` means a directly matching property test, `partial`
means a related check that reduces but does not close the class, empty
means no matching artifact at the pinned commit. Only rows empty across
every comparator carry the word "unique."

| Bug class | v4-core / v4-periphery | OZ uniswap-hooks | Hacken checker | HookScan | hunterinvariants | Chimera | Unique across comparators? |
|---|---|---|---|---|---|---|---|
| **H1 hookData identity trust** | | | partial (introspection only) | | | | yes |
| **H2 fee waiver via hookData** | | partial (boilerplate reducer) | | | | | yes |
| **H3 flash-accounting settlement** | partial (runtime revert) | partial (settle/take patterns) | partial (stateless delta check) | | | | no |
| **B1 custom-accounting conservation** | | partial (boilerplate reducer) | | | | | yes |

Applicability against Uniswap's 253-hook live registry, from the same
file: 17% of deployed hooks read `hookData` (union of author flag and
description signals), 65% opt into at least one return-delta callback
(v4-mechanical custom accounting; a superset of Bunni-shaped bespoke
accounting), 37% carry the dynamic-fee flag, 53% carry any
liquidity-modification callback, and 98% carry any swap callback. 90%
of the deployed surface carries no linked audit URL.

`H3` is the honest case for size: the real v4 `PoolManager` already
reverts on unsettled delta at unlock time, so H3's delta in this repo
is to catch pre-deploy what mainnet would revert. Real, small, stated
at that size.

## Cases

Every case here is a same-source clean/planted twin built on an
already-public source of truth (an audit finding shipped with a fix,
a hook team's own public postmortem, or the Uniswap protocol spec
itself), credited to the party whose public work carries that source
of truth. Where an audit firm carries the finding, the credit names
the firm; where the class-source is the protocol spec itself or a
hook team's own postmortem, the credit names that party. Rows without
an external audit-firm precedent at the pinned commit say so; each
case README carries the deeper report URLs, fix-commit hashes, and
version tags, and `docs/coverage_map.md` carries the file-level
comparator citations.

Six cases ship. Each is a clean/planted twin: the clean twin is what
a hook author would write if they got the spec right, the planted twin
is the same source with one single-hunk seeded specification violation
in the flagged code path, and CI runs both legs. Twin diffs and per-run
receipts live in each case README; the summary rows below use each
case's own canonical name and marker.

| Case | Hook | Seeded specification violation | Invariant marker | Credited to | Clean leg | Planted leg |
|---|---|---|---|---|---|---|
| **C-H1** [details](src/cases/h1-hookdata-identity/README.md) | `RewardsHook` | reward-recipient identity read from caller-supplied `hookData` instead of the authenticated sender | `INVARIANT VIOLATED h1_rewards_identity` | no external audit-firm precedent at pinned commit; class-source is Uniswap's own `IHooks` natspec at `lib/v4-core/src/interfaces/IHooks.sol` @ `e50237c` (v4.0.0), which defines `hookData` as caller-supplied. Hacken `test/suites/HookDataDetection.t.sol` @ `965be6006eab` covers partial introspection only (per `docs/coverage_map.md` §H1) | green | red with marker |
| **C-H2** [details](src/cases/h2-fee-waiver/README.md) | `FeeSwitchHook` | fee-waiver decision honored from a byte of caller-supplied `hookData` instead of an on-chain allowlist | `INVARIANT VIOLATED h2_fee_waiver_via_hookdata` | no external audit-firm precedent at pinned commit; same class-source as C-H1 (Uniswap `IHooks` natspec). OpenZeppelin `src/fee/BaseOverrideFee.sol` @ `26dc8e53f812` reduces the boilerplate H2 surface by construction without closing the class (per `docs/coverage_map.md` §H2) | green | red with marker |
| **C-H3** [details](src/cases/h3-flash-accounting/README.md) | `FlashHook` | callback opens a currency delta on the `PoolManager` and does not `settle` it before the outer `unlock` returns | `INVARIANT VIOLATED h3_flash_accounting` | Uniswap, whose own `PoolManager.sol` L111 @ `e50237c` reverts any unlock exit with a nonzero delta (`CurrencyNotSettled`); the case turns that mainnet revert into a pre-deploy CI failure. Partial adjacencies: OpenZeppelin `CurrencySettler.sol` + `BaseCustomAccounting.sol` settle/take patterns, and Hacken `test/deltas/{SwapDeltaEffects,LiquidityDeltaEffects}.t.sol` stateless delta checks (per `docs/coverage_map.md` §H3) | green | red with marker |
| **C-B1** [details](src/cases/b1-custom-accounting/README.md) | `LiquidityVaultHook` | withdraw-path rounding direction flipped on the idle leg of a pro-rata split, so remainder-carrying withdrawals systematically overstate the split by 1 wei | `INVARIANT VIOLATED b1_balance_split_integrity` (plus `b1_accounting_conservation`) | Bunni team's own public postmortem (`blog.bunni.xyz/posts/exploit-post-mortem/`, September 2025, $8.3M) is the class-source of record. Taxonomy adjacency: Zealynx Pattern 4 (custom-accounting drift), whose public write-up (2026-05-25) uses Bunni V2 as the walkthrough. Partial mitigation: OpenZeppelin `BaseCustomAccounting.sol` @ `26dc8e53f812` reduces the boilerplate surface without closing the class (per `docs/coverage_map.md` §B1) | green | red with marker |
| **C-P1** [details](src/cases/p1-liquidity-penalty-conservation/README.md) | `LiquidityPenaltyHook` | add-event on an existing position (i.e. an increase) fails to capture the fees v4-core just auto-collected into the pending penalty base, so a removal inside the penalty window donates zero for that epoch | `INVARIANT VIOLATED p1_liquidity_penalty_conservation` | **OpenZeppelin** (root finding: Uniswap Hooks v1.1.0 audit; guard shipped in `LiquidityPenaltyHook.sol` v1.2.0 under `OpenZeppelin/uniswap-hooks/src/general/`). **Zealynx** (public v4-hook write-up 2026-05-25, the taxonomy source) | green | red with marker |
| **C-P2** [details](src/cases/p2-dynamicfee-direction-integrity/README.md) | `DemoDynamicAfterFeeHook` (subclass of OZ's audited `BaseDynamicAfterFee` @ tag `v1.1.0`) | after-swap fee-arithmetic is the pre-`2678eb9` shape: `feeAmount = unspec - target` computed unconditionally without branching on `exactInput`, so on exactOutput swaps the fee is billed with the wrong sign convention and the accrued ledger diverges from the reference | `INVARIANT VIOLATED p2_dynamicfee_direction_integrity` | **OpenZeppelin** (root finding: Uniswap Hooks v1.1.0 RC-2 audit finding M-01 "Incorrect Fee Application When `unspecifiedAmount` Represents Input Instead of Output"; fix commit `2678eb9`, released in tag `v1.1.0`). **Zealynx** (Pattern 4: custom-accounting drift, public write-up 2026-05-25) | green | red with marker |

Each case ships:

- A `clean/` and `planted/` hook that share their source except for the
  single-hunk twin diff shown in the case README.
- A stateful invariant suite (256 runs x depth 50) with the marker
  above, plus a deterministic regression sequence that trips the marker
  seed-independently on the planted twin, plus unit checks.
- A scorecard under `docs/scorecards/` recording the exact `forge test`
  output on both legs.

**Motivation note for B1, cited once and not reproduced as a
reproduction.** Rounding-direction defects in custom vault share
accounting have been publicly documented as the cause of real-world
losses (Bunni, September 2025, $8.3M, per the team's own postmortem
at `blog.bunni.xyz/posts/exploit-post-mortem/`), and Bunni's own team
had run Foundry unit + fuzz tests and Medusa fuzzing before the
incident. The B1 fixture encodes this class as a defender-side
regression on a synthetic vault hook so a future custom-accounting
hook team can prove their suite catches the class before deploying.
This repo does not claim its own suite would have found Bunni ahead
of time; the B1 case is a regression fixture for the class, not a
reproduction of the incident.

**Motivation note for P1, cited once.** The class the P1 fixture
encodes (add-time fee-state guard on a liquidity-penalty hook) was
drawn from Zealynx's public v4-hook pattern write-up (2026-05-25), with
the root finding first surfaced in OpenZeppelin's own Uniswap Hooks
v1.1.0 audit; the current published `LiquidityPenaltyHook` (v1.2.0,
under `OpenZeppelin/uniswap-hooks/src/general/`) carries the guard.
The P1 fixture is a defender-side regression on a synthetic teaching-
scale hook so a future penalty-donation hook team can prove their
suite catches the class before deploying. This repo does not
reproduce the class as a mechanism against any specific deployment;
the case is a class-level regression fixture.

**Motivation note for P2, cited once.** The class the P2 fixture
encodes (direction-aware fee arithmetic on the after-swap fee-basis
path) was reported and fixed on OpenZeppelin's own `uniswap-hooks`
library under OpenZeppelin's Uniswap Hooks v1.1.0 RC 2 audit as
finding M-01 ("Incorrect Fee Application When `unspecifiedAmount`
Represents Input Instead of Output"). The fix landed as commit
`2678eb9` and released in tag `v1.1.0`; the case's clean twin
subclasses the audited fixed `BaseDynamicAfterFee` (vendored under
`src/cases/p2-dynamicfee-direction-integrity/vendor/oz-uniswap-hooks-v1.1.0/`)
and byte-copies the post-fix fee-arithmetic; the planted twin
byte-copies the pre-fix arithmetic into the same file at the same
line. Zealynx's public v4-hook write-up (2026-05-25) carries Pattern 4
(custom-accounting drift) as the umbrella taxonomy this class sits
under. The P2 fixture is a defender-side regression on a teaching-
scale synthetic hook so a future dynamic-fee hook team can prove
their suite catches the class before deploying. This repo does not
reproduce the finding against any specific deployed hook; the case
is a class-level regression fixture.

## Bring your hook

Walkthrough: `test/bring-your-hook/README.md`. Worked example:
`test/bring-your-hook/ExampleAdopter.t.sol` (clean leg) and
`ExamplePlanted.t.sol` (planted leg). Copy-paste CI:
`.github/workflows/bring-your-hook.yml`, a two-job workflow whose
clean-passes job is required and whose planted-mutation-fails job is
optional (vacuously green if no `Planted` suite exists in the fork).

Rough time to first green on a new hook: 10 minutes for steps 1 to 3
of the walkthrough (clone, drop hook in, run the example suite against
the real `PoolManager`), and 20 to 30 minutes for steps 4 to 6
(writing the hook's own test file, declaring the business-logic
properties that only the author can state). Steps 7 and 8 (planted-leg
red proof and CI wire-up) are optional; the harness is useful without
them.

## Layout

- `src/routers/InvariantRouter.sol`: this repo's own thin
  unlock-callback router (`swap` and `modifyLiquidity` through
  `PoolManager.unlock`). Original code, Apache-2.0. v4-core's in-repo
  test routers carry SPDX `UNLICENSED` and are not imported.
- `src/cases/<case>/{clean,planted}/`: twin hooks per bug class.
- `test/base/`: shared deploy helpers and handler base. The real
  `PoolManager` is deployed in-test, and hooks are placed at
  flag-encoded addresses via `deployCodeTo`.
- `test/bring-your-hook/`: adoption scaffold. Inherit
  `BYOHInvariantBase`, point it at your hook, get the invariant walk.
- `docs/coverage_map.md`, `docs/scorecards/`, `docs/pin_decision_v4-core.md`, `docs/design_notes.md`.

## Toolchain

- solc `0.8.26` exactly (`PoolManager`'s pragma is exact),
  `evm_version = cancun` (transient storage), `via_ir = false`.
- `lib/v4-core` pinned at release tag `v4.0.0`; `lib/forge-std` at
  `v1.9.4`. Clone with `--recursive` so v4-core's own nested submodules
  are fetched (v4-core imports them in its sources; this repo does not).

```sh
git clone --recursive <repo>
cd uniswap-v4-invariants
forge build
forge test
```

## License

This repository's own code (everything outside `lib/`) is licensed
under the Apache License, Version 2.0. See `LICENSE` for the full text.

Uniswap `v4-core` is vendored as a pinned git submodule at `lib/v4-core`
and is NOT Apache-2.0. `v4-core` is per-file dual-licensed by
Universal Navigation Inc., with each file's applicable license stated
in its `SPDX-License-Identifier` header:

- **BUSL-1.1** covers the core protocol contracts, including
  `src/PoolManager.sol` and the transient-state libraries the manager
  compiles against (`Pool`, `Position`, `Lock`, `NonzeroDeltaCount`,
  `CurrencyReserves`, `CurrencyDelta`). Change Date is the earlier of
  2027-06-15 or a date at `v4-core-license-date.uniswap.eth`; Change
  License is MIT; the Additional Use Grant points at
  `v4-core-license-grants.uniswap.eth`. Full text:
  `lib/v4-core/licenses/BUSL_LICENSE`.
- **MIT** covers the core libraries, interfaces, and types this
  harness compiles against directly (for example
  `src/libraries/Hooks.sol`, `src/interfaces/IHooks.sol`,
  `src/interfaces/IPoolManager.sol`). Copyright 2023 Universal Navigation
  Inc. Full text: `lib/v4-core/licenses/MIT_LICENSE`.

This repository's use of the BUSL-1.1 contracts is non-production
pre-deployment testing: `v4-core` is compiled and deployed only inside
local and CI Foundry test processes to exercise hook invariants before
any production deployment. No BUSL-1.1 source is modified (submodule
pointer only) and none is deployed to any production network by this
project. This use is within the base BUSL-1.1 non-production use and
redistribution grants.

Two disciplines are worth naming:

- `v4-core` files bearing SPDX `UNLICENSED` (its in-repo test routers
  such as `src/test/PoolSwapTest.sol`, and one `src/test/NativeERC20.sol`
  carrying SPDX `GPL-3.0-or-later`) are NOT imported or used by this
  repository. Pool interaction goes through this repository's own
  Apache-2.0 `InvariantRouter`.
- `v4-core`'s nested dependency `solmate` (AGPL-3.0-only) is present
  on disk via recursive submodule init because `v4-core`'s own sources
  reference it; no file in this repository imports `solmate`.

The full attribution and per-file surface (the 8-file BUSL-1.1
enumeration, the MIT-licensed files this harness compiles against,
transitive submodules, and the UNLICENSED / GPL-3.0-or-later files that
travel with the submodule but are not imported) lives in `NOTICE`.

## AI disclosure

CaliperForge's authoring stack is AI-augmented. What is AI-touched on
this repo, and the reviews that gate it, are disclosed in
`AI_DISCLOSURE.md`. CI verdicts and license posture are not AI-touched.
