// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.26;

import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {IERC20Minimal} from "v4-core/src/interfaces/external/IERC20Minimal.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {FullMath} from "v4-core/src/libraries/FullMath.sol";
import {FixedPoint96} from "v4-core/src/libraries/FixedPoint96.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";

/// @title LiquidityVaultHook (case C-B1: custom-accounting rounding integrity)
/// @notice A teaching-scale vault-style custom-accounting hook. Depositors
/// hand the vault its asset (the pool's currency0); the vault mints shares
/// against a conservative net asset value and books every asset it holds
/// into a two-tranche balance split:
///
///   idleBalance   assets held as withdrawable cash
///   activeBalance assets the strategy books as deployed against the pool
///                 it hooks (teaching-scale: the tranche is modeled as a
///                 50/50 token0/token1 position entered at the 1:1 pool
///                 price; a production vault would hold a real position)
///
/// The vault's liquidity estimate for the active tranche is the MIN of two
/// estimates: the balance-derived book value and a spot-derived value read
/// from the real pool's sqrtPriceX96. Taking the minimum keeps share
/// pricing conservative when the two disagree.
///
/// The accounting identities this design is built to preserve, and which
/// the case suite asserts as invariants:
///
///   1. b1_balance_split_integrity:
///        idleBalance + activeBalance == trackedTotal, to the wei, after
///        any deposit/withdraw/swap sequence.
///   2. b1_accounting_conservation:
///        totalAssets() + accruedFees <= asset.balanceOf(vault), i.e. the
///        value redeemable across all outstanding shares, net of declared
///        fees, never exceeds what the vault actually holds.
///
/// The rounding-direction discipline that keeps identity 1 exact lives in
/// the withdraw path's pro-rata sourcing hunk; the clean and planted twins
/// are byte-identical except that hunk (diff shown in the case README).
contract LiquidityVaultHook {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    /// Declared withdrawal fee in basis points of the gross redemption
    /// (10 = 0.10%). Fees accrue to the admin's ledger and stay in the
    /// vault's token balance; they are excluded from share pricing.
    uint256 public constant WITHDRAW_FEE_BPS = 10;

    IPoolManager public immutable manager;
    address public immutable admin;
    IERC20Minimal public immutable asset;

    PoolKey public poolKey;
    PoolId public poolId;
    bool public poolSet;

    uint256 public totalShares;
    mapping(address => uint256) public sharesOf;

    /// The balance split. trackedTotal is updated exactly (by the raw
    /// deposit amount and by the gross redemption); the split legs are
    /// updated per path. Keeping idle + active == trackedTotal is the
    /// withdraw path's rounding obligation.
    uint256 public idleBalance;
    uint256 public activeBalance;
    uint256 public trackedTotal;

    /// Declared-fee ledger (see WITHDRAW_FEE_BPS).
    uint256 public accruedFees;

    /// Swaps observed through this hook's afterSwap callback; the unit
    /// leg uses it to prove the hook is wired to the real pool.
    uint256 public swapCount;

    event Deposited(address indexed from, uint256 assets, uint256 shares);
    event Withdrawn(address indexed to, uint256 shares, uint256 gross, uint256 fee, uint256 payout);

    error NotAdmin();
    error NotManager();
    error ZeroAdmin();
    error PoolNotSet();
    error PoolAlreadySet();
    error WrongPool();
    error ZeroNav();
    error ZeroShares();
    error BadShares();
    error TransferFailed();

    constructor(IPoolManager manager_, address admin_, IERC20Minimal asset_) {
        if (admin_ == address(0)) revert ZeroAdmin();
        manager = manager_;
        admin = admin_;
        asset = asset_;
        // Self-check: the deployment address must encode exactly this
        // hook's permission bitmap (afterSwap only) in its low 14 bits,
        // or the real PoolManager would never dispatch to it.
        Hooks.validateHookPermissions(
            IHooks(address(this)),
            Hooks.Permissions({
                beforeInitialize: false,
                afterInitialize: false,
                beforeAddLiquidity: false,
                afterAddLiquidity: false,
                beforeRemoveLiquidity: false,
                afterRemoveLiquidity: false,
                beforeSwap: false,
                afterSwap: true,
                beforeDonate: false,
                afterDonate: false,
                beforeSwapReturnDelta: false,
                afterSwapReturnDelta: false,
                afterAddLiquidityReturnDelta: false,
                afterRemoveLiquidityReturnDelta: false
            })
        );
    }

    /// One-time admin wiring: the pool this vault prices its active
    /// tranche against. The pool must carry this hook and must have the
    /// vault's asset as currency0 (the denomination of all accounting).
    function setPool(PoolKey calldata key) external {
        if (msg.sender != admin) revert NotAdmin();
        if (poolSet) revert PoolAlreadySet();
        if (address(key.hooks) != address(this) || Currency.unwrap(key.currency0) != address(asset)) {
            revert WrongPool();
        }
        poolKey = key;
        poolId = key.toId();
        poolSet = true;
    }

    /// Conservative value of the active tranche: MIN of the
    /// balance-derived book value and the spot-derived value of the
    /// modeled 50/50 position at the pool's current sqrtPriceX96
    /// (token1 leg converted to token0 terms). Rounding inside the
    /// spot conversion only ever lowers the estimate, which is the
    /// safe direction for share pricing.
    function activeValue() public view returns (uint256) {
        if (activeBalance == 0) return 0;
        (uint160 sqrtPriceX96,,,) = manager.getSlot0(poolId);
        uint256 held0 = activeBalance / 2;
        uint256 held1 = activeBalance - held0;
        // token1 -> token0 at spot: held1 / price, price = (sqrtP/Q96)^2.
        uint256 t = FullMath.mulDiv(held1, FixedPoint96.Q96, sqrtPriceX96);
        uint256 spotDerived = held0 + FullMath.mulDiv(t, FixedPoint96.Q96, sqrtPriceX96);
        return spotDerived < activeBalance ? spotDerived : activeBalance;
    }

    /// Net asset value backing the outstanding shares: withdrawable cash
    /// plus the conservative active-tranche estimate. Excludes accrued
    /// fees by construction (fees are never booked into the split).
    function totalAssets() public view returns (uint256) {
        return idleBalance + activeValue();
    }

    function deposit(uint256 assets) external returns (uint256 shares) {
        if (!poolSet) revert PoolNotSet();
        uint256 nav = totalAssets();
        if (totalShares == 0) {
            shares = assets;
        } else {
            if (nav == 0) revert ZeroNav();
            // Shares round DOWN: the wei remainder favors the vault.
            shares = FullMath.mulDiv(assets, totalShares, nav);
        }
        if (shares == 0) revert ZeroShares();
        if (!asset.transferFrom(msg.sender, address(this), assets)) revert TransferFailed();

        totalShares += shares;
        sharesOf[msg.sender] += shares;

        // Book the raw amount exactly, then split it: half of each
        // deposit is deployed to the active tranche. Both legs move by
        // amounts that sum to exactly `assets`, so the split identity
        // is preserved without any rounding obligation here.
        trackedTotal += assets;
        uint256 toActive = assets / 2;
        activeBalance += toActive;
        idleBalance += assets - toActive;

        emit Deposited(msg.sender, assets, shares);
    }

    function withdraw(uint256 shares) external returns (uint256 payout) {
        if (!poolSet) revert PoolNotSet();
        if (shares == 0 || shares > sharesOf[msg.sender]) revert BadShares();

        // Gross redemption rounds DOWN (favors the vault); the declared
        // fee is carved out of it and booked to the fee ledger.
        uint256 gross = FullMath.mulDiv(shares, totalAssets(), totalShares);
        uint256 fee = (gross * WITHDRAW_FEE_BPS) / 10_000;
        payout = gross - fee;

        // PLANTED (single-hunk twin diff, the seeded specification
        // violation): the idle share of the withdrawal is computed with
        // its own floor division instead of taking the exact remainder
        // of the split, flipping the idle term's rounding direction
        // from round-up-to-the-remainder to round-down. Each individual
        // withdrawal still pays the correct amount, and both floors
        // agree with the exact split whenever the divisions are exact;
        // whenever both carry a remainder the two decrements sum to
        // gross - 1, so the split releases one wei less than
        // trackedTotal. Bounded per operation, systematic across many:
        // the books overstate the split by the accumulated drift,
        // violating the balance-split identity.
        uint256 fromActive = FullMath.mulDiv(gross, activeBalance, trackedTotal);
        uint256 fromIdle = FullMath.mulDiv(gross, idleBalance, trackedTotal);

        sharesOf[msg.sender] -= shares;
        totalShares -= shares;
        activeBalance -= fromActive;
        idleBalance -= fromIdle;
        trackedTotal -= gross;
        accruedFees += fee;

        if (!asset.transfer(msg.sender, payout)) revert TransferFailed();
        emit Withdrawn(msg.sender, shares, gross, fee, payout);
    }

    function afterSwap(address, PoolKey calldata, SwapParams calldata, BalanceDelta, bytes calldata)
        external
        returns (bytes4, int128)
    {
        if (msg.sender != address(manager)) revert NotManager();
        swapCount++;
        // The manager reverts on a wrong selector return; the int128 is
        // the hook's unspecified-currency delta, unused by this hook.
        return (IHooks.afterSwap.selector, 0);
    }
}
