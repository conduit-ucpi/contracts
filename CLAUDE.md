# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

This is a Foundry-based smart contract project for the Conduit UCPI Web3 SDK implementing a two-contract escrow system:
- **EscrowContractFactory**: Factory contract owned by the gas-relayer service that creates individual escrow contracts
- **EscrowContract**: Individual escrow contract template for time-delayed escrow transactions

## Development Commands

This project uses Foundry for smart contract development:
- **Install dependencies**: `forge install @openzeppelin/contracts`
- **Build contracts**: `forge build`
- **Run tests**: `forge test -vvv`
- **Run specific test**: `forge test --match-contract EscrowContractTest -vvv`
- **Deploy contracts**: `forge script script/DeploymentScript.s.sol:DeploymentScript --rpc-url $NETWORK_RPC_URL --broadcast --verify`
- **Generate gas report**: `forge test --gas-report`

## Environment Configuration

The project requires a `.env` file based on `.env.example`:
- `USDC_CONTRACT_ADDRESS`: USDC contract address (Fuji testnet: 0x5425890298aed601595a70AB815c96711a31Bc65)
- `RELAYER_WALLET_PRIVATE_KEY`: Private key for the gas-relayer wallet (becomes factory owner)
- `NETWORK`: Target network name ("fuji" for Avalanche Fuji testnet)
- `CHAIN_ID`: Blockchain chain ID (43113 for Fuji, 43114 for Avalanche mainnet)
- `NETWORK_RPC_URL`: Base RPC URL for the target network
- `INFURA_API_KEY`: Infura API key for RPC access
- `ETHERSCAN_API_KEY`: Etherscan API key for contract verification
- `AVA_VERIFIER_URL`: Avalanche verifier URL for Avalanche networks

**Network Configuration**:
- `NETWORK` determines verification method (Sourcify for Avalanche, Etherscan for Ethereum)
- `CHAIN_ID` provides network safety check during deployment
- Deployment script validates chain ID matches expected network

## Contract Architecture

### Factory Pattern
- **EscrowContractFactory** creates individual escrow contracts using CREATE2 for deterministic addresses
- Only the factory owner (gas-relayer service) can create new escrow contracts
- Each escrow contract is immutable once created

### Escrow Contract Lifecycle
1. **Active**: Contract is live, funds locked, can be disputed
2. **Disputed**: Buyer raised dispute, awaiting gas-payer resolution
3. **Expired**: Time passed expiry, seller can claim funds
4. **Resolved**: Dispute resolved by gas-payer
5. **Claimed**: Funds distributed to final recipient

### Access Controls
- **Buyer**: Can raise disputes only
- **Seller**: Can claim funds after expiry (if not disputed)
- **Gas Payer**: Can resolve disputes and claim funds on behalf of seller

## Security Features

- OpenZeppelin contracts for battle-tested security patterns
- Reentrancy protection on all state-changing functions
- Comprehensive input validation
- Immutable contract parameters prevent tampering
- No upgrade mechanisms (security by design)

## Testing

The test suite includes:
- **Unit tests**: Individual contract functionality
- **Integration tests**: Full escrow lifecycle scenarios
- **Security tests**: Access control and edge cases
- **Mock ERC20**: Complete USDC simulation for testing

Run tests with different verbosity levels:
- `forge test`: Basic test results
- `forge test -vv`: Show logs for failing tests
- `forge test -vvv`: Show logs for all tests
- `forge test -vvvv`: Show detailed trace information

## Repository Structure

```
contracts/
├── foundry.toml              # Foundry configuration
├── src/
│   ├── EscrowContract.sol    # Individual escrow contract template
│   └── EscrowContractFactory.sol # Factory for creating escrow contracts
├── script/
│   └── DeploymentScript.s.sol # Deployment script with logging
├── test/
│   ├── EscrowContract.t.sol  # Comprehensive escrow contract tests
│   └── EscrowContractFactory.t.sol # Factory contract tests
├── .env.example              # Environment configuration template
└── .github/workflows/deploy.yml # CI/CD pipeline
```