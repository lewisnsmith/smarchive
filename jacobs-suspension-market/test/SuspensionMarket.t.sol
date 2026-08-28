// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test, console2} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {SuspensionMarket} from "../src/SuspensionMarket.sol";
import {OutcomeToken} from "../src/OutcomeToken.sol";
import {IOptimisticOracleV3} from "../src/interfaces/IOptimisticOracleV3.sol";
import {MockUSDC, MockOptimisticOracleV3} from "./mocks/Mocks.sol";

contract SuspensionMarketTest is Test {
    uint256 constant START = 1_787_702_400; // ~2026-08-26 UTC
    uint256 constant BOND = 500e6;
    uint64 constant LIVENESS = 24 hours;

    MockUSDC usdc;
    MockOptimisticOracleV3 oracle;
    SuspensionMarket market;
    OutcomeToken yes;
    OutcomeToken no;

    uint64 eventDeadline;
    uint64 fallbackDeadline;

    address lewis = makeAddr("lewis"); // believes YES
    address taker = makeAddr("taker"); // takes the NO side
    address asserter = makeAddr("asserter");
    address disputer = makeAddr("disputer");

    function setUp() public {
        vm.warp(START);

        usdc = new MockUSDC();
        oracle = new MockOptimisticOracleV3(IERC20(address(usdc)), BOND);

        eventDeadline = uint64(START + 14 days);
        fallbackDeadline = uint64(START + 44 days);

        market = new SuspensionMarket(
            IERC20(address(usdc)),
            IOptimisticOracleV3(address(oracle)),
            eventDeadline,
            LIVENESS,
            fallbackDeadline,
            "Will Josh Jacobs be suspended by the first NFL game?",
            "RESOLVES YES if the NFL announces a suspension before the cutoff. Exempt list does not count."
        );

        yes = market.yesToken();
        no = market.noToken();

        usdc.mint(lewis, 250e6);
        usdc.mint(taker, 1000e6);
        usdc.mint(asserter, BOND);
        usdc.mint(disputer, BOND);
    }

    // ------------------------------------------------------------ collateral

    function test_SplitMintsBothSidesAndMergeUnwinds() public {
        vm.startPrank(lewis);
        usdc.approve(address(market), 250e6);
        market.split(250e6);

        assertEq(yes.balanceOf(lewis), 250e6, "yes minted");
        assertEq(no.balanceOf(lewis), 250e6, "no minted");
        assertEq(usdc.balanceOf(lewis), 0, "collateral taken");
        assertEq(market.backing(), 250e6, "backing tracked");

        market.merge(100e6);
        assertEq(yes.balanceOf(lewis), 150e6);
        assertEq(no.balanceOf(lewis), 150e6);
        assertEq(usdc.balanceOf(lewis), 100e6, "collateral returned");
        assertEq(market.backing(), 150e6);
        vm.stopPrank();
    }

    function test_OutcomeTokensMatchCollateralDecimals() public view {
        assertEq(yes.decimals(), 6);
        assertEq(no.decimals(), 6);
    }

    function test_OnlyMarketCanMint() public {
        vm.prank(lewis);
        vm.expectRevert(OutcomeToken.OnlyMarket.selector);
        yes.mint(lewis, 1e6);
    }

    function test_BackingAlwaysCoversOutstandingShares() public {
        _split(lewis, 250e6);
        _split(taker, 400e6);

        assertEq(yes.totalSupply(), no.totalSupply(), "sides balanced");
        assertEq(market.backing(), yes.totalSupply(), "fully backed");
        assertGe(usdc.balanceOf(address(market)), market.backing(), "solvent");
    }

    // ------------------------------------------------------------- assertion

    function test_CannotAssertNoBeforeDeadline() public {
        vm.startPrank(asserter);
        usdc.approve(address(market), BOND);
        vm.expectRevert(SuspensionMarket.TooEarlyForNo.selector);
        market.assertResolution(false);
        vm.stopPrank();
    }

    /// YES is knowable the moment discipline is announced, so it can settle early.
    function test_CanAssertYesBeforeDeadline() public {
        _split(lewis, 250e6);

        vm.startPrank(asserter);
        usdc.approve(address(market), BOND);
        bytes32 id = market.assertResolution(true);
        vm.stopPrank();

        assertEq(uint8(market.status()), uint8(SuspensionMarket.Status.Pending));
        assertEq(market.liveAssertionId(), id);
        assertTrue(market.assertedOutcome());
    }

    function test_UndisputedYesResolvesYesAndRefundsBond() public {
        _split(lewis, 250e6);

        vm.startPrank(asserter);
        usdc.approve(address(market), BOND);
        bytes32 id = market.assertResolution(true);
        vm.stopPrank();

        assertEq(usdc.balanceOf(asserter), 0, "bond posted");

        vm.warp(block.timestamp + LIVENESS + 1);
        oracle.settleAs(id, true, address(0));

        assertEq(uint8(market.status()), uint8(SuspensionMarket.Status.ResolvedYes));
        assertEq(usdc.balanceOf(asserter), BOND, "bond refunded by UMA, not the market");
    }

    function test_UndisputedNoResolvesNo() public {
        _split(lewis, 250e6);

        vm.warp(eventDeadline + 1);
        vm.startPrank(asserter);
        usdc.approve(address(market), BOND);
        bytes32 id = market.assertResolution(false);
        vm.stopPrank();

        vm.warp(block.timestamp + LIVENESS + 1);
        oracle.settleAs(id, true, address(0));

        assertEq(uint8(market.status()), uint8(SuspensionMarket.Status.ResolvedNo));
    }

    function test_ClaimEmbedsRulesAndCutoff() public view {
        string memory claim = market.claimPreview(true);
        assertTrue(_contains(claim, "Asserted resolution: YES"), "states outcome");
        assertTrue(_contains(claim, "Exempt list does not count"), "embeds rules verbatim");
        assertTrue(_contains(claim, vm.toString(uint256(eventDeadline))), "states cutoff");
    }

    // ----------------------------------------------------- dispute semantics

    /// A won dispute voids the assertion. It must NOT flip the market, because an
    /// assertion can be voted false over drafting defects rather than the fact itself.
    function test_RejectedAssertionReopensTradingWithoutFlipping() public {
        _split(lewis, 250e6);

        vm.startPrank(asserter);
        usdc.approve(address(market), BOND);
        bytes32 id = market.assertResolution(true);
        vm.stopPrank();

        oracle.fireDisputeCallback(id);
        oracle.settleAs(id, false, disputer);

        assertEq(uint8(market.status()), uint8(SuspensionMarket.Status.Trading), "reopened, not flipped");
        assertEq(market.liveAssertionId(), bytes32(0));
        assertEq(market.lastRejectionAt(), block.timestamp);
        assertEq(usdc.balanceOf(disputer), BOND * 2, "disputer took the losing bond");
    }

    function test_RejectedAssertionCanBeReassertedAndSettle() public {
        _split(lewis, 250e6);

        vm.startPrank(asserter);
        usdc.approve(address(market), BOND * 2);
        bytes32 first = market.assertResolution(true);
        vm.stopPrank();

        oracle.settleAs(first, false, disputer);

        vm.warp(eventDeadline + 1);
        usdc.mint(asserter, BOND);
        vm.startPrank(asserter);
        bytes32 second = market.assertResolution(false);
        vm.stopPrank();

        vm.warp(block.timestamp + LIVENESS + 1);
        oracle.settleAs(second, true, address(0));

        assertEq(uint8(market.status()), uint8(SuspensionMarket.Status.ResolvedNo));
    }

    function test_OnlyOracleCanFireCallbacks() public {
        _split(lewis, 250e6);

        vm.startPrank(asserter);
        usdc.approve(address(market), BOND);
        bytes32 id = market.assertResolution(true);
        vm.stopPrank();

        vm.prank(lewis);
        vm.expectRevert(SuspensionMarket.NotOracle.selector);
        market.assertionResolvedCallback(id, true);

        vm.prank(lewis);
        vm.expectRevert(SuspensionMarket.NotOracle.selector);
        market.assertionDisputedCallback(id);
    }

    function test_UnknownAssertionIdRejected() public {
        _split(lewis, 250e6);

        vm.startPrank(asserter);
        usdc.approve(address(market), BOND);
        market.assertResolution(true);
        vm.stopPrank();

        vm.prank(address(oracle));
        vm.expectRevert(SuspensionMarket.UnknownAssertion.selector);
        market.assertionResolvedCallback(keccak256("bogus"), true);
    }

    // -------------------------------------------------------------- fallback

    function test_FallbackResolvesNoWhenNobodyAsserts() public {
        _split(lewis, 250e6);

        vm.warp(fallbackDeadline + 1);
        market.settleFallbackNo();

        assertEq(uint8(market.status()), uint8(SuspensionMarket.Status.ResolvedNo));
    }

    function test_FallbackBlockedBeforeDeadline() public {
        _split(lewis, 250e6);

        vm.warp(fallbackDeadline);
        vm.expectRevert(SuspensionMarket.FallbackNotReached.selector);
        market.settleFallbackNo();
    }

    function test_FallbackBlockedWhileAssertionPending() public {
        _split(lewis, 250e6);

        vm.startPrank(asserter);
        usdc.approve(address(market), BOND);
        market.assertResolution(true);
        vm.stopPrank();

        vm.warp(fallbackDeadline + 1);
        vm.expectRevert(SuspensionMarket.NotTrading.selector);
        market.settleFallbackNo();
    }

    /// Without this grace window, a disputer could kill an honest YES assertion filed
    /// near the fallback deadline and then immediately settle the market to NO.
    function test_FallbackBlockedDuringReassertGrace() public {
        _split(lewis, 250e6);

        vm.warp(fallbackDeadline - 1 hours);
        vm.startPrank(asserter);
        usdc.approve(address(market), BOND);
        bytes32 id = market.assertResolution(true);
        vm.stopPrank();

        vm.warp(fallbackDeadline + 1);
        oracle.settleAs(id, false, disputer);

        vm.expectRevert(SuspensionMarket.ReassertGraceActive.selector);
        market.settleFallbackNo();

        vm.warp(block.timestamp + market.REASSERT_GRACE() + 1);
        market.settleFallbackNo();
        assertEq(uint8(market.status()), uint8(SuspensionMarket.Status.ResolvedNo));
    }

    // ---------------------------------------------------------------- redeem

    function test_RedeemLosingSideReverts() public {
        _split(lewis, 250e6);

        vm.warp(fallbackDeadline + 1);
        market.settleFallbackNo();

        vm.prank(taker);
        vm.expectRevert(SuspensionMarket.NothingToRedeem.selector);
        market.redeem();
    }

    function test_CannotSplitAfterResolution() public {
        vm.warp(fallbackDeadline + 1);
        market.settleFallbackNo();

        vm.startPrank(lewis);
        usdc.approve(address(market), 10e6);
        vm.expectRevert(SuspensionMarket.MarketClosed.selector);
        market.split(10e6);
        vm.stopPrank();
    }

    // ------------------------------------------------------------- economics

    /// The capital-efficiency claim, end to end: mint complete sets, sell the side you
    /// do not want, and your net outlay collapses to the price of the side you keep.
    function test_MintAndSellGivesLeveredYesExposure() public {
        uint256 startingCapital = usdc.balanceOf(lewis);
        assertEq(startingCapital, 250e6);

        _split(lewis, 250e6);

        // OTC: sell 250 NO to taker at $0.80 each.
        vm.prank(lewis);
        no.transfer(taker, 250e6);
        vm.prank(taker);
        usdc.transfer(lewis, 200e6);

        uint256 netOutlay = startingCapital - usdc.balanceOf(lewis);
        assertEq(netOutlay, 50e6, "250 YES shares acquired for a net $50");
        assertEq(yes.balanceOf(lewis), 250e6);

        // Suspension announced and asserted.
        vm.startPrank(asserter);
        usdc.approve(address(market), BOND);
        bytes32 id = market.assertResolution(true);
        vm.stopPrank();
        vm.warp(block.timestamp + LIVENESS + 1);
        oracle.settleAs(id, true, address(0));

        vm.prank(lewis);
        uint256 payout = market.redeem();

        assertEq(payout, 250e6);
        assertEq(usdc.balanceOf(lewis), 450e6, "$50 at risk returned $250");

        console2.log("net outlay (usdc 6dp)", netOutlay);
        console2.log("payout     (usdc 6dp)", payout);
    }

    /// The mirror case: the whole downside is the net outlay, nothing more.
    function test_DownsideCappedAtNetOutlay() public {
        uint256 startingCapital = usdc.balanceOf(lewis);
        _split(lewis, 250e6);

        vm.prank(lewis);
        no.transfer(taker, 250e6);
        vm.prank(taker);
        usdc.transfer(lewis, 200e6);

        vm.warp(fallbackDeadline + 1);
        market.settleFallbackNo();

        vm.prank(lewis);
        vm.expectRevert(SuspensionMarket.NothingToRedeem.selector);
        market.redeem();

        assertEq(startingCapital - usdc.balanceOf(lewis), 50e6, "loss capped at net outlay");

        vm.prank(taker);
        uint256 takerPayout = market.redeem();
        assertEq(takerPayout, 250e6, "winning side fully paid");
    }

    // --------------------------------------------------------------- helpers

    function _split(address who, uint256 amount) internal {
        if (usdc.balanceOf(who) < amount) usdc.mint(who, amount - usdc.balanceOf(who));
        vm.startPrank(who);
        usdc.approve(address(market), amount);
        market.split(amount);
        vm.stopPrank();
    }

    function _contains(string memory haystack, string memory needle) internal pure returns (bool) {
        bytes memory h = bytes(haystack);
        bytes memory n = bytes(needle);
        if (n.length == 0 || n.length > h.length) return false;
        for (uint256 i = 0; i <= h.length - n.length; i++) {
            bool ok = true;
            for (uint256 j = 0; j < n.length; j++) {
                if (h[i + j] != n[j]) {
                    ok = false;
                    break;
                }
            }
            if (ok) return true;
        }
        return false;
    }
}
