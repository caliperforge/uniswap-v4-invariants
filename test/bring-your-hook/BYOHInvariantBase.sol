// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.26;

import {StdInvariant} from "forge-std/StdInvariant.sol";
import {StdUtils} from "forge-std/StdUtils.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {SwapParams, ModifyLiquidityParams} from "v4-core/src/types/PoolOperation.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {V4TestBase} from "../base/V4TestBase.sol";
import {InvariantRouter} from "../../src/routers/InvariantRouter.sol";
import {TestERC20} from "../base/TestERC20.sol";

/// One adopter-declared property line: a hook-side accounting
/// observable paired with the adopter's independently computed
/// expectation. `name` is the `INVARIANT VIOLATED <name>` marker
/// printed when the pair diverges.
struct Observable {
    string name;
    uint256 observed;
    uint256 expected;
}

/// Ledger callbacks the fuzz walk feeds back to the adopter's test
/// contract after every successful action, so expected-state ledgers
/// can be extended without the adopter touching the walk itself.
interface IBYOHLedger {
    /// hookData to attach to the next fuzzed swap. Default is empty;
    /// override when the hook consumes hookData.
    function swapHookData(uint256 seed) external view returns (bytes memory);

    function onSwap(address routerActor, bool zeroForOne, uint256 amountIn, bytes calldata hookData) external;

    function onModifyLiquidity(address routerActor, int256 liquidityDelta) external;
}

