# Adopt in ten minutes: wire uv4i into your CI as a pre-deploy screen

You have a Uniswap v4 hook. You want a defender-side pre-deploy screen
that runs on every PR, deploys the real `v4-core` `PoolManager` in-test,
fuzz-walks your hook against it, and prints a standing green/red
receipt on each commit. Not an audit, not a runtime guard, and not a
discovery engine for unknown bug classes. A pre-deploy screen: the
encoded properties (settlement liveness for free, plus whatever
business-logic observables you declare) run against your hook on every
commit, so a class of regression that this suite encodes cannot silently
land on `main`.

**What this actually covers, up front.** The bring-your-hook harness
deploys the real `v4-core` `PoolManager`, seeds a hooked pool through
a flag-encoded address, and drives 256 fuzz runs of depth 50 through
swaps and liquidity churn with `fail_on_revert = true`. That gives you
settlement liveness (no revert on any legit walk path, no unsettled
currency delta, no wrong selector return) as a free floor. Your hook's
business-logic properties are yours to state; the harness makes stating
them a few overrides per property. A clean-leg green run means the
properties you have encoded hold on your hook at the pinned harness
revision. It does not clear your hook of a class that no property here
encodes. The harness repo's `README.md` "what is already free" section
names the free tools this composes with (Uniswap's own suites, OZ
`uniswap-hooks`, Hacken's checker, BlockSec's `HookScan`, Chimera,
`hunterinvariants`) and the coverage map cites every claim to a file at
a pinned commit.

**Framing register.** Everything in this path is defender-side. The
seeded specification violation in the optional planted twin is a logic
error in your own synthetic copy of your own hook. The receipt is a
standing detection receipt: the invariant catches the class it
encodes. See
`agents/engineering_lead/templates/planted_twin_framing_discipline.md`
in the CaliperForge org repo for the full standard the case fixtures
comply with.

## Ten-minute path (steps 1 to 4)

Step budget: 1 to 2 about 2 min, 3 about 5 min, 4 about 3 min. Steps
5 and 6 are optional and take another 20 to 30 min if you want them.
All step timings assume you already have a v4 hook and can run
`forge test` locally.

### 1. Copy the workflow into your repo

From this harness repo, copy `adopt/pre-deploy-screen.yml` to
`.github/workflows/pre-deploy-screen.yml` in YOUR hook repo. Do not
edit the shell blocks; only the four env vars at the top need your
attention.

```sh
mkdir -p .github/workflows
curl -sSL \
  https://raw.githubusercontent.com/caliperforge/uniswap-v4-invariants/main/adopt/pre-deploy-screen.yml \
  -o .github/workflows/pre-deploy-screen.yml
```

### 2. Point HOOK_SRC and HOOK_TEST at your files

Open the workflow file and edit the four env vars:

```yaml
env:
  HOOK_SRC: src/MyHook.sol                          # path to your hook
  HOOK_TEST: test/pre-deploy-screen/MyHookScreen.t.sol  # path to your test
  UV4I_REPO: caliperforge/uniswap-v4-invariants     # leave as-is
  UV4I_REF:  079da75fa6b18e70946eaec37910a876f7d4ed00  # pin to a specific rev
```

`UV4I_REF` is pinned so a change on the harness cannot silently change
what runs in your CI. Bump it deliberately when you want the newer
properties.

### 3. Write your BYOH test file

Create the test at whatever path you set for `HOOK_TEST`. It inherits
`BYOHInvariantBase` and sets `_hookArtifact()` to the path the workflow
copies your hook to inside the harness, which is
`src/adopters/local/<basename of HOOK_SRC>:<ContractName>`.

Minimum viable test (settlement-liveness-only leg, no business-logic
observables):

