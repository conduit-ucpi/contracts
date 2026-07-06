# Stabledrop Liquidity Marketplace — Contract OpenSpec

**Version:** 0.3  
**Date:** 2026-07-06  
**Status:** Escrow interface implemented; `MarketplaceEscrow` contract pending  
**Scope:** MarketplaceEscrow smart contract only. Builds on the deployed StabledropEscrow (`EscrowContract`), which now exposes a `changeRecipient` function callable only by the current recipient. Note: the escrow is no longer fully immutable — the seller (recipient) address is reassignable by the current recipient; all other roles remain fixed.

---

## Implementation Status (2026-07-06)

The underlying `EscrowContract` now implements everything §3 assumes:

| Requirement | Status |
|---|---|
| `recipient() → address` | ✅ returns current SELLER |
| `maturity() → uint256` | ✅ returns EXPIRY_TIMESTAMP (0 = instant transfer) |
| `hasActiveDispute() → bool` | ✅ true while `_state == 2` |
| `changeRecipient(address)` callable only by current recipient | ✅ |
| Bonus: `token()`, `payoutAmount()` (net of fee) for LP pricing | ✅ |

**Deviation from original assumption — resolved in favour of the marketplace:** `changeRecipient` is permitted while the escrow is **funded OR disputed** (not funded-only). This lets the marketplace hand the recipient role back to the seller even if the buyer disputes while the marketplace holds it, avoiding stranded funds. It is safe: the arbiter can never share the seller's address (no vote-collapse), a reassignment only ever resets the seller's own vote to "not voted" (cannot manufacture consensus), and buyer + arbiter remain a 2-of-3 majority so a seller cannot stall resolution. `changeRecipient` reverts once the escrow is claimed/resolved (`_state == 4`).

**Guards the `MarketplaceEscrow` must enforce on its side (see §6, §11):**
- Reject escrows with `maturity() == 0` (instant transfers — no locked cashflow).
- When calling `changeRecipient(lp)`, `lp` must not be the escrow's buyer or arbiter (the escrow reverts otherwise) — pre-check for a clean error.
- Handle the escrow already being claimed/resolved (`changeRecipient` / accept will revert).

---

## 1. Overview

The Stabledrop Liquidity Marketplace enables escrow recipients (sellers) to sell their locked cashflows to liquidity providers (LPs) at a discount via an atomic, trustless swap. There is no UI dependency — the contract is fully operable via direct on-chain interaction by any wallet.

---

## 2. Actors

| Actor | Description |
|---|---|
| **Seller** | Current recipient of a StabledropEscrow. Wants immediate liquidity at a discount. |
| **LP (Liquidity Provider)** | Any wallet. Makes offers by depositing funds into the MarketplaceEscrow contract. |
| **Protocol** | Collects a configurable fee from LP deposits at time of offer creation. |
| **Owner** | Controls the fee rate. Cannot interfere with individual escrow transactions. |

---

## 3. Assumptions / Prerequisites

- The underlying StabledropEscrow contract exposes:
  - `recipient() → address` — current recipient
  - `maturity() → uint256` — UNIX timestamp at which funds release
  - `hasActiveDispute() → bool` — whether a dispute is currently open on this escrow
  - `changeRecipient(address newRecipient)` — callable only by `recipient()`
- Acceptance is a two-transaction sequence initiated by the seller: (1) seller calls `changeRecipient(marketplaceContractAddress)` on the underlying escrow, (2) seller calls `acceptOffer` on the MarketplaceEscrow contract, which verifies recipient status and executes the swap atomically.
- All amounts are in USDC (or the stablecoin denomination of the underlying escrow).

---

## 4. Offer Lifecycle

```
LP deposits → Offer created (OPEN)
                    │
          Seller calls changeRecipient (tx 1, on underlying escrow)
                    │
          Seller calls acceptOffer (tx 2, on marketplace contract)
                    │
          Atomic swap executes → COMPLETED
                    │
          Seller rejects → LP withdraws full amount → CANCELLED
                    │
          Offer time limit expires (seller never acted) → LP withdraws full amount → EXPIRED
                    │
          Dispute active at acceptance time → tx reverts; LP withdraws full amount
```

