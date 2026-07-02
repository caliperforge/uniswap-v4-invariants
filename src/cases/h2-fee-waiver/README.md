# C-H2: fee waiver via hookData (`FeeSwitchHook`)

Same-source clean/planted twin pair against the real v4-core
`PoolManager` (pinned submodule, tag `v4.0.0`). No mock anywhere: the
suite deploys the real manager in-test, places the hook at an
afterSwap-only flag address, and drives swaps through this repo's own
`InvariantRouter` and the real unlock/flash-accounting path.

## The bug class

A hook charges a fee unless the swap is waived, and the load-bearing
question is where the waiver decision comes from. `sender` (the first
argument of every hook callback) is an authenticated identity: the
v4-core `IHooks` natspec defines it as "The initial msg.sender for the
swap call", i.e. the router contract that called `PoolManager.swap`.
`hookData` is the opposite: "Arbitrary data handed into the PoolManager
by the swapper to be be passed on to the hook" (quoted verbatim,
including the upstream doubled word, from
`lib/v4-core/src/interfaces/IHooks.sol` at commit `e50237c`, the
`v4.0.0` tag). A hook that wires fee policy (waivers, rebates,
allowlists) to hookData hands fee policy to whoever crafts the swap
calldata.

- Clean twin: the waiver comes from an admin-set allowlist mapping
  keyed by `sender`. hookData plays no part in the fee decision.
- Planted twin (single hunk, shown below): the waiver is ALSO honored
  when the swapper-supplied `hookData[0]` equals `0x01`. The admin path
  still works, which is exactly what makes the bug shape realistic: the
  legitimate tests of the allowlist keep passing while any unprivileged
  swapper zeroes their own fee.

Comparator and audit-literature citations for this class are
consolidated file-by-file in `docs/coverage_map.md` (built by the
coverage-map ticket, not duplicated here).

## Fee sizing (decided in the build spec, section 3)

The fee is sized on the swap's SPECIFIED amount:
`-params.amountSpecified` for exact-input swaps, the absolute value in
general. It is NOT sized on the realized `BalanceDelta`. This keeps the
test-side expected-fee ledger exact and path-independent under
concentrated liquidity: expected fees depend only on the sequence of
specified amounts and allowlist states, never on pool price or
liquidity. The trade-off is acknowledged: a production fee hook might
size on realized amounts; this case is about the waiver source, and the
sizing rule is identical on both twins.

## What the invariant asserts

```
h2_fee_waiver_via_hookdata:
    hook.accruedFees() == handler.expectedFees()
```

Stateful invariant, 256 runs x depth 50 (12,800 handler calls per
campaign). The handler owns three real router actors, fuzzes exact-input
swaps in both directions with and without the waiver byte in hookData,
and churns the allowlist through the legitimate admin path, mirroring
it in its model. The expected ledger extends by CLEAN semantics only:
allowlisted router pays zero, everyone else pays
`amount * FEE_BPS / 10_000`, hookData never consulted.

- Clean twin: ledgers stay in lockstep for every reachable state.
- Planted twin: the first fuzzed swap that claims the hookData waiver
  from a non-allowlisted router diverges the ledgers. The fuzzer
  shrinks the counterexample to that single call.

Legs (per repo convention, all three required):

| Leg | Clean twin | Planted twin |
|---|---|---|
| `invariant_h2_accruedFees_match_expected` | holds | fires `INVARIANT VIOLATED h2_fee_waiver_via_hookdata` |
| `test_regression_h2_unentitledWaiverViaHookData` | fee charged in full despite crafted hookData | unentitled swapper's fee zeroed, marker fires |
| Unit leg (fee sizing, allowlist waiver, admin gate) | passes | passes (does not touch the bug path) |

The deterministic regression leg scripts the canonical regression sequence
end-to-end: a fresh, never-allowlisted router swaps 1e18 exact-input with
hookData `0x01`. On the clean twin the full fee (3e15) accrues; on the
planted twin the unentitled swapper pays zero.

## Twin diff (the waiver source only)

```diff
--- clean/FeeSwitchHook.sol
+++ planted/FeeSwitchHook.sol
@@ -87,11 +87,12 @@
         emit ExemptUpdated(sender, exempt);
     }
 
-    /// Waiver policy: ONLY the admin-set allowlist decides. hookData is
-    /// untrusted, swapper-supplied input and plays no part in the fee
-    /// decision.
-    function _isWaived(address sender, bytes calldata) internal view returns (bool) {
-        return feeExempt[sender];
+    /// Waiver policy (PLANTED BUG, the single-hunk twin diff): the
+    /// waiver is ALSO honored from swapper-supplied hookData, on top of
+    /// the admin allowlist. Any unprivileged swapper zeroes their own
+    /// fee by passing hookData whose first byte is 0x01.
+    function _isWaived(address sender, bytes calldata hookData) internal view returns (bool) {
+        return feeExempt[sender] || (hookData.length > 0 && hookData[0] == 0x01);
     }
 
     function afterSwap(
```

## Honest scope caveats

- The hook is a teaching-scale fee ledger, not production fee
  collection: fees accrue to an internal counter denominated in raw
  units of each swap's specified currency (token0 and token1 units mix
  in one total; both twins and the handler apply the identical rule, so
  the property is exact). No claim tokens, no withdrawal path.
- Fee on the specified amount means a swap that partially fills against
  a price limit is still charged on the full specified amount. The
  fuzz campaign bounds swap sizes so fills are always complete; the
  sizing rule is a build-spec decision, identical on both twins.
- The property catches the class the invariant encodes (fee accrual
  diverging from admin-only waiver semantics). A hook with a different
  fee architecture needs its own expected-fee model; the bring-your-hook
  scaffold is the path for that.
- Not a runtime guard and not an audit. This is a pre-deploy CI gate:
  the planted leg proves the suite fails loudly when the waiver source
  is wrong.

## Planned M2 expansion (named, not built here)

The dynamic-fee-override variant of this class: on a dynamic-fee pool
(`LPFeeLibrary.DYNAMIC_FEE_FLAG`, `0x800000`), `beforeSwap`'s returned
`uint24` can override the LP fee for the swap. A hook that derives that
override (or a zero-fee override) from unauthenticated hookData is the
same bug class expressed through the fee-override return path instead
of an internal ledger. That variant is grant milestone M2 scope per the
build spec (section 9) and is deliberately not built in this case.

## Scorecards

Raw captured runs: `docs/scorecards/h2-fee-waiver/scorecard.clean.md`
and `docs/scorecards/h2-fee-waiver/scorecard.planted.md`.
