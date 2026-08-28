// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {
    IOptimisticOracleV3,
    IOptimisticOracleV3Callbacks
} from "../../src/interfaces/IOptimisticOracleV3.sol";

contract MockUSDC is ERC20 {
    constructor() ERC20("USD Coin", "USDC") {}

    function decimals() public pure override returns (uint8) {
        return 6;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

/// @notice Stand-in for UMA's OptimisticOracleV3 with manual settlement, so tests can
///         drive the undisputed, disputed-and-upheld, and disputed-and-overturned paths.
contract MockOptimisticOracleV3 is IOptimisticOracleV3 {
    struct Assertion {
        address asserter;
        address callbackRecipient;
        IERC20 currency;
        uint256 bond;
        bool settled;
        bool result;
        bytes claim;
    }

    IERC20 public immutable bondCurrency;
    uint256 public minimumBond;
    uint256 private nonce;

    mapping(bytes32 => Assertion) public assertions;

    constructor(IERC20 bondCurrency_, uint256 minimumBond_) {
        bondCurrency = bondCurrency_;
        minimumBond = minimumBond_;
    }

    function setMinimumBond(uint256 v) external {
        minimumBond = v;
    }

    function defaultIdentifier() external pure returns (bytes32) {
        return bytes32("ASSERT_TRUTH");
    }

    function defaultCurrency() external view returns (address) {
        return address(bondCurrency);
    }

    function getMinimumBond(address) external view returns (uint256) {
        return minimumBond;
    }

    function assertTruth(
        bytes calldata claim,
        address asserter,
        address callbackRecipient,
        address,
        uint64,
        IERC20 currency,
        uint256 bond,
        bytes32,
        bytes32
    ) external returns (bytes32 assertionId) {
        currency.transferFrom(msg.sender, address(this), bond);
        assertionId = keccak256(abi.encode(address(this), ++nonce));
        assertions[assertionId] = Assertion({
            asserter: asserter,
            callbackRecipient: callbackRecipient,
            currency: currency,
            bond: bond,
            settled: false,
            result: false,
            claim: claim
        });
    }

    /// @notice Test hook. `truthfully = false` models a dispute the asserter lost;
    ///         the bond goes to `bondWinner` the way UMA pays the disputer.
    function settleAs(bytes32 assertionId, bool truthfully, address bondWinner) external {
        Assertion storage a = assertions[assertionId];
        require(a.callbackRecipient != address(0), "no assertion");
        require(!a.settled, "settled");
        a.settled = true;
        a.result = truthfully;

        a.currency.transfer(truthfully ? a.asserter : bondWinner, a.bond);
        IOptimisticOracleV3Callbacks(a.callbackRecipient).assertionResolvedCallback(assertionId, truthfully);
    }

    function fireDisputeCallback(bytes32 assertionId) external {
        IOptimisticOracleV3Callbacks(assertions[assertionId].callbackRecipient)
            .assertionDisputedCallback(assertionId);
    }

    function claimOf(bytes32 assertionId) external view returns (string memory) {
        return string(assertions[assertionId].claim);
    }

    function settleAssertion(bytes32) external pure {
        revert("use settleAs");
    }

    function settleAndGetAssertionResult(bytes32 assertionId) external view returns (bool) {
        return assertions[assertionId].result;
    }

    function getAssertionResult(bytes32 assertionId) external view returns (bool) {
        require(assertions[assertionId].settled, "not settled");
        return assertions[assertionId].result;
    }
}
