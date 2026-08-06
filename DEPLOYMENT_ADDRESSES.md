# Deployed Contract Addresses

This file tracks all deployed contract addresses across different networks.

## Base Mainnet (Production)

### Legacy pair (single-recipient escrow) — CURRENT (marketplace-capable)

Used by **chainservice**. Retains `EXPIRY_TIMESTAMP`, where expiry is load-bearing:
it gates `claimFunds()`, and `EXPIRY_TIMESTAMP == 0` means instant transfer.

Carries the marketplace additions: §3.2 approve/pull recipient transfer and §3.3
sale-triggered arbiter reset (`resolvedBuyerPercentage`, nominate/seat/evict, the
72-hour `NOMINATION_WINDOW` constant). **`initialize` and `createEscrowContract`
keep their previous signatures** — integrators repoint at the new addresses and
change no call sites.

| Contract | Address | BaseScan Link | Deployment Date |
|----------|---------|---------------|-----------------|
| EscrowContract (Implementation) | `0x77acD2d342cF513A60e6d51ca5a36C93BD14A04B` | [View on BaseScan](https://basescan.org/address/0x77acD2d342cF513A60e6d51ca5a36C93BD14A04B) | 2026-08-06 |
| EscrowContractFactory | `0x575AB01251cfc4DB9Ce90A13152a7a616Bd304b9` | [View on BaseScan](https://basescan.org/address/0x575AB01251cfc4DB9Ce90A13152a7a616Bd304b9) | 2026-08-06 |

**Immutable parameters baked into this implementation** (changing either requires a
new implementation, hence a new codehash, factory and marketplace):

| Parameter | Value |
|---|---|
| `DEFAULT_ARBITER` (fallback arbitrator Safe) | `0x9bB8e809EA6F5A74f46027D8016641D9cE9A149C` |
| `NOMINATION_WINDOW` | 72 hours (259200s) |
| `ARBITER_SILENCE_TIMEOUT` | 30 days |
| `RECIPIENT_APPROVAL_TTL` | 5 minutes |

**ERC-1167 clone codehash for this implementation** — the value `MarketplaceEscrow`
derives and enforces. Verified two ways (`cast keccak` over the minimal-proxy runtime,
and the constructor's own derivation):

```
0x5c1d3f7f01cbe7c3aa294f7f7d426ad766c7c99513eb563742964c4f22477644
```

#### Superseded legacy pair (pre-marketplace)

Predates §3.2/§3.3. Escrows created by this factory have a **different codehash** and
are therefore permanently invisible to the marketplace — correctly, since they cannot
perform the approve-and-pull swap. They remain live to their own terms.

| Contract | Address | Status |
|----------|---------|--------|
| EscrowContract (Implementation) | `0xCbfD53842f0ACc885a55b7A0eDb18eF5ac9237f9` | superseded 2026-08-06 |
| EscrowContractFactory | `0x00b1D1A005022D1f140062Ba5aB0A44788089F88` | superseded 2026-08-06 |

### Completion (fan-out) pair — CURRENT

Used by **fanOutChainService**; powers the Projects feature. This pair has **no
expiry**: the buyer may dispute until payout, and funds move only on dual-verify
or dispute resolution. Roles are BUYER / LEAD_SUPPLIER / VERIFIER / ARBITER with
a 1–10 way `payees[]` split.

| Contract | Address | BaseScan Link | Deployment Date |
|----------|---------|---------------|-----------------|
| CompletionEscrowContract (Implementation) | `0x9d0a65a1540b435a549b438b6b99E8bA7aB48E44` | [View on BaseScan](https://basescan.org/address/0x9d0a65a1540b435a549b438b6b99E8bA7aB48E44) | 2026-08-06 |
| CompletionEscrowContractFactory | `0xFF4625e772e9031EF94D98253d6dDe6e7b7eEcFa` | [View on BaseScan](https://basescan.org/address/0xFF4625e772e9031EF94D98253d6dDe6e7b7eEcFa) | 2026-08-06 |

_Previous: implementation `0x86f1959b235573b1daa4cecf96214c500c7a1160`, factory `0x821575b2311635e54a662fdcfb92fe8df17f36b7` (2026-07-27) — superseded 2026-08-06._

Set on fanOutChainService:

```bash
FANOUT_ESCROW_IMPLEMENTATION_ADDRESS=0x86f1959b235573b1daa4cecf96214c500c7a1160
FANOUT_CONTRACT_FACTORY_ADDRESS=0x821575b2311635e54a662fdcfb92fe8df17f36b7
```

Both MUST be set explicitly. `application.yml` falls back to
`CONTRACT_FACTORY_ADDRESS` / `ESCROW_IMPLEMENTATION_ADDRESS` (the legacy pair)
when they are absent, which points the completion ABI at the legacy factory.

### Superseded completion pair

Escrows created by any earlier completion factory are **not readable** by the
current ABI (`getRecipients()` was renamed `getPayees()`; `getContractInfo()`
lost a field). They remain on-chain and their parties can still call them
directly, but the app will not list them. Record the prior factory address here
if such escrows still hold funds.

| Contract | Address | Notes |
|----------|---------|-------|
| CompletionEscrowContractFactory (previous) | _TBD — fill in if pre-2026-07-27 escrows still hold funds_ | Unreadable by current ABI |

## Base Sepolia (Testnet)

| Contract | Address | BaseScan Link | Deployment Date |
|----------|---------|---------------|-----------------|
| EscrowContract (Implementation) | Not deployed | - | - |
| EscrowContractFactory | Not deployed | - | - |

## Legacy Deployments

### Avalanche Fuji (Testnet) - Legacy

| Contract | Address | SnowTrace Link | Deployment Date |
|----------|---------|----------------|-----------------|
| EscrowContract (Implementation) | - | - | - |
| EscrowContractFactory | - | - | - |

## Deployment Instructions

After deploying contracts:

1. Copy the deployment output addresses
2. Update this file with actual addresses
3. Update README.md with the addresses
4. Commit changes:
   ```bash
   git add DEPLOYMENT_ADDRESSES.md README.md
   git commit -m "Update deployed contract addresses for [network]"
   git push
   ```

## Verification

All contracts should be verified on block explorers:

### Base Sepolia
- Verifier: BlockScout
- API: https://api-sepolia.basescan.org/api

### Base Mainnet
- Verifier: BlockScout
- API: https://api.basescan.org/api

## Environment Variables

After deployment, update these environment variables in all services:

**contracts/.env**:
```bash
CONTRACT_FACTORY_ADDRESS=0x00b1D1A005022D1f140062Ba5aB0A44788089F88  # Production factory
```

**chainservice/.env**:
```bash
CONTRACT_FACTORY_ADDRESS=0x00b1D1A005022D1f140062Ba5aB0A44788089F88  # Production factory
USDC_CONTRACT_ADDRESS=0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913  # Base mainnet USDC
```

**webapp/.env.local**:
```bash
CONTRACT_FACTORY_ADDRESS=0x00b1D1A005022D1f140062Ba5aB0A44788089F88  # Production factory
USDC_CONTRACT_ADDRESS=0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913  # Base mainnet USDC
```

## GitHub Configuration

Don't forget to update GitHub repository variables after deployment:

1. Go to repository Settings → Secrets and variables → Actions
2. Update `CONTRACT_FACTORY_ADDRESS` variable
3. Redeploy services to pick up new address

---

## Liquidity Marketplace

Spec: `MARKETPLACE_OPENSPEC.md`. Deploy order is load-bearing (§3.4): implementation →
factory → marketplace.

| Contract | Address | Status |
|----------|---------|--------|
| MarketplaceEscrow | _not yet deployed_ | pending — run `script/DeployMarketplace.s.sol` |

Constructor inputs when it is deployed:

| Input | Value |
|---|---|
| `trustedImplementation` | `0x77acD2d342cF513A60e6d51ca5a36C93BD14A04B` |
| `initialFeeRateBps` | **TBD** — §13.1 proposes 25–50; hard cap 1000 |
| `initialMinOfferBps` | 1000 (10%) — §13.12, settled |
| `initialDefaultOfferDuration` | **TBD** — §13.2 proposes 86400 (24h) |
| `initialOwner` | **TBD** — MUST differ from the `DEFAULT_ARBITER` Safe (§3.3E) |

> **Inventory reality (§3.4):** the marketplace opens **empty** and fills only from
> escrows created by factory `0x575AB0…` onward. Escrows from the superseded factory
> are permanently invisible to it. Launch messaging must not promise liquidity on
> existing deals.

