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
import {CLDirectionalFeeHook} from "../../src/pool-cl/dynamic-fee/CLDirectionalFeeHook.sol";

contract CLDirectionalFeeHookTest is Test, Deployers, DeployPermit2 {
    using PoolIdLibrary for PoolKey;
    using CLPoolParametersHelper for bytes32;

    // ─── Infrastructure ──────────────────────────────────────────────────────────
    IVault vault;
    ICLPoolManager poolManager;
    IAllowanceTransfer permit2;
    MockCLPositionManager cpm;
    MockCLSwapRouter swapRouter;

    // ─── Contract under test ─────────────────────────────────────────────────────
    CLDirectionalFeeHook hook;

    // ─── Pool ────────────────────────────────────────────────────────────────────
    MockERC20 token0;
    MockERC20 token1;
    Currency currency0;
    Currency currency1;
    PoolKey key;
    PoolId id;

    // ─── Setup ───────────────────────────────────────────────────────────────────

    function setUp() public {
        // 1. Deploy tokens
        MockERC20[] memory tokens = deployTokens(2, type(uint256).max);
        (currency0, currency1) = SortTokens.sort(tokens[0], tokens[1]);
        token0 = MockERC20(Currency.unwrap(currency0));
        token1 = MockERC20(Currency.unwrap(currency1));

        // 2. Deploy vault + pool manager (test contract is the owner)
        (vault, poolManager) = createFreshManager();

        // 3. Deploy hook
        hook = new CLDirectionalFeeHook(poolManager);

        // 4. Deploy router helpers
        permit2 = IAllowanceTransfer(deployPermit2());
        cpm = new MockCLPositionManager(vault, poolManager, permit2);
        swapRouter = new MockCLSwapRouter(vault, poolManager);

        // 5. Approve tokens
        address[3] memory approvalAddresses = [address(cpm), address(swapRouter), address(permit2)];
        for (uint256 i; i < approvalAddresses.length; i++) {
            token0.approve(approvalAddresses[i], type(uint256).max);
            token1.approve(approvalAddresses[i], type(uint256).max);
        }
        permit2.approve(address(token0), address(cpm), type(uint160).max, type(uint48).max);
        permit2.approve(address(token1), address(cpm), type(uint160).max, type(uint48).max);

        // 6. Build pool key — must use DYNAMIC_FEE_FLAG for a dynamic-fee pool
        key = PoolKey({
            currency0: currency0,
            currency1: currency1,
            hooks: hook,
            poolManager: poolManager,
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            parameters: bytes32(uint256(hook.getHooksRegistrationBitmap())).setTickSpacing(60)
        });
        id = key.toId();

        // 7. Initialize pool (triggers afterInitialize → sets INITIAL_FEE)
        poolManager.initialize(key, SQRT_RATIO_1_1);

        // 8. Add initial liquidity
        cpm.mint(key, -120, 120, 10e18, 1e18, 1e18, address(this), ZERO_BYTES);
    }

    // ─── LP Fee tests ────────────────────────────────────────────────────────────

    /// @notice After pool initialization the hook should have set INITIAL_FEE (1.0%)
    function test_InitialFeeIsSet() public view {
        assertEq(hook.currentLPFee(id), hook.INITIAL_FEE());
        assertEq(hook.currentLPFee(id), 10000); // 1.0%
    }

    /// @notice Test that fee constants are set correctly
    function test_FeeConstants() public view {
        assertEq(hook.INITIAL_FEE(), 10000); // 1.0%
        assertEq(hook.ZERO_FOR_ONE_FEE(), 10000); // 1.0%
        assertEq(hook.ONE_FOR_ZERO_FEE(), 15000); // 1.5%
    }

    /// @notice Swap zeroForOne=true should set fee to 1.0%
    function test_ZeroForOneSwapSetsFeeToOnePercent() public {
        swapRouter.exactInputSingle(
            ICLRouterBase.CLSwapExactInputSingleParams({
                poolKey: key, zeroForOne: true, amountIn: 0.5e18, amountOutMinimum: 0, hookData: ZERO_BYTES
            }),
            block.timestamp
        );

        assertEq(hook.currentLPFee(id), hook.ZERO_FOR_ONE_FEE());
        assertEq(hook.currentLPFee(id), 10000); // 1.0%
    }

    /// @notice Swap zeroForOne=false should set fee to 1.5%
    function test_OneForZeroSwapSetsFeeToOnePointFivePercent() public {
        swapRouter.exactInputSingle(
            ICLRouterBase.CLSwapExactInputSingleParams({
                poolKey: key, zeroForOne: false, amountIn: 0.5e18, amountOutMinimum: 0, hookData: ZERO_BYTES
            }),
            block.timestamp
        );

        assertEq(hook.currentLPFee(id), hook.ONE_FOR_ZERO_FEE());
        assertEq(hook.currentLPFee(id), 15000); // 1.5%
    }

    /// @notice Fee changes when swap direction changes
    function test_FeeChangesWithDirection() public {
        // First swap: zeroForOne=true → 1.0%
        swapRouter.exactInputSingle(
            ICLRouterBase.CLSwapExactInputSingleParams({
                poolKey: key, zeroForOne: true, amountIn: 0.3e18, amountOutMinimum: 0, hookData: ZERO_BYTES
            }),
            block.timestamp
        );
        assertEq(hook.currentLPFee(id), 10000);

        // Second swap: zeroForOne=false → 1.5%
        swapRouter.exactInputSingle(
            ICLRouterBase.CLSwapExactInputSingleParams({
                poolKey: key, zeroForOne: false, amountIn: 0.2e18, amountOutMinimum: 0, hookData: ZERO_BYTES
            }),
            block.timestamp
        );
        assertEq(hook.currentLPFee(id), 15000);

        // Third swap: back to zeroForOne=true → 1.0%
        swapRouter.exactInputSingle(
            ICLRouterBase.CLSwapExactInputSingleParams({
                poolKey: key, zeroForOne: true, amountIn: 0.2e18, amountOutMinimum: 0, hookData: ZERO_BYTES
            }),
            block.timestamp
        );
        assertEq(hook.currentLPFee(id), 10000);
    }

    /// @notice Multiple swaps in the same direction maintain the same fee
    function test_ConsecutiveSwapsInSameDirection() public {
        // Add more liquidity to support consecutive swaps
        cpm.mint(key, -120, 120, 100e18, 100e18, 100e18, address(this), ZERO_BYTES);

        // First swap zeroForOne=true
        swapRouter.exactInputSingle(
            ICLRouterBase.CLSwapExactInputSingleParams({
                poolKey: key, zeroForOne: true, amountIn: 0.1e18, amountOutMinimum: 0, hookData: ZERO_BYTES
            }),
            block.timestamp
        );
        assertEq(hook.currentLPFee(id), 10000);

        // Second swap zeroForOne=true (same direction)
        swapRouter.exactInputSingle(
            ICLRouterBase.CLSwapExactInputSingleParams({
                poolKey: key, zeroForOne: true, amountIn: 0.1e18, amountOutMinimum: 0, hookData: ZERO_BYTES
            }),
            block.timestamp
        );
        assertEq(hook.currentLPFee(id), 10000); // Still 1.0%
    }

    /// @notice Large swap in zeroForOne direction maintains 1.0% fee
    function test_LargeZeroForOneSwap() public {
        // Add more liquidity for large swap
        cpm.mint(key, -120, 120, 1000e18, 1000e18, 1000e18, address(this), ZERO_BYTES);

        swapRouter.exactInputSingle(
            ICLRouterBase.CLSwapExactInputSingleParams({
                poolKey: key, zeroForOne: true, amountIn: 50e18, amountOutMinimum: 0, hookData: ZERO_BYTES
            }),
            block.timestamp
        );

        // Fee should still be 1.0% regardless of swap size
        assertEq(hook.currentLPFee(id), hook.ZERO_FOR_ONE_FEE());
        assertEq(hook.currentLPFee(id), 10000);
    }

    /// @notice Large swap in oneForZero direction maintains 1.5% fee
    function test_LargeOneForZeroSwap() public {
        // Add more liquidity for large swap
        cpm.mint(key, -120, 120, 1000e18, 1000e18, 1000e18, address(this), ZERO_BYTES);

        swapRouter.exactInputSingle(
            ICLRouterBase.CLSwapExactInputSingleParams({
                poolKey: key, zeroForOne: false, amountIn: 50e18, amountOutMinimum: 0, hookData: ZERO_BYTES
            }),
            block.timestamp
        );

        // Fee should still be 1.5% regardless of swap size
        assertEq(hook.currentLPFee(id), hook.ONE_FOR_ZERO_FEE());
        assertEq(hook.currentLPFee(id), 15000);
    }

    /// @notice Verify LPFeeUpdated event is emitted correctly
    function test_LPFeeUpdatedEventEmitted() public {
        // Expect event when fee changes
        vm.expectEmit(true, false, false, true, address(hook));
        emit CLDirectionalFeeHook.LPFeeUpdated(id, 15000);

        swapRouter.exactInputSingle(
            ICLRouterBase.CLSwapExactInputSingleParams({
                poolKey: key, zeroForOne: false, amountIn: 0.5e18, amountOutMinimum: 0, hookData: ZERO_BYTES
            }),
            block.timestamp
        );
    }
}