```solidity
// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.26;

import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {BYOHInvariantBase} from "../../lib/uv4i-harness/BYOHInvariantBase.sol";
// If you prefer, replace the import above with a direct reference to
// the checked-out harness path. In CI, the workflow places your test
// at harness/test/bring-your-hook/, so the import can also read
// "./BYOHInvariantBase.sol". The example below uses the sibling-file
// form because that is what CI sees; a small local `remappings.txt`
// keeps `forge test` green on your workstation too. See the
// "Local dev loop" section below.

contract MyHookScreen is BYOHInvariantBase {
    function _hookArtifact() internal pure virtual override returns (string memory) {
        return "src/adopters/local/MyHook.sol:MyHook";
    }

    function _hookFlags() internal pure override returns (uint160) {
        // OR the Hooks.*_FLAG constants your hook validates in its
        // constructor. If they do not match, setUp reverts with
        // HookAddressNotValid.
        return uint160(Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG);
    }

    // Only if your constructor takes args. A BaseHook-style hook that
    // takes the PoolManager:
    function _hookConstructorArgs() internal view override returns (bytes memory) {
        return abi.encode(address(manager));
    }
}
```

What this alone gets you on every PR: the settlement-liveness floor.
Every fuzzed swap and liquidity modification your hook sees goes
through the real `PoolManager` with `fail_on_revert = true`. Any
revert, any unsettled currency delta, any wrong selector return fails
the leg. This is the H3 (flash-accounting) class as a free floor; the
harness repo's coverage map records the honest scope.

### 4. Push and read the badge

Push the branch, open a PR, watch the checks. The
`your-hook-clean-passes` job runs your test at 256 fuzz runs of depth
50 against the real `PoolManager` and reports one of:

- **OK.** `clean-passes: OK`, rc=0, no `INVARIANT VIOLATED` line in
  the log. The encoded properties hold on your hook at the pinned
  harness rev. Add the workflow's badge to your README:
  `![pre-deploy-screen](.../workflows/pre-deploy-screen.yml/badge.svg)`.
- **Not OK, revert.** A fuzzed action reverted in a path the walk
  exercises. The forge output shows the exact call sequence and the
  revert reason. Fix the hook, or if the revert is intended behavior on
  that path, gate it in `_afterSetUp` (see the "Knobs" section of
  `test/bring-your-hook/README.md`).
- **Not OK, marker printed.** An observable you declared diverged from
  its expectation. The marker string points at the property; the
  shrunk sequence points at the shortest call chain that trips it.

## Optional deeper coverage (steps 5 and 6)

Skip these on the first PR. Wire them in a second PR when you want
more than the settlement-liveness floor.

### 5. Declare your hook's own properties

Pair each hook-side accounting read with an expectation you compute
independently from the fuzz walk's ledger callbacks. The full pattern
lives in the harness repo's `test/bring-your-hook/README.md` step 6;
here is the shape.

```solidity
uint256 internal expectedFees; // YOUR ledger, YOUR semantics

function onSwap(address, bool, uint256 amountIn, bytes calldata)
    external
    override
{
    expectedFees += (amountIn * 30) / 10_000; // whatever your spec says
}

function _observables() internal view override returns (Observable[] memory o) {
    o = new Observable[](1);
    o[0] = obs("my_hook_fee_ledger", hook.accruedFees(), expectedFees);
}
```

On divergence the run fails and prints
`INVARIANT VIOLATED my_hook_fee_ledger`, the marker both CI legs
parse. Property patterns to steal, each a worked case in the harness
repo: identity (`h1`), fee ledgers (`h2`), settlement discipline
(`h3`), conservation under custom accounting (`b1`).

### 6. Optional red leg (planted twin)

Copy your hook, seed one deliberate specification violation in the
copy (flip a rounding direction, read an identity from `hookData`
instead of the sender, skip a branch of a tally), and add a twin
suite whose name ends in `Planted`. The `pre-deploy-screen` workflow
picks up any planted twin you place alongside your test (see the
comments in `pre-deploy-screen.yml` for the exact paths) and inverts
the assertion: the leg is green exactly when your seeded violation is
caught with a marker.

This is the receipt discipline: "our clean leg passes" alone is
falsifiable only against real defects; "our clean leg passes AND our
planted twin fails with our marker" is the pair that makes the receipt
mean something. The harness ships four cases end to end
(`h1`/`h2`/`h3`/`b1`), each shipped as a clean/planted twin pair, as
examples of the discipline.

## Local dev loop (before you push)

The CI wires your files into the harness on every run. Locally, you
have two options:

**Option A (simpler): clone the harness alongside your repo** and
`forge test` inside it after copying your hook and test in. The one-
liner:

