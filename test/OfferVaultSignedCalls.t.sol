// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {EscrowContract} from "../src/EscrowContract.sol";
import {EscrowContractFactory} from "../src/EscrowContractFactory.sol";
import {OfferVault} from "../src/OfferVault.sol";
import {OfferVaultFactory} from "../src/OfferVaultFactory.sol";

contract VaultSignedCallsToken is ERC20 {
    constructor() ERC20("Test USD", "TUSD") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

/// Foundry's own EIP-712 hashing of a typed-data JSON document (see SignedCalls.t.sol).
interface VaultTypedDataHasher {
    function eip712HashTypedData(string calldata jsonData) external pure returns (bytes32);
}

/// A contract wallet that vouches for whatever its owner key signed (ERC-1271).
contract VaultSignedCallsWallet {
    address public immutable OWNER;

    constructor(address owner) {
        OWNER = owner;
    }

    function isValidSignature(bytes32 hash, bytes calldata signature) external view returns (bytes4) {
        (bytes32 r, bytes32 s, uint8 v) = abi.decode(signature, (bytes32, bytes32, uint8));
        return ecrecover(hash, v, r, s) == OWNER ? bytes4(0x1626ba7e) : bytes4(0xffffffff);
    }
}

/**
 * A seller who holds no ETH takes or turns down an offer by signing; a relayer delivers it.
 * The vault acts for the signer, for exactly what was signed, once.
 */
contract OfferVaultSignedCallsTest is Test {
    EscrowContractFactory escrowFactory;
    OfferVaultFactory market;
    VaultSignedCallsToken token;

    uint256 constant SELLER_KEY = 0x5E11;
    uint256 constant STRANGER_KEY = 0xBAD;
    address seller = vm.addr(SELLER_KEY);
    address stranger = vm.addr(STRANGER_KEY);
    address buyer = address(0xB0B);
    address arbiter = address(0xA4B);
    address platform = address(0x91A7);
    address owner = address(0x0E4);
    address feeRecipient = address(0xFEE);
    address lp = address(0x1B);
    address relayer = address(0x4E1A);

    uint256 constant AMOUNT = 10_000e6;
    uint256 constant OFFER = 9_000e6;
    bytes32 constant ACCEPT_OFFER = keccak256("AcceptOffer(uint256 nonce,uint256 deadline)");
    bytes32 constant REJECT_OFFER = keccak256("RejectOffer(uint256 nonce,uint256 deadline)");
    bytes32 constant CANCEL = keccak256("CancelSignedCall(uint256 cancelledNonce,uint256 nonce,uint256 deadline)");
    bytes32 constant APPROVE_TRANSFER =
        keccak256("ApproveRecipientTransfer(address operator,address newRecipient,uint256 nonce,uint256 deadline)");

    function setUp() public {
        token = new VaultSignedCallsToken();
        EscrowContract implementation = new EscrowContract(address(0xDEFA17), bytes20(0));
        escrowFactory = new EscrowContractFactory(platform, address(implementation), platform, bytes20(0));
        market = new OfferVaultFactory(
            address(new OfferVault()), address(implementation), 50, 1000, 24 hours, feeRecipient, owner
        );
    }

    function escrowFor(address asSeller, uint256 salt) internal returns (EscrowContract escrow) {
        vm.prank(platform);
        escrow = EscrowContract(
            escrowFactory.createEscrowContract(
                address(token), buyer, asSeller, AMOUNT, block.timestamp + 30 days, "x", arbiter, bytes32(salt)
            )
        );
        token.mint(address(escrow), AMOUNT);
        escrow.checkAndActivate();
    }

    function openOffer(EscrowContract escrow) internal returns (OfferVault vault) {
        vm.prank(platform);
        vault = OfferVault(market.createOffer(address(escrow), lp, OFFER, 0, 0));
        token.mint(address(vault), OFFER);
        vault.fund();
    }

    function deadlineSoon() internal view returns (uint256) {
        return block.timestamp + 1 hours;
    }

    // Built field by field, the way a wallet builds it, not the way the contract does.
    function message(bytes32 typeHash, uint256 nonce, uint256 deadline) internal pure returns (bytes32) {
        return keccak256(abi.encode(typeHash, nonce, deadline));
    }

    function signFor(uint256 key, OfferVault vault, bytes32 structHash) internal view returns (bytes memory) {
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", vault.signedCallDomainSeparator(), structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(key, digest);
        return abi.encodePacked(r, s, v);
    }

    /// The seller's half on the escrow, itself signed and relayed: name this vault and its LP.
    function signedApproval(EscrowContract escrow, OfferVault vault, uint256 nonce) internal {
        uint256 deadline = deadlineSoon();
        bytes32 structHash = keccak256(abi.encode(APPROVE_TRANSFER, address(vault), lp, nonce, deadline));
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", escrow.signedCallDomainSeparator(), structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(SELLER_KEY, digest);
        vm.prank(relayer);
        escrow.executeSigned(
            seller,
            abi.encodeCall(EscrowContract.approveRecipientTransfer, (address(vault), lp)),
            nonce,
            deadline,
            abi.encodePacked(r, s, v)
        );
    }

    function deliver(OfferVault vault, address signer, bytes memory call, uint256 nonce, bytes memory signature)
        internal
    {
        vm.prank(relayer);
        vault.executeSigned(signer, call, nonce, deadlineSoon(), signature);
    }

    // ---- it works, and for the signer ----

    function test_a_seller_with_no_eth_takes_an_offer_with_two_signatures() public {
        EscrowContract escrow = escrowFor(seller, 1);
        OfferVault vault = openOffer(escrow);
        assertEq(seller.balance, 0);

        signedApproval(escrow, vault, 1);
        deliver(
            vault,
            seller,
            abi.encodeCall(OfferVault.accept, ()),
            1,
            signFor(SELLER_KEY, vault, message(ACCEPT_OFFER, 1, deadlineSoon()))
        );

        assertEq(escrow.recipient(), lp);
        assertEq(token.balanceOf(seller), vault.netAmount());
        assertEq(token.balanceOf(feeRecipient), vault.fee());
        assertEq(uint256(vault.status()), uint256(OfferVault.Status.SETTLED));
    }

    function test_a_seller_with_no_eth_turns_an_offer_down() public {
        EscrowContract escrow = escrowFor(seller, 2);
        OfferVault vault = openOffer(escrow);

        deliver(
            vault,
            seller,
            abi.encodeCall(OfferVault.reject, ()),
            1,
            signFor(SELLER_KEY, vault, message(REJECT_OFFER, 1, deadlineSoon()))
        );

        assertEq(uint256(vault.status()), uint256(OfferVault.Status.CANCELLED));
        vault.withdraw();
        assertEq(token.balanceOf(lp), OFFER);
    }

    function test_calling_directly_still_works() public {
        EscrowContract escrow = escrowFor(seller, 3);
        OfferVault vault = openOffer(escrow);
        vm.prank(seller);
        vault.reject();
        assertEq(uint256(vault.status()), uint256(OfferVault.Status.CANCELLED));
    }

    function test_a_contract_wallet_seller_can_sign_for_itself() public {
        VaultSignedCallsWallet wallet = new VaultSignedCallsWallet(seller);
        EscrowContract escrow = escrowFor(address(wallet), 4);
        OfferVault vault = openOffer(escrow);

        bytes32 digest = keccak256(
            abi.encodePacked(
                "\x19\x01", vault.signedCallDomainSeparator(), message(REJECT_OFFER, 1, deadlineSoon())
            )
        );
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(SELLER_KEY, digest);
        deliver(vault, address(wallet), abi.encodeCall(OfferVault.reject, ()), 1, abi.encode(r, s, v));

        assertEq(uint256(vault.status()), uint256(OfferVault.Status.CANCELLED));
    }

    /// The digest the vault checks is the one a wallet computes from the typed data it is shown.
    function test_the_message_a_wallet_displays_is_the_one_the_vault_checks() public {
        EscrowContract escrow = escrowFor(seller, 5);
        OfferVault vault = openOffer(escrow);
        uint256 deadline = deadlineSoon();
        string memory typedData = string.concat(
            '{"types":{"EIP712Domain":[{"name":"name","type":"string"},{"name":"version","type":"string"},',
            '{"name":"chainId","type":"uint256"},{"name":"verifyingContract","type":"address"}],',
            '"RejectOffer":[{"name":"nonce","type":"uint256"},{"name":"deadline","type":"uint256"}]},',
            '"primaryType":"RejectOffer",',
            '"domain":{"name":"Stabledrop","version":"1","chainId":',
            vm.toString(block.chainid),
            ',"verifyingContract":"',
            vm.toString(address(vault)),
            '"},"message":{"nonce":7,"deadline":',
            vm.toString(deadline),
            "}}"
        );
        (uint8 v, bytes32 r, bytes32 s) =
            vm.sign(SELLER_KEY, VaultTypedDataHasher(address(vm)).eip712HashTypedData(typedData));

        vm.prank(relayer);
        vault.executeSigned(seller, abi.encodeCall(OfferVault.reject, ()), 7, deadline, abi.encodePacked(r, s, v));
        assertEq(uint256(vault.status()), uint256(OfferVault.Status.CANCELLED));
    }

    // ---- and only for the signer, only for what was signed, only once ----

    function test_a_signature_to_reject_does_not_accept() public {
        EscrowContract escrow = escrowFor(seller, 6);
        OfferVault vault = openOffer(escrow);
        signedApproval(escrow, vault, 1);
        bytes memory rejection = signFor(SELLER_KEY, vault, message(REJECT_OFFER, 1, deadlineSoon()));

        vm.expectRevert(abi.encodeWithSelector(OfferVault.SignedCallNotSignedBy.selector, seller));
        deliver(vault, seller, abi.encodeCall(OfferVault.accept, ()), 1, rejection);
    }

    function test_a_strangers_signature_does_not_speak_for_the_seller() public {
        EscrowContract escrow = escrowFor(seller, 7);
        OfferVault vault = openOffer(escrow);
        bytes memory signature = signFor(STRANGER_KEY, vault, message(REJECT_OFFER, 1, deadlineSoon()));

        vm.expectRevert(abi.encodeWithSelector(OfferVault.SignedCallNotSignedBy.selector, seller));
        deliver(vault, seller, abi.encodeCall(OfferVault.reject, ()), 1, signature);
    }

    function test_a_stranger_signing_as_themselves_is_still_not_the_seller() public {
        EscrowContract escrow = escrowFor(seller, 8);
        OfferVault vault = openOffer(escrow);
        bytes memory signature = signFor(STRANGER_KEY, vault, message(REJECT_OFFER, 1, deadlineSoon()));

        vm.expectRevert(abi.encodeWithSelector(OfferVault.NotEscrowRecipient.selector, stranger));
        deliver(vault, stranger, abi.encodeCall(OfferVault.reject, ()), 1, signature);
    }

    function test_a_signature_is_spent_by_its_first_delivery() public {
        EscrowContract escrow = escrowFor(seller, 9);
        OfferVault vault = openOffer(escrow);
        bytes memory signature = signFor(SELLER_KEY, vault, message(REJECT_OFFER, 1, deadlineSoon()));

        deliver(vault, seller, abi.encodeCall(OfferVault.reject, ()), 1, signature);
        vm.expectRevert(OfferVault.SignedCallAlreadyUsed.selector);
        deliver(vault, seller, abi.encodeCall(OfferVault.reject, ()), 1, signature);
    }

    function test_a_signature_is_no_good_after_its_deadline() public {
        EscrowContract escrow = escrowFor(seller, 10);
        OfferVault vault = openOffer(escrow);
        uint256 deadline = deadlineSoon();
        bytes memory signature = signFor(SELLER_KEY, vault, message(REJECT_OFFER, 1, deadline));

        vm.warp(deadline + 1);
        vm.prank(relayer);
        vm.expectRevert(OfferVault.SignedCallExpired.selector);
        vault.executeSigned(seller, abi.encodeCall(OfferVault.reject, ()), 1, deadline, signature);
    }

    /// Two offers on the same escrow: a yes to one is not a yes to the other.
    function test_a_signature_for_one_vault_is_no_good_on_another() public {
        EscrowContract escrow = escrowFor(seller, 11);
        OfferVault one = openOffer(escrow);
        OfferVault other = openOffer(escrow);
        bytes memory signature = signFor(SELLER_KEY, one, message(REJECT_OFFER, 1, deadlineSoon()));

        vm.expectRevert(abi.encodeWithSelector(OfferVault.SignedCallNotSignedBy.selector, seller));
        deliver(other, seller, abi.encodeCall(OfferVault.reject, ()), 1, signature);
    }

    function test_only_the_sellers_actions_can_be_signed_for() public {
        EscrowContract escrow = escrowFor(seller, 12);
        OfferVault vault = openOffer(escrow);
        bytes[5] memory calls = [
            abi.encodeCall(OfferVault.fund, ()),
            abi.encodeCall(OfferVault.withdraw, ()),
            abi.encodeCall(OfferVault.releaseHoldback, ()),
            abi.encodeCall(OfferVault.sweep, (address(token))),
            abi.encodeCall(OfferVault.executeSigned, (seller, "", 0, 0, ""))
        ];
        for (uint256 i = 0; i < calls.length; i++) {
            vm.expectRevert(abi.encodeWithSelector(OfferVault.SignedCallNotAllowed.selector, bytes4(calls[i])));
            deliver(vault, seller, calls[i], 100 + i, "");
        }
    }

    function test_a_call_with_anything_after_the_selector_is_refused() public {
        EscrowContract escrow = escrowFor(seller, 13);
        OfferVault vault = openOffer(escrow);
        bytes[2] memory malformed =
            [abi.encodePacked(OfferVault.reject.selector, uint256(1)), bytes(hex"1234")];
        for (uint256 i = 0; i < malformed.length; i++) {
            vm.expectRevert(OfferVault.SignedCallMalformed.selector);
            deliver(vault, seller, malformed[i], 50 + i, "");
        }
    }

    function test_appending_the_sellers_address_to_a_direct_call_fools_nothing() public {
        EscrowContract escrow = escrowFor(seller, 14);
        OfferVault vault = openOffer(escrow);
        bytes memory forged = abi.encodePacked(abi.encodeCall(OfferVault.reject, ()), seller);

        vm.prank(stranger);
        (bool ok, bytes memory answer) = address(vault).call(forged);
        assertFalse(ok);
        assertEq(bytes4(answer), OfferVault.NotEscrowRecipient.selector);
    }

    function test_the_implementation_delivers_nothing() public {
        OfferVault implementation = OfferVault(market.VAULT_IMPLEMENTATION());
        vm.expectRevert(OfferVault.NotInitialized.selector);
        implementation.executeSigned(seller, abi.encodeCall(OfferVault.reject, ()), 1, deadlineSoon(), "");
    }

    // ---- and a seller who changes their mind can withdraw a signature ----

    /// Both halves of a gasless sale are signed and held; the seller cancels the accept by
    /// signing too. Delivering the held pair afterwards sells nothing.
    function test_a_seller_can_back_out_of_a_signed_sale_before_delivery() public {
        EscrowContract escrow = escrowFor(seller, 15);
        OfferVault vault = openOffer(escrow);
        bytes memory acceptance = signFor(SELLER_KEY, vault, message(ACCEPT_OFFER, 1, deadlineSoon()));

        bytes memory cancel = signFor(SELLER_KEY, vault, keccak256(abi.encode(CANCEL, 1, 2, deadlineSoon())));
        deliver(vault, seller, abi.encodeCall(OfferVault.cancelSignedCall, (1)), 2, cancel);

        signedApproval(escrow, vault, 1);
        vm.expectRevert(OfferVault.SignedCallAlreadyUsed.selector);
        deliver(vault, seller, abi.encodeCall(OfferVault.accept, ()), 1, acceptance);
        assertEq(escrow.recipient(), seller);
        assertEq(uint256(vault.status()), uint256(OfferVault.Status.OPEN));
    }

    function test_cancelling_directly_spends_only_the_cancellers_own_nonce() public {
        EscrowContract escrow = escrowFor(seller, 16);
        OfferVault vault = openOffer(escrow);
        vm.prank(stranger);
        vault.cancelSignedCall(1);

        assertTrue(vault.signedCallUsed(stranger, 1));
        assertFalse(vault.signedCallUsed(seller, 1));
    }
}