/// @title BYOHInvariantBase (bring-your-hook adoption scaffold, build spec section 5)
/// @notice Drop your hook in, inherit this base, override the small
/// surface below. The base deploys the REAL v4-core PoolManager (no
/// mock), sorted test tokens, a hooked pool with seeded liquidity, and
/// three InvariantRouter actors, then fuzz-walks swaps and liquidity
/// churn against your hook (256 runs x depth 50, house convention).
///
/// What you get without declaring anything:
///   settlement liveness. `fail_on_revert = true` means any fuzzed
///   swap or liquidity modification your hook reverts, leaves
///   unsettled (`CurrencyNotSettled`), or answers with a wrong
///   selector fails the run. That is the flash-accounting protocol
///   check (the H3 class) for free.
///
/// What you must declare yourself:
///   your hook's business-logic properties. Override `_observables()`
///   to pair each hook-side accounting read with an expectation you
///   compute independently in the `onSwap` / `onModifyLiquidity`
///   ledger callbacks. The base asserts every pair after every fuzzed
///   action and prints `INVARIANT VIOLATED <name>` on divergence.
///
/// Required overrides: `_hookArtifact()`, `_hookFlags()`.
/// Everything else has working defaults. `ExampleAdopter.t.sol` in
/// this directory is a complete adoption; the walkthrough is in this
/// directory's README.
abstract contract BYOHInvariantBase is V4TestBase, IBYOHLedger {
    BYOHActions internal actions;
    PoolKey internal poolKey;
    address internal hookAddress;

    // ------------------- required adopter surface --------------------

    /// Foundry artifact of YOUR hook, e.g.
    /// "src/adopters/my-hook/MyHook.sol:MyHook".
    function _hookArtifact() internal pure virtual returns (string memory);

    /// Permission bitmap of YOUR hook (OR of Hooks.*_FLAG constants).
    /// Must match the permissions the hook validates in its
    /// constructor; the base deploys the hook at an address encoding
    /// exactly these flags.
    function _hookFlags() internal pure virtual returns (uint160);

    // ------------------- optional adopter surface --------------------

    /// Deploy any prerequisite contracts (AccessManager, oracle, etc.)
    /// the hook's constructor needs, and cache their addresses in
    /// state your `_hookConstructorArgs()` override can read.
    /// Called BEFORE `_hookConstructorArgs()` in the setup order:
    ///     deployV4Core -> _deployPrereqs -> _hookConstructorArgs
    ///     -> deployHookTo -> initPoolWithLiquidity -> _afterSetUp.
    /// Default is a no-op; override only for hooks whose constructor
    /// takes references to contracts the harness does not know about.
    function _deployPrereqs() internal virtual {}

    /// abi.encode(...) of your hook's constructor args. `manager` is
    /// already deployed when this is called, so hooks taking the
    /// manager return abi.encode(address(manager)). Non-view so
    /// adopters MAY inline prereq deploys here directly; the cleaner
    /// pattern is `_deployPrereqs()` -> state var -> read here.
    function _hookConstructorArgs() internal virtual returns (bytes memory) {
        return "";
    }

    function _poolFee() internal pure virtual returns (uint24) {
        return 3000;
    }

    function _poolTickSpacing() internal pure virtual returns (int24) {
        return 60;
    }

    /// Per-swap exact-input cap. The default keeps worst-case
    /// one-directional volume (depth 50) inside the seeded liquidity
    /// range so no fuzzed swap exits the range or hits the price limit
    /// (fail_on_revert stays sound; same sizing math as the case
    /// handlers). Raise only with a matching liquidity raise.
    function _maxSwapAmount() internal pure virtual returns (uint256) {
        return 1e17;
    }

    /// Per-action liquidity cap for the churn walk.
    function _maxLiquidityPerAdd() internal pure virtual returns (uint256) {
        return 100e18;
    }

    /// Post-deploy wiring point: the hook and pool exist, the fuzz
    /// walk has not started. Cast `hookAddress`, set admin state, seed
    /// balances here.
    function _afterSetUp() internal virtual {}

    /// YOUR properties: pair each hook-side accounting read with the
    /// expectation your ledger callbacks maintain. Checked after every
    /// fuzzed action. Non-uint observables (addresses, bools) widen:
    /// uint256(uint160(addr)), boolVal ? 1 : 0.
    function _observables() internal view virtual returns (Observable[] memory) {
        return new Observable[](0);
    }

    /// IBYOHLedger defaults: no hookData, no ledger. Override the ones
    /// your hook's semantics need.
    function swapHookData(uint256) external view virtual returns (bytes memory) {
        return "";
    }

    function onSwap(address, bool, uint256, bytes calldata) external virtual {}

    function onModifyLiquidity(address, int256) external virtual {}

    // --------------------------- harness ------------------------------

    function setUp() public virtual {
        deployV4Core();

        actions = new BYOHActions(
            IPoolManager(address(manager)), IBYOHLedger(address(this)), token0, token1, _maxSwapAmount(), _maxLiquidityPerAdd()
        );
        // In native-pair mode token0 is the address(0) sentinel; actions
        // and each of its routers hold ETH via vm.deal instead of a mint
        // call on token0 (the routers settle native from their own balance
        // — see InvariantRouter._resolve).
        if (address(token0) != address(0)) {
            token0.mint(address(actions), 1_000_000e18);
        } else {
            vm.deal(address(actions), 1_000_000e18);
            for (uint256 i = 0; i < 3; i++) {
                vm.deal(address(actions.routers(i)), 1_000_000e18);
            }
        }
        token1.mint(address(actions), 1_000_000e18);

        // Prereqs (e.g. an AccessManager the hook's ctor takes) go
        // here; they must exist before _hookConstructorArgs() runs.
        _deployPrereqs();

        // deployCodeTo runs the constructor AT the flag-encoded
        // address, so a hook that self-validates its permissions (the
        // v4 norm) passes its own check.
        hookAddress = deployHookTo(_hookArtifact(), _hookConstructorArgs(), _hookFlags(), 0xBF);

        poolKey = initPoolWithLiquidity(IHooks(hookAddress), _poolFee(), _poolTickSpacing());
        actions.init(poolKey);

        _afterSetUp();

        // Fuzz only the walk's two action selectors; the ledger
        // callbacks and view surface are not fuzz targets.
        targetContract(address(actions));
        bytes4[] memory selectors = new bytes4[](2);
        selectors[0] = BYOHActions.swap.selector;
        selectors[1] = BYOHActions.modifyLiquidity.selector;
        targetSelector(StdInvariant.FuzzSelector({addr: address(actions), selectors: selectors}));
    }

    /// The one invariant the base owns: every adopter-declared
    /// observable equals its expectation, with the house
    /// `INVARIANT VIOLATED <name>` marker on divergence (parsed by
    /// both CI legs).
    function invariant_byoh_observables_match_ledgers() public {
        Observable[] memory declared = _observables();
        for (uint256 i = 0; i < declared.length; i++) {
            requireInvariant(declared[i].observed == declared[i].expected, declared[i].name);
        }
    }

    /// Terse constructor for observable lines inside `_observables()`.
    function obs(string memory name, uint256 observed, uint256 expected) internal pure returns (Observable memory) {
        return Observable({name: name, observed: observed, expected: expected});
    }
}