---

## 5. Contract: MarketplaceEscrow

### 5.1 State

```solidity
struct Offer {
    address escrowContract;     // The underlying StabledropEscrow being sold
    address seller;             // Original recipient at time of offer creation
    address lp;                 // LP wallet that made the offer
    uint256 offerAmount;        // Gross amount deposited by LP (before fee)
    uint256 netAmount;          // Amount seller receives (offerAmount minus fee)
    uint256 fee;                // Protocol fee retained
    uint256 offerExpiry;        // UNIX timestamp after which LP can withdraw if unaccepted
    OfferStatus status;         // OPEN | COMPLETED | CANCELLED | EXPIRED | BLOCKED
}

enum OfferStatus { OPEN, COMPLETED, CANCELLED, EXPIRED, BLOCKED }

mapping(bytes32 => Offer) public offers;
// Key: keccak256(abi.encodePacked(escrowContract, lp))
// Enforces one active offer per LP per escrow

uint256 public feeRateBps;      // Fee in basis points, e.g. 100 = 1%
address public owner;
uint256 public defaultOfferDuration = 24 hours;  // Configurable per offer
```

### 5.2 Key Invariants

1. One active offer per LP per escrow address. An LP may not create a second offer on the same escrow while their first is `OPEN`.
2. Offer expiry must be strictly less than escrow maturity, verified on-chain at offer creation time by reading `escrowContract.maturity()`.
3. The atomic swap will revert if `escrowContract.hasActiveDispute()` returns true at execution time.
4. The seller may only accept one offer per escrow. Accepting an offer auto-cancels all other `OPEN` offers on the same escrow in the same transaction, with LP funds made available for withdrawal.
5. The protocol fee is computed at offer creation time and held as part of the LP's deposit. It is only transferred to the protocol on successful acceptance. If an offer is cancelled, rejected, or expired, the full gross amount (including the computed fee) is returned to the LP.

---

## 6. Functions

### 6.1 `createOffer`

```solidity
function createOffer(
    address escrowContract,
    uint256 offerAmount,        // Gross amount LP is depositing
    uint256 offerDurationSeconds // Duration of offer window; 0 = use default
) external payable
```

**Logic:**

1. Derive offer key: `keccak256(abi.encodePacked(escrowContract, msg.sender))`
2. Assert no `OPEN` offer exists for this key.
3. Read `escrowContract.maturity()` on-chain. Compute `offerExpiry = block.timestamp + offerDurationSeconds (or defaultOfferDuration)`. Assert `offerExpiry < escrowContract.maturity()`.
4. Read `escrowContract.recipient()`. Store as `seller`.
5. Assert `escrowContract.hasActiveDispute() == false`. (Belt-and-braces — swap will also check, but no point accepting an offer on a disputed escrow.)
6. Compute `fee = offerAmount * feeRateBps / 10000`. Compute `netAmount = offerAmount - fee`. Store both on the offer — fee is not transferred to protocol at this point.
7. Transfer `offerAmount` (gross) from LP to contract via `USDC.transferFrom` (see §8).
8. Store `Offer` with status `OPEN`.
9. Emit `OfferCreated(escrowContract, msg.sender, offerAmount, netAmount, fee, offerExpiry)`.

---

### 6.2 `acceptOffer`

```solidity
function acceptOffer(
    address escrowContract,
    address lp               // Which LP's offer the seller is accepting
) external
```

**Pre-condition (Transaction 1 — seller, outside this contract):**  
Seller calls `changeRecipient(address(marketplaceContract))` on the underlying StabledropEscrow. This is a separate transaction. Without it, step 5 below will revert.

**Logic (Transaction 2 — seller calls `acceptOffer`):**

1. Derive offer key for `(escrowContract, lp)`. Assert offer status is `OPEN`.
2. Assert `msg.sender == offer.seller`. (Only the original seller can accept.)
3. Assert `block.timestamp <= offer.offerExpiry`.
4. Assert `escrowContract.hasActiveDispute() == false`. Revert if dispute active.
5. Assert `escrowContract.recipient() == address(this)`. Revert with `RecipientNotTransferred` if seller has not completed Transaction 1.
6. **Atomic execution (within this transaction):**
   a. Set offer status to `COMPLETED`. (State change first — reentrancy guard.)
   b. Call `escrowContract.changeRecipient(lp)` — transfers cashflow ownership to LP.
   c. Transfer `offer.netAmount` to `offer.seller`.
   d. Transfer `offer.fee` to protocol (retained in contract balance, withdrawable by owner).
