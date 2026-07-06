# Stabledrop Liquidity Marketplace — Contract OpenSpec

**Version:** 0.4
**Date:** 2026-07-06
**Status:** Escrow side fully implemented (incl. §3.2 atomic-swap support); `MarketplaceEscrow` contract pending
**Scope:** MarketplaceEscrow smart contract, plus two small additions to `EscrowContract` that make the swap atomic.

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
| **Protocol** | Collects a configurable fee from LP deposits, accrued at acceptance time. |
| **Owner** | Controls the fee rate and default offer duration (Ownable2Step). Cannot interfere with individual escrow transactions or touch LP deposits. |

---

## 3. Escrow Interface

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
| `FACTORY() → address` | The factory that created the escrow — used for provenance verification (§8.1) |

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

> Deployment note: existing deployed escrows are immutable and will not have these functions. The marketplace serves escrows created by the **new** factory/implementation deployment only, enforced by the provenance check (§8.1).

---

## 4. Offer Lifecycle

```
LP deposits token → Offer created (OPEN)
        │
        ├─ Seller: escrow.approveRecipientTransfer(marketplace, lp)  (tx 1, on escrow, 5-min TTL)
        │  Seller: marketplace.acceptOffer(escrow, lp)            (tx 2, atomic swap)
        │        → role pulled to LP, seller paid, fee accrued → COMPLETED
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

## 5. Contract: MarketplaceEscrow

### 5.1 State

```solidity
struct Offer {
    address escrowContract;   // The underlying escrow being sold
    address seller;           // recipient() at offer creation — offer is valid only while this holds
    address lp;               // LP wallet that made the offer
    address token;            // escrow.token() at creation; all transfers for this offer use it
    uint256 offerAmount;      // Gross amount deposited by LP (before fee)
    uint256 netAmount;        // Amount seller receives (offerAmount − fee)
    uint256 fee;              // Protocol fee, computed at creation, accrued only on acceptance
    uint256 offerExpiry;      // Timestamp after which the LP may withdraw
    OfferStatus status;       // OPEN | COMPLETED | CANCELLED
}

enum OfferStatus { NONE, OPEN, COMPLETED, CANCELLED }   // NONE = empty slot (default)

mapping(bytes32 => Offer) public offers;
// Key: keccak256(abi.encodePacked(escrowContract, lp))
// One offer record per (escrow, LP). Slot is freed (deleted) on withdrawal.

