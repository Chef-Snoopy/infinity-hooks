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
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";

/// @title CLSwapFeeHook
/// @notice A CL hook that charges configurable fees on swaps:
///         - Sell: fee charged in beforeSwap (on the input token)
///         - Buy: fee charged in afterSwap (on the output token)
///         Fees are credited to the hook in the infinity vault; owner withdraws via take (or burn + take).
/// @dev Per-token fee can be enabled/disabled; buy and sell fee rates are set separately.
contract CLSwapFeeHook is CLBaseHook, Ownable {
    using PoolIdLibrary for PoolKey;
    using SafeERC20 for IERC20;

    /// @notice Fee denominator (1e6 = 100%)
    uint256 public constant FEE_DENOMINATOR = 1_000_000;

    /// @notice Whether to charge fee for a given currency
    mapping(Currency => bool) public tokenChargeFee;

    /// @notice Sell fee rate (input token), in FEE_DENOMINATOR units (e.g. 10000 = 1%)
    uint256 public sellFeeRate;

    /// @notice Buy fee rate (output token), in FEE_DENOMINATOR units (e.g. 10000 = 1%)
    uint256 public buyFeeRate;

    /// @notice Cumulative fees collected per currency (for accounting)
    mapping(Currency => uint256) public feesCollected;

    event TokenChargeFeeSet(Currency indexed currency, bool charge);
    event SellFeeRateSet(uint256 rate);
    event BuyFeeRateSet(uint256 rate);
    event FeesWithdrawn(Currency indexed currency, address indexed to, uint256 amount);

    error InvalidFeeRate();
    error InsufficientFeeBalance();
    error ZeroAmount();

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

    /// @notice Withdraw collected fees to recipient. Transfers from this hook's token balance (owner only).
    /// @dev Call settleFeesInLock (during the swap lock) first so fees are pulled from vault to this contract.
    /// @param currency Currency to withdraw
    /// @param to Recipient
    /// @param amount Amount to withdraw
    function withdrawFees(Currency currency, address to, uint256 amount) external onlyOwner {
        if (amount == 0) revert ZeroAmount();
        IERC20(Currency.unwrap(currency)).safeTransfer(to, amount);
        emit FeesWithdrawn(currency, to, amount);
    }

    /// @notice Withdraw collected fees by burning vault balance then taking. Use when fee was minted as vault tokens.
    /// @param currency Currency to withdraw
    /// @param to Recipient
    /// @param amount Amount to withdraw
    function withdrawFeesByBurn(Currency currency, address to, uint256 amount) external onlyOwner {
        if (amount == 0) revert ZeroAmount();
        vault.burn(address(this), currency, amount);
        vault.take(currency, to, amount);
        emit FeesWithdrawn(currency, to, amount);
    }

    /// @notice Settle the hook's positive vault delta within the current lock (call by the locker after a swap).
    ///         Zeros the hook's vault balance by taking fees to this contract so the lock can complete.
    /// @dev Must be called during the same vault.lock() that performed the swap, before the lock returns.
    function settleFeesInLock(Currency currency) external {
        int256 delta = vault.currencyDelta(address(this), currency);
        if (delta > 0) {
            vault.take(currency, address(this), uint256(delta));
        }
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

    /// @dev Sell: charge fee on input token in beforeSwap. Return extra delta so user pays more (specified = input).
    function _beforeSwap(
        address,
        PoolKey calldata key,
        ICLPoolManager.SwapParams calldata params,
        bytes calldata
    ) internal override returns (bytes4, BeforeSwapDelta, uint24) {
        uint256 rate = sellFeeRate;
        if (rate == 0) return (this.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);

        Currency inputCurrency = params.zeroForOne ? key.currency0 : key.currency1;
        if (!tokenChargeFee[inputCurrency]) return (this.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);

        uint256 amountIn = params.amountSpecified < 0
            ? uint256(-params.amountSpecified)
            : uint256(params.amountSpecified);
        uint256 feeAmount = (amountIn * rate) / FEE_DENOMINATOR;
        if (feeAmount == 0) return (this.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);

        unchecked {
            feesCollected[inputCurrency] += feeAmount;
        }

        // Specified = input: user pays more (negative delta in specified token)
        int128 feeSpecified = -SafeCast.toInt128(feeAmount);
        int128 feeUnspecified = 0;
        BeforeSwapDelta hookDelta = toBeforeSwapDelta(feeSpecified, feeUnspecified);
        return (this.beforeSwap.selector, hookDelta, 0);
    }

    /// @dev Buy: charge fee on output token in afterSwap. Return positive int128 so hook receives that much output.
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
        }

        return (this.afterSwap.selector, SafeCast.toInt128(feeAmount));
    }
}
