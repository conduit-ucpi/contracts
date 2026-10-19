# Deployed Contract Addresses

This file tracks all deployed contract addresses across different networks.

> **Before reporting an issue:** check the address against the tables below. Each
> section says which commit is live. Reports against a superseded address describe
> code that is no longer current and need no report. Anything else goes to
> [SECURITY.md](SECURITY.md).

## Base Mainnet (Production)

### Legacy pair (single-recipient escrow) — CURRENT

Used by **chainservice**. Retains `EXPIRY_TIMESTAMP`, where expiry is load-bearing:
it gates `claimFunds()`, and `EXPIRY_TIMESTAMP == 0` means instant transfer.

Built from commit `a42c1e2`. It includes the §3.2 approve/pull recipient transfer, the §3.3
sale-triggered arbiter reset, the `hasBeenSold` flag (§5.3), partner fee splits
(`*WithSplit`, gated by `FEE_SPLIT_SIGNER`), arbiter resignation/reseating, and the
fix for the dispute-window re-arm issue reported by xbyteid (`83a3e77b2f`). Every issue
fixed up to that commit is live in this deployment. Anything reported against
`0x77acD2d…` or older addresses describes a superseded deployment.

| Contract | Address | BaseScan Link | Deployment Date |
|----------|---------|---------------|-----------------|
| EscrowContract (Implementation) | `0xFe951aB5d24F0B09F692e6C7C71Bf4C4235E2B5D` | [View on BaseScan](https://basescan.org/address/0xFe951aB5d24F0B09F692e6C7C71Bf4C4235E2B5D) | 2026-10-14 |
| EscrowContractFactory | `0xe9F9e568B0B52b93c5aD3289A556A395Ea92B93b` | [View on BaseScan](https://basescan.org/address/0xe9F9e568B0B52b93c5aD3289A556A395Ea92B93b) | 2026-10-14 |

**Immutable parameters baked into this deployment** (changing any of them requires a
new implementation, which means a new codehash, factory and marketplace):

| Parameter | Value |
|---|---|
| `GIT_COMMIT` | `0xa42c1e200107969f937f0e9d3ec12d4775e60776` |
| `DEFAULT_ARBITER` (fallback arbitrator Safe) | `0x9bB8e809EA6F5A74f46027D8016641D9cE9A149C` |
| `FEE_SPLIT_SIGNER` | `0xCbd6Fb910694A9c2c0729D89D2057469857B1C26` |
| `NOMINATION_WINDOW` | 72 hours (259200s) |
| `ARBITER_SILENCE_TIMEOUT` | 30 days |
| `RECIPIENT_APPROVAL_TTL` | 5 minutes |

**ERC-1167 clone codehash for this implementation**: the value `OfferVaultFactory`
derives and enforces as its provenance gate. Computed with `cast keccak` over the
minimal-proxy runtime. When the marketplace is deployed, compare it against the
`EXPECTED_ESCROW_CODEHASH` that `DeployMarketplace.s.sol` logs:

```
0x9fe6294a6c47f65ce1c577a04ffa30054d50995f441c8ce1de1eb57f94d86b0b
```

#### Superseded legacy pairs

These are older deployments. Their escrows remain live on their own terms, but their
clone codehashes differ, so the marketplace never sees them. Do **not** treat code
behaviour at these addresses as current.

| Contract | Address | Status |
|----------|---------|--------|
| EscrowContract (Implementation) | `0x77acD2d342cF513A60e6d51ca5a36C93BD14A04B` | deployed 2026-08-06, superseded 2026-10-14 |
| EscrowContractFactory | `0x575AB01251cfc4DB9Ce90A13152a7a616Bd304b9` | deployed 2026-08-06, superseded 2026-10-14 |
| EscrowContract (Implementation) | `0xCbfD53842f0ACc885a55b7A0eDb18eF5ac9237f9` | pre-marketplace, superseded 2026-08-06 |
| EscrowContractFactory | `0x00b1D1A005022D1f140062Ba5aB0A44788089F88` | pre-marketplace, superseded 2026-08-06 |

### Completion (fan-out) pair — CURRENT

Used by **fanOutChainService**; powers the Projects feature. This pair has **no
expiry**: the buyer may dispute until payout, and funds move only on dual-verify
or dispute resolution. Roles are BUYER / LEAD_SUPPLIER / VERIFIER / ARBITER with
a 1–10 way `payees[]` split.

Built from commit `810fc2a`. It includes every fix from the 2026-08-23 audit
(`b6c8931`): the arbiter must be distinct from buyer and supplier
(`ArbiterMustBeDistinct`), short (fee-on-transfer) deposits revert
(`TransferAmountMismatch`), the arbiter may raise a dispute, and stray tokens can be
recovered with `sweepToken`. Every issue fixed up to that commit is live in this
deployment. Anything reported against `0x9d0a65a…` or older addresses describes a
superseded deployment.

| Contract | Address | BaseScan Link | Deployment Date |
|----------|---------|---------------|-----------------|
| CompletionEscrowContract (Implementation) | `0x99Df2f361EBB0C6305FB00592c82Cba9b017F3d9` | [View on BaseScan](https://basescan.org/address/0x99Df2f361EBB0C6305FB00592c82Cba9b017F3d9) | 2026-10-16 |
| CompletionEscrowContractFactory | `0x67a219e3A3a570bBC58f839CE4FD4eF51748572c` | [View on BaseScan](https://basescan.org/address/0x67a219e3A3a570bBC58f839CE4FD4eF51748572c) | 2026-10-16 |

**Immutable parameters baked into this deployment:**

| Parameter | Value |
|---|---|
| `GIT_COMMIT` (implementation and factory) | `0x810fc2aaf2c2c0a52ae8d48c6a246e027bcd7c62` |
| `PLATFORM_FEE_WALLET` | `0xC9125aCda217A4c79453Fa33955ebf141Bae7349` |

Set on fanOutChainService:

```bash
FANOUT_ESCROW_IMPLEMENTATION_ADDRESS=0x99Df2f361EBB0C6305FB00592c82Cba9b017F3d9
FANOUT_CONTRACT_FACTORY_ADDRESS=0x67a219e3A3a570bBC58f839CE4FD4eF51748572c
```

Both MUST be set explicitly. `application.yml` falls back to
`CONTRACT_FACTORY_ADDRESS` / `ESCROW_IMPLEMENTATION_ADDRESS` (the legacy pair)
when they are absent, which points the completion ABI at the legacy factory.

### Superseded completion pairs

These are older deployments. Their escrows remain live on their own terms and their
parties can still call them directly. Do **not** treat code behaviour at these
addresses as current.

The 2026-08-06 pair lacks the 2026-08-23 audit fixes listed above. Its escrows are
still readable by the current ABI apart from the new `GIT_COMMIT()` getter. Escrows
from the 2026-07-27 pair are **not readable** by the current ABI (`getRecipients()`
was renamed `getPayees()`; `getContractInfo()` lost a field), so the app will not
list them.

| Contract | Address | Status |
|----------|---------|--------|
| CompletionEscrowContract (Implementation) | `0x9d0a65a1540b435a549b438b6b99E8bA7aB48E44` | deployed 2026-08-06, superseded 2026-10-16 |
| CompletionEscrowContractFactory | `0xFF4625e772e9031EF94D98253d6dDe6e7b7eEcFa` | deployed 2026-08-06, superseded 2026-10-16 |
| CompletionEscrowContract (Implementation) | `0x86f1959b235573b1daa4cecf96214c500c7a1160` | deployed 2026-07-27, superseded 2026-08-06 |
| CompletionEscrowContractFactory | `0x821575b2311635e54a662fdcfb92fe8df17f36b7` | deployed 2026-07-27, superseded 2026-08-06 |

## Other networks

No other network has a deployment tracked here. Base Sepolia and Avalanche Fuji
have none recorded. Contracts found on any other chain are not maintained by us.

## Deployment Instructions

The legacy escrow pair deploys on its own, stamped with the commit it was built from:

- CI: the deploy job runs `script/DeployEscrow.s.sol:DeployEscrow` with
  `GIT_COMMIT=0x${{ github.sha }}`. It deploys **only** EscrowContract +
  EscrowContractFactory — the completion pair and marketplace are separate
  (see below).
- Locally: `./script/deploy-escrow-keystore.sh` (refuses a dirty tree, sets
  `GIT_COMMIT` from `HEAD`). `DeploymentScript` still deploys legacy + completion
  together when that is wanted.

The completion (fan-out) pair deploys from `.github/workflows/deploy-completion.yml`
on its own tags — `completion-vX.Y.Z` (production) or `completion-testX.Y.Z`
(test) — running `DeployCompletionEscrow`. Locally:
`./script/deploy-completion-keystore.sh` (refuses a dirty tree). Both stamp the
implementation and factory with `GIT_COMMIT`, which is required. Either way, copy
the two printed `FANOUT_*` values onto fanOutChainService.

The marketplace deploys from `deploy-marketplace.yml` on `offervault-v*` /
`offervault-test*` tags.

Legacy env: `DEFAULT_ARBITER_ADDRESS` and `GIT_COMMIT` are required;
`FEE_SWEEPER_ADDRESS` defaults to the owner (relayer) when unset — set it explicitly,
since it is immutable, stamped into every escrow the factory creates, and is the only
key that can release escrow fees (`sweepFees`) to targets of its own choosing.

Read the commit back from any escrow, factory or implementation with
`cast call <address> "GIT_COMMIT()(bytes20)"`.

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
CONTRACT_FACTORY_ADDRESS=0xe9F9e568B0B52b93c5aD3289A556A395Ea92B93b  # Production factory
```

**chainservice/.env**:
```bash
CONTRACT_FACTORY_ADDRESS=0xe9F9e568B0B52b93c5aD3289A556A395Ea92B93b  # Production factory
ESCROW_IMPLEMENTATION_ADDRESS=0xFe951aB5d24F0B09F692e6C7C71Bf4C4235E2B5D
DEFAULT_ARBITER_ADDRESS=0x9bB8e809EA6F5A74f46027D8016641D9cE9A149C  # stabledropAdmin Safe
USDC_CONTRACT_ADDRESS=0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913  # Base mainnet USDC
```

> ⚠️ **`ESCROW_IMPLEMENTATION_ADDRESS` must ship in the same release as the factory repoint**
> (§15.4 sequencing). chainservice reads `DEFAULT_ARBITER()` from that implementation at
> startup and passes it explicitly as the creation arbiter on every escrow; a zero arbiter
> is silently rewritten by the factory to the relayer hot wallet, permanently, per escrow.
>
> `DEFAULT_ARBITER_ADDRESS` is optional and acts as an assertion: when set, chainservice
> refuses to start if it disagrees with the implementation's bytecode. When neither the
> on-chain read nor the variable yields an address, the service refuses to start rather than
> defaulting.

**webapp/.env.local**:
```bash
CONTRACT_FACTORY_ADDRESS=0xe9F9e568B0B52b93c5aD3289A556A395Ea92B93b  # Production factory
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

**Two contracts, deployed in order by `script/DeployMarketplace.s.sol`.** The venue no
longer pools LP capital (§5.0): the factory holds no tokens at any point, and each offer's
funds sit in its own `OfferVault` clone.

| Contract | Address | Status |
|----------|---------|--------|
| OfferVault (implementation) | _not yet deployed_ | pending — cloned once per offer |
| OfferVaultFactory | _not yet deployed_ | pending — the venue and registry |

Factory constructor inputs when it is deployed:

| Input | Value |
|---|---|
| `vaultImplementation` | the OfferVault deployed in the same script |
| `trustedImplementation` | `0xFe951aB5d24F0B09F692e6C7C71Bf4C4235E2B5D` |
| `initialFeeRateBps` | **TBD** — §13.1 proposes 25–50; hard cap 1000 |
| `initialMinOfferBps` | 1000 (10%) — §13.12, settled |
| `initialDefaultOfferDuration` | **TBD** — §13.2 proposes 86400 (24h) |
| `initialFeeRecipient` | **TBD** — fees are paid here at acceptance, never accrued |
| `initialOwner` | **TBD** — MUST differ from the `DEFAULT_ARBITER` Safe (§3.3E) |

> Record BOTH addresses. Redeploying the factory later would orphan its `hasBeenSold` /
> `holdbackVault` registry — existing vaults keep working and their funds stay reachable by
> their own LP and seller, but a fresh factory would not know which escrows had already been
> sold, so a second reserve could be stacked on one that already has a live reserve.

> **Inventory reality (§3.4):** the marketplace opens **empty** and fills only from
> escrows created by factory `0xe9F9e5…` onward. Escrows from the superseded factories
> are permanently invisible to it. Launch messaging must not promise liquidity on
> existing deals.

