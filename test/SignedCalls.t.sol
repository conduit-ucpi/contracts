// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {EscrowContract} from "../src/EscrowContract.sol";
import {EscrowContractFactory} from "../src/EscrowContractFactory.sol";

contract SignedCallsToken is ERC20 {
    constructor() ERC20("Test USD", "TUSD") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

/// Foundry's own EIP-712 hashing of a typed-data JSON document. Declared here because the
/// forge-std this repo pins predates the cheatcode; the forge binary has it.
interface TypedDataHasher {
    function eip712HashTypedData(string calldata jsonData) external pure returns (bytes32);
}

/// A contract wallet that vouches for whatever its owner key signed (ERC-1271).
contract SignedCallsWallet {
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
 * A party who holds no ETH signs what they want done; a relayer delivers it and pays.
 * The contract acts for the signer, for exactly what was signed, once.
 */
contract SignedCallsTest is Test {
    EscrowContractFactory factory;
    SignedCallsToken token;

    uint256 constant BUYER_KEY = 0xB0B;
    uint256 constant SELLER_KEY = 0x5E11;
    uint256 constant STRANGER_KEY = 0xBAD;
    address buyer = vm.addr(BUYER_KEY);
    address seller = vm.addr(SELLER_KEY);
    address stranger = vm.addr(STRANGER_KEY);
    address arbiter = address(0xA4B);
    address relayer = address(0x4E1A);

    uint256 constant AMOUNT = 1000e6;
    bytes32 constant RAISE_DISPUTE = keccak256("RaiseDispute(uint256 nonce,uint256 deadline)");
    bytes32 constant VOTE = keccak256("Vote(uint256 refundToBuyerPercent,uint256 nonce,uint256 deadline)");
    bytes32 constant NOMINATE = keccak256("NominateArbiter(address candidate,uint256 nonce,uint256 deadline)");
    bytes32 constant CANCEL = keccak256("CancelSignedCall(uint256 cancelledNonce,uint256 nonce,uint256 deadline)");
    bytes32 constant APPROVE_TRANSFER =
        keccak256("ApproveRecipientTransfer(address operator,address newRecipient,uint256 nonce,uint256 deadline)");

    function setUp() public {
        token = new SignedCallsToken();
        EscrowContract implementation = new EscrowContract(address(0xDEFA17), bytes20(0));
        factory = new EscrowContractFactory(arbiter, address(implementation), address(0), bytes20(0));
    }

    function funded(address asBuyer, uint256 salt) internal returns (EscrowContract escrow) {
        vm.prank(arbiter);
        escrow = EscrowContract(
            factory.createEscrowContract(
                address(token), asBuyer, seller, AMOUNT, block.timestamp + 7 days, "x", arbiter, bytes32(salt)
            )
        );
        token.mint(address(escrow), AMOUNT);
        escrow.checkAndActivate();
    }

    // The struct hashes are built here the way a wallet builds them: field by field, by name.
    // Not the way the contract does (type hash + the call's argument bytes), so that a pass
    // here means the contract's shortcut really is EIP-712.
    function raiseDisputeMessage(uint256 nonce, uint256 deadline) internal pure returns (bytes32) {
        return keccak256(abi.encode(RAISE_DISPUTE, nonce, deadline));
    }

    function voteMessage(uint256 percent, uint256 nonce, uint256 deadline) internal pure returns (bytes32) {
        return keccak256(abi.encode(VOTE, percent, nonce, deadline));
    }

    function digestOf(EscrowContract escrow, bytes32 message) internal view returns (bytes32) {
        return keccak256(abi.encodePacked("\x19\x01", escrow.signedCallDomainSeparator(), message));
    }

    function sign(uint256 key, EscrowContract escrow, bytes32 message) internal view returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(key, digestOf(escrow, message));
        return abi.encodePacked(r, s, v);
    }

    function deadlineSoon() internal view returns (uint256) {
        return block.timestamp + 1 hours;
    }

    function signedDispute(EscrowContract escrow, uint256 key, address signer, uint256 nonce) internal {
        uint256 deadline = deadlineSoon();
        bytes memory signature = sign(key, escrow, raiseDisputeMessage(nonce, deadline));
        vm.prank(relayer);
        escrow.executeSigned(signer, abi.encodeCall(EscrowContract.raiseDispute, ()), nonce, deadline, signature);
    }

    function signedVote(EscrowContract escrow, uint256 key, address signer, uint256 percent, uint256 nonce) internal {
        uint256 deadline = deadlineSoon();
        bytes memory signature = sign(key, escrow, voteMessage(percent, nonce, deadline));
        vm.prank(relayer);
        escrow.executeSigned(
            signer, abi.encodeCall(EscrowContract.submitResolutionVote, (percent)), nonce, deadline, signature
        );
    }

    function disputed(uint256 salt) internal returns (EscrowContract escrow) {
        escrow = funded(buyer, salt);
        signedDispute(escrow, BUYER_KEY, buyer, 1);
    }

    // ---- it works, and for the signer ----

    function test_a_buyer_with_no_eth_raises_a_dispute_through_a_relayer() public {
        assertEq(buyer.balance, 0);
        EscrowContract escrow = disputed(1);
        assertTrue(escrow.isDisputed());
    }

    function test_a_signed_vote_is_the_signers_not_the_relayers() public {
        EscrowContract escrow = disputed(2);
        signedVote(escrow, SELLER_KEY, seller, 40, 7);

        assertEq(escrow.resolutionVotes(seller), 40);
        assertEq(escrow.resolutionVotes(relayer), 0);
    }

    function test_two_signed_votes_that_agree_settle_the_dispute() public {
        EscrowContract escrow = disputed(3);
        signedVote(escrow, BUYER_KEY, buyer, 30, 2);
        signedVote(escrow, SELLER_KEY, seller, 30, 2);

        assertTrue(escrow.consensusReached());
        assertGt(token.balanceOf(buyer), 0);
        assertGt(token.balanceOf(seller), 0);
    }

    function test_calling_directly_still_works() public {
        EscrowContract escrow = funded(buyer, 4);
        vm.prank(buyer);
        escrow.raiseDispute();
        assertTrue(escrow.isDisputed());
    }

    function test_a_contract_wallet_can_sign_for_itself() public {
        SignedCallsWallet wallet = new SignedCallsWallet(buyer);
        EscrowContract escrow = funded(address(wallet), 5);

        uint256 deadline = deadlineSoon();
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(BUYER_KEY, digestOf(escrow, raiseDisputeMessage(1, deadline)));

        vm.prank(relayer);
        escrow.executeSigned(
            address(wallet), abi.encodeCall(EscrowContract.raiseDispute, ()), 1, deadline, abi.encode(r, s, v)
        );
        assertTrue(escrow.isDisputed());
    }

    function test_actions_that_name_addresses_can_be_signed_for() public {
        EscrowContract escrow = funded(buyer, 15);
        address candidate = address(0xCA4D);
        address operator = address(0x0AE4);
        address newRecipient = address(0x4EC1);
        uint256 deadline = deadlineSoon();

        bytes memory nomination = sign(BUYER_KEY, escrow, keccak256(abi.encode(NOMINATE, candidate, 1, deadline)));
        vm.prank(relayer);
        escrow.executeSigned(
            buyer, abi.encodeCall(EscrowContract.nominateArbiter, (candidate)), 1, deadline, nomination
        );
        assertEq(escrow.nominatedByBuyer(), candidate);

        bytes memory approval =
            sign(SELLER_KEY, escrow, keccak256(abi.encode(APPROVE_TRANSFER, operator, newRecipient, 1, deadline)));
        vm.prank(relayer);
        escrow.executeSigned(
            seller,
            abi.encodeCall(EscrowContract.approveRecipientTransfer, (operator, newRecipient)),
            1,
            deadline,
            approval
        );
        assertEq(escrow.recipientOperator(), operator);
    }

    /// The digest the contract checks is the one a wallet computes from the typed data it is
    /// shown. Foundry hashes this JSON with its own EIP-712 implementation, not ours.
    function test_the_message_a_wallet_displays_is_the_one_the_contract_checks() public {
        EscrowContract escrow = disputed(16);
        uint256 deadline = deadlineSoon();
        string memory typedData = string.concat(
            '{"types":{"EIP712Domain":[{"name":"name","type":"string"},{"name":"version","type":"string"},',
            '{"name":"chainId","type":"uint256"},{"name":"verifyingContract","type":"address"}],',
            '"Vote":[{"name":"refundToBuyerPercent","type":"uint256"},{"name":"nonce","type":"uint256"},',
            '{"name":"deadline","type":"uint256"}]},"primaryType":"Vote",',
            '"domain":{"name":"Stabledrop","version":"1","chainId":',
            vm.toString(block.chainid),
            ',"verifyingContract":"',
            vm.toString(address(escrow)),
            '"},"message":{"refundToBuyerPercent":30,"nonce":2,"deadline":',
            vm.toString(deadline),
            "}}"
        );
        (uint8 v, bytes32 r, bytes32 s) =
            vm.sign(BUYER_KEY, TypedDataHasher(address(vm)).eip712HashTypedData(typedData));

        vm.prank(relayer);
        escrow.executeSigned(
            buyer, abi.encodeCall(EscrowContract.submitResolutionVote, (30)), 2, deadline, abi.encodePacked(r, s, v)
        );
        assertEq(escrow.resolutionVotes(buyer), 30);
    }

    // ---- and only for the signer, only for what was signed, only once ----

    function test_the_relayer_cannot_change_what_was_signed() public {
        EscrowContract escrow = disputed(6);
        uint256 deadline = deadlineSoon();
        bytes memory signature = sign(BUYER_KEY, escrow, voteMessage(30, 2, deadline));

        vm.prank(relayer);
        vm.expectRevert(abi.encodeWithSelector(EscrowContract.SignedCallNotSignedBy.selector, buyer));
        escrow.executeSigned(buyer, abi.encodeCall(EscrowContract.submitResolutionVote, (100)), 2, deadline, signature);
    }

    function test_a_signature_for_one_action_does_not_authorise_another() public {
        EscrowContract escrow = disputed(17);
        uint256 deadline = deadlineSoon();
        // Signed: resign as arbiter. Delivered as: evict the arbiter. Same fields, different name.
        bytes memory signature = sign(
            BUYER_KEY,
            escrow,
            keccak256(abi.encode(keccak256("ResignArbiter(uint256 nonce,uint256 deadline)"), 2, deadline))
        );

        vm.prank(relayer);
        vm.expectRevert(abi.encodeWithSelector(EscrowContract.SignedCallNotSignedBy.selector, buyer));
        escrow.executeSigned(buyer, abi.encodeCall(EscrowContract.evictArbiter, ()), 2, deadline, signature);
    }

    function test_a_strangers_signature_does_not_speak_for_the_buyer() public {
        EscrowContract escrow = funded(buyer, 7);
        uint256 deadline = deadlineSoon();
        bytes memory signature = sign(STRANGER_KEY, escrow, raiseDisputeMessage(1, deadline));

        vm.prank(relayer);
        vm.expectRevert(abi.encodeWithSelector(EscrowContract.SignedCallNotSignedBy.selector, buyer));
        escrow.executeSigned(buyer, abi.encodeCall(EscrowContract.raiseDispute, ()), 1, deadline, signature);
    }

    function test_a_stranger_signing_as_themselves_is_still_not_the_buyer() public {
        EscrowContract escrow = funded(buyer, 8);
        uint256 deadline = deadlineSoon();
        bytes memory signature = sign(STRANGER_KEY, escrow, raiseDisputeMessage(1, deadline));

        vm.prank(relayer);
        vm.expectRevert(EscrowContract.OnlyBuyer.selector);
        escrow.executeSigned(stranger, abi.encodeCall(EscrowContract.raiseDispute, ()), 1, deadline, signature);
    }

    function test_a_signature_is_spent_by_its_first_delivery() public {
        EscrowContract escrow = disputed(9);
        bytes memory call = abi.encodeCall(EscrowContract.submitResolutionVote, (30));
        uint256 deadline = deadlineSoon();
        bytes memory signature = sign(BUYER_KEY, escrow, voteMessage(30, 2, deadline));

        vm.prank(relayer);
        escrow.executeSigned(buyer, call, 2, deadline, signature);
        vm.prank(relayer);
        vm.expectRevert(EscrowContract.SignedCallAlreadyUsed.selector);
        escrow.executeSigned(buyer, call, 2, deadline, signature);
    }

    function test_a_signature_is_no_good_after_its_deadline() public {
        EscrowContract escrow = funded(buyer, 10);
        uint256 deadline = deadlineSoon();
        bytes memory signature = sign(BUYER_KEY, escrow, raiseDisputeMessage(1, deadline));

        vm.warp(deadline + 1);
        vm.prank(relayer);
        vm.expectRevert(EscrowContract.SignedCallExpired.selector);
        escrow.executeSigned(buyer, abi.encodeCall(EscrowContract.raiseDispute, ()), 1, deadline, signature);
    }

    function test_a_signature_for_one_contract_is_no_good_on_another() public {
        EscrowContract one = funded(buyer, 11);
        EscrowContract other = funded(buyer, 12);
        uint256 deadline = deadlineSoon();
        bytes memory signature = sign(BUYER_KEY, one, raiseDisputeMessage(1, deadline));

        vm.prank(relayer);
        vm.expectRevert(abi.encodeWithSelector(EscrowContract.SignedCallNotSignedBy.selector, buyer));
        other.executeSigned(buyer, abi.encodeCall(EscrowContract.raiseDispute, ()), 1, deadline, signature);
    }

    function test_only_party_actions_can_be_signed_for() public {
        EscrowContract escrow = funded(buyer, 13);
        bytes[4] memory calls = [
            abi.encodeCall(EscrowContract.sweepToken, (address(token))),
            abi.encodeCall(EscrowContract.claimFunds, ()),
            abi.encodeCall(EscrowContract.checkAndActivate, ()),
            abi.encodeCall(EscrowContract.executeSigned, (buyer, "", 0, 0, ""))
        ];
        for (uint256 i = 0; i < calls.length; i++) {
            vm.prank(relayer);
            vm.expectRevert(abi.encodeWithSelector(EscrowContract.SignedCallNotAllowed.selector, bytes4(calls[i])));
            escrow.executeSigned(buyer, calls[i], 100 + i, deadlineSoon(), "");
        }
    }

    function test_a_call_with_the_wrong_number_of_arguments_is_refused() public {
        EscrowContract escrow = disputed(18);
        uint256 deadline = deadlineSoon();
        bytes memory vote = abi.encodeCall(EscrowContract.submitResolutionVote, (30));
        bytes[3] memory malformed = [
            abi.encodePacked(vote, uint256(1)), // something after the argument
            abi.encodePacked(EscrowContract.submitResolutionVote.selector), // the argument missing
            hex"1234" // not even a selector
        ];
        for (uint256 i = 0; i < malformed.length; i++) {
            vm.prank(relayer);
            vm.expectRevert(EscrowContract.SignedCallMalformed.selector);
            escrow.executeSigned(buyer, malformed[i], 50 + i, deadline, "");
        }
    }

    function test_appending_someone_elses_address_to_a_direct_call_fools_nothing() public {
        EscrowContract escrow = funded(buyer, 14);
        bytes memory forged = abi.encodePacked(abi.encodeCall(EscrowContract.raiseDispute, ()), buyer);

        vm.prank(stranger);
        (bool ok, bytes memory answer) = address(escrow).call(forged);
        assertFalse(ok);
        assertEq(bytes4(answer), EscrowContract.OnlyBuyer.selector);
    }

    // ---- and a signature not yet delivered can be withdrawn ----

    /// The stale-vote case: a signed vote for 100 is held back, the buyer votes 30 directly,
    /// then cancels. The old signature can no longer flip the vote back.
    function test_a_cancelled_signature_cannot_override_a_later_direct_vote() public {
        EscrowContract escrow = disputed(19);
        uint256 deadline = deadlineSoon();
        bytes memory stale = sign(BUYER_KEY, escrow, voteMessage(100, 5, deadline));

        vm.prank(buyer);
        escrow.submitResolutionVote(30);
        vm.prank(buyer);
        escrow.cancelSignedCall(5);

        vm.prank(relayer);
        vm.expectRevert(EscrowContract.SignedCallAlreadyUsed.selector);
        escrow.executeSigned(buyer, abi.encodeCall(EscrowContract.submitResolutionVote, (100)), 5, deadline, stale);
        assertEq(escrow.resolutionVotes(buyer), 30);
    }

    function test_a_party_with_no_eth_can_cancel_by_signing() public {
        EscrowContract escrow = funded(buyer, 20);
        uint256 deadline = deadlineSoon();
        bytes memory dispute = sign(BUYER_KEY, escrow, raiseDisputeMessage(1, deadline));
        bytes memory cancel = sign(BUYER_KEY, escrow, keccak256(abi.encode(CANCEL, 1, 2, deadline)));

        vm.prank(relayer);
        escrow.executeSigned(buyer, abi.encodeCall(EscrowContract.cancelSignedCall, (1)), 2, deadline, cancel);
        assertTrue(escrow.signedCallUsed(buyer, 1));

        vm.prank(relayer);
        vm.expectRevert(EscrowContract.SignedCallAlreadyUsed.selector);
        escrow.executeSigned(buyer, abi.encodeCall(EscrowContract.raiseDispute, ()), 1, deadline, dispute);
    }

    function test_cancelling_spends_only_the_cancellers_own_nonce() public {
        EscrowContract escrow = funded(buyer, 21);
        vm.prank(stranger);
        escrow.cancelSignedCall(1);

        assertTrue(escrow.signedCallUsed(stranger, 1));
        assertFalse(escrow.signedCallUsed(buyer, 1));
        signedDispute(escrow, BUYER_KEY, buyer, 1);
        assertTrue(escrow.isDisputed());
    }

    function test_cancelling_a_signature_that_already_ran_says_so() public {
        EscrowContract escrow = funded(buyer, 22);
        signedDispute(escrow, BUYER_KEY, buyer, 1);

        vm.prank(buyer);
        vm.expectRevert(EscrowContract.SignedCallAlreadyUsed.selector);
        escrow.cancelSignedCall(1);
    }
}
