// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import {Ownable} from "openzeppelin-contracts/contracts/access/Ownable.sol";
import {CLBaseHook} from "../CLBaseHook.sol";
import {ICLPoolManager} from "infinity-core/src/pool-cl/interfaces/ICLPoolManager.sol";
import {LPFeeLibrary} from "infinity-core/src/libraries/LPFeeLibrary.sol";
import {PoolKey} from "infinity-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "infinity-core/src/types/PoolId.sol";
import {BalanceDelta} from "infinity-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "infinity-core/src/types/BeforeSwapDelta.sol";
import {CLDynamicFeeHookProtocolFeeController} from "./CLDynamicFeeHookProtocolFeeController.sol";

/// @title CLDynamicFeeHook
/// @notice A dynamic-fee CL hook that:
///         1. Sets a base LP fee (0.3%) on pool initialization via afterInitialize.
///         2. Adjusts the LP fee after every swap based on the swap size (tiered rule).
///         3. Holds authorization to modify the protocol fee for its pools via a
///            custom CLDynamicFeeHookProtocolFeeController.
///
/// @dev Fee tier rule (applied in afterSwap):
///      |amountSpecified| >= 10e18  → HIGH_LP_FEE = 10000 (1.0%)
///      |amountSpecified| >=  1e18  →  MID_LP_FEE =  5000 (0.5%)
///      otherwise                   → BASE_LP_FEE =  3000 (0.3%)
///
/// @dev Pool key must be initialized with fee = LPFeeLibrary.DYNAMIC_FEE_FLAG (0x800000).
contract CLDynamicFeeHook is CLBaseHook, Ownable {
    using PoolIdLibrary for PoolKey;

    // ─── Fee tiers (in hundredths of a bip) ────────────────────────────────────
    uint24 public constant BASE_LP_FEE = 3000; // 0.30%
    uint24 public constant MID_LP_FEE = 5000; // 0.50%
    uint24 public constant HIGH_LP_FEE = 10000; // 1.00%

    // ─── Swap-size thresholds ───────────────────────────────────────────────────
    uint256 public constant MID_SWAP_THRESHOLD = 1e18; // 1 token (18 decimals)
    uint256 public constant HIGH_SWAP_THRESHOLD = 10e18; // 10 tokens (18 decimals)

    // ─── State ──────────────────────────────────────────────────────────────────
    /// @notice Tracks the current LP fee for each pool managed by this hook
    mapping(PoolId => uint24) public currentLPFee;

    /// @notice The protocol fee controller this hook is authorized to call
    CLDynamicFeeHookProtocolFeeController public protocolFeeController;

    // ─── Events ─────────────────────────────────────────────────────────────────
    event LPFeeUpdated(PoolId indexed poolId, uint24 newFee);
    event ProtocolFeeControllerSet(address indexed controller);

    // ─── Errors ─────────────────────────────────────────────────────────────────
    error ProtocolFeeControllerNotSet();

    // ────────────────────────────────────────────────────────────────────────────

    constructor(ICLPoolManager _poolManager) CLBaseHook(_poolManager) Ownable(msg.sender) {}

    /// @notice Set the protocol fee controller reference (onlyOwner)
    function setProtocolFeeController(CLDynamicFeeHookProtocolFeeController _controller) external onlyOwner {
        protocolFeeController = _controller;
        emit ProtocolFeeControllerSet(address(_controller));
    }

    /// @notice Allows the hook owner to set the protocol fee for a pool this hook manages.
    ///         The hook must be authorized in the CLDynamicFeeHookProtocolFeeController first.
    /// @param key      The pool key of the target pool
    /// @param newProtocolFee  Encoded protocol fee (lower 12 bits = 0→1, upper 12 bits = 1→0).
    ///                        Max 4000 (0.4%) per direction.
    function updateProtocolFee(PoolKey memory key, uint24 newProtocolFee) external onlyOwner {
        if (address(protocolFeeController) == address(0)) revert ProtocolFeeControllerNotSet();
        protocolFeeController.setProtocolFee(key, newProtocolFee);
    }

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

    // ─── Hook callbacks ──────────────────────────────────────────────────────────

    /// @dev Called once after the pool is initialized. Sets the initial LP fee to BASE_LP_FEE.
    function _afterInitialize(address, PoolKey calldata key, uint160, int24) internal override returns (bytes4) {
        PoolId poolId = key.toId();
        currentLPFee[poolId] = BASE_LP_FEE;
        poolManager.updateDynamicLPFee(key, BASE_LP_FEE);
        emit LPFeeUpdated(poolId, BASE_LP_FEE);
        return this.afterInitialize.selector;
    }

    /// @dev Called after every swap. Computes a new LP fee based on swap size and
    ///      updates the pool's dynamic LP fee when it changes.
    function _afterSwap(
        address,
        PoolKey calldata key,
        ICLPoolManager.SwapParams calldata params,
        BalanceDelta,
        bytes calldata
    ) internal override returns (bytes4, int128) {
        // Derive the absolute value of the swap amount
        uint256 absAmount =
            params.amountSpecified < 0 ? uint256(-params.amountSpecified) : uint256(params.amountSpecified);

        // Tiered fee based on swap size
        uint24 newFee;
        if (absAmount >= HIGH_SWAP_THRESHOLD) {
            newFee = HIGH_LP_FEE;
        } else if (absAmount >= MID_SWAP_THRESHOLD) {
            newFee = MID_LP_FEE;
        } else {
            newFee = BASE_LP_FEE;
        }

        // Only update storage + pool manager when the fee actually changes
        PoolId poolId = key.toId();
        if (newFee != currentLPFee[poolId]) {
            currentLPFee[poolId] = newFee;
            poolManager.updateDynamicLPFee(key, newFee);
            emit LPFeeUpdated(poolId, newFee);
        }

        return (this.afterSwap.selector, 0);
    }
}
