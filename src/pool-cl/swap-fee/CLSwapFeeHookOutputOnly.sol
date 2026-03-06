// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import {Ownable} from "openzeppelin-contracts/contracts/access/Ownable.sol";
import {CLBaseHook} from "../CLBaseHook.sol";
import {ICLPoolManager} from "infinity-core/src/pool-cl/interfaces/ICLPoolManager.sol";
import {PoolKey} from "infinity-core/src/types/PoolKey.sol";
import {PoolIdLibrary} from "infinity-core/src/types/PoolId.sol";
import {Currency} from "infinity-core/src/types/Currency.sol";
import {BalanceDelta} from "infinity-core/src/types/BalanceDelta.sol";
import {SafeCast} from "infinity-core/src/libraries/SafeCast.sol";

/// @title CLSwapFeeHookOutputOnly
/// @notice A CL hook that charges a configurable fee on the *output* token only (user receives less).
///         Fee is settled in the hook via vault.mint; owner withdraws via vault.lock + burn + take.
/// @dev No beforeSwap / settleFeesInLock; compatible with any router that does not need to call hook helpers.
contract CLSwapFeeHookOutputOnly is CLBaseHook, Ownable {
    using PoolIdLibrary for PoolKey;

    /// @notice Fee denominator (1e6 = 100%)
    uint256 public constant FEE_DENOMINATOR = 1_000_000;

    /// @notice Whether to charge fee when this currency is the output
    mapping(Currency => bool) public tokenChargeFee;

    /// @notice Fee rate on output token, in FEE_DENOMINATOR units (e.g. 10000 = 1%)
    uint256 public feeRate;

    /// @notice Cumulative fees collected per currency (for accounting)
    mapping(Currency => uint256) public feesCollected;

    /// @notice Accumulated vault ERC-6909 claims per currency, withdrawable by owner
    mapping(Currency => uint256) public accruedFees;

    event TokenChargeFeeSet(Currency indexed currency, bool charge);
    event FeeRateSet(uint256 rate);
    event FeesWithdrawn(Currency indexed currency, address indexed to, uint256 amount);
    event FeeCollected(Currency indexed currency, uint256 amount);

    error InvalidFeeRate();
    error InsufficientAccruedFees();
    error ZeroAddress();

    constructor(ICLPoolManager _poolManager) CLBaseHook(_poolManager) Ownable(msg.sender) {}

    /// @notice Set whether to charge fee when this currency is output (onlyOwner)
    function setTokenChargeFee(Currency currency, bool charge) external onlyOwner {
        tokenChargeFee[currency] = charge;
        emit TokenChargeFeeSet(currency, charge);
    }

    /// @notice Set output fee rate in FEE_DENOMINATOR units (onlyOwner). Max 100%.
    function setFeeRate(uint256 rate) external onlyOwner {
        if (rate > FEE_DENOMINATOR) revert InvalidFeeRate();
        feeRate = rate;
        emit FeeRateSet(rate);
    }

    /// @notice Withdraw accumulated protocol fees to recipient (burn vault claims and take underlying).
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
                beforeSwap: false,
                afterSwap: true,
                beforeDonate: false,
                afterDonate: false,
                beforeSwapReturnDelta: false,
                afterSwapReturnDelta: true,
                afterAddLiquidityReturnDelta: false,
                afterRemoveLiquidityReturnDelta: false
            })
        );
    }

    // ─── Hook callback ─────────────────────────────────────────────────────────

    /// @dev Charge fee on output token in afterSwap; mint to settle hook delta.
    function _afterSwap(
        address,
        PoolKey calldata key,
        ICLPoolManager.SwapParams calldata params,
        BalanceDelta delta,
        bytes calldata
    ) internal override returns (bytes4, int128) {
        uint256 rate = feeRate;
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

        vault.mint(address(this), outputCurrency, feeAmount);

        return (this.afterSwap.selector, SafeCast.toInt128(feeAmount));
    }
}
