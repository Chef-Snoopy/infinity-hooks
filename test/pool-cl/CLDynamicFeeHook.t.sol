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
import {CLDynamicFeeHook} from "../../src/pool-cl/dynamic-fee/CLDynamicFeeHook.sol";
import {
    CLDynamicFeeHookProtocolFeeController
} from "../../src/pool-cl/dynamic-fee/CLDynamicFeeHookProtocolFeeController.sol";

contract CLDynamicFeeHookTest is Test, Deployers, DeployPermit2 {
    using PoolIdLibrary for PoolKey;
    using CLPoolParametersHelper for bytes32;

    // ─── Infrastructure ──────────────────────────────────────────────────────────
    IVault vault;
    ICLPoolManager poolManager;
    IAllowanceTransfer permit2;
    MockCLPositionManager cpm;
    MockCLSwapRouter swapRouter;

    // ─── Contracts under test ────────────────────────────────────────────────────
    CLDynamicFeeHook hook;
    CLDynamicFeeHookProtocolFeeController protocolFeeController;

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

        // 3. Deploy ProtocolFeeController (msg.sender = test contract = owner)
        protocolFeeController = new CLDynamicFeeHookProtocolFeeController(address(poolManager));

        // 4. Register ProtocolFeeController with pool manager
        poolManager.setProtocolFeeController(protocolFeeController);

        // 5. Deploy hook (msg.sender = test contract = hook owner)
        hook = new CLDynamicFeeHook(poolManager);

        // 6. Authorize hook in the ProtocolFeeController so it can call setProtocolFee
        protocolFeeController.setAuthorized(address(hook), true);

        // 7. Tell the hook which controller to use
        hook.setProtocolFeeController(protocolFeeController);

        // 8. Deploy router helpers
        permit2 = IAllowanceTransfer(deployPermit2());
        cpm = new MockCLPositionManager(vault, poolManager, permit2);
        swapRouter = new MockCLSwapRouter(vault, poolManager);

        // 9. Approve tokens
        address[3] memory approvalAddresses = [address(cpm), address(swapRouter), address(permit2)];
        for (uint256 i; i < approvalAddresses.length; i++) {
            token0.approve(approvalAddresses[i], type(uint256).max);
            token1.approve(approvalAddresses[i], type(uint256).max);
        }
        permit2.approve(address(token0), address(cpm), type(uint160).max, type(uint48).max);
        permit2.approve(address(token1), address(cpm), type(uint160).max, type(uint48).max);

        // 10. Build pool key — must use DYNAMIC_FEE_FLAG for a dynamic-fee pool
        key = PoolKey({
            currency0: currency0,
            currency1: currency1,
            hooks: hook,
            poolManager: poolManager,
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            parameters: bytes32(uint256(hook.getHooksRegistrationBitmap())).setTickSpacing(60)
        });
        id = key.toId();

        // 11. Initialize pool (triggers afterInitialize → sets BASE_LP_FEE)
        poolManager.initialize(key, SQRT_RATIO_1_1);

        // 12. Add initial liquidity
        cpm.mint(key, -120, 120, 10e18, 1e18, 1e18, address(this), ZERO_BYTES);
    }

    // ─── LP Fee tests ────────────────────────────────────────────────────────────

    /// @notice After pool initialization the hook should have set BASE_LP_FEE (0.3%)
    function test_InitialFeeIsBaseFee() public view {
        assertEq(hook.currentLPFee(id), hook.BASE_LP_FEE());
    }

    /// @notice A swap below MID_SWAP_THRESHOLD keeps the fee at BASE_LP_FEE
    function test_SmallSwapKeepsBaseFee() public {
        swapRouter.exactInputSingle(
            ICLRouterBase.CLSwapExactInputSingleParams({
                poolKey: key,
                zeroForOne: true,
                amountIn: 0.1e18, // < 1e18 → BASE_LP_FEE
                amountOutMinimum: 0,
                hookData: ZERO_BYTES
            }),
            block.timestamp
        );

        assertEq(hook.currentLPFee(id), hook.BASE_LP_FEE());
    }

    /// @notice A swap between MID_SWAP_THRESHOLD and HIGH_SWAP_THRESHOLD raises fee to MID_LP_FEE
    function test_MediumSwapIncreasesFee() public {
        swapRouter.exactInputSingle(
            ICLRouterBase.CLSwapExactInputSingleParams({
                poolKey: key,
                zeroForOne: true,
                amountIn: 5e18, // >= 1e18 and < 10e18 → MID_LP_FEE
                amountOutMinimum: 0,
                hookData: ZERO_BYTES
            }),
            block.timestamp
        );

        assertEq(hook.currentLPFee(id), hook.MID_LP_FEE());
    }

    /// @notice A swap at or above HIGH_SWAP_THRESHOLD raises fee to HIGH_LP_FEE
    function test_LargeSwapIncreasesFeeFurther() public {
        // Add more liquidity so the large swap can execute
        cpm.mint(key, -120, 120, 1000e18, 1000e18, 1000e18, address(this), ZERO_BYTES);

        swapRouter.exactInputSingle(
            ICLRouterBase.CLSwapExactInputSingleParams({
                poolKey: key,
                zeroForOne: true,
                amountIn: 15e18, // >= 10e18 → HIGH_LP_FEE
                amountOutMinimum: 0,
                hookData: ZERO_BYTES
            }),
            block.timestamp
        );

        assertEq(hook.currentLPFee(id), hook.HIGH_LP_FEE());
    }

    /// @notice Fee resets to BASE_LP_FEE when a small swap follows a large one
    function test_FeeResetsAfterSmallSwap() public {
        // First a large swap to set HIGH_LP_FEE
        cpm.mint(key, -120, 120, 1000e18, 1000e18, 1000e18, address(this), ZERO_BYTES);
        swapRouter.exactInputSingle(
            ICLRouterBase.CLSwapExactInputSingleParams({
                poolKey: key, zeroForOne: true, amountIn: 15e18, amountOutMinimum: 0, hookData: ZERO_BYTES
            }),
            block.timestamp
        );
        assertEq(hook.currentLPFee(id), hook.HIGH_LP_FEE());

        // Then a small swap resets the fee back to BASE_LP_FEE
        swapRouter.exactInputSingle(
            ICLRouterBase.CLSwapExactInputSingleParams({
                poolKey: key,
                zeroForOne: false, // reverse direction
                amountIn: 0.1e18,
                amountOutMinimum: 0,
                hookData: ZERO_BYTES
            }),
            block.timestamp
        );
        assertEq(hook.currentLPFee(id), hook.BASE_LP_FEE());
    }

    // ─── ProtocolFeeController access-control tests ──────────────────────────────

    /// @notice Unauthorized callers cannot call setProtocolFee on the controller
    function test_UnauthorizedCannotSetProtocolFee() public {
        address attacker = address(0xdead);
        vm.prank(attacker);
        vm.expectRevert(CLDynamicFeeHookProtocolFeeController.Unauthorized.selector);
        protocolFeeController.setProtocolFee(key, uint24(1000));
    }

    /// @notice The controller owner can set the protocol fee directly
    function test_OwnerCanSetProtocolFee() public {
        // Encode 0.1% (1000) for both directions: lower 12 bits | upper 12 bits
        uint24 encodedFee = uint24(1000) | (uint24(1000) << 12);
        protocolFeeController.setProtocolFee(key, encodedFee);
        assertEq(protocolFeeController.protocolFeeForPoolId(id), encodedFee);
    }

    /// @notice The hook owner can update the protocol fee via hook.updateProtocolFee
    function test_HookOwnerCanUpdateProtocolFeeViaHook() public {
        uint24 encodedFee = uint24(500) | (uint24(500) << 12); // 0.05% both ways
        hook.updateProtocolFee(key, encodedFee);
        assertEq(protocolFeeController.protocolFeeForPoolId(id), encodedFee);
    }

    /// @notice A newly authorized address can call setProtocolFee
    function test_AuthorizedAddressCanSetProtocolFee() public {
        address newOperator = address(0xbabe);

        // Not authorized yet → should revert
        vm.prank(newOperator);
        vm.expectRevert(CLDynamicFeeHookProtocolFeeController.Unauthorized.selector);
        protocolFeeController.setProtocolFee(key, uint24(1000));

        // Grant authorization
        protocolFeeController.setAuthorized(newOperator, true);
        assertTrue(protocolFeeController.authorized(newOperator));

        // Now it should succeed
        vm.prank(newOperator);
        protocolFeeController.setProtocolFee(key, uint24(1000));
        assertEq(protocolFeeController.protocolFeeForPoolId(id), uint24(1000));
    }

    /// @notice Revoking authorization prevents subsequent calls
    function test_RevokeAuthorizationBlocksFutureCalls() public {
        address operator = address(0xcafe);

        // Grant then revoke
        protocolFeeController.setAuthorized(operator, true);
        protocolFeeController.setAuthorized(operator, false);
        assertFalse(protocolFeeController.authorized(operator));

        // Call should now revert
        vm.prank(operator);
        vm.expectRevert(CLDynamicFeeHookProtocolFeeController.Unauthorized.selector);
        protocolFeeController.setProtocolFee(key, uint24(1000));
    }

    /// @notice updateProtocolFee reverts when no controller is set
    function test_UpdateProtocolFeeRevertsIfControllerNotSet() public {
        // Deploy a fresh hook without configuring its controller
        CLDynamicFeeHook freshHook = new CLDynamicFeeHook(poolManager);

        vm.expectRevert(CLDynamicFeeHook.ProtocolFeeControllerNotSet.selector);
        freshHook.updateProtocolFee(key, uint24(1000));
    }

    /// @notice Only the hook owner can call updateProtocolFee
    function test_NonOwnerCannotCallUpdateProtocolFee() public {
        address nonOwner = address(0x1234);
        vm.prank(nonOwner);
        // OZ Ownable reverts with OwnableUnauthorizedAccount
        vm.expectRevert();
        hook.updateProtocolFee(key, uint24(1000));
    }
}
