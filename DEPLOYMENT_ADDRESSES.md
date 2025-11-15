# Deployed Contract Addresses

This file tracks all deployed contract addresses across different networks.

## Base Mainnet (Production)

| Contract | Address | BaseScan Link | Deployment Date |
|----------|---------|---------------|-----------------|
| EscrowContract (Implementation) | `0xCbfD53842f0ACc885a55b7A0eDb18eF5ac9237f9` | [View on BaseScan](https://basescan.org/address/0xCbfD53842f0ACc885a55b7A0eDb18eF5ac9237f9) | 2024-2025 |
| EscrowContractFactory | `0x00b1D1A005022D1f140062Ba5aB0A44788089F88` | [View on BaseScan](https://basescan.org/address/0x00b1D1A005022D1f140062Ba5aB0A44788089F88) | 2024-2025 |

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
