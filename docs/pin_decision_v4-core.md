# v4-core pin decision: release tag v4.0.0

Pinned: `lib/v4-core` at tag `v4.0.0` = commit
`e50237c43811bd9b526eff40f26772152a42daba` (the audited release), per
build spec §3 primary. The fallback (`46c6834`, main at the feasibility
spike) was NOT needed.

## v4.0.0..46c6834 diff classification (21 commits)

Classified so case authors know what the spike report describes that
this pin does not have:

- `src/` changes are ONE refactor plus its churn: `SwapParams` and
  `ModifyLiquidityParams` moved out of `IPoolManager` into a new
  `src/types/PoolOperation.sol`. `PoolManager.sol`'s diff is import and
  signature-formatting lines only; no semantic change to swap,
  modifyLiquidity, unlock, or the flash-accounting guard. The rest of
  the touched `src/` files are v4-core's own test hooks/routers (which
  we do not import) picking up the moved types.
- Everything else in the diff is `test/` and CI/docs churn.

## Consequence for our code at this pin

The spike scratch project (written against `46c6834`) imported
`SwapParams`/`ModifyLiquidityParams` from `v4-core/src/types/PoolOperation.sol`.
At `v4.0.0` that file does not exist; the structs are nested in the
interface. All our files use the qualified form:

    IPoolManager.SwapParams
    IPoolManager.ModifyLiquidityParams

imported via `v4-core/src/interfaces/IPoolManager.sol`. Everything else
the spike proved (exact solc 0.8.26, cancun, via_ir=false, hook flag
validation, `initialize(key, sqrtPriceX96)`, `CurrencyNotSettled`
guard) is identical at the tag; the spike's three test shapes pass
unchanged apart from that import form (verified in
`test/Scaffold.t.sol`).

If a future pin bump crosses to a post-`PoolOperation.sol` commit, the
mechanical change is: import the two structs from
`v4-core/src/types/PoolOperation.sol` and drop the `IPoolManager.`
qualifier.
