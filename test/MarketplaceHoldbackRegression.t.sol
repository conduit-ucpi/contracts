// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {EscrowContract} from "../src/EscrowContract.sol";
import {EscrowContractFactory} from "../src/EscrowContractFactory.sol";
import {MarketplaceEscrow} from "../src/MarketplaceEscrow.sol";

contract Tok {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    uint8 public decimals = 6;

    function mint(address t, uint256 a) external {
        balanceOf[t] += a;
    }

    function approve(address s, uint256 a) external returns (bool) {
        allowance[msg.sender][s] = a;
        return true;
    }

    function transfer(address t, uint256 a) external returns (bool) {
        balanceOf[msg.sender] -= a;
        balanceOf[t] += a;
        return true;
    }

    function transferFrom(address f, address t, uint256 a) external returns (bool) {
        balanceOf[f] -= a;
        balanceOf[t] += a;
        allowance[f][msg.sender] -= a;
        return true;
    }
}

contract MarketplaceHoldbackRegressionTest is Test {
    EscrowContract impl;
    EscrowContractFactory factory;
    MarketplaceEscrow market;
    Tok tok;
    address DA = makeAddr("safe");
    address owner = makeAddr("owner");
    address plat = makeAddr("plat");
    address B = makeAddr("buyer");
    address S = makeAddr("seller");
    address A = makeAddr("arb");
    address LP1 = makeAddr("lp1");
    address LP2 = makeAddr("lp2");
    uint256 constant AMT = 10_000e6;
    uint256 expiry;

    function setUp() public {
        tok = new Tok();
        impl = new EscrowContract(DA);
        factory = new EscrowContractFactory(plat, address(impl), plat);
        market = new MarketplaceEscrow(address(impl), 50, 1000, 24 hours, owner);
        expiry = block.timestamp + 30 days;
    }

    function _offer(address e, address who, uint256 amt, uint256 hb) internal {
        tok.mint(who, amt);
        vm.prank(who);
        tok.approve(address(market), amt);
        vm.prank(who);
        market.createOffer(e, amt, hb, 0);
    }

    function _accept(EscrowContract e, address who) internal {
        address s = e.SELLER();
        vm.prank(s);
        e.approveRecipientTransfer(address(market), who);
        vm.prank(s);
        market.acceptOffer(address(e), who);
    }

    /// Regression: a second holdback-bearing offer must never overwrite a live reserve.
    function test_holdbackRecordCannotBeOverwritten() public {
        vm.prank(plat);
        EscrowContract e = EscrowContract(factory.createEscrowContract(address(tok), B, S, AMT, expiry, "x", A));
        tok.mint(B, AMT);
        vm.prank(B);
        tok.approve(address(e), AMT);
        vm.prank(B);
        e.depositFunds();

        // TWO competing offers, BOTH with a holdback. Both legal: hasBeenSold is false.
        _offer(address(e), LP1, 9_000e6, 500e6);
        _offer(address(e), LP2, 8_000e6, 400e6);

        // Seller accepts LP1. Reserve #1 recorded.
        _accept(e, LP1);
        (,, uint256 amt1) = market.holdbacks(address(e));
        assertEq(amt1, 500e6);
        assertEq(market.totalHoldbacks(address(tok)), 500e6);

        // The position returns to S by any route (here: a plain OTC transfer back).
        vm.prank(LP1);
        e.changeRecipient(S);
        assertEq(e.SELLER(), S);

        // LP2's offer is live again (its `seller` snapshot matches the recipient once
        // more) and still carries a holdback validated when hasBeenSold was false.
        // Accepting it MUST now be refused, or the first reserve is stranded forever.
        vm.prank(S);
        e.approveRecipientTransfer(address(market), LP2);
        vm.prank(S);
        vm.expectRevert(abi.encodeWithSelector(MarketplaceEscrow.HoldbackOnResale.selector, address(e)));
        market.acceptOffer(address(e), LP2);

        // The original reserve is intact and still the only one.
        (,, uint256 stillFirst) = market.holdbacks(address(e));
        assertEq(stillFirst, 500e6, "reserve #1 untouched");
        assertEq(market.totalHoldbacks(address(tok)), 500e6, "no phantom booking");

        // LP2 is not trapped - they exit whole.
        uint256 lp2Before = tok.balanceOf(LP2);
        vm.prank(LP2);
        market.withdrawFunds(address(e));
        assertEq(tok.balanceOf(LP2), lp2Before + 8_000e6, "LP2 refunded in full gross");
    }

    /// After the fix, the reserve settles cleanly and nothing is left stranded.
    function test_holdbackSettlesCleanlyAfterFix() public {
        vm.prank(plat);
        EscrowContract e = EscrowContract(factory.createEscrowContract(address(tok), B, S, AMT, expiry, "x", A));
        tok.mint(B, AMT);
        vm.prank(B);
        tok.approve(address(e), AMT);
        vm.prank(B);
        e.depositFunds();

        _offer(address(e), LP1, 9_000e6, 500e6);
        _accept(e, LP1);

        vm.warp(expiry + 1);
        e.claimFunds();

        uint256 sBefore = tok.balanceOf(S);
        market.releaseHoldback(address(e));

        assertEq(tok.balanceOf(S), sBefore + 500e6, "funder repaid in full");
        assertEq(market.totalHoldbacks(address(tok)), 0, "books fully drained - nothing stranded");
    }
}
