# Deployed Contract Addresses

This file tracks all deployed contract addresses across different networks.

## Base Mainnet (Production)

### Legacy pair (single-recipient escrow)

Used by **chainservice**. Retains `EXPIRY_TIMESTAMP`, where expiry is load-bearing:
it gates `claimFunds()`, and `EXPIRY_TIMESTAMP == 0` means instant transfer.

| Contract | Address | BaseScan Link | Deployment Date |
|----------|---------|---------------|-----------------|
| EscrowContract (Implementation) | `0xCbfD53842f0ACc885a55b7A0eDb18eF5ac9237f9` | [View on BaseScan](https://basescan.org/address/0xCbfD53842f0ACc885a55b7A0eDb18eF5ac9237f9) | 2024-2025 |
| EscrowContractFactory | `0x00b1D1A005022D1f140062Ba5aB0A44788089F88` | [View on BaseScan](https://basescan.org/address/0x00b1D1A005022D1f140062Ba5aB0A44788089F88) | 2024-2025 |

### Completion (fan-out) pair — CURRENT

Used by **fanOutChainService**; powers the Projects feature. This pair has **no
expiry**: the buyer may dispute until payout, and funds move only on dual-verify
or dispute resolution. Roles are BUYER / LEAD_SUPPLIER / VERIFIER / ARBITER with
a 1–10 way `payees[]` split.

| Contract | Address | BaseScan Link | Deployment Date |
|----------|---------|---------------|-----------------|
| CompletionEscrowContract (Implementation) | `0x86f1959b235573b1daa4cecf96214c500c7a1160` | [View on BaseScan](https://basescan.org/address/0x86f1959b235573b1daa4cecf96214c500c7a1160) | 2026-07-27 |
| CompletionEscrowContractFactory | `0x821575b2311635e54a662fdcfb92fe8df17f36b7` | [View on BaseScan](https://basescan.org/address/0x821575b2311635e54a662fdcfb92fe8df17f36b7) | 2026-07-27 |

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
