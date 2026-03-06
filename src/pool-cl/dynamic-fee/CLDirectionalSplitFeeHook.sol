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

/// @title CLDirectionalSplitFeeHook
/// @notice A directional-fee CL hook that:
///         1. Sets initial fees on pool initialization via afterInitialize.
///         2. Adjusts both LP fee and protocol fee before every swap based on direction.
///         3. Maintains the invariant: LPFee = 2 * protocolFee
///
/// @dev Fee rule (applied in beforeSwap):
///      zeroForOne = true:
///          - Total fee: ~1.0% (9999)
///          - Protocol fee: 3333 (0.333%)
///          - LP fee: 6666 (0.666%)
///
///      zeroForOne = false:
///          - Total fee: 1.2% (12000)
///          - Protocol fee: 4000 (0.4%, max allowed)
///          - LP fee: 8000 (0.8%)
///
/// @dev Pool key must be initialized with fee = LPFeeLibrary.DYNAMIC_FEE_FLAG (0x800000).
contract CLDirectionalSplitFeeHook is CLBaseHook, Ownable {
    using PoolIdLibrary for PoolKey;

    // ─── Fee constants (in hundredths of a bip) ─────────────────────────────────
    // zeroForOne = true: total ≈ 1.0%
    uint24 public constant ZERO_FOR_ONE_LP_FEE = 6666; // 0.666%
    uint24 public constant ZERO_FOR_ONE_PROTOCOL_FEE = 3333; // 0.333%

    // zeroForOne = false: total = 1.2% (adjusted to stay within protocol fee limit)
    uint24 public constant ONE_FOR_ZERO_LP_FEE = 8000; // 0.8%
    uint24 public constant ONE_FOR_ZERO_PROTOCOL_FEE = 4000; // 0.4% (max allowed)

    // Initial fees (same as zeroForOne)
    uint24 public constant INITIAL_LP_FEE = ZERO_FOR_ONE_LP_FEE;
    uint24 public constant INITIAL_PROTOCOL_FEE = ZERO_FOR_ONE_PROTOCOL_FEE;

    // ─── State ──────────────────────────────────────────────────────────────────
    /// @notice Tracks the current LP fee for each pool managed by this hook
    mapping(PoolId => uint24) public currentLPFee;

    /// @notice Tracks the current protocol fee for each pool managed by this hook
    mapping(PoolId => uint24) public currentProtocolFee;

    /// @notice The protocol fee controller this hook is authorized to call
    CLDynamicFeeHookProtocolFeeController public protocolFeeController;

    // ─── Events ─────────────────────────────────────────────────────────────────
    event LPFeeUpdated(PoolId indexed poolId, uint24 newLPFee);
    event ProtocolFeeUpdated(PoolId indexed poolId, uint24 newProtocolFee);
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

    /// @dev Called once after the pool is initialized. Sets the initial LP fee and protocol fee.
    function _afterInitialize(address, PoolKey calldata key, uint160, int24) internal override returns (bytes4) {
        if (address(protocolFeeController) == address(0)) revert ProtocolFeeControllerNotSet();

        PoolId poolId = key.toId();

        // Set initial LP fee
        currentLPFee[poolId] = INITIAL_LP_FEE;
        poolManager.updateDynamicLPFee(key, INITIAL_LP_FEE);
        emit LPFeeUpdated(poolId, INITIAL_LP_FEE);

        // Set initial protocol fee (same for both directions)
        uint24 encodedProtocolFee = INITIAL_PROTOCOL_FEE | (uint24(INITIAL_PROTOCOL_FEE) << 12);
        currentProtocolFee[poolId] = encodedProtocolFee;
        protocolFeeController.setProtocolFee(key, encodedProtocolFee);
        emit ProtocolFeeUpdated(poolId, encodedProtocolFee);

        return this.afterInitialize.selector;
    }

    /// @dev Called before every swap. Sets the LP fee and protocol fee based on swap direction.
    ///      Maintains invariant: LPFee = 2 * protocolFee
    function _beforeSwap(address, PoolKey calldata key, ICLPoolManager.SwapParams calldata params, bytes calldata)
        internal
        override
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        // Determine fees based on swap direction
        uint24 newLPFee;
        uint24 newProtocolFee; // per direction

        if (params.zeroForOne) {
            newLPFee = ZERO_FOR_ONE_LP_FEE;
            newProtocolFee = ZERO_FOR_ONE_PROTOCOL_FEE;
        } else {
            newLPFee = ONE_FOR_ZERO_LP_FEE;
            newProtocolFee = ONE_FOR_ZERO_PROTOCOL_FEE;
        }

        // Encode protocol fee for both directions (same fee for both)
        uint24 encodedProtocolFee = newProtocolFee | (uint24(newProtocolFee) << 12);

        PoolId poolId = key.toId();

        // Update LP fee if changed
        if (newLPFee != currentLPFee[poolId]) {
            currentLPFee[poolId] = newLPFee;
            poolManager.updateDynamicLPFee(key, newLPFee);
            emit LPFeeUpdated(poolId, newLPFee);
        }

        // Update protocol fee if changed
        if (encodedProtocolFee != currentProtocolFee[poolId]) {
            currentProtocolFee[poolId] = encodedProtocolFee;
            protocolFeeController.setProtocolFee(key, encodedProtocolFee);
            emit ProtocolFeeUpdated(poolId, encodedProtocolFee);
        }

        return (this.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
    }
}
