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
import {CLDirectionalSplitFeeHook} from "../../src/pool-cl/dynamic-fee/CLDirectionalSplitFeeHook.sol";
import {CLDynamicFeeHookProtocolFeeController} from
    "../../src/pool-cl/dynamic-fee/CLDynamicFeeHookProtocolFeeController.sol";

contract CLDirectionalSplitFeeHookTest is Test, Deployers, DeployPermit2 {
    using PoolIdLibrary for PoolKey;
    using CLPoolParametersHelper for bytes32;

    // ─── Infrastructure ──────────────────────────────────────────────────────────
    IVault vault;
    ICLPoolManager poolManager;
    IAllowanceTransfer permit2;
    MockCLPositionManager cpm;
    MockCLSwapRouter swapRouter;

    // ─── Contracts under test ────────────────────────────────────────────────────
    CLDirectionalSplitFeeHook hook;
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
        hook = new CLDirectionalSplitFeeHook(poolManager);

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

        // 11. Initialize pool (triggers afterInitialize → sets initial fees)
        poolManager.initialize(key, SQRT_RATIO_1_1);

        // 12. Add initial liquidity
        cpm.mint(key, -120, 120, 10e18, 1e18, 1e18, address(this), ZERO_BYTES);
    }

    // ─── Fee constant tests ──────────────────────────────────────────────────────

    /// @notice Verify fee constants maintain the 2:1 ratio
    function test_FeeConstantsRatio() public view {
        assertEq(hook.ZERO_FOR_ONE_LP_FEE(), hook.ZERO_FOR_ONE_PROTOCOL_FEE() * 2);
        assertEq(hook.ONE_FOR_ZERO_LP_FEE(), hook.ONE_FOR_ZERO_PROTOCOL_FEE() * 2);
    }

    /// @notice Verify total fees match expected values
    function test_TotalFees() public view {
        // zeroForOne: total ≈ 1.0% (9999)
        uint256 totalZeroForOne = hook.ZERO_FOR_ONE_LP_FEE() + hook.ZERO_FOR_ONE_PROTOCOL_FEE();
        assertEq(totalZeroForOne, 9999);
        
        // oneForZero: total = 1.2% (12000)
        uint256 totalOneForZero = hook.ONE_FOR_ZERO_LP_FEE() + hook.ONE_FOR_ZERO_PROTOCOL_FEE();
        assertEq(totalOneForZero, 12000);
    }

    // ─── Initialization tests ────────────────────────────────────────────────────

    /// @notice After initialization, fees should be set to initial values
    function test_InitialFeesAreSet() public view {
        assertEq(hook.currentLPFee(id), hook.INITIAL_LP_FEE());
        assertEq(hook.currentLPFee(id), 6666);
        
        uint24 protocolFee = protocolFeeController.protocolFeeForPoolId(id);
        uint24 expectedProtocolFee = hook.INITIAL_PROTOCOL_FEE() | (uint24(hook.INITIAL_PROTOCOL_FEE()) << 12);
        assertEq(protocolFee, expectedProtocolFee);
    }

    /// @notice Initial fees maintain 2:1 ratio
    function test_InitialFeesRatio() public view {
        uint24 lpFee = hook.currentLPFee(id);
        uint24 protocolFee = protocolFeeController.protocolFeeForPoolId(id);
        uint24 protocolFeePerDirection = uint24(protocolFee & 0xFFF); // lower 12 bits
        
        assertEq(lpFee, protocolFeePerDirection * 2);
    }

    // ─── Swap direction fee tests ────────────────────────────────────────────────

    /// @notice zeroForOne swap sets fees to zeroForOne values
    function test_ZeroForOneSwapSetsFees() public {
        swapRouter.exactInputSingle(
            ICLRouterBase.CLSwapExactInputSingleParams({
                poolKey: key,
                zeroForOne: true,
                amountIn: 0.5e18,
                amountOutMinimum: 0,
                hookData: ZERO_BYTES
            }),
            block.timestamp
        );

        assertEq(hook.currentLPFee(id), hook.ZERO_FOR_ONE_LP_FEE());
        assertEq(hook.currentLPFee(id), 6666);
        
        uint24 protocolFee = protocolFeeController.protocolFeeForPoolId(id);
        uint24 protocolFeePerDirection = uint24(protocolFee & 0xFFF);
        assertEq(protocolFeePerDirection, hook.ZERO_FOR_ONE_PROTOCOL_FEE());
        assertEq(protocolFeePerDirection, 3333);
    }

    /// @notice oneForZero swap sets fees to oneForZero values
    function test_OneForZeroSwapSetsFees() public {
        swapRouter.exactInputSingle(
            ICLRouterBase.CLSwapExactInputSingleParams({
                poolKey: key,
                zeroForOne: false,
                amountIn: 0.5e18,
                amountOutMinimum: 0,
                hookData: ZERO_BYTES
            }),
            block.timestamp
        );

        uint24 lpFee = hook.currentLPFee(id);
        uint24 protocolFee = hook.currentProtocolFee(id);
        uint24 protocolFeePerDirection = uint24(protocolFee & 0xFFF);
        
        assertEq(lpFee, hook.ONE_FOR_ZERO_LP_FEE(), "LP fee mismatch");
        assertEq(lpFee, 8000, "LP fee should be 8000");
        assertEq(protocolFeePerDirection, hook.ONE_FOR_ZERO_PROTOCOL_FEE(), "Protocol fee mismatch");
        assertEq(protocolFeePerDirection, 4000, "Protocol fee should be 4000");
    }

    /// @notice Fee ratio is maintained for zeroForOne swaps
    function test_ZeroForOneMaintainsRatio() public {
        swapRouter.exactInputSingle(
            ICLRouterBase.CLSwapExactInputSingleParams({
                poolKey: key,
                zeroForOne: true,
                amountIn: 0.5e18,
                amountOutMinimum: 0,
                hookData: ZERO_BYTES
            }),
            block.timestamp
        );

        uint24 lpFee = hook.currentLPFee(id);
        uint24 protocolFee = protocolFeeController.protocolFeeForPoolId(id);
        uint24 protocolFeePerDirection = uint24(protocolFee & 0xFFF);
        
        assertEq(lpFee, protocolFeePerDirection * 2);
    }

    /// @notice Fee ratio is maintained for oneForZero swaps
    function test_OneForZeroMaintainsRatio() public {
        swapRouter.exactInputSingle(
            ICLRouterBase.CLSwapExactInputSingleParams({
                poolKey: key,
                zeroForOne: false,
                amountIn: 0.5e18,
                amountOutMinimum: 0,
                hookData: ZERO_BYTES
            }),
            block.timestamp
        );

        uint24 lpFee = hook.currentLPFee(id);
        uint24 protocolFee = hook.currentProtocolFee(id);
        uint24 protocolFeePerDirection = uint24(protocolFee & 0xFFF);
        
        assertEq(lpFee, protocolFeePerDirection * 2);
    }

    // ─── Fee switching tests ─────────────────────────────────────────────────────

    /// @notice Fees change correctly when swap direction changes
    function test_FeesChangeWithDirection() public {
        // First swap: zeroForOne
        swapRouter.exactInputSingle(
            ICLRouterBase.CLSwapExactInputSingleParams({
                poolKey: key,
                zeroForOne: true,
                amountIn: 0.3e18,
                amountOutMinimum: 0,
                hookData: ZERO_BYTES
            }),
            block.timestamp
        );
        assertEq(hook.currentLPFee(id), 6666);

        // Second swap: oneForZero
        swapRouter.exactInputSingle(
            ICLRouterBase.CLSwapExactInputSingleParams({
                poolKey: key,
                zeroForOne: false,
                amountIn: 0.2e18,
                amountOutMinimum: 0,
                hookData: ZERO_BYTES
            }),
            block.timestamp
        );
        assertEq(hook.currentLPFee(id), 8000);

        // Third swap: back to zeroForOne
        swapRouter.exactInputSingle(
            ICLRouterBase.CLSwapExactInputSingleParams({
                poolKey: key,
                zeroForOne: true,
                amountIn: 0.2e18,
                amountOutMinimum: 0,
                hookData: ZERO_BYTES
            }),
            block.timestamp
        );
        assertEq(hook.currentLPFee(id), 6666);
    }

    /// @notice Ratio is maintained across direction changes
    function test_RatioMaintainedAcrossDirectionChanges() public {
        // zeroForOne swap
        swapRouter.exactInputSingle(
            ICLRouterBase.CLSwapExactInputSingleParams({
                poolKey: key,
                zeroForOne: true,
                amountIn: 0.3e18,
                amountOutMinimum: 0,
                hookData: ZERO_BYTES
            }),
            block.timestamp
        );
        
        uint24 lpFee1 = hook.currentLPFee(id);
        uint24 protocolFee1 = hook.currentProtocolFee(id) & 0xFFF;
        assertEq(lpFee1, protocolFee1 * 2);

        // oneForZero swap
        swapRouter.exactInputSingle(
            ICLRouterBase.CLSwapExactInputSingleParams({
                poolKey: key,
                zeroForOne: false,
                amountIn: 0.2e18,
                amountOutMinimum: 0,
                hookData: ZERO_BYTES
            }),
            block.timestamp
        );
        
        uint24 lpFee2 = hook.currentLPFee(id);
        uint24 protocolFee2 = hook.currentProtocolFee(id) & 0xFFF;
        assertEq(lpFee2, protocolFee2 * 2);
    }

    // ─── Large swap tests ────────────────────────────────────────────────────────

    /// @notice Large swaps maintain the same fee rules
    function test_LargeSwapsMaintainRatio() public {
        // Add more liquidity for large swap
        cpm.mint(key, -120, 120, 1000e18, 1000e18, 1000e18, address(this), ZERO_BYTES);

        swapRouter.exactInputSingle(
            ICLRouterBase.CLSwapExactInputSingleParams({
                poolKey: key,
                zeroForOne: false,
                amountIn: 50e18,
                amountOutMinimum: 0,
                hookData: ZERO_BYTES
            }),
            block.timestamp
        );

        uint24 lpFee = hook.currentLPFee(id);
        uint24 protocolFee = hook.currentProtocolFee(id);
        uint24 protocolFeePerDirection = uint24(protocolFee & 0xFFF);
        
        assertEq(lpFee, protocolFeePerDirection * 2);
        assertEq(lpFee, 8000);
        assertEq(protocolFeePerDirection, 4000);
    }

    // ─── Event tests ─────────────────────────────────────────────────────────────

    /// @notice LPFeeUpdated event is emitted when fee changes
    function test_LPFeeUpdatedEventEmitted() public {
        vm.expectEmit(true, false, false, true, address(hook));
        emit CLDirectionalSplitFeeHook.LPFeeUpdated(id, 8000);

        swapRouter.exactInputSingle(
            ICLRouterBase.CLSwapExactInputSingleParams({
                poolKey: key,
                zeroForOne: false,
                amountIn: 0.5e18,
                amountOutMinimum: 0,
                hookData: ZERO_BYTES
            }),
            block.timestamp
        );
    }

    /// @notice ProtocolFeeUpdated event is emitted when fee changes
    function test_ProtocolFeeUpdatedEventEmitted() public {
        uint24 expectedProtocolFee = hook.ONE_FOR_ZERO_PROTOCOL_FEE() | (uint24(hook.ONE_FOR_ZERO_PROTOCOL_FEE()) << 12);
        
        vm.expectEmit(true, false, false, true, address(hook));
        emit CLDirectionalSplitFeeHook.ProtocolFeeUpdated(id, expectedProtocolFee);

        swapRouter.exactInputSingle(
            ICLRouterBase.CLSwapExactInputSingleParams({
                poolKey: key,
                zeroForOne: false,
                amountIn: 0.5e18,
                amountOutMinimum: 0,
                hookData: ZERO_BYTES
            }),
            block.timestamp
        );
    }

    // ─── Access control tests ────────────────────────────────────────────────────

    /// @notice Hook initialization fails without protocol fee controller
    function test_InitializationFailsWithoutController() public {
        // Deploy a fresh hook without setting controller
        CLDirectionalSplitFeeHook freshHook = new CLDirectionalSplitFeeHook(poolManager);

        PoolKey memory freshKey = PoolKey({
            currency0: currency0,
            currency1: currency1,
            hooks: freshHook,
            poolManager: poolManager,
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            parameters: bytes32(uint256(freshHook.getHooksRegistrationBitmap())).setTickSpacing(60)
        });

        // The error will be wrapped by the pool manager, so we just expect a revert
        vm.expectRevert();
        poolManager.initialize(freshKey, SQRT_RATIO_1_1);
    }

    /// @notice Only owner can set protocol fee controller
    function test_OnlyOwnerCanSetController() public {
        CLDynamicFeeHookProtocolFeeController newController = 
            new CLDynamicFeeHookProtocolFeeController(address(poolManager));
        
        address nonOwner = address(0x1234);
        vm.prank(nonOwner);
        vm.expectRevert();
        hook.setProtocolFeeController(newController);
    }
}