address public immutable TRUSTED_FACTORY;               // provenance check (§8.1)
uint256 public feeRateBps;                              // e.g. 100 = 1%; hard cap 1000 (10%)
uint256 public defaultOfferDuration;                    // e.g. 24 hours
mapping(address => uint256) public accruedFees;         // per-token protocol fees (§8.5)
mapping(address => uint256) public totalDeposits;       // per-token sum of live LP deposits (§8.6)
```

There is **no offer-enumeration array**. Competing offers are invalidated lazily by the staleness rule, so no O(N) cancellation loop exists (removes the sybil gas-DoS on `acceptOffer`).

### 5.2 Key Invariants

1. **Slot integrity:** `createOffer` requires the (escrow, lp) slot to be `NONE`. A cancelled/expired-but-unwithdrawn offer still owns its slot and its deposit; it can never be overwritten.
2. **Sellable escrow only:** at `createOffer` AND `acceptOffer` the escrow must be funded, undisputed, unclaimed, non-instant (`maturity() != 0`), created by `TRUSTED_FACTORY`, and `offerExpiry < maturity()`.
3. **Live seller:** an offer is acceptable only while `escrow.recipient() == offer.seller` and only by that address. Any recipient change makes every existing offer on that escrow permanently stale (withdrawable, never acceptable). Payment always goes to `msg.sender == offer.seller == recipient()` — a stale snapshot can never be paid.
4. **Minimum offer:** `offerAmount >= escrow.payoutAmount() / 2` (at least 50% of face value).
5. **Fee containment:** protocol fees accrue to `accruedFees[token]` only at acceptance. `withdrawFees` is capped by `accruedFees[token]` — the owner can never touch LP deposits. Cancelled/expired/stale offers refund the **full gross** amount including the computed fee.
6. **No custody:** the marketplace address is never the escrow recipient at rest. The role moves seller → LP within a single `acceptOffer` transaction.
7. **Conservation:** for every token, `balanceOf(marketplace) >= totalDeposits[token] + accruedFees[token]` (excess = accidental transfers, sweepable §8.7).

---

## 6. Functions

### 6.1 `createOffer`

```solidity
function createOffer(
    address escrowContract,
    uint256 offerAmount,
    uint256 offerDurationSeconds   // 0 = use defaultOfferDuration
) external nonReentrant            // NOT payable — this is an ERC20 contract
```

**Logic:**

1. Require `EscrowContract(escrowContract).FACTORY() == TRUSTED_FACTORY` (revert `UntrustedEscrow`).
2. Derive key `keccak256(abi.encodePacked(escrowContract, msg.sender))`; require `offers[key].status == NONE` (revert `OfferSlotOccupied`).
3. Require `maturity() != 0` (revert `InstantEscrowNotSupported`).
4. Require sellable: `isFunded() && !hasActiveDispute() && !isClaimed()` (revert `EscrowNotSellable`). Protects the LP from offering on unfunded or already-settled escrows.
5. `offerExpiry = block.timestamp + (offerDurationSeconds == 0 ? defaultOfferDuration : offerDurationSeconds)`; require `offerExpiry < maturity()` (revert `OfferExpiryExceedsEscrowMaturity`).
6. `seller = escrow.recipient()`; require `msg.sender != seller && msg.sender != BUYER() && msg.sender != ARBITER()` (revert `LpCannotBeEscrowParty`) — the escrow re-checks buyer/arbiter at the pull; this is a clean early error.
7. Require `offerAmount >= escrow.payoutAmount() / 2` (revert `OfferBelowMinimum`).
8. `fee = offerAmount * feeRateBps / 10000`; `netAmount = offerAmount − fee`.
9. `token = escrow.token()`. Pull deposit with a **balance-delta check**: measure `balanceOf(this)` before/after `safeTransferFrom(msg.sender, this, offerAmount)`; require delta `== offerAmount` (revert `TransferAmountMismatch`) — rejects fee-on-transfer tokens, mirroring the escrow's own deposit guard.
10. `totalDeposits[token] += offerAmount`. Store `Offer{..., status: OPEN}`.
11. Emit `OfferCreated(escrowContract, msg.sender, seller, token, offerAmount, netAmount, fee, offerExpiry)`.

### 6.2 `acceptOffer`

```solidity
function acceptOffer(address escrowContract, address lp) external nonReentrant
```

**Pre-condition (tx 1, seller, on the escrow):** `escrow.approveRecipientTransfer(marketplace, lp)` — binds the operator AND the exact LP, valid 5 minutes. Without it (or after expiry), step 6 reverts and nothing moves; the seller simply re-approves.

**Logic (tx 2 — checks → effects → interactions):**

1. Load offer; require `status == OPEN` (revert `OfferNotOpen`).
2. Require `block.timestamp <= offer.offerExpiry` (revert `OfferExpired`).
3. `seller = escrow.recipient()` (live read). Require `msg.sender == seller` (revert `NotEscrowRecipient`) and `seller == offer.seller` (revert `OfferStale`).
4. Require sellable: `isFunded() && !hasActiveDispute() && !isClaimed()` (revert `EscrowNotSellable`).
5. **Effects:** `offer.status = COMPLETED`; `totalDeposits[token] −= offer.offerAmount`; `accruedFees[token] += offer.fee`.
6. **Interactions:**
   a. `escrow.transferRecipientFrom(lp)` — pulls the role directly seller → LP using the one-shot approval. The escrow enforces lp ≠ zero/buyer/arbiter and resets the LP's dispute vote.
   b. `token.safeTransfer(seller, offer.netAmount)`.
7. Emit `OfferAccepted(escrowContract, lp, seller, offer.netAmount, offer.fee)`.

All other OPEN offers on this escrow are now stale (`recipient()` changed) — each LP withdraws their full gross deposit via `withdrawFunds`. No loop, no gas ceiling, no event storm.

### 6.3 `rejectOffer`

```solidity
function rejectOffer(address escrowContract, address lp) external
```

1. Require `status == OPEN`; require `msg.sender == offer.seller` and `escrow.recipient() == offer.seller` (only the current recipient may reject — a stale offer needs no rejection, it is already withdrawable).
2. `offer.status = CANCELLED`. Emit `OfferRejected(escrowContract, lp)`.

### 6.4 `withdrawFunds`

```solidity
function withdrawFunds(address escrowContract) external nonReentrant
```

1. Key = (escrowContract, `msg.sender`). Withdrawable iff:
   - `status == CANCELLED`, **or**
   - `status == OPEN && (block.timestamp > offerExpiry || escrow.recipient() != offer.seller)` (expired or stale — evaluated lazily, no separate expire transaction).
   Otherwise revert `NothingToWithdraw`.
2. **Effects first (CEI):** cache `(token, offerAmount)`; `totalDeposits[token] −= offerAmount`; `delete offers[key]` — freeing the slot for a future offer (invariant 1).
3. `token.safeTransfer(msg.sender, offerAmount)` — full gross, including the never-accrued fee.
4. Emit `FundsWithdrawn(escrowContract, msg.sender, token, offerAmount)`.

### 6.5 Owner functions (Ownable2Step)

```solidity
function setFeeRate(uint256 newFeeRateBps) external onlyOwner;          // require <= 1000 (10% cap); applies to NEW offers only
function setDefaultOfferDuration(uint256 durationSeconds) external onlyOwner;
function withdrawFees(address token, address to, uint256 amount) external onlyOwner;
// require amount <= accruedFees[token]; decrement before transfer. LP deposits are unreachable.
```

### 6.6 `sweepToken` (optional, recommended)

Sweeps only the **excess** of a token above `totalDeposits[token] + accruedFees[token]` (accidental direct transfers). Can never touch live deposits or accrued fees.

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

1. **Provenance (`TRUSTED_FACTORY`):** offers are only accepted on escrows created by the known factory, closing the "malicious escrow returns fake `maturity()`/`hasActiveDispute()`" hole from v0.2 §11. The factory is permissionless, so anyone can *create* a genuine escrow — genuineness of code is what's being verified, not the creator.
2. **Atomicity:** the marketplace holds the recipient role for zero blocks. Every custody-window failure mode (dispute payout landing on the marketplace, maturity claim landing on the marketplace, stranded role) is structurally impossible rather than handled.
3. **One-shot approval:** consumed on use, cleared on any recipient change, revocable by approving `address(0)`. An approval can never be replayed or survive a seller change.
4. **Staleness over enumeration:** `recipient()` is the single source of truth. Any change of recipient — sale through this marketplace, direct `changeRecipient`, resale by an LP — automatically invalidates all outstanding offers without touching them.
5. **Fee accounting:** `accruedFees[token]` is the only balance the owner can withdraw. Refunds are always full-gross, so an LP never pays a fee on a deal that didn't happen.
6. **`totalDeposits[token]`** exists to enforce invariant 7 and to make `sweepToken` safe; it is not consulted in the hot path beyond ±= updates.
7. **Resale supported naturally:** an LP who acquired the role is simply the new `recipient()`; new offers snapshot them as seller and the same flow applies.

---

## 9. Events

```solidity
event OfferCreated(address indexed escrowContract, address indexed lp, address indexed seller, address token, uint256 offerAmount, uint256 netAmount, uint256 fee, uint256 offerExpiry);
event OfferAccepted(address indexed escrowContract, address indexed lp, address indexed seller, uint256 netAmount, uint256 fee);
event OfferRejected(address indexed escrowContract, address indexed lp);
event FundsWithdrawn(address indexed escrowContract, address indexed lp, address token, uint256 amount);
event FeeRateUpdated(uint256 newFeeRateBps);
event DefaultOfferDurationUpdated(uint256 durationSeconds);
event FeesWithdrawn(address indexed token, address to, uint256 amount);
```

On the escrow (implemented): `RecipientTransferApproved(address indexed operator, address indexed newRecipient, uint256 expiry)`; `RecipientChanged` already existed.

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
error OfferBelowMinimum(uint256 offerAmount, uint256 minimum); // < payoutAmount()/2
error LpCannotBeEscrowParty(address lp);
error TransferAmountMismatch();                                // fee-on-transfer token rejected
error NothingToWithdraw(address escrowContract, address lp);
error FeeTooHigh(uint256 requested, uint256 max);
error InsufficientAccruedFees(address token, uint256 requested, uint256 available);
```