7. **Cancel all other OPEN offers** on `escrowContract` in the same transaction:
   - Iterate over all `OPEN` offers for this `escrowContract` (see §7 for enumeration approach).
   - Set each to `CANCELLED`. Full gross LP funds remain in contract, withdrawable by each LP via `withdrawFunds`.
8. Emit `OfferAccepted(escrowContract, lp, offer.netAmount, offer.fee)`.
9. Emit `OfferCancelled(escrowContract, otherLp)` for each cancelled offer.

> **Gas note:** Cancelling N competing offers in one transaction is O(N) on Base. Gas costs are negligible on L2 but the enumeration data structure must support iteration — see §7.

---

### 6.3 `rejectOffer`

```solidity
function rejectOffer(
    address escrowContract,
    address lp
) external
```

**Logic:**

1. Assert offer status is `OPEN`.
2. Assert `msg.sender == offer.seller`.
3. Set offer status to `CANCELLED`.
4. LP funds available for withdrawal via `withdrawFunds`.
5. Emit `OfferRejected(escrowContract, lp)`.

---

### 6.4 `withdrawFunds`

```solidity
function withdrawFunds(
    address escrowContract
) external
```

**Logic:**

1. Derive offer key for `(escrowContract, msg.sender)`.
2. Assert offer status is `CANCELLED` or `EXPIRED`. (Not `OPEN`, not `COMPLETED`.)
3. Transfer `offer.offerAmount` (full gross amount, including computed fee) back to LP.
4. Delete or zero-out the offer record.
5. Emit `FundsWithdrawn(escrowContract, msg.sender, amount)`.

---

### 6.5 `expireOffer`

```solidity
function expireOffer(
    address escrowContract,
    address lp
) external
```

Anyone can call this to mark an offer as expired once `block.timestamp > offer.offerExpiry` and status is `OPEN`. This enables keepers or the LP themselves to trigger the status transition before calling `withdrawFunds`.

**Logic:**

1. Assert offer status is `OPEN`.
2. Assert `block.timestamp > offer.offerExpiry`.
3. Set status to `EXPIRED`.
4. If `escrowContract.recipient() == address(this)`, call `escrowContract.changeRecipient(offer.seller)` — restores seller's recipient status automatically.
5. Emit `OfferExpired(escrowContract, lp)`.
6. If recipient was restored, emit `RecipientRestored(escrowContract, offer.seller)`.

---

### 6.5a `reclaimRecipient`

```solidity
function reclaimRecipient(
    address escrowContract,
    address lp
) external
```

Allows the seller to manually restore their recipient status on the underlying escrow at any time while the marketplace contract holds it. Covers the case where the seller transferred recipient status but decides not to proceed.

**Logic:**

1. Derive offer key for `(escrowContract, lp)`. Assert offer status is `OPEN`.
2. Assert `msg.sender == offer.seller`.
3. Assert `escrowContract.recipient() == address(this)`. Revert with `NotCurrentRecipient` if not.
4. Call `escrowContract.changeRecipient(offer.seller)`.
5. Set offer status to `CANCELLED`. LP funds available for withdrawal via `withdrawFunds`.
6. Emit `RecipientRestored(escrowContract, offer.seller)`.
7. Emit `OfferCancelled(escrowContract, lp)`.

---

### 6.6 `setFeeRate` (Owner only)

```solidity
function setFeeRate(uint256 newFeeRateBps) external onlyOwner
```

- Assert `newFeeRateBps <= 1000` (hard cap at 10% — sanity guard).
- Fee rate change applies to new offers only. Existing offers retain the fee computed at creation.

---

### 6.7 `setDefaultOfferDuration` (Owner only)

```solidity
function setDefaultOfferDuration(uint256 durationSeconds) external onlyOwner
```

