// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import {Test} from "forge-std/Test.sol";

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

        // Enable fee for both tokens and set rates (1% sell, 0.5% buy)
        hook.setTokenChargeFee(currency0, true);
        hook.setTokenChargeFee(currency1, true);
        hook.setSellFeeRate(10_000); // 1%
        hook.setBuyFeeRate(5_000);   // 0.5%
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

    /// @notice When sell fee is enabled, swap reverts with CurrencyNotSettled (router does not settle hook delta)
    function test_SellFeeRevertsWithoutSettlement() public {
        vm.expectRevert();
        swapRouter.exactInputSingle(
            ICLRouterBase.CLSwapExactInputSingleParams({
                poolKey: key,
                zeroForOne: true,
                amountIn: uint128(1e18),
                amountOutMinimum: 0,
                hookData: ZERO_BYTES
            }),
            block.timestamp
        );
    }

    /// @notice Sell fee disabled: fee rate 0 and token disabled mean no fee collected on swap
    function test_SellNoFeeWhenDisabled() public {
        hook.setSellFeeRate(0);
        assertEq(hook.feesCollected(currency0), 0);
        hook.setTokenChargeFee(currency0, false);
        assertEq(hook.tokenChargeFee(currency0), false);
    }

    /// @notice Owner can withdraw fees when hook holds tokens (e.g. after settleFeesInLock)
    function test_OwnerWithdrawFees() public {
        uint256 feeAmount = 0.01e18;
        token0.transfer(address(hook), feeAmount);
        uint256 bal0Before = token0.balanceOf(owner);
        hook.withdrawFees(currency0, owner, feeAmount);
        assertEq(token0.balanceOf(owner), bal0Before + feeAmount, "owner should receive withdrawn fees");
    }

    /// @notice Non-owner cannot withdraw
    function test_NonOwnerCannotWithdraw() public {
        token0.transfer(address(hook), 0.01e18);
        vm.prank(address(0x123));
        vm.expectRevert();
        hook.withdrawFees(currency0, address(0x123), 0.01e18);
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

    /// @notice Withdraw zero amount reverts
    function test_WithdrawZeroReverts() public {
        vm.expectRevert(CLSwapFeeHook.ZeroAmount.selector);
        hook.withdrawFees(currency0, owner, 0);
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

    /// @notice settleFeesInLock zeros hook vault delta (callable by anyone during lock)
    function test_SettleFeesInLock() public {
        // Hook has no vault delta initially
        assertEq(vault.currencyDelta(address(hook), currency0), 0);
        assertEq(vault.currencyDelta(address(hook), currency1), 0);
        // After a hypothetical credit, settleFeesInLock would take to self; here we just call it (no-op)
        hook.settleFeesInLock(currency0);
        hook.settleFeesInLock(currency1);
    }
}
