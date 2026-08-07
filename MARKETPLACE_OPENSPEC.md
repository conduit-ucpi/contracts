# Stabledrop Liquidity Marketplace — Contract OpenSpec

**Version:** 0.9.0
**Date:** 2026-08-07
**Status:** §3.2 (atomic swap) implemented ✅. **§3.3 (sale-triggered arbiter reset) implemented ✅.** **Marketplace implemented ✅ as per-offer vaults** (§5.0 — the pooled design was replaced to avoid commingling LP capital; §13.15). Full suite green: **282 tests, 0 failing**. **chainservice migrated onto the new contracts ✅ (§15.4, 263 tests green)** — the platform now holds no dispute power on any escrow it creates. Build log and deviations: **§0**. Remaining gates are external, not code: audit (§16 phase 3), counsel (§13.14), the Safe's outstanding test transaction (§13.8), and deploy-day parameters (§13.1/13.2). Test & audit plan: §14. UI & off-chain obligations: §15. Path to production: §16.
**Scope:** MarketplaceEscrow smart contract, plus two small additions to `EscrowContract` that make the swap atomic. Serves `EscrowContract` clones only — see §3.0.

---

## 0. Build Progress

> **Purpose:** resumable build log. Each row is updated as work lands so an interrupted
> session can pick up exactly where it stopped. Status values: ⬜ not started · 🟨 in
> progress · ✅ done · ⏸️ blocked.
>
> **Build started:** 2026-08-06 · **Branch:** `marketplace`
> **Phases 1 and 2 complete: 2026-08-06.** `forge test` — **309 passing, 0 failing**
> across 9 suites. Next gate is §16 phase 3 (audit); see §0.5 for what is deliberately
> out of this build.

### 0.1 Phase status

| # | Item | Spec | Status | Artifact |
|---|---|---|---|---|
| 1.1 | `EscrowContract` §3.3 arbiter changes | §3.3A–E | ✅ | `src/EscrowContract.sol` |
| 1.2 | `EscrowContractFactory` — signature **unchanged** (window is a constant) | §3.3A1, §3.3E | ✅ | `src/EscrowContractFactory.sol` |
| 1.4 | Escrow + factory deploy hardening & CI wiring | §3.4 | ✅ | `script/DeploymentScript.s.sol`, `.github/workflows/build.yml` |
| 1.3 | Escrow tests | §14.1 | ✅ | `test/EscrowArbiter.t.sol` + `test/ArbiterNominationWindow.t.sol` |
| 2.1 | Marketplace contracts (per-offer vaults) | §5.0, §5, §6 | ✅ | `src/OfferVault.sol` + `src/OfferVaultFactory.sol` |
| 2.2 | Marketplace tests | §14.2 | ✅ | `test/OfferVault.t.sol` (31) |
| 2.3 | Invariant suites | §14.3 | ✅ | `test/InvariantMarketplace.t.sol` |
| 2.4 | Marketplace deploy script | §3.4 step 3 | ✅ | `script/DeployMarketplace.s.sol` — deploys vault impl + factory |
| 3.1 | Escrow + factory deployed to Base mainnet | §3.4 steps 1–2 | 🟨 | ⚠️ REDEPLOY REQUIRED — `hasBeenSold` changed the bytecode and the clone codehash (§5.0) |
| 3.2 | Marketplace deployed | §3.4 step 3 | ⬜ | blocked on §13.1/13.2/owner/fee-recipient |
| 4.1 | chainservice migration | **§15.4** | ✅ | `chainservice/` — see §15.4a for what shipped |
| 4.2 | contractservice — stop calling the retired admin vote | **§15.5** | ✅ | auto-resolve path + `submitVote` client deleted; 321 tests green |
| 4.3 | webapp — dispute + arbiter screens | **§15.6b–c** | ⬜ | ⚠️ BLOCKING: no UI settlement path until this ships |
| 4.4 | ~~subgraph~~ → folded into 4.6 | **§15.3** | ⬜ | settled: chainservice indexes, not a subgraph. ⚠️ LOAD-BEARING — no on-chain offer book exists |
| 4.5 | webapp — marketplace screens | **§15.6d** | ⬜ | services ready (4.6, 4.7) — now blocked only on the marketplace deploy |
| 4.6 | chainservice — marketplace API + reconciler | **§15.6a, §15.3a** | ✅ | create-offer + on-demand refresh (no poll), ABIs, push; 275 tests green. Needs `OFFER_VAULT_FACTORY_ADDRESS` at deploy |
| 4.7 | contractservice — receive & serve the marketplace index | **§15.7** | ✅ | ingest + offer book + user-scoped refresh; 330 tests green |
| 4.8 | webapp — "refresh from chain" action | **§15.6f** | ⬜ | surface on an LP's offer list; a missed acceptance strands their capital |

**Open decisions blocking nothing but worth settling before audit:** §0.4c M-1 (coupled
holdback payouts) and L-2 (`renounceOwnership`).

### 0.2 Detailed checklist — Phase 1.1 (`EscrowContract` §3.3)

- [x] `DEFAULT_ARBITER` as a true `immutable`, set in the **implementation constructor** (§3.3A1a)
- [x] `arbiterNominationWindow` storage, written once in `initialize`, **no setter** (§3.3A1)
- [x] `DEFAULT_NOMINATION_WINDOW = 72 hours`; `0` at initialize → default
- [x] `resolvedBuyerPercentage` written to `255` in `initialize` (clone storage starts at 0)
- [x] `_unseatArbiter()` — called by `transferRecipientFrom` **only**, after the role moves (§3.3A1a)
- [x] `nominateArbiter(address)` — party-only, unseated-only, states 1|2, match seats immediately
- [x] `seatDefaultArbiter()` — permissionless, disputed + unseated + deadline passed
- [x] `_seatArbiter(address)` — sets `ARBITER`, **resets their vote to 255**, stamps clock (§3.3D)
- [x] `evictArbiter()` — party-only, disputed, after `ARBITER_SILENCE_TIMEOUT` (30 days)
- [x] `lastArbiterActionAt` stamped at: `raiseDispute` (arbiter seated), `_seatArbiter`, arbiter vote
- [x] `raiseDispute` sets `nominationDeadline` when `ARBITER == address(0)` (§3.3A1a)
- [x] **§3.3D guard:** `adminVoted = ARBITER != address(0) && adminVote != 255`
- [x] **§3.3D belt-and-braces:** `resolutionVotes[address(0)] = 255` at `initialize`
- [x] `_transferRecipient` rejects `DEFAULT_ARBITER`, resets `nominatedByRecipient` (§3.3A1a)
- [x] `_executeResolution` persists `resolvedBuyerPercentage` **before** transfers (§3.3C)
- [x] `changeRecipient` does **NOT** unseat (§3.3A)
- [x] §9 events + errors: `ArbiterUnseated/Nominated/Seated/Evicted`, `NotDisputeParty`, `ArbiterAlreadySeated`, `NoArbiterSeated`, `ArbiterNotSilent`, `NominationWindowStillOpen`, `InvalidArbiterCandidate`

### 0.3 Detailed checklist — Phase 2.1 (`MarketplaceEscrow`)

- [x] State + constructor (§5.1, §5.1a) incl. ERC-1167 `EXPECTED_ESCROW_CODEHASH` derivation
- [x] `createOffer` (§6.1) — 11 steps incl. codehash gate, balance-delta guard, `HoldbackOnResale`
- [x] `acceptOffer` (§6.2) — CEI, slot delete before interactions, atomic pull + pay
- [x] `rejectOffer` (§6.3) — slot **not** freed
- [x] `withdrawFunds` (§6.4) — lazy withdrawability matrix, full-gross refund
- [x] Owner surface (§6.5) — `setFeeRate`, `setMinOfferBps`, `setDefaultOfferDuration`, `withdrawFees`, `pause`/`unpause`
- [x] `sweepToken` (§6.6) — excess only
- [x] `releaseHoldback` (§6.7) — permissionless, single-shot, live beneficiary
- [x] Pause asymmetry (§5.2.10): `whenNotPaused` on **exactly** `createOffer` + `acceptOffer`
- [x] All §9 events, all §10 errors

### 0.4 Deviations from spec (deliberate, with rationale)

1. **`initialize` also rejects `_buyer == DEFAULT_ARBITER` and `_seller == DEFAULT_ARBITER`**
   (error `PartyCannotBeDefaultArbiter`). §3.3A1a specifies this rejection only on
   `_transferRecipient`, but the identical hazard exists at creation: `seatDefaultArbiter`
   is permissionless, so an escrow initialized with a party equal to the fallback would let
   anyone collapse two of the three voting roles into one address. The creation `ARBITER`
   may still be `DEFAULT_ARBITER` — that is the normal platform-created case (§3.3A2a).
2. **⚠️ `arbiterNominationWindow` is GONE. The window is a 72-hour constant,
   `NOMINATION_WINDOW`.** This supersedes §3.3A1 entirely — that section specifies a
   per-escrow value supplied to the factory, `0` meaning a 72h default, deliberately
   unbounded and immutable after `initialize`. **All of that is removed.** §3.3A1, §3.3E's
   `initialize` bullet, §13.9's ABI-break note, and §15.1's "show the nomination window" row
   must be rewritten before audit.

   **Why the parameter was wrong, in one line:** the value would be chosen by whoever
   *creates* the escrow, while the cost falls on the LP who buys the cashflow *later* — and
   in the §8.1a attack the creator **is** the adversary. While the window runs on a disputed
   sold escrow the seat is empty (`seatDefaultArbiter` is deadline-gated, `evictArbiter`
   refuses an empty seat), so there are exactly two live voters and a stonewalling buyer
   holds the recipient's capital. A creator-chosen window is a creator-chosen hostage
   duration.

   **And it bought the honest parties nothing.** `nominateArbiter` has no deadline check —
   a match seats right up until `seatDefaultArbiter` actually executes — so a longer window
   never creates more time to agree. It only delays the LP's guaranteed arrival at a third
   voter. 72 hours is therefore the *shortest humane* window, not a compromise ceiling.
   (30 days was briefly mandated instead; that would have universalised the worst tolerable
   case and is why the constant is the old default, not the old cap.)

   **What this deletes:** the `initialize` parameter (so the signature returns to its
   pre-marketplace form — **the factory ABI break of §13.9 disappears; integrators repoint
   at a new address and change no call sites**), the storage slot, `MAX_NOMINATION_WINDOW`,
   `NominationWindowTooLong`, the saturation branch in `_nominationDeadlineFromNow`, and the
   LP's obligation to discover and price a per-escrow value.

3. **`_nominationDeadlineFromNow()` must never clamp or wrap.** An earlier revision added
   saturation at `type(uint64).max` and justified it as fixing a benign truncation. That was
   backwards: a truncating cast wraps the deadline into the *past* (fallback instantly
   seatable — benign), whereas saturation makes `block.timestamp > nominationDeadline`
   unsatisfiable, i.e. a **permanently unseatable fallback** and a permanent hostage state.
   With a constant window the sum cannot approach the boundary, so the branch is gone. If
   the window ever becomes caller-influenced again, overflow must **revert**, never clamp.
   `test_SaturatedDeadlineWouldBrickTheEscrow` retains the demonstration.

4. **The fallback arbitrator stays an implementation-constructor `immutable`** and is
   deliberately **not** read from the factory. `initialize` sets `FACTORY = msg.sender` and
   is permissionless, so on a direct clone the "factory" is the attacker's own contract and
   could return any address — a self-reported value, the exact class §8.1 exists to avoid
   trusting. Because `DEFAULT_ARBITER` lives in the implementation's bytecode and a clone
   merely delegatecalls into it, an attacker's clone reads the honest Safe and cannot alter
   it; `test_DirectCloneCannotForgeDefaultArbiter` pins this. Rotation is handled by the
   Safe rotating its own signers behind a fixed address.

5. **Existing test `testPulledSellerNotCountedAsVoted` was rewritten**, not merely
   re-plumbed. Its original body had the creation arbiter voting after a
   `transferRecipientFrom`, which §3.3A now correctly rejects with `NotAuthorizedToVote`.
   The rewrite asserts that rejection, re-seats the incumbent by matching nomination, and
   then makes the original assertion (a pulled-in recipient must not read as having voted).

### 0.4a Test coverage map (§14 → file)

| §14 requirement | Where |
|---|---|
| 14.1 vote-trap trio | `EscrowArbiter.t.sol::testVoteTrap_*` (3 tests + zero-address sentinel) |
| 14.1 unseating | `testUnseat_*` (5) — incl. `changeRecipient` does NOT unseat, mid-dispute restart |
| 14.1 nomination & seating | `testNominate_*` (6), `testSeat*` (6) — incl. late-match-still-wins |
| 14.1 eviction | `testEvict_*` (8) — incl. rolling clock, unsold-escrow exit, fund-neutrality |
| 14.1 window immutability | `testWindow_IsAConstantSharedByEveryClone` + `test_DirectCloneCannotForgeTheWindow` |
| Fallback unforgeability on a direct clone | `test_DirectCloneCannotForgeDefaultArbiter`, `test_DirectCloneIsCodehashGenuine` |
| **Fallback-liveness guard (new, not in §14)** | `testFuzz_AnyAcceptedWindowLeavesFallbackReachable`, `test_FallbackReachableAtEveryRepresentativeWindow`, `test_CapIsSizedAgainstSilenceTimeout`, `test_SaturatedDeadlineWouldBrickTheEscrow`, `test_DuringWindowThereIsNoEscapeHatch` — see §0.4b |
| 14.1 `resolvedBuyerPercentage` | `testResolvedPercentage_*` — b ∈ {0,1,50,99,100} |
| **14.1 §8.1a attack replay** | **`testAttack_SelfDealtEscrowFailsAfterSale`** + `testAttack_MidDisputeSaleStillUnseats` |
| 14.2 `createOffer` | `testCreate_*` (14) — codehash gate, dust edge, fee-on-transfer, pause |
| 14.2 `acceptOffer` | `testAccept_*` (10) — approval failure modes, slot delete, resale |
| 14.2 reject/withdraw matrix | `testReject_*`, `testWithdraw_*` (10) + `testFuzz_NeverBothAcceptableAndWithdrawable` |
| 14.2 `releaseHoldback` | `testHoldback_*` (7) + `testFuzz_HoldbackRoundingMatchesEscrow` |
| 14.2 owner surface + pause asymmetry | `testOwner_*`, `testSweep_*`, `testPauseAsymmetry_AllExitsSucceedWhilePaused` |
| 14.3.1–3 marketplace invariants | `InvariantMarketplace.t.sol` (7 invariants) |
| 14.3.4–6 escrow invariants | `invariant_noManufacturedConsensus`, `invariant_marketplaceNeverHoldsTheRole`, `testEvict_MovesNoFunds` |

> The invariant handler was verified **non-vacuous** with a temporary probe asserting the
> fuzzer never reaches a sale; it failed as intended (sales and booked reserves are both
> reached), and the probe was then removed.

### 0.4b Fallback-liveness guard — and why the earlier tests missed it

**Safety property:** *a disputed sold escrow must always reach a third voter within a
bounded, plausible time.* Nothing in §14 states it. The original window tests could not
detect its loss because **every one of them measured against the window/cap constants
themselves** — one fuzz case even bounded its own input by the very constant whose removal
it should have caught. Change the constant and they all still pass, by construction.

`testFuzz_FallbackAlwaysReachableAndUnblocksTheLp` asserts the property directly against a
fixed tolerance (`MAX_TOLERABLE_HOSTAGE = 90 days`, deliberately far looser than the 72-hour
window so it is a real bound, not a restatement). It also pins that during the window there
is genuinely no escape (no fallback, no seat to evict), and that once the fallback seats,
the LP can settle **without the buyer**.

**Mutation-tested at each design stage — a passing guard proves nothing until shown to fail:**

| Design | Mutation | Cap/constant-relative tests | Liveness guard |
|---|---|---|---|
| per-escrow window | cap removed from `initialize` | 2 fail | **fail in 6 fuzz runs** (a ~546-million-year window accepted) |
| per-escrow window | cap **kept and enforced**, raised to 10 years | **all 5 pass** ✅ | **3 fail** |
| constant window | `NOMINATION_WINDOW` widened to 120 days | — | **3 fail** |

The middle row was the original finding: a plausible "allow longer negotiations" change
sailed through the entire old suite untouched.

### 0.4c Security review findings (self-audit, 2026-08-06)

Reviewed: `EscrowContract`, `EscrowContractFactory`, `MarketplaceEscrow`. This is an
internal review, **not a substitute for §16 phase 3**.

| # | Severity | Finding | Status |
|---|---|---|---|
| H-1 | **High** | `acceptOffer` could overwrite a live holdback record, stranding the first reserve permanently | **Fixed** |
| M-1 | Medium | `releaseHoldback` pays beneficiary and funder in one transaction; a blocked beneficiary blocks the funder, with no remedy after settlement | **Open — decision needed** |
| L-1 | Low | `acceptOffer` transferred zero to the seller when a holdback consumed the whole offer | **Fixed** |
| L-2 | Low | `renounceOwnership` is inherited and would permanently lock all accrued fees | **Open — decision needed** |

**H-1 — holdback record overwrite (fixed).** `createOffer` validated `holdback == 0 ||
!hasBeenSold[escrow]`, but `acceptOffer` did not re-check, and `hasBeenSold` can flip
between the two calls. Two LPs may both bid with a holdback while an escrow is unsold (both
legal). The seller accepts the first, recording the one permitted reserve. If the position
then returns to that same seller — a direct `changeRecipient` back, or the seller buying
their own cashflow back as an LP, since after the first sale they are no longer the
recipient and so pass the party check — the second offer becomes live again and its
acceptance **overwrote `holdbacks[escrow]` while still adding to `totalHoldbacks`**. The
first reserve was then unreachable by everyone: no record remained to release it, and
`sweepToken` subtracts `totalHoldbacks`, so the owner could not recover it either.
Conservation still held, so no invariant caught it — the loss is liveness, not solvency.
Fixed by re-checking at acceptance, plus making such an offer immediately withdrawable so
the second LP is not locked in until expiry. Regression:
`test/MarketplaceHoldbackRegression.t.sol`.

**M-1 — coupled holdback payouts (open).** `releaseHoldback` sends to the beneficiary and
the funder in the same transaction. If the beneficiary cannot receive (USDC blacklist, a
reverting contract), the whole call reverts and the **funder's** unrelated refund is blocked
too. Normally a beneficiary could rotate their payout address, but `releaseHoldback`
requires `isClaimed()`, and at that state `_transferRecipient` reverts — so there is no
remedy. Options: split into per-party pull claims (adds state), or accept and document
alongside the existing blacklist residual in §11.

**L-2 — `renounceOwnership` (open).** Inherited from `Ownable` and not overridden. Calling
it makes `withdrawFees`, `sweepToken`, `pause`/`unpause` and every setter permanently
unreachable, stranding all accrued fees. One-line fix if unwanted: override to revert.

**Checked and found sound:** CEI ordering in all five state-mutating paths; `nonReentrant`
coverage incl. cross-function reentry; the pause asymmetry; owner reach bounded by
`accruedFees`; `EXPECTED_ESCROW_CODEHASH` against a real factory clone; fee snapshotting;
slot lifecycle; the §3.3D vote-trap guards; `DEFAULT_ARBITER` unforgeability on a direct
clone; `NOMINATION_WINDOW` liveness; holdback rounding against `_executeResolution`.

### 0.5 Not in this build

- Nothing in the contract or deploy-tooling scope remains. Both deploy scripts exist and
  `DEPLOYMENT_ADDRESSES.md` records the live addresses (§3.4).
- **chainservice is now done (§15.4a).** Still outside this build: the rest of §16 phase 4
  — contractservice's retired-vote caller, webapp dispute screens, subgraph — and the
  external gates below.
- The §13.1/13.2 launch parameters — passed at deploy, not baked in.
- Audit (§16 phase 3), counsel (§13.14), Safe test transaction (§13.8) — external gates.

---

## 1. Overview

The Stabledrop Liquidity Marketplace enables escrow recipients (sellers) to sell their locked cashflows to liquidity providers (LPs) at a discount via an **atomic, trustless swap**. There is no UI dependency — the contract is fully operable via direct on-chain interaction by any wallet.

**v0.4 design principle:** the marketplace **never takes custody of the recipient role**. The seller grants the marketplace a one-shot approval on the escrow; `acceptOffer` pulls the role and pays the seller in a single transaction. This eliminates the entire class of custody-window failures present in v0.2/v0.3 (stuck dispute payouts, stranded recipient roles, stale-seller theft, expire-restore griefing).

---

## 2. Actors

| Actor | Description |
|---|---|
| **Seller** | Current recipient of a StabledropEscrow (read live via `recipient()`). Wants immediate liquidity at a discount. |
| **LP (Liquidity Provider)** | Any wallet except the escrow's buyer or arbiter. Makes offers by depositing the escrow's token into the MarketplaceEscrow contract. |
| **Protocol** | Collects a configurable fee, accrued at acceptance time. **The seller bears it:** the LP deposits exactly `offerAmount` and the seller receives `offerAmount − fee − holdback` at acceptance (§5.1, §6.1.8; the holdback comes back to them at settlement if the cashflow collects in full, §5.3). The fee is deducted from the LP's deposit in transit, but its economic incidence is on the seller's proceeds, not on the LP's cost. See §8.5a. |
| **Owner** | Controls the fee rate and default offer duration (Ownable2Step). Cannot interfere with individual escrow transactions or touch LP deposits. |

---

## 3. Escrow Interface

### 3.0 Supported escrow types — `EscrowContract` only

The marketplace serves clones of **`EscrowContract`** (the legacy, single-recipient,
expiry-based escrow) and nothing else. `CompletionEscrowContract` clones are **out of
scope** — not deferred, but structurally incompatible. Two independent reasons:

1. **No maturity.** `CompletionEscrowContract` has no `EXPIRY_TIMESTAMP`. Funds move on
   `verifyComplete()` or on dispute resolution — never on a clock. The marketplace exists
   to discount a cashflow that unlocks at a known time T; here there is no T. This voids
   the `maturity() != 0` gate, the `offerExpiry < maturity()` invariant (§5.2.2), and the
   bound on LP downside: on `EscrowContract` the buyer's dispute window closes at expiry,
   whereas `CompletionEscrowContract` permits `raiseDispute` in both the funded and
   pending-verify states with nothing to run out. Worse, `VERIFIER` defaults to `BUYER`,
   so the LP's counterparty would control whether the LP is ever paid, indefinitely.
2. **No single recipient role.** Payout is an `address[] payees` / `payeeBps[]` split of
   1..10 entries. There is no one role to transfer, so §3.2's one-shot approval has no
   analogue. Supporting it would require a per-payee transfer approval on the escrow, a
   three-part offer key `(escrow, payeeIndex, lp)`, and per-slice pricing
   (`payoutAmount() * payeeBps[i] / 10000`).

Selling completion-escrow slices is therefore a **different product with a different risk
model**, not a codehash added to a set. Should it ever be built, it warrants its own spec.

`EXPECTED_ESCROW_CODEHASH` is a single `immutable` (§5.1) precisely because there is exactly
one supported implementation. Any future multi-implementation support is a constructor and
state-layout change, not a configuration change.

### 3.1 Already implemented on `EscrowContract` ✅

| Function | Behaviour |
|---|---|
| `recipient() → address` | Current SELLER (reassignable) |
| `maturity() → uint256` | `EXPIRY_TIMESTAMP` (0 = instant transfer — not sellable) |
| `hasActiveDispute() → bool` | True while disputed (`_state == 2`) |
| `token() → address` | The escrowed ERC20 (any ERC20 permitted) |
| `payoutAmount() → uint256` | Net amount the recipient receives (`AMOUNT − CREATOR_FEE`) — **the figure LPs price against** |
| `isFunded() / isClaimed()` | State views. NOTE: `isFunded()` is `_state >= 1` (includes disputed/claimed). "Sellable" is the composite: `isFunded() && !hasActiveDispute() && !isClaimed()` |
| `changeRecipient(address)` | Callable only by current recipient, funded OR disputed state; new recipient cannot be zero/buyer/arbiter; new recipient's vote reset to "not voted" |
| `FACTORY() → address` | Set to whoever initialized the clone. **Informational only — NOT usable for provenance** (a fake contract can return any address). Genuineness is verified via the ERC-1167 codehash check (§8.1). |

