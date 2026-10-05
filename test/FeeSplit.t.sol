// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {IERC1271} from "@openzeppelin/contracts/interfaces/IERC1271.sol";
import {EscrowContract} from "../src/EscrowContract.sol";
import {EscrowContractFactory} from "../src/EscrowContractFactory.sol";

contract FeeSplitToken {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    uint8 public constant decimals = 6;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        require(balanceOf[msg.sender] >= amount, "balance");
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        require(allowance[from][msg.sender] >= amount, "allowance");
        require(balanceOf[from] >= amount, "balance");
        allowance[from][msg.sender] -= amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }
}

/// A contract wallet that approves whatever its one EOA key signed - stands in for a Safe.
contract FeeSplitMultisig is IERC1271 {
    address internal immutable KEY;

    constructor(address key) {
        KEY = key;
    }

    function isValidSignature(bytes32 hash, bytes calldata signature) external view returns (bytes4) {
        (uint8 v, bytes32 r, bytes32 s) = (uint8(signature[64]), bytes32(signature[0:32]), bytes32(signature[32:64]));
        return ecrecover(hash, v, r, s) == KEY ? IERC1271.isValidSignature.selector : bytes4(0xffffffff);
    }
}

/**
 * Partner fee splits: a share OF the platform fee, admitted only with FEE_SPLIT_SIGNER's
 * signature over the complete terms. The properties pinned here:
 *   • the buyer's payment and the seller's net never depend on a split;
 *   • platform + partner == CREATOR_FEE, exactly;
 *   • no split without the signer, and no signature reusable on any other terms, factory
 *     or chain;
 *   • an unsplit escrow's address is exactly what it was before splits existed.
 */
