# Bring your hook

Point this harness at YOUR v4 hook and get a stateful invariant walk
against the real PoolManager (no mock, no fork) in under an hour. You
do not need to read any harness internals for the basic path: you
inherit one base contract, override a handful of small functions, and
run `forge test`.

Honest framing, up front: the scaffold supplies the harness and the
property patterns. It deploys the real v4-core PoolManager, seeds a
hooked pool, and fuzz-walks swaps and liquidity churn through it, so
settlement liveness (every action settles; no revert, no unsettled
delta, no wrong selector return) is checked for free. Your hook's
business-logic properties are yours to state: only you know what your
hook's accounting is supposed to do. That is the point of the
exercise, and no tool that skips this step is checking your logic.

## Walkthrough: clone to green in numbered steps

Rough time budget for a first adoption: steps 1 to 3 about 10
minutes, steps 4 to 6 about 20 to 30 minutes.

1. **Clone with submodules and sanity-check the toolchain** (v4-core's
   own sources import its nested submodules; solc 0.8.26 exactly and
   evm cancun are pinned in `foundry.toml`, so plain `forge` commands
   just work):

   ```sh
   git clone --recursive <this-repo>
   cd uniswap-v4-invariants
   forge test --match-contract ExampleAdopterTest -vv
   ```

   Green here means the toolchain and the example adoption both work
   on your machine.

2. **Drop your hook in** under `src/adopters/<your-name>/`:

   ```sh
   mkdir -p src/adopters/my-hook
   cp <your>/MyHook.sol src/adopters/my-hook/
   ```

   Requirements: the pragma must accept solc 0.8.26 (`^0.8.24` and
   the like are fine; everything compiles with the pinned 0.8.26),
   and the hook must validate its own permissions in its constructor,
   which is the v4 norm (raw `IHooks` implementations calling
   `Hooks.validateHookPermissions`, and `BaseHook`-style bases doing
   it for you, both qualify).

3. **Add your hook's base library, if it has one.** The repo ships
   only `v4-core` and `forge-std`. For a hook built on OpenZeppelin's
   uniswap-hooks, for example:

   ```sh
   git submodule add https://github.com/OpenZeppelin/uniswap-hooks lib/uniswap-hooks
   ```

   and add its remapping to `foundry.toml`'s `remappings` list, e.g.
   `"uniswap-hooks/=lib/uniswap-hooks/src/"`. Your dependency's own
   `remappings.txt` (or `forge remappings` run inside it) shows the
   prefixes it expects; its `v4-core/...` imports already resolve
   through this repo's existing remapping.

4. **Write your test** at `test/bring-your-hook/MyHook.t.sol`,
   starting from this template (this is the whole required surface):

   ```solidity
   // SPDX-License-Identifier: Apache-2.0
   pragma solidity 0.8.26;

   import {Hooks} from "v4-core/src/libraries/Hooks.sol";
   import {BYOHInvariantBase, Observable} from "./BYOHInvariantBase.sol";
   import {MyHook} from "../../src/adopters/my-hook/MyHook.sol";

   contract MyHookTest is BYOHInvariantBase {
       MyHook internal hook;

       function _hookArtifact() internal pure override returns (string memory) {
           return "src/adopters/my-hook/MyHook.sol:MyHook";
       }

       /// OR of the Hooks.*_FLAG constants matching the permissions
       /// your hook validates in its constructor.
       function _hookFlags() internal pure override returns (uint160) {
           return uint160(Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG);
       }

       /// Only if your constructor takes args. A BaseHook-style hook
       /// taking the manager:
       function _hookConstructorArgs() internal view override returns (bytes memory) {
           return abi.encode(address(manager));
       }

       function _afterSetUp() internal override {
           hook = MyHook(hookAddress);
           // admin wiring, balance seeding, anything your hook needs
       }
   }
   ```

5. **Run it:**

   ```sh
   forge test --match-contract MyHookTest -vv
   ```

   Green means your hook survived 256 runs x depth 50 of fuzzed
   swaps and liquidity churn against the real PoolManager with
   `fail_on_revert` on: no revert on any legit path, no unsettled
   currency delta, no wrong selector return. That is the clean leg,
   and steps 1 to 5 required zero knowledge of harness internals.