### 3.2 One-shot recipient-transfer approval — implemented ✅

```solidity
address public recipientOperator;          // approved operator, address(0) = none
uint64  public recipientApprovalExpiry;    // approval deadline (packed)
address public approvedRecipientTarget;    // the ONLY address the operator may set
uint256 public constant RECIPIENT_APPROVAL_TTL = 5 minutes;

function approveRecipientTransfer(address operator, address newRecipient) external;
function transferRecipientFrom(address newRecipient) external;
```

- `approveRecipientTransfer(operator, newRecipient)`: callable **only by the current recipient**, in the same states `changeRecipient` allows (funded or disputed). Binds **both** the operator **and** the exact destination — even a malicious operator can only execute the precise move the seller sanctioned. The destination is validated at grant time (zero/buyer/arbiter rejected). Valid for **5 minutes** (`RECIPIENT_APPROVAL_TTL`) — covers the human gap between the two signed transactions; an expired approval just means re-approving. `operator == address(0)` revokes. Emits `RecipientTransferApproved(operator, newRecipient, expiry)`.
- `transferRecipientFrom(newRecipient)`: callable **only by the approved operator**, **only** with `newRecipient == approvedRecipientTarget`, **only** before expiry. Applies the identical guards and effects as `changeRecipient` (state check, zero/buyer/arbiter rejection, vote reset, `RecipientChanged` event), then **clears the approval** (one-shot, no replay).
- **Any** recipient change (direct or operator-driven) clears the approval — an approval granted by a previous seller can never act on the new seller's role.
- A dangling approval is harmless: it moves nothing by itself, blocks nothing (claims/disputes/votes unaffected), expires in 5 minutes, and is inert once the escrow settles regardless.
- **"One-shot" means per grant, not per escrow.** Each grant permits at most one transfer; after use (or expiry/revocation/recipient change) the slot is empty again and a **fresh approval can be granted at any time by whoever is the current recipient then**. The original seller cannot re-grant after a sale — only the new recipient (e.g. the LP) can, which is exactly what enables resale.

> Deployment note: existing deployed escrows are immutable and will not have these functions. The marketplace serves clones of the **new** implementation only, enforced by the codehash check (§8.1) — old-implementation clones have a different codehash and are rejected automatically.

### 3.3 Required escrow changes — implemented ✅

These address the self-dealt-escrow attack (§8.1a) — specifically its **corrupt-arbiter
variant**, where the attacker pre-loads an arbiter they control. What remains afterwards is
the ordinary risk that an arbiter rules wrongly on the merits, which is true of every
arbitration in every system and is not specific to this design; see §8.1a for what is and is
not closed.

They are changes to `EscrowContract` itself, not to the marketplace, and they ship in the
same new implementation as §3.2. At the **contract** level they are confined to sold
escrows — an escrow that never sells keeps today's dispute mechanics exactly. At the
**service** level two things change platform-wide: the creation arbiter becomes the
`DEFAULT_ARBITER` Safe rather than chainservice's hot wallet, and agreed settlements are
pushed on-chain by the two disputants themselves (§3.3A2a, §13.9) — the hot wallet retains
no dispute power on any escrow.

**A. Arbiter is chosen at creation — and unseated by a sale.**
`initialize` **keeps** its arbiter parameter, and an escrow that is never sold behaves
exactly as today: the creation arbiter holds office and the current 2-of-3 runs unchanged,
with none of the machinery below ever invoked. The change is confined to the moment a
cashflow is sold through the marketplace:

```
transferRecipientFrom(lp)              // the atomic sale, §3.2
  → ARBITER := address(0)              // incumbent UNSEATED, automatically, in the same tx
  → buyer and new recipient may re-seat by agreement at any time:
      both nominate the same address → seated immediately
      (nominating the incumbent re-confirms them — two transactions, done)
  → if a dispute is raised while unseated:
      nomination window opens → on expiry unmatched, DEFAULT_ARBITER is seatable (fallback)
  → throughout, buyer + recipient matching votes still settle 2-of-3 —
    no arbiter is needed when the parties agree on the outcome

Once seated, ordinary 2-of-3 resolution proceeds with NO deadline (see A2).
```

`changeRecipient` does **not** unseat: a seller rotating their own payout wallet should not
evict a legitimate arbiter, and an OTC buyer taking the role outside the marketplace gets
none of the marketplace's other protections either. Unseating is a property of the **sale**.