---

## 11. Security Considerations

| Risk | Mitigation |
|---|---|
| Reentrancy (arbitrary ERC20s may have hooks) | `nonReentrant` on every state-mutating external function (**mandatory**, not optional) + strict checks-effects-interactions everywhere. |
| Owner drains LP deposits | Structurally impossible: `withdrawFees` capped by `accruedFees[token]`; deposits tracked separately. |
| Custody-window failures (dispute/maturity payouts landing on marketplace, stranded role) | Eliminated by design — the marketplace is never the recipient (§8.2). |
| Stale-seller payment/restore theft | Eliminated — acceptance requires live `recipient() == offer.seller == msg.sender`; payment goes to the live recipient; no restore path exists. |
| Sybil offer spam gas-DoS on acceptance | No cancellation loop (lazy staleness); 50%-of-payout minimum makes spam capital-intensive. |
| Deposit-slot overwrite | `createOffer` requires an empty (`NONE`) slot; slots free only on withdrawal. |
| Fee-on-transfer / deflationary tokens | Balance-delta check on deposit (revert), mirroring the escrow. |
| Malicious escrow contract | `TRUSTED_FACTORY` provenance check — only genuine escrow code is accepted. |
| **LP inherits dispute risk (disclose!)** | After acceptance the LP is the escrow's seller-side party: the buyer can still dispute before maturity, and buyer + arbiter can outvote the LP 2-of-3, up to a 100% buyer refund. LPs must price buyer/arbiter reputation into their discount. This is inherent to buying the cashflow, not a defect. |
| Seller approves marketplace but never accepts | Harmless: the approval moves nothing by itself, is revocable (`approveRecipientTransfer(address(0))`), and is cleared by any recipient change. |
| Front-running `acceptOffer` | Only the current recipient can call it; the approval is only usable by the marketplace inside that call. An LP withdrawing a stale/expired offer cannot be raced into an acceptance (stale/expired offers are never acceptable). |

