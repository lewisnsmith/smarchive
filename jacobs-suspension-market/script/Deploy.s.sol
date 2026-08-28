// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {SuspensionMarket} from "../src/SuspensionMarket.sol";
import {IOptimisticOracleV3} from "../src/interfaces/IOptimisticOracleV3.sol";

contract Deploy is Script {
    string constant TITLE =
        "Will Josh Jacobs be suspended by the NFL before the Packers' Week 1 kickoff (2026-09-13)?";

    /// @dev This text is embedded verbatim into every UMA assertion. It is the single
    ///      most important artifact in the project: UMA voters judge this, not intent.
    string constant RULES = "QUESTION\n"
        "Will Josh Jacobs (NFL running back, Green Bay Packers) be suspended by the National\n"
        "Football League before the resolution cutoff timestamp stated in this assertion?\n" "\n"
        "The cutoff corresponds to the scheduled kickoff of the Packers' 2026 Week 1 opener,\n"
        "at the Minnesota Vikings, Sunday 13 September 2026, 3:25 p.m. CT / 20:25 UTC.\n" "\n"
        "RESOLVES YES\n"
        "If, at any time strictly before the resolution cutoff, the NFL publicly announces a\n"
        "suspension of Josh Jacobs of any length, under either the NFL Personal Conduct Policy\n"
        "or the NFL Policy and Program on Substances of Abuse or Performance Enhancing Substances.\n" "\n"
        "RESOLVES NO\n" "In every other case, including if no such announcement occurs before the cutoff.\n"
        "\n" "INITIAL ANNOUNCEMENT GOVERNS\n"
        "Resolution is fixed by the initial announced discipline. A later reduction, vacatur,\n"
        "settlement, or reversal on appeal does not change the resolution. A suspension announced\n"
        "before the cutoff but scheduled to be served after the cutoff still resolves YES.\n" "\n"
        "THE FOLLOWING DO NOT COUNT AS A SUSPENSION\n" "1. Placement on the Commissioner Exempt List.\n"
        "2. Paid or unpaid administrative leave of any kind.\n"
        "3. A fine, or any discipline that does not include a suspension.\n"
        "4. A suspension imposed by the Green Bay Packers or any other club rather than by the NFL.\n"
        "5. Any absence attributable to injury, illness, holdout, retirement, release, trade,\n"
        "   or any other roster transaction.\n"
        "6. Arrest, criminal charges, indictment, plea, or conviction, absent an NFL suspension\n"
        "   announcement.\n" "\n" "SOURCE OF TRUTH, IN PRIORITY ORDER\n"
        "1. An official public statement from the NFL or the NFLPA.\n"
        "2. Failing that, concurring reports from at least two of: ESPN, NFL Network,\n"
        "   The Athletic, Associated Press, Reuters.\n" "\n" "TIME\n"
        "All times are UTC. The resolution cutoff is the unix timestamp stated in this assertion.\n"
        "That timestamp is authoritative and overrides any prose description of a game date.\n"
        "If the NFL reschedules, moves, or cancels the Packers' Week 1 game for any reason, the\n"
        "cutoff timestamp does NOT move. It remains the fixed timestamp stated in this assertion.\n" "\n"
        "AMBIGUITY\n"
        "If the NFL announces discipline whose character cannot be clearly determined from the\n"
        "sources above, resolve NO. YES requires an affirmative, clearly reported suspension.\n";

    function run() external returns (SuspensionMarket market) {
        address collateral = vm.envAddress("COLLATERAL");
        address oracle = vm.envAddress("OOV3");
        uint64 eventDeadline = uint64(vm.envUint("RESOLUTION_TIMESTAMP"));
        uint64 liveness = uint64(vm.envOr("ASSERTION_LIVENESS", uint256(24 hours)));
        uint64 fallbackDeadline =
            uint64(vm.envOr("FALLBACK_DEADLINE", uint256(eventDeadline) + uint256(30 days)));

        console2.log("collateral        ", collateral);
        console2.log("oracle (OOv3)     ", oracle);
        console2.log("event deadline    ", eventDeadline);
        console2.log("assertion liveness", liveness);
        console2.log("fallback deadline ", fallbackDeadline);

        vm.startBroadcast();
        market = new SuspensionMarket(
            IERC20(collateral),
            IOptimisticOracleV3(oracle),
            eventDeadline,
            liveness,
            fallbackDeadline,
            TITLE,
            RULES
        );
        vm.stopBroadcast();

        console2.log("market            ", address(market));
        console2.log("YES token         ", address(market.yesToken()));
        console2.log("NO token          ", address(market.noToken()));

        (address bondCurrency, uint256 bondAmount) = market.currentBond();
        console2.log("bond currency     ", bondCurrency);
        console2.log("bond amount       ", bondAmount);
    }
}