contract FeeSplitTest is Test {
    FeeSplitToken internal usdc;
    EscrowContract internal implementation;
    EscrowContractFactory internal factory;

    uint256 internal constant SIGNER_KEY = 0xA11CE;
    uint256 internal constant ROGUE_KEY = 0xBAD;
    address internal signer;

    address internal owner = address(0x0A11);
    address internal feeRecipient = address(0xFEE);
    address internal buyer = address(0xB0B);
    address internal seller = address(0x5E11);
    address internal arbiter = address(0xA4B);
    address internal partner = address(0x9A27);
    address internal stranger = address(0x57A9);
    address internal constant DEFAULT_ARBITER = address(0xDEFA17);
    bytes20 internal constant IMPL_COMMIT = bytes20(0x1111111111111111111111111111111111111111);
    bytes20 internal constant FACTORY_COMMIT = bytes20(0x2222222222222222222222222222222222222222);

    uint256 internal constant AMOUNT = 1_000e6;
    uint256 internal constant FEE = 10e6; // 1% of AMOUNT
    uint256 internal expiry;
    bytes32 internal constant ID = keccak256("pending-contract-1");

    event FeeSplitApplied(
        address indexed contractAddress, address indexed partner, uint16 partnerBps, uint256 partnerFee
    );
    event PlatformFeeCollected(address recipient, uint256 feeAmount, uint256 timestamp);
    event PartnerFeeCollected(address recipient, uint256 feeAmount, uint256 timestamp);

    function setUp() public {
        vm.warp(1_800_000_000);
        expiry = block.timestamp + 7 days;
        signer = vm.addr(SIGNER_KEY);
        usdc = new FeeSplitToken();
        implementation = new EscrowContract(DEFAULT_ARBITER, IMPL_COMMIT);
        factory = new EscrowContractFactory(owner, address(implementation), feeRecipient, signer, FACTORY_COMMIT);
        usdc.mint(buyer, AMOUNT * 100);
    }

    // ── helpers ──────────────────────────────────────────────────────────────

    struct T {
        address token;
        address buyer;
        address seller;
        uint256 amount;
        uint256 expiry;
        address arbiter;
        bytes32 id;
        address partner;
        uint16 bps;
    }

    function terms(uint16 bps) internal view returns (T memory) {
        return T(address(usdc), buyer, seller, AMOUNT, expiry, arbiter, ID, partner, bps);
    }

    function split(T memory t) internal pure returns (EscrowContractFactory.FeeSplit memory) {
        return EscrowContractFactory.FeeSplit(t.partner, t.bps);
    }

    function sign(EscrowContractFactory f, T memory t, uint256 key) internal view returns (bytes memory) {
        bytes32 digest = f.feeSplitDigest(t.token, t.buyer, t.seller, t.amount, t.expiry, t.arbiter, t.id, split(t));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(key, digest);
        return abi.encodePacked(r, s, v);
    }

    function predict(T memory t) internal view returns (address) {
        return
            factory.getContractAddressWithSplit(
                t.token, t.buyer, t.seller, t.amount, t.expiry, t.arbiter, t.id, split(t)
            );
    }

    function create(T memory t, bytes memory sig) internal returns (EscrowContract) {
        return EscrowContract(
            factory.createEscrowContractWithSplit(
                t.token, t.buyer, t.seller, t.amount, t.expiry, "deal", t.arbiter, t.id, split(t), sig
            )
        );
    }

    function createAndActivate(T memory t, bytes memory sig) internal returns (EscrowContract) {
        return EscrowContract(
            factory.createAndActivateWithSplit(
                t.token, t.buyer, t.seller, t.amount, t.expiry, "deal", t.arbiter, t.id, split(t), sig
            )
        );
    }

    function deposit(EscrowContract e) internal {
        vm.startPrank(buyer);
        usdc.approve(address(e), e.AMOUNT());
        e.depositFunds();
        vm.stopPrank();
    }

    // ── addresses ────────────────────────────────────────────────────────────

    function test_NoSplitAddressIsExactlyThePreSplitAddress() public view {
        T memory t = terms(0);
        t.partner = address(0);
        assertEq(
            predict(t), factory.getContractAddress(t.token, t.buyer, t.seller, t.amount, t.expiry, t.arbiter, t.id)
        );
    }

    function test_SplitMovesTheAddress() public view {
        T memory half = terms(5000);
        T memory whole = terms(10_000);
        T memory otherPartner = terms(5000);
        otherPartner.partner = stranger;
        address unsplit = factory.getContractAddress(address(usdc), buyer, seller, AMOUNT, expiry, arbiter, ID);

        assertTrue(predict(half) != unsplit, "split must not share the unsplit address");
        assertTrue(predict(half) != predict(whole), "bps is committed to");
        assertTrue(predict(half) != predict(otherPartner), "partner is committed to");
    }

    function test_CreatedAtThePredictedAddress() public {
        T memory t = terms(5000);
        address expected = predict(t);
        assertEq(address(create(t, sign(factory, t, SIGNER_KEY))), expected);
    }

    // ── money ────────────────────────────────────────────────────────────────

    function test_HalfSplitOnDeposit() public {
        T memory t = terms(5000);
        EscrowContract e = create(t, sign(factory, t, SIGNER_KEY));
        assertEq(e.PARTNER_FEE_RECIPIENT(), partner);
        assertEq(e.PARTNER_FEE(), FEE / 2);
        assertEq(e.CREATOR_FEE(), FEE);

        vm.prank(buyer);
        usdc.approve(address(e), AMOUNT);
        vm.expectEmit(address(e));
        emit PlatformFeeCollected(feeRecipient, FEE / 2, block.timestamp);
        vm.expectEmit(address(e));
        emit PartnerFeeCollected(partner, FEE / 2, block.timestamp);
        vm.prank(buyer);
        e.depositFunds();

        assertEq(usdc.balanceOf(feeRecipient), FEE / 2);
        assertEq(usdc.balanceOf(partner), FEE / 2);
        assertEq(usdc.balanceOf(address(e)), AMOUNT - FEE, "escrowed amount is untouched by the split");

        vm.warp(expiry);
        vm.prank(seller);
        e.claimFunds();
        assertEq(usdc.balanceOf(seller), AMOUNT - FEE, "seller nets exactly what an unsplit escrow pays");
    }

    function test_HalfSplitOnInstantTransferDeposit() public {
        T memory t = terms(5000);
        t.expiry = 0;
        EscrowContract e = create(t, sign(factory, t, SIGNER_KEY));
        deposit(e);
        assertEq(usdc.balanceOf(feeRecipient), FEE / 2);
        assertEq(usdc.balanceOf(partner), FEE / 2);
        assertEq(usdc.balanceOf(seller), AMOUNT - FEE);
    }

    /// The late-funding path: buyer pays the bare address, a stranger deploys onto it.
    function test_StrangerDeploysLateFundedSplitEscrow() public {
        T memory t = terms(5000);
        bytes memory sig = sign(factory, t, SIGNER_KEY);
        address at = predict(t);
        vm.prank(buyer);
        usdc.transfer(at, AMOUNT);

        vm.prank(stranger);
        EscrowContract e = createAndActivate(t, sig);
        assertEq(address(e), at);
        assertEq(usdc.balanceOf(feeRecipient), FEE / 2);
        assertEq(usdc.balanceOf(partner), FEE / 2);
        assertEq(usdc.balanceOf(address(e)), AMOUNT - FEE);
        assertEq(usdc.balanceOf(stranger), 0, "the caller gets nothing for deploying");
    }

    function test_LateFundedInstantSplit() public {
        T memory t = terms(2500);
        t.expiry = 0;
        bytes memory sig = sign(factory, t, SIGNER_KEY);
        address at = predict(t);
        vm.prank(buyer);
        usdc.transfer(at, AMOUNT);

        vm.prank(stranger);
        createAndActivate(t, sig);
        assertEq(usdc.balanceOf(feeRecipient), FEE - FEE / 4);
        assertEq(usdc.balanceOf(partner), FEE / 4);
        assertEq(usdc.balanceOf(seller), AMOUNT - FEE);
    }

    function test_WholeFeeToPartner() public {
        T memory t = terms(10_000);
        EscrowContract e = create(t, sign(factory, t, SIGNER_KEY));
        deposit(e);
        assertEq(usdc.balanceOf(feeRecipient), 0);
        assertEq(usdc.balanceOf(partner), FEE);
        assertEq(usdc.balanceOf(address(e)), AMOUNT - FEE);
    }

    /// At the 0.30 USDC minimum fee, with a share that does not divide evenly: dust to the platform.
    function test_MinimumFeeRoundsDustToPlatform() public {
        T memory t = terms(3333);
        t.amount = 10e6; // 1% = 0.1 USDC, below the 0.30 minimum
        EscrowContract e = create(t, sign(factory, t, SIGNER_KEY));
        assertEq(e.CREATOR_FEE(), 300_000);
        assertEq(e.PARTNER_FEE(), 99_990); // 300_000 * 3333 / 10_000, rounded down
        deposit(e);
        assertEq(usdc.balanceOf(partner), 99_990);
        assertEq(usdc.balanceOf(feeRecipient), 200_010);
    }

    /// A fee-free test escrow with a split: nothing to share, nothing stored, still works.
    function test_SplitOnFeeFreeAmount() public {
        T memory t = terms(5000);
        t.amount = 1_000; // 0.001 USDC: zero fee
        EscrowContract e = create(t, sign(factory, t, SIGNER_KEY));
        assertEq(e.CREATOR_FEE(), 0);
        assertEq(e.PARTNER_FEE(), 0);
        assertEq(e.PARTNER_FEE_RECIPIENT(), address(0));
        deposit(e);
        assertEq(usdc.balanceOf(address(e)), 1_000);
    }

    function testFuzz_PlatformPlusPartnerIsExactlyTheFee(uint256 amount, uint16 bps) public {
        amount = bound(amount, 300_001, AMOUNT * 50);
        bps = uint16(bound(bps, 1, 10_000));
        T memory t = terms(bps);
        t.amount = amount;
        EscrowContract e = create(t, sign(factory, t, SIGNER_KEY));
        uint256 fee = e.CREATOR_FEE();
        deposit(e);
        assertEq(usdc.balanceOf(feeRecipient) + usdc.balanceOf(partner), fee);
        assertEq(usdc.balanceOf(address(e)), amount - fee);
    }

    function test_EmitsFeeSplitApplied() public {
        T memory t = terms(5000);
        bytes memory sig = sign(factory, t, SIGNER_KEY);
        vm.expectEmit(address(factory));
        emit FeeSplitApplied(predict(t), partner, 5000, FEE / 2);
        create(t, sig);
    }

    function test_UnsplitEscrowStoresNoPartner() public {
        EscrowContract e = EscrowContract(
            factory.createEscrowContract(address(usdc), buyer, seller, AMOUNT, expiry, "deal", arbiter, ID)
        );
        assertEq(e.PARTNER_FEE(), 0);
        assertEq(e.PARTNER_FEE_RECIPIENT(), address(0));
        deposit(e);
        assertEq(usdc.balanceOf(feeRecipient), FEE);
    }

    // ── authorisation ────────────────────────────────────────────────────────

    function test_RejectsSignatureFromAnotherKey() public {
        T memory t = terms(5000);
        bytes memory sig = sign(factory, t, ROGUE_KEY);
        vm.expectRevert(EscrowContractFactory.InvalidFeeSplitSignature.selector);
        create(t, sig);
    }

    /// With a dedicated signer, even OWNER's key cannot authorise a split.
    function test_RejectsOwnerKeyWhenSignerIsDedicated() public {
        uint256 ownerKey = 0x0E11;
        EscrowContractFactory f =
            new EscrowContractFactory(vm.addr(ownerKey), address(implementation), feeRecipient, signer, bytes20(0));
        T memory t = terms(5000);
        bytes memory sig = sign(f, t, ownerKey);
        vm.expectRevert(EscrowContractFactory.InvalidFeeSplitSignature.selector);
        f.createEscrowContractWithSplit(
            t.token, t.buyer, t.seller, t.amount, t.expiry, "deal", t.arbiter, t.id, split(t), sig
        );
    }

    function test_SignerDefaultsToOwner() public {
        uint256 ownerKey = 0x0E11;
        EscrowContractFactory f =
            new EscrowContractFactory(vm.addr(ownerKey), address(implementation), feeRecipient, address(0), bytes20(0));
        assertEq(f.FEE_SPLIT_SIGNER(), vm.addr(ownerKey));
        T memory t = terms(5000);
        f.createEscrowContractWithSplit(
            t.token, t.buyer, t.seller, t.amount, t.expiry, "deal", t.arbiter, t.id, split(t), sign(f, t, ownerKey)
        );
    }

    function test_RejectsEmptySignature() public {
        vm.expectRevert(EscrowContractFactory.InvalidFeeSplitSignature.selector);
        create(terms(5000), "");
    }

    /// Every field of the signed struct is load-bearing: change any one and the signature dies.
    function test_RejectsSignatureOnTamperedTerms() public {
        T memory signed = terms(5000);
        bytes memory sig = sign(factory, signed, SIGNER_KEY);

        for (uint256 i = 0; i < 9; i++) {
            T memory t = terms(5000);
            if (i == 0) t.token = address(new FeeSplitToken());
            if (i == 1) t.buyer = address(0xB0B2);
            if (i == 2) t.seller = address(0x5E12);
            if (i == 3) t.amount = AMOUNT + 1;
            if (i == 4) t.expiry = expiry + 1;
            if (i == 5) t.arbiter = address(0xA4C);
            if (i == 6) t.id = keccak256("pending-contract-2");
            if (i == 7) t.partner = stranger;
            if (i == 8) t.bps = 5001;
            vm.expectRevert(EscrowContractFactory.InvalidFeeSplitSignature.selector);
            this.externalCreate(t, sig);
        }
    }

    function externalCreate(T memory t, bytes memory sig) external returns (EscrowContract) {
        return create(t, sig);
    }

    function test_RejectsSignatureForAnotherFactory() public {
        EscrowContractFactory other =
            new EscrowContractFactory(owner, address(implementation), feeRecipient, signer, bytes20(0));
        T memory t = terms(5000);
        bytes memory sig = sign(other, t, SIGNER_KEY);
        vm.expectRevert(EscrowContractFactory.InvalidFeeSplitSignature.selector);
        create(t, sig);
    }

    function test_RejectsSignatureFromAnotherChain() public {
        T memory t = terms(5000);
        bytes memory sig = sign(factory, t, SIGNER_KEY);
        vm.chainId(8453);
        vm.expectRevert(EscrowContractFactory.InvalidFeeSplitSignature.selector);
        create(t, sig);
    }

    /// Replay can only rebuild the one address, which CREATE2 deploys once.
    function test_ReplayCannotDeployTwice() public {
        T memory t = terms(5000);
        bytes memory sig = sign(factory, t, SIGNER_KEY);
        create(t, sig);
        vm.expectRevert();
        create(t, sig);
    }

    function test_AcceptsErc1271Signer() public {
        FeeSplitMultisig safe = new FeeSplitMultisig(signer);
        EscrowContractFactory f =
            new EscrowContractFactory(owner, address(implementation), feeRecipient, address(safe), bytes20(0));
        T memory t = terms(5000);
        f.createEscrowContractWithSplit(
            t.token, t.buyer, t.seller, t.amount, t.expiry, "deal", t.arbiter, t.id, split(t), sign(f, t, SIGNER_KEY)
        );
    }

    // ── split validation ─────────────────────────────────────────────────────

    function test_RejectsBpsAboveWholeFee() public {
        T memory t = terms(10_001);
        bytes memory sig = sign(factory, t, SIGNER_KEY);
        vm.expectRevert(EscrowContractFactory.InvalidPartnerBps.selector);
        create(t, sig);
    }

    function test_RejectsPartnerWithoutShare() public {
        T memory t = terms(0);
        vm.expectRevert(EscrowContractFactory.InvalidPartnerBps.selector);
        create(t, "");
    }

    function test_RejectsBadPartnerAddresses() public {
        address[4] memory bad = [address(0), buyer, seller, feeRecipient];
        for (uint256 i = 0; i < bad.length; i++) {
            T memory t = terms(5000);
            t.partner = bad[i];
            bytes memory sig = sign(factory, t, SIGNER_KEY);
            vm.expectRevert(EscrowContractFactory.InvalidPartnerAddress.selector);
            this.externalCreate(t, sig);
        }
    }

    // ── direct initialize guards ─────────────────────────────────────────────

    function test_InitializeRejectsPartnerFeeAboveCreatorFee() public {
        EscrowContract e = EscrowContract(Clones.clone(address(implementation)));
        vm.expectRevert(EscrowContract.PartnerFeeExceedsCreatorFee.selector);
        e.initialize(address(usdc), buyer, seller, arbiter, AMOUNT, expiry, FEE, feeRecipient, partner, FEE + 1);
    }

    function test_InitializeRejectsPartnerFeeWithoutRecipient() public {
        EscrowContract e = EscrowContract(Clones.clone(address(implementation)));
        vm.expectRevert(EscrowContract.InvalidPartnerFeeRecipient.selector);
        e.initialize(address(usdc), buyer, seller, arbiter, AMOUNT, expiry, FEE, feeRecipient, address(0), 1);
    }

    // ── git commit ───────────────────────────────────────────────────────────

    function test_GitCommitIsStampedAndClonesReportTheImplementations() public {
        assertEq(factory.GIT_COMMIT(), FACTORY_COMMIT);
        assertEq(implementation.GIT_COMMIT(), IMPL_COMMIT);
        EscrowContract e = EscrowContract(
            factory.createEscrowContract(address(usdc), buyer, seller, AMOUNT, expiry, "deal", arbiter, ID)
        );
        assertEq(e.GIT_COMMIT(), IMPL_COMMIT);
    }
}
