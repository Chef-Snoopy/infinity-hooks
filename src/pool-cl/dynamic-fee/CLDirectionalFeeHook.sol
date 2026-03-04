// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import {CLBaseHook} from "../CLBaseHook.sol";
import {ICLPoolManager} from "infinity-core/src/pool-cl/interfaces/ICLPoolManager.sol";
import {LPFeeLibrary} from "infinity-core/src/libraries/LPFeeLibrary.sol";
import {PoolKey} from "infinity-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "infinity-core/src/types/PoolId.sol";
import {BalanceDelta} from "infinity-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "infinity-core/src/types/BeforeSwapDelta.sol";

/// @title CLDirectionalFeeHook
/// @notice A directional-fee CL hook that:
///         1. Sets an initial LP fee (1.0%) on pool initialization via afterInitialize.
///         2. Adjusts the LP fee before every swap based on the swap direction (zeroForOne).
///
/// @dev Fee rule (applied in beforeSwap):
///      zeroForOne = true  → ZERO_FOR_ONE_FEE = 10000 (1.0%)
///      zeroForOne = false → ONE_FOR_ZERO_FEE = 15000 (1.5%)
///
/// @dev Pool key must be initialized with fee = LPFeeLibrary.DYNAMIC_FEE_FLAG (0x800000).
contract CLDirectionalFeeHook is CLBaseHook {
    using PoolIdLibrary for PoolKey;

    // ─── Fee constants (in hundredths of a bip) ─────────────────────────────────
    uint24 public constant INITIAL_FEE      = 10000; // 1.0%
    uint24 public constant ZERO_FOR_ONE_FEE = 10000; // 1.0%
    uint24 public constant ONE_FOR_ZERO_FEE = 15000; // 1.5%

    // ─── State ──────────────────────────────────────────────────────────────────
    /// @notice Tracks the current LP fee for each pool managed by this hook
    mapping(PoolId => uint24) public currentLPFee;

    // ─── Events ─────────────────────────────────────────────────────────────────
    event LPFeeUpdated(PoolId indexed poolId, uint24 newFee);

    // ────────────────────────────────────────────────────────────────────────────

    constructor(ICLPoolManager _poolManager) CLBaseHook(_poolManager) {}

    // ─── Hook registration ───────────────────────────────────────────────────────

    function getHooksRegistrationBitmap() external pure override returns (uint16) {
        return _hooksRegistrationBitmapFrom(
            Permissions({
                beforeInitialize: false,
                afterInitialize: true,
                beforeAddLiquidity: false,
                afterAddLiquidity: false,
                beforeRemoveLiquidity: false,
                afterRemoveLiquidity: false,
                beforeSwap: true,
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

    // ─── Hook callbacks ──────────────────────────────────────────────────────────

    /// @dev Called once after the pool is initialized. Sets the initial LP fee.
    function _afterInitialize(address, PoolKey calldata key, uint160, int24)
        internal
        override
        returns (bytes4)
    {
        PoolId poolId = key.toId();
        currentLPFee[poolId] = INITIAL_FEE;
        poolManager.updateDynamicLPFee(key, INITIAL_FEE);
        emit LPFeeUpdated(poolId, INITIAL_FEE);
        return this.afterInitialize.selector;
    }

    /// @dev Called before every swap. Sets the LP fee based on swap direction.
    ///      zeroForOne = true  → 1.0%
    ///      zeroForOne = false → 1.5%
    function _beforeSwap(
        address,
        PoolKey calldata key,
        ICLPoolManager.SwapParams calldata params,
        bytes calldata
    ) internal override returns (bytes4, BeforeSwapDelta, uint24) {
        // Determine fee based on swap direction
        uint24 newFee = params.zeroForOne ? ZERO_FOR_ONE_FEE : ONE_FOR_ZERO_FEE;

        // Only update storage + pool manager when the fee actually changes
        PoolId poolId = key.toId();
        if (newFee != currentLPFee[poolId]) {
            currentLPFee[poolId] = newFee;
            poolManager.updateDynamicLPFee(key, newFee);
            emit LPFeeUpdated(poolId, newFee);
        }

        return (this.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
    }
}
