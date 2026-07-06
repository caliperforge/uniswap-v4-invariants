// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.26;

import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IERC20Minimal} from "v4-core/src/interfaces/external/IERC20Minimal.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {Position} from "v4-core/src/libraries/Position.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";

/// @title LiquidityPenaltyHook (case C-P1: liquidity-penalty conservation)
/// @notice A teaching-scale hook that mirrors the add-time fee-state guard
/// pattern published in OpenZeppelin's `LiquidityPenaltyHook` (v1.2.0,
/// under `OpenZeppelin/uniswap-hooks/src/general/`). Design intent, in
/// plain terms: a liquidity provider that adds a position and removes it
/// within a short window donates a share of the fees the position earned
/// during that window back to the in-range LPs, so a position cannot add,
/// harvest, and remove in the same or adjacent block without giving back
/// the fees it collected on that timescale.
///
/// The accounting identity this design is built to preserve, and which the
/// case suite asserts as an invariant:
///
///   p1_liquidity_penalty_conservation:
///     hook.penaltyDonated(P) == hook.expectedPenaltyDonated(P)
///
///   For every position P touched, the cumulative amount actually donated
///   at removals must equal the cumulative penalty owed by P's fee-accrual
///   lifetime under the hook's declared decay schedule.
///
/// v4-core fee-state model this hook rides on: any `modifyLiquidity` call
/// against an existing position auto-collects the position's accrued fees
/// as part of the call's `BalanceDelta`. The `feesAccrued` argument on the
/// `afterAddLiquidity` and `afterRemoveLiquidity` callbacks is v4-core's
/// authoritative report of what was collected on that call. The clean and
/// planted twins are byte-identical except for one hunk in
/// `afterAddLiquidity`: the clean twin captures that reported `feesAccrued`
/// into the position's `pendingPenaltyBase` (so an increase call inside the
/// penalty window still carries those fees into the base used at the next
/// remove); the planted twin omits the capture. The twin diff is shown in
/// the case README.
contract LiquidityPenaltyHook {
    /// Blocks after the most recent add-event during which a removal
    /// incurs a penalty. Linear decay to zero at `PENALTY_WINDOW` blocks.
    uint256 public constant PENALTY_WINDOW = 10;

    IPoolManager public immutable manager;

    /// The `currency0` of the pool this hook is registered against. The
    /// hook denominates all accounting in this currency and donates
    /// penalties in this currency; the token1-side accrual observed on
    /// the callback is folded into the same ledger at teaching scale.
    IERC20Minimal public immutable asset;

    /// Position key = keccak(owner, tickLower, tickUpper, salt), matching
    /// v4-core's `Position.calculatePositionKey`. A per-position mapping
    /// keeps the shape identical to production hooks; the case suite
    /// exercises a single full-range position at teaching scale.
    mapping(bytes32 => uint256) public pendingPenaltyBase;
    mapping(bytes32 => uint256) public lastAddBlock;
    mapping(bytes32 => uint256) public feesSinceEpochStart;
    mapping(bytes32 => uint256) public penaltyDonated;
    mapping(bytes32 => uint256) public expectedPenaltyDonated;

    event PenaltyDonated(bytes32 indexed posKey, uint256 amount, uint256 blocksSinceAdd);

    error NotManager();
    error DonationTransferFailed();

    constructor(IPoolManager manager_, IERC20Minimal asset_) {
        manager = manager_;
        asset = asset_;
        // Self-check: the deployment address must encode exactly this
        // hook's permission bitmap (afterAddLiquidity + afterRemoveLiquidity)
        // in its low 14 bits, or the real PoolManager would never dispatch
        // to it.
        Hooks.validateHookPermissions(
            IHooks(address(this)),
            Hooks.Permissions({
                beforeInitialize: false,
                afterInitialize: false,
                beforeAddLiquidity: false,
                afterAddLiquidity: true,
                beforeRemoveLiquidity: false,
                afterRemoveLiquidity: true,
                beforeSwap: false,
                afterSwap: false,
                beforeDonate: false,
                afterDonate: false,
                beforeSwapReturnDelta: false,
                afterSwapReturnDelta: false,
                afterAddLiquidityReturnDelta: false,
                afterRemoveLiquidityReturnDelta: false
            })
        );
    }

    /// Position key convention matches v4-core's own `Position` library so
    /// a case-side handler can address the same key without a shared type.
    function positionKey(address owner, int24 tickLower, int24 tickUpper, bytes32 salt)
        public
        pure
        returns (bytes32)
    {
        return Position.calculatePositionKey(owner, tickLower, tickUpper, salt);
    }

    function afterAddLiquidity(
        address sender,
        PoolKey calldata,
        IPoolManager.ModifyLiquidityParams calldata params,
        BalanceDelta,
        BalanceDelta feesAccrued,
        bytes calldata
    ) external returns (bytes4, BalanceDelta) {
        if (msg.sender != address(manager)) revert NotManager();
        bytes32 posKey = Position.calculatePositionKey(sender, params.tickLower, params.tickUpper, params.salt);
        uint256 fees = _sumFees(feesAccrued);

        // Both twins: observe the fees v4-core just auto-collected so the
        // reference expected-penalty ledger tracks the position's true
        // fee-accrual lifetime. This mirror is not the fee-state guard;
        // it is the shared source of truth against which the actual
        // penalty is checked.
        feesSinceEpochStart[posKey] += fees;

        // PLANTED (single-hunk twin diff, the seeded specification
        // violation): the CLEAN GUARD line
        //     pendingPenaltyBase[posKey] += fees;
        // is omitted here. On an add-on-existing-position the fees v4-core
        // just auto-collected are the position's earnings from the current
        // penalty window; without capture they are lost from
        // `pendingPenaltyBase`, so at the next remove the penalty computed
        // over the base misses the epoch between the last add and this
        // increase. Property `p1_liquidity_penalty_conservation` diverges
        // under an add -> swap -> increase -> remove sequence: the actual
        // penalty donated goes to zero while the reference expected stays
        // at the decayed epoch total.

        lastAddBlock[posKey] = block.number;
        return (IHooks.afterAddLiquidity.selector, BalanceDelta.wrap(0));
    }

    function afterRemoveLiquidity(
        address sender,
        PoolKey calldata key,
        IPoolManager.ModifyLiquidityParams calldata params,
        BalanceDelta,
        BalanceDelta feesAccrued,
        bytes calldata
    ) external returns (bytes4, BalanceDelta) {
        if (msg.sender != address(manager)) revert NotManager();
        bytes32 posKey = Position.calculatePositionKey(sender, params.tickLower, params.tickUpper, params.salt);
        uint256 fees = _sumFees(feesAccrued);

        // Shared observation: this remove's auto-collected fees complete
        // the position's epoch, so the reference epoch-total is the sum
        // of afterAdd-observed fees and this-call's feesAccrued.
        feesSinceEpochStart[posKey] += fees;

        uint256 dt = block.number - lastAddBlock[posKey];

        // Actual penalty: the base the CLEAN GUARD maintained, plus this
        // call's just-collected fees, decayed linearly to zero at
        // PENALTY_WINDOW blocks after the last add-event.
        uint256 actualBase = pendingPenaltyBase[posKey] + fees;
        uint256 penalty = _decay(actualBase, dt);

        // Reference expected penalty: the same decay schedule applied to
        // the shared epoch total, which both twins maintain identically.
        // The two agree when the CLEAN GUARD has captured every add-event
        // feesAccrued into pendingPenaltyBase; they diverge on the planted
        // twin at the first add -> swap -> increase -> remove sequence.
        uint256 expected = _decay(feesSinceEpochStart[posKey], dt);

        // Reset the epoch accounting: the position's next fee-accrual
        // window starts fresh from this block. lastAddBlock advances so a
        // subsequent add-event measures dt against this remove-event.
        pendingPenaltyBase[posKey] = 0;
        feesSinceEpochStart[posKey] = 0;
        lastAddBlock[posKey] = block.number;

        penaltyDonated[posKey] += penalty;
        expectedPenaltyDonated[posKey] += expected;

        if (penalty > 0) {
            _donateAndSettle(key, penalty);
            emit PenaltyDonated(posKey, penalty, dt);
        }
        return (IHooks.afterRemoveLiquidity.selector, BalanceDelta.wrap(0));
    }

    /// Sum feesAccrued's currency0 and currency1 legs as unsigned raw
    /// units. v4-core reports feesAccrued with positive amounts on both
    /// sides when fees exist; a negative signed value here would indicate
    /// an unexpected shape and is clamped to zero rather than trusted.
    function _sumFees(BalanceDelta d) internal pure returns (uint256) {
        int128 f0 = d.amount0();
        int128 f1 = d.amount1();
        uint256 acc;
        // f0 and f1 are int128 > 0 when this branch runs, so the uint128
        // cast is a bit-preserving reinterpret and the uint256 widen is
        // lossless.
        // forge-lint: disable-next-line(unsafe-typecast)
        if (f0 > 0) acc += uint256(uint128(f0));
        // forge-lint: disable-next-line(unsafe-typecast)
        if (f1 > 0) acc += uint256(uint128(f1));
        return acc;
    }

    function _decay(uint256 base, uint256 dt) internal pure returns (uint256) {
        if (dt >= PENALTY_WINDOW || base == 0) return 0;
        return (base * (PENALTY_WINDOW - dt)) / PENALTY_WINDOW;
    }

    /// Donate to in-range LPs on the hooked pool, and close the delta the
    /// donate opens against this hook by transferring from the hook's own
    /// pre-funded balance. The manager is unlocked when this runs (we are
    /// inside the outer modifyLiquidity's unlock callback), so the settle
    /// dance follows the same protocol every non-return-delta hook uses.
    function _donateAndSettle(PoolKey calldata key, uint256 amount) internal {
        manager.donate(key, amount, 0, "");
        manager.sync(key.currency0);
        if (!asset.transfer(address(manager), amount)) revert DonationTransferFailed();
        manager.settle();
    }
}
