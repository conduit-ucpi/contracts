// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script, console} from "forge-std/Script.sol";
import {OfferVault} from "../src/OfferVault.sol";
import {OfferVaultFactory} from "../src/OfferVaultFactory.sol";
import {EscrowContract} from "../src/EscrowContract.sol";

/**
 * Deploys the marketplace — step 3 of the §3.4 launch order, AFTER the escrow
 * implementation and factory are live.
 *
 * TWO contracts, in order:
 *   1. OfferVault        — the implementation cloned once per offer. Holds nothing itself.
 *   2. OfferVaultFactory — the venue: prices offers, deploys vaults, holds the per-escrow
 *                          registry. Never custodies a token.
 *
 * ⚠️ RUN THIS ONCE, DELIBERATELY. It is deliberately NOT part of the tag-triggered
 *    DeploymentScript: that runs on every release tag, and redeploying the factory would
 *    orphan the registry (`hasBeenSold`, `holdbackVault`) that live vaults depend on.
 *    Existing vaults keep working — their funds are reachable by their own LP and seller
 *    regardless — but a new factory would not know which escrows had already been sold,
 *    so a second reserve could be stacked on an escrow that already has one.
 *
 * Required environment:
 *   TRUSTED_IMPLEMENTATION_ADDRESS   the EscrowContract implementation to serve (§3.4 step 1)
 *   DEFAULT_ARBITER_ADDRESS          the fallback Safe — cross-checked against the implementation
 *   MARKETPLACE_OWNER_ADDRESS        Ownable2Step owner; MUST differ from the Safe
 *   MARKETPLACE_FEE_RECIPIENT        where protocol fees land at acceptance
 *   MARKETPLACE_FEE_BPS              §13.1 — proposed 25–50; hard cap 1000
 *   MARKETPLACE_OFFER_DURATION_SECS  §13.2 — proposed 86400 (24h); must be > 0
 * Optional:
 *   MARKETPLACE_MIN_OFFER_BPS        §13.12 — settled at 1000 (10%); cap 10000
 */
contract DeployMarketplace is Script {
    uint256 internal constant DEFAULT_MIN_OFFER_BPS = 1000; // §13.12, settled

    function run() external {
        uint256 deployerPrivateKey = vm.envUint("RELAYER_WALLET_PRIVATE_KEY");
        uint256 chainId = vm.envUint("CHAIN_ID");
        require(block.chainid == chainId, "Chain ID mismatch");

        address implementation = vm.envAddress("TRUSTED_IMPLEMENTATION_ADDRESS");
        address expectedSafe = vm.envAddress("DEFAULT_ARBITER_ADDRESS");
        address owner = vm.envAddress("MARKETPLACE_OWNER_ADDRESS");
        address feeRecipient = vm.envAddress("MARKETPLACE_FEE_RECIPIENT");

        // No silent defaults for anything that affects money. §13.1 and §13.2 are still
        // "proposed" in the spec, so they must be stated explicitly at deploy time.
        uint256 feeBps = vm.envUint("MARKETPLACE_FEE_BPS");
        uint256 offerDuration = vm.envUint("MARKETPLACE_OFFER_DURATION_SECS");
        uint256 minOfferBps = vm.envOr("MARKETPLACE_MIN_OFFER_BPS", DEFAULT_MIN_OFFER_BPS);

        // ── Guards ────────────────────────────────────────────────────────────────
        require(implementation.code.length > 0, "TRUSTED_IMPLEMENTATION_ADDRESS has no code on this chain");
        require(owner != address(0), "MARKETPLACE_OWNER_ADDRESS must not be zero");
        require(feeRecipient != address(0), "MARKETPLACE_FEE_RECIPIENT must not be zero");

        // §3.3E: the marketplace owner sets fees; the Safe arbitrates disputes. One key
        // holding both is a total-compromise target.
        require(owner != expectedSafe, "MARKETPLACE_OWNER_ADDRESS must differ from the DEFAULT_ARBITER Safe");

        // Prove we are pointing at an implementation from THIS deployment lineage, not the
        // pre-§3.3 one still live on mainnet. Both reads revert on the old implementation
        // (neither member exists), which is exactly the failure we want.
        address implArbiter = EscrowContract(implementation).DEFAULT_ARBITER();
        require(implArbiter == expectedSafe, "implementation's DEFAULT_ARBITER != DEFAULT_ARBITER_ADDRESS");
        uint64 window = EscrowContract(implementation).NOMINATION_WINDOW();
        require(window == 72 hours, "implementation NOMINATION_WINDOW is not 72h - wrong implementation?");

        // Fail early with a readable message rather than inside the constructor.
        require(feeBps <= 1000, "MARKETPLACE_FEE_BPS exceeds the 10% hard cap");
        require(minOfferBps <= 10000, "MARKETPLACE_MIN_OFFER_BPS exceeds 10000");
        require(offerDuration > 0, "MARKETPLACE_OFFER_DURATION_SECS must be > 0");

        console.log("=================================================");
        console.log("Deploying marketplace (per-offer vault model)");
        console.log("  Trusted implementation:", implementation);
        console.log("  Implementation's Safe :", implArbiter);
        console.log("  Owner                 :", owner);
        console.log("  Fee recipient         :", feeRecipient);
        console.log("  Fee (bps)             :", feeBps);
        console.log("  Min offer (bps)       :", minOfferBps);
        console.log("  Offer duration (s)    :", offerDuration);
        console.log("=================================================");

        vm.startBroadcast(deployerPrivateKey);
        OfferVault vaultImplementation = new OfferVault();
        OfferVaultFactory factory = new OfferVaultFactory(
            address(vaultImplementation), implementation, feeBps, minOfferBps, offerDuration, feeRecipient, owner
        );
        vm.stopBroadcast();

        console.log("OfferVault implementation:", address(vaultImplementation));
        console.log("OfferVaultFactory        :", address(factory));

        // §16 phase 6.5: recompute the codehash against the FINAL implementation address.
        // Read it back off the deployed factory so the log proves what it will enforce.
        console.log("=================================================");
        console.log("EXPECTED_ESCROW_CODEHASH (record this):");
        console.logBytes32(factory.EXPECTED_ESCROW_CODEHASH());
        console.log("=================================================");
        console.log("Custody: the factory holds NO tokens. Each offer's capital sits in its");
        console.log("own OfferVault clone, reachable only by that offer's LP or seller.");
        console.log("=================================================");
        console.log("Inventory reality (spec 3.4): the marketplace opens EMPTY and fills");
        console.log("only from escrows created by the NEW factory. Old-implementation");
        console.log("escrows are permanently invisible to it.");
        console.log("=================================================");
    }
}
