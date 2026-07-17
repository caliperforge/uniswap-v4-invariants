// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {IPermit2} from "@uniswap/permit2/src/interfaces/IPermit2.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {FixedPoint96} from "@uniswap/v4-core/src/libraries/FixedPoint96.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {BeforeSwapDelta, toBeforeSwapDelta} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {BaseHook} from "@uniswap/v4-hooks-public/src/base/BaseHook.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {Actions} from "@uniswap/v4-periphery/src/libraries/Actions.sol";
import {LiquidityAmounts} from "@uniswap/v4-periphery/src/libraries/LiquidityAmounts.sol";

import "./IMoonpotManager.sol";
import "./IMoonpotHook.sol";
import "./MoonpotToken.sol";
import {Oracle} from "./lib/Oracle.sol";

contract MoonpotHook is BaseHook, Ownable2Step, ReentrancyGuard, IUnlockCallback {
    using CurrencyLibrary for Currency;
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;
    using SafeERC20 for IERC20;
    using Oracle for Oracle.Observation[65535];

    uint8 private constant ACTION_INJECT_LIQUIDITY = 0;

    // Hard ceiling on the defense tax (90%); keeps an exit open even at max penalty.
    uint24 public constant MAX_DEFENSE_TAX = 900_000;

    IPositionManager public immutable posm;
    IPermit2 public immutable permit2;
    IERC20 public immutable usdc;
    IERC20 public immutable tmp;

    address public manager;
    bool private _initialized;

    PoolKey public poolKey;
    int24 public currentFloorTick;
    // Sentinel: distinguishes a real floor at tick 0 from the never-set default,
    // so the sell-defense path can never run on an uninitialized floor (F-2026-17240).
    bool public floorTickSet;

    uint256 public _positionId;
    int24 public floorTickLower;
    int24 public floorTickUpper;

    uint24 public baseDefenseTax = 3_000;
    uint24 public maxDefenseTax = 500_000;
    int24 public taxRampTicks = 4080;

    int24 public positionTickLower;
    int24 public positionTickUpper;

    uint128 public protocolLiquidity;

    // TWAP oracle (sandwich guard for liquidity injection, F-2026-17061)
    Oracle.Observation[65535] public observations;
    uint16 public observationIndex;
    uint16 public observationCardinality;
    uint16 public observationCardinalityNext;

    uint32 public twapWindow = 1800;
    uint24 public maxTwapDeviationTicks = 1000;
    int24 public maxFloorDeviationTicks = 2400;

    error InvalidAddress();
    error InvalidDefenseParams();
    error InvalidFloorTick();
    error InvalidInjectionGuardParams();
    error InvalidTokens();
    error ManagerNotSet();
    error ManagerAlreadySet();
    error OnlyManager();
    error PoolAlreadyInitialized();
    error ExactOutputTMPSellBlocked();
    error FloorTickNotSet();

    event CurrentFloorTickUpdated(int24 tick);
    event DefenseParamsUpdated(
        uint24 baseTax,
        uint24 maxTax,
        int24 taxRampTicks
    );
    event PositionConfigured(uint256 id, int24 tickLower, int24 tickUpper, uint128 liquidity);
    event ManagerSet(address manager);
    event FeesHarvested(uint256 usdcAmount, uint256 tmpAmount);
    event TMPIntercepted(uint256 tmpBurned, uint256 maxAllowed);
    event InjectionGuardParamsUpdated(
        uint32 twapWindow,
        uint24 maxTwapDeviationTicks,
        int24 maxFloorDeviationTicks
    );
    event ObservationCardinalityIncreased(uint16 cardinalityNext);

    modifier onlyManager() {
        if (manager == address(0)) revert ManagerNotSet();
        if (msg.sender != manager) revert OnlyManager();
        _;
    }

    constructor(
        IPoolManager _poolManager,
        address _posm,
        address _permit2,
        address _usdc,
        address _tmp,
        address _owner
    ) BaseHook(_poolManager) Ownable(_owner) {
        if (
            _posm == address(0) ||
            _permit2 == address(0) ||
            _usdc == address(0) ||
            _tmp == address(0)
        ) revert InvalidAddress();

        posm = IPositionManager(_posm);
        permit2 = IPermit2(_permit2);
        usdc = IERC20(_usdc);
        tmp = IERC20(_tmp);

        usdc.approve(_permit2, type(uint256).max);
        tmp.approve(_permit2, type(uint256).max);
        IPermit2(_permit2).approve(
            address(usdc),
            address(posm),
            type(uint160).max,
            type(uint48).max
        );
        IPermit2(_permit2).approve(
            address(tmp),
            address(posm),
            type(uint160).max,
            type(uint48).max
        );
    }

    function getHookPermissions()
        public
        pure
        override
        returns (Hooks.Permissions memory)
    {
        return
            Hooks.Permissions({
                beforeInitialize: true,
                afterInitialize: false,
                beforeAddLiquidity: false,
                afterAddLiquidity: false,
                beforeRemoveLiquidity: false,
                afterRemoveLiquidity: false,
                beforeSwap: true,
                afterSwap: false,
                beforeDonate: false,
                afterDonate: false,
                beforeSwapReturnDelta: true,
                afterSwapReturnDelta: false,
                afterAddLiquidityReturnDelta: false,
                afterRemoveLiquidityReturnDelta: false
            });
    }

    function _beforeInitialize(
        address,
        PoolKey calldata key,
        uint160
    ) internal override returns (bytes4) {
        if (
            Currency.unwrap(key.currency0) != address(usdc) &&
            Currency.unwrap(key.currency1) != address(usdc)
        ) revert InvalidTokens();

        if (_initialized) revert PoolAlreadyInitialized();

        poolKey = key;
        _initialized = true;

        (observationCardinality, observationCardinalityNext) = observations
            .initialize(uint32(block.timestamp));

        return BaseHook.beforeInitialize.selector;
    }

    function _beforeSwap(
        address,
        PoolKey calldata key,
        SwapParams calldata params,
        bytes calldata
    ) internal override returns (bytes4, BeforeSwapDelta, uint24) {
        if (PoolId.unwrap(key.toId()) != PoolId.unwrap(poolKey.toId()))
            return (BaseHook.beforeSwap.selector, toBeforeSwapDelta(0, 0), 0);

        // Record the pre-swap price into the TWAP oracle for every swap.
        (uint160 sqrtPriceX96, int24 currentTick, , ) = poolManager.getSlot0(
            key.toId()
        );
        (observationIndex, observationCardinality) = observations.write(
            observationIndex,
            uint32(block.timestamp),
            currentTick,
            1,
            observationCardinality,
            observationCardinalityNext
        );

        bool usdcIsCurrency0 = Currency.unwrap(key.currency0) == address(usdc);
        bool isSellingTMP = usdcIsCurrency0
            ? !params.zeroForOne
            : params.zeroForOne;

        if (!isSellingTMP)
            return (
                BaseHook.beforeSwap.selector,
                toBeforeSwapDelta(0, 0),
                baseDefenseTax | LPFeeLibrary.DYNAMIC_FEE_FLAG
            );
        if (params.amountSpecified > 0) revert ExactOutputTMPSellBlocked();

        uint24 tax = _defenseTax(usdcIsCurrency0, currentTick);

        uint24 feeWithFlag = tax > 0
            ? (tax | LPFeeLibrary.DYNAMIC_FEE_FLAG)
            : 0;

        uint256 swapAmount = uint256(-params.amountSpecified);
        uint256 maxTmpSell = _computeMaxTmpSell(usdcIsCurrency0, sqrtPriceX96);

        if (swapAmount <= maxTmpSell)
            return (
                BaseHook.beforeSwap.selector,
                toBeforeSwapDelta(0, 0),
                feeWithFlag
            );

        uint256 excessTmp = swapAmount - maxTmpSell;
        Currency tmpCurrency = usdcIsCurrency0 ? key.currency1 : key.currency0;

        poolManager.take(tmpCurrency, address(this), excessTmp);
        MoonpotToken(address(tmp)).burn(excessTmp);

        emit TMPIntercepted(excessTmp, maxTmpSell);

        return (
            BaseHook.beforeSwap.selector,
            toBeforeSwapDelta(int128(int256(excessTmp)), 0),
            feeWithFlag
        );
    }

    function unlockCallback(
        bytes calldata data
    ) external onlyPoolManager returns (bytes memory) {
        uint8 action = abi.decode(data[:32], (uint8));

        if (action == ACTION_INJECT_LIQUIDITY) {
            (, uint256 usdcAmount) = abi.decode(data, (uint8, uint256));

            uint256 usdcBefore = usdc.balanceOf(address(this));

            bool usdcIsZero = Currency.unwrap(poolKey.currency0) ==
                address(usdc);

            int24 tickLower = positionTickLower;
            int24 tickUpper = positionTickUpper;

            (uint160 sqrtPriceX96, , , ) = poolManager.getSlot0(poolKey.toId());

            uint256 MAX_V4_AMOUNT = uint256(uint128(type(int128).max));

            uint128 liquidityToAdd = LiquidityAmounts.getLiquidityForAmounts(
                sqrtPriceX96,
                TickMath.getSqrtPriceAtTick(tickLower),
                TickMath.getSqrtPriceAtTick(tickUpper),
                usdcIsZero ? usdcAmount : MAX_V4_AMOUNT,
                usdcIsZero ? MAX_V4_AMOUNT : usdcAmount
            );

            if (liquidityToAdd > 0) {
                bytes memory actions = abi.encodePacked(
                    uint8(Actions.INCREASE_LIQUIDITY),
                    uint8(Actions.SETTLE_PAIR)
                );
                bytes[] memory p = new bytes[](2);
                p[0] = abi.encode(
                    _positionId,
                    liquidityToAdd,
                    MAX_V4_AMOUNT,
                    MAX_V4_AMOUNT,
                    bytes("")
                );
                p[1] = abi.encode(poolKey.currency0, poolKey.currency1);

                posm.modifyLiquiditiesWithoutUnlock(actions, p);

                protocolLiquidity += liquidityToAdd;
            }

            uint256 leftover = tmp.balanceOf(address(this));
            if (leftover > 0) MoonpotToken(address(tmp)).burn(leftover);

            // Report the USDC actually pulled into the LP so the manager keeps
            // any unused remainder tracked as pending (F-2026-17073).
            return abi.encode(usdcBefore - usdc.balanceOf(address(this)));
        }

        return bytes("");
    }

    function injectLiquidity(
        uint256 usdcAmount
    ) external onlyManager nonReentrant returns (uint256 consumed) {
        if (usdcAmount == 0) return 0;
        bytes memory result = poolManager.unlock(
            abi.encode(ACTION_INJECT_LIQUIDITY, usdcAmount)
        );
        consumed = abi.decode(result, (uint256));
    }

    function quoteSell(
        uint256 tmpAmount
    )
        external
        view
        returns (uint256 effectiveSell, uint256 tmpBurned, uint24 tax)
    {
        (uint160 sqrtPriceX96, int24 currentTick, , ) = poolManager.getSlot0(
            poolKey.toId()
        );
        bool usdcIsCurrency0 = Currency.unwrap(poolKey.currency0) ==
            address(usdc);

        uint256 maxSell = _computeMaxTmpSell(usdcIsCurrency0, sqrtPriceX96);

        if (tmpAmount <= maxSell) {
            effectiveSell = tmpAmount;
            tmpBurned = 0;
        } else {
            effectiveSell = maxSell;
            tmpBurned = tmpAmount - maxSell;
        }

        tax = _defenseTax(usdcIsCurrency0, currentTick);
    }

    function quoteBuy(
        uint256 usdcAmount
    ) external view returns (uint256 tmpOut, uint24 tax) {
        (uint160 sqrtPriceX96, , , ) = poolManager.getSlot0(poolKey.toId());
        uint128 liquidity = poolManager.getLiquidity(poolKey.toId());
        bool usdcIsCurrency0 = Currency.unwrap(poolKey.currency0) ==
            address(usdc);

        tax = baseDefenseTax;

        if (liquidity == 0 || sqrtPriceX96 == 0) return (0, tax);

        uint256 amountInAfterFee = FullMath.mulDiv(
            usdcAmount,
            uint256(1_000_000 - tax),
            1_000_000
        );

        tmpOut = _quoteBuyTmpOut(
            usdcIsCurrency0,
            sqrtPriceX96,
            liquidity,
            amountInAfterFee
        );
    }

    function _quoteBuyTmpOut(
        bool usdcIsCurrency0,
        uint160 sqrtPriceX96,
        uint128 liquidity,
        uint256 amountInAfterFee
    ) internal pure returns (uint256 tmpOut) {
        if (usdcIsCurrency0) {
            // Canonical token0 exact-input (matches v4-core SqrtPriceMath):
            // denominator is (liquidity << 96) + amountIn * sqrtP, with no extra
            // /Q96 (which would make the term negligible and truncate output to 0).
            uint256 liquidityQ96 = uint256(liquidity) << 96;
            uint256 denominator = liquidityQ96 +
                amountInAfterFee *
                sqrtPriceX96;

            if (denominator == 0) return 0;

            uint160 sqrtPriceNew = uint160(
                FullMath.mulDiv(liquidityQ96, sqrtPriceX96, denominator)
            );

            if (sqrtPriceNew >= sqrtPriceX96) return 0;

            tmpOut = FullMath.mulDiv(
                liquidity,
                sqrtPriceX96 - sqrtPriceNew,
                FixedPoint96.Q96
            );
        } else {
            uint256 sqrtPriceDelta = FullMath.mulDiv(
                amountInAfterFee,
                FixedPoint96.Q96,
                liquidity
            );
            uint160 sqrtPriceNew = uint160(
                uint256(sqrtPriceX96) + sqrtPriceDelta
            );

            tmpOut = FullMath.mulDiv(
                FullMath.mulDiv(liquidity, sqrtPriceDelta, sqrtPriceNew),
                FixedPoint96.Q96,
                sqrtPriceX96
            );
        }
    }

    function harvestFees() external nonReentrant onlyOwner {
        bytes memory actions = abi.encodePacked(
            uint8(Actions.DECREASE_LIQUIDITY),
            uint8(Actions.TAKE_PAIR)
        );
        bytes[] memory params = new bytes[](2);
        params[0] = abi.encode(
            _positionId,
            uint128(0),
            uint128(0),
            uint128(0),
            ""
        );
        params[1] = abi.encode(
            poolKey.currency0,
            poolKey.currency1,
            address(this)
        );

        posm.modifyLiquidities(
            abi.encode(actions, params),
            block.timestamp + 15 minutes
        );

        uint256 pending = IMoonpotManager(manager).pendingLiquidityUsdc();
        uint256 usdcBalance = usdc.balanceOf(address(this));
        uint256 usdcFees = usdcBalance > pending ? usdcBalance - pending : 0;

        if (usdcFees > 0) {
            usdc.safeTransfer(IMoonpotManager(manager).company(), usdcFees);
        }

        uint256 tmpFees = tmp.balanceOf(address(this));

        if (tmpFees > 0) {
            MoonpotToken(address(tmp)).burn(tmpFees);
        }

        if (usdcFees > 0 || tmpFees > 0) {
            emit FeesHarvested(usdcFees, tmpFees);
        }
    }

    function _defenseTax(
        bool usdcIsCurrency0,
        int24 currentTick
    ) internal view returns (uint24) {
        // Never tax against the zero-default floor: the manager must have set a
        // real floor band first (F-2026-17240). Guards the whole sell path since
        // _beforeSwap calls this before _computeMaxTmpSell.
        if (!floorTickSet) revert FloorTickNotSet();
        int24 ticksAboveFloor = currentTick - currentFloorTick;
        // When usdc is currency0 a higher tick means a lower TMP price, so the
        // distance-above-floor is inverted relative to TMP price (F-2026-17059).
        if (usdcIsCurrency0) ticksAboveFloor = -ticksAboveFloor;
        return _calculateTax(ticksAboveFloor);
    }

    function _calculateTax(
        int24 ticksAboveFloor
    ) internal view returns (uint24 tax) {
        if (ticksAboveFloor <= 0) return maxDefenseTax;
        if (ticksAboveFloor >= taxRampTicks) return baseDefenseTax;

        uint256 reduction = (uint256(uint24(maxDefenseTax - baseDefenseTax)) *
            uint256(uint24(ticksAboveFloor))) / uint256(uint24(taxRampTicks));

        tax = uint24(maxDefenseTax - uint24(reduction));
    }

    function _computeMaxTmpSell(
        bool usdcIsCurrency0,
        uint160 sqrtPriceX96
    ) internal view returns (uint256 maxTmpSell) {
        uint128 liquidity = protocolLiquidity;
        if (liquidity == 0) return 0;

        if (usdcIsCurrency0) {
            uint160 sqrtFloorUpper = TickMath.getSqrtPriceAtTick(
                floorTickUpper
            );

            if (sqrtPriceX96 >= sqrtFloorUpper) return 0;

            maxTmpSell = FullMath.mulDiv(
                liquidity,
                sqrtFloorUpper - sqrtPriceX96,
                FixedPoint96.Q96
            );
        } else {
            uint160 sqrtFloorLower = TickMath.getSqrtPriceAtTick(
                floorTickLower
            );

            if (sqrtPriceX96 <= sqrtFloorLower) return 0;

            maxTmpSell = FullMath.mulDiv(
                FullMath.mulDiv(liquidity, FixedPoint96.Q96, sqrtFloorLower),
                sqrtPriceX96 - sqrtFloorLower,
                sqrtPriceX96
            );
        }
    }

    function setPosition(
        uint256 id,
        int24 tickLower,
        int24 tickUpper,
        uint128 liquidity
    ) external onlyManager {
        if (id == 0) return;

        _positionId = id;
        positionTickLower = tickLower;
        positionTickUpper = tickUpper;
        protocolLiquidity = liquidity;

        emit PositionConfigured(id, tickLower, tickUpper, liquidity);
    }

    function setCurrentFloorTick(int24 tick) external onlyManager {
        // Keep the floor band within TickMath range so the sell path
        // (getSqrtPriceAtTick in _computeMaxTmpSell) can never revert (F-2026-17240).
        int24 spacing = poolKey.tickSpacing;
        if (
            tick - spacing < TickMath.MIN_TICK ||
            tick + spacing > TickMath.MAX_TICK
        ) revert InvalidFloorTick();

        currentFloorTick = tick;
        floorTickLower = tick - spacing;
        floorTickUpper = tick + spacing;
        floorTickSet = true;

        emit CurrentFloorTickUpdated(tick);
    }

    function setManager(address _manager) external onlyOwner {
        if (_manager == address(0)) revert InvalidAddress();
        if (manager != address(0)) revert ManagerAlreadySet();

        manager = _manager;

        emit ManagerSet(_manager);
    }

    function setDefenseParams(
        uint24 _base,
        uint24 _max,
        int24 _taxRampTicks
    ) external onlyOwner {
        if (_base > _max) revert InvalidDefenseParams();
        if (_taxRampTicks <= 0) revert InvalidDefenseParams();
        if (_max > MAX_DEFENSE_TAX) revert InvalidDefenseParams();

        baseDefenseTax = _base;
        maxDefenseTax = _max;
        taxRampTicks = _taxRampTicks;

        emit DefenseParamsUpdated(_base, _max, _taxRampTicks);
    }

    /// @notice Whether liquidity injection is allowed at the current price.
    /// @dev TWAP deviation guard once the oracle is warm; floor-band fallback until then.
    function injectionAllowed() external view returns (bool) {
        (, int24 currentTick, , ) = poolManager.getSlot0(poolKey.toId());
        return _injectionAllowedAt(currentTick);
    }

    function _injectionAllowedAt(
        int24 currentTick
    ) internal view returns (bool) {
        if (_twapReady()) {
            int24 twap = _consultTwapTick(currentTick);
            int24 diff = currentTick > twap
                ? currentTick - twap
                : twap - currentTick;
            return uint24(diff) <= maxTwapDeviationTicks;
        }

        // Warm-up: require price within a band above the floor (ordering-aware).
        bool usdcIsCurrency0 = Currency.unwrap(poolKey.currency0) ==
            address(usdc);
        int24 above = usdcIsCurrency0
            ? currentFloorTick - currentTick
            : currentTick - currentFloorTick;
        return above >= 0 && above <= maxFloorDeviationTicks;
    }

    function _twapReady() internal view returns (bool) {
        uint16 card = observationCardinality;
        if (card < 2) return false;
        Oracle.Observation memory oldest = observations[
            (observationIndex + 1) % card
        ];
        if (!oldest.initialized) oldest = observations[0];
        if (!oldest.initialized) return false;
        return uint32(block.timestamp) - oldest.blockTimestamp >= twapWindow;
    }

    function _consultTwapTick(
        int24 currentTick
    ) internal view returns (int24) {
        uint32[] memory secondsAgos = new uint32[](2);
        secondsAgos[0] = twapWindow;
        secondsAgos[1] = 0;
        (int56[] memory cums, ) = observations.observe(
            uint32(block.timestamp),
            secondsAgos,
            currentTick,
            observationIndex,
            1,
            observationCardinality
        );
        int56 delta = cums[1] - cums[0];
        int56 window = int56(uint56(twapWindow));
        int24 twap = int24(delta / window);
        if (delta < 0 && delta % window != 0) twap--;
        return twap;
    }

    function growOracle(uint16 next) external onlyOwner {
        observationCardinalityNext = observations.grow(
            observationCardinalityNext,
            next
        );
        emit ObservationCardinalityIncreased(observationCardinalityNext);
    }

    function setInjectionGuardParams(
        uint32 _twapWindow,
        uint24 _maxTwapDeviationTicks,
        int24 _maxFloorDeviationTicks
    ) external onlyOwner {
        if (_twapWindow < 60) revert InvalidInjectionGuardParams();
        if (_maxTwapDeviationTicks == 0) revert InvalidInjectionGuardParams();
        if (_maxFloorDeviationTicks <= 0) revert InvalidInjectionGuardParams();

        twapWindow = _twapWindow;
        maxTwapDeviationTicks = _maxTwapDeviationTicks;
        maxFloorDeviationTicks = _maxFloorDeviationTicks;

        emit InjectionGuardParamsUpdated(
            _twapWindow,
            _maxTwapDeviationTicks,
            _maxFloorDeviationTicks
        );
    }

    function positionId() external view returns (uint256) {
        return _positionId;
    }
}
