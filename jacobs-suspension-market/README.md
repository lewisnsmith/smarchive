# jacobs-suspension-market

bet on whether josh jacobs gets suspended

A binary prediction market resolved by UMA's Optimistic Oracle V3. Deploy it, mint
complete sets, sell the side you don't want, and hold the side you do.

## Tech stack

| Layer | Choice | Why |
| --- | --- | --- |
| Language | Solidity 0.8.24 | Oracle and token deps are all Solidity |
| Framework | Foundry | Solidity-native tests, fast fuzzing, `cast` for oracle introspection |
| Chain | Base (8453) | OOv3 is deployed there, native USDC, cents-level gas |
| Collateral | USDC (6 decimals) | Same asset UMA uses for bonds, so one token to manage |
| Outcome shares | ERC-20 via OpenZeppelin 5.1 | Tradeable on any DEX or OTC without custom infra |
| Oracle | UMA Optimistic Oracle V3 | Judges a human-readable sentence, which is what this question needs |
| Testing | Foundry + mock OOv3 | Drives undisputed, disputed-upheld, and disputed-overturned paths |

Test on Base Sepolia first. Base mainnet is cheap but the UMA bond is not.

## Contract logic

Three moving parts.

**Collateral.** `split(amount)` takes USDC and mints equal YES and NO. `merge(amount)`
burns equal YES and NO and returns USDC. Exactly one side redeems 1:1 after
resolution, so the contract is always fully backed and the two sides must trade at a
combined price near $1. `merge` is what lets an arbitrageur enforce that.

**Assertion.** After resolution is knowable, anyone calls `assertResolution(bool)`.
The contract pulls UMA's minimum bond from the caller, builds a claim string, and
files it with the oracle. If nobody disputes within the liveness window, the claim is
true and the market resolves to the asserted side. The bond is refunded by UMA
directly to the caller, so the market never custodies it — that's why `msg.sender` is
passed as the `asserter` parameter.

**Settlement.** `assertionResolvedCallback` is how the outcome lands. `redeem()` burns
winning shares for USDC.

### The asymmetry you asked for

You wanted the default claim to be "Jacobs is not suspended," so that anyone holding a
press release can knock it down. That's exactly how this is wired, and the question's
structure makes the asymmetry fall out naturally:

- **YES needs an affirmative announcement**, so it's knowable the moment discipline is
  announced. `assertResolution(true)` works any time, including before the cutoff. If
  the news breaks on September 2nd you can settle immediately instead of waiting.
- **NO is the absence of an announcement**, only knowable once the cutoff passes.
  `assertResolution(false)` reverts with `TooEarlyForNo` before then. You can't assert a
  negative about the future.
- **If nobody asserts anything, the market falls back to NO** via `settleFallbackNo()`.

That fallback matters more than it looks. The obvious alternative — void the market and
pay both sides $0.50 — creates a griefing vector: a YES holder who knows they've lost
just never asserts, waits out the clock, and collects $0.50 on a worthless share.
Falling back to NO removes the incentive entirely, and it's the logically correct
default, because "no suspension was announced" *is* the NO outcome.

### One place this departs from your spec

You described contesting a "not suspended" assertion as directly proving suspension,
which implies a won dispute flips the market to YES. This contract doesn't auto-flip.
A won dispute voids the assertion, sets `status` back to `Trading`, and lets someone
file a fresh one.

The reason: UMA voters judge whether the *literal claim string* is true. A claim can be
voted false over a defect that has nothing to do with the underlying fact — an
off-by-one on the cutoff timestamp, an ambiguous phrase, a scope error. If false
auto-flipped the market, a drafting mistake would become a misresolution and pay out
the wrong side irreversibly. Requiring a fresh assertion costs one extra liveness
window and makes that failure recoverable.

It still gives you the behavior you want. Someone asserts NO, you dispute with the
press release, the assertion dies, you assert YES, it sails through liveness. If you'd
rather have the flip, it's one line in `assertionResolvedCallback`.

`REASSERT_GRACE` (3 days) blocks the NO fallback for a window after any rejection.
Without it, a disputer could kill an honest YES assertion filed near the fallback
deadline and immediately settle to NO.