```sh
git clone --recursive https://github.com/caliperforge/uniswap-v4-invariants ../uv4i
cp src/MyHook.sol ../uv4i/src/adopters/local/
cp test/pre-deploy-screen/MyHookScreen.t.sol ../uv4i/test/bring-your-hook/
cd ../uv4i && forge test --match-contract MyHookScreen -vv
```

**Option B (in-repo): vendor the harness as a submodule** at
`lib/uv4i-harness/` in your repo and add a `remappings.txt` so
`forge test` in your own repo resolves the harness base. This lets
your test live at `HOOK_TEST` in your repo and run locally too. The
CI still checks out the harness fresh at `UV4I_REF`, so the submodule
here is a workstation convenience, not a CI dependency.

## Using this as a pre-deploy screen (for audit firms)

If you are an audit firm (Zealynx, 33Audits, or similar) offering
Uniswap v4 hook engagements, adding this workflow to a client's repo
at engagement start gives you three things:

1. **A standing receipt of the settlement-liveness floor on every
   commit** between engagement start and delivery. If a commit lands
   that breaks flash-accounting settlement on the walked surface, the
   badge goes red on the commit that introduced it, not at delivery.
2. **A shared, auditable substrate for property discussion.** When you
   tell the client "add an observable for the fee accrual" and they
   push it, the CI runs it under the same fuzz walk you would use to
   reproduce a finding. The observable is the discussion object, and
   its marker string is the client's own regression handle after
   delivery.
3. **A pre-deploy gate that outlives the engagement.** After delivery,
   the client's own team keeps the workflow green through
   maintenance. If a future PR to the hook trips the marker, the PR
   author sees the receipt before it ships to mainnet.

The scope discipline is the honest sale: this is a pre-deploy screen
for the encoded classes plus whatever business-logic properties the
engagement declares. It is not a replacement for the engagement's own
manual review, reasoning about upgradeability, or the classes that no
property here encodes. The harness repo's `README.md` "what is already
free" section names the complementary tools; the coverage map cites
every claim to a file at a pinned commit.

Framing to keep on the surface, both in client-facing writeups and in
PRs opened against client repos: the receipt is what the invariant
catches, the seeded violations are logic errors in synthetic copies,
and this is not a claim of first discovery or uniqueness in the
ecosystem. See `templates/planted_twin_framing_discipline.md` in the
CaliperForge org repo for the standard the case fixtures comply with.

## What you will see when it passes, and when it catches something

**Passing clean leg (excerpt).**

```
Ran 1 test for test/bring-your-hook/MyHookScreen.t.sol:MyHookScreen
[PASS] invariant_byoh_observables_match_ledgers() (runs: 256, calls: 12800, reverts: 0)

| BYOHActions | swap            | 6441  | 0       | 0        |
| BYOHActions | modifyLiquidity | 6359  | 0       | 0        |

Suite result: ok. 1 passed; 0 failed; 0 skipped
clean-passes: OK
```

Six thousand swaps and six thousand liquidity churn ops against the
real `PoolManager`, zero reverts, zero markers. That is the standing
receipt on that commit.

**Catching a divergent observable (excerpt).**

```
Ran 1 test for test/bring-your-hook/MyHookScreen.t.sol:MyHookScreen
[FAIL: INVARIANT VIOLATED my_hook_fee_ledger]
        [Sequence]
                sender=... addr=[.../BYOHActions.sol:BYOHActions]
                        calldata=swap(...) args=[...]
                ...
clean-passes: FAIL (marker printed on the clean leg)
```

The marker names the property that diverged; the shrunk sequence is
the shortest call chain forge could find that trips it. Read up from
the sequence to the offending state transition; the observable you
declared is the reference for what the expectation should have been.

## Repo hygiene and license

The harness is Apache-2.0 (its own code) with `v4-core` vendored as a
pinned BUSL-1.1 / MIT submodule and used only for in-process
pre-deploy testing. Full attribution: `NOTICE` and `README.md` in the
harness repo. The workflow above vendors the harness at CI time via
`actions/checkout`; nothing about the workflow ships BUSL-1.1 code
into your repo or your build artifacts.

## AI disclosure

CaliperForge's authoring stack is AI-augmented. What is AI-touched in
this adoption path, and the reviews that gate it, is disclosed in
`AI_DISCLOSURE.md` in the harness repo. CI verdicts and license
posture are not AI-touched.