---

## 12. Out of Scope (unchanged)

- Offer discovery / indexing (off-chain: UI + subgraph)
- Yield on deposited funds
- Upgradability / proxy pattern
- Timelock on fee/owner changes (pilot: Ownable2Step EOA)
- Whitelisting of escrow contracts beyond factory provenance

## 13. Open Questions (before audit)

1. **Fee rate at launch** — TBD.
2. **`defaultOfferDuration` at launch** — 24h proposed.
3. Should `sweepToken` (§6.6) ship in v1 or be deferred?

## 14. Changelog

- **v0.4.1 (2026-07-06):** Escrow §3.2 implemented. Approval now binds **operator + exact destination** (decision: even a malicious operator can only execute the sanctioned move) and carries a **5-minute TTL** (decision: covers only the human gap between the two signed transactions; prevents indefinite dangling approvals). Event finalized as `RecipientTransferApproved(operator, newRecipient, expiry)`.
- **v0.4 (2026-07-06):** Adversarial review. Replaced two-tx custody flow with atomic approve-and-pull (kills stale-seller theft, custody-window fund stranding, expire-restore griefing, reclaim deadlock). Added: factory provenance check, funded/undisputed/unclaimed gate at create+accept, per-escrow token support with per-token fee accounting (`accruedFees`), deposit/fee segregation (`totalDeposits`), empty-slot requirement (fixes deposit overwrite), 50%-of-payout minimum offer, balance-delta deposit guard, mandatory `nonReentrant`, lazy expiry/staleness (removed `expireOffer`, `reclaimRecipient`, enumeration array, O(N) cancel loop, `EXPIRED`/`BLOCKED` states, `payable`). Escrow additions specified: `approveRecipientTransfer` / `transferRecipientFrom` (one-shot operator).
- **v0.3 (2026-07-06):** Recorded escrow-side interface implementation; `changeRecipient` extended to disputed state.
- **v0.2 (2026-07-01):** Initial draft.