/// @title BYOHActions (the generic fuzz walk; adopters do not edit this)
/// @notice Owns three real InvariantRouter actors (each a distinct
/// `sender` identity as the hook sees it) and drives bounded exact-input
/// swaps plus per-actor liquidity churn through the real PoolManager,
/// reporting every action back to the adopter's ledger callbacks.
contract BYOHActions is StdUtils {
    IPoolManager public immutable manager;
    IBYOHLedger public immutable ledger;
    TestERC20 public immutable token0;
    TestERC20 public immutable token1;
    uint256 public immutable maxSwapAmount;
    uint256 public immutable maxLiquidityPerAdd;

    InvariantRouter[3] public routers;
    PoolKey internal poolKey;
    bool internal inited;

    /// Accept native ETH on takes (native-pair sell-side or refunds).
    receive() external payable {}

    /// Walk-owned liquidity per router actor. Removals are bounded by
    /// this, so the walk never touches the seed liquidity the base
    /// added in setUp (which keeps the swap-sizing math sound) and
    /// never reverts on over-withdrawal (fail_on_revert is on).
    mapping(uint256 => uint256) public liquidityByActor;

    /// Observability for adopters debugging a walk.
    uint256 public swapCount;
    uint256 public liquidityActionCount;

    constructor(
        IPoolManager manager_,
        IBYOHLedger ledger_,
        TestERC20 t0,
        TestERC20 t1,
        uint256 maxSwapAmount_,
        uint256 maxLiquidityPerAdd_
    ) {
        manager = manager_;
        ledger = ledger_;
        token0 = t0;
        token1 = t1;
        maxSwapAmount = maxSwapAmount_;
        maxLiquidityPerAdd = maxLiquidityPerAdd_;
        for (uint256 i = 0; i < routers.length; i++) {
            routers[i] = new InvariantRouter(manager_);
            // In native-pair mode t0 is address(0); the router settles
            // native from its own balance (funded by V4TestBase via
            // vm.deal in _afterSetUp below) instead of transferFrom on t0.
            if (address(t0) != address(0)) {
                t0.approve(address(routers[i]), type(uint256).max);
            }
            t1.approve(address(routers[i]), type(uint256).max);
        }
    }

    /// One-time wiring, called by the base's setUp. NOT a fuzz target
    /// (the base restricts fuzzed selectors to swap and
    /// modifyLiquidity).
    function init(PoolKey calldata key) external {
        require(!inited, "BYOHActions: already inited");
        inited = true;
        poolKey = key;
    }

    // ---- fuzzed actions (the ONLY selectors the base targets) ----

    /// Exact-input swap from a fuzz-chosen router actor, hookData
    /// supplied by the adopter's swapHookData override.
    function swap(uint256 actorSeed, uint256 amountSeed, bool zeroForOne, uint256 dataSeed) external {
        InvariantRouter r = routers[_bound(actorSeed, 0, routers.length - 1)];
        uint256 amount = _bound(amountSeed, 1, maxSwapAmount);
        bytes memory hookData = ledger.swapHookData(dataSeed);

        r.swap(
            poolKey,
            SwapParams({
                zeroForOne: zeroForOne,
                // exact-input per v4 convention; amount is bounded to
                // maxSwapAmount so the uint256 -> int256 cast is safe
                // forge-lint: disable-next-line(unsafe-typecast)
                amountSpecified: -int256(amount),
                sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            }),
            hookData
        );

        swapCount++;
        ledger.onSwap(address(r), zeroForOne, amount, hookData);
    }

    /// Liquidity churn: a fuzz-chosen actor adds a bounded amount, or
    /// removes a bounded share of what that same actor added earlier.
    /// A remove with nothing to remove is a no-op rather than a revert.
    function modifyLiquidity(uint256 actorSeed, uint256 liqSeed, bool add) external {
        uint256 idx = _bound(actorSeed, 0, routers.length - 1);
        InvariantRouter r = routers[idx];

        int256 liquidityDelta;
        if (add) {
            uint256 amount = _bound(liqSeed, 1e18, maxLiquidityPerAdd);
            liquidityByActor[idx] += amount;
            // bounded to maxLiquidityPerAdd, so the cast is safe
            // forge-lint: disable-next-line(unsafe-typecast)
            liquidityDelta = int256(amount);
        } else {
            uint256 current = liquidityByActor[idx];
            if (current == 0) return;
            uint256 amount = _bound(liqSeed, 1, current);
            liquidityByActor[idx] = current - amount;
            // bounded to the actor's tracked liquidity, so the cast is safe
            // forge-lint: disable-next-line(unsafe-typecast)
            liquidityDelta = -int256(amount);
        }

        r.modifyLiquidity(
            poolKey,
            ModifyLiquidityParams({
                tickLower: -10 * poolKey.tickSpacing,
                tickUpper: 10 * poolKey.tickSpacing,
                liquidityDelta: liquidityDelta,
                salt: 0
            }),
            ""
        );

        liquidityActionCount++;
        ledger.onModifyLiquidity(address(r), liquidityDelta);
    }
}
