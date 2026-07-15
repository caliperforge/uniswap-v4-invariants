# PR template: offer to wire the uv4i pre-deploy screen into a hook team's repo

Use this when CaliperForge (or the CEO on our behalf) offers to open
the integration PR on a hook team's or audit firm's repo. Keep it
short, honest, one link. The give is "we wire it in, you review." No
uniqueness claim, no would-have-caught claim, no ask beyond a merge or
a redirect.

The four fill-ins are at the top; the body below is the copy-paste PR
description.

---

**Fill in before opening the PR:**
- `<TEAM_NAME>`: the hook team or audit firm's name.
- `<HOOK_SRC_PATH>`: the path to their hook Solidity file in their
  repo, e.g. `src/RewardsHook.sol`.
- `<HOOK_NAME>`: the Solidity contract name.
- `<HOOK_FLAGS_OR>`: the OR of `Hooks.*_FLAG` constants matching the
  permissions the hook validates in its constructor.

---

## PR title

`pre-deploy-screen: add uv4i bring-your-hook CI (defender-side, no runtime change)`

## PR description (copy-paste body)

Hi `<TEAM_NAME>` team,

We are CaliperForge. We maintain
[uniswap-v4-invariants](https://github.com/caliperforge/uniswap-v4-invariants),
a defender-side pre-deploy screen for v4 hooks: it deploys the real
`v4-core` `PoolManager` in-test, seeds a hooked pool at a flag-encoded
address, and fuzz-walks swaps and liquidity churn against the hook
under test (256 runs of depth 50, `fail_on_revert = true`).

This PR adds one file:
`.github/workflows/pre-deploy-screen.yml`.

**What it does.** On every push and PR, it checks out this repo and
the uv4i harness (pinned by commit SHA), copies `<HOOK_SRC_PATH>` and
a small BYOH test into the harness, and runs the invariant walk. The
job passes when the encoded properties hold on your hook at the pinned
harness rev, and fails with the shrunk call sequence when they do not.
The walk is bounded (worst-case volume stays inside the seeded
liquidity range) so it does not hit the price limit or exit range on
its own; any revert or unsettled delta is a real signal.

**What it is not.** Not an audit, not a runtime guard, not a discovery
engine for unknown bug classes. Not a claim of first discovery or
uniqueness. The harness repo's README ("what is already free"
section) names the free tools this composes with (Uniswap's own
suites, OpenZeppelin `uniswap-hooks`, Hacken's checker, BlockSec's
`HookScan`, Chimera, `hunterinvariants`), and the coverage map cites
every claim to a file at a pinned commit. A green run means the
encoded properties hold; it does not clear the hook of a class no
property here encodes.

**Runtime footprint.** Zero. Nothing in this PR changes your hook,
your deployment artifacts, or any dependency on your production path.
The workflow is CI-only.

**What you would review.**
- One YAML file: the workflow.
- One Solidity file we wrote for you (`test/pre-deploy-screen/<HOOK_NAME>Screen.t.sol`):
  the bring-your-hook test that names your hook, its flags
  (`<HOOK_FLAGS_OR>`), and its constructor args. Two required
  overrides, plus an `_afterSetUp` for typed access to the deployed
  hook. Around 40 lines.
- One README pointer in the top-level README noting the badge, if you
  want it visible.

**How to run it locally before merging:**
```sh
git clone --recursive https://github.com/caliperforge/uniswap-v4-invariants ../uv4i
cp <HOOK_SRC_PATH> ../uv4i/src/adopters/local/
cp test/pre-deploy-screen/<HOOK_NAME>Screen.t.sol ../uv4i/test/bring-your-hook/
cd ../uv4i && forge test --match-contract <HOOK_NAME>Screen -vv
```
Expected: `[PASS] invariant_byoh_observables_match_ledgers()` with
256 runs, 12,800 calls, 0 reverts, 0 markers. If it fails on your
hook out of the box on a path you did not expect the walk to exercise,
that is worth a message either way, either the harness config needs
a knob (`_maxSwapAmount`, pool fee, tick spacing) or the finding is
real.

**If you would rather write it yourselves,** the ten-minute
integration guide is at
[`adopt/README.md`](https://github.com/caliperforge/uniswap-v4-invariants/blob/main/adopt/README.md)
in the harness repo. This PR is the "we will wire it in, you review"
version of that same path.

**If this is not for you,** no worries; feel free to close. If it is
almost right but you want the walk to declare a business-logic
property that only your team can state (a fee ledger, a share-price
observable, an identity check), tell us the observable and we will
extend the test in a follow-up commit.

The four case fixtures in the harness repo
(`src/cases/{h1,h2,h3,b1}/`) are worked examples of the property
patterns, each shipped as a clean/planted twin pair so there is a
standing receipt that each property catches the class it encodes. The
planted twins are seeded specification violations in synthetic copies
of our own hooks, per the framing standard at
`agents/engineering_lead/templates/planted_twin_framing_discipline.md`.

Thanks for reading. We are happy to iterate on the smallest possible
diff.

--- CaliperForge

---

## Notes for the sender (do not paste)

- **Do not** claim the screen would have caught any specific past
  incident. It is a regression fixture for the encoded classes, not a
  reproduction of any incident. The B1 case's honest framing is the
  model: cite once as motivation, do not reproduce as a receipt.
- **Do not** claim uniqueness against other tools. The `Unique across
  comparators?` column in the coverage map is the only place any
  uniqueness claim lives, and only for rows empty across every free
  comparator at the pinned commit.
- **Do use** the "defender-side pre-deploy screen" framing on the
  surface. Not offense-side framing, not discovery-engine framing.
- **Keep the ask small.** One workflow file plus one test file. If
  the team wants observables extended, that is a follow-up commit on
  the same PR, not a re-scope.
- **Framing discipline reference:**
  `agents/engineering_lead/templates/planted_twin_framing_discipline.md`.
  Grep the PR body against the word-ban list named there (plus
  em-dashes) before hitting Submit.
