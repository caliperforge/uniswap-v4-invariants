# C-H1: reward-recipient identity from hookData (`RewardsHook`)

Same-source clean/planted twin pair against the real v4-core
`PoolManager` (pinned submodule, tag `v4.0.0`). No mock anywhere: the
suite deploys the real manager in-test, places the hook at a
beforeSwap+afterSwap flag address, and drives swaps through this repo's
own `InvariantRouter` and the real unlock/flash-accounting path.

## The bug class

A hook credits per-swap rewards (points, rebates, referral credit) to a
recipient, and the load-bearing question is where the recipient
identity comes from. `sender` (the first argument of every hook
callback) is an identity the manager supplies from the call context:
the v4-core `IHooks` natspec defines it as "The initial msg.sender for
the swap call", i.e. the router contract that called
`PoolManager.swap`. `hookData` is the opposite: "Arbitrary data handed
into the PoolManager by the swapper to be be passed on to the hook"
(quoted verbatim, including the upstream doubled word, from
`lib/v4-core/src/interfaces/IHooks.sol` at commit `e50237c`, the
`v4.0.0` tag). A hook that keys an identity decision to hookData lets
whoever crafts the swap calldata direct the credit to any address.

The seeded defect is a source-of-truth specification violation in our
own synthetic hook: the reward recipient must come from the call
context (`sender`), and the planted twin reads it from caller-supplied
`hookData` instead.

- Clean twin: recipient = `sender`, the manager-forwarded msg.sender of
  `PoolManager.swap`. hookData plays no part in the identity decision.
- Planted twin (single line, shown below): when `hookData` carries an
  ABI-encoded address, that address becomes the recipient. Swaps with
  empty hookData still credit `sender`, which is exactly what makes the
  bug shape realistic: conformance-style tests that never populate
  hookData keep passing while the identity property is broken.

Comparator and audit-literature citations for this class are
consolidated file-by-file in `docs/coverage_map.md` (built by the
coverage-map ticket, not duplicated here).

## Hook shape

`RewardsHook` implements the `IHooks` callback surface directly
(no v4-periphery BaseHook): `beforeSwap` + `afterSwap` permission
flags, constructor self-validates via `Hooks.validateHookPermissions`,
correct selector returns on both callbacks (the manager reverts on a
wrong selector). `beforeSwap` counts swap starts; `afterSwap` credits
exactly one reward point. Two observables fall out:

- Identity: `rewardsTo[R]` per recipient R. The planted twin breaks
  this one.
- Conservation: `swapsStarted == totalRewards` after any sequence of
  completed swaps. Holds on BOTH twins (the planted twin moves credit
  between identities; it never mints or loses points), which is why a
  totals-only test cannot catch the class.

## What the invariant asserts

```
h1_rewards_identity:
    hook.rewardsTo(R) == handler.swapsByRouter(R) for every router R
```

Stateful invariant, 256 runs x depth 50 (12,800 handler calls per
campaign). The handler owns three real router actors (each a distinct
`sender` identity as the hook sees it, real contracts rather than
impersonated addresses) and fuzzes exact-input swaps in both directions
with hookData that is empty, names the performing router itself, or
names a different router. The expected ledger extends by CLEAN
semantics only: credit follows the router that performed the swap,
hookData never consulted.

- Clean twin: ledgers stay in lockstep for every reachable state.
- Planted twin: the first fuzzed swap whose hookData names a different
  address diverges the ledgers. The fuzzer shrinks the counterexample
  to that single call.

Legs (per repo convention, all three required):

| Leg | Clean twin | Planted twin |
|---|---|---|
| `invariant_h1_rewardsTo_match_swapsByRouter` | holds | fires `INVARIANT VIOLATED h1_rewards_identity` |
| `test_regression_h1_hookDataNamesDifferentRecipient` | credit lands on the performing router | credit lands on the hookData-named address, marker fires |
| Unit leg (credit-to-sender, conservation, manager gate) | passes | passes (does not touch the bug path) |

The deterministic regression leg encodes the class in one fixed
sequence: router A performs one swap while the hookData names router
B's address as recipient. On the clean twin the credit lands on A and B
stays at zero; on the planted twin the invariant fires at that first
divergent swap and the run exits nonzero. The sequence stops at the
first violation; it detects, nothing more.

## Twin diff (the recipient-source line only)

```diff
--- clean/RewardsHook.sol
+++ planted/RewardsHook.sol
@@ -97,7 +97,7 @@
         bytes calldata hookData
     ) external returns (bytes4, int128) {
         if (msg.sender != address(manager)) revert NotManager();
-        address recipient = sender;
+        address recipient = hookData.length >= 32 ? abi.decode(hookData, (address)) : sender;
         rewardsTo[recipient] += 1;
         totalRewards += 1;
         emit RewardCredited(recipient, 1);
```

The twins are byte-identical apart from this line, including the
callback signatures and every comment. That is deliberate: the doc
comment above `afterSwap` states the recipient specification in both
files, and the planted twin's assignment line is the one place the code
violates it. The clean twin's named-but-unused `hookData` parameter is
the accepted cost of keeping the diff to the assignment line alone
(one solc 5667 warning, documented in the source).

## Honest scope caveats

- The hook is a teaching-scale points ledger, not a production rewards
  system: one point per swap into an internal counter, no token
  minting, no claim path, no reward weighting by swap size. The
  identity property is independent of reward sizing, which is why the
  fixed per-swap point keeps the expected ledger exact.
- The property catches the class the invariant encodes (per-identity
  credit diverging from the call-context sender). A hook with a
  different rewards architecture needs its own expected-state model;
  the bring-your-hook scaffold is the path for that.
- hookData has many legitimate uses (slippage hints, referral tags,
  routing metadata). The case does not say "never read hookData"; it
  says identity must not come from it. The invariant only fires when
  the credited identity diverges from `sender`.
- Not a runtime guard and not an audit. This is a pre-deploy CI gate:
  the planted leg proves the suite fails loudly when the recipient
  source of truth is wrong.

## Scorecards

Raw captured runs: `docs/scorecards/h1-hookdata-identity/scorecard.clean.md`
and `docs/scorecards/h1-hookdata-identity/scorecard.planted.md`.