**Why unseating is automatic, not objection-based.** An opt-in objection ("the new recipient
may object to the incumbent after buying") loses a race the attacker controls: in the
self-dealt escrow the attacker *is* the seller, so they choose the block the sale lands in
and can bundle `acceptOffer` → `raiseDispute` → buyer votes 100 → pre-loaded arbiter votes
100 — consensus executes before any objection can land. Unseating inside
`transferRecipientFrom` makes that bundle fail (the old arbiter is no longer an authorised
voter), and costs an honest incumbent nothing: both parties re-confirm them at leisure.

**Why this closes the corrupt-arbiter variant.** The §8.1a attack needs a pre-loaded arbiter
still holding office when the dispute fires. After any sale the incumbent is out, and every
path back to a seat runs through the new recipient: re-confirmation and replacement both
need their matching nomination, and the fallback is a party the attacker does not control.
The 2-of-3 majority cannot be manufactured — and refusing to agree does not deadlock the
escrow, it hands the seat to the default arbiter. The attack fails rather than relocating.

**A1. Nomination window is a 72-hour CONSTANT — `NOMINATION_WINDOW`.**
It is read only when a **sold** escrow raises a dispute while unseated; an escrow that never
sells never consults it.

> **Revised (v0.7.0). Earlier drafts of this section made the window a per-escrow value
> supplied to the factory, `0` meaning a 72h default, deliberately unbounded, and argued a
> hostile window was "self-limiting" because it is public before anyone buys. That was
> wrong and is superseded.** The rest of this box records why, because the reasoning
> generalises.

**Why a parameter was the wrong shape.** The value would be chosen by whoever *creates* the
escrow, while the cost falls entirely on the **LP who buys the cashflow later** — and in the
§8.1a attack the creator *is* the adversary. While the window runs on a disputed sold
escrow the arbiter seat is empty: `seatDefaultArbiter` is deadline-gated and `evictArbiter`
refuses an empty seat, so there are exactly two live voters and a buyer who simply withholds
agreement holds the recipient's capital. **A creator-chosen window is a creator-chosen
hostage duration.**

**And it bought the honest parties nothing.** `nominateArbiter` has *no deadline check* — a
matching pair seats right up until `seatDefaultArbiter` actually executes (§3.3A1a). So a
longer window never creates more time to agree; it only delays the LP's guaranteed arrival
at a third voter. 72 hours is therefore the **shortest humane window**, not a compromise
ceiling — which is why the constant is the old *default*, not the old *cap*.

**The "self-limiting" argument also failed on its own terms:** nothing in the sale path read
the field, so the protection rested entirely on an LP's client surfacing it, which §15 never
guaranteed.

**What this removes:** the `initialize` parameter — so the signature returns to its
pre-marketplace form and **the factory ABI break of §13.9 disappears entirely** (integrators
repoint at a new address and change no call sites) — plus the storage slot, and any need for
an LP to discover and price a per-escrow value. There is no minimum and no maximum to
enforce, because there is nothing to supply.

**A1a. Nomination and seating mechanism.**

```solidity
address public immutable DEFAULT_ARBITER;   // fallback arbitrator ONLY — set in the IMPLEMENTATION constructor, see below
// Named DEFAULT_ARBITER (not "admin") deliberately: this address has no operational role.
// It never touches escrow creation, offers, or acceptances — its sole capability is being
// seated as the fallback arbiter on a SOLD escrow and then casting a dispute vote. That is
// why multisig latency is acceptable for it (§13.8) and why it needs no other powers.
uint64  public constant NOMINATION_WINDOW = 72 hours;   // constant, not a parameter — see A1

address public ARBITER;                     // set at initialize; address(0) while unseated after a sale
address public nominatedByBuyer;
address public nominatedByRecipient;
uint64  public nominationDeadline;          // set when a dispute and the unseated state coincide

function nominateArbiter(address candidate) external;   // buyer or current recipient
function seatDefaultArbiter() external;                // permissionless, after deadline
```

**Where each value lives is security-relevant, not stylistic:**

- **`DEFAULT_ARBITER` is a true Solidity `immutable`, set in the implementation's constructor**
  and therefore shared by every clone. It MUST NOT be an `initialize` parameter: `initialize`
  is permissionless (§8.1a), so a per-escrow admin would let a self-dealt clone install its
  own fallback — zero nomination window, dispute, refuse to nominate, and the fallback seats
  an attacker-controlled arbiter. The corrupt-arbiter attack would return straight through
  the mechanism built to kill it. Baking the address into the implementation bytecode makes
  it unforgeable by direct clones at no cost.

  Consequence: rotating `DEFAULT_ARBITER` means a new implementation, hence a new codehash,
  factory, and marketplace. **It must therefore be a multisig** (rotate signers inside it;
  the address never changes) — this upgrades §13.8's "ideally a multisig" to a requirement.

- **`NOMINATION_WINDOW` is a plain `constant`**, so like `DEFAULT_ARBITER` it lives in the
  implementation's bytecode and is identical for every clone. An attacker's direct clone
  cannot present a different one, and there is no storage slot and no setter to audit. This
  replaces the earlier per-escrow storage variable (§3.3A1).

**`_unseatArbiter()` (internal) — called by `transferRecipientFrom` only, after the role
moves.** Not by `changeRecipient`, and not inside the shared `_transferRecipient` (which
both paths use):

```solidity
address previous = ARBITER;
ARBITER = address(0);
nominatedByBuyer = address(0);
nominatedByRecipient = address(0);
if (_state == 2) nominationDeadline = uint64(block.timestamp + NOMINATION_WINDOW);
emit ArbiterUnseated(previous);
```

The `_state == 2` branch covers a sale executed mid-dispute (§3.2 permits the transfer in
funded *or* disputed state — though the marketplace itself never sells into a dispute, a
direct operator flow could): the new recipient gets a full window from the moment they hold
the role. For the normal funded-state sale, the deadline is instead set by `raiseDispute()`:
**if `ARBITER == address(0)` at that point, `raiseDispute` sets `nominationDeadline =
block.timestamp + NOMINATION_WINDOW`.**

**`nominateArbiter(candidate)`**
1. Require `ARBITER == address(0)` (revert `ArbiterAlreadySeated`) — only a sold, unseated
   escrow accepts nominations. Require `_state == 1 || _state == 2`: agreement is allowed
   **before** any dispute (settle governance while relations are good) as well as during
   one.
2. Require `msg.sender == BUYER || msg.sender == SELLER` (revert `NotDisputeParty`).
3. Require `candidate != address(0) && candidate != BUYER && candidate != SELLER`
   (revert `InvalidArbiterCandidate`) — an arbiter who is also a party would hold 2-of-3
   alone, the precise failure `initialize` guards against today. This is the **only**
   constraint on a candidate; nominations are otherwise free-form (§3.3B), and nominating
   the unseated incumbent to re-confirm them is the expected common case.
4. Record the nomination for the caller's side. Nominations are **mutable** until seated:
   re-nominating overwrites.
5. If both sides have nominated and the two addresses are equal → `_seatArbiter(candidate)`
   **immediately**, in this same transaction.
6. Emit `ArbiterNominated(msg.sender, candidate)`.

There is deliberately **no deadline check on nominations**: a match is always better than
the fallback, so a late agreement still seats right up until `seatDefaultArbiter` actually
executes. The deadline's only role is to *enable* the fallback, never to block agreement.

**`seatDefaultArbiter()`**
1. Require `_state == 2` and `ARBITER == address(0)`.
2. Require `block.timestamp > nominationDeadline` (revert `NominationWindowStillOpen`).
3. `_seatArbiter(DEFAULT_ARBITER)`.

Permissionless by design, mirroring `checkAndActivate`: it takes no discretion and can only
do the one thing the elapsed window already determined. Note it never forecloses agreement:
nominations carry no deadline check, so a matching pair still seats right up until this
actually executes.

**`_seatArbiter(address a)` (internal)**
```solidity
ARBITER = a;
resolutionVotes[a].buyerPercentage = 255;   // ⚠️ MANDATORY — see §3.3D
emit ArbiterSeated(a, /* byAgreement */ a != DEFAULT_ARBITER);
```

The vote reset also covers a re-confirmed incumbent who had already voted before the sale
unseated them mid-dispute — they return to office with a clean slate.

**`evictArbiter()` — remedy for a seated-but-silent arbiter.**

```solidity
uint256 public constant ARBITER_SILENCE_TIMEOUT = 30 days;
uint64  public lastArbiterActionAt;   // see update rules below

function evictArbiter() external;     // either disputant, after the timeout
```

`lastArbiterActionAt` is stamped `block.timestamp` at three points: when `raiseDispute`
fires with an arbiter already seated (the clock must start at the dispute, not at creation —
an unsold escrow's Safe may sit quietly for months before any dispute exists); inside
`_seatArbiter`; and inside `submitResolutionVote` whenever `msg.sender == ARBITER` (casting
*or changing* a vote resets the clock).

1. Require `_state == 2` (eviction is meaningless outside a dispute) and
   `ARBITER != address(0)` (revert `NoArbiterSeated`).
2. Require `msg.sender == BUYER || msg.sender == SELLER` (revert `NotDisputeParty`).
3. Require `block.timestamp > lastArbiterActionAt + ARBITER_SILENCE_TIMEOUT`
   (revert `ArbiterNotSilent`).
4. Clear the seat and nominations exactly as `_unseatArbiter` does, restart
   `nominationDeadline = block.timestamp + NOMINATION_WINDOW`, emit
   `ArbiterEvicted(previous)`.

Eviction **only swaps the third voter** — it moves no funds and closes nothing, so it cannot
become a forced-resolution backdoor (§3.3A2). After eviction the ordinary path resumes:
match-nominate a replacement (or the same arbiter again), or let the window lapse and seat
the Safe. Two deliberate properties:

- It also covers the arbiter who voted once and vanished: a standing figure that matches
  neither party is the same deadlock as silence, and the rolling clock (silence since *last*
  vote) makes it evictable.
- On an **unsold** escrow it is the parties' exit from a slow Safe: evict, then
  match-nominate a private arbiter of their choosing — the platform is not a mandatory
  bottleneck even where it holds the creation seat. If they can't match, the same Safe
  simply re-seats after the window.

Accepted cost: a party who dislikes an honest arbiter's standing figure can wait out the
timeout and evict — effectively appealing to the Safe. Bounded (they cannot choose the
replacement unilaterally), and slow by construction.

**Recipient changes while unseated clear the recipient's nomination.** `_transferRecipient`
MUST reset `nominatedByRecipient = address(0)` alongside the existing vote reset — a
nomination made by a previous recipient must never bind the new one. (This lives in the
shared `_transferRecipient` because it must also cover `changeRecipient` while unseated.)

**`_transferRecipient` must also reject `newSeller == DEFAULT_ARBITER`.** Otherwise an escrow
whose recipient is the default arbiter would have no valid fallback, and seating one would
collapse two of the three voting roles into a single address. This sits alongside the
existing `newSeller == ARBITER` rejection, which remains live whenever an arbiter is seated
(i.e. always, except between a sale and a re-seating).

> **A candidate is not validated for competence.** Nothing checks that a nominated address
> can actually vote. If both parties agree on a contract with no `submitResolutionVote`
> path, the third voter is seated and permanently dead. Buyer and recipient can still
> settle 2-of-3 between themselves, but the tiebreaker is gone for good. This is the main
> cost of dropping the registry (§3.3B); `evictArbiter` (below) is the remedy — after 30
> days of silence the dead seat is cleared and nomination reopens.

**A2. No resolution deadline — the arbiter proposes, a party disposes.**
Once an arbiter is seated, ordinary 2-of-3 resolution runs with **no time limit and no
forced closure**. `_checkAndExecuteConsensus` is unchanged; the arbiter is simply a third
voter whose figure becomes focal.

This is deliberate, and it is what keeps the platform out of the payout decision:

- **The platform can never move funds alone.** Every settlement requires a *disputing
  party* to actively vote the number that executes. The admin's vote alone does nothing.
  This is a materially stronger and simpler claim than any weighted or averaged formula,
  and it is the property to lead with in any regulatory conversation. **(Not legal advice —
  confirm the perimeter with counsel; see §13.14.)**
- **A single stubborn party cannot deadlock.** The arbiter plus one party is already 2-of-3,
  so if the buyer stonewalls, the arbiter can vote the recipient's figure and it settles
  without the buyer, and vice versa. Holding out is not a blocking move; it is a bet that
  the arbiter will not endorse the other side.
- **Time pressure drives convergence.** The recipient — after a sale, the LP — is holding a
  discounted position and bleeding time-value on frozen capital, so they are strongly
  incentivised to converge on the arbiter's figure. They control their own settlement
  timing by choosing to accept it.

Rejected alternatives, recorded so they are not revisited: making the seated arbiter's vote
**binding** after the window (gives the platform unilateral control of funds — the exact
exposure this design exists to avoid); resolving to the **mean of the three votes** (not
strategy-proof — honest voting becomes dominated, both parties pin to the extremes, and
every dispute refunds the buyer ~33% regardless of merit, which in this marketplace is a
guaranteed extraction from the LP and would collapse the discount range); resolving to the
**median** (strategy-proof, but with polarised parties the median *is* the arbiter's vote,
i.e. unilateral control with extra steps).

**A2a. Agreed settlements — every vote is an on-chain binding offer. (ALL escrows.)**
Today chainservice settles an agreed dispute by completing the vote pair itself: one party
casts `submitResolutionVote(X)` on-chain and the platform, holding the arbiter seat with its
hot wallet, casts the matching vote. **That mechanism is retired everywhere, not only for
sold escrows** — because of the companion decision:

> **The creation arbiter is the `DEFAULT_ARBITER` Safe on every chainservice-created
> escrow.** The operational hot wallet holds no dispute power on any escrow, and a 2-of-3
> multisig cannot act as an automated vote-completer. This also makes the §3.3A2 claim —
> the platform can never move funds alone — true of the whole platform, not just the
> marketplace. (On a sold escrow the sale still unseats the Safe and the fallback re-seats
> it; unseat-on-sale remains load-bearing for hostile direct clones, whose creator picks
> their own creation arbiter.)

**There is no off-chain agreement stage.** (Decision, 2026-08-06 — this supersedes the
earlier "negotiate off-chain, then prompt both parties to ratify" flow.) Every settlement
figure a disputant names goes **straight on-chain** as `submitResolutionVote(X)` from their
own wallet, the moment they name it. The contract is the only place agreement is detected:
`_checkAndExecuteConsensus` runs at the end of *every* vote, so the instant any two of the
three current votes match, the payout executes in that same transaction.

Rationale: the retired design had the platform mirror the contract's own consensus rule
off-chain — recording each side's figure, comparing them, then triggering the votes. That is
duplicated logic whose only possible behaviours are *agree with the chain* or *be wrong*, and
it created a state ("agreed off-chain, unsettled on-chain") that could persist indefinitely
and had to be chased. Removing the mirror removes the state.

Consequences, all load-bearing:

- **A submitted number is an offer, not a position.** The contract holds exactly one value per
  role — the latest — and any two matching values settle immediately and irreversibly. On-chain
  there is no difference between "I propose 40%" and "I accept 40%". **The UI must therefore
  present every submission as binding** (§15.1): naming a figure the other side already holds
  ends the dispute at that figure. A counter-offer thread implying numbers can be floated and
  refined is a misrepresentation of what the transaction does.
- **Discussion stays off-chain; only the number goes on-chain.** Messages, evidence and
  reasoning remain in contractservice. This is the whole of what "negotiation is off-chain"
  now means.
- **Votes stay mutable until consensus** (`:1174`), so a party may revise their offer freely.
  Each revision is another sponsored transaction — cheap, because the slot is already non-zero
  (a revision costs far less than a first vote).
- **Any two of three settle, not just buyer-and-seller.** Once an arbiter is seated, a party
  moving to the arbiter's standing figure ends the dispute without the third party's assent.
  The arbiter still takes **no action of any kind** in a settlement the two parties reach
  between themselves.
- **A party who never votes simply never agrees.** The dispute stays open and resolves as any
  contested one does — arbiter adjudication (the Safe on an unsold escrow; the seated or
  fallback arbiter on a sold one, §3.3A1a). There is no deadline (§3.3A2).

Gas: every vote routes through the existing **gas-sponsorship path** used for all user-wallet
actions — a party with zero ETH settles fine, and no wallet funding step is needed anywhere.
Measured cost (§15.4a): a first vote is ~28k gas all-in and the settling vote ~99k (worst case
observed ~160k), the asymmetry being that the settling voter's transaction executes the whole
payout. At the platform's sponsored rates a fully settled dispute is on the order of a tenth
of a cent, so the extra transactions from on-chain revisions are not a cost consideration.

> Considered and rejected: a gasless `settleBySignatures(pct, buyerSig, recipientSig)`
> (EIP-712, permissionless relay — the platform carries the parties' signature bytes but
> never authority). Cryptographically sound and a standard pattern, but it requires reliable
> typed-data signing in the webapp wallet layer, which the current provider stack does not
> deliver across the user base (embedded/contract wallets would additionally force ERC-1271
> verification onto the escrow). Revisit only if the wallet stack changes.

**A3. Residual risks of no deadline — disclose, do not "fix".**

1. **Hold-up against the time-pressured party.** The LP's time incentive is visible to the
   buyer, so a patient bad-faith buyer can hold out for a better split than the merits
   justify. Bounded — the buyer risks the arbiter endorsing the LP's figure outright — but
   real, and LPs will price it into their discount.
2. **Arbiter negligence.** Deadlock is now reachable only if the arbiter's figure matches
   neither party, neither party moves, *and* the arbiter will not adopt either figure. A
   conscientious arbiter can always break it; an absent one cannot — which is why a
   seated-but-silent arbiter is **evictable** after `ARBITER_SILENCE_TIMEOUT` (§3.3A1a,
   `evictArbiter`): the freeze is bounded at 30 days plus a nomination round, never forever.

**B. No arbiter registry — nominations are free-form.**

Earlier drafts required nominations to come from a curated list, at first for all escrows
and then for resold ones only. **Both are dropped.** Nominations are unconstrained beyond
"not the zero address and not a party" (§3.3A1a step 4). There is no registry contract, no
curator role, and no `wasResold` flag.

**Why a registry is unnecessary.** Three facts compose:

1. **Any arbiter chosen before the sale is unseated at the moment of sale** (§3.3A) — the
   LP is never subject to an incumbent they did not personally re-confirm.
2. **An LP can never buy into a disputed escrow.** `createOffer` and `acceptOffer` both
   require `!hasActiveDispute()` (§6.1.4, §6.2.4), and an offer on an escrow that becomes
   disputed turns immediately withdrawable (§6.4).
3. **Seating requires a match**, so either party can veto any candidate by simply not
   matching, and a non-match falls through to the default arbiter (§3.3A1a).

Together these mean an LP is *never* bound by an arbiter chosen before they arrived, and
can never be outvoted onto an arbiter they did not personally agree to. The veto — not a
list — is what prevents collusion, and the veto works identically with or without one. A
registry would have added a quality bar on top of a protection that was already complete.

**It also improves the regulatory position (§13.14).** Curating a panel is itself a form of
influence over dispute outcomes. Removing the curator removes that question rather than
having to answer it: the platform now maintains no list, vets no one, and appears in a
dispute only as the fallback third voter that neither party can outvote alone.

**What is genuinely given up:** resistance to social engineering. Nothing on-chain now stops
an LP being talked into matching a plausible-looking address that is in fact the buyer's
associate. This moves from a contract guarantee to a **UI responsibility** — the nomination
step must warn clearly that matching an unknown arbiter is irreversible and that declining
to match is always safe, because it falls back to the admin. Note the LP has to take
positive action against their own interest for this to bite; the default path is safe.

**Second cost:** no candidate is checked for competence — see the warning in §3.3A1a. This
is remedied by `evictArbiter` (§3.3A1a) — a dead seat clears after 30 days of silence.

**C. Residual holdback — specified on the marketplace, not here.**

The residual is a term of the **sale**, not of the escrow: the LP advances part of the
agreed price and retains a reserve, released to the seller once the cashflow is collected.
It is therefore funded out of the **seller's proceeds** and never touches the buyer's refund
rights. Full specification is §5.3 / §6.7.

One escrow change is required to support it:

**Persist the dispute outcome.** `_executeResolution(agreedPercentage)` currently emits the
figure but does not store it, so an external contract cannot read how a dispute resolved.
The marketplace needs it to compute the LP's shortfall. Add:

```solidity
uint8 public resolvedBuyerPercentage = 255;   // 255 = no dispute resolution has occurred
```

Set in `_executeResolution` before the transfers. The 255 sentinel matches the convention
already used by `resolutionVotes` and distinguishes "resolved at 0% to buyer" from "never
disputed".

Note that distinction is **not** load-bearing for §6.7: both cases yield `loss == 0` and pay
the reserve back to the funder in full, so a plain `0` default would compute identically. The
sentinel is kept for observability — indexers and the UI can tell a dispute that went the
recipient's way from one that never happened — and because the escrow already uses 255 for
exactly this meaning. If the extra branch is unwanted, defaulting to `0` is safe.

**⚠️ D. The unseated-arbiter vote trap — implementation-critical.**

**Getting this wrong hands any seller the entire escrow.** In `resolutionVotes`, "not
voted" is the sentinel **255**, and it must be *written*, because a default mapping read
returns **0** — which is a valid vote meaning "0% to buyer", i.e. **100% to the seller**.
This is why `initialize` explicitly sets all three parties to 255 (`EscrowContract.sol`
lines 399–401) and why `_transferRecipient` resets a new recipient to 255.

§3.3A unseats `ARBITER` at every sale, so `address(0)` is now a live mid-life state — which
walks straight into this trap twice:

1. **While unseated.** If `ARBITER == address(0)`, then `resolutionVotes[address(0)]`
   reads 0, so `_checkAndExecuteConsensus` computes `adminVoted == true` with a vote of
   100%-to-seller already cast. The branch `sellerVoted && adminVoted && sellerVote ==
   adminVote` then fires the moment the seller votes 0 — **the seller unilaterally takes
   the full escrow, before the nomination window has even opened.** The attack §3.3 exists
   to prevent is replaced by a strictly worse one that needs no collusion at all.
2. **At seating.** A newly seated arbiter's slot also defaults to 0, so seating them
   silently casts a 100%-to-seller vote on their behalf. If the seller has already voted
   0, consensus fires in the same transaction that seats the arbiter.

Required, both of them:

```solidity
// (1) Never treat an unseated arbiter as a voter.
bool adminVoted = ARBITER != address(0) && adminVote != 255;

// (2) Seating an arbiter must reset their vote, exactly as _transferRecipient does
//     for a new recipient.
ARBITER = seatedArbiter;
resolutionVotes[seatedArbiter].buyerPercentage = 255;
```

Belt-and-braces: also write `resolutionVotes[address(0)].buyerPercentage = 255` at
`initialize`, so the zero address can never read as a live voter even if a future edit
drops the guard in (1).

**Test this explicitly.** Minimum cases: seller votes 0 with no arbiter seated (must NOT
resolve); seller votes 0, then an arbiter is seated (must NOT resolve); buyer and seller
both vote 50 with no arbiter seated (MUST resolve — this is the no-arbiter-needed path,
`_checkAndExecuteConsensus` branch 1, and it is the common case).

**E. Trust consequences and knock-on changes.**
These follow from §3.3 as a whole — principally from A (arbiter selection) and its
default-arbiter fallback.

**Trust consequences to disclose:**
- The platform becomes a **trusted backstop** for any *sold-escrow* dispute the parties do
  not settle themselves. The escrow is trust-*minimised*, not trustless. Both buyers and LPs
  need to know this. Note the limit of that trust: the default arbiter is one voter of three
  and can never move funds alone (§3.3A2).
- The default-arbiter Safe is load-bearing and **MUST be a distinct address from the marketplace
  owner** (ideally a multisig). A single key that both sets fees and arbitrates disputes is
  a total-compromise target. See §13.8.
- Any party can force platform arbitration for free by never agreeing — on an unsold escrow
  the Safe already holds the seat; on a sold one the fallback re-seats it after the window.
  This is an ops-load question, not a security hole, but plan for it: **the Safe signs in
  every contested dispute platform-wide** (agreed settlements never involve it, §3.3A2a),
  so signer responsiveness is an operational SLA — see §13.8.

**Knock-on changes to `EscrowContract`:**
- `initialize` **keeps** its arbiter parameter (the primary market is unchanged) but
  is **otherwise unchanged**: the nomination window is the `NOMINATION_WINDOW` constant, not
  a parameter (§3.3A1), so `initialize` keeps its original 8-argument signature and the
  factory ABI is untouched. Integrators repoint at the new addresses and change no call
  sites (§13.9).
- `transferRecipientFrom` additionally calls `_unseatArbiter()` after the role moves
  (§3.3A1a). `changeRecipient` does not.
- `raiseDispute` sets `nominationDeadline` when `ARBITER == address(0)` (§3.3A1a).
- `_checkAndExecuteConsensus` must not treat an unseated arbiter as a voter (§3.3D). Note
  `submitResolutionVote` itself needs **no** change on this account: it gates on
  `msg.sender != ARBITER`, and `msg.sender` can never be the zero address.
- `_transferRecipient` keeps its `newSeller == ARBITER` rejection — live whenever an arbiter
  is seated — and **gains** a `newSeller == DEFAULT_ARBITER` rejection, plus a reset of
  `nominatedByRecipient` (all three per §3.3A1a).
- `_executeResolution` must persist `resolvedBuyerPercentage` (§3.3C).

### 3.4 Launch precondition — a new implementation must ship first

**The marketplace has zero addressable inventory until a new `EscrowContract`
implementation is deployed.** This is a hard precondition, not a migration detail.

The implementation currently live on Base mainnet is
`0xCbfD53842f0ACc885a55b7A0eDb18eF5ac9237f9` (`DEPLOYMENT_ADDRESSES.md`), which predates
both §3.2 and §3.3. Every escrow in existence today is a clone of it, so every escrow in
existence today has a codehash that `EXPECTED_ESCROW_CODEHASH` will reject — correctly,
since none of them can perform the approve-and-pull swap. Clones are immutable; there is
no retrofit.

Launch therefore requires, in order:

1. Deploy the new `EscrowContract` implementation carrying **both** §3.2 (approve/pull)
   and §3.3 (sale-triggered arbiter reset, `resolvedBuyerPercentage` persistence).
   **Its constructor takes `DEFAULT_ARBITER`, which is baked into bytecode and can never be
   changed** — see the deploy-tooling note below.
2. Deploy the matching `EscrowContractFactory`, and repoint chainservice at it.
   (§13.9 — **the ABI is unchanged as of v0.7.0**, so this is an address change, not a
   call-site change.)
3. Deploy `MarketplaceEscrow` with `TRUSTED_IMPLEMENTATION` set to (1).
4. Record all three in `DEPLOYMENT_ADDRESSES.md`.

Inventory then accrues only from escrows created **after** step 2. The marketplace opens
empty and fills at the rate new escrows are written — worth knowing before any launch
messaging promises liquidity on existing deals.

| Contract | Address |
|---|---|
| `EscrowContract` implementation (new, §3.2 + §3.3) | `0x77acD2d342cF513A60e6d51ca5a36C93BD14A04B` ✅ deployed 2026-08-06 |
| `EscrowContractFactory` (new) | `0x575AB01251cfc4DB9Ce90A13152a7a616Bd304b9` ✅ deployed 2026-08-06 |
| `MarketplaceEscrow` | _pending — `script/DeployMarketplace.s.sol`, parameters below_ |
| **ERC-1167 codehash of the above implementation** | `0x5c1d3f7f01cbe7c3aa294f7f7d426ad766c7c99513eb563742964c4f22477644` |
| | |

**Deploy tooling (added v0.7.0).** Steps 1–2 run through GitHub Actions
(`.github/workflows/build.yml`, triggered by a `v*` tag → `production`, `test*` →
`test`), which invokes `script/DeploymentScript.s.sol`. `DEFAULT_ARBITER` is supplied as the
`DEFAULT_ARBITER_ADDRESS` environment **variable** (not a secret — the address is public) and
**must be set in both environments**.

The script has **no default** for it and refuses to run if it is unset, zero, equal to the
relayer/owner, or **has no deployed code on the target chain**. That last check is why a
`test*` deploy needs a **test Safe deployed on the testnet** — a Safe is a contract and
exists per-chain, so a mainnet address is empty on Sepolia. The script logs
`implementation.DEFAULT_ARBITER()` read back off the deployed contract, so the run output
proves what was actually baked in rather than echoing the input.

> Step 3 (`MarketplaceEscrow`) uses `script/DeployMarketplace.s.sol`, which is deliberately
> NOT tag-triggered — redeploying the marketplace would orphan live offers and unsettled
> holdbacks.
>
> ⚠️ **The deployed contracts are inert until chainservice repoints at them** — no escrow
> exists on the new factory until then. The repoint, not the deploy, is the point of no
> return. See **§15.4** for exactly what chainservice must change first.
| `DEFAULT_ARBITER` multisig ("stabledropAdmin" Safe, must differ from marketplace owner, §3.3) | `0x9bB8e809EA6F5A74f46027D8016641D9cE9A149C` ✅ (Safe v1.4.1 on Base, 2-of-3, no modules — verified 2026-08-05; **test transaction still pending**, nonce 0) |

---

## 4. Offer Lifecycle

```
LP deposits token → Offer created (OPEN)
        │
        ├─ Seller: escrow.approveRecipientTransfer(marketplace, lp)  (tx 1, on escrow, 5-min TTL)
        │  Seller: marketplace.acceptOffer(escrow, lp)            (tx 2, atomic swap)
        │        → role pulled to LP, seller paid, fee accrued, offer slot freed
        │        → all other OPEN offers on this escrow become STALE (recipient changed)
        │          and their LPs may withdraw in full
        │
        ├─ Seller rejects → CANCELLED → LP withdraws full amount
        │
        ├─ Offer expiry passes → LP withdraws full amount directly (no separate expire step)
        │
        └─ Escrow's recipient changes for any reason → offer is STALE → LP withdraws full amount
```

There is **no `expireOffer` and no `reclaimRecipient`**: expiry and staleness are evaluated lazily inside `withdrawFunds`, and the marketplace never holds the recipient role, so there is nothing to reclaim or restore.

---

## 5. Contract: the marketplace

> ## ⚠️ ARCHITECTURE CHANGED (v0.9.0, 2026-08-07) — read §5.0 first
>
> **The single pooled `MarketplaceEscrow` contract is gone.** It has been replaced by a
> **factory that deploys one `OfferVault` per offer**. The economics, validation, pricing,
> holdback semantics and lifecycle below are all UNCHANGED — but every statement about
> *where funds sit* and *which contract you call* is superseded by **§5.0**.
>
> Read §5.1–§5.3 and §6 for the rules, which still hold; read §5.0 for where they now live.

### 5.0 Per-offer vaults — the custody model

**Decision (2026-08-07): the marketplace must not pool user capital.** The pooled design
held every LP's deposit at one address, kept apart by per-(escrow, LP) accounting. That was
sound on its own terms — `sweepToken` could only ever reach genuine surplus, and
`withdrawFunds` was unpausable — but commingling unrelated users' funds at a
platform-deployed address is a custody question before it is a technical one, and the
answer is not ours to assume.

**Shape now, mirroring the escrow exactly:**

| | Contract | Holds |
|---|---|---|
| Venue | `OfferVaultFactory` | **nothing, ever** — validates, prices, deploys, and keeps the per-escrow registry |
| One per offer | `OfferVault` (ERC-1167 clone) | exactly one LP's capital, and later that offer's reserve |

- **Creation is permissionless and moves no money**, exactly like `createEscrowContract`:
  the LP is a **parameter**, not the caller, so chainservice deploys the vault on a user's
  behalf without gaining any power over the funds. A vault starts `PENDING` and empty.
- **Only the named LP can fund it** (`fund()`), with their own signature. Before that, the
  vault is an empty shell and no offer exists in any meaningful sense.
- **Every function answers to exactly one role**: `fund`/`withdraw` → the LP;
  `accept`/`reject` → the escrow's current recipient; `releaseHoldback` → the funder or the
  live beneficiary; `sweep` → the factory owner, and only above what the vault owes.
- **Fees are paid to `FEE_RECIPIENT` at acceptance**, not accrued. There is no pooled fee
  balance and therefore no owner-withdrawable balance anywhere in the system.
- **The seller's §3.2 approval names the individual vault** as operator, not a global venue
  — the narrowest authority the swap can be granted.

**The factory keeps NO per-escrow or per-offer state.** The one cross-offer fact — whether
an escrow has already been sold, which decides if a reserve may be set (§5.3) — lives on the
**escrow itself** as `hasBeenSold`, set by `transferRecipientFrom` and never by
`changeRecipient` (an OTC rotation is not a sale, the same line §3.3A draws for arbiter
unseating). Vaults read it straight from the escrow.

That makes the venue **fully redeployable**: a new factory reads the same truth off the same
escrows, with nothing to migrate and no way to lose the one-reserve guarantee. An earlier
revision of this design kept `hasBeenSold`/`holdbackVault` in the factory and carried exactly
that hazard — redeploying the venue would have allowed a second reserve to be stacked on an
escrow that already had one. The offer book is not kept on-chain either; `OfferCreated`
events are the index (§15.3 already put discovery off-chain).

⚠️ **This required a new escrow implementation**, since the flag is new storage. Backwards
compatibility was explicitly waived: escrows on `0x77acD2d…` become a third superseded
lineage, and chainservice repoints again. See `DEPLOYMENT_ADDRESSES.md`.

**What this costs.** A clone deploy per offer (~45k gas, well under a cent at current Base
prices), plus one redeploy of the escrow implementation and factory to carry the flag.

**What it buys.** No commingling; blast radius of one offer rather than all of them;
conservation checkable per contract instead of as a global invariant; and a narrower
approval at the swap.

> **Still open regardless (§13.15):** whether the *previous* design would have been
> permissible was never answered by counsel. This change makes the question moot for the
> marketplace, but the escrow model's own custody position remains counsel's to confirm.

### 5.1 State

```solidity
struct Offer {
    address escrowContract;   // The underlying escrow being sold
    address seller;           // recipient() at offer creation — offer is valid only while this holds
    address lp;               // LP wallet that made the offer
    address token;            // escrow.token() at creation; all transfers for this offer use it
    uint256 offerAmount;      // Gross amount deposited by LP (before fee and holdback)
    uint256 holdback;         // Reserve retained at acceptance, released later (§5.3)
    uint256 netAmount;        // Amount seller receives AT ACCEPTANCE (offerAmount − fee − holdback)
    uint256 fee;              // Protocol fee, computed at creation, accrued only on acceptance
    uint256 offerExpiry;      // Timestamp after which the LP may withdraw
    OfferStatus status;       // OPEN | CANCELLED
}

enum OfferStatus { NONE, OPEN, CANCELLED }   // NONE = empty slot (default)
// There is deliberately no COMPLETED state. An accepted offer's slot is deleted inside
// acceptOffer (§6.2) — the deposit has already left the contract, so there is nothing
// left to track, and a persisted COMPLETED would be write-only dead state that barred
// that (escrow, LP) pair from ever bidding again. Completion is recorded by the
// OfferAccepted event, which is where history belongs.

mapping(bytes32 => Offer) public offers;
// Key: keccak256(abi.encodePacked(escrowContract, lp))
// One LIVE offer record per (escrow, LP). The slot is freed on acceptance (§6.2) and on
// withdrawal (§6.4) — i.e. whenever the deposit is no longer held for that pair.

address public immutable TRUSTED_IMPLEMENTATION;        // the audited EscrowContract implementation
bytes32 public immutable EXPECTED_ESCROW_CODEHASH;       // ERC-1167 clone hash embedding it (§8.1)
uint256 public feeRateBps;                              // e.g. 100 = 1%; hard cap 1000 (10%)
uint256 public minOfferBps;                             // floor as bps of payoutAmount(); launch 1000 (10%); cap 10000
uint256 public defaultOfferDuration;                    // e.g. 24 hours; always > 0
mapping(address => uint256) public accruedFees;         // per-token protocol fees (§8.5)
mapping(address => uint256) public totalDeposits;       // per-token sum of live LP deposits (§8.6)
mapping(address => uint256) public totalHoldbacks;      // per-token sum of live holdbacks (§5.3)
```

### 5.1a Constructor

```solidity
constructor(address trustedImplementation, uint256 initialFeeRateBps, uint256 initialMinOfferBps, uint256 initialDefaultOfferDuration, address initialOwner)
```

- Require `trustedImplementation != address(0)`, `initialFeeRateBps <= 1000`, `initialMinOfferBps <= 10000`, `initialDefaultOfferDuration > 0`, `initialOwner != address(0)` (Ownable2Step initial owner).
- `EXPECTED_ESCROW_CODEHASH = keccak256(abi.encodePacked(hex"363d3d373d3d3d363d73", trustedImplementation, hex"5af43d82803e903d91602b57fd5bf3"))` — the ERC-1167 minimal-proxy runtime code that OpenZeppelin `Clones` deploys, with the implementation address embedded.

There is **no offer-enumeration array**. Competing offers are invalidated lazily by the staleness rule, so no O(N) cancellation loop exists (removes the sybil gas-DoS on `acceptOffer`).

### 5.2 Key Invariants

1. **Slot integrity:** `createOffer` requires the (escrow, lp) slot to be `NONE`. **A slot is occupied exactly while the contract still holds that LP's deposit for that escrow**, and is freed the moment it does not — on acceptance (§6.2, funds paid out) or on withdrawal (§6.4, funds returned). A cancelled/expired-but-unwithdrawn offer therefore still owns its slot and its deposit and can never be overwritten; an accepted one does not. This keeps re-bidding possible: an LP who bought an escrow and later resold it may bid on it again.
2. **Sellable escrow only:** the escrow must be **verifiably genuine** (`escrow.codehash == EXPECTED_ESCROW_CODEHASH` — unforgeable, unlike any self-reported value), funded, undisputed, unclaimed, non-instant (`maturity() != 0`), and `offerExpiry < maturity()`.

   Genuineness is checked **once, at `createOffer`**. It is deliberately *not* re-checked at `acceptOffer`: a deployed clone's codehash is immutable, and a minimal proxy has no `SELFDESTRUCT` path, so the value cannot change between the two calls — re-reading it would be pure gas. The mutable conditions (funded / undisputed / unclaimed / live seller) *are* re-checked at acceptance, because those genuinely can change.
3. **Live seller:** an offer is acceptable only while `escrow.recipient() == offer.seller` and only by that address. Any recipient change makes every existing offer on that escrow permanently stale (withdrawable, never acceptable). Payment always goes to `msg.sender == offer.seller == recipient()` — a stale snapshot can never be paid.
4. **Minimum offer:** `offerAmount >= max(escrow.payoutAmount() * minOfferBps / 10000, 1)` — never zero even at `minOfferBps == 0` (guards the dust edge where the product rounds to 0).

   `minOfferBps` is **owner-configurable** (§6.5), launching at **1000 (10%)**, hard cap 10000. The floor is a spam guard, not a price policy: with no enumeration array a dust offer harms nothing on-chain (it occupies only its own slot and locks the spammer's own capital), so the real cost of a high floor is banning deep-discount bids — which §8.1a shows are the *safest* trades for LPs (attacker profit scales with `r − d`). An earlier fixed 50% floor was rejected for exactly that reason. Changes apply to **new offers only**; a live offer was validated at creation and its terms are firm.
4a. **Firm quotes:** an LP **cannot cancel their own OPEN offer**. Offers are irrevocable commitments until expiry/rejection/staleness — otherwise an LP could bait with a high offer and front-run the seller's `acceptOffer` with a cancellation. LPs control their exposure via `offerDurationSeconds`.
5. **Fee containment:** protocol fees accrue to `accruedFees[token]` only at acceptance. `withdrawFees` is capped by `accruedFees[token]` — the owner can never touch LP deposits. Cancelled/expired/stale offers refund the **full gross** amount including the computed fee.
6. **No custody:** the marketplace address is never the escrow recipient at rest. The role moves seller → LP within a single `acceptOffer` transaction.
7. **Conservation:** for every token, `balanceOf(marketplace) >= totalDeposits[token] + accruedFees[token] + totalHoldbacks[token]` (excess = accidental transfers, sweepable §8.7).
8. **Holdback segregation:** a reserve is owed to either its funder or the escrow's current recipient and to nobody else. It is never withdrawable by the owner, never counted in `accruedFees`, and is settled exactly once. `toFunder + toRecipient == amount` — settlement redistributes the reserve, it never creates or destroys value.
9. **One reserve per escrow, set on the first sale only.** A resale neither creates nor releases one; the existing reserve follows the position because its beneficiary is read live at settlement (§5.3).
10. **Pause asymmetry — exits are never pausable.** `whenNotPaused` guards exactly two functions: `createOffer` and `acceptOffer` (the inflows). `withdrawFunds`, `releaseHoldback`, and `rejectOffer` MUST carry no pause check, ever — a paused marketplace is one where nothing new starts but every LP recovers every deposit and every holdback still settles. The pause is a stop button, structurally incapable of being a seize button: even a malicious owner pausing forever produces only a dead venue from which everyone exits whole.

### 5.3 Residual holdback

Invoice-factoring semantics: the LP advances part of the agreed price and retains a
**holdback**, released to the party who funded it once the cashflow is collected. If the
cashflow is impaired, the holdback covers the current holder's loss first. It is funded out
of the **original seller's proceeds** — it never touches the buyer's refund rights and needs
no buyer consent.

> **Terminology.** **Holdback** is the canonical name and matches the code (`Holdback`,
> `releaseHoldback`); *reserve* is used interchangeably in prose, and *residual* means the
> same thing where it survives from earlier drafts. The parties are named precisely, because
> "seller" is ambiguous once an escrow has been resold:
>
> - **funder** — the original seller, the supplier who performs the work and out of whose
>   proceeds the holdback is retained. Fixed at the first sale.
> - **beneficiary** — `escrow.recipient()` read at settlement, i.e. whoever holds the
>   cashflow at the end. After a resale this is **not** the LP who set the holdback.

```solidity
struct Holdback {
    address token;
    address funder;      // the seller in the escrow's FIRST marketplace sale
    uint256 amount;
}
mapping(address => Holdback) public holdbacks;    // ONE per escrow
mapping(address => bool)     public hasBeenSold;  // set on first acceptance; blocks stacking
```

> Precision on `funder`: the contract records the seller of the escrow's first *marketplace*
> sale. In the normal case that is the original supplier; if the position reached the
> marketplace via an OTC `changeRecipient` first, it is that OTC holder — the marketplace
> cannot tell the difference and does not need to. Whoever chooses to sell first under a
> holdback accepts the funder role as a term of their sale.

**The beneficiary is deliberately not stored.** It is `escrow.recipient()`, read live at
settlement. The reserve therefore **follows the position automatically**: when LP1 sells to
LP2, nothing is created, released, or reassigned — LP2 simply becomes the party the reserve
protects, and LP1 exits flat. There is no state to keep in sync and no action required on a
resale.

**The reserve is set once, on the first sale, and only there.** `holdback` is a field of the
LP's bid — different LPs have different risk appetites and the advance rate is part of what
they quote — but `createOffer` rejects a non-zero holdback once `hasBeenSold[escrow]` is
true (§6.1.8).

**Why only the first sale: the reserve is recourse against the party who performs.** The
supplier did the work. If the buyer disputes and wins, it is because the supplier did not
deliver, so the supplier bearing first loss is exactly right — this is recourse factoring.
A reselling LP performed nothing. If the buyer wins, that is still the *supplier's* failure;
LP1 is no more culpable than LP2, so "LP1 funds LP2's first loss" does not follow from the
logic that makes the original reserve sensible. Instead the original reserve travels with the
cashflow it protects, and the supplier stays on the hook regardless of who holds the paper.

**Settlement — two payments, two contracts.** The cashflow itself never passes through the
marketplace: the escrow pays its recipient directly, and the marketplace settles only the
holdback. A complete payout is therefore two independent, permissionless transactions, and
neither blocks the other. Writing `L = payoutAmount × b / 100` for the buyer's award:

| | Escrow pays (`claimFunds` / `_executeResolution`) | Marketplace pays (`releaseHoldback`) |
|---|---|---|
| **Undisputed** | full `payoutAmount` → beneficiary | full holdback → funder |
| **Disputed, `b`% to buyer** | `L` → buyer; remainder → beneficiary | `min(holdback, L)` → beneficiary; remainder → funder |

Read the rows together for the economic picture: undisputed, the beneficiary collects the
whole cashflow and the funder gets their holdback back; disputed, the beneficiary is made
whole out of the holdback up to its size, and only what it cannot cover is a real loss to
them.

**Effect on the §8.1a attack.** The reserve is not sized as a deterrent (§3.3A does that
job), but it does subtract directly from attacker profit, which becomes `P(r − d) − R`
rather than `P(r − d)` — the attacker is the supplier, so they forfeit the reserve in exactly
the scenario they are engineering, and forfeit it to whoever holds the position at the end.

> **Deferred: seller skin-in-the-game on resale.** A reselling LP may know something the buyer
> does not — that a dispute is imminent — and a reserve retained from *them* would be
> adverse-selection protection rather than performance recourse. That is a different
> instrument that happens to share a shape, and it is **out of scope for v1**. Note the
> general form (a reserve per sale, settling as a waterfall in which each level's loss is the
> level above's payout) is a strict superset of what is specified here, so adding it later
> forecloses nothing. See §13.5.

---

## 6. Functions

> **⚠️ Where these now live (v0.9.0, §5.0).** The rules, validation order, pricing and
> economics below are unchanged and authoritative. What changed is the contract you call:
>
> | Spec function | Now on | Caller |
> |---|---|---|
> | §6.1 `createOffer` | `OfferVaultFactory` — takes `lp` as a **parameter**, deploys a vault, **moves no money** | anyone (chainservice in practice) |
> | — `fund` *(new)* | `OfferVault` — pulls the capital | the named LP only |
> | §6.2 `acceptOffer` → `accept` | `OfferVault` | the escrow's current recipient |
> | §6.3 `rejectOffer` → `reject` | `OfferVault` | the escrow's current recipient |
> | §6.4 `withdrawFunds` → `withdraw` | `OfferVault` | that offer's LP |
> | §6.7 `releaseHoldback` | `OfferVault` | the funder or the live beneficiary |
> | §6.5 owner surface | `OfferVaultFactory` | owner — **`withdrawFees` is gone**; fees pay out at acceptance |
> | §6.6 `sweepToken` | both — factory sweeps its whole balance (it should have none); a vault sweeps only above what it owes | owner |

### 6.1 `createOffer`

```solidity
function createOffer(
    address escrowContract,
    uint256 offerAmount,
    uint256 holdback,              // reserve retained at acceptance (§5.3); 0 = advance in full
    uint256 offerDurationSeconds   // 0 = use defaultOfferDuration
) external nonReentrant whenNotPaused   // NOT payable — this is an ERC20 contract
```

**Logic:**

1. Require `escrowContract.codehash == EXPECTED_ESCROW_CODEHASH` (revert `UntrustedEscrow`). This is checked against the EVM's own record of the deployed code — a hostile contract cannot fake it, unlike a self-reported `FACTORY()` value. It also rejects EOAs and the raw implementation itself.
2. Derive key `keccak256(abi.encodePacked(escrowContract, msg.sender))`; require `offers[key].status == NONE` (revert `OfferSlotOccupied`).
3. Require `maturity() != 0` (revert `InstantEscrowNotSupported`).
4. Require sellable: `isFunded() && !hasActiveDispute() && !isClaimed()` (revert `EscrowNotSellable`). Protects the LP from offering on unfunded or already-settled escrows.
5. `offerExpiry = block.timestamp + (offerDurationSeconds == 0 ? defaultOfferDuration : offerDurationSeconds)`; require `offerExpiry < maturity()` (revert `OfferExpiryExceedsEscrowMaturity`).
6. `seller = escrow.recipient()`; require `msg.sender != seller && msg.sender != BUYER() && msg.sender != ARBITER()` (revert `LpCannotBeEscrowParty`) — the escrow re-checks buyer/arbiter at the pull; this is a clean early error.
7. Require `offerAmount >= max(escrow.payoutAmount() * minOfferBps / 10000, 1)` (revert `OfferBelowMinimum`).
8. `fee = offerAmount * feeRateBps / 10000`; require `fee + holdback <= offerAmount` (revert `HoldbackExceedsOffer`); `netAmount = offerAmount − fee − holdback`.

   Additionally require `holdback == 0` if `hasBeenSold[escrowContract]` (revert `HoldbackOnResale`) — a reserve may only be set on an escrow's **first** sale, because it is recourse against the party who performs (§5.3). A resale passes the existing reserve on untouched.

   No cap is placed on `holdback` beyond that. It is self-limiting because the **seller must actively accept it** — an LP quoting a 90% holdback is quoting a 10% advance, which the seller sees in the offer and simply will not accept. (Note this is a genuinely different situation from the escrow's nomination window, whose per-escrow form was removed precisely because no such consent step existed — see §3.3A1.) The discipline here comes from the **seller**, who is the party whose proceeds fund it.
9. `token = escrow.token()`. Pull deposit with a **balance-delta check**: measure `balanceOf(this)` before/after `safeTransferFrom(msg.sender, this, offerAmount)`; require delta `== offerAmount` (revert `TransferAmountMismatch`) — rejects fee-on-transfer tokens, mirroring the escrow's own deposit guard.
10. `totalDeposits[token] += offerAmount`. Store `Offer{..., status: OPEN}`.
11. Emit `OfferCreated(escrowContract, msg.sender, seller, token, offerAmount, netAmount, fee, holdback, offerExpiry)`.

### 6.2 `acceptOffer`

```solidity
function acceptOffer(address escrowContract, address lp) external nonReentrant whenNotPaused
```

**Pre-condition (tx 1, seller, on the escrow):** `escrow.approveRecipientTransfer(marketplace, lp)` — binds the operator AND the exact LP, valid 5 minutes. Without it (or after expiry), step 6 reverts and nothing moves; the seller simply re-approves.

**Logic (tx 2 — checks → effects → interactions):**

1. Load offer; require `status == OPEN` (revert `OfferNotOpen`).
2. Require `block.timestamp <= offer.offerExpiry` (revert `OfferExpired`).
3. `seller = escrow.recipient()` (live read). Require `msg.sender == seller` (revert `NotEscrowRecipient`) and `seller == offer.seller` (revert `OfferStale`).
4. Require sellable: `isFunded() && !hasActiveDispute() && !isClaimed()` (revert `EscrowNotSellable`).
4a. **Re-check the holdback rule:** require `offer.holdback == 0 || !hasBeenSold[escrowContract]` (revert `HoldbackOnResale`). **This is not redundant with §6.1.8.** `hasBeenSold` can flip between an offer's creation and its acceptance, and this offer's holdback was validated against the value at *creation* time. Two LPs may both bid with a holdback while an escrow is unsold (both legal); the seller accepts the first, recording the one permitted reserve; if the position then returns to that same seller — a direct `changeRecipient` back, or the seller buying their own cashflow back as an LP, which they may do because after the first sale they are no longer the recipient — the second offer becomes live again and accepting it would **overwrite `holdbacks[escrow]` while still adding to `totalHoldbacks`**, stranding the first reserve permanently. See §0.4c H-1.
5. **Effects:** cache `(token, offerAmount, netAmount, fee, holdback)` into locals **first** — this step deletes the struct, so every later step must read the locals, not `offer`. Then: `totalDeposits[token] −= offerAmount`; `accruedFees[token] += fee`; `delete offers[key]`.

   Then `hasBeenSold[escrowContract] = true`. If `holdback > 0` (guaranteed a first sale by step 4a, *not* by §6.1.8 alone): store `Holdback{token, funder: seller, amount: holdback}` and `totalHoldbacks[token] += holdback`. Nothing is written on a resale — the existing reserve already follows the position, since its beneficiary is read live (§5.3).

   The `delete` is what marks the offer consumed — the slot reads `NONE`, so a re-entrant `acceptOffer` fails the `status == OPEN` check at step 1. No `COMPLETED` state is written: it would be dead state that permanently barred this (escrow, LP) pair from bidding again (§5.1). Conservation holds because `netAmount + fee + holdback == offerAmount`.
6. **Interactions:**
   a. `escrow.transferRecipientFrom(lp)` — pulls the role directly seller → LP using the one-shot approval. The escrow enforces lp ≠ zero/buyer/arbiter, resets the LP's dispute vote, and **unseats the incumbent arbiter** (§3.3A).
   b. `token.safeTransfer(seller, netAmount)` — **skipped when `netAmount == 0`**, which is reachable when the LP quotes a holdback consuming the whole offer. Some ERC20s revert on zero-value transfers, which would otherwise make such an offer permanently unacceptable (§0.4c L-1).
7. Emit `OfferAccepted(escrowContract, lp, seller, netAmount, fee, holdback)`. With no holdback this event is the **only** record that the sale happened; with one, the `Holdback` record survives until §6.7 settles it.

All other OPEN offers on this escrow are now stale (`recipient()` changed) — each LP withdraws their full gross deposit via `withdrawFunds`. No loop, no gas ceiling, no event storm.

### 6.3 `rejectOffer`

```solidity
function rejectOffer(address escrowContract, address lp) external nonReentrant
```

1. Require `status == OPEN`; require `msg.sender == offer.seller` and `escrow.recipient() == offer.seller` (only the current recipient may reject — a stale offer needs no rejection, it is already withdrawable).
2. `offer.status = CANCELLED`. Emit `OfferRejected(escrowContract, lp)`.

> The slot is **not** freed here — the contract still holds the LP's deposit, so it must keep tracking it (§5.2.1). The LP calls `withdrawFunds` to recover the deposit and free the slot. Consequence: an LP who wants to re-bid higher after a rejection needs three transactions (reject → withdraw → new offer). Acceptable for v1; see §13.11.

### 6.4 `withdrawFunds`

```solidity
function withdrawFunds(address escrowContract) external nonReentrant
```

1. Key = (escrowContract, `msg.sender`). Withdrawable iff:
   - `status == CANCELLED`, **or**
   - `status == OPEN &&` any of:
     - `block.timestamp > offerExpiry` (expired), or
     - `escrow.recipient() != offer.seller` (stale — recipient changed), or
     - `escrow.hasActiveDispute() || escrow.isClaimed()` (escrow permanently unacceptable: a dispute can only resolve to settled — state 2 never returns to state 1 — so the offer can never be accepted again; the LP exits immediately instead of waiting out `offerExpiry`), or
     - `offer.holdback > 0 && hasBeenSold[escrowContract]` (also permanently unacceptable: §6.2.4a will always reject it, since only an escrow's first sale may set a reserve. Without this the LP's capital would sit locked until expiry for an offer that can never be taken).
   Otherwise revert `NothingToWithdraw`. No withdrawable offer is ever simultaneously acceptable (acceptance rejects every one of these conditions), so there is no accept/withdraw race.
2. **Effects first (CEI):** cache `(token, offerAmount)`; `totalDeposits[token] −= offerAmount`; `delete offers[key]` — freeing the slot for a future offer (invariant 1).
3. `token.safeTransfer(msg.sender, offerAmount)` — full gross, including the never-accrued fee.
4. Emit `FundsWithdrawn(escrowContract, msg.sender, token, offerAmount)`.

### 6.5 Owner functions (Ownable2Step)

```solidity
function setFeeRate(uint256 newFeeRateBps) external onlyOwner;          // require <= 1000 (10% cap); applies to NEW offers only
function setMinOfferBps(uint256 newMinOfferBps) external onlyOwner;     // require <= 10000; applies to NEW offers only (§5.2.4)
function pause() external onlyOwner;                                    // OZ Pausable — halts createOffer + acceptOffer ONLY
function unpause() external onlyOwner;
function setDefaultOfferDuration(uint256 durationSeconds) external onlyOwner; // require > 0 (a 0 default would make offers expire at creation)
function withdrawFees(address token, address to, uint256 amount) external onlyOwner;
// require amount <= accruedFees[token]; decrement before transfer. LP deposits are unreachable.
```

### 6.6 `sweepToken` — ships in v1

```solidity
function sweepToken(address token, address to) external onlyOwner nonReentrant
```

Recovers tokens accidentally transferred straight to the marketplace address (a routine
occurrence for any well-known contract). Sweeps only the **excess** of a token above
`totalDeposits[token] + accruedFees[token] + totalHoldbacks[token]`; reverts
(`NothingToSweep`) when the books and the balance agree. Structurally incapable of touching
live deposits, accrued fees, or holdbacks — the subtraction excludes everything the contract
owes anyone (invariant §5.2.7). Not pausable (it is an owner recovery path, not an inflow).
Emits `TokenSwept(token, to, amount)`.

### 6.7 `releaseHoldback`

```solidity
function releaseHoldback(address escrowContract) external nonReentrant
```

Permissionless and single-shot — it takes no discretion, and both destinations are fixed by
the escrow's own final state. Anyone may trigger it; the funds can only reach the recorded
funder and the escrow's current recipient.

1. Load `h = holdbacks[escrowContract]`; require `h.amount > 0` (revert `NoHoldback`).
2. Require the escrow has **finally settled**: `escrow.isClaimed()` (revert `EscrowNotSettled`). This covers both terminal paths — claimed at maturity and dispute-resolved — because `_executeResolution` also sets `_state = 4`. An escrow still funded or still disputed is not settleable, and reverting keeps the reserve in place until the outcome is known.
3. `beneficiary = escrow.recipient()` — read **live**, so the reserve lands on whoever holds the position, no matter how many times it changed hands (§5.3).
4. Read `b = escrow.resolvedBuyerPercentage()` (§3.3C) and split:
   ```
   loss        = (b == 255) ? 0 : escrow.payoutAmount() * b / 100
   toRecipient = min(h.amount, loss)
   toFunder    = h.amount − toRecipient
   ```
5. **Effects first (CEI):** cache `(token, funder, amount, toRecipient, toFunder)`; then `totalHoldbacks[token] −= amount`; `delete holdbacks[escrowContract]`. The delete is what makes this single-shot — a second call finds `amount == 0` and reverts.
6. Transfer `toRecipient` to the beneficiary and `toFunder` to the funder, skipping zero-value transfers (one side is zero in the common cases).
7. Emit `HoldbackReleased(escrowContract, h.funder, beneficiary, toFunder, toRecipient)`.

> **Read the beneficiary, never store it.** Storing it at sale time would need reassigning on
> every resale, and any missed path — a direct `changeRecipient`, say — would strand the
> reserve on a party who no longer holds the cashflow. Reading `recipient()` at settlement is
> correct by construction for every transfer route.

> **`payoutAmount()` is read at settlement, not snapshotted at sale.** It is derived from
> `AMOUNT − CREATOR_FEE`, both immutable after `initialize`, so it cannot drift. Reading it
> late avoids storing a redundant copy per holdback.

**Liveness note.** A holdback is only releasable once the escrow reaches `_state == 4`. Since
§3.3A2 removes the resolution deadline, a dispute that never resolves leaves the reserve
locked alongside the escrow itself. That is the same freeze surface as §3.3A3.2 and has the
same remedy (`evictArbiter`, §3.3A1a) — it is not a separate risk, but it does mean the
holdback inherits the escrow's liveness rather than having its own.

---

## 7. Removed from v0.2 (and why)

| Removed | Reason |
|---|---|
| `expireOffer` | Expiry handled lazily in `withdrawFunds`. The old auto-restore of the recipient was a griefing vector (anyone could yank the role mid-acceptance) and used a stale seller snapshot. |
| `reclaimRecipient` | No custody → nothing to reclaim. (The old version also dead-locked: it required an OPEN offer, so a seller whose offers had all expired could never recover the role.) |
| `escrowOfferLPs[]` enumeration + O(N) auto-cancel in `acceptOffer` | Sybil dust offers could push cancellation past the block gas limit and block all acceptances. Lazy staleness invalidation needs no iteration. |
| `OfferStatus.EXPIRED`, `OfferStatus.BLOCKED` | EXPIRED is now a lazy predicate, not a stored state; BLOCKED was declared and never used. |
| `payable` on `createOffer` | ERC20-only contract; stray ETH would be locked. |
| Global USDC assumption (§8 old) | The escrow supports any ERC20; offers are denominated in `escrow.token()` per offer, fees accounted per token. |

---

## 8. Design Notes

1. **Provenance (codehash, not self-report):** the marketplace verifies `escrow.codehash == EXPECTED_ESCROW_CODEHASH` — the ERC-1167 minimal-proxy bytecode embedding the trusted implementation. This is read from the EVM's record of deployed code, which a hostile contract cannot forge. (v0.4 originally specified checking `escrow.FACTORY() == TRUSTED_FACTORY`, which asked the escrow to vouch for itself — a fake contract could return the real factory's address, report a fake `payoutAmount()`/`recipient()`, accept a real-token deposit from an LP, and no-op the role transfer. Fixed in v0.4.2.) The factory is permissionless, so anyone can create a genuine escrow — genuineness of *code* plus the funded-state gate (real tokens actually deposited) is the security property, not who created it. **This is necessary but not sufficient: genuine code says nothing about collusive parties — see §8.1a.**
1a. **The self-dealt escrow — why the codehash alone is not enough.** `EscrowContract.initialize()` is permissionless: any caller becomes `FACTORY`. Because §8.1 verifies only *code*, an attacker can `Clones.clone` the trusted implementation directly, bypass the factory entirely, and initialize with parameters of their choosing — the only constraint being that buyer, seller and arbiter are three distinct addresses, which costs them nothing.

   The attack: clone and initialize with buyer and arbiter wallets you control and yourself as seller; fund it with real tokens so it passes the funded/undisputed/unclaimed gate; list it; an LP buys the cashflow at a discount; your "buyer" then disputes and buyer + arbiter vote 2-of-3 for a full refund. You recover the deposit and keep the LP's payment. The dispute window is open for the entire offer life, because `offerExpiry < maturity()` is required.

   This is a **profitable, repeatable attack, not a pricing problem.** With deposit `D`, payout `P ≈ D`, LP discount `d` and refund fraction `r`:

   > profit = `P(1−d) + rP − P` = **`P(r − d)`**

   Two things follow. First, capping the buyer's *refund* cannot fix this: it is unprofitable only when `r < d`, i.e. the cap must sit *below* the LP's discount — at a realistic 10% discount that means capping honest buyers' refunds under 10%, gutting legitimate dispute protection for everyone to deter a marketplace-specific attack. That approach was specified and abandoned; the residual became a seller-funded holdback instead (§5.3), which subtracts from attacker profit directly — `P(r − d) − R` — without touching any buyer's refund rights. Second, attacker profit scales with `(r − d)`, so **deeper discounts are inherently safer for LPs** — a useful property to surface in the UI.

   **What §3.3A does and does not close.** The attack requires a pre-loaded attacker-controlled arbiter still in office when the dispute fires; unseating the arbiter automatically at every sale — with re-seating requiring the new recipient's matching nomination and a default-arbiter fallback — makes that 2-of-3 majority unmanufacturable — the *corrupt arbiter* variant is dead. What remains is the ordinary risk that an arbiter rules wrongly on the merits, which is true of every arbitration in every system and is not specific to this design. It bites harder here only because of the evidence asymmetry noted in §11: the LP was never party to the underlying deal. The LP's levers are care in agreeing an arbiter, the holdback, and short-dated purchases.

2. **Atomicity:** the marketplace holds the recipient role for zero blocks. Every custody-window failure mode (dispute payout landing on the marketplace, maturity claim landing on the marketplace, stranded role) is structurally impossible rather than handled.
3. **One-shot approval:** consumed on use, cleared on any recipient change, revocable by approving `address(0)`. An approval can never be replayed or survive a seller change.
4. **Staleness over enumeration:** `recipient()` is the single source of truth. Any change of recipient — sale through this marketplace, direct `changeRecipient`, resale by an LP — automatically invalidates all outstanding offers without touching them.
5. **Fee accounting:** `accruedFees[token]` is the only balance the owner can withdraw. Refunds are always full-gross, so an LP never pays a fee on a deal that didn't happen.

5a. **Fee incidence — the seller pays.** An LP bidding `X` transfers `X` and the seller receives `X − fee − holdback` at acceptance (the holdback returns to them at settlement if the cashflow collects in full, §5.3; the fee never does). The fee travels inside the LP's deposit but comes out of the seller's proceeds. **This must be surfaced in the UI at bid entry and at acceptance**, or a seller who sees "offer: 10,000" and receives 9,900 will read it as a bug. Two consequences: (a) an LP's headline bid overstates what the seller actually nets, so bids are not directly comparable to `payoutAmount()` without deducting the fee; (b) because `fee` is snapshotted at `createOffer`, a later `setFeeRate` never changes what a live offer pays out — the seller's quote is firm from the moment the offer appears. The alternative convention (LP deposits `offerAmount + fee`, seller receives `offerAmount` in full) is economically equivalent once LPs adjust their bids; it was considered and **rejected — seller-pays is confirmed** (§13.10): simplest to implement, and LPs price it into their bids. The fee here is the **marketplace** fee (§13.1, expected 25–50 bps) — distinct from the 1% creation fee the escrow already collected at deposit.
6. **`totalDeposits[token]`** exists to enforce invariant 7 and to make `sweepToken` safe; it is not consulted in the hot path beyond ±= updates.
7. **Resale supported naturally:** an LP who acquired the role is simply the new `recipient()`; new offers snapshot them as seller and the same flow applies. This is also why acceptance frees the offer slot (§5.2.1): a persisted `COMPLETED` would bar an LP from ever bidding on an escrow they had previously bought and resold, quietly capping resale to one round-trip per address.

---

## 9. Events

```solidity
event OfferCreated(address indexed escrowContract, address indexed lp, address indexed seller, address token, uint256 offerAmount, uint256 netAmount, uint256 fee, uint256 holdback, uint256 offerExpiry);
event OfferAccepted(address indexed escrowContract, address indexed lp, address indexed seller, uint256 netAmount, uint256 fee, uint256 holdback);
event HoldbackReleased(address indexed escrowContract, address indexed funder, address indexed beneficiary, uint256 toFunder, uint256 toBeneficiary);
event OfferRejected(address indexed escrowContract, address indexed lp);
event FundsWithdrawn(address indexed escrowContract, address indexed lp, address token, uint256 amount);
event FeeRateUpdated(uint256 newFeeRateBps);
event MinOfferUpdated(uint256 newMinOfferBps);
event DefaultOfferDurationUpdated(uint256 durationSeconds);
event FeesWithdrawn(address indexed token, address to, uint256 amount);
event TokenSwept(address indexed token, address to, uint256 amount);   // §6.6
```

On the escrow (implemented): `RecipientTransferApproved(address indexed operator, address indexed newRecipient, uint256 expiry)`; `RecipientChanged` already existed.

On the escrow (§3.3, implemented ✅):

```solidity
event ArbiterUnseated(address indexed previousArbiter);
event ArbiterNominated(address indexed nominator, address indexed candidate);
event ArbiterSeated(address indexed arbiter, bool byAgreement);
event ArbiterEvicted(address indexed previousArbiter);

error NotDisputeParty(address caller);
error ArbiterAlreadySeated(address arbiter);
error NoArbiterSeated();
error ArbiterNotSilent(uint256 lastActionAt);
error NominationWindowStillOpen(uint256 deadline);
error InvalidArbiterCandidate(address candidate);
error PartyCannotBeDefaultArbiter();        // §0.4 deviation 3 — buyer/seller may not BE the fallback
error InvalidDefaultArbiterAddress();       // implementation constructor rejects address(0)
// note: there is no NominationWindowClosed — late matches remain seatable until the
// fallback actually executes (§3.3A1a); the deadline only enables seatDefaultArbiter
// note: there is no NominationWindowTooLong either — the window is a constant (§3.3A1),
// so there is no caller-supplied value left to validate
```

## 10. Errors

```solidity
error UntrustedEscrow(address escrowContract);
error OfferSlotOccupied(address escrowContract, address lp);
error OfferNotOpen(address escrowContract, address lp);
error OfferExpired(address escrowContract, address lp);
error OfferStale(address escrowContract, address lp);        // recipient changed since creation
error NotEscrowRecipient(address caller);
error EscrowNotSellable(address escrowContract);              // unfunded, disputed, or claimed
error InstantEscrowNotSupported(address escrowContract);
error OfferExpiryExceedsEscrowMaturity(uint256 offerExpiry, uint256 maturity);
error OfferBelowMinimum(uint256 offerAmount, uint256 minimum); // < payoutAmount() × minOfferBps / 10000
error MinOfferTooHigh(uint256 requested, uint256 max);         // setMinOfferBps > 10000
error LpCannotBeEscrowParty(address lp);
error TransferAmountMismatch();                                // fee-on-transfer token rejected
error NothingToWithdraw(address escrowContract, address lp);
error HoldbackExceedsOffer(uint256 holdback, uint256 fee, uint256 offerAmount);
error HoldbackOnResale(address escrowContract);    // a reserve may only be set on the first sale
error NoHoldback(address escrowContract);          // none exists, or already settled
error EscrowNotSettled(address escrowContract);
error FeeTooHigh(uint256 requested, uint256 max);              // constructor AND setFeeRate
error InsufficientAccruedFees(address token, uint256 requested, uint256 available);

// Constructor / owner-input validation (§5.1a, §6.5)
error ZeroAddress();                                           // implementation, owner, or `to`
error ZeroOfferDuration();                                     // constructor and setDefaultOfferDuration
error NothingToSweep(address token);                           // §6.6
```

---

## 11. Security Considerations

| Risk | Mitigation |
|---|---|
| Reentrancy (arbitrary ERC20s may have hooks) | `nonReentrant` on every state-mutating external function (**mandatory**, not optional) + strict checks-effects-interactions everywhere. |
| Bug discovered in live contract | Emergency pause on inflows (`createOffer`, `acceptOffer`) bounds the damage to existing state; exits (`withdrawFunds`, `releaseHoldback`, `rejectOffer`) are structurally unpausable, so LPs always recover deposits and holdbacks always settle (§5.2.10). Pause abuse is bounded to killing the venue — it can never trap funds. |
| Owner drains LP deposits | Structurally impossible: `withdrawFees` capped by `accruedFees[token]`; deposits tracked separately. |
| Custody-window failures (dispute/maturity payouts landing on marketplace, stranded role) | Eliminated by design — the marketplace is never the recipient (§8.2). |
| Stale-seller payment/restore theft | Eliminated — acceptance requires live `recipient() == offer.seller == msg.sender`; payment goes to the live recipient; no restore path exists. |
| Sybil offer spam gas-DoS on acceptance | No cancellation loop (lazy staleness); 50%-of-payout minimum makes spam capital-intensive. |
| Deposit-slot overwrite | `createOffer` requires an empty (`NONE`) slot; slots free only on withdrawal. |
| Fee-on-transfer / deflationary tokens | Balance-delta check on deposit (revert), mirroring the escrow. |
| Malicious escrow contract | ERC-1167 codehash check — only clones of the trusted implementation are accepted; deployed code cannot be forged. A self-reported value (e.g. `FACTORY()`) is never trusted. |
| **Self-dealt escrow** (attacker controls buyer + arbiter, sells to an LP, then disputes for a full refund) | The codehash check cannot catch this — the code *is* genuine; only the parties are collusive (§8.1a). Closed by §3.3A: every sale automatically unseats the incumbent arbiter, and re-seating requires the new recipient's matching nomination with a default-arbiter fallback — so buyer + arbiter can never be pre-loaded into a 2-of-3 majority. An LP can never buy into a disputed escrow (§6.1.4, §6.2.4), so they are never bound by a selection made before they arrived. Attacker profit is additionally reduced by the §5.3 holdback — the attacker is the seller, so they forfeit the reserve in precisely the scenario they are engineering. |
| Arbiter-selection deadlock / stonewalling | Refusing to agree does not freeze funds and does not revert to an attacker-chosen arbiter — it falls back to the default arbiter (§3.3A). Free to trigger, so treat platform arbitration as the common path for ops-capacity planning. |
| Default-arbiter compromise | **Residual risk.** The fallback arbiter can form a 2-of-3 majority on any unsettled sold-escrow dispute. MUST be a multisig, distinct from the marketplace owner (§3.3E, §13.8). |
| LP bait-and-switch (cancel at acceptance) | Impossible: LPs cannot cancel OPEN offers (§5.2.4a firm quotes); their exposure window is the duration they chose. |
| Blacklistable tokens (e.g. USDC) | **Accepted residual risk:** if the marketplace address were blacklisted by a token issuer, deposits in that token would be stuck until unblacklisted. Not fixable on-chain; scope of harm is one token's live offers. |
| **LP inherits dispute risk (disclose!)** | After acceptance the LP is the escrow's seller-side party: the buyer can still dispute before maturity, and a 2-of-3 vote can go against the LP up to a full buyer refund. §3.3A gives the LP a **veto over who arbitrates**, so the counterparty cannot both dispute and judge, and the §5.3 holdback means the seller absorbs first loss — but an honest arbiter may still rule against the LP on the merits. Inherent to buying the cashflow, not a defect. |
| **LP cannot evidence the underlying deal** | Sharper than the row above, and worth surfacing separately in the UI: an LP who buys the recipient role inherits a dispute about work they never performed. They have no delivery records, no correspondence with the buyer, and the original supplier has been paid and has no incentive to assist. If the buyer alleges non-delivery, the LP is structurally unable to rebut it. Their only real levers are **care in agreeing an arbiter** (§3.3A1a), the **holdback** (§5.3), and preferring **short-dated purchases** where the remaining dispute window is small. |
| Seller approves marketplace but never accepts | Harmless: the approval moves nothing by itself, is revocable (`approveRecipientTransfer(address(0))`), and is cleared by any recipient change. |
| Front-running `acceptOffer` | Only the current recipient can call it; the approval is only usable by the marketplace inside that call. An LP withdrawing a stale/expired offer cannot be raced into an acceptance (stale/expired offers are never acceptable). |

---

## 12. Out of Scope

- Offer discovery / indexing (off-chain: UI + subgraph)
- Yield on deposited funds
- Upgradability / proxy pattern
- Timelock on fee/owner changes (pilot: Ownable2Step EOA)
- Whitelisting of *escrow contracts* — provenance is the codehash check (§8.1) plus the collusion mitigations of §3.3, not a listing allowlist.
- Curation of **arbiters** — considered and dropped; the nomination veto already provides the protection a list would have (§3.3B).
- `CompletionEscrowContract` / payee-slice sales — structurally incompatible, see §3.0

## 13. Open Questions (before audit)

1. **Fee rate at launch** — TBD, but note it is **distinct from and smaller than the 1% creation fee** (`CREATOR_FEE`, taken at escrow deposit). The marketplace fee taxes the same cashflow a second time, stacks with the LP's discount in the seller's all-in cost of liquidity, and is charged on **every** sale including resales — so a chain of sales compounds it. Proposed starting point: **25–50 bps**, adjustable via `setFeeRate` (new offers only; live offers are snapshotted).
2. **`defaultOfferDuration` at launch** — 24h proposed.
3. ~~`sweepToken`~~ — **settled: ships in v1** (§6.6). Owner-only recovery of accidental direct transfers; structurally unable to touch deposits, fees, or holdbacks.

**Sub-decisions opened by §3.3 (arbiter selection):**

4. ~~**Re-seating a silent arbiter**~~ — **settled** (§3.3A1a, `evictArbiter`): either disputant may evict after 30 days (`ARBITER_SILENCE_TIMEOUT`) with no vote cast or changed; the seat clears, nominations reopen, the window restarts, and the Safe re-seats on expiry. Only ever swaps the third voter — moves no funds. The rolling clock also covers an arbiter who voted once and vanished; on unsold escrows it doubles as the parties' exit from a slow Safe.
5. ~~**Holdback**~~ — **settled** (§5.3, §6.7). Factoring semantics; one reserve per escrow, funded out of the original supplier's proceeds on the first sale only; the beneficiary is read live at settlement so the reserve follows the position through any number of resales; split by the recipient's loss when the escrow settles. Deferred, not rejected: a **seller skin-in-the-game reserve on resale**, which is adverse-selection protection rather than performance recourse and is a strictly larger mechanism (a reserve per sale, settling as a waterfall). Revisit if secondary-market adverse selection proves real.
6. ~~**Curated arbiter registry**~~ — **settled: there is no registry** (§3.3B). The nomination veto already provides the protection a list would have, since an LP can never buy into a disputed escrow and so is never bound by a selection made before they arrived. Residual: social-engineering resistance is now a **UI responsibility** at the nomination step, not a contract guarantee.
7. ~~**"Resold" detection**~~ — **moot.** It existed only to scope the registry; with no registry there is no `wasResold` flag and nothing to detect.
8. ~~**`DEFAULT_ARBITER` multisig**~~ — **created: "stabledropAdmin" Safe `0x9bB8e809EA6F5A74f46027D8016641D9cE9A149C`** (Base, Safe v1.4.1, threshold 2-of-3, signers `0x2956…7F62` / `0x1936…0b05` / `0x431F…b607`, no modules — all verified on-chain 2026-08-05). **Outstanding before the implementation deploys: one test transaction executed at threshold** (nonce is 0 — the 2-of-3 has never actually fired). Note `0x1936…0b05` is also the legacy factory OWNER EOA; acceptable, but its compromise then touches two roles — worth a conscious sign-off. Note the role is **arbitration only**: it never signs escrow creations (chainservice's own hot wallet does those), offers, acceptances, or agreed settlements (§3.3A2a). But since it is now the creation arbiter on every escrow, it adjudicates **every contested dispute platform-wide** — size the signer set and threshold for that volume and responsiveness, not for a rare edge case. No resolution deadline exists (§3.3A2), so latency is an SLA concern, never a fund-safety one. Constraint from §3.3A1a: `DEFAULT_ARBITER` is baked into the implementation bytecode, so rotating it means a whole new implementation + factory + marketplace. **It must be a multisig** (a Safe whose signers can rotate while the address stays fixed) — decide its composition before deploying the implementation, because it is the one address that cannot be changed afterwards.
9. **Migration** — ~~§3.3 changes `initialize`'s signature and the factory ABI~~ **— no longer true (v0.7.0): the nomination window became a constant, so `initialize` and `createEscrowContract` keep their original signatures and chainservice needs only new ADDRESSES, not new call sites.** What remains is what happens to escrows already live on the current implementation (answer: they stay on their own terms and are permanently invisible to the marketplace, §3.4). **✅ Settled (v0.8.0): chainservice shipped this on 2026-08-06 — see §15.4a for what landed.** **The concrete, post-deploy integration checklist lives in §15.4** — read that rather than this paragraph. In summary (§3.3A2a): chainservice passes the `DEFAULT_ARBITER` Safe as the creation arbiter (never its hot wallet, and note the factory silently defaults a zero arbiter to `msg.sender` — which is why the shipped implementation *derives* the address from the implementation's `DEFAULT_ARBITER()` rather than trusting configuration, §15.4a), and retires the complete-the-pair arbiter vote entirely. For **every** dispute it instead watches `VoteSubmitted` and prompts each disputant to push the agreed % on-chain, routing those vote transactions through the existing **gas-sponsorship path** like all other user-wallet actions. Detect "sold" via the `ArbiterUnseated` event where the UI needs to distinguish.
10. ~~**Fee incidence**~~ — **settled: seller pays, as specified** (§8.5a). LP deposits `X`; seller receives `X − fee − holdback` at acceptance. Simplest to implement, and LPs price the convention into their bids. The UI must show the seller their net figure at bid display and at acceptance.
11. ~~**`reviseOffer`**~~ — **settled: deferred, confirmed.** A rejected LP re-bids via reject → withdraw → new offer (three transactions; gas-sponsored, so the cost is clicks, not money). Revisit only if real usage shows haggling dominating — that means a marketplace redeploy (offers are short-lived, so migration is a natural wind-down), and any future design must preserve §5.2.4a: revision only by the LP, only on a **rejected** offer, never on a live `OPEN` one.
12. ~~**Minimum-offer floor**~~ — **settled: owner-configurable `minOfferBps`, launching at 1000 (10%)**, hard cap 10000, new offers only (§5.2.4, §6.5). The fixed 50% floor was rejected: it banned the deep-discount bids §8.1a identifies as the safest LP trades, while the spam it guarded against is harmless on-chain (no enumeration; dust locks the spammer's own capital) and filterable off-chain.
13. ~~**Emergency pause**~~ — **settled: yes, inflows only** (§5.2.10, §6.5). OZ `Pausable`; `whenNotPaused` on `createOffer` + `acceptOffer`; `withdrawFunds`, `releaseHoldback`, and `rejectOffer` are never pausable. Incident response becomes "stop, let everyone out, fix" instead of "watch". The lever is bounded: it can halt the venue, never touch or trap funds.
14. **Regulatory perimeter — confirm with counsel.** §3.3A2 is designed so the platform can never move funds alone: the default arbiter is one voter of three, and every settlement requires a *disputing party* to vote the executing figure. That is the property to put in front of an adviser. Dropping the arbiter registry (§3.3B) deliberately narrows the surface: the platform now curates nothing and vets no one, and appears in a dispute only as a fallback third voter that neither party can outvote alone. What still warrants a view is whether being that fallback voter — in the subset of disputes where the parties fail to agree — is itself enough to constitute influence over client funds. Get this confirmed **before** launch: if the answer is no, the fallback has to become something other than the default arbiter, and that is a contract change rather than a policy one.

15. ~~**Pooled custody of LP capital**~~ — **settled by redesign (v0.9.0, §5.0): the marketplace no longer pools funds.** The question §13.14 never asked: the pooled `MarketplaceEscrow` held every LP's deposit at one platform-deployed address, commingled across unrelated users and escrows, apart only by internal accounting. The technical position was defensible — the owner could reach nothing but genuine surplus (`sweepToken` required `balance > owed`), and `withdrawFunds` was structurally unpausable — but *commingling* is a regulatory trigger in its own right in several regimes, independent of who controls the funds. Rather than rest on a legal reading nobody had obtained, the venue was rebuilt as **one `OfferVault` clone per offer**: each LP's capital sits in its own contract, reachable only by that offer's LP or seller, and the factory holds nothing at any point — no funds, and no state either, since the one-reserve fact moved onto the escrow. Fees now pay out to `FEE_RECIPIENT` at acceptance rather than accruing, so no owner-withdrawable balance exists anywhere. **Timing made this cheap** — the marketplace was never deployed, so there was no migration, no live funds and no wasted audit (§16 phase 3 had not run). **Still outstanding for counsel:** this removes the marketplace's commingling question but says nothing about the escrow model itself, where a single escrow holds one deal's funds for two named parties. That, and §13.14's arbitration question, remain the pre-launch legal gates.

## 14. Test & Audit Plan

Foundry throughout, extending the existing suites (`test/EscrowContract.t.sol` already
covers §3.2; `test/InvariantEscrow.t.sol` already exercises the approval/transfer surface).
Every test named here is **mandatory before audit** — most encode a specific bug this spec
caught on paper, and the auditor should be handed this section as the map of what we believe
and why.

### 14.1 Escrow (§3.3) — unit & scenario tests

**The vote trap (§3.3D) — the three cases, verbatim:**
1. Sold escrow (arbiter unseated), seller votes 0 → MUST NOT resolve.
2. Seller votes 0, arbiter then seated → seating MUST NOT fire consensus.
3. Buyer and seller both vote 50, no arbiter seated → MUST resolve (branch 1, the common case).

**Unseating:**
- `transferRecipientFrom` unseats, clears both nominations, emits `ArbiterUnseated`.
- `changeRecipient` does NOT unseat.
- Mid-dispute transfer restarts `nominationDeadline` with a full window.
- Old arbiter's `submitResolutionVote` reverts after unseating (`NotAuthorizedToVote`).

**Nomination & seating (§3.3A1a):**
- Party-only; candidate ≠ zero/buyer/seller; nominations mutable; single nomination never seats.
- Match seats immediately, in the matching transaction; incumbent re-confirmation works.
- Re-seated incumbent who had voted pre-unseat returns with vote reset to 255.
- `seatDefaultArbiter`: only disputed + unseated + deadline passed; zero-window escrow → seatable as soon as disputed; **late match still seats after the deadline, right up until the fallback executes**.
- `NOMINATION_WINDOW`: a 72h constant, identical on every clone and on the implementation; no code path can change it, and a direct clone cannot present a different one.
- **Fallback liveness (new, §0.4b):** for any accepted escrow the fallback must become seatable within a bounded, plausible time and must then let the LP settle WITHOUT the buyer. Assert the PROPERTY against a fixed tolerance, never against the window constant — a test that measures the constant against itself passes however far the constant moves.

**Eviction (§3.3A1a):**
- Rolling clock: stamped at `raiseDispute` (arbiter already seated), at seating, and on every arbiter vote/vote-change; eviction reverts inside the 30 days from each.
- Party-only, disputed-only; clears seat + nominations, restarts window; moves no funds.
- Covers the voted-once-then-vanished arbiter; on an unsold escrow, evicting the Safe and match-nominating a private arbiter works.

**The attack, end-to-end (§8.1a):** attacker direct-clones the implementation, initializes with their own buyer/arbiter/window, funds it, lists it, sells to an LP, then bundles `raiseDispute` + buyer-vote-100 + old-arbiter-vote-100 in the block after `acceptOffer` — MUST fail (arbiter unseated by the sale). This is the single most important test in the suite.

**State & persistence:**
- `resolvedBuyerPercentage`: 255 until a dispute resolves; set before transfers in `_executeResolution`; equals the executed percentage for b ∈ {0, 1, 50, 99, 100}.
- `_transferRecipient` rejects `DEFAULT_ARBITER` and (when seated) `ARBITER`; resets `nominatedByRecipient` and the new recipient's vote.
- `initialize` writes `resolutionVotes[address(0)] = 255` (belt-and-braces, §3.3D).

### 14.2 Marketplace — unit tests

**`createOffer`:** codehash gate rejects EOAs, wrong-implementation clones, and the raw implementation itself; slot occupancy; `maturity() != 0`; sellable gate; `offerExpiry < maturity()`; party exclusion; floor at `minOfferBps` including the dust edge (`max(…, 1)` with `payoutAmount ∈ {0, 1, 2}`); `fee + holdback <= offerAmount`; `HoldbackOnResale` once `hasBeenSold`; balance-delta check against a fee-on-transfer mock token; reverts when paused.

**`acceptOffer`:** requires OPEN, unexpired, live seller (`msg.sender == recipient() == offer.seller`), sellable; **rejects a holdback-bearing offer once `hasBeenSold` (§6.2.4a) — including the reacquired-position sequence that made this reachable, and the matching `withdrawFunds` exit for the stranded LP**; reverts with no approval / expired approval / approval bound to a different LP; slot deleted (re-entrant second accept fails at step 1); `hasBeenSold` set; `Holdback` recorded with `funder = seller` on first sale only; seller receives exactly `offerAmount − fee − holdback`; reverts when paused.

**`rejectOffer` / `withdrawFunds`:** the withdrawability matrix — CANCELLED, expired, stale (recipient changed), disputed, claimed — each refunds **full gross** and frees the slot; a live acceptable offer reverts `NothingToWithdraw`; no state exists where an offer is simultaneously acceptable and withdrawable (fuzz this).

**`releaseHoldback`:** reverts before `isClaimed()`; undisputed → full holdback to funder; disputed at `b`% → `min(holdback, payoutAmount × b / 100)` to the **live** `recipient()`, remainder to funder; **rounding must match `_executeResolution`'s division exactly** (fuzz b over 0–100 and assert the two contracts' splits are consistent to the wei); beneficiary read after a resale and after a direct `changeRecipient` lands on the current holder; second call reverts (`NoHoldback`); the 255 sentinel and a 0% resolution both pay the funder in full.

**Owner surface:** fee cap 1000; `minOfferBps` cap 10000; duration > 0; `withdrawFees` capped by `accruedFees`; `sweepToken` moves only the excess and reverts at zero excess; **pause asymmetry — while paused, `withdrawFunds`, `releaseHoldback`, and `rejectOffer` all succeed** (§5.2.10).

### 14.3 Invariants (fuzz / invariant suites)

1. **Conservation (§5.2.7):** per token, `balanceOf(marketplace) ≥ totalDeposits + accruedFees + totalHoldbacks`, across arbitrary interleavings of every external function.
2. **Slot ⇔ deposit (§5.2.1):** an offer slot is non-`NONE` iff the contract still holds that LP's gross deposit.
3. **Holdback conservation (§5.2.8):** `toFunder + toRecipient == amount`, settled exactly once, owner can never withdraw it.
4. **No manufactured consensus:** with `ARBITER == address(0)`, no sequence of calls produces a resolution without buyer AND seller voting the same figure.
5. **Role integrity:** no sequence moves the recipient role without a live approval from the then-current recipient (extends the existing invariant suite).
6. **Eviction is fund-neutral:** `evictArbiter` never changes any balance.

### 14.4 Audit scope & known-accepted residuals

- **Prior review assumptions are void:** §3.3 changes the dispute model (arbiter no longer fixed for life; new unseat/nominate/evict surface). Any earlier review of `EscrowContract` predates this.
- In scope: full `EscrowContract` (new implementation = §3.2 + §3.3), full `MarketplaceEscrow`, and their interaction under adversarial ERC-20s (hooks, fee-on-transfer, blacklisting).
- Accepted residuals, documented not fixed (point the auditor at them rather than re-discovering): deceived-arbiter / evidence asymmetry (§8.1a, §11), buyer hold-up under no-deadline (§3.3A3.1), blacklistable tokens (§11), Safe responsiveness as SLA (§13.8), social engineering of nominations as UI responsibility (§3.3B).
- Deploy-order checks (§3.4): Safe exists and has executed a test transaction before the implementation deploys; `EXPECTED_ESCROW_CODEHASH` recomputed against the **final** deployed implementation address.

## 15. UI & Off-Chain Obligations

The §1 principle stands — the contracts are fully operable raw, with no UI dependency for
*correctness*. But several protections were **deliberately delegated from the contract to
the UI** during design, and the flows below are load-bearing for user safety. This section
collects every such obligation so the frontend and chainservice teams have one place to
build from. Each item cites the section that created it.

> ### Which section is yours
>
> | Team | Read | Status |
> |---|---|---|
> | **chainservice** | §15.4 (why) + **§15.4a** (what shipped) | ✅ complete — escrow migration and marketplace API both done |
> | **contractservice** | §15.5 (retired vote) + **§15.7** (marketplace index) | ✅ both complete |
> | **webapp / front-end** | **§15.6** in full — a–f | ⬜ outstanding · §15.6b–c are **blocking** |
>
> **webapp: everything you need is §15.6 of this file.** §15.6a says what is ready to build
> against, §15.6b–c the dispute and arbiter screens (**start here — nothing settles without
> them**), §15.6d the marketplace screens, §15.6e every endpoint across both services, §15.6f
> the refresh action. Request/response detail lives in `chainservice/API_REFERENCE.md` and on
> contractservice's Swagger UI; §15.1 and §15.2 are the safety obligations those screens carry.
>
> §15.1 (disclosures) and §15.2 (choreography) are obligations the *contracts deliberately
> delegate to the UI*. They are not optional polish: each one replaces a protection that was
> considered and left out of the contract on purpose, so omitting it removes the protection
> entirely rather than degrading it.

### 15.1 Safety-critical disclosures

| Screen | Obligation | Source |
|---|---|---|
| Dispute settlement entry (ALL escrows) | The figure being submitted is a **binding offer that pays out on match**, immediately and irreversibly — the contract cannot distinguish a proposal from an acceptance, and any two of the three current votes settle. The other party's (and any seated arbiter's) standing figure must be shown and labelled as the number that settles on match. Presenting this as a revisable negotiating position is the failure mode. | §3.3A2a |
| Arbiter nomination (sold-escrow dispute) | Warn that **matching an unknown candidate is irreversible** and seats them; declining to match is **always safe** — the default arbiter takes the seat after the window. This replaced the dropped registry: social-engineering resistance is a UI guarantee now, not a contract one. | §3.3B |
| Seller's offer list + accept confirmation | The headline figure the seller sees MUST be their **net at acceptance** (`offerAmount − fee − holdback`), with the holdback's return-at-settlement explained. A seller shown "10,000" who receives 8,900 reads it as theft. Fee and holdback are separate `OfferCreated` fields precisely so offers can be compared on both. | §8.5a, §13.10, §5.3 |
| LP bid entry / purchase confirmation | Disclose the **evidence asymmetry** before purchase: an LP inherits a dispute they cannot evidence; their levers are care in agreeing an arbiter, the holdback they set, and short-dated purchases. Surface **time-to-maturity (= remaining dispute window)** as the primary risk metric, and note deeper discounts mechanically reduce attack exposure (`r − d`). | §11, §8.1a |
| Buying a previously-sold escrow | Show the **existing holdback** (amount, funder) — the reserve travels with the position and the new buyer becomes its beneficiary. (The nomination window no longer needs surfacing: it is a protocol-wide 72h constant, identical on every escrow, so there is nothing per-escrow for an LP to price — §3.3A1.) | §5.3 |

### 15.2 Flow choreography (multi-transaction sequences the UI orchestrates)

- **Accept flow:** tx 1 `approveRecipientTransfer(marketplace, lp)` on the escrow → tx 2 `acceptOffer` on the marketplace, within the **5-minute TTL** (§3.2). On expiry, simply re-prompt — an expired approval is inert and nothing is at risk.
- **Dispute settlement (ALL escrows):** there is **no off-chain agreement stage** — each disputant's settlement figure goes on-chain as `submitResolutionVote(X)` from their own wallet the moment they name it, and the contract settles the instant any two of the three current votes match (§3.3A2a). Present every submission as **binding**: it is an offer that pays out on match, not a negotiating position. Votes remain revisable until consensus. The UI encodes the call, requests gas via `fund-wallet`, and the user's own provider sends it — chainservice relays nothing, because the wallet stack cannot produce a signed transaction to relay (§15.6b).
- **Contested sold-escrow dispute:** nomination entry (free-form address + the §15.1 warning); a permissionless "seat default arbiter" action once the window lapses; a "request new arbiter" (`evictArbiter`) action once a seated arbiter has been silent 30 days (§3.3A1a).
- **LP housekeeping:** expiry, staleness, rejection, and dispute-triggered withdrawability are all **lazy** — nothing on-chain notifies the LP. The indexer must detect each condition and prompt `withdrawFunds`; likewise prompt (or keeper-fire) `releaseHoldback` once the escrow settles — it is permissionless by design (§6.4, §6.7).

### 15.3 Discovery & indexing (off-chain by design, §12)

> ## ⚠️ NOW LOAD-BEARING, NOT OPTIONAL (v0.9.0)
>
> §5.0 removed the on-chain offer book: the marketplace factory keeps **no per-escrow and no
> per-offer storage**, so there is no way to enumerate offers on-chain. `OfferCreated` carries
> the vault address and the events are complete and replayable — but **without an indexer
> there is no offer book at all**. This was a deliberate trade (it removed an unbounded array,
> an SSTORE per offer, and the venue-redeploy hazard), and the index is the other half of it.

- Subgraph over the §9 marketplace events plus escrow events; the sellable list = new-implementation clones passing the §5.2.2 composite, computed client-side.
- Offer books from `OfferCreated` / `OfferFunded` / `OfferAccepted` / `OfferRejected` / `FundsWithdrawn` / `HoldbackReleased`. `ArbiterUnseated` marks an escrow "sold" where dispute flows branch (§13.9); the escrow's own `hasBeenSold` is the authoritative read (§5.0).
- **An unfunded vault is not an offer.** `createOffer` deploys an empty shell and only the LP's `fund()` makes it live (§5.0), so index on `OfferFunded`, not `OfferCreated`, when building the book a seller sees. Showing PENDING vaults would advertise offers nobody has committed to.
- **Listing-level curation is the chokepoint for the §8.1a residual** — the contract stays permissionless, but the UI need not list everything. Tells worth screening: buyer/seller wallets funded from a common source, freshly created parties, listing immediately after funding.

#### 15.3a Two rules for whatever does the indexing

**1. Index for reading. Never for deciding.** An off-chain record may drive display,
discovery, prompts and notifications. It must never gate anything the contracts also gate —
whether an offer may be accepted, whether a reserve may be set, whether funds may move. Those
are enforced atomically on-chain, and `hasBeenSold` was moved onto the escrow (§5.0)
specifically so that no off-chain party is ever consulted about them. This is §3.3A2a's lesson
generalised: the moment a mirror gates a decision the chain also gates, there are two answers
and one of them is wrong.

**2. Derive it from EVENTS, not from UI reports.** Do not build the marketplace index by
having the webapp tell contractservice what it just did. Every vault function —
`fund`, `accept`, `reject`, `withdraw`, `releaseHoldback` — is callable directly by its party
without touching our UI at all; the contracts are fully operable raw (§1). A UI-reported index
misses all of that silently and diverges without anyone noticing, whereas events miss nothing
and can be replayed from zero after an outage.

> Note this differs deliberately from §15.6b, where the *UI* reports a settlement vote to
> contractservice after a successful relay. That is a record of a **conversation** — which
> figure a party committed to, alongside the discussion that produced it — and it is not used
> to decide anything. The marketplace index is a mirror of **chain state**, and mirrors must
> be built from the chain.

**✅ Settled (2026-08-07): chainservice indexes, and pushes to contractservice.** Not a
subgraph. chainservice is the chain-facing service, already owns `EventParsingService`, the
ABIs and the RPC configuration, and already pushes to contractservice on other paths — so the
marketplace index arrives the same way dispute-state discrepancies do. contractservice remains
the system of record the UI reads; it just never talks to the chain itself.

Consequences worth stating plainly:

- **contractservice never becomes chain-aware.** It receives, stores and serves. No RPC, no
  ABI, no log parsing — which is also why §15.3a rule 1 is easy to keep: it holds a mirror it
  cannot mistake for authority.
- **chainservice owns replay.** Because the index is event-derived (rule 2), chainservice must
  be able to rebuild it from any block — an outage, a redeploy of contractservice, or a bug in
  the push path must all be recoverable by re-reading the chain. chainservice has **no durable
  storage** (its only cache is per-process Caffeine), so it keeps no cursor and no record:
  every read states its own range, and a repeat is harmless because the push is idempotent.

**✅ Reconciliation is ON DEMAND, not polled (decision, 2026-08-07).** The index is fed by the
UI reporting each action once it lands on-chain; a chain read is the *reconciler*, not the
primary feed. A background poll would therefore spend almost all of its time rediscovering
what contractservice already knows — the only thing a read uniquely catches is activity that
bypassed the UI, which the contracts permit (§1) but which is uncommon.

So the UI carries a **"refresh from chain"** action, and contractservice supplies the escrows
it believes are live (funded, unexpired) with roughly when each became relevant.

- **The escrow list is what makes this cheap.** `escrowContract` is an indexed parameter on all
  six marketplace events, so the list becomes a **topic-1 filter**: the node returns logs for
  those escrows only, rather than every marketplace log in the range. A narrow question
  instead of a broad one.
- **⚠️ The staleness that costs money is a missed ACCEPTANCE**, not a missed offer. An
  acceptance makes every *other* offer on that escrow stale and withdrawable at once, and those
  LPs have capital they could recover but do not know it. Surface the refresh where that
  matters — an LP's own offer list — not only on an admin screen.
- Date bounds may be approximate: the block estimate deliberately **errs backwards**, since
  starting early costs a few log reads whereas starting late silently misses events.
- **The push must be idempotent.** Re-indexing the same block range must not duplicate offers
  or double-apply state; key on `(vault address, event)` rather than on arrival order.

### 15.4 chainservice migration checklist (concrete, post-deploy)

> **✅ Shipped 2026-08-06.** Every item below is implemented; **§15.4a records what landed**,
> including the one place the implementation deliberately improved on item 1. This section is
> kept as written because it is the rationale — the *why* behind each change, and the
> reference for anyone auditing whether the migration was done correctly.

The new implementation and factory are live (§3.4). This is the exact integration work
required to move chainservice onto them. Items 1–3 apply to **every escrow chainservice
creates, platform-wide** — not only ones that reach the marketplace.

**✅ The factory ABI is unchanged.** `createEscrowContract` still takes the same 7
arguments and `initialize` the same 8, verified against the pre-marketplace version. Escrow
creation needs **no call-site changes** — new addresses are sufficient for it to keep
working. That is precisely what makes item 1 dangerous.

#### Required changes

**1. Pass the `DEFAULT_ARBITER` Safe as the creation arbiter — ⚠️ THIS FAILS SILENTLY.**

Today chainservice passes its own hot wallet, or passes `address(0)` and the factory
defaults it: `if (arbiter == address(0)) arbiter = msg.sender;` — which *is* the hot wallet.

If you repoint the addresses and change nothing else, **everything keeps working**. Escrows
create, fund, dispute and settle exactly as before. There is no revert and no warning. But
every new escrow gets the hot wallet as arbiter, so:

- the operational hot wallet retains dispute power it was supposed to surrender (§3.3A2a);
- **the §3.3A2 claim — "the platform can never move funds alone" — becomes false**, and that
  is the property §13.14 puts in front of counsel;
- it is immutable per escrow, so every escrow created before the fix is permanently wrong.

Pass `0x9bB8e809EA6F5A74f46027D8016641D9cE9A149C` explicitly.

**2. Retire the complete-the-pair arbiter vote (§3.3A2a).**

Today an agreed dispute is settled by one party voting on-chain and chainservice casting the
matching vote from the arbiter seat. **That mechanism is gone** — a 2-of-3 Safe cannot act as
an automated vote-completer.

Replacement flow, for **every** dispute, sold or unsold: each disputant calls
`submitResolutionVote(X)` from their own wallet **when they name a figure** — there is no
off-chain agreement stage and nothing off-chain detects agreement (§3.3A2a, revised
2026-08-06). The contract settles the instant any two of the three current votes match,
executing the payout in that same transaction. The arbiter takes **no action of any kind** in
a settlement the parties reach between themselves.

> ⚠️ Superseded wording: an earlier revision of this item said "negotiate off-chain, then
> prompt both disputants to ratify, and chase the outstanding side." That describes the
> mirror-the-contract design that §3.3A2a removed — there is no agreed-but-unsettled state to
> chase any more, because a matching figure settles on submission.

**3. Route those votes through the existing gas-sponsorship path**, like every other
user-wallet action, so a disputant holding zero ETH can still settle.

#### Integration hazards

**4. `ARBITER()` can now return `address(0)`.** This is a live mid-life state after a
marketplace sale (§3.3A), not an error condition. Any code that assumes it is non-zero, or
that compares it against the hot wallet, needs an explicit unseated branch.

**5. Two escrow cohorts now coexist.** Escrows on the superseded implementation
(`0xCbfD5384…`) stay live to their own terms and expose an **identical ABI** for everything
chainservice does today, so existing code paths work unchanged on both. What they do *not*
have is the §3.3 surface — `nominateArbiter`, `seatDefaultArbiter`, `evictArbiter`,
`NOMINATION_WINDOW`. Any new dispute UI must therefore detect the cohort before offering
those actions. Cheapest checks, either works:

- `escrow.codehash == 0x5c1d3f7f01cbe7c3aa294f7f7d426ad766c7c99513eb563742964c4f22477644`
  (the same check the marketplace itself uses), or
- a `NOMINATION_WINDOW()` call, which reverts on old-implementation escrows.

#### New surface to read and index

| Read | Purpose |
|---|---|
| `resolvedBuyerPercentage()` | how a dispute resolved; 255 = never disputed (§3.3C) |
| `nominationDeadline()` | when `seatDefaultArbiter` becomes callable |
| `nominatedByBuyer()` / `nominatedByRecipient()` | pending nominations; equal ⇒ seated |
| `lastArbiterActionAt()` | eviction clock; +30 days ⇒ `evictArbiter` available |
| `NOMINATION_WINDOW()` | 72h constant; doubles as a cohort probe |

New events to index: `ArbiterUnseated`, `ArbiterNominated`, `ArbiterSeated`,
`ArbiterEvicted`. **`ArbiterUnseated` is the "this escrow has been sold" marker** where
dispute flows branch.

New user-callable actions the UI must expose on sold escrows: `nominateArbiter(candidate)`,
the permissionless `seatDefaultArbiter()` once the window lapses, and `evictArbiter()` after
30 days of arbiter silence (§15.2).

#### Unchanged — no work required

`depositFunds`, `checkAndActivate`, `claimFunds`, `raiseDispute`, `submitResolutionVote`,
`changeRecipient`, and every view chainservice already consumes.

#### Sequencing

**Item 1 and the address repoint must ship in the same release.** Escrows created with the
wrong arbiter cannot be corrected afterwards, so repointing first and fixing the arbiter
later leaves a permanent cohort with the platform holding dispute power.

More broadly: the deployed contracts are **inert until chainservice repoints** — no escrow
exists on them until then. That makes the repoint, not the deploy, the real point of no
return, and the reason §16 phase 3 (audit) should clear first.

### 15.4a What shipped (chainservice, 2026-08-06)

Build green: **263 tests, 0 failing**. Mapping from the §15.4 checklist to the code:

| §15.4 | Landed as |
|---|---|
| 1. Safe as creation arbiter | `DefaultArbiterResolver` + `EscrowTransactionService.createContract` — see the amendment below |
| 2. Retire complete-the-pair | `VoteService` deleted; `POST /api/vote/submit` now returns **410 Gone** naming the replacement |
| 3. Sponsored disputant votes | ⚠️ **corrected 2026-08-07** — relay endpoints were built, then removed as unusable: embedded wallets expose no raw signing. The existing `fund-wallet` path already sponsors these; the UI funds and sends (§15.6b) |
| 4. `ARBITER()` may be `address(0)` | `ArbiterQueryService` reports an empty seat as unseated, never as an error or a mismatch |
| 5. Two cohorts | `detectCohort` probes `NOMINATION_WINDOW()`; a legacy escrow is offered no §3.3 action |
| New reads | `GET /api/chain/contract/{addr}/arbiter` — seat, nominations, eviction clock, `resolvedBuyerPercentage`, cohort, and per-action availability flags |
| New events | `ArbiterUnseated` / `Nominated` / `Seated` / `Evicted` indexed; `ArbiterUnseated` also answers "has this escrow been sold" via log query |
| New user actions | `POST /api/chain/nominate-arbiter`, `/evict-arbiter` (user-signed, sponsored) and `/seat-default-arbiter` (relayer-fired — permissionless on-chain, so no signature is needed and none is privileged) |

> **On item 5 — no backward compatibility is being built** (decision, 2026-08-06). Cohort
> detection ships because it costs one `eth_call` and makes the `can*` flags correct for free,
> but **no consumer should branch on it**: a legacy escrow can never be sold (§5.2.2 restricts
> the marketplace to the new codehash), so it never reaches an unseated seat or an open
> nomination window, and the §3.3 actions are unreachable on it by construction rather than by
> our checking. Legacy escrows keep working on the unchanged flows and are otherwise out of
> scope — see §15.6.

#### Amendment to item 1 — derive the Safe, do not configure it

§15.4 item 1 says "Pass `0x9bB8e809…` explicitly." That is correct but understates the
failure mode it is guarding, because it substitutes one silent error for another: a
configured address that is well-formed but **wrong** passes every validation and produces
permanently mis-arbitered escrows, undetectable until a dispute arrives.

Two distinct addresses are involved, and conflating them is the trap:

- **`DEFAULT_ARBITER`** is an `immutable` in the implementation's bytecode, shared by every
  clone, and acts *only* as the fallback seated by `seatDefaultArbiter()`.
- **`ARBITER`** is ordinary per-clone storage, set from the 7th argument of
  `createEscrowContract`. Nothing in the bytecode ties it to `DEFAULT_ARBITER`.

They coincide on our escrows purely because we choose to pass the same value. Omitting the
argument does not fall back to the immutable: `initialize` reverts on a zero arbiter, so the
factory substitutes `msg.sender` — our relayer — *before* `initialize` sees it.

chainservice therefore **reads `DEFAULT_ARBITER()` from the configured implementation at
startup** and passes that as the creation arbiter, deriving the per-escrow value from the
immutable one rather than restating it. `DEFAULT_ARBITER_ADDRESS` remains supported but is
now an **assertion, not a setting**: when present it must agree with the bytecode or the
service refuses to start. If neither the on-chain read nor the variable yields an address,
the service refuses to start rather than defaulting to anything.

Consequence for §16 phase 7: the load-bearing deploy variable is
`ESCROW_IMPLEMENTATION_ADDRESS`, not `DEFAULT_ARBITER_ADDRESS`.

#### Also caught during the migration

- **`ArbiterMustBeDistinct` is a new factory error** (arbiter equal to buyer or seller).
  chainservice pre-checks it so callers get a readable message rather than an opaque revert.
- **A caller-supplied arbiter override was retained** at the platform's decision, but an
  explicit zero address now resolves to the Safe rather than being forwarded — zero is never
  a legitimate override value, only the factory's substitution trigger. No current caller
  exercises the override (the webapp omits the field when falsy).
- **Two dead call sites surfaced** once the ABI was refreshed against the live
  implementation: `resolveDispute(uint256,uint256)` and `USDC_TOKEN()` exist in no deployed
  ABI and threw before reaching the chain. The latter was repointed to `tokenAddress()`; the
  former belonged to the arbiter-resolution path that item 2 retires.

#### Knock-on, not yet done

Retiring the admin vote breaks `contractservice`'s auto-resolve path. **See §15.5** — that
change is required before agreed settlements complete on-chain again. Tracked as §0.1 row 4.2.

### 15.5 ⚠️ contractservice — required change

> **✅ Done 2026-08-06.** `checkAndAutoResolveIfAgreed` and its call site are removed, as are
> `ChainServiceClient.submitVote` and the `VoteSubmitRequest`/`VoteResponse` models — so the
> retired endpoint is now unreachable by construction rather than by discipline. A regression
> test (`matching refund percentages record the dispute without triggering settlement`) pins
> the intent: cache invalidation is the only chainservice call a dispute may make. 321 tests
> green. The section below is retained as the rationale.

**What changed.** chainservice's `POST /api/vote/submit` is **retired** and now returns
**410 Gone**. It used to complete a 2-of-3 vote pair: when both parties agreed a figure
off-chain, one of them voted from their own wallet and the platform cast the matching vote
from the arbiter seat. The platform no longer holds that seat on any escrow (§3.3A2a), and
the Safe that does cannot act as an automated vote-completer.

**What breaks.** contractservice calls that endpoint from its auto-resolution path — the one
that fires when both parties' recorded refund percentages match. That call now always fails.
It fails safely: the error is logged, nothing is left half-written, and no funds are at risk.
But **the settlement never reaches the chain**, so a dispute both parties have agreed will
sit unresolved with the money still locked.

**The change is a deletion, not a rewrite** (decision, 2026-08-06 — §3.3A2a). Do not rebuild
the auto-resolve path to prompt both parties. **Remove contractservice from the settlement
path entirely.** Each disputant's figure now goes straight on-chain when they name it, and the
contract detects consensus itself — `_checkAndExecuteConsensus` runs on every vote, so any two
matching current votes settle in that same transaction.

**What has to be true afterwards:**

- contractservice **records and compares nothing** for the purpose of settling. Matching
  percentages held off-chain trigger no action, because by the time two figures match on-chain
  the escrow has already paid out.
- No agreement detection, no vote triggering, no chasing an outstanding side. All three were
  mirroring a rule the contract already enforces; keeping any of them reintroduces a state that
  can disagree with the chain.
- The platform submits **nothing** and needs no wallet in this flow.
- **The chain is the sole source of truth for settlement status.** Read it (or the
  `DisputeResolved` / `VoteSubmitted` events) rather than inferring from your own records.

**What contractservice keeps.** Everything that is genuinely off-chain: the dispute record,
the discussion and evidence between the parties, and notifications. §3.3A2a's "negotiation
stays off-chain" now means exactly this — the conversation is yours, the number is the chain's.

**Every party can settle — there is no wallet-funding problem to solve here.** Once both sides
have agreed, both can push their own vote to the chain, because these votes go through the
**same gas-sponsorship path the webapp already uses for every other user-wallet action**
(deposit, claim, raise-dispute): the user signs, the platform relays and pays the gas. This is
not a new mechanism and needs no new plumbing — a disputant holding zero ETH settles exactly
like one holding plenty. Do not design around funding user wallets.

**What chainservice already provides.** The relay endpoint
(`POST /api/chain/submit-resolution-vote`), the sponsorship, and the on-chain reads needed to
tell whether a given party has voted (`GET /api/chain/contract/{addr}/arbiter`, plus the
`VoteSubmitted` event). No further chainservice work is expected — if something is missing,
raise it rather than working around it.

**Sequencing.** chainservice can deploy first; this is not a coordinated cutover. But between
that deploy and this change, agreed disputes will stall, so keep the gap short or hold both.
Nothing is corrupted by the gap — the same disputes settle normally once both parties vote.

The user-facing half of this flow — actually getting each disputant to sign — is **§15.6**.

### 15.6 ⚠️ webapp / front-end — build brief

> **For the front-end team.** Same footing as §15.5: what has to exist and what must be true,
> not how to build it. §15.1 (disclosures) and §15.2 (choreography) are the obligations; this
> section collects them into one buildable brief and adds what the services actually expose.
>
> **Read §15.6a first if you are planning the work** — it says what is ready to build against
> and what is not, and the two halves have very different readiness.

#### 15.6a What is ready, and what is not

**Ready now — the dispute and arbiter surface (§15.6b, §15.6c).** The contracts are deployed,
chainservice is migrated (§15.4a) and every endpoint named below exists and is tested. This is
also the **blocking** work: until it ships, disputes on the new implementation cannot be
settled through the UI at all, because the platform no longer settles them for anyone.

**Also required before §15.6d is usable — the indexer (§15.3).** The marketplace factory keeps
no on-chain offer book, so offers are discoverable only from events. Two rules govern whatever
does that indexing (§15.3a): index for reading and never for deciding, and derive it from
events rather than from UI reports — every vault function is callable directly by its party
without touching our UI.

**Not ready — the marketplace surface (§15.6d).** The marketplace is **not deployed** (§0.1
row 3.2), and **chainservice has no marketplace endpoints yet** — everything it gained in
§15.4 concerns the escrow and its arbiter seat. §15.6d is design-ready but not build-ready.

**✅ The architecture is settled, though (2026-08-07): chainservice mediates everything.** The
marketplace uses the same model as the escrow, end to end:

| Step | Who | How |
|---|---|---|
| Deploy an offer vault | **chainservice**, from user activity in the UI | `createOffer(escrow, lp, …)` from the relayer — permissionless, LP is a parameter, moves no money |
| Fund / accept / reject / withdraw / release | **the party**, from their own wallet | the UI encodes the call, `fund-wallet` supplies the gas, the user's provider sends it — **chainservice relays nothing** |
| Offer book and state | **chainservice indexes events**, pushes to contractservice (§15.3a) | the UI reads contractservice, never the chain |

So the webapp calls marketplace contracts **directly** for the five party actions — it already
holds an RPC and encodes calldata for escrows today, and the wallet stack leaves no
alternative (§15.6b). chainservice's role is the three things the UI cannot do for itself:
deploy the vault, supply gas, and index.

**What chainservice still needs building** (none of it blocked by the deploy — addresses are
config, as they are for the escrow factory): a `create-offer` endpoint, marketplace ABIs, event
indexing for
`OfferCreated`/`OfferFunded`/`OfferAccepted`/`OfferRejected`/`FundsWithdrawn`/`HoldbackReleased`,
and the push to contractservice. **No relays** — `fund-wallet` already covers the party actions.
Tracked as §0.1 row 4.6.

Sequence accordingly: §15.6b → §15.6c → row 4.6 (chainservice marketplace API + indexer) → §15.6d.

#### 15.6b Dispute settlement — the votes

**Every settlement figure is now an on-chain transaction, signed by the user.** There is no
off-chain agreement stage any more (§3.3A2a): a disputant does not "propose" a number to the
platform and get prompted to ratify it later. The moment they name a figure, it goes on-chain
as `submitResolutionVote(X)` from their own wallet, and if it matches what the other side
already holds, the escrow pays out in that same transaction. There is no separate "finalise"
step to build — and nothing to build for detecting agreement, because the contract does it.

> ### ⚠️ The single most important thing on this screen
>
> **A submitted figure is a binding offer, not a negotiating position.** The contract stores
> one value per party — the latest — and settles the instant any two of the three match. It
> cannot tell "I propose 40%" from "I accept 40%", because on-chain they are the same
> transaction.
>
> - ✅ Frame it as: *"Submit your settlement figure. If it matches the other party's, the
>   escrow pays out immediately and this cannot be undone."*
> - ❌ Do **not** build a slider, counter-offer thread, or anything implying a number can be
>   floated and refined without consequence. A user who types the other side's current figure
>   as an opening anchor has just ended the dispute at that figure.
>
> Show the other party's current standing figure prominently, and label it as the number that
> settles on match. Once an arbiter is seated their figure counts too — a party matching the
> **arbiter's** figure settles the dispute without the third party's assent (any two of three).

Figures stay revisable until consensus, so a user may replace their own offer; each revision
is another signature and another sponsored transaction. Keep the *discussion* — messages,
evidence, reasoning — off-chain in contractservice. Only the number goes on-chain.

**What you implement, per submitted figure — this is the existing `fundAndSendTransaction`
pattern, not a new one:**

1. Encode `submitResolutionVote(buyerPercentage)` against the escrow address.
2. Call `web3Service.fundAndSendTransaction({ to: escrow, data })`, which already:
   estimates gas against the RPC, applies the funding buffer, calls
   `POST /api/chain/fund-wallet` so chainservice moves enough **ETH into the user's wallet**,
   and then sends the transaction through the user's own provider.

> ⚠️ **chainservice does NOT relay transactions, and cannot.** Embedded wallet providers
> (Farcaster, Dynamic, WalletConnect) do not expose raw transaction signing, and calling
> `getSigner()` after connection is forbidden on them — so there is no signed transaction to
> hand over. Gas sponsorship works by **funding the wallet first**; the user's provider then
> broadcasts. Any endpoint asking you for a `signedTransaction` is the wrong shape and should
> not exist.

`fund-wallet` takes a wei amount rather than an operation name, so it already covers this with
**no new chainservice endpoint**. `Web3Service.detectTransactionType` also already special-cases
`submitResolutionVote` with a 1.5× funding buffer and a 300k fallback estimate — worth checking
those still hold once the settling vote's real cost is measured on the new implementation.

**Record the figure with contractservice only after the vote lands on-chain.** The order is
fixed: user names a figure → user **signs** → the relay returns `success: true` → *then*
contractservice is told. Never at the point of typing, never when the wallet prompt opens,
never optimistically alongside the relay call. A declined signature or a failed transaction
means **nothing happened on-chain**, and contractservice must hold no record suggesting
otherwise — its dispute record is a record of what happened, not of what was intended. Getting
this backwards puts "both parties agreed at 40%" in front of users while the chain holds one
vote and the funds stay locked, which is precisely the drift §3.3A2a was restructured to
eliminate. A cancelled signature warrants no record at all.

**Estimate gas per transaction, not per flow.** `fundAndSendTransaction` estimates each call
against the RPC, which is correct — but the two votes are **not** symmetric and the fallbacks
must reflect that: a first vote is ~28k gas all-in, while the vote that triggers consensus is
~99k (worst case observed ~160k), because that transaction executes the entire payout. A
funding figure derived from a first vote and reused will strand the settling vote out of gas,
which is precisely the transaction that moves the money.

**What must be true for the user:**

- Settlement is not done when one side has submitted. Show clearly that an offer is standing
  and unmatched. There is no on-chain deadline, so a dispute can sit indefinitely with two
  non-matching figures — surface that state rather than implying something is in progress.
- Matching is **exact**: two different percentages are two standing offers, not a settlement.
- Treat the chain as the source of truth for "has this settled" — read state or the
  `DisputeResolved` / `VoteSubmitted` events. Do not infer it from your own records.

#### 15.6c Arbiter seat screens — sold escrows only

**The same fund-then-send shape covers the rest of the dispute surface** (§15.2), so build it
once: `nominateArbiter(candidate)` and `evictArbiter()` are encoded and sent exactly like the
vote, with no chainservice endpoint involved beyond `fund-wallet`.

`POST /api/chain/seat-default-arbiter` is the one exception, and the one place chainservice
does send a transaction: the call is permissionless on-chain, so the platform fires it from its
own relayer. **No signature and no user wallet** — just the escrow address.

These screens exist because a marketplace sale empties the arbiter seat (§3.3A). Three actions,
each gated by a flag from the state read below:

| Action | When it appears | What it does |
|---|---|---|
| **Nominate** an arbiter | seat empty, escrow funded or disputed | buyer and current recipient each name a candidate; **matching names seat that candidate instantly** |
| **Seat the default arbiter** | seat empty, disputed, 72h nomination window lapsed | anyone may fire it; seats the `DEFAULT_ARBITER` Safe |
| **Request a new arbiter** (`evictArbiter`) | seat filled, disputed, arbiter silent 30 days | clears the seat and reopens nominations; **moves no funds** |

A late matching nomination still wins right up until the default-arbiter transaction actually
executes, so a nomination racing a seat-default is an ordinary race, not an error — if it
reverts, re-read the state and re-render.

**Drive the arbiter screens off `GET /api/chain/contract/{contractAddress}/arbiter`**, which
returns the seat state, pending nominations, the eviction clock, and a `can*` flag per action.
Show a control when its flag is true. That is the whole rule — you do not need to reason about
which implementation an escrow is a clone of.

> **No backward compatibility is required here** (decision, 2026-08-06). Escrows predating the
> marketplace implementation lack the §3.3 arbiter surface entirely, but they also **cannot
> ever reach the state where it is used**: the marketplace only accepts clones matching the new
> codehash (§5.2.2), so a legacy escrow can never be sold, never has its arbiter unseated, and
> never opens a nomination window. The arbiter screens are reachable only on sold escrows,
> which are necessarily new-implementation ones. The response still carries a `cohort` field
> and the `can*` flags are false for legacy escrows, so the correct behaviour falls out without
> a special case — but do not build legacy-specific UI, and do not treat legacy escrows as a
> migration problem. Their ordinary flows (fund, claim, dispute, vote) are unaffected and use
> the same endpoints as everything else.

**Don't forget §15.1.** The nomination screen carries a safety-critical warning that matching
an unknown candidate is irreversible and that declining to match is always safe. That warning
is a UI guarantee, not a contract one — there is nothing on-chain to fall back on if it is
omitted. Nomination is a **free-form address entry**: there is no arbiter registry and no
validation beyond "not a party to the escrow", so the warning is the entire protection.

#### 15.6d Marketplace screens — design-ready, chainservice ready, contract not deployed

Read §15.6a before starting. **chainservice is done** (row 4.6): `create-offer` and `refresh`
exist and are tested. What is still missing is the **contract deploy** (row 3.2) and
**contractservice's receiver** (row 4.7, §15.7) — until the latter lands there is nowhere for
the offer book to be stored or read from.

**Making an offer is now two transactions** (§5.0), mirroring create-then-deposit on an
escrow: the platform deploys the LP's `OfferVault` (no money moves, no signature from the
LP), then the **LP signs `fund()`** on that vault to put the capital in. An unfunded vault
is not an offer — do not show it in a book until it is funded.

**The accept flow is two transactions with a five-minute fuse** (§3.2, §15.2):

1. `approveRecipientTransfer(vaultAddress, lp)` on the **escrow** — note the operator is
   **that offer's own vault**, not a global venue
2. `accept()` on the **vault**, within **5 minutes** of step 1

Both are ordinary fund-then-send calls from the seller's own wallet (§15.6b); neither goes
through a chainservice relay.

If the window lapses, just re-prompt. An expired approval is inert and nothing is at risk —
so treat expiry as a retry, never as an error state needing recovery. Both steps are
user-signed and belong on the same sponsorship path as everything else.

**Three disclosures are load-bearing** (§15.1), each delegated from contract to UI by design:

- **Seller, on the offer list and the accept confirmation.** The headline number must be their
  **net at acceptance** — `offerAmount − fee − holdback` — with the holdback's return at
  settlement explained. A seller shown "10,000" who receives 8,900 reads it as theft. Fee and
  holdback are separate `OfferCreated` fields precisely so offers can be compared on both.
- **LP, at bid entry and purchase confirmation.** Disclose the **evidence asymmetry**: an LP
  inherits a dispute they cannot evidence. Their only levers are care in agreeing an arbiter,
  the holdback they set, and short-dated purchases. Surface **time to maturity (= remaining
  dispute window)** as the primary risk metric, and note that deeper discounts mechanically
  reduce attack exposure.
- **LP buying a previously-sold escrow.** Show the **existing holdback** (amount and funder) —
  the reserve travels with the position and the new buyer becomes its beneficiary.

**Housekeeping is lazy — nothing on-chain notifies anyone** (§6.4, §6.7, §15.2). Expiry,
staleness, rejection and dispute-triggered withdrawability all require the UI (or indexer) to
detect the condition and prompt `withdraw()` on the LP's vault. An LP whose funds are
withdrawable and who is never told simply never withdraws.

⚠️ **`releaseHoldback` is no longer keeper-firable.** In the per-offer model it answers only
to the reserve's funder or the live beneficiary (§5.0), so nobody can sweep up on the
parties' behalf. §15.2's "prompt or keeper-fire" is therefore **prompt-only**: the UI must
detect a settled escrow with a live reserve and tell them, or the reserve sits there. Find live reserves from `OfferAccepted` events.

**Listing curation is a UI responsibility, not a contract one** (§15.3). The contract stays
permissionless, but you need not list everything. Tells worth screening: buyer and seller
wallets funded from a common source, freshly created parties, listing immediately after
funding. This is the chokepoint for the §8.1a self-dealt-escrow residual — the contract's
protections bound the damage, curation is what avoids the encounter.

#### 15.6e Endpoints you have today

**Two services, and the split matters.** You send transactions via **chainservice** (or your own
wallet, funded by it) and you read state from **contractservice**. You never read the chain
directly for marketplace data, and you never call chainservice for an offer book.

**chainservice — doing things**

| Purpose | How |
|---|---|
| Submit a settlement figure | encode + `fundAndSendTransaction` — **no endpoint** |
| Nominate an arbiter | encode + `fundAndSendTransaction` — **no endpoint** |
| Evict a silent arbiter | encode + `fundAndSendTransaction` — **no endpoint** |
| Fund / accept / reject / withdraw / release an offer | encode + `fundAndSendTransaction` — **no endpoint** |
| Gas for any of the above | `POST /api/chain/fund-wallet` `{walletAddress, totalAmountNeededWei}` |
| Create an offer vault for an LP | `POST /api/chain/marketplace/create-offer` — returns the `vaultAddress` the LP then funds |
| Seat the default arbiter | `POST /api/chain/seat-default-arbiter` — relayer-fired, no signature |
| Read arbiter seat state + action flags | `GET /api/chain/contract/{address}/arbiter` |
| Raise a dispute, deposit, claim | unchanged — same fund-then-send path you already use |

**contractservice — reading things**

| Purpose | How |
|---|---|
| A seller's offer book for one escrow | `GET /api/marketplace/escrows/{escrowContract}/offers` |
| An LP's own offers, across escrows | `GET /api/marketplace/lps/{lpAddress}/offers` |
| Refresh from chain (§15.6f) | `POST /api/marketplace/refresh` — user-authenticated, scoped to the caller |
| Contracts, disputes, notes | unchanged |

**Reading the offer view.** Each offer carries `status` — `PENDING`, `OPEN`, `ACCEPTED`,
`REJECTED`, `WITHDRAWN`, `RELEASED` — plus a separate `expired` boolean.

- ⚠️ **`PENDING` is not an offer.** The vault has been deployed but the LP has not funded it
  (§5.0). Do not show these in a seller's book: it would advertise offers nobody has committed
  to. They become `OPEN` on funding.
- ⚠️ **`expired` is computed, not observed.** An offer lapsing emits no on-chain event, so
  nothing will ever arrive to announce it. An `OPEN` offer with `expired: true` is the LP's cue
  to withdraw.
- `lastReconciledAt` on the book is when that escrow was last checked against the chain — use it
  to distinguish "no offers" from "no offers as of an hour ago".

Full request and response shapes: `chainservice/API_REFERENCE.md`. contractservice's are on its
Swagger UI, and the rationale behind them is §15.7.

**Only three chainservice endpoints are new**, because party actions do not need one — the UI
funds and sends. An earlier draft specified relay endpoints taking a `signedTransaction`; they
were built, found to be unusable by the wallet stack, and removed.

#### 15.6f "Refresh from chain" — a user-facing action, not an admin tool

There is **no background poll**. contractservice's marketplace index is fed by the UI reporting
each action once it lands on-chain, and a chain read is the reconciler that catches whatever
bypassed the UI (§15.3a). That read happens when a user asks for it.

**What you call:** `POST /api/marketplace/refresh` on **contractservice** — user-authenticated,
no body needed. It reconciles **the caller's own** escrows and offers, then returns once the
index is updated, so re-reading the offer list afterwards shows the result.

You do **not** call chainservice's refresh directly. The UI does not know which escrows are
live, and that endpoint is service-to-service: it takes an explicit escrow list precisely so the
caller must have decided the scope. contractservice is the only service that can.

**⚠️ Where to put it, and why it is not merely a convenience.** The staleness that costs money
is a missed **acceptance**, not a missed offer. When a seller accepts an offer directly
on-chain, every *other* LP's offer on that escrow becomes stale and withdrawable **at once** —
those LPs have capital they could recover and no way to learn it. So the control belongs where
that bites:

- ✅ On an **LP's own offer list** — "check for updates", next to offers that might already be
  withdrawable.
- ✅ On a **seller's offer book**, where an offer may have been withdrawn or expired since load.
- ❌ Not only on an admin screen. The people who lose by staleness are LPs, and they will never
  see an admin screen.

Show when the data was last reconciled, so a user can tell "no offers" from "no offers as of an
hour ago". After a refresh returns, re-read the offer list — the response reports how many
events were found, but the data itself arrives via contractservice.

### 15.7 contractservice — marketplace index (row 4.7)

> **✅ Done 2026-08-07.** Built as described below: `POST /api/marketplace/events` (ingest,
> idempotent on `(transactionHash, logIndex)` with a unique Mongo index behind it),
> `POST /api/marketplace/refresh` (user-scoped reconcile), and two read endpoints —
> `GET /api/marketplace/escrows/{escrow}/offers` and `GET /api/marketplace/lps/{lp}/offers`.
> Offer state is folded from event history on read rather than stored as a mutable projection.
> 330 tests green. Retained below as the rationale.

**Why you are the store.** The venue keeps **no on-chain offer book** — the factory holds no
per-escrow or per-offer storage (§5.0) — so the only durable index is the one you hold.
chainservice reads the chain and pushes; you store and serve. You never talk to the chain
yourself: no RPC, no ABI, no log parsing.

**1. Receive the push.** `POST /api/marketplace/events`, authenticated with the service API key,
body as documented in `chainservice/API_REFERENCE.md`:

```json
{ "fromBlock": "…", "toBlock": "…", "events": [ { "eventType": "OfferFunded", "vaultAddress": "0x…",
  "escrowContract": "0x…", "transactionHash": "0x…", "blockNumber": "…", "logIndex": "…",
  "timestamp": 1754500000, "payload": { … } } ] }
```

> ⚠️ **IDEMPOTENT, on `(transactionHash, logIndex)`.** A reconcile deliberately re-reads ground
> it has covered before — that is what makes it a reconcile rather than a tail — so the same
> event **will** arrive repeatedly. A repeat must be a no-op, not a duplicate row and not an
> error. `payload` carries whatever that event's ABI declares, so store it loosely: adding an
> event to the contracts should not require a schema change here.

**2. Serve the offer book.** *(Built: `GET /api/marketplace/escrows/{escrow}/offers` and
`GET /api/marketplace/lps/{lp}/offers`.)* Group by `escrowContract` for a seller's view and by the LP address
in the payload for an LP's view. `vaultAddress` is the natural key for one offer — it is unique
per offer and appears on every event about it.

**3. Expose the refresh the UI calls, and drive the reconcile.**

`POST /api/marketplace/refresh` — **user-authenticated**, this is the button's endpoint
(§15.6f). On receipt: work out which escrows this user has a stake in, then call chainservice's
`POST /api/chain/marketplace/refresh` with those escrows and roughly when each became relevant,
store what comes back, and return.

> ⚠️ **Scope it to the caller, not the world.** A refresh is a chain read triggered by a button,
> so an endpoint that reconciles *everything* hands any logged-in user an expensive operation on
> demand — and repeated clicks multiply it. Reconciling only the escrows that user is party to
> (as buyer, seller or LP) bounds the cost, matches what they actually want to see, and is
> naturally cheap because `escrowContract` is an indexed event parameter: the list becomes an
> on-chain topic filter and the node returns logs for those escrows only. **A tight list is a
> cheap query; "everything" is an expensive one.**
>
> Consider a short per-user debounce — returning the previous result for a few seconds — so that
> impatient clicking does not become repeated chain reads.

Reconciling all live escrows is still legitimate as an **operator** action (after an outage, or
a contractservice rebuild); keep it admin-only and separate from the user-facing path.

**4. Compute expiry yourself — it is not an event.** An offer lapsing emits nothing on-chain; it
is a time condition (`offerExpiry` vs now) evaluated lazily when someone acts. No amount of
indexing will surface it. Derive it from the stored `offerExpiry` so the UI can prompt an LP to
withdraw.

**What you must NOT do.** Nothing you store may gate anything the contracts gate — whether an
offer may be accepted, whether a reserve may be set, whether funds move (§15.3a rule 1). Your
index describes; the chain decides. This is the same discipline as §15.5: the reason the
`hasBeenSold` flag lives on the escrow rather than in a service is precisely so that no
off-chain record is ever consulted for a decision.

## 16. Path to Production

Phases 1–2 are sequential builds; phase 0 and phase 4 run in parallel with them. The three
hard gates: **the Safe exists before the implementation deploys** (its address is baked into
bytecode), **counsel reports before audit ends** (a "no" on the fallback design is a
contract change — the one external input that can still reshape §3.3), and **audit clears
before mainnet**.

**Phase 0 — start now, in parallel**
1. ~~Create the `DEFAULT_ARBITER` Safe~~ **done: `0x9bB8e809EA6F5A74f46027D8016641D9cE9A149C`** (2-of-3, verified §13.8). **Still outstanding: execute one test transaction at threshold** — nonce is 0, and this gates the implementation deploy (phase 6.1).
2. Engage counsel on §13.14. Front-load it: this is the only open item that can still change contract code.
3. Fix launch parameters: marketplace fee (25–50 bps proposed), `minOfferBps` (1000), `defaultOfferDuration` (24h proposed) — needed at phase 6, decided cheaply now.

**Phase 1 — escrow implementation (§3.3)**
1. ✅ `EscrowContract`: unseat-on-sale (A), the `NOMINATION_WINDOW` constant (A1), nominate/seat/evict (A1a), the §3.3D consensus guards, `resolvedBuyerPercentage` (C), and every §3.3E knock-on.
2. ✅ `EscrowContractFactory`: signature **unchanged** — the window is a constant, so there is no ABI break to propagate.
3. Tests: all of §14.1 — the end-to-end §8.1a attack replay is the acceptance criterion — plus invariants §14.3.4–6 extending `test/InvariantEscrow.t.sol`.

**Phase 2 — marketplace implementation**
1. `MarketplaceEscrow` per §5/§6: offers, atomic accept, lazy withdrawal, holdback, `minOfferBps`, `Pausable` (inflows only), `sweepToken`, Ownable2Step.
2. Tests: §14.2 plus invariants §14.3.1–3. Integration tests run against real phase-1 clones — the codehash check makes mocks useless by design.

**Phase 3 — audit**
1. Hand over both contracts, this spec, and §14.4 as the scope sheet (lead with: prior `EscrowContract` reviews are void — the dispute model changed).
2. Remediation loop; re-run §14 suites after every fix. **Gate: no mainnet while criticals are open.**

**Phase 4 — off-chain builds (parallel with 1–3)**
1. ~~chainservice — **follow the concrete checklist in §15.4.**~~ **✅ done 2026-08-06 — see §15.4a.** The factory ABI was indeed unchanged, so this was: repoint addresses, pass the Safe as creation arbiter (now *derived* from the implementation rather than configured — §15.4a), retire complete-the-pair, watch-and-prompt vote choreography, sponsorship routing for votes, `ArbiterUnseated` handling, and cohort detection for the two live escrow generations.
1a. **contractservice** — its auto-resolve path still calls the now-retired admin vote. **See §15.5.** Until then, agreed settlements do not complete on-chain.
2. Webapp: §15.1 disclosures and §15.2 flows — the dispute screens (nominate / seat-default / evict / both-party vote prompts) are new surface, not a reskin. **Concrete build note: §15.6** — every disputant now signs their own vote and posts it to the gas-sponsored relay.
3. Subgraph/indexer: §15.3 — offer books, lazy-withdrawability detection, sold-escrow marking.

**Phase 5 — testnet dry run (Base Sepolia)**
1. Deploy the full stack (Safe can be a test Safe) and walk every §4 path end-to-end: create → fund → list → offer → accept → resale; agreed settlement (both-vote flow, sponsored); contested dispute → nomination → fallback seat → evict; holdback release both ways; pause/unpause; sweep.
2. Verify `EXPECTED_ESCROW_CODEHASH` accepts a real factory clone and rejects an old-implementation clone on-chain.

**Phase 6 — mainnet deploy (order is load-bearing, §3.4)**
1. Confirm the production Safe has executed its test transaction.
2. Deploy `EscrowContract` implementation (constructor: Safe address).
3. Deploy `EscrowContractFactory` pointing at it.
4. Deploy `MarketplaceEscrow` (implementation address, phase-0 parameters, owner — **distinct from the Safe**).
5. Verify all three on BaseScan; recompute the codehash against the **final** implementation address; record everything (addresses, Safe signers/threshold) in `DEPLOYMENT_ADDRESSES.md` and the §3.4 table.

**Phase 7 — cutover & launch**
1. Repoint chainservice env at the new factory/implementation (same pattern as the completion-pair variables in `DEPLOYMENT_ADDRESSES.md`). **`ESCROW_IMPLEMENTATION_ADDRESS` is load-bearing, not cosmetic** — chainservice reads `DEFAULT_ARBITER()` from it at startup to determine the creation arbiter (§15.4a), and refuses to start if it can resolve no address at all.
2. Inventory reality (§3.4): the marketplace opens **empty** and fills at the rate new escrows are created. Launch messaging must not promise liquidity on existing deals. Old-implementation escrows stay live to their own terms, permanently invisible to the marketplace.
3. Runbooks before announcement: pause criteria and who holds the owner key; Safe arbitration SLA (§13.8); mistaken-transfer recovery via `sweepToken`.

## 17. Changelog

- **v0.9.0 (2026-08-07): the marketplace no longer pools LP capital — one `OfferVault` per offer replaces the single `MarketplaceEscrow`.** Prompted by a custody concern §13.14 never asked about: the pooled venue commingled every LP's deposit at one platform-deployed address. The technical position was defensible (the owner could reach only genuine surplus; `withdrawFunds` was unpausable) but commingling is a regulatory trigger in its own right, and resting on an unobtained legal reading was the wrong risk. **New shape (§5.0), mirroring the escrow exactly:** `OfferVaultFactory` validates, prices, deploys and keeps the per-escrow registry while **holding no tokens ever**; each offer's capital sits in its own ERC-1167 `OfferVault` clone. Creation is permissionless and **moves no money** — the LP is a parameter, not the caller, so chainservice deploys on a user's behalf without gaining power over funds — and **only the named LP can `fund()`** it. Every vault function answers to exactly one role: `fund`/`withdraw` → the LP, `accept`/`reject` → the escrow's current recipient, `releaseHoldback` → funder or live beneficiary, `sweep` → the factory owner and only above what the vault owes. **Fees pay out to `FEE_RECIPIENT` at acceptance rather than accruing**, so `withdrawFees` is gone and no owner-withdrawable balance exists anywhere in the system. The seller's §3.2 approval now names the individual vault, the narrowest authority the swap can be granted.
  **Economics, validation and lifecycle are unchanged** — §5.1–5.3 and §6 remain authoritative for the rules; §5.0 and the §6 routing table say where they live. The factory retains **no** per-escrow or per-offer state at all — see the next paragraph for where the one cross-offer fact ended up.
  **Cost:** a ~45k-gas clone per offer (well under a cent at current Base prices) and an on-chain offer book that is enumerable per escrow rather than a single mapping — discovery was already off-chain by design (§12, §15.3). **Benefit:** no commingling, blast radius of one offer instead of all of them, conservation checkable per contract, and a narrower approval at the swap.
  **Tests rebuilt: 282 passing.** `test/OfferVault.t.sol` (31) covers the codehash gate, the create/fund split, per-role access control, the swap and fee payout, all five withdrawal conditions, the holdback rules and the sweep bounds — including the §0.4c High restated for this model (two reserve-bearing offers, position returns to the original seller, second acceptance must revert rather than strand the first reserve). `test/InvariantMarketplace.t.sol` restates §14.3 for per-offer custody: **every vault always covers its own obligation**, **the factory never holds a token balance**, status matches obligation, at most one live reserve per escrow, no manufactured consensus, and neither venue nor vault ever holds the cashflow role. **Removed:** `MarketplaceEscrow.sol` and its three suites.
  **The one-reserve rule moved onto the escrow.** `hasBeenSold` is now a flag on `EscrowContract`, set by `transferRecipientFrom` (never `changeRecipient` — an OTC rotation is not a sale, the same line §3.3A draws for arbiter unseating). An interim revision of this design kept it in a factory registry alongside `holdbackVault`, `isVault` and an on-chain offer book; that carried a real hazard — **redeploying the venue would have lost the fact, allowing a second reserve to be stacked on an escrow that already had one**, which `releaseHoldback` would then compensate twice from the second funder's pocket. Putting it where the fact belongs makes the marketplace **stateless per escrow and per offer** and therefore freely redeployable, and lets the offer book fall back to `OfferCreated` events, which §15.3 had already designated the index. **Cost: a new escrow implementation** (new storage ⇒ new bytecode ⇒ new clone codehash ⇒ new escrow factory ⇒ chainservice repoints again). Backwards compatibility was explicitly waived; escrows on `0x77acD2d…` become a third superseded lineage. `DEPLOYMENT_ADDRESSES.md` marks the pair redeploy-pending and the recorded codehash stale.
  **⚠️ Correction to §15.4's item 3, and to this section's first draft: chainservice does not relay transactions.** Three endpoints taking a `signedTransaction` (`submit-resolution-vote`, `nominate-arbiter`, `evict-arbiter`) were built and then **removed** — embedded wallet providers do not expose raw transaction signing, and `getSigner()` is forbidden after connection, so the webapp has no signed transaction to hand over. Gas sponsorship has always worked the other way round: the UI encodes the call, `POST /api/chain/fund-wallet` moves ETH into the user's wallet, and the user's provider broadcasts. `fund-wallet` takes a wei amount rather than an operation name, so it already covers every new action with **no new endpoint**. What survives is what the UI genuinely cannot do: `seat-default-arbiter` (permissionless, relayer-fired) and the arbiter-state read. The same correction applies to the marketplace — chainservice deploys vaults, supplies gas and indexes; it relays none of the five party actions.
  **§15.3 promoted to load-bearing, with two rules added (§15.3a).** Removing the on-chain offer book means the indexer is no longer a convenience — without it there is no book at all. The rules: **index for reading, never for deciding** (nothing off-chain may gate what the contracts gate — the generalisation of §3.3A2a, and why `hasBeenSold` sits on the escrow), and **derive the index from events, not UI reports** (every vault function is callable directly by its party without touching our UI, so a UI-reported index diverges silently). Note this deliberately differs from §15.6b, where the UI reports a settlement vote: that records a *conversation* and gates nothing, whereas the marketplace index mirrors *chain state* and must be built from the chain. **Settled the same day: chainservice does the reading and pushes to contractservice** — not a subgraph — so contractservice never becomes chain-aware, chainservice owns replay from any block, and the push must be idempotent on `(vault, event)`. Row 4.4 folded into new row 4.6, which also carries the marketplace API: chainservice mediates everything, so the webapp never holds an RPC or an ABI (§15.6a).
  **⚠️ Regression against §15.2, recorded in §15.6d:** `releaseHoldback` was permissionless in the pooled design so a keeper could fire it. Restricting vault functions to the deal's parties makes it prompt-only — nobody sweeps up on the parties' behalf. Re-opening it to all callers is safe if unclaimed reserves prove a problem, since both destinations and amounts are fixed by the escrow's final state. **§13.15 added** recording the custody decision; **the escrow model's own custody position and §13.14's arbitration question remain counsel's to confirm.**
- **v0.8.1 (2026-08-06): §3.3A2a revised — the off-chain agreement stage is removed; every vote goes straight on-chain.** Superseding v0.6.1's "negotiate off-chain, then prompt both parties to ratify", a disputant's settlement figure is now submitted as `submitResolutionVote(X)` **the moment they name it**, and the contract is the only place agreement is detected. The retired design had the platform mirror `_checkAndExecuteConsensus` off-chain — recording each side's figure, comparing them, then triggering the votes — which is duplicated logic whose only possible behaviours are *agree with the chain* or *be wrong*, and which created an "agreed off-chain, unsettled on-chain" state that could persist indefinitely and had to be chased. **Removing the mirror removes the state**, and with it contractservice's entire settlement role: §15.5 becomes a deletion rather than a rewrite (no agreement detection, no vote triggering, no chasing). contractservice keeps the genuinely off-chain parts — dispute record, discussion, evidence, notifications.
  **The load-bearing consequence is a UI obligation, added to §15.1.** The contract holds one value per role (the latest) and settles the instant any two of the three match, so **on-chain there is no difference between "I propose 40%" and "I accept 40%"** — every submitted figure is a **binding offer that pays out on match, irreversibly**. §15.6 accordingly forbids sliders, counter-offer threads, or any presentation implying a number can be floated and refined: a user typing the other side's standing figure as an opening anchor has ended the dispute at that figure. Both the counterparty's and any seated arbiter's standing figures must be shown and labelled as settling on match — note **any two of three** settle, so a party matching the *arbiter* ends the dispute without the third party's assent. Figures stay revisable until consensus; each revision is another sponsored transaction, and cheap, since the slot is already non-zero.
  **Measured gas, replacing estimates** (§15.4a): a first vote is ~28k gas all-in, the consensus-triggering vote ~99k (worst observed ~160k) — roughly 10× the first, because the settling transaction executes the whole payout. A fully settled dispute is on the order of a tenth of a cent at sponsored rates, so on-chain revisions cost nothing worth optimising. §15.6 now requires the front-end to size gas **per transaction rather than per flow**: gas-payer funds against whatever the signed transaction declares, so a limit derived from a first vote and reused would strand the settling vote out of gas.
  **Correction to an earlier read of the sponsorship path:** chainservice's `escrow.limit-*` constants do **not** govern relay funding — `GasPayerServiceClient` discards the `gasLimit` argument and gas-payer derives funding from the signed transaction itself. No chainservice gas-limit change was needed or made; the requirement lands on whoever signs.
- **v0.8.0 (2026-08-06): chainservice migrated onto the new contracts (§15.4 complete).** The full §15.4 checklist shipped — **263 tests, 0 failing** — and the outcome is recorded in the new **§15.4a**. The platform now holds no dispute power on any escrow it creates: the complete-the-pair arbiter vote is gone (`/api/vote/submit` returns **410 Gone**), agreed settlements are pushed by both disputants through a sponsored `submit-resolution-vote` relay, and the §3.3 arbiter surface (nominate / seat-default / evict, plus the seat-state read and the four arbiter events) is exposed with cohort detection so legacy-implementation escrows are never offered actions they do not have.
  **One deliberate amendment to §15.4 item 1: the creation arbiter is now DERIVED, not configured.** Item 1's "pass `0x9bB8e809…` explicitly" is correct but guards only half the failure — a configured address that is well-formed yet **wrong** passes every validation and produces permanently mis-arbitered escrows, invisible until a dispute. The root confusion is that `DEFAULT_ARBITER` (an implementation `immutable`, fallback-only) and `ARBITER` (per-clone storage, set from `createEscrowContract`'s 7th argument) are *different addresses* that coincide only because we pass the same value; omitting the argument does not fall back to the immutable, because the factory substitutes `msg.sender` before `initialize` can reject the zero. chainservice therefore reads `DEFAULT_ARBITER()` off the configured implementation at startup and passes that, making the per-escrow value a derivation of the immutable one. `DEFAULT_ARBITER_ADDRESS` survives as an **assertion** — a mismatch with the bytecode refuses startup — and with neither source available the service refuses to start rather than defaulting. **Consequence for §16 phase 7: `ESCROW_IMPLEMENTATION_ADDRESS` is the load-bearing variable, not `DEFAULT_ARBITER_ADDRESS`.**
  **Three latent defects surfaced by the migration**, all recorded in §15.4a: the factory's new `ArbiterMustBeDistinct` error is now pre-checked rather than hit as an opaque revert; an explicitly-zero caller-supplied arbiter now resolves to the Safe instead of being forwarded (zero is never an override, only the factory's substitution trigger); and refreshing the ABI against the live implementation exposed two call sites — `resolveDispute(uint256,uint256)` and `USDC_TOKEN()` — that exist in no deployed ABI and had been throwing before reaching the chain.
  **Knock-on left open (§0.1 row 4.2), written up for its owning team as the new §15.5:** `contractservice`'s auto-resolve path still calls the retired admin vote. It fails safely and loudly, but agreed settlements will not complete on-chain until it is changed to have both parties vote themselves. Rows 4.3 (webapp dispute screens) and 4.4 (subgraph) remain untouched.
