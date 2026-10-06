// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {SeatStream} from "../src/SeatStream.sol";

contract Rejector {
    bool public accept;

    function setAccept(bool a) external {
        accept = a;
    }

    function openOn(SeatStream s, uint256 tokenId, uint256 deadline, bytes calldata sig) external payable {
        s.open{value: msg.value}(tokenId, deadline, sig);
    }

    function collect(SeatStream s) external {
        s.collectRefund();
    }

    function collectTo(SeatStream s, address to) external {
        s.collectRefundTo(to);
    }

    receive() external payable {
        require(accept, "no");
    }
}

/// Rejects ETH with a large revert payload (returndata bomb).
contract Bomber {
    function openOn(SeatStream s, uint256 tokenId, uint256 deadline, bytes calldata sig) external payable {
        s.open{value: msg.value}(tokenId, deadline, sig);
    }

    function withdrawTo(SeatStream s, uint256 tokenId, address to) external {
        s.withdrawTo(tokenId, to);
    }

    receive() external payable {
        assembly {
            revert(0, 100000)
        }
    }
}

contract SeatStreamTest is Test {
    uint256 constant PRICE = 0.05 ether;
    uint256 constant PERIOD = 30 days;

    SeatStream s;
    address payee = makeAddr("payee");
    uint256 keeperPk = 0xA11CE;
    address keeper;
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");

    function setUp() public {
        keeper = vm.addr(keeperPk);
        s = new SeatStream(PRICE, payee, keeper);
        vm.deal(alice, 10 ether);
        vm.deal(bob, 10 ether);
        vm.warp(1_700_000_000);
    }

    function sig(uint256 tokenId, address depositor, uint256 deadline) internal view returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 ss) =
            vm.sign(keeperPk, s.openDigest(tokenId, depositor, s.openNonce(tokenId), deadline));
        return abi.encodePacked(r, ss, v);
    }

    function openFor(address who, uint256 tokenId, uint256 amount) internal {
        uint256 deadline = block.timestamp + 1 days;
        bytes memory sg = sig(tokenId, who, deadline);
        vm.prank(who);
        s.open{value: amount}(tokenId, deadline, sg);
    }

    // --- constructor ---
    function test_constructor_rejects_bad_values() public {
        vm.expectRevert(SeatStream.PriceTooLow.selector);
        new SeatStream(0, payee, keeper);
        vm.expectRevert(SeatStream.PriceTooLow.selector);
        new SeatStream(PERIOD - 1, payee, keeper);
        new SeatStream(PERIOD, payee, keeper); // smallest price that streams at least 1 wei/s
        vm.expectRevert(SeatStream.ZeroAddress.selector);
        new SeatStream(PRICE, address(0), keeper);
        vm.expectRevert(SeatStream.ZeroAddress.selector);
        new SeatStream(PRICE, payee, address(0));
    }

    // --- open ---
    function test_open_sets_position() public {
        openFor(alice, 7, PRICE);
        (address depositor, uint256 balance, bool paused, uint256 until) = s.positionOf(7);
        assertEq(depositor, alice);
        assertEq(balance, PRICE);
        assertFalse(paused);
        assertEq(until, block.timestamp + PERIOD);
    }

    function test_open_requires_one_period() public {
        uint256 deadline = block.timestamp + 1 days;
        bytes memory sg = sig(7, alice, deadline);
        vm.prank(alice);
        vm.expectRevert(SeatStream.BelowMinimum.selector);
        s.open{value: PRICE - 1}(7, deadline, sg);
    }

    function test_open_rejects_expired_signature() public {
        uint256 deadline = block.timestamp + 1 days;
        bytes memory sg = sig(7, alice, deadline);
        vm.warp(deadline + 1);
        vm.prank(alice);
        vm.expectRevert(SeatStream.Expired.selector);
        s.open{value: PRICE}(7, deadline, sg);
    }

    function test_open_rejects_other_signer_and_other_depositor() public {
        uint256 deadline = block.timestamp + 1 days;
        (uint8 v, bytes32 r, bytes32 ss) = vm.sign(0xB0B, s.openDigest(7, alice, 0, deadline));
        vm.prank(alice);
        vm.expectRevert(SeatStream.BadSignature.selector);
        s.open{value: PRICE}(7, deadline, abi.encodePacked(r, ss, v));

        bytes memory forAlice = sig(7, alice, deadline);
        vm.prank(bob);
        vm.expectRevert(SeatStream.BadSignature.selector);
        s.open{value: PRICE}(7, deadline, forAlice);
    }

    function test_open_signature_is_bound_to_token() public {
        uint256 deadline = block.timestamp + 1 days;
        bytes memory forSeven = sig(7, alice, deadline);
        vm.prank(alice);
        vm.expectRevert(SeatStream.BadSignature.selector);
        s.open{value: PRICE}(8, deadline, forSeven);
    }

    function test_open_rejects_second_position() public {
        openFor(alice, 7, PRICE);
        uint256 deadline = block.timestamp + 1 days;
        bytes memory sg = sig(7, bob, deadline);
        vm.prank(bob);
        vm.expectRevert(SeatStream.PositionOpen.selector);
        s.open{value: PRICE}(7, deadline, sg);
    }

    // --- streaming ---
    function test_streams_linearly() public {
        openFor(alice, 7, PRICE);
        vm.warp(block.timestamp + 15 days);
        (, uint256 balance,, uint256 until) = s.positionOf(7);
        assertEq(balance, PRICE / 2);
        assertEq(until, block.timestamp + 15 days);
        uint256[] memory ids = new uint256[](1);
        ids[0] = 7;
        assertEq(s.pendingClaim(ids), PRICE / 2);
    }

    function test_exhausted_stream_stops_without_debt() public {
        openFor(alice, 7, PRICE);
        vm.warp(block.timestamp + 40 days);
        (address depositor, uint256 balance,, uint256 until) = s.positionOf(7);
        assertEq(depositor, alice);
        assertEq(balance, 0);
        assertEq(until, block.timestamp);
        uint256[] memory ids = new uint256[](1);
        ids[0] = 7;
        assertEq(s.pendingClaim(ids), PRICE);
    }

    function test_top_up_after_exhaustion_restarts_from_now() public {
        openFor(alice, 7, PRICE);
        vm.warp(block.timestamp + 40 days);
        vm.prank(alice);
        s.deposit{value: PRICE}(7);
        vm.warp(block.timestamp + 15 days);
        (, uint256 balance,,) = s.positionOf(7);
        assertEq(balance, PRICE / 2);
    }

    function test_top_up_has_no_minimum() public {
        openFor(alice, 7, PRICE);
        vm.prank(alice);
        s.deposit{value: 1 wei}(7);
        (, uint256 balance,,) = s.positionOf(7);
        assertEq(balance, PRICE + 1);
    }

    function test_deposit_rules() public {
        vm.prank(alice);
        vm.expectRevert(SeatStream.NoPosition.selector);
        s.deposit{value: 1}(7);
        openFor(alice, 7, PRICE);
        vm.prank(bob);
        vm.expectRevert(SeatStream.NotDepositor.selector);
        s.deposit{value: 1}(7);
        vm.prank(alice);
        vm.expectRevert(SeatStream.ZeroAmount.selector);
        s.deposit{value: 0}(7);
    }

    // --- withdraw ---
    function test_withdraw_returns_unstreamed_and_closes() public {
        openFor(alice, 7, 2 * PRICE);
        vm.warp(block.timestamp + 15 days);
        uint256 before = alice.balance;
        vm.prank(alice);
        s.withdraw(7);
        assertEq(alice.balance - before, 2 * PRICE - PRICE / 2);
        (address depositor,,, uint256 until) = s.positionOf(7);
        assertEq(depositor, address(0));
        assertEq(until, 0);
        assertEq(s.claimable(), PRICE / 2);
    }

    function test_withdraw_only_depositor() public {
        openFor(alice, 7, PRICE);
        vm.prank(bob);
        vm.expectRevert(SeatStream.NotDepositor.selector);
        s.withdraw(7);
    }

    function test_reopen_after_withdraw_needs_a_signature() public {
        openFor(alice, 7, PRICE);
        vm.prank(alice);
        s.withdraw(7);
        openFor(bob, 7, PRICE);
        (address depositor,,,) = s.positionOf(7);
        assertEq(depositor, bob);
    }

    // --- release ---
    function test_release_by_payee_or_keeper_refunds_depositor() public {
        openFor(alice, 7, PRICE);
        vm.warp(block.timestamp + 10 days);
        uint256 before = alice.balance;
        vm.prank(payee);
        s.release(7);
        assertEq(alice.balance - before, PRICE - (10 days * PRICE) / PERIOD);

        openFor(bob, 8, PRICE);
        vm.prank(keeper);
        s.release(8);
        (address depositor,,,) = s.positionOf(8);
        assertEq(depositor, address(0));
    }

    function test_release_by_stranger_reverts() public {
        openFor(alice, 7, PRICE);
        vm.prank(bob);
        vm.expectRevert(SeatStream.NotOperator.selector);
        s.release(7);
    }

    function test_release_to_rejecting_depositor_credits_refund() public {
        Rejector rj = new Rejector();
        vm.deal(address(rj), 1 ether);
        uint256 deadline = block.timestamp + 1 days;
        bytes memory sg = sig(9, address(rj), deadline);
        rj.openOn{value: PRICE}(s, 9, deadline, sg);
        vm.prank(payee);
        s.release(9);
        assertEq(s.refunds(address(rj)), PRICE);
        rj.setAccept(true);
        rj.collect(s);
        assertEq(s.refunds(address(rj)), 0);
        assertEq(address(rj).balance, 1 ether + PRICE);
    }

    // --- pause / resume ---
    function test_pause_stops_streaming_and_extends_paid_until() public {
        openFor(alice, 7, PRICE);
        vm.warp(block.timestamp + 10 days);
        vm.prank(keeper);
        s.pause(7);
        (, uint256 atPause,,) = s.positionOf(7);
        vm.warp(block.timestamp + 10 days);
        (, uint256 later, bool paused, uint256 until) = s.positionOf(7);
        assertTrue(paused);
        assertEq(later, atPause);
        assertEq(until, block.timestamp + 20 days);
        vm.prank(keeper);
        s.resume(7);
        vm.warp(block.timestamp + 10 days);
        (, uint256 afterResume,,) = s.positionOf(7);
        assertEq(afterResume, atPause - (10 days * PRICE) / PERIOD);
    }

    function test_pause_rules() public {
        vm.prank(keeper);
        vm.expectRevert(SeatStream.NoPosition.selector);
        s.pause(7);
        openFor(alice, 7, PRICE);
        vm.prank(payee);
        vm.expectRevert(SeatStream.NotKeeper.selector);
        s.pause(7);
        vm.prank(keeper);
        s.pause(7);
        vm.prank(keeper);
        vm.expectRevert(SeatStream.AlreadyPaused.selector);
        s.pause(7);
        vm.prank(keeper);
        s.resume(7);
        vm.prank(keeper);
        vm.expectRevert(SeatStream.NotPaused.selector);
        s.resume(7);
    }

    function test_depositor_can_withdraw_while_paused() public {
        openFor(alice, 7, PRICE);
        vm.prank(keeper);
        s.pause(7);
        vm.warp(block.timestamp + 60 days);
        uint256 before = alice.balance;
        vm.prank(alice);
        s.withdraw(7);
        assertEq(alice.balance - before, PRICE);
    }

    // --- claim ---
    function test_claim_pays_payee() public {
        openFor(alice, 7, PRICE);
        openFor(bob, 8, PRICE);
        vm.warp(block.timestamp + 15 days);
        uint256[] memory ids = new uint256[](2);
        ids[0] = 7;
        ids[1] = 8;
        vm.prank(bob);
        s.claim(ids);
        assertEq(payee.balance, PRICE);
        assertEq(s.claimable(), 0);
    }

    function test_claim_nothing_reverts() public {
        uint256[] memory ids = new uint256[](0);
        vm.expectRevert(SeatStream.ZeroAmount.selector);
        s.claim(ids);
    }

    // --- F1: single-use authorizations ---
    function test_open_bumps_nonce() public {
        assertEq(s.openNonce(7), 0);
        openFor(alice, 7, PRICE);
        assertEq(s.openNonce(7), 1);
    }

    function test_signature_cannot_be_replayed_after_withdraw() public {
        uint256 deadline = block.timestamp + 1 days;
        bytes memory sg = sig(7, alice, deadline);
        vm.prank(alice);
        s.open{value: PRICE}(7, deadline, sg);
        vm.prank(alice);
        s.withdraw(7);
        vm.prank(alice);
        vm.expectRevert(SeatStream.BadSignature.selector);
        s.open{value: PRICE}(7, deadline, sg);
    }

    function test_signature_cannot_be_replayed_after_release() public {
        uint256 deadline = block.timestamp + 1 days;
        bytes memory sg = sig(7, alice, deadline);
        vm.prank(alice);
        s.open{value: PRICE}(7, deadline, sg);
        vm.prank(keeper);
        s.release(7);
        vm.prank(alice);
        vm.expectRevert(SeatStream.BadSignature.selector);
        s.open{value: PRICE}(7, deadline, sg);
        // A fresh signature for the new owner works.
        openFor(bob, 7, PRICE);
        (address depositor,,,) = s.positionOf(7);
        assertEq(depositor, bob);
    }

    function test_revoke_opens_kills_an_unused_signature() public {
        uint256 deadline = block.timestamp + 1 days;
        bytes memory sg = sig(7, alice, deadline);
        vm.prank(payee);
        s.revokeOpens(7);
        assertEq(s.openNonce(7), 1);
        vm.prank(alice);
        vm.expectRevert(SeatStream.BadSignature.selector);
        s.open{value: PRICE}(7, deadline, sg);
        vm.prank(keeper);
        s.revokeOpens(7);
        assertEq(s.openNonce(7), 2);
        vm.prank(alice);
        vm.expectRevert(SeatStream.NotOperator.selector);
        s.revokeOpens(7);
    }

    // --- F2: deadline cap ---
    function test_open_deadline_cap() public {
        uint256 far = block.timestamp + 2 days + 1;
        bytes memory sgFar = sig(7, alice, far);
        vm.prank(alice);
        vm.expectRevert(SeatStream.DeadlineTooFar.selector);
        s.open{value: PRICE}(7, far, sgFar);
        uint256 edge = block.timestamp + 2 days;
        bytes memory sgEdge = sig(7, alice, edge);
        vm.prank(alice);
        s.open{value: PRICE}(7, edge, sgEdge);
    }

    // --- F2: payee freeze ---
    function test_disable_opens_blocks_open_and_deposit_but_not_exits() public {
        openFor(alice, 7, 2 * PRICE);
        openFor(bob, 8, PRICE);
        vm.prank(keeper);
        vm.expectRevert(SeatStream.NotPayee.selector);
        s.disableOpens();
        vm.prank(payee);
        s.disableOpens();
        assertTrue(s.opensDisabled());
        vm.prank(payee);
        vm.expectRevert(SeatStream.Frozen.selector);
        s.disableOpens();

        uint256 deadline = block.timestamp + 1 days;
        bytes memory sg = sig(9, alice, deadline);
        vm.prank(alice);
        vm.expectRevert(SeatStream.Frozen.selector);
        s.open{value: PRICE}(9, deadline, sg);
        vm.prank(alice);
        vm.expectRevert(SeatStream.Frozen.selector);
        s.deposit{value: 1}(7);

        vm.warp(block.timestamp + 10 days);
        vm.prank(keeper);
        s.pause(7);
        vm.prank(keeper);
        s.resume(7);
        vm.prank(alice);
        s.withdraw(7);
        vm.prank(payee);
        s.release(8);
        uint256[] memory none = new uint256[](0);
        s.claim(none);
        assertEq(address(s).balance, 0);
    }

    // --- F3: payout to another address ---
    function test_withdraw_to_sends_elsewhere() public {
        Bomber b = new Bomber();
        vm.deal(address(b), 1 ether);
        uint256 deadline = block.timestamp + 1 days;
        bytes memory sg = sig(9, address(b), deadline);
        b.openOn{value: PRICE}(s, 9, deadline, sg);
        address safe = makeAddr("safe");
        b.withdrawTo(s, 9, safe);
        assertEq(safe.balance, PRICE);
        (address depositor,,,) = s.positionOf(9);
        assertEq(depositor, address(0));
    }

    function test_withdraw_to_rules() public {
        openFor(alice, 7, PRICE);
        vm.prank(alice);
        vm.expectRevert(SeatStream.ZeroAddress.selector);
        s.withdrawTo(7, address(0));
        vm.prank(bob);
        vm.expectRevert(SeatStream.NotDepositor.selector);
        s.withdrawTo(7, bob);
    }

    function test_collect_refund_to() public {
        Rejector rj = new Rejector();
        vm.deal(address(rj), 1 ether);
        uint256 deadline = block.timestamp + 1 days;
        bytes memory sg = sig(9, address(rj), deadline);
        rj.openOn{value: PRICE}(s, 9, deadline, sg);
        vm.prank(payee);
        s.release(9);
        assertEq(s.refunds(address(rj)), PRICE);
        address safe = makeAddr("safe");
        rj.collectTo(s, safe); // rj still rejects ETH; the refund goes to `safe`
        assertEq(safe.balance, PRICE);
        assertEq(s.refunds(address(rj)), 0);
        vm.expectRevert(SeatStream.ZeroAmount.selector);
        rj.collectTo(s, safe);
    }

    // --- F8: release ignores returndata ---
    function test_release_to_returndata_bomb_credits_refund() public {
        Bomber b = new Bomber();
        vm.deal(address(b), 1 ether);
        uint256 deadline = block.timestamp + 1 days;
        bytes memory sg = sig(9, address(b), deadline);
        b.openOn{value: PRICE}(s, 9, deadline, sg);
        vm.prank(keeper);
        s.release{gas: 300_000}(9);
        assertEq(s.refunds(address(b)), PRICE);
    }
}
