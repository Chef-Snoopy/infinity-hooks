// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import {Ownable} from "openzeppelin-contracts/contracts/access/Ownable.sol";
import {IProtocolFeeController} from "infinity-core/src/interfaces/IProtocolFeeController.sol";
import {IProtocolFees} from "infinity-core/src/interfaces/IProtocolFees.sol";
import {PoolKey} from "infinity-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "infinity-core/src/types/PoolId.sol";

/// @title CLDynamicFeeHookProtocolFeeController
/// @notice A ProtocolFeeController that allows the owner to grant/revoke permission
///         to other addresses (e.g. the CLDynamicFeeHook) to call setProtocolFee.
contract CLDynamicFeeHookProtocolFeeController is IProtocolFeeController, Ownable {
    using PoolIdLibrary for PoolKey;

    /// @notice The CL pool manager this controller manages fees for
    address public immutable clPoolManager;

    /// @notice Addresses authorized to call setProtocolFee
    mapping(address => bool) public authorized;

    /// @notice Per-pool protocol fee overrides (stored locally for view queries)
    mapping(PoolId => uint24) public protocolFeeForPoolId;

    event AuthorizationUpdated(address indexed account, bool isAuthorized);
    event ProtocolFeeSet(PoolId indexed poolId, uint24 newProtocolFee);

    error Unauthorized();
    error InvalidPoolManager();

    constructor(address _clPoolManager) Ownable(msg.sender) {
        clPoolManager = _clPoolManager;
    }

    /// @dev Allows owner OR any address that has been granted authorization
    modifier onlyAuthorized() {
        if (!authorized[msg.sender] && msg.sender != owner()) revert Unauthorized();
        _;
    }

    /// @notice Grant or revoke permission for an address to call setProtocolFee
    /// @param account The address to update authorization for
    /// @param isAuthorized True to grant, false to revoke
    function setAuthorized(address account, bool isAuthorized) external onlyOwner {
        authorized[account] = isAuthorized;
        emit AuthorizationUpdated(account, isAuthorized);
    }

    /// @notice Set the protocol fee for a specific pool.
    ///         Can be called by the owner or any authorized address (e.g. the hook).
    /// @param key The pool key identifying the pool
    /// @param newProtocolFee Encoded protocol fee: lower 12 bits = 0→1 fee, upper 12 bits = 1→0 fee.
    ///        Each direction is in hundredths of a bip, max 4000 (0.4%).
    ///        Example: 1000 | (1000 << 12) sets 0.1% in both directions.
    function setProtocolFee(PoolKey memory key, uint24 newProtocolFee) external onlyAuthorized {
        if (address(key.poolManager) != clPoolManager) revert InvalidPoolManager();

        PoolId poolId = key.toId();
        protocolFeeForPoolId[poolId] = newProtocolFee;

        // Forward to pool manager — succeeds because this contract IS the protocolFeeController
        IProtocolFees(clPoolManager).setProtocolFee(key, newProtocolFee);

        emit ProtocolFeeSet(poolId, newProtocolFee);
    }

    /// @inheritdoc IProtocolFeeController
    /// @notice Returns the stored protocol fee for the given pool (0 if not set)
    function protocolFeeForPool(PoolKey memory key) external view override returns (uint24 protocolFee) {
        return protocolFeeForPoolId[key.toId()];
    }
}