- **v0.7.0 (2026-08-06): BUILD RELEASE — §3.3 and `MarketplaceEscrow` implemented.** Both contracts are written and tested (**311 passing**); build log, per-item checklists, deviations, test-coverage map and self-audit findings are in the new **§0**. **Three substantive design changes came out of the build, all recorded in §0.4:**
  **(1) The arbiter nomination window became a 72-hour CONSTANT (`NOMINATION_WINDOW`), superseding §3.3A1's per-escrow parameter.** The parameter put the choice in the hands of whoever *creates* the escrow while the cost falls on the LP who buys later — and in the §8.1a attack the creator is the adversary, so a creator-chosen window was a creator-chosen hostage duration. It also bought the honest parties nothing, since `nominateArbiter` has no deadline check and a match seats right up until the fallback executes. §3.3A1's "no maximum / self-limiting because it is public before purchase" argument additionally failed on its own terms: nothing in the sale path reads the value, so the protection rested on an LP's client surfacing it. **Consequence: `initialize` and `createEscrowContract` keep their ORIGINAL signatures, so §13.9's factory ABI break disappears** — integrators repoint at new addresses and change no call sites. An interim revision that kept the parameter under a 30-day cap is also superseded.
  **(2) A saturating `nominationDeadline` was identified as a vulnerability, not a mitigation.** Clamping at `type(uint64).max` makes `block.timestamp > nominationDeadline` unsatisfiable, i.e. a *permanently unseatable* fallback and a permanent hostage state; a truncating cast, by contrast, wraps into the past and is benign. With a constant window the branch is unreachable and has been removed — if the window ever becomes caller-influenced again, overflow must **revert**, never clamp.
  **(3) `initialize` now also rejects `_buyer`/`_seller == DEFAULT_ARBITER`**, closing the creation-time half of a hazard §3.3A1a only guarded on transfer: `seatDefaultArbiter` is permissionless, so a party equal to the fallback would let anyone collapse two of three voting roles into one address.
  **Self-audit (§0.4c) found one High-severity bug, fixed:** `acceptOffer` did not re-check `hasBeenSold`, so a second holdback-bearing offer could **overwrite a live reserve record** while still crediting `totalHoldbacks` — stranding the first reserve permanently (unreleasable, and excluded from `sweepToken`). Reachable whenever a sold position returns to its original seller. Conservation still held throughout, so no invariant caught it — the loss is liveness, not solvency. §6.2 gains step 4a and §6.4 gains a matching withdrawability condition so the blocked LP is not locked in until expiry. Two findings remain **open for decision**: M-1 (`releaseHoldback` pays beneficiary and funder in one transaction, so a blocked beneficiary blocks the funder, with no remedy since the recipient cannot rotate after settlement) and L-2 (`renounceOwnership` is inherited and would permanently strand accrued fees).
  **Testing lesson recorded in §0.4b:** every original window test measured against the window/cap constant itself — one fuzz case bounded its own input by the constant whose removal it should have detected — so all of them passed when the cap was raised tenfold. Replaced with a liveness guard that asserts the *property* against a fixed tolerance, and mutation-tested at each design stage to prove it actually fails.
  **Deploy tooling (§3.4):** the escrow + factory path is wired into GitHub Actions. `DEFAULT_ARBITER` is supplied via the `DEFAULT_ARBITER_ADDRESS` environment variable with no default, and the script refuses to run if it is unset, zero, equal to the relayer/owner, or has no deployed code on the target chain — the last of which requires a **test Safe on any testnet you deploy to**. `MarketplaceEscrow` still has no deploy script.
