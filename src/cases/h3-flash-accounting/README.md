# C-H3: settle protocol on the flash-accounting surface (`FlashHook`)

Same-source clean/planted twin pair against the real v4-core
`PoolManager` (pinned submodule, tag `v4.0.0`). No mock anywhere: the
suite deploys the real manager in-test, places the hook at a
beforeSwap-only flag address, and drives swaps through this repo's own
`InvariantRouter` and the real unlock/flash-accounting path.

## The bug class

v4's flash accounting is a protocol with a contract: any currency a
contract moves out of the `PoolManager` mid-unlock (via `take`) books a
negative delta against that contract, and every delta must be zero
when the unlock ends. Closing a debt is a three-step dance, in order:
`sync(currency)` snapshots the manager's currency balance, an ERC20
transfer pays the owed amount to the manager, and `settle()` books the
payment against the delta. The manager enforces the contract with a
transient-storage counter (`NonzeroDeltaCount`) and reverts the entire
unlock with `CurrencyNotSettled` if any delta is still open at the end
(`lib/v4-core/src/PoolManager.sol`, commit `e50237c`, the `v4.0.0`
tag).

A hook that pays out currency from inside a swap callback is on this
surface whether its author thinks about it or not. This case's
synthetic `FlashHook` pays a fixed currency0 bonus to the swap sender
when the swapper opts in via hookData:

- Clean twin: the bonus path performs the full dance. `take` opens the
  delta, then `sync`, an ERC20 transfer from the hook's own pre-funded
  balance, and `settle` close it. The bonus really moves balances and
  the unlock ends with zero delta.
- Planted twin (single hunk, shown below): the same `take`, and no
  settle step. The seeded specification violation is the hook opening
  a debt against the manager on the bonus path and never closing it.
  Every swap that opts into the bonus now reverts in its entirety with
  `CurrencyNotSettled`.

Comparator and audit-literature citations for this class are
consolidated file-by-file in `docs/coverage_map.md` (built by the
coverage-map ticket, not duplicated here).

## The observable (decided in the build spec, section 3)

The manager's delta state lives in transient storage, so nothing is
inspectable after the revert. The handler therefore try/catches every
router call and counts reverts carrying the
`IPoolManager.CurrencyNotSettled` selector; any other revert is
rethrown so the campaign fails loudly rather than miscounting.

## What the invariant asserts

```
h3_flash_accounting:
    handler.settleGuardReverts() == 0
```

Stateful invariant, 256 runs x depth 50 (12,800 handler calls per
campaign). The handler owns three real router actors and fuzzes
exact-input swaps in both directions, with and without the bonus
opt-in byte (`0xBB`) in hookData.

- Clean twin: the settle dance closes every bonus delta; the count
  stays zero for every reachable state.
- Planted twin: the first fuzzed swap that opts into the bonus trips
  the real manager's guard. The fuzzer shrinks the counterexample to
  that single call.

Legs (per repo convention, all three required):

| Leg | Clean twin | Planted twin |
|---|---|---|
| `invariant_h3_bonusPathSettles` | holds | fires `INVARIANT VIOLATED h3_flash_accounting` |
| `test_regression_h3_takeWithoutSettleTripsGuard` | bonus swap completes, balances move, delta closes | swap reverts `CurrencyNotSettled`, marker fires |
| Unit leg (benign path, manager gate, funding precondition) | passes | passes (does not touch the bonus path) |

The deterministic regression leg is the feasibility spike's test 3
shape verbatim: a benign swap (no opt-in byte) completes on both
twins, then a fixed 1e18 exact-input swap opts into the bonus path. On
the clean twin the sender router receives the bonus and the hook's
funding drops by exactly that amount; on the planted twin the whole
swap reverts and the marker fires.

## Twin diff (the missing settle step only)

```diff
--- clean/FlashHook.sol
+++ planted/FlashHook.sol
@@ -93,15 +93,11 @@
         // Open: the manager pays BONUS out to the swap sender and books
         // a -BONUS delta against this hook.
         manager.take(currency, to, BONUS);
-        // Close: the settle dance the flash-accounting protocol
-        // requires. sync snapshots the manager's currency balance, the
-        // ERC20 transfer pays the debt from this hook's own funding,
-        // settle books the payment and zeroes the delta.
-        manager.sync(currency);
-        if (!IERC20Minimal(Currency.unwrap(currency)).transfer(address(manager), BONUS)) {
-            revert BonusTransferFailed();
-        }
-        manager.settle();
+        // PLANTED BUG (the single-hunk twin diff): the settle step is
+        // missing. The take above opened a -BONUS delta this hook never
+        // closes, violating the sync -> transfer -> settle contract;
+        // the manager's flash-accounting guard reverts the whole unlock
+        // with CurrencyNotSettled when it ends.
         bonusPaid += BONUS;
         emit BonusPaid(to, BONUS);
     }
```

## Honest scope caveats (sizing this case correctly)

- The real manager's transient-storage guard already catches this
  violation at runtime: an unsettled hook delta reverts the unlock, so
  this is NOT a live loss condition on v4. No funds can be removed
  from the manager this way.
- What the runtime guard turns it into is an availability failure: a
  hook that ships this bug reverts every user swap that touches its
  broken path, in production, after deployment. The value of this case
  is converting that production availability failure into a pre-deploy
  CI failure, with the planted leg proving the suite fails loudly when
  the settle step is missing. Exactly that, nothing bigger.
- The coverage map records the real v4 runtime guard
  (`PoolManager.sol`, `CurrencyNotSettled`) as partial coverage of
  this class; our addition is the pre-deploy regression gate, not the
  guard itself.
- The hook is a teaching-scale fixture: a fixed bonus, one currency,
  hookData opt-in. A production hook's flash-accounting interactions
  (return deltas, multi-currency dances) need their own properties;
  the bring-your-hook scaffold is the path for that.
- Not a runtime guard and not an audit.

## Scorecards

Raw captured runs:
`docs/scorecards/h3-flash-accounting/scorecard.clean.md` and
`docs/scorecards/h3-flash-accounting/scorecard.planted.md`.