## Resolution criteria

**Cutoff: Sunday 13 September 2026, 20:25 UTC** (3:25 p.m. CT) — the scheduled kickoff
of the Packers' Week 1 opener at Minnesota. Unix `1789331100`.

The rules make that unix timestamp authoritative and state explicitly that it does not
move even if the NFL reschedules, moves, or cancels the game. Otherwise a flex-schedule
change would silently redefine the question after people had already traded it.

The full text lives in `script/Deploy.s.sol` as `RULES`, is stored immutably on the
market, and is embedded verbatim into every assertion so voters read exactly what
traders read. Read it before you deploy — it is the most important artifact here.

The traps it closes, all of which are live in this specific situation:

- **The Commissioner Exempt List does not count.** This is the single likeliest
  near-term outcome if Jacobs is formally charged: away from the team, still paid, not
  suspended. Without an explicit exclusion, half your traders would read it as YES.
- **Fines don't count.** Reporting has left open that the league disciplines him
  without charges being filed, and that discipline could be a fine.
- **Club-imposed suspensions don't count**, only NFL discipline.
- **The initial announcement governs.** NFL discipline is routinely reduced on appeal;
  waiting for appeals to conclude can outrun your deadline.
- **Arrest and charges alone don't count.**
- **Ambiguity resolves NO**, consistent with the fallback.

## Deploying

```bash
cp .env.example .env          # then fill it in

# Derive the oracle address from UMA's Finder rather than trusting a constant.
FINDER=<uma finder for your chain> RPC_URL=$BASE_RPC_URL make oracle-info

make test
make deploy-sepolia           # rehearse the whole lifecycle here first
make deploy-base
```

Then take your position:

```bash
cast send $USDC "approve(address,uint256)" $MARKET 250000000 --rpc-url $BASE_RPC_URL --private-key $PRIVATE_KEY
cast send $MARKET "split(uint256)" 250000000 --rpc-url $BASE_RPC_URL --private-key $PRIVATE_KEY
# you now hold 250 YES + 250 NO. sell the NO.
```

Confirm what voters will see before you ever assert:

```bash
MARKET=<address> make claim-preview
```

## The bond problem, read this before you commit money

`assertResolution` pulls UMA's live minimum bond. Check the actual number with
`make oracle-info` before deploying, because it drives whether this works at all.

The bond is a **capital lockup, not a cost** — UMA refunds it to an honest asserter on
settlement. You need it liquid for the liveness window, not spent. But two things
follow, and neither is optional:

1. **If the bond exceeds the YES side's total payout, the market is structurally
   biased toward NO.** A YES holder who can't front the bond can't assert, and the
   market falls back to NO even when YES is correct. Size the market so the winning
   side's payout comfortably exceeds the bond, or pre-commit the bond capital yourself.
2. **Disputing also requires a bond.** For a very small market, a rational disputer
   won't front hundreds of dollars purely to correct a $250 market. UMA does pay the
   winner the loser's bond minus a burn, which helps, but don't rely on a stranger
   showing up to correct a bad assertion.

A market of a few hundred dollars secured by a bond of several hundred is
economically odd. It works, but the oracle costs more than the thing it secures. If
this is primarily a learning exercise, run it on Base Sepolia where the bond is play
money.

## Timeline reality

Reporting points to NFL discipline landing around the start of the regular season.
Writing rules, rehearsing on testnet, deploying, and finding counterparties inside
that window is tight. If the news breaks before you have takers, you own both sides
and the whole thing nets to zero minus gas.

## Legal

Sports event contracts are legally contested in the US — this is the live issue in
CFTC-versus-Kalshi litigation, and why Polymarket geoblocked US users before acquiring
a licensed exchange. Deploying an unlicensed contract on a sports outcome and
soliciting participants may constitute unlicensed gambling under state law or an
unregistered swap under the CEA. Wisconsin has its own rules. Talk to a lawyer before
promoting this publicly. Building it and running it on a testnet is a different risk
profile from opening it to strangers.

Not audited. Not legal advice.
