# Conduit UCPI - Escrow Smart Contracts

Time-delayed escrow contracts on Base blockchain with built-in dispute resolution.

## Overview

This repository contains the Foundry-based smart contract implementation for Conduit UCPI's trustless escrow system. The contracts enable secure, time-locked transactions with buyer protection and administrator dispute resolution.

### Contract Architecture

- **EscrowContractFactory**: Factory contract that creates individual escrow contracts using CREATE2 for deterministic addresses
- **EscrowContract**: Immutable escrow contract template for individual transactions

## Features

- ⏱️ **Time-delayed Release**: Funds locked until expiry, protecting buyers
- 🛡️ **Dispute Resolution**: Built-in mechanism for handling transaction disputes
- 🔒 **Immutable Parameters**: Contract terms cannot be changed after deployment
- ✅ **Battle-tested Security**: Built with OpenZeppelin contracts
- 💰 **USDC Support**: Native USDC token integration
- 🏭 **Factory Pattern**: Gas-efficient contract deployment
- 🔄 **Reentrancy Protection**: Comprehensive security measures

## Contract Lifecycle

1. **Active**: Contract deployed, funds locked, can be disputed by buyer
2. **Disputed**: Buyer raised a dispute, awaiting administrator resolution
3. **Expired**: Time passed expiry, seller can claim funds
4. **Resolved**: Dispute resolved by administrator with percentage-based fund distribution
5. **Claimed**: Funds distributed to final recipient(s)

## Quick Start

### Prerequisites

