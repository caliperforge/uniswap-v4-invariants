# Coverage map: v4-hook bug classes x free comparators

**What this file is.** A one-page reconciliation of which free public tools cover which recurring Uniswap v4 hook bug classes, with a file-level citation at a pinned commit for every non-empty cell. Any cell not cited is empty, and "empty across the whole row" is the only condition under which a class is called "unique" here.

**Reading order.** Row = a recurring v4-hook bug class. Column = a free comparator (Uniswap suites, OZ base library, Hacken checker, HookScan static analyzer, hunterinvariants suite, Chimera scaffold). Cell entries: `covered` (a directly matching property test), `partial` (a related check that reduces the attack surface or catches a subset), or empty. Every non-empty cell links a file path @ commit that a reviewer can open in one click.

**Reconciliation baseline.** This map is the artifact required by the adversarial evaluation `agents/adversarial_research_lead/outbox/uniswap_value_over_free_eval_2026-07-01.md` §8 requirement 3. Every row characterizes each comparator exactly as §§1-4 of that evaluation do (0 `StdInvariant` in v4-core and v4-periphery; OZ ships unit tests only; Hacken's fuzz is stateless single-operation; hunterinvariants covers six generic hook-archetype properties). If a reader spots a discrepancy, primary sources win: open the cited file at the pinned commit.

**Scope of this file.** Not an audit. Not a claim about maintenance status or completeness of any comparator. Not a claim that the atlas is safer than any listed tool. It is a map of what is already free, so a reviewer of the atlas can size the marginal contribution honestly.

## Sections

1. Pinned commits (every citation resolves to one of these SHAs)
2. Bug classes covered by this file
3. The map (matrix)
4. Row-by-row justification, with file-level citations
5. Registry applicability stats (against Uniswap's live 253-hook registry)
6. Reconciliation with the adversarial evaluation §§1-4
7. Reviewer spot-check pointers (open one cell, verify one claim)
8. License and disclaimers

---

## 1. Pinned commits

Every non-empty cell in section 3 resolves to a file at exactly one of these SHAs. The v4-core pin is the scaffold's submodule pin (a reviewer can spot-check it in the same working tree); the other pins are the HEAD of each comparator's default branch at fetch time 2026-07-01.

| Comparator | Repository | Commit SHA (12) | Date | How to open |
|---|---|---|---|---|
| Uniswap v4-core (v4.0.0 tag) | `Uniswap/v4-core` | `e50237c43811` | 2025-01-28 | `experiments/uniswap-v4-invariants/lib/v4-core/` |
| Uniswap v4-periphery (HEAD) | `Uniswap/v4-periphery` | `363226d9e1e2` | 2026-05-27 | github.com/Uniswap/v4-periphery/tree/363226d9e1e2 |
| OpenZeppelin uniswap-hooks (HEAD) | `OpenZeppelin/uniswap-hooks` | `26dc8e53f812` | 2026-05-15 | github.com/OpenZeppelin/uniswap-hooks/tree/26dc8e53f812 |
| Hacken uni-v4-hooks-checker (HEAD) | `hknio/uni-v4-hooks-checker` | `965be6006eab` | 2025-11-27 | github.com/hknio/uni-v4-hooks-checker/tree/965be6006eab |
| BlockSec HookScan (HEAD) | `blocksecteam/hookscan` | `3869b6479037` | 2024-01-23 | github.com/blocksecteam/hookscan/tree/3869b6479037 |
| hunterinvariants v4-hook-invariants (HEAD) | `hunterinvariants/v4-hook-invariants` | `93e341ae975f` | 2026-06-15 | github.com/hunterinvariants/v4-hook-invariants/tree/93e341ae975f |
| Recon-Fuzz chimera (HEAD) | `Recon-Fuzz/chimera` | `463c0d413493` | 2026-04-01 | github.com/Recon-Fuzz/chimera/tree/463c0d413493 |

Fetch method: `gh api repos/<owner>/<name>/commits?per_page=1` for the HEAD SHAs; the v4-core pin is verbatim from `experiments/uniswap-v4-invariants/.gitmodules` (release tag `v4.0.0`), corroborated in `docs/pin_decision_v4-core.md`.

## 2. Bug classes covered by this file

Four shipped classes (H1, H2, H3, B1) and three planned classes marked "planned" until their planted-twin case lands.

- **H1 hookData identity tampering.** A hook reads a trust decision (a recipient, an actor identity, an allowance ceiling) out of the opaque `bytes hookData` and does not authenticate that decision. The caller controls the field, so the caller controls the decision.
- **H2 fee waiver via hookData.** A hook keys a fee override (a waiver, a discount tier, a fee-collecting recipient) on caller-supplied hookData, so any swapper who knows the encoding sets the override to zero or redirects the taker.
- **H3 flash accounting: unresolved-delta / nested-call.** A hook's callback opens or leaves a nonzero currency delta on the PoolManager that is not settled before the outer `unlock` returns.
- **B1 custom-accounting conservation (the Bunni class).** A hook maintains its own share / idle-balance / active-balance accounting alongside the pool. A rounding-direction choice safe for a single operation is unsafe when repeated across many operations, and the drift is monetizable.
- **M2 planned: dynamic-fee override misuse.** A dynamic-fee hook returns an LP fee beyond a declared cap, or in a state (post-honeypot gate) that a single-swap check reads as clean.
- **M2 planned: return-delta routing.** A hook that opts into `*ReturnsDelta` flags returns a delta shape the routing/settlement path does not tolerate, so value leaks on a round trip.
- **M2 planned: liquidity-modification reentrancy.** A `beforeAddLiquidity` / `beforeRemoveLiquidity` callback re-enters the PoolManager via a different action inside its own callback, so a per-action invariant read at the outer step is stale.

## 3. The map

Legend: `[covered]` = a directly matching property test on the comparator side; `[partial]` = a related check (runtime guard, boilerplate reducer, or single-op / introspection variant of the property) that reduces but does not close the class; empty = no matching artifact at the pinned commit. Only rows empty across every comparator carry the word "unique."

| Bug class | Uniswap v4-core / v4-periphery | OZ uniswap-hooks | Hacken uni-v4-hooks-checker | BlockSec HookScan | hunterinvariants v4-hook-invariants | Chimera | Unique across all comparators? |
|---|---|---|---|---|---|---|---|
| **H1 hookData identity tampering** | | | [partial] introspection only | | | | **yes** |
| **H2 fee waiver via hookData** | | [partial] boilerplate reducer | | | | | **yes (see §4)** |
| **H3 flash accounting (unresolved-delta)** | [partial] runtime revert | [partial] settle/take patterns | [partial] stateless delta check | | | | no |
| **B1 custom-accounting conservation** | | [partial] boilerplate reducer | | | | | **yes** |
| M2 dynamic-fee override misuse [planned] | [partial] core doubles | [partial] guarded bases | | | [covered] single class | | no |
| M2 return-delta routing [planned] | | | | | [partial] swap-path leak | | no |
| M2 liquidity-modification reentrancy [planned] | | | | | | | **yes** |

## 4. Row-by-row justification, with file-level citations

Each row lists the exact file(s) at the pinned commit that back the cell entry. If a cell is empty in section 3, there is no citation, because there is no corresponding artifact at the pinned commit. Two comparators (HookScan, Chimera) get characterized once here rather than reappearing per row: HookScan targets four specific static-analysis categories that do not overlap any row in this file, and Chimera ships property-writing scaffolding with zero v4-hook properties, so both are empty across every row.

### H1 hookData identity tampering

- v4-core / v4-periphery: no cell. GitHub code search for `StdInvariant` in both repositories returns 0 results (verified in `uniswap_value_over_free_eval_2026-07-01.md` §1); the core-side test doubles under `lib/v4-core/src/test/` (`MockHooks.sol`, `FeeTakingHook.sol`, `DeltaReturningHook.sol`, `CustomCurveHook.sol`, `SkipCallsTestHook.sol`, `DynamicFeesTestHook.sol`, `DynamicReturnFeeTestHook.sol`, `LPFeeTakingHook.sol`) exist to exercise the PoolManager's handling of hook interactions, not to check that any third-party hook's use of hookData is authenticated. `src/test/` has no `StdInvariant`.
- OZ uniswap-hooks: no cell. `src/base/BaseHook.sol` @ `26dc8e53f812` enforces `msg.sender == poolManager` on every callback but does not authenticate the semantic content of the `bytes hookData` parameter, which is opaque to the base. A hook built on BaseHook that reads a reward recipient out of hookData is exactly as vulnerable to H1 as one that is not.
- Hacken uni-v4-hooks-checker: `[partial] introspection only`, cite `test/suites/HookDataDetection.t.sol` @ `965be6006eab`. This suite calls `swapRouter.swap` with `Constants.ZERO_BYTES` and reports whether the hook accepts empty hookData or requires a specific format. The suite explicitly declares hooks that require signed or structured hookData as "cannot auto-test" (verbatim string in the file). That is introspection, not a check that the hook's trust decision is safe. Marked partial for honest disclosure, not because it covers the H1 property class.
- BlockSec HookScan: no cell. The four documented detectors are `UniswapPublicHook`, `UniswapPublicCallback`, `UniswapUpgradableHook`, `UniswapSuicidalHook` (see `docs/detectors/*.md` @ `3869b6479037`); none targets hookData trust decisions.
- hunterinvariants v4-hook-invariants: no cell. The six shipped properties (`test/HookInvariant.t.sol`, `test/RoundTripProof.t.sol`, `test/DynamicFeeProof.t.sol`, `test/DelayedTrapProof.t.sol`, `test/SwapLivenessProof.t.sol` @ `93e341ae975f`, README @ same commit) are access-control-on-callback, LP withdrawal liveness, round-trip value leak, dynamic-fee cap, delayed honeypot, swap liveness. None is a hookData trust decision.
- Chimera: no cell. `src/BaseSetup.sol`, `src/BaseTargetFunctions.sol`, `src/BaseProperties.sol` @ `463c0d413493` are property-suite scaffolding; the repository ships zero v4-hook property tests.

Reading the row across: only introspection at Hacken, no property coverage anywhere. H1 is unique across comparators at the pinned commits.

### H2 fee waiver via hookData

- v4-core / v4-periphery: no cell. Same code-search result as H1. The dynamic-fee test doubles `src/test/DynamicFeesTestHook.sol` and `src/test/DynamicReturnFeeTestHook.sol` @ `e50237c43811` exercise the core's dynamic-fee wiring; they do not check that a fee override is authorized by an authenticated party.
- OZ uniswap-hooks: `[partial] boilerplate reducer`, cite `src/fee/BaseOverrideFee.sol`, `src/fee/BaseDynamicFee.sol`, `src/fee/BaseDynamicAfterFee.sol`, `src/fee/BaseHookFee.sol` @ `26dc8e53f812`. These bases structure where the fee override happens and enforce PoolManager-only invocation, so they close the boilerplate route to H2 (an unguarded callback that any caller can trip). What they do not check is whether the input the override trusts (typically the caller-supplied hookData) is authenticated: a `BaseOverrideFee`-derived hook keyed on caller-supplied hookData reproduces H2 unchanged. Test coverage is `test/fee/BaseDynamicAfterFee.t.sol`, `test/fee/BaseOverrideFee.t.sol` @ same commit, unit tests only.
- Hacken uni-v4-hooks-checker: no cell. The swap-side suites `test/suites/Swap.t.sol`, `test/FuzzTestEntry.t.sol`, `test/deltas/SwapDeltaEffects.t.sol` @ `965be6006eab` run single-operation fuzzing with random amounts and tick ranges, several wrapped in `try/catch {}` blocks that swallow reverts. No property expresses "fee override was authorized by an identity the swapper could not forge."
- HookScan / hunterinvariants / Chimera: no cell (see the once-and-done characterization above).

Reading the row: the OZ boilerplate reducer is the only non-empty cell, and it does not close the H2 property class. H2 is unique across comparators at the pinned commits, with the caveat that OZ's partial column is a real attack-surface reduction for teams that build on top of `BaseOverrideFee`.

### H3 flash accounting: unresolved-delta / nested-call

- v4-core: `[partial] runtime revert`, cite `src/PoolManager.sol` L111 @ `e50237c43811`:

  ```solidity
  if (NonzeroDeltaCount.read() != 0) CurrencyNotSettled.selector.revertWith();
  ```

  This is the real v4 runtime guard the adversarial evaluation §2 flags as the honest sizing of H3's delta. Any unlock exit with a nonzero delta reverts. Not a pre-deploy property test, and it fires only when the exploit shape reaches mainnet, but real coverage.
- OZ uniswap-hooks: `[partial] settle/take patterns`, cite `src/utils/CurrencySettler.sol`, `src/base/BaseCustomAccounting.sol` @ `26dc8e53f812`. Encoding correct settle/take patterns reduces the incidence of H3 by construction in author code that uses them. Not a property check.
- Hacken uni-v4-hooks-checker: `[partial] stateless delta check`, cite `test/deltas/SwapDeltaEffects.t.sol`, `test/deltas/LiquidityDeltaEffects.t.sol` @ `965be6006eab`. Delta-integrity checks against the PoolManager, single-op fuzz. A multi-operation walk that leaves a delta unsettled across a nested action is not exercised.
- HookScan / hunterinvariants / Chimera: no cell.

Reading the row: three partial cells, no unique claim. The evaluation §2's honest sizing is exactly the entry here: H3's delta over "OZ patterns + real v4 runtime" is to convert a mainnet revert into a pre-deploy CI failure.

### B1 custom-accounting conservation (the Bunni class)

- v4-core / v4-periphery: no cell. The bug lives in third-party hook logic (Bunni's `BunniHubLogic::withdraw` idle-balance accounting per the postmortem at `blog.bunni.xyz/posts/exploit-post-mortem/`). Out of scope by construction.
- OZ uniswap-hooks: `[partial] boilerplate reducer`, cite `src/base/BaseCustomAccounting.sol` @ `26dc8e53f812`. Provides the shape a custom-accounting hook fills in; does not encode a conservation property over the hook's own share / idle / active accounting.
- Hacken uni-v4-hooks-checker: no cell. Delta suites and single-op fuzz do not exercise a chained withdraw / withdraw / swap sequence with adversarially sized amounts and a property over the hook's internal share accounting. Bunni's own team ran Foundry fuzz and Medusa on their own accounting and still died (postmortem, primary source in the adversarial eval §5).
- hunterinvariants v4-hook-invariants: no cell. Confirmed in their own README @ `93e341ae975f`: "More hook archetypes (JIT-liquidity, custom accounting, async swaps) are the natural next additions." Their round-trip proof `test/RoundTripProof.t.sol` checks swap-path value leak, not share-redemption conservation.
- HookScan / Chimera: no cell.

Reading the row: no comparator covers B1. Only the OZ boilerplate reducer is non-empty, and it does not close the class. B1 is unique across comparators at the pinned commits, and hunterinvariants' own README explicitly disclaims custom accounting as future work.

### M2 planned: dynamic-fee override misuse

Marked planned; no atlas case ships yet. The row is included for scoping honesty rather than credit-taking.

- v4-core: `[partial] core doubles`, cite `src/test/DynamicFeesTestHook.sol`, `src/test/DynamicReturnFeeTestHook.sol` @ `e50237c43811`.
- OZ uniswap-hooks: `[partial] guarded bases`, cite `src/fee/BaseDynamicFee.sol`, `src/fee/BaseDynamicAfterFee.sol` @ `26dc8e53f812`.
- Hacken uni-v4-hooks-checker: no cell.
- HookScan: no cell.
- hunterinvariants v4-hook-invariants: `[covered] single class`, cite `src/AbusiveDynamicFeeHook.sol`, `src/SafeDynamicFeeHook.sol`, `src/DelayedHoneypotHook.sol`, `test/DynamicFeeProof.t.sol`, `test/DelayedTrapProof.t.sol` @ `93e341ae975f`. Fee cap + delayed-trap coverage on real v4-core.
- Chimera: no cell.

Reading the row: hunterinvariants ships a directly matching property here. Any future atlas case in this class must not claim "unique" and must cite hunterinvariants explicitly as prior public art.

### M2 planned: return-delta routing

Marked planned.

- v4-core: no cell. Core-side hook doubles exercise the PoolManager applying returned deltas but do not check third-party hook return shapes.
- OZ uniswap-hooks: no cell. `src/base/BaseCustomAccounting.sol`, `src/base/BaseAsyncSwap.sol` @ `26dc8e53f812` use return-delta patterns but do not check them.
- Hacken uni-v4-hooks-checker: no cell.
- HookScan: no cell.
- hunterinvariants v4-hook-invariants: `[partial] swap-path leak`, cite `src/LeakyFeeHook.sol`, `test/RoundTripProof.t.sol` @ `93e341ae975f`. Round-trip value leak checked on the swap path; not the general routing-tolerance property class.
- Chimera: no cell.

Reading the row: partial precedent only, not full coverage. A future atlas case here would cite the hunterinvariants precedent and scope its addition narrowly.

### M2 planned: liquidity-modification reentrancy

Marked planned.

Every comparator: no cell. v4-core's `unlock` guards the flash context, not the reentrancy of a liquidity-modification callback into a different action. OZ does not ship a reentrancy property test. Hacken does not. HookScan's four static detectors do not target this class. hunterinvariants' six properties do not include it. Chimera ships zero v4-hook properties.

Reading the row: unique across all comparators at the pinned commits. A future atlas case in this class would be the first public planted twin for it, on the evidence available at this commit.

## 5. Registry applicability stats (against Uniswap's live 253-hook registry)

Purpose. Turn "recurring" into a countable statement about the deployed surface, not an assertion. Consumes `research_lead`'s existing hooklist parse (`agents/research_lead/outbox/uniswap_v4_adopter_probe_2026-07-01.md` §base-rate context: 253 hooks / 220 unique names / 26 with `auditUrl` at fetch 2026-07-01, over the 8855-line `hooklist.json` on disk at `/tmp/hooklist.json`). No re-derivation; a fresh parse over the same file for the two flag columns the prior parse did not compute.

Methodology, stated exactly so a reviewer can reproduce.

- Population. Every object in `hooklist.json` counts once, so N = 253. The 220-unique-names figure is not the denominator; a hook deployed on three chains is three distinct deployments a reviewer might examine.
- "Reads hookData." Primary signal: `properties.requiresCustomSwapData == true` (an author-authored flag in the registry schema; a hook whose swap callback branches on non-empty hookData is expected to set it). Secondary signal: `hook.description` mentions the word "hookData" or the phrase "custom swap data" (case-insensitive substring). Reported both individually and unioned. The union is the correct upper bound because the primary signal is author-authored and imperfectly filled; the primary alone is the correct lower bound.
- "Custom accounting." Any of the four return-delta flags set to true: `flags.beforeSwapReturnsDelta`, `flags.afterSwapReturnsDelta`, `flags.afterAddLiquidityReturnsDelta`, `flags.afterRemoveLiquidityReturnsDelta`. In v4, opting into any of these makes the hook return a `BalanceDelta` that the PoolManager applies to settlement; that is custom accounting by construction. This is a mechanical signal on the deployed bytecode's permission bits (deployment-authoritative), not an author-authored flag.

Counts, at parse time 2026-07-01 over the same `hooklist.json` as the prior parse.

| Signal | Count | Share of 253 |
|---|---|---|
| `requiresCustomSwapData == true` (primary "reads hookData") | 34 | 13% |
| description substring "hookData" or "custom swap data" (secondary) | 20 | 8% |
| Union of the two "reads hookData" signals | 43 | 17% |
| Any `*ReturnsDelta == true` ("custom accounting") | 165 | 65% |
| `flags.beforeSwapReturnsDelta == true` | 126 | 50% |
| `flags.afterSwapReturnsDelta == true` | 114 | 45% |
| `flags.afterAddLiquidityReturnsDelta == true` | 3 | 1% |
| `flags.afterRemoveLiquidityReturnsDelta == true` | 3 | 1% |
| `properties.dynamicFee == true` (M2 dynamic-fee row applicability) | 93 | 37% |
| Any liquidity-modification callback (`beforeAddLiquidity` / `afterAddLiquidity` / `beforeRemoveLiquidity` / `afterRemoveLiquidity`) | 135 | 53% |
| Any swap callback (`beforeSwap` / `afterSwap`, bounds H3 applicability) | 248 | 98% |
| `hook.auditUrl` non-empty | 26 | 10% |

Reading the numbers, in one paragraph. On the deployed 253-hook surface the H1 / H2 hookData-trust classes apply to at least 13% of hooks by author flag and up to 17% by description text; the B1 / return-delta custom-accounting class applies to 65% by permission-bit flag; the dynamic-fee row applies to 37%; the liquidity-modification-reentrancy row applies at least to the 53% of hooks with any liquidity-modification callback; H3's runtime guard applies to essentially every hook that touches a swap (98%). 90% of the deployed surface carries no linked audit. These numbers are the honest sizing for "recurring."

Caveats.

- `requiresCustomSwapData` is author-authored; a hook that reads hookData but forgot to set the flag is undercounted by the primary signal. That is why the union with the description text is reported.
- The description-substring signal has false-positive potential (a description mentioning hookData incidentally counts). Reported separately so the reader can weight.
- "Custom accounting" here is the v4-mechanical definition (return-delta permission). It is a superset of Bunni-class custom accounting, which requires additional internal share / idle-balance bookkeeping. A 65% number therefore over-scopes B1's applicability; the honest B1 upper bound is somewhere inside that 65%. This map does not attempt a sharper bound, and no reviewer of this file should conclude 65% of deployed hooks are Bunni-shaped.
- Registry composition is a snapshot at fetch time. Future deployments will move the numbers.

## 6. Reconciliation with the adversarial evaluation §§1-4

This map's characterization of each comparator matches the adversarial evaluation exactly. Each item below has the eval clause on the left and the map's citation on the right; a reader who wants to test reconciliation opens both.

- Eval §1: "0 `StdInvariant` results in v4-core and v4-periphery; core echidna covers only three math surfaces; test hook doubles exist to exercise the core." Map §4 rows for v4-core cite the three echidna files (`SqrtPriceMathEchidnaTest.sol`, `TickMathEchidnaTest.sol`, `TickOverflowSafetyEchidnaTest.sol`) and the test-double directory contents.
- Eval §2: "OZ ships unit tests only; 0 `StdInvariant` in `OpenZeppelin/uniswap-hooks`; base contracts remove boilerplate but do not close hookData trust or bespoke accounting." Map §4 H1 / H2 / B1 rows cite the OZ base contracts as partial-boilerplate reducers only, not as covered, and cite the OZ test files as unit-only.
- Eval §3: "Hacken's fuzz is stateless single-operation; introspection layer covers permission-bitmap / EOA / onlyPoolManager." Map §4 rows for Hacken cite `test/FuzzTestEntry.t.sol`, `test/deltas/*`, `test/suites/HookDataDetection.t.sol` in the exact shape the eval assigns them.
- Eval §3b: "hunterinvariants ships six properties: unguarded callback, bricked LP withdrawal, value-leaking round trip, dynamic fee past cap, delayed fee honeypot, swap liveness; none is hookData trust or per-hook business-logic accounting; README explicitly names custom accounting as future work." Map §4 hunterinvariants cells characterize the six properties identically and quote the future-work admission from the pinned README.
- Eval §4: "HookScan is a static analyzer over four categories, no dynamic property coverage. Chimera is scaffolding, zero v4-hook properties." Map §4 folds both into the once-and-done characterization at the top of the row-by-row section.

If a reviewer opens a comparator's file at the pinned commit and finds a discrepancy with either the eval or this map, the map defers to the primary source: open the file, redo the row.

## 7. Reviewer spot-check pointers

The point of file-level citation is a one-click test. Three fast checks a reviewer can run in a minute apiece.

1. Open `experiments/uniswap-v4-invariants/lib/v4-core/src/PoolManager.sol` and jump to L111. Confirm the `CurrencyNotSettled` revert exists exactly as quoted in §4 H3. That backs H3's partial cell for v4-core.
2. Open github.com/hunterinvariants/v4-hook-invariants/blob/93e341ae975f/README.md and read the "Honest limits" section. Confirm the sentence "More hook archetypes (JIT-liquidity, custom accounting, async swaps) are the natural next additions." That backs the B1 unique claim.
3. Open github.com/hknio/uni-v4-hooks-checker/blob/965be6006eab/test/suites/HookDataDetection.t.sol and read the `run_DetectHookDataRequirement` body. Confirm the "cannot auto-test" warning strings. That backs the H1 row's partial-introspection-only entry for Hacken.

If any of the three fails, the map is wrong on that cell and gets corrected on the primary source.

## 8. License and disclaimers

- License. This map is Apache-2.0, matching the scaffold's license.
- Not an audit. Not a claim about any comparator's overall quality, maintenance state, or completeness. A "no cell" here means "no matching artifact for this specific bug class at the pinned commit," not "this tool is bad."
- Snapshot. Commits pin the state at fetch time 2026-07-01. Any comparator can add coverage after this file was written; a future map version will re-fetch and re-cite.
- Public-surface discipline. No em-dashes anywhere in this file; safe to excerpt externally verbatim.
