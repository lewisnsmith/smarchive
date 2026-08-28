// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test, console2} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {SuspensionMarket} from "../src/SuspensionMarket.sol";
import {IOptimisticOracleV3} from "../src/interfaces/IOptimisticOracleV3.sol";
import {Deploy} from "../script/Deploy.s.sol";
import {MockUSDC, MockOptimisticOracleV3} from "./mocks/Mocks.sol";

/// @notice Renders the production rules text into a real assertion claim. A malformed
///         rules string is the highest-consequence bug in this project, so it gets
///         eyeballed rather than only asserted on.
contract ClaimTest is Test, Deploy {
    function test_PrintProductionClaim() public {
        vm.warp(1_787_702_400);

        MockUSDC usdc = new MockUSDC();
        MockOptimisticOracleV3 oracle = new MockOptimisticOracleV3(IERC20(address(usdc)), 500e6);

        SuspensionMarket market = new SuspensionMarket(
            IERC20(address(usdc)),
            IOptimisticOracleV3(address(oracle)),
            1_789_331_100, // Packers Week 1 kickoff, 2026-09-13T20:25:00Z
            24 hours,
            1_791_923_100, // cutoff + 30 days
            TITLE,
            RULES
        );

        console2.log("================ CLAIM AS UMA VOTERS SEE IT ================");
        console2.log(market.claimPreview(false));
        console2.log("============================================================");

        string memory claim = market.claimPreview(false);
        assertTrue(bytes(claim).length > 1000, "rules text made it in");
        assertTrue(_has(claim, "Asserted resolution: NO"), "outcome stated");
        assertTrue(_has(claim, "Commissioner Exempt List"), "exempt list carve-out present");
        assertTrue(_has(claim, "1789331100"), "cutoff timestamp present");
        assertTrue(_has(claim, "Week 1 opener"), "game reference present");
        assertTrue(_has(claim, "does NOT move"), "reschedule clause present");
        assertTrue(_has(claim, "AMBIGUITY"), "ambiguity tiebreak present");
    }

    function _has(string memory haystack, string memory needle) internal pure returns (bool) {
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