- [Foundry](https://book.getfoundry.sh/getting-started/installation)
- Git

### Installation

```bash
# Clone the repository
git clone <repository-url>
cd contracts

# Install dependencies
forge install
```

### Configuration

Create a `.env` file based on `.env.example`:

```bash
cp .env.example .env
# Edit .env with your configuration
```

Required environment variables:
- `RELAYER_WALLET_PRIVATE_KEY`: Private key of the deployer wallet
- `NETWORK`: Target network (e.g., `base-sepolia`, `base`)
- `CHAIN_ID`: Network chain ID (84532 for Base Sepolia, 8453 for Base Mainnet)
- `NETWORK_RPC_URL`: RPC endpoint URL
- `USDC_CONTRACT_ADDRESS`: USDC contract address on target network
- `VERIFIER_API_KEY`: Block explorer API key for contract verification
- `VERIFIER_URL`: Block explorer API endpoint

### Building

```bash
forge build
```

### Testing

```bash
# Run all tests
forge test -vvv

# Run specific test
forge test --match-contract EscrowContractTest -vvv

# Generate gas report
forge test --gas-report
```

### Deployment

There are two escrow families, each with its own implementation + factory:

- **Legacy** — `EscrowContract` / `EscrowContractFactory` (single-recipient).
- **Completion (fan-out)** — `CompletionEscrowContract` /
  `CompletionEscrowContractFactory` (dual-verify, 1–10 recipient split; powers
  the Projects feature).

Two scripts cover them:

- `DeploymentScript` — deploys **both** families in one broadcast. Use on a
  fresh chain (e.g. a clean testnet) where neither is deployed yet.
- `DeployCompletionEscrow` — deploys **only** the completion family. Use when
  the legacy factory is already live on the target chain (as on Base mainnet —
  see `DEPLOYMENT_ADDRESSES.md`) and you only need to add the fan-out pair.

Verification is **not** configured in `foundry.toml`, so you must pass the
explorer credentials on the command line — a bare `--verify` will not verify
anything. For Base, `VERIFIER_URL` is `https://api.basescan.org/api` (mainnet)
or `https://api-sepolia.basescan.org/api` (Sepolia), and `VERIFIER_API_KEY` is
your Basescan key.

```bash
# Deploy BOTH families (fresh chain) + verify all four contracts
forge script script/DeploymentScript.s.sol:DeploymentScript \
  --rpc-url $NETWORK_RPC_URL \
  --broadcast \
  --verify \
  --etherscan-api-key $VERIFIER_API_KEY \
  --verifier-url $VERIFIER_URL

# Deploy ONLY the completion (fan-out) family (legacy already deployed)
forge script script/DeployCompletionEscrow.s.sol:DeployCompletionEscrow \
  --rpc-url $NETWORK_RPC_URL \
  --broadcast \
  --verify \
  --etherscan-api-key $VERIFIER_API_KEY \
  --verifier-url $VERIFIER_URL
```

Both scripts print each deployed implementation + factory address. The
completion deploy also prints the two values to set on **fanOutChainService**:

- `FANOUT_CONTRACT_FACTORY_ADDRESS`
- `FANOUT_ESCROW_IMPLEMENTATION_ADDRESS`

If verification fails mid-run (explorer lag is common), you don't need to
redeploy — verify a single address afterwards:

```bash
forge verify-contract <address> <ContractName> \
  --etherscan-api-key $VERIFIER_API_KEY \
  --verifier-url $VERIFIER_URL
```

## Security

### Access Controls

- **Buyer**: Can raise disputes only
- **Seller**: Can claim funds after expiry (if not disputed)
- **Gas Payer** (Factory Owner): Can resolve disputes and facilitate claims

### Security Features

- OpenZeppelin contracts for proven security patterns
- Reentrancy protection on all state-changing functions
- Comprehensive input validation
- Immutable contract parameters prevent tampering
- No upgrade mechanisms (security by design)

### Testing

The test suite includes:
- Unit tests for individual contract functions
- Integration tests for full escrow lifecycle
- Security tests for access controls and edge cases
- Mock ERC20 implementation for comprehensive testing

## Network Support

### Supported Networks

| Network | Chain ID | USDC Address |
|---------|----------|--------------|
| Base Sepolia (Testnet) | 84532 | `0x036CbD53842c5426634e7929541eC2318f3dCF7e` |
| Base Mainnet | 8453 | `0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913` |
| Avalanche Fuji (Legacy) | 43113 | `0x5425890298aed601595a70AB815c96711a31Bc65` |
| Avalanche Mainnet (Legacy) | 43114 | TBD |

## Project Structure

```
contracts/
├── foundry.toml              # Foundry configuration
├── src/
│   ├── EscrowContract.sol    # Individual escrow contract template
│   └── EscrowContractFactory.sol # Factory for creating escrow contracts
├── script/
│   └── DeploymentScript.s.sol # Deployment script with verification
├── test/
│   ├── EscrowContract.t.sol  # Comprehensive escrow contract tests
│   └── EscrowContractFactory.t.sol # Factory contract tests
└── .env.example              # Environment configuration template
```

## Related Repositories

- [Chain Service](../chainservice/) - Transaction relay service with gas sponsorship
- [Web Application](../webapp/) - Next.js frontend for escrow management

## Contributing

Contributions are welcome! Please see [CONTRIBUTING.md](CONTRIBUTING.md) for guidelines.

## License

MIT License - see [LICENSE](LICENSE) file for details

## Deployed Contracts

### Base Mainnet (Production)
- **Factory**: [`0x00b1D1A005022D1f140062Ba5aB0A44788089F88`](https://basescan.org/address/0x00b1D1A005022D1f140062Ba5aB0A44788089F88)
- **Implementation**: [`0xCbfD53842f0ACc885a55b7A0eDb18eF5ac9237f9`](https://basescan.org/address/0xCbfD53842f0ACc885a55b7A0eDb18eF5ac9237f9)

### Base Sepolia (Testnet)
- **Factory**: Not yet deployed
- **Implementation**: Not yet deployed

> **To update testnet**: After testnet deployment, add addresses here.

## Support

For issues and questions:
- Open an issue on GitHub
- Check existing documentation in `.claude/CLAUDE.md` (for developers)

---

Built with ❤️ for trustless transactions on Base
