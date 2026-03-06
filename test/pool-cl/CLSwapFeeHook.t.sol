// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import {Test, Vm} from "forge-std/Test.sol";

import {ICLPoolManager} from "infinity-core/src/pool-cl/interfaces/ICLPoolManager.sol";
import {IVault} from "infinity-core/src/interfaces/IVault.sol";
import {CLPoolManager} from "infinity-core/src/pool-cl/CLPoolManager.sol";
import {Vault} from "infinity-core/src/Vault.sol";
import {Currency} from "infinity-core/src/types/Currency.sol";
import {PoolKey} from "infinity-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "infinity-core/src/types/PoolId.sol";
import {LPFeeLibrary} from "infinity-core/src/libraries/LPFeeLibrary.sol";
import {CLPoolParametersHelper} from "infinity-core/src/pool-cl/libraries/CLPoolParametersHelper.sol";
import {SortTokens} from "infinity-core/test/helpers/SortTokens.sol";
import {Deployers} from "infinity-core/test/pool-cl/helpers/Deployers.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

import {ICLRouterBase} from "infinity-periphery/src/pool-cl/interfaces/ICLRouterBase.sol";
import {DeployPermit2} from "permit2/test/utils/DeployPermit2.sol";
import {IAllowanceTransfer} from "permit2/src/interfaces/IAllowanceTransfer.sol";

import {MockCLSwapRouter} from "./helpers/MockCLSwapRouter.sol";
import {MockCLPositionManager} from "./helpers/MockCLPositionManager.sol";
import {CLSwapFeeHook} from "../../src/pool-cl/swap-fee/CLSwapFeeHook.sol";
import {BalanceDelta} from "infinity-core/src/types/BalanceDelta.sol";
import {BalanceDeltaLibrary} from "infinity-core/src/types/BalanceDelta.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";

