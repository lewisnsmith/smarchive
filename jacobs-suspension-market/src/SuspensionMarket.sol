// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";

import {OutcomeToken} from "./OutcomeToken.sol";
import {IOptimisticOracleV3, IOptimisticOracleV3Callbacks} from "./interfaces/IOptimisticOracleV3.sol";

/// @title SuspensionMarket
/// @notice Binary prediction market on whether a named player is suspended before a
///         fixed deadline, resolved by UMA's Optimistic Oracle V3.
///
/// Collateral model: 1 unit of collateral mints 1 YES + 1 NO ("a complete set").
/// Exactly one side redeems for 1 unit after resolution, so the contract is always
/// fully backed and the two sides must price to roughly 1 unit combined.
///
/// Resolution model, and why it is shaped this way:
///
///   - YES requires an affirmative public announcement, so YES is knowable early.
///     It may be asserted the moment discipline is announced, before the deadline.
///   - NO is the absence of an announcement, which is only knowable once the
///     deadline has passed. NO cannot be asserted early.
///   - If nobody asserts anything at all, the market falls back to NO. Absence of
///     an announcement *is* the NO outcome, so this is both the correct default and
///     removes any incentive for a losing YES holder to stall for a 50/50 void.
///   - A successful dispute does NOT flip the outcome. It only voids that assertion
///     and reopens the window. An assertion can be voted false for reasons unrelated
///     to the underlying fact (a typo, an ambiguous date, wrong scope), and auto-
///     flipping would turn a drafting error into a misresolution.
contract SuspensionMarket is IOptimisticOracleV3Callbacks {
    using SafeERC20 for IERC20;

    enum Status {
        Trading, // no live assertion; split/merge open
        Pending, // assertion in flight at the oracle
        ResolvedYes,
        ResolvedNo
    }

    /// @notice Window after a rejected assertion during which the NO fallback is
    ///         blocked, so an honest asserter can re-file without being front-run
    ///         by the fallback.
    uint64 public constant REASSERT_GRACE = 3 days;

    IERC20 public immutable collateral;
    IOptimisticOracleV3 public immutable oracle;
    OutcomeToken public immutable yesToken;
    OutcomeToken public immutable noToken;

    /// @notice Cutoff the question is asked against ("by the first NFL game").
    uint64 public immutable eventDeadline;
    /// @notice Seconds an assertion sits undisputed before it can settle.
    uint64 public immutable assertionLiveness;
    /// @notice After this, if nothing is pending, anyone can settle the market to NO.
    uint64 public immutable fallbackDeadline;

    bytes32 public immutable priceIdentifier;

    /// @notice Full resolution criteria. Immutable, and embedded verbatim into every
    ///         assertion so UMA voters judge the same text traders read.
    string public rules;
    string public title;

    Status public status;
    bytes32 public liveAssertionId;
    bool public assertedOutcome;
    uint64 public lastRejectionAt;

    /// @notice Collateral owed to complete-set holders. Tracked explicitly so oracle
    ///         bond flows can never be mistaken for trader collateral.
    uint256 public backing;

    event Split(address indexed who, uint256 amount);
    event Merged(address indexed who, uint256 amount);
    event ResolutionAsserted(
        bytes32 indexed assertionId, address indexed asserter, bool assertedYes, uint256 bond
    );
    event AssertionDisputed(bytes32 indexed assertionId);
    event AssertionRejected(bytes32 indexed assertionId);
    event MarketResolved(Status status, bytes32 assertionId);
    event Redeemed(address indexed who, uint256 payout);

    error BadWindow();
    error MarketClosed();
    error NotTrading();
    error ZeroAmount();
    error TooEarlyForNo();
    error NotOracle();
    error UnknownAssertion();
    error Unresolved();
    error NothingToRedeem();
    error FallbackNotReached();
    error ReassertGraceActive();

    constructor(
        IERC20 collateral_,
        IOptimisticOracleV3 oracle_,
        uint64 eventDeadline_,
        uint64 assertionLiveness_,
        uint64 fallbackDeadline_,
        string memory title_,
        string memory rules_
    ) {
        // The fallback must not be reachable before an honest asserter could have
        // filed and settled a NO assertion.
        if (
            eventDeadline_ <= block.timestamp
                || fallbackDeadline_ <= uint256(eventDeadline_) + uint256(assertionLiveness_)
        ) revert BadWindow();

        collateral = collateral_;
        oracle = oracle_;
        eventDeadline = eventDeadline_;
        assertionLiveness = assertionLiveness_;
        fallbackDeadline = fallbackDeadline_;
        title = title_;
        rules = rules_;
        priceIdentifier = oracle_.defaultIdentifier();

        uint8 dec = IERC20Metadata(address(collateral_)).decimals();
        yesToken = new OutcomeToken("Jacobs Suspended YES", "JJSUSP-YES", dec);
        noToken = new OutcomeToken("Jacobs Suspended NO", "JJSUSP-NO", dec);
    }

    // ---------------------------------------------------------------- trading

    /// @notice Deposit collateral, receive equal amounts of YES and NO.
    function split(uint256 amount) external {
        if (status != Status.Trading && status != Status.Pending) revert MarketClosed();
        if (amount == 0) revert ZeroAmount();

        collateral.safeTransferFrom(msg.sender, address(this), amount);
        backing += amount;
        yesToken.mint(msg.sender, amount);
        noToken.mint(msg.sender, amount);

        emit Split(msg.sender, amount);
    }

    /// @notice Burn equal amounts of YES and NO, recover collateral. This is the
    ///         arbitrage path that keeps YES + NO priced near 1.
    function merge(uint256 amount) external {
        if (status != Status.Trading && status != Status.Pending) revert MarketClosed();
        if (amount == 0) revert ZeroAmount();

        yesToken.burn(msg.sender, amount);
        noToken.burn(msg.sender, amount);
        backing -= amount;
        collateral.safeTransfer(msg.sender, amount);

        emit Merged(msg.sender, amount);
    }

    /// @notice Burn winning shares for collateral, 1:1.
    function redeem() external returns (uint256 payout) {
        if (status != Status.ResolvedYes && status != Status.ResolvedNo) revert Unresolved();

        OutcomeToken winner = status == Status.ResolvedYes ? yesToken : noToken;
        payout = winner.balanceOf(msg.sender);
        if (payout == 0) revert NothingToRedeem();

        winner.burn(msg.sender, payout);
        backing -= payout;
        collateral.safeTransfer(msg.sender, payout);

        emit Redeemed(msg.sender, payout);
    }

    // -------------------------------------------------------------- resolution

    /// @notice Assert the market's resolution to UMA, posting the oracle bond.
    /// @dev The bond is pulled from the caller and refunded directly to the caller by
    ///      UMA on truthful settlement, so the market never custodies it. If the
    ///      assertion is successfully disputed, the caller loses the bond to the disputer.
    /// @param assertYes True to assert "suspended", false to assert "not suspended".
    function assertResolution(bool assertYes) external returns (bytes32 assertionId) {
        if (status != Status.Trading) revert NotTrading();
        // NO is a statement about the whole window, so it cannot be known early.
        // YES is a statement about an announcement that has already happened.
        if (!assertYes && block.timestamp < eventDeadline) revert TooEarlyForNo();

        IERC20 bondCurrency = IERC20(oracle.defaultCurrency());
        uint256 bond = oracle.getMinimumBond(address(bondCurrency));

        bondCurrency.safeTransferFrom(msg.sender, address(this), bond);
        bondCurrency.forceApprove(address(oracle), bond);

        assertionId = oracle.assertTruth(
            _claim(assertYes),
            msg.sender, // bond refund recipient
            address(this), // callback recipient
            address(0), // no escalation manager
            assertionLiveness,
            bondCurrency,
            bond,
            priceIdentifier,
            bytes32(0) // no domain
        );

        status = Status.Pending;
        liveAssertionId = assertionId;
        assertedOutcome = assertYes;

        emit ResolutionAsserted(assertionId, msg.sender, assertYes, bond);
    }

    /// @notice UMA callback once an assertion settles, either by expiring undisputed
    ///         or by a DVM vote.
    function assertionResolvedCallback(bytes32 assertionId, bool assertedTruthfully) external {
        if (msg.sender != address(oracle)) revert NotOracle();
        if (status != Status.Pending || assertionId != liveAssertionId) revert UnknownAssertion();

        if (assertedTruthfully) {
            status = assertedOutcome ? Status.ResolvedYes : Status.ResolvedNo;
            emit MarketResolved(status, assertionId);
        } else {
            status = Status.Trading;
            liveAssertionId = bytes32(0);
            lastRejectionAt = uint64(block.timestamp);
            emit AssertionRejected(assertionId);
        }
    }

    /// @notice UMA callback when someone disputes. Informational only: the outcome
    ///         still arrives later via assertionResolvedCallback after the DVM votes.
    function assertionDisputedCallback(bytes32 assertionId) external {
        if (msg.sender != address(oracle)) revert NotOracle();
        emit AssertionDisputed(assertionId);
    }

    /// @notice Settle to NO if nobody ever asserted. Permissionless.
    function settleFallbackNo() external {
        if (status != Status.Trading) revert NotTrading();
        if (block.timestamp <= fallbackDeadline) revert FallbackNotReached();
        if (lastRejectionAt != 0 && block.timestamp <= uint256(lastRejectionAt) + REASSERT_GRACE) {
            revert ReassertGraceActive();
        }

        status = Status.ResolvedNo;
        emit MarketResolved(Status.ResolvedNo, bytes32(0));
    }

    // ------------------------------------------------------------------- views

    /// @notice The exact bond `assertResolution` will pull, read live from the oracle.
    function currentBond() external view returns (address currency, uint256 amount) {
        currency = oracle.defaultCurrency();
        amount = oracle.getMinimumBond(currency);
    }

    /// @notice Preview the claim string UMA voters will see.
    function claimPreview(bool assertYes) external view returns (string memory) {
        return string(_claim(assertYes));
    }

    /// @dev Split into parts to keep the legacy codegen pipeline off a stack-too-deep path.
    function _claim(bool assertYes) internal view returns (bytes memory) {
        return bytes.concat(_claimHeader(), _claimOutcome(assertYes), _claimCriteria());
    }

    function _claimHeader() private view returns (bytes memory) {
        return abi.encodePacked(
            "Prediction market resolution assertion.\n\n",
            "Market: ",
            title,
            "\n",
            "Contract: ",
            Strings.toHexString(address(this)),
            "\n",
            "Chain ID: ",
            Strings.toString(block.chainid),
            "\n"
        );
    }

    function _claimOutcome(bool assertYes) private view returns (bytes memory) {
        return abi.encodePacked(
            "Asserted resolution: ",
            assertYes ? "YES" : "NO",
            "\n",
            "Resolution cutoff (unix): ",
            Strings.toString(eventDeadline),
            "\n",
            "Asserted at (unix): ",
            Strings.toString(block.timestamp),
            "\n\n"
        );
    }

    function _claimCriteria() private view returns (bytes memory) {
        return abi.encodePacked(
            "The asserter claims that the criteria below, applied to public information, ",
            "produce the asserted resolution above.\n\n",
            "--- RESOLUTION CRITERIA ---\n",
            rules
        );
    }
}
