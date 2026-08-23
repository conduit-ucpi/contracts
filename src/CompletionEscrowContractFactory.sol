// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {CompletionEscrowContract} from "./CompletionEscrowContract.sol";

/**
 * ═══════════════════════════════════════════════════════════════════════════════════
 *           🔒 COMPLETION ESCROW FACTORY (DUAL-VERIFY + RECIPIENT SPLIT) 🔒
 * ═══════════════════════════════════════════════════════════════════════════════════
 *
 * Creates individual CompletionEscrowContract instances via minimal proxies. Each
 * escrow gates payout behind BOTH supplier and buyer agreement (dual-verify) and pays
 * out to up to MAX_PAYEES payees by a configured basis-point split. The factory
 * has no power over contracts once created.
 *
 * The payee split is validated inside CompletionEscrowContract.initialize; that
 * revert bubbles up through createEscrowContract, so callers see the same errors.
 * ═══════════════════════════════════════════════════════════════════════════════════
 */
contract CompletionEscrowContractFactory {

    // Custom errors (saves gas compared to require strings)
    error InvalidOwnerAddress();
    error InvalidImplementationAddress();
    error InvalidTokenAddress();
    error InvalidBuyerAddress();
    error InvalidLeadSupplierAddress();
    error BuyerAndLeadSupplierMustDiffer();
    error ArbiterMustBeDistinct();
    error VerifierCannotBeLeadSupplier();
    error AmountMustBeGreaterThanZero();
    error OnlyOwner();

    // 🔒 IMMUTABLE FACTORY SETTINGS
    address public immutable OWNER;          // Platform/arbiter - creates contracts, cannot take money
    address public immutable IMPLEMENTATION; // Template contract (all escrows share its security)
    address public immutable PLATFORM_FEE_WALLET;  // Receives platform fees (defaults to OWNER if unset)

    // 📢 PUBLIC EVENT: Records every escrow creation
    event ContractCreated(
        address indexed contractAddress,
        address indexed buyer,
        address indexed leadSupplier,
        uint256 amount,
        address[] payees,
        uint256[] payeeBps,
        address verifier,
        string description
    );

    constructor(address _owner, address _implementation, address _platformFeeWallet) {
        if (_owner == address(0)) revert InvalidOwnerAddress();
        if (_implementation == address(0)) revert InvalidImplementationAddress();

        OWNER = _owner;
        IMPLEMENTATION = _implementation;
        PLATFORM_FEE_WALLET = _platformFeeWallet == address(0) ? _owner : _platformFeeWallet;
    }

    /**
     * 🏭 CREATE NEW COMPLETION ESCROW CONTRACT
     *
     * Creates a dual-verify escrow between BUYER and LEAD_SUPPLIER (supplier), paying out to
     * 1..MAX_PAYEES payees by a basis-point split (the bps must sum to 10000).
     * All addresses and the split are locked in at creation. Charges the flat 1%
     * platform fee - this is the path for top-level (root) escrows.
     */
    function createEscrowContract(
        address tokenAddress,
        address buyer,
        address leadSupplier,
        uint256 amount,
        address[] calldata payees,
        uint256[] calldata payeeBps,
        address verifier,
        string memory description
    ) external returns (address) {
        return _create(EscrowParams({
            tokenAddress: tokenAddress,
            buyer: buyer,
            leadSupplier: leadSupplier,
            amount: amount,
            payees: payees,
            payeeBps: payeeBps,
            verifier: verifier,
            creatorFee: quoteCreatorFee(amount)
        }), description);
    }

    /**
     * 🏭 CREATE CHILD ESCROW CONTRACT (FEE-EXEMPT, PLATFORM ONLY)
     *
     * The platform fee is charged once per fan-out tree, on the top-level escrow.
     * Child nodes are created through this fee-exempt path instead. Only OWNER (the
     * platform relayer, which deploys all nodes) may call it - otherwise anyone
     * could create fee-free escrows.
     */
    function createChildEscrowContract(
        address tokenAddress,
        address buyer,
        address leadSupplier,
        uint256 amount,
        address[] calldata payees,
        uint256[] calldata payeeBps,
        address verifier,
        string memory description
    ) external returns (address) {
        if (msg.sender != OWNER) revert OnlyOwner();
        return _create(EscrowParams({
            tokenAddress: tokenAddress,
            buyer: buyer,
            leadSupplier: leadSupplier,
            amount: amount,
            payees: payees,
            payeeBps: payeeBps,
            verifier: verifier,
            creatorFee: 0
        }), description);
    }

    /**
     * Shared validate + deploy + announce path for both creation variants. The params
     * arrive as a memory struct so the deploy step keeps a shallow stack.
     */
    function _create(EscrowParams memory p, string memory description) internal returns (address) {
        if (p.tokenAddress == address(0)) revert InvalidTokenAddress();
        if (p.buyer == address(0)) revert InvalidBuyerAddress();
        if (p.leadSupplier == address(0)) revert InvalidLeadSupplierAddress();
        if (p.buyer == p.leadSupplier) revert BuyerAndLeadSupplierMustDiffer();
        // Every escrow this factory creates is arbitrated by OWNER (see _init), so a party
        // that IS the owner would hold two of the three votes — and because both votes read
        // one storage slot, a single vote would settle the dispute at any split they chose.
        // The escrow enforces this itself; pre-checking here turns it into a clear refusal
        // at creation rather than an opaque revert from inside initialize.
        if (p.buyer == OWNER || p.leadSupplier == OWNER) revert ArbiterMustBeDistinct();
        // A nominated verifier acts for the buyer - it must never be the supplier
        if (p.verifier == p.leadSupplier) revert VerifierCannotBeLeadSupplier();
        if (p.amount == 0) revert AmountMustBeGreaterThanZero();
        // The payee split is validated in CompletionEscrowContract.initialize.

        address clone = _deploy(p);

        emit ContractCreated(
            clone,
            p.buyer,
            p.leadSupplier,
            p.amount,
            p.payees,
            p.payeeBps,
            p.verifier,
            description
        );

        return clone;
    }

    // Internal carrier for escrow parameters - keeps createEscrowContract's stack shallow
    struct EscrowParams {
        address tokenAddress;
        address buyer;
        address leadSupplier;
        uint256 amount;
        address[] payees;
        uint256[] payeeBps;
        address verifier;
        uint256 creatorFee;
    }

    /**
     * 🏭 Deterministically clones the implementation and initializes it. Split into
     * _computeSalt and _init so each heavy step gets its own stack frame and the build
     * stays within the stack limit with via_ir disabled.
     */
    function _deploy(EscrowParams memory p) internal returns (address) {
        address clone = Clones.cloneDeterministic(IMPLEMENTATION, _computeSalt(p));
        _init(clone, p);
        return clone;
    }

    function _computeSalt(EscrowParams memory p) internal view returns (bytes32) {
        // abi.encode (not encodePacked) so the dynamic arrays are encoded unambiguously
        return keccak256(abi.encode(
            p.tokenAddress,
            p.buyer,
            p.leadSupplier,
            p.amount,
            p.payees,
            p.payeeBps,
            block.timestamp
        ));
    }

    function _init(address clone, EscrowParams memory p) internal {
        CompletionEscrowContract(clone).initialize(
            CompletionEscrowContract.InitParams({
                tokenAddress: p.tokenAddress,
                buyer: p.buyer,
                leadSupplier: p.leadSupplier,
                arbiter: OWNER,
                amount: p.amount,
                creatorFee: p.creatorFee,
                platformFeeWallet: PLATFORM_FEE_WALLET,
                payees: p.payees,
                payeeBps: p.payeeBps,
                verifier: p.verifier
            })
        );
    }

    /**
     * 📊 Flat 1% platform fee, floor division. No minimum and no thresholds: tiny
     * amounts floor to a zero fee, and 1% can never reach the escrow contract's
     * creatorFee < amount limit, so no amount or split can revert a creation.
     *
     * Public so off-chain services quote the fee by asking the contract instead of
     * duplicating the formula. Child escrows (createChildEscrowContract) are exempt.
     */
    function quoteCreatorFee(uint256 amount) public pure returns (uint256) {
        return amount / 100;
    }

    function getContractAddress(
        address tokenAddress,
        address buyer,
        address leadSupplier,
        uint256 amount,
        address[] calldata payees,
        uint256[] calldata payeeBps,
        uint256 creationTimestamp
    ) external view returns (address) {
        bytes32 salt = keccak256(abi.encode(
            tokenAddress,
            buyer,
            leadSupplier,
            amount,
            payees,
            payeeBps,
            creationTimestamp
        ));

        return Clones.predictDeterministicAddress(IMPLEMENTATION, salt, address(this));
    }
}