- **v0.6.1 (2026-08-05):** **Added §3.3A2a — agreed settlements are pushed on-chain by the two disputants themselves, on ALL escrows.** Companion decision: **the creation arbiter is the `DEFAULT_ARBITER` Safe on every chainservice-created escrow** — the operational hot wallet retains no dispute power anywhere, retiring the complete-the-pair mechanism platform-wide and extending "the platform can never move funds alone" to unsold escrows. The arbiter takes no action of any kind in an agreed settlement; both disputants are UI-prompted to cast `submitResolutionVote(X)` (same two-transaction cost as today, second signature moves from platform to second party), with votes routed through the existing gas-sponsorship path so zero-ETH wallets settle fine. `settleBySignatures` (EIP-712 relay) considered and rejected — the webapp wallet-provider stack does not reliably support typed-data signing. §13.8 re-scoped: the Safe adjudicates every contested dispute platform-wide, so signer set/threshold are sized for volume; no fund-safety deadline exists. §13.9 extended with the chainservice changes (pass the Safe at creation, retire auto-complete, watch-and-prompt, sponsorship routing). **Settled §13.4:** `evictArbiter` — either disputant may clear a seat silent for 30 days (rolling clock: seating, dispute-raise, or last vote change); nominations reopen, window restarts, Safe re-seats on expiry; swaps the third voter only, never moves funds. **Settled §13.10:** fee incidence stays seller-pays (simplest; LPs price it in); noted the marketplace fee is distinct from the 1% creation fee and expected at 25–50 bps (§13.1). **Settled §13.12:** minimum-offer floor becomes owner-configurable `minOfferBps` (launch 1000 = 10%, cap 10000, new offers only) — the fixed 50% floor banned the deep discounts §8.1a shows are the safest LP trades. **Settled §13.13:** emergency pause, inflows only (`createOffer` + `acceptOffer`); exits structurally unpausable (§5.2.10). **Settled §13.3:** `sweepToken` ships in v1 (§6.6). **Settled §13.11:** `reviseOffer` deferred, confirmed. **Added §14 Test & Audit Plan** — mandatory pre-audit test set (vote-trap trio, end-to-end §8.1a attack replay, window immutability, eviction clock, holdback/`_executeResolution` rounding consistency, pause asymmetry), six fuzz invariants, audit scope with prior-review-void warning and the accepted-residuals list. **Added §15 UI & Off-Chain Obligations** — collects every protection deliberately delegated from contract to UI (nomination warning, seller-net disclosure, LP evidence-asymmetry disclosure, holdback-travels display), the multi-tx choreography (5-min accept TTL, both-party vote prompts, lazy withdrawal detection), and indexing/curation duties. **Added §16 Path to Production** — seven phases with the three hard gates (Safe before implementation deploy; counsel before audit ends; audit before mainnet). Changelog renumbered → §17.
- **v0.6.0 (2026-08-04):** **§3.3A redesigned: sale-triggered arbiter reset replaces dispute-time selection.** `initialize` keeps its arbiter parameter and the primary market keeps today's dispute flow exactly — the machinery now activates only when a cashflow is sold. `transferRecipientFrom` automatically unseats the incumbent arbiter in the same transaction as the sale (automatic, not objection-based: an opt-in objection loses the race where the attacker-seller bundles `acceptOffer` → dispute → both votes in one block). Re-seating requires buyer + new recipient matching nominations (re-confirming the incumbent is the expected common case, allowed pre-dispute); a dispute while unseated opens the nomination window; on expiry the default-arbiter fallback becomes seatable, but a late match still wins until the fallback actually executes. `changeRecipient` does not unseat (wallet rotation shouldn't evict a legitimate arbiter; OTC transfers get no marketplace protections). Also fixed a Solidity-level error in A1a: `DEFAULT_ARBITER` must be an implementation-constructor immutable (a permissionless-`initialize` parameter would let self-dealt clones install their own fallback, resurrecting the attack through the fallback itself) — hence it must be a multisig, since rotation now requires a full redeploy; `arbiterNominationWindow` cannot be a Solidity `immutable` in a clone (storage, set once in `initialize`, no setter — kept as a factory parameter by decision, accepting the ABI change). Holdback fee lines (§2, §8.5a) updated for `netAmount = X − fee − holdback`; `funder` precision note (first *marketplace* sale); header/§3.4/§8.1a/§11 aligned. **Renamed `SYSTEM_ADMIN` → `DEFAULT_ARBITER`** (and `seatFallbackArbiter` → `seatDefaultArbiter`): the role is fallback arbitration only — it has no operational powers and never signs escrow creations, so the "admin" name invited confusion with chainservice's hot wallet and the marketplace owner.
- **v0.5.0 (2026-08-04):** Spec review against the implemented contracts. **Identified the self-dealt-escrow attack (§8.1a):** `initialize()` is permissionless, so the §8.1 codehash check proves the *code* is genuine but says nothing about the *parties* — an attacker controlling buyer + arbiter can sell to an LP and then vote a full refund, at a profit of `P(r − d)`. Closed by new **§3.3**: the arbiter is chosen at dispute time with a current-recipient veto and a default-arbiter fallback (so a 2-of-3 majority cannot be pre-loaded). **The residual became an invoice-factoring holdback** (§5.3, §6.7): the LP advances part of the price and retains a reserve, released to the seller once the cashflow is collected and applied to the LP's shortfall if it is not. Funded from the **seller's** proceeds, so it gives LPs first-loss protection without touching any buyer's refund rights — an earlier draft capped the buyer's refund instead, which taxed honest buyers in ordinary escrows to deter a marketplace-specific attack. **One reserve per escrow, set on the first sale only**, with the beneficiary read live at settlement so it follows the position through any number of resales: the reserve is recourse against the party who *performs*, and a reselling LP performed nothing. A per-sale waterfall was specified and then dropped as a strictly larger mechanism answering a different question (adverse selection, not performance) — deferred, not foreclosed. Resolution has **no deadline** and the arbiter's vote is **never binding on its own** — the platform can therefore never move funds alone, which is both the security property and the regulatory one (§3.3A2, §13.14). A curated arbiter registry was specified and then dropped: an LP can never buy into a disputed escrow, so the nomination veto already provides what a list would have (§3.3B). §3.3 is an `EscrowContract` change and is **not yet implemented**. Added **§3.0** (`CompletionEscrowContract` is out of scope — no maturity, and `payees[]` has no single transferable role) and **§3.4** (launch precondition: the live implementation predates §3.2/§3.3, so the marketplace opens with zero inventory until a new implementation and factory ship). **Removed `OfferStatus.COMPLETED`** — it was write-only dead state that permanently barred an (escrow, LP) pair from re-bidding, quietly capping resale at one round-trip per address; `acceptOffer` now deletes the slot (§5.2.1, §6.2.5). Resolved the §2-vs-§5.1 contradiction on fee incidence (the **seller** bears it, §8.5a). Corrected invariant §5.2.2 (codehash is checked once at creation — a clone's codehash is immutable, so re-checking is pure gas). Added `nonReentrant` to `rejectOffer` per §11. Documented the 50% floor as a spam guard with price-floor side effects. Added missing errors/events, and §13.4–13.14 (silent-arbiter re-seating, residual sizing, admin key, migration, fee convention, `reviseOffer`, the minimum-offer floor, emergency pause, regulatory perimeter). Settled during review: §13.4's window (per-escrow, 72h default, immutable, unbounded — a hostile window is self-limiting because it is public before purchase), §13.5's holdback mechanism (only resale chains remain open), §13.6 (no registry) and §13.7 (moot).
- **v0.4.2 (2026-07-06):** Full-spec re-review. **Fixed spoofable provenance:** replaced the `FACTORY()` self-report with an unforgeable ERC-1167 codehash check (`EXPECTED_ESCROW_CODEHASH`) — no factory/escrow changes needed. Widened `withdrawFunds` so LPs exit immediately when an escrow becomes permanently unacceptable (disputed/settled; state 2 never returns to 1). Documented firm quotes (LPs cannot cancel OPEN offers — prevents accept-front-run bait-and-switch). Minimum offer now `max(payout/2, 1)` (dust edge). `setDefaultOfferDuration` requires `> 0`. Added constructor spec (§5.1a), blacklist-token residual risk, and the per-grant (reusable) one-shot clarification.
- **v0.4.1 (2026-07-06):** Escrow §3.2 implemented. Approval now binds **operator + exact destination** (decision: even a malicious operator can only execute the sanctioned move) and carries a **5-minute TTL** (decision: covers only the human gap between the two signed transactions; prevents indefinite dangling approvals). Event finalized as `RecipientTransferApproved(operator, newRecipient, expiry)`.
- **v0.4 (2026-07-06):** Adversarial review. Replaced two-tx custody flow with atomic approve-and-pull (kills stale-seller theft, custody-window fund stranding, expire-restore griefing, reclaim deadlock). Added: factory provenance check, funded/undisputed/unclaimed gate at create+accept, per-escrow token support with per-token fee accounting (`accruedFees`), deposit/fee segregation (`totalDeposits`), empty-slot requirement (fixes deposit overwrite), 50%-of-payout minimum offer, balance-delta deposit guard, mandatory `nonReentrant`, lazy expiry/staleness (removed `expireOffer`, `reclaimRecipient`, enumeration array, O(N) cancel loop, `EXPIRED`/`BLOCKED` states, `payable`). Escrow additions specified: `approveRecipientTransfer` / `transferRecipientFrom` (one-shot operator).
- **v0.3 (2026-07-06):** Recorded escrow-side interface implementation; `changeRecipient` extended to disputed state.
- **v0.2 (2026-07-01):** Initial draft.
