// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @notice Minimal subset of UMA's OptimisticOracleV3 that this project uses.
/// @dev Declared locally rather than importing @uma/core, which pulls in a large
///      dependency tree. Verify against the deployed implementation before mainnet use.
interface IOptimisticOracleV3 {
    function defaultIdentifier() external view returns (bytes32);

    function defaultCurrency() external view returns (address);

    function getMinimumBond(address currency) external view returns (uint256);

    /// @param claim Human-readable statement that UMA voters will judge as true or false.
    /// @param asserter Address the bond is refunded to when the assertion settles truthfully.
    /// @param callbackRecipient Receives assertionResolvedCallback / assertionDisputedCallback.
    /// @param escalationManager Optional custom dispute policy. Pass address(0) for none.
    /// @param liveness Seconds the assertion sits undisputed before it can be settled.
    function assertTruth(
        bytes calldata claim,
        address asserter,
        address callbackRecipient,
        address escalationManager,
        uint64 liveness,
        IERC20 currency,
        uint256 bond,
        bytes32 identifier,
        bytes32 domainId
    ) external returns (bytes32 assertionId);

    function settleAssertion(bytes32 assertionId) external;

    function settleAndGetAssertionResult(bytes32 assertionId) external returns (bool);

    function getAssertionResult(bytes32 assertionId) external view returns (bool);
}

/// @notice Interface a callbackRecipient must implement to receive OOv3 settlement callbacks.
interface IOptimisticOracleV3Callbacks {
    function assertionResolvedCallback(bytes32 assertionId, bool assertedTruthfully) external;

    function assertionDisputedCallback(bytes32 assertionId) external;
}