6. **Declare your hook's own properties.** Pair each hook-side
   accounting observable with an expectation you compute
   independently, then let the base assert every pair after every
   fuzzed action:

   ```solidity
   uint256 internal expectedFees; // your ledger, YOUR semantics

   /// Called after every fuzzed swap; extend your ledger here.
   function onSwap(address routerActor, bool zeroForOne, uint256 amountIn, bytes calldata hookData)
       external
       override
   {
       expectedFees += (amountIn * 30) / 10_000; // whatever YOUR spec says
   }

   function _observables() internal view override returns (Observable[] memory o) {
       o = new Observable[](1);
       o[0] = obs("my_hook_fee_ledger", hook.accruedFees(), expectedFees);
   }
   ```

   On divergence the run fails and prints `INVARIANT VIOLATED
   my_hook_fee_ledger`, the marker both CI legs parse. There is also
   `onModifyLiquidity` for liquidity-side ledgers and
   `swapHookData(seed)` to feed your hook fuzzed hookData.

   Property patterns to steal, each a worked case in this repo:
   identity (whoever your hook credits must be the sender it actually
   saw: `test/h1/`), fee ledgers (accrued fees match an independently
   computed expectation: `test/h2/`), settlement discipline
   (`test/h3/`), and conservation under custom accounting (redeemable
   value never exceeds deposits net of fees: `test/b1/`).

7. **Optional red leg: prove your suite catches.** Copy your hook,
   seed ONE deliberate specification violation in the copy (flip a
   rounding direction, read an identity from hookData instead of the
   sender, skip a branch of a tally), and add a twin suite whose name
   ends in `Planted`:

   ```solidity
   contract MyHookPlanted is MyHookTest {
       function _hookArtifact() internal pure override returns (string memory) {
           return "src/adopters/my-hook/planted/MyHook.sol:MyHook";
       }
   }
   ```

   (Make `_hookArtifact` in your clean suite `virtual override` so the
   twin can re-point it.) The twin must FAIL with your marker; if it
   stays green, your properties are not sensitive to that defect and
   need tightening. `ExamplePlanted.t.sol` in this directory is this
   pattern end to end.

8. **CI.** `.github/workflows/bring-your-hook.yml` runs in your fork
   as-is: `your-hook-clean-passes` (rc=0, zero markers) and
   `your-planted-mutation-fails` (inverted assertion: green exactly
   when every `Planted` suite fails with a marker; vacuously green if
   you skipped step 7). If your suite lives elsewhere, edit the
   `BYOH_MATCH_PATH` env var at the top of the workflow and nothing
   else.

## Knobs, if the defaults fight your hook

All optional overrides on `BYOHInvariantBase`, with working defaults:
`_poolFee()` (3000), `_poolTickSpacing()` (60), `_maxSwapAmount()`
(1e17, sized so the fuzz walk never exits the seeded liquidity range),
`_maxLiquidityPerAdd()` (100e18).

### Pool shape: native/ERC20 vs the default two-ERC20

The default pool is `(TokenA, TokenB)` — two plain `TestERC20`s. Hooks
that gate their real logic on the pool containing native ETH
(`Currency.wrap(address(0))`) — a common shape for protocol-fee-on-ETH
patterns — never reach that logic on the default pool and would pass
the settlement-liveness walk vacuously. Override two virtuals on
`BYOHInvariantBase` to opt into a `(native, ERC20)` pool:

```solidity
function _useNativePair() internal view override returns (bool) {
    return true;
}

/// Only override when your hook interrogates the token (isStarted(),
/// start(), ...). Return a TestERC20 subclass that satisfies your
/// hook's expected token surface without breaking the ERC20 shape
/// the router uses for settlement.
function _deployQuoteToken() internal override returns (TestERC20) {
    return new MyStartableTestERC20();
}
```

In native-pair mode the harness deploys only the quote token, seeds
the pool with liquidity across `(address(0), quote)`, funds each fuzz
router with ETH via `vm.deal`, and settles native-side deltas via
`PoolManager.settle{value: ...}()` from the router's balance. Nothing
else in the adopter surface changes; the walk, observables, and
ledger callbacks are shape-agnostic.

### Non-vacuous properties (reachability discipline)

Settlement liveness alone is a reachability-blind check: it passes
even when the fuzz walk never exercises the code paths your hook's
gate protects. If your hook has a tracked-pool gate (a `if
(_isTrackedPool(key))` short-circuit at the top of `_beforeSwap` /
`_afterSwap`), pair a hook-side counter that only advances inside
that gate with a ledger-side counter that increments on every
`onSwap`. When the two diverge the walk fails with your marker; when
they agree over the full walk the pass is genuinely non-vacuous
(every fuzzed action took the tracked-pool branch you care about).

## Troubleshooting

- `HookAddressNotValid` or a constructor revert in `setUp`:
  `_hookFlags()` does not match the permissions your hook validates.
  The two must agree exactly.
- `vm.getCode: no matching artifact found`: the `_hookArtifact()`
  string must be `path/from/repo/root/File.sol:ContractName`, and the
  file must be part of the build (hooks under `src/` always are).
- A failing walk with a plain revert (no marker): `fail_on_revert` is
  on, so a hook that reverts on a path the walk exercises fails the
  run. If the revert is intended behavior, gate it in `_afterSetUp`
  configuration or shrink `_maxSwapAmount()`; if not, the harness
  just found its first finding.
