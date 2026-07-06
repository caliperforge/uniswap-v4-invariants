# C-P2: fee-direction integrity (`DemoDynamicAfterFeeHook`)

Same-source clean/planted twin pair against the real v4-core
`PoolManager` (pinned submodule, tag `v4.0.0`). No mock anywhere: the
suite deploys the real manager in-test, places the hook at an
address whose low 14 bits encode `BEFORE_SWAP | AFTER_SWAP |
AFTER_SWAP_RETURNS_DELTA`, drives every `swap` call through this
repo's own `InvariantRouter`, and lets the hook's `afterSwap` accrue
a per-currency fee ledger the invariant compares against a reference
ledger the handler maintains under the SAME direction-aware fee
ARITHMETIC OpenZeppelin's post-`2678eb9` `BaseDynamicAfterFee._afterSwap`
encodes.

The clean twin subclasses OpenZeppelin's actual audited
`BaseDynamicAfterFee` (vendored under `vendor/oz-uniswap-hooks-v1.1.0/`
from tag `v1.1.0`, first release containing the RC-2 fix at commit
`2678eb9`), and its `_afterSwap` override byte-copies the post-fix
fee-arithmetic block character-for-character. The planted twin uses
the same subclass shape and byte-copies the pre-`2678eb9` arithmetic
block in the same span. The twin diff is thus confined to the
arithmetic that `2678eb9` actually changed, not to any surrounding
line.

The class the case encodes was drawn from Zealynx's public v4-hook
write-up (2026-05-25, Pattern 4: custom-accounting drift) with the
root finding from OpenZeppelin's own Uniswap Hooks v1.1.0 RC 2 audit;
this repo cites the class provenance in the top-level `README.md` and
does not reproduce any specific hostile-input sequence verbatim. See
the "Provenance" block below for the case-README credit line.

## The design intent

On every swap the hook's `_beforeSwap` transiently stores a target
unspecified amount (this case's `_getTargetUnspecified` returns 0
with `applyTarget = true` on every swap; a production hook would
compute a non-zero target from the swap params and pool state). On
every swap the hook's `_afterSwap` reads the transient target and
applies the direction-aware fee arithmetic OZ's audited base library
encodes. Under target = 0, the resulting fee reduces to:

- exactInput: `feeAmount = unspec - 0 = unspec` (accrued to the
  unspecified currency, which is the swap OUTPUT on exactInput).
- exactOutput: `feeAmount = 0` (the exactOutput branch's guard
  `unspec < target` is false for target = 0; no accrual).

The unspecified currency is selected by the SAME expression the
audited base uses, `(params.amountSpecified < 0 == params.zeroForOne)`.
That currency-selection line was UNCHANGED across commit `2678eb9`
in `src/fee/BaseDynamicAfterFee.sol`; it pre-existed the fix and was
carried forward unchanged. What `2678eb9` actually changed was the
fee-amount ARITHMETIC below the currency selection: the pre-fix code
computed `feeAmount = uint128(unspecifiedAmount) - targetOutput`
unconditionally (assuming `unspecifiedAmount` always represented
output) and reverted with `TargetOutputExceeds()` when the target
exceeded the swap's unspecified amount. The post-fix code branches
on `exactInput` and computes `feeAmount = unspec - target` on
exactInput and `feeAmount = target - unspec` on exactOutput.

- Clean twin: `_afterSwap` runs the post-`2678eb9` fee-arithmetic
  block byte-copied from the vendored `BaseDynamicAfterFee.sol`.
- Planted twin (single-hunk diff): `_afterSwap` runs the
  pre-`2678eb9` fee-arithmetic block byte-copied from the same
  vendored file's audit-history context, reproducing the actual
  audited M-01 bug. On exactOutput swaps the planted twin computes a
  non-zero fee where the post-fix code computes zero, so the hook's
  accrued ledger diverges from the reference ledger. The invariant
  catches the divergence on the first exactOutput swap the fuzz walk
  emits.

## What the invariants assert

```
p2_dynamicfee_direction_integrity:
    hook.accruedProtocolFees(c) == handler.expectedFees(c)
```