---

### 6.8 `withdrawFees` (Owner only)

```solidity
function withdrawFees(address to, uint256 amount) external onlyOwner
```

Withdraws accumulated protocol fees from contract balance.

---

## 7. Data Structure: Offer Enumeration

To support cancellation of all competing offers in `acceptOffer`, the contract must be able to enumerate all `OPEN` offers per escrow address.

**Recommended approach:**

```solidity
mapping(address => address[]) private escrowOfferLPs;
// escrowContract → array of LP addresses with active offers
```

On `createOffer`: push `msg.sender` to `escrowOfferLPs[escrowContract]`.  
On cancellation/expiry/completion: remove from array (swap-and-pop pattern).

This gives O(N) iteration where N = number of active offers per escrow. In practice N will be small (single digits) for pilot scale.

---

## 8. Token Handling

The underlying StabledropEscrow holds USDC (ERC20). The MarketplaceEscrow contract must therefore handle ERC20 transfers, not native ETH.

- LP calls `USDC.approve(marketplaceContract, offerAmount)` before calling `createOffer`.
- `createOffer` calls `USDC.transferFrom(msg.sender, address(this), offerAmount)`.
- `acceptOffer` calls `USDC.transfer(seller, netAmount)`.
- `withdrawFunds` calls `USDC.transfer(lp, amount)`.

The USDC contract address on Base must be set at deployment and immutable (or owner-settable with a timelock — TBD).

---

## 9. Events

```solidity
event OfferCreated(address indexed escrowContract, address indexed lp, uint256 offerAmount, uint256 netAmount, uint256 fee, uint256 offerExpiry);
event OfferAccepted(address indexed escrowContract, address indexed lp, uint256 netAmount, uint256 fee);
event OfferRejected(address indexed escrowContract, address indexed lp);
event OfferCancelled(address indexed escrowContract, address indexed lp);
event OfferExpired(address indexed escrowContract, address indexed lp);
event FundsWithdrawn(address indexed escrowContract, address indexed lp, uint256 amount);
event FeeRateUpdated(uint256 newFeeRateBps);
```

---

## 10. Errors

```solidity
error OfferAlreadyExists(address escrowContract, address lp);
error OfferNotOpen(address escrowContract, address lp);
error OfferExpiredError(address escrowContract, address lp);
error NotSeller(address escrowContract, address caller);
error DisputeActive(address escrowContract);
error RecipientNotTransferred(address escrowContract);
error OfferExpiryExceedsEscrowMaturity(uint256 offerExpiry, uint256 escrowMaturity);
error InsufficientAllowance();
error FeeTooHigh(uint256 requested, uint256 max);
```

---

## 11. Security Considerations

| Risk | Mitigation |
|---|---|
| Reentrancy on `acceptOffer` | Use checks-effects-interactions pattern. Update offer status to `COMPLETED` before external calls. Consider `ReentrancyGuard`. |
| Seller front-running | Seller could change recipient back before `acceptOffer` executes. Step 5 of `acceptOffer` asserts `recipient() == address(this)` — tx reverts cleanly if not. |
| Malicious escrow contract | A crafted escrow could return false values from `hasActiveDispute()` or `maturity()`. Spec does not address this — out of scope for pilot; note for audit. |
| Fee drain by owner | Owner can call `withdrawFees` freely. No timelock in this spec. Acceptable for pilot; revisit pre-mainnet scale. |
| Offer enumeration gas ceiling | If N offers per escrow grows large, cancellation loop could hit gas limits. Acceptable on Base at pilot scale; note for audit. |

---

## 12. Out of Scope (This Spec)

- Offer discovery / indexing (off-chain, handled by UI and subgraph)
- Yield on escrowed USDC
- Multi-stablecoin support
- Upgradability / proxy pattern
- Timelock on fee/owner changes
- Whitelisting of escrow contracts

---

## 13. Open Questions (Requiring Decision Before Audit)

1. **USDC address governance** — immutable at deploy, or owner-settable?
2. **Owner model** — EOA, multisig, or governance? For pilot, EOA is likely sufficient.
3. **Fee rate at launch** — to be decided.
