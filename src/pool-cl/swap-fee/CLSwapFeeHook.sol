// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import {Ownable} from "openzeppelin-contracts/contracts/access/Ownable.sol";
import {CLBaseHook} from "../CLBaseHook.sol";
import {ICLPoolManager} from "infinity-core/src/pool-cl/interfaces/ICLPoolManager.sol";
import {PoolKey} from "infinity-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "infinity-core/src/types/PoolId.sol";
import {Currency} from "infinity-core/src/types/Currency.sol";
import {BalanceDelta} from "infinity-core/src/types/BalanceDelta.sol";
import {BalanceDeltaLibrary} from "infinity-core/src/types/BalanceDelta.sol";
import "infinity-core/src/types/BeforeSwapDelta.sol";
import {SafeCast} from "infinity-core/src/libraries/SafeCast.sol";

/// @title CLSwapFeeHook
/// @notice A CL hook that charges swap fee on a chosen currency (e.g. only on Cake in a USDT/Cake pair).
///         - When that currency is INPUT: user pays e.g. 100, fee 1% → BeforeSwapDelta reduces amountToSwap to 99
///           (pool receives 99, hook receives 1 as fee).
///         - When that currency is OUTPUT: afterSwap charges 1% of output; hook receives that amount as fee.
///         In both cases the fee is directly minted to the vault and held there (accruedFees); owner withdraws via withdrawFees.
/// @dev Use setTokenChargeFee(currency, true) only for the token to charge (e.g. Cake).
contract CLSwapFeeHook is CLBaseHook, Ownable {
    using PoolIdLibrary for PoolKey;

    /// @notice Fee denominator (1e6 = 100%)
    uint256 public constant FEE_DENOMINATOR = 1_000_000;

    /// @notice Whether to charge fee when this currency is involved (e.g. true only for Cake in USDT/Cake pair)
    mapping(Currency => bool) public tokenChargeFee;

    /// @notice Sell fee rate (input token), in FEE_DENOMINATOR units (e.g. 10000 = 1%)
    uint256 public sellFeeRate;

    /// @notice Buy fee rate (output token), in FEE_DENOMINATOR units (e.g. 10000 = 1%)
    uint256 public buyFeeRate;

    /// @notice Cumulative fees collected per currency (for accounting)
    mapping(Currency => uint256) public feesCollected;

    /// @notice Accumulated vault ERC-6909 claims per currency, withdrawable by owner (both sell and buy fee settled via mint)
    mapping(Currency => uint256) public accruedFees;

    event TokenChargeFeeSet(Currency indexed currency, bool charge);
    event SellFeeRateSet(uint256 rate);
    event BuyFeeRateSet(uint256 rate);
    event FeesWithdrawn(Currency indexed currency, address indexed to, uint256 amount);
    event FeeCollected(Currency indexed currency, uint256 amount);

    error InvalidFeeRate();
    error InsufficientAccruedFees();
    error ZeroAddress();

    constructor(ICLPoolManager _poolManager) CLBaseHook(_poolManager) Ownable(msg.sender) {}

    /// @notice Set whether to charge fee for a token (onlyOwner)
    function setTokenChargeFee(Currency currency, bool charge) external onlyOwner {
        tokenChargeFee[currency] = charge;
        emit TokenChargeFeeSet(currency, charge);
    }

    /// @notice Set sell fee rate in FEE_DENOMINATOR units (onlyOwner). Max 100%.
    function setSellFeeRate(uint256 rate) external onlyOwner {
        if (rate > FEE_DENOMINATOR) revert InvalidFeeRate();
        sellFeeRate = rate;
        emit SellFeeRateSet(rate);
    }

    /// @notice Set buy fee rate in FEE_DENOMINATOR units (onlyOwner). Max 100%.
    function setBuyFeeRate(uint256 rate) external onlyOwner {
        if (rate > FEE_DENOMINATOR) revert InvalidFeeRate();
        buyFeeRate = rate;
        emit BuyFeeRateSet(rate);
    }

    /// @notice Withdraw accumulated protocol fees to recipient (V1 style: burn vault claims and take underlying).
    /// @param currency Currency to withdraw
    /// @param to Recipient; must not be zero
    /// @param amount Amount to withdraw; pass 0 to withdraw entire accrued balance
    function withdrawFees(Currency currency, address to, uint256 amount) external onlyOwner {
        if (to == address(0)) revert ZeroAddress();

        uint256 available = accruedFees[currency];
        if (amount == 0) amount = available;
        if (amount > available) revert InsufficientAccruedFees();

        accruedFees[currency] = available - amount;

        vault.lock(abi.encode(currency, to, amount));

        emit FeesWithdrawn(currency, to, amount);
    }

    /// @notice Called by the vault during fee withdrawal. Burns hook's ERC-6909 claims and forwards underlying to recipient.
    function lockAcquired(bytes calldata data) external override vaultOnly returns (bytes memory) {
        (Currency currency, address recipient, uint256 amount) = abi.decode(data, (Currency, address, uint256));

        vault.burn(address(this), currency, amount);
        vault.take(currency, recipient, amount);

        return abi.encode(true);
    }

    // ─── Hook registration ─────────────────────────────────────────────────────

    function getHooksRegistrationBitmap() external pure override returns (uint16) {
        return _hooksRegistrationBitmapFrom(
            Permissions({
                beforeInitialize: false,
                afterInitialize: false,
                beforeAddLiquidity: false,
                afterAddLiquidity: false,
                beforeRemoveLiquidity: false,
                afterRemoveLiquidity: false,
                beforeSwap: true,
                afterSwap: true,
                beforeDonate: false,
                afterDonate: false,
                beforeSwapReturnDelta: true,
                afterSwapReturnDelta: true,
                afterAddLiquidityReturnDelta: false,
                afterRemoveLiquidityReturnDelta: false
            })
        );
    }

    // ─── Hook callbacks ────────────────────────────────────────────────────────

    /// @dev When fee currency is input (e.g. user pays 100 Cake, 1% fee): return +fee so amountToSwap becomes 99, pool gets 99, hook gets 1; fee minted in settleFeesInLock.
    function _beforeSwap(address, PoolKey calldata key, ICLPoolManager.SwapParams calldata params, bytes calldata)
        internal
        override
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        uint256 rate = sellFeeRate;
        if (rate == 0) return (this.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);

        Currency inputCurrency = params.zeroForOne ? key.currency0 : key.currency1;
        if (!tokenChargeFee[inputCurrency]) return (this.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);

        uint256 amountIn =
            params.amountSpecified < 0 ? uint256(-params.amountSpecified) : uint256(params.amountSpecified);
        uint256 feeAmount = (amountIn * rate) / FEE_DENOMINATOR;
        if (feeAmount == 0) return (this.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);

        unchecked {
            feesCollected[inputCurrency] += feeAmount;
            accruedFees[inputCurrency] += feeAmount;
        }
        emit FeeCollected(inputCurrency, feeAmount);

        // Mint the fee to vault immediately
        vault.mint(address(this), inputCurrency, feeAmount);

        // +fee → amountToSwap += fee, so amountToSwap becomes -(amountIn - fee) = -99 when amountIn=100, fee=1; pool receives 99, hook receives 1
        int128 feeSpecified = SafeCast.toInt128(feeAmount);
        int128 feeUnspecified = 0;
        BeforeSwapDelta hookDelta = toBeforeSwapDelta(feeSpecified, feeUnspecified);
        return (this.beforeSwap.selector, hookDelta, 0);
    }

    /// @dev When fee currency is output (e.g. user receives Cake): charge rate% of output, return +fee; fee minted in settleFeesInLock.
    function _afterSwap(
        address,
        PoolKey calldata key,
        ICLPoolManager.SwapParams calldata params,
        BalanceDelta delta,
        bytes calldata
    ) internal override returns (bytes4, int128) {
        uint256 rate = buyFeeRate;
        if (rate == 0) return (this.afterSwap.selector, 0);

        Currency outputCurrency = params.zeroForOne ? key.currency1 : key.currency0;
        if (!tokenChargeFee[outputCurrency]) return (this.afterSwap.selector, 0);

        int128 outputAmount = params.zeroForOne ? delta.amount1() : delta.amount0();
        if (outputAmount <= 0) return (this.afterSwap.selector, 0);

        uint256 feeAmount = (uint256(int256(outputAmount)) * rate) / FEE_DENOMINATOR;
        if (feeAmount == 0) return (this.afterSwap.selector, 0);

        unchecked {
            feesCollected[outputCurrency] += feeAmount;
            accruedFees[outputCurrency] += feeAmount;
        }
        emit FeeCollected(outputCurrency, feeAmount);

        // Mint the fee to vault immediately
        vault.mint(address(this), outputCurrency, feeAmount);

        return (this.afterSwap.selector, SafeCast.toInt128(feeAmount));
    }
}