Stateful invariant, 256 runs x depth 50 (12,800 handler calls per
campaign). The handler owns its own router (so the `sender` v4-core
reports on every swap is this handler's router) and drives all four
`(zeroForOne, exactInput)` combinations via a mode seed; the reference
`expectedFees[c]` ledger advances via the same post-`2678eb9`
fee-arithmetic the clean twin runs, so the clean twin matches by
construction and the planted twin diverges on any exactOutput swap.

- Clean twin: `accruedProtocolFees == expectedFees` on every reachable
  state; both ledgers advance identically on every swap.
- Planted twin: the first fuzzed exactOutput swap diverges the two
  ledgers. The fuzz walk shrinks the counterexample to a single call;
  the deterministic regression fires the same divergence in a scripted
  `(exactInput, exactOutput, exactInput)` sequence.

A second invariant, `p2_fee_solvency` (both twins hold by construction),
asserts that the hook's cumulative accrual per currency never exceeds
its own cumulative-unspecified-amount ledger. The check reads from the
hook only (not from the handler) so it stays a same-currency bound: a
fee-arithmetic that computes the wrong magnitude shows up as a
direction-integrity failure, not a fake solvency failure. Under
target = 0, both twins record `feeAmount = |unspec|` on any swap where
they accrue a non-zero fee, so the bound is trivially tight.

## Fee scope

The hook is a teaching-scale record-only accruer; the identity
`accrued(c) == expected(c)` is preserved regardless of which side the
handler drives the pool from, and the fuzz walk exercises all four
`(direction, exact-side)` combos so both twin behaviors are visible.

Legs (per repo convention, all four required):

| Leg | Clean twin | Planted twin |
|---|---|---|
| `invariant_p2_dynamicfeeDirectionIntegrity` | holds | fires `INVARIANT VIOLATED p2_dynamicfee_direction_integrity` |
| `invariant_p2_feeSolvency` | holds | holds (both twins accrue only a magnitude of the amount they observed) |
| `test_regression_p2_directionMismatchOnExactOutput` | ledgers stay in lockstep across the `(exactInput, exactOutput, exactInput)` sequence | ledger diverges on the exactOutput step, marker fires |
| Unit legs (hook wiring on first exactInput, exactInput-only lockstep across both twins) | pass | pass (do not touch the twin-diff path) |

## Twin diff (the fee-arithmetic block only)

```diff
--- clean/DemoDynamicAfterFeeHook.sol (post-`2678eb9` arithmetic)
+++ planted/DemoDynamicAfterFeeHook.sol (pre-`2678eb9` arithmetic)
@@ ---- inside _afterSwap, after currency selection + abs(unspec) ----
-        // Get the exact input flag
-        bool exactInput = params.amountSpecified < 0;
-
-        uint256 feeAmount;
-
-        // If the swap is exactInput, any fee should be decreased from the swap output
-        if (exactInput) {
-            // If the swap output exceeds the target, decrease it by the difference as a hook fee
-            if (unspecifiedAmount.toUint256() > targetUnspecifiedAmount) {
-                feeAmount = unspecifiedAmount.toUint256() - targetUnspecifiedAmount;
-            }
-        }
-        // If the swap is exactOutput, any fee should be increased to the swap input
-        else {
-            // If the swap input is less than the target, increase it by the difference as a hook fee
-            if (unspecifiedAmount.toUint256() < targetUnspecifiedAmount) {
-                feeAmount = targetUnspecifiedAmount - unspecifiedAmount.toUint256();
-            }
-        }
+        // Revert if the target output exceeds the swap amount
+        if (targetOutput > uint128(unspecifiedAmount)) revert TargetOutputExceeds();
+
+        // Calculate the fee amount, which is the difference between the
+        // swap amount and the target output. NOTE: this arithmetic assumes
+        // `unspecifiedAmount` always represents OUTPUT, so on exactOutput
+        // swaps (where `unspecifiedAmount` is INPUT) the fee is computed
+        // with the wrong sign convention.
+        uint256 feeAmount = uint128(unspecifiedAmount) - targetOutput;
```

The clean-twin block above is a character-for-character copy of the
vendored `BaseDynamicAfterFee.sol` @ tag `v1.1.0` (post-`2678eb9`),
lines 155-174. The planted-twin block above is the pre-`2678eb9`
arithmetic reported as M-01 in the OZ RC-2 audit. Reviewer check:
`git show 2678eb9 -- src/fee/BaseDynamicAfterFee.sol` inside the
pinned submodule at `lib/openzeppelin-uniswap-hooks/` shows the
same delta.

The planted variant is defined ONLY in our teaching-scale demo hook;
the vendored base is never mutated (rule: planted bugs live only in
our hook code, never in vendored source).

## Honest scope caveats

- The hook is a teaching-scale record-only accruer, not production
  dynamic-fee collection: it does NOT call `unspecified.take(...)` to
  mint ERC-6909 hook fees, does NOT return a hook-side delta to the
  manager, and does NOT emit `HookFee` events. That plumbing is
  present in the vendored base's `_afterSwap` but this teaching-scale
  hook overrides `_afterSwap` with a record-only shape so the swap-delta
  the handler observes is the raw pool-computed delta (unadjusted by
  a hook return-delta), which is the input the same-currency
  same-magnitude invariant comparison needs. The fee-arithmetic block
  itself is byte-faithful; only the accounting plumbing around it is
  stripped.
- A production hook that inherits `BaseDynamicAfterFee` for the same
  class would use the base's full `_afterSwap`, including the
  ERC-6909 mint, the `HookFee` emit, and the swap-delta return; the
  underlying property (`accrued == expected` under a direction-aware
  fee-arithmetic) is the same shape.
- The property catches the class the invariant encodes (direction-
  aware fee-arithmetic on the after-swap fee-basis path). A hook with
  a different target strategy or a different fee-basis expression
  needs its own reference ledger; the bring-your-hook scaffold is the
  path for that.
- The stateful campaign finds the class probabilistically. The
  deterministic regression is what fires with certainty, and only a
  known class can be scripted deterministically.
- Not a runtime guard and not an audit. This is a pre-deploy CI gate:
  the planted leg proves the suite fails loudly when the after-swap
  fee-arithmetic is direction-blind.
- The clean twin literally subclasses OpenZeppelin's audited
  `BaseDynamicAfterFee`. The vendored copy at
  `vendor/oz-uniswap-hooks-v1.1.0/` carries the OZ MIT LICENSE and a
  NOTICE that lists the three patch classes (sibling `./` imports,
  `SwapParams` referenced as `IPoolManager.SwapParams`, no
  fee-arithmetic byte altered). The submodule at
  `lib/openzeppelin-uniswap-hooks` (tag `v1.1.0`) is pinned as the
  on-disk reference against which a reviewer verifies the byte-copy.

## Running it

```
forge test --match-contract '^P2DirectionClean$' -vv    # all green, zero markers
forge test --match-contract '^P2DirectionPlanted$' -vv  # detection legs fail WITH marker
```

Scorecards: `docs/scorecards/p2-dynamicfee-direction-integrity/`.

## Provenance

> **Provenance.** The bug class this case encodes is documented in
> Zealynx's public write-up
> ["Uniswap v4 hook attacks: 4 exploit patterns with PoCs"](https://www.zealynx.io/research/protocol-deep-dives/uniswap-v4-hook-attacks)
> (2026-05-25, Pattern 4: custom-accounting drift). The specific
> fee-arithmetic-direction finding that motivates the invariant was
> reported and fixed on OpenZeppelin's own `uniswap-hooks` library
> under OpenZeppelin's
> [Uniswap Hooks v1.1.0 RC 2 audit](https://www.openzeppelin.com/news/openzeppelin-uniswap-hooks-v1.1.0-rc-2-audit)
> as finding M-01 ("Incorrect Fee Application When `unspecifiedAmount`
> Represents Input Instead of Output"). The fix landed as commit
> [`2678eb9`](https://github.com/OpenZeppelin/uniswap-hooks/commit/2678eb92ab15270837e6be5972bedf314636c529),
> released in tag `v1.1.0`. `2678eb9` remediated the fee-amount
> ARITHMETIC in `BaseDynamicAfterFee._afterSwap`: pre-fix computed
> `feeAmount = uint128(unspecifiedAmount) - targetOutput` uncondition-
> ally (assuming `unspecifiedAmount` was always output) and reverted
> with `TargetOutputExceeds()` when target exceeded unspec; post-fix
> branches on `exactInput` and computes `feeAmount = unspec - target`
> on exactInput or `feeAmount = target - unspec` on exactOutput. The
> currency-selection expression above the arithmetic block was
> unchanged across the fix. This case is a defender-side regression
> fixture on a teaching-scale synthetic hook that subclasses the
> audited fixed `BaseDynamicAfterFee` and byte-copies the pre-fix
> arithmetic into the planted twin's `_afterSwap`; it does not
> reproduce the finding against any specific deployed hook.