contract CLSwapFeeHookTest is Test, Deployers, DeployPermit2 {
    using PoolIdLibrary for PoolKey;
    using CLPoolParametersHelper for bytes32;

    IVault vault;
    ICLPoolManager poolManager;
    IAllowanceTransfer permit2;
    MockCLPositionManager cpm;
    MockCLSwapRouter swapRouter;

    CLSwapFeeHook hook;

    MockERC20 token0;
    MockERC20 token1;
    Currency currency0;
    Currency currency1;
    PoolKey key;
    PoolId id;

    address owner;

    function setUp() public {
        owner = address(this);
        MockERC20[] memory tokens = deployTokens(2, type(uint256).max);
        (currency0, currency1) = SortTokens.sort(tokens[0], tokens[1]);
        token0 = MockERC20(Currency.unwrap(currency0));
        token1 = MockERC20(Currency.unwrap(currency1));

        (vault, poolManager) = createFreshManager();
        hook = new CLSwapFeeHook(poolManager);

        permit2 = IAllowanceTransfer(deployPermit2());
        cpm = new MockCLPositionManager(vault, poolManager, permit2);
        swapRouter = new MockCLSwapRouter(vault, poolManager);

        address[3] memory approvalAddresses = [address(cpm), address(swapRouter), address(permit2)];
        for (uint256 i; i < approvalAddresses.length; i++) {
            token0.approve(approvalAddresses[i], type(uint256).max);
            token1.approve(approvalAddresses[i], type(uint256).max);
        }
        permit2.approve(address(token0), address(cpm), type(uint160).max, type(uint48).max);
        permit2.approve(address(token1), address(cpm), type(uint160).max, type(uint48).max);

        key = PoolKey({
            currency0: currency0,
            currency1: currency1,
            hooks: hook,
            poolManager: poolManager,
            fee: 3000, // 0.3% LP fee
            parameters: bytes32(uint256(hook.getHooksRegistrationBitmap())).setTickSpacing(60)
        });
        id = key.toId();

        poolManager.initialize(key, SQRT_RATIO_1_1);
        cpm.mint(key, -120, 120, 10e18, 1e18, 1e18, address(this), ZERO_BYTES);
        cpm.mint(key, -120, 120, 100e18, 100e18, 100e18, address(this), ZERO_BYTES);

        // Enable fee for both tokens and set rates (1% sell, 0.5% buy)
        hook.setTokenChargeFee(currency0, true);
        hook.setTokenChargeFee(currency1, true);
        hook.setSellFeeRate(10_000); // 1%
        hook.setBuyFeeRate(5_000); // 0.5%
    }

    /// @dev Helper to execute a swap using the swapRouter
    function doSwap(uint256 amountIn, bool zeroForOne) internal {
        swapRouter.exactInputSingle(
            ICLRouterBase.CLSwapExactInputSingleParams({
                poolKey: key,
                zeroForOne: zeroForOne,
                amountIn: uint128(amountIn),
                amountOutMinimum: 0,
                hookData: ZERO_BYTES
            }),
            block.timestamp
        );
    }

    /// @notice No fee when sell fee rate is 0 (hook state only; swap with this hook needs lock to settle hook delta)
    function test_NoSellFeeWhenRateZero() public {
        hook.setSellFeeRate(0);
        assertEq(hook.sellFeeRate(), 0);
        assertEq(hook.feesCollected(currency0), 0);
        assertEq(hook.feesCollected(currency1), 0);
    }

    /// @notice No fee when token charge fee is disabled for input currency
    function test_NoSellFeeWhenTokenDisabled() public {
        hook.setTokenChargeFee(currency0, false);
        assertEq(hook.tokenChargeFee(currency0), false);
        assertEq(hook.feesCollected(currency0), 0);
    }

    /// @notice Sell fee disabled: fee rate 0 and token disabled mean no fee collected on swap
    function test_SellNoFeeWhenDisabled() public {
        hook.setSellFeeRate(0);
        assertEq(hook.feesCollected(currency0), 0);
        hook.setTokenChargeFee(currency0, false);
        assertEq(hook.tokenChargeFee(currency0), false);
    }

    /// @notice Owner can withdraw accrued fees (V1 style: burn vault claims + take to recipient)
    function test_OwnerWithdrawFees() public {
        hook.setSellFeeRate(0);
        uint256 amountIn = 2e18;
        doSwap(amountIn, true);

        uint256 accrued = hook.accruedFees(currency1);
        assertGt(accrued, 0, "accrued buy fee");
        uint256 bal1Before = token1.balanceOf(owner);
        hook.withdrawFees(currency1, owner, 0); // 0 = withdraw all
        assertEq(token1.balanceOf(owner), bal1Before + accrued, "owner should receive withdrawn fees");
        assertEq(hook.accruedFees(currency1), 0, "accrued should be zero after withdraw");
    }

    /// @notice Non-owner cannot withdraw
    function test_NonOwnerCannotWithdraw() public {
        hook.setSellFeeRate(0);
        doSwap(2e18, true);
        uint256 accrued = hook.accruedFees(currency1);
        assertGt(accrued, 0);

        vm.prank(address(0x123));
        vm.expectRevert();
        hook.withdrawFees(currency1, address(0x123), accrued);
    }

    /// @notice setSellFeeRate and setBuyFeeRate onlyOwner
    function test_SetFeeRatesOnlyOwner() public {
        vm.prank(address(0x123));
        vm.expectRevert();
        hook.setSellFeeRate(5000);
        vm.prank(address(0x123));
        vm.expectRevert();
        hook.setBuyFeeRate(5000);
    }

    /// @notice setTokenChargeFee onlyOwner
    function test_SetTokenChargeFeeOnlyOwner() public {
        vm.prank(address(0x123));
        vm.expectRevert();
        hook.setTokenChargeFee(currency0, false);
    }

    /// @notice Cannot set fee rate above 100%
    function test_InvalidFeeRateReverts() public {
        vm.expectRevert(CLSwapFeeHook.InvalidFeeRate.selector);
        hook.setSellFeeRate(1_000_001);
        vm.expectRevert(CLSwapFeeHook.InvalidFeeRate.selector);
        hook.setBuyFeeRate(1_000_001);
    }

    /// @notice Withdraw more than accrued reverts
    function test_WithdrawInsufficientAccruedReverts() public {
        assertEq(hook.accruedFees(currency0), 0);
        vm.expectRevert(CLSwapFeeHook.InsufficientAccruedFees.selector);
        hook.withdrawFees(currency0, owner, 1);
    }

    /// @notice Withdraw to zero address reverts
    function test_WithdrawToZeroReverts() public {
        hook.setSellFeeRate(0);
        doSwap(2e18, true);
        vm.expectRevert(CLSwapFeeHook.ZeroAddress.selector);
        hook.withdrawFees(currency1, address(0), 0);
    }

    /// @notice Fee constants
    function test_FeeDenominator() public view {
        assertEq(hook.FEE_DENOMINATOR(), 1_000_000);
    }

    /// @notice Fee state: when both rates are 0, feesCollected stays 0
    function test_MultipleSwapsWhenFeeDisabled() public {
        hook.setSellFeeRate(0);
        hook.setBuyFeeRate(0);
        assertEq(hook.feesCollected(currency0), 0);
        assertEq(hook.feesCollected(currency1), 0);
    }

    // ─── Input token (sell) fee: computed vs contract data & events ────────────────────────

    /// @notice Charge fee on INPUT token (sell token0): compare computed fee, feesCollected and hook balance
    function test_InputTokenFee_ComputedVsContractAndEvent() public {
        hook.setBuyFeeRate(0); // only test input fee
        uint256 amountIn = 2e18;
        uint256 sellRate = hook.sellFeeRate(); // 10_000 = 1%
        uint256 expectedInputFee = (amountIn * sellRate) / hook.FEE_DENOMINATOR();

        uint256 feesCollected0Before = hook.feesCollected(currency0);
        vm.recordLogs();
        doSwap(amountIn, true);

        uint256 feesCollected0After = hook.feesCollected(currency0);

        assertEq(
            feesCollected0After - feesCollected0Before, expectedInputFee, "feesCollected delta vs computed input fee"
        );
        assertEq(hook.accruedFees(currency0), expectedInputFee, "accruedFees(currency0) = sell fee (vault claims)");
        assertEq(token0.balanceOf(address(hook)), 0, "hook holds vault claims, not ERC20");

        // Event: FeeCollected(currency0, expectedInputFee) — compare event amount with computed fee
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bool foundInputFeeEvent;
        for (uint256 i; i < logs.length; i++) {
            if (logs[i].emitter == address(hook) && logs[i].data.length >= 32) {
                uint256 amount = abi.decode(logs[i].data, (uint256));
                if (
                    amount == expectedInputFee
                        && logs[i].topics[1] == bytes32(uint256(uint160(Currency.unwrap(currency0))))
                ) {
                    foundInputFeeEvent = true;
                    break;
                }
            }
        }
        assertTrue(foundInputFeeEvent, "FeeCollected event for input token (amount + currency match computed fee)");
    }

    /// @notice Charge fee on OUTPUT token (buy token1): compare computed fee, feesCollected and accruedFees
    function test_OutputTokenFee_ComputedVsContractAndEvent() public {
        hook.setSellFeeRate(0); // disable input fee for clearer test
        uint256 amountIn = 2e18;
        uint256 buyRate = hook.buyFeeRate(); // 5_000 = 0.5%

        uint256 feesCollected1Before = hook.feesCollected(currency1);
        uint256 bal1Before = token1.balanceOf(address(this));

        vm.recordLogs();
        doSwap(amountIn, true);

        uint256 bal1After = token1.balanceOf(address(this));
        uint256 outputReceived = bal1After - bal1Before;

        // Output fee: user receives less by fee amount
        // If rawOutput from pool = X, fee = X * buyRate / FEE_DENOMINATOR, user gets X - fee
        // So: outputReceived = rawOutput - fee = rawOutput * (1 - buyRate/FEE_DENOMINATOR)
        // => rawOutput = outputReceived / (1 - buyRate/FEE_DENOMINATOR)
        // => fee = rawOutput * buyRate / FEE_DENOMINATOR
        uint256 rawOutput = (outputReceived * hook.FEE_DENOMINATOR()) / (hook.FEE_DENOMINATOR() - buyRate);
        uint256 expectedOutputFee = rawOutput - outputReceived;

        uint256 feesCollected1After = hook.feesCollected(currency1);
        assertEq(
            feesCollected1After - feesCollected1Before,
            expectedOutputFee,
            "feesCollected(currency1) vs computed output fee"
        );
        assertEq(
            hook.accruedFees(currency1), expectedOutputFee, "accruedFees(currency1) equals output fee (vault claims)"
        );

        // Event: FeeCollected(currency1, expectedOutputFee) — compare event amount with computed fee
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bool foundOutputFeeEvent;
        for (uint256 i; i < logs.length; i++) {
            if (logs[i].emitter == address(hook) && logs[i].data.length >= 32) {
                uint256 amount = abi.decode(logs[i].data, (uint256));
                if (
                    amount == expectedOutputFee
                        && logs[i].topics[1] == bytes32(uint256(uint160(Currency.unwrap(currency1))))
                ) {
                    foundOutputFeeEvent = true;
                    break;
                }
            }
        }
        assertTrue(foundOutputFeeEvent, "FeeCollected event for output token (amount + currency match computed fee)");
    }

    /// @notice Both input and output fee in one swap: verify both fees and totals
    function test_InputAndOutputFee_BothComputedAndMatchContract() public {
        uint256 amountIn = 3e18;
        uint256 sellRate = hook.sellFeeRate();
        uint256 buyRate = hook.buyFeeRate();
        uint256 expectedInputFee = (amountIn * sellRate) / hook.FEE_DENOMINATOR();

        uint256 bal1Before = token1.balanceOf(address(this));
        doSwap(amountIn, true);
        uint256 bal1After = token1.balanceOf(address(this));

        uint256 outputReceived = bal1After - bal1Before;
        uint256 rawOutput = (outputReceived * hook.FEE_DENOMINATOR()) / (hook.FEE_DENOMINATOR() - buyRate);
        uint256 expectedOutputFee = rawOutput - outputReceived;

        assertEq(hook.feesCollected(currency0), expectedInputFee, "input fee: computed vs contract");
        assertEq(hook.feesCollected(currency1), expectedOutputFee, "output fee: computed vs contract");
    }
}
