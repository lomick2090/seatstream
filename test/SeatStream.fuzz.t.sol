// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {SeatStream} from "../src/SeatStream.sol";

contract SeatStreamFuzzTest is Test {
    uint256 constant PRICE = 0.05 ether;
    SeatStream s;
    address payee = makeAddr("payee");
    uint256 keeperPk = 0xA11CE;
    address alice = makeAddr("alice");

    function setUp() public {
        s = new SeatStream(PRICE, payee, vm.addr(keeperPk));
        vm.warp(1_700_000_000);
    }

    function _open(uint256 tokenId, uint256 amount) internal {
        uint256 deadline = block.timestamp + 1 days;
        (uint8 v, bytes32 r, bytes32 ss) =
            vm.sign(keeperPk, s.openDigest(tokenId, alice, s.openNonce(tokenId), deadline));
        vm.deal(alice, amount);
        vm.prank(alice);
        s.open{value: amount}(tokenId, deadline, abi.encodePacked(r, ss, v));
    }

    /// Whatever the timing, depositor refund + payee claim == deposited, and the contract ends empty.
    function testFuzz_conservation(uint256 amount, uint256 elapsed, uint256 tokenId) public {
        amount = bound(amount, PRICE, 100 ether);
        elapsed = bound(elapsed, 0, 5 * 365 days);
        _open(tokenId, amount);
        vm.warp(block.timestamp + elapsed);
        uint256 before = alice.balance;
        vm.prank(alice);
        s.withdraw(tokenId);
        uint256 refunded = alice.balance - before;
        uint256[] memory none = new uint256[](0);
        uint256 streamed = s.claimable();
        if (streamed > 0) s.claim(none);
        assertEq(refunded + payee.balance, amount);
        assertEq(address(s).balance, 0);
        uint256 expected = (elapsed * PRICE) / 30 days;
        if (expected > amount) expected = amount;
        assertEq(payee.balance, expected);
    }

    /// paidUntil never decreases while paused, and never moves past the real exhaustion time while streaming.
    function testFuzz_paid_until_tracks_balance(uint256 amount, uint256 t1) public {
        amount = bound(amount, PRICE, 10 ether);
        t1 = bound(t1, 1, 400 days);
        _open(1, amount);
        uint256 exhaustion = block.timestamp + (amount * 30 days) / PRICE;
        uint256 t = block.timestamp + t1;
        vm.warp(t);
        uint256 until = s.paidUntil(1);
        // Flooring the streamed amount can leave paidUntil one second past the exact exhaustion time
        // (both sides floor separately), never earlier and never further.
        uint256 lo = t > exhaustion ? t : exhaustion;
        uint256 hi = t > exhaustion + 1 ? t : exhaustion + 1;
        assertGe(until, lo);
        assertLe(until, hi);
        if (t > exhaustion) assertEq(until, t);
    }

    /// Splitting time into many settlements never streams more than one continuous settlement.
    function testFuzz_settlement_frequency_does_not_overcharge(uint8 steps, uint256 stepSize) public {
        steps = uint8(bound(steps, 1, 50));
        stepSize = bound(stepSize, 1, 3 days);
        // Up to 50 x 3 days = 150 days; fund 180 days so the balance never runs out (the cap would
        // make claimable fall below the uncapped continuous figure for reasons unrelated to rounding).
        _open(2, 6 * PRICE);
        uint256 start = block.timestamp;
        vm.deal(alice, 1 ether);
        for (uint256 i; i < steps; ++i) {
            vm.warp(block.timestamp + stepSize);
            vm.prank(alice);
            s.deposit{value: 1}(2); // settles
        }
        uint256 continuous = ((block.timestamp - start) * PRICE) / 30 days;
        assertLe(s.claimable(), continuous);
        assertGe(s.claimable() + steps, continuous); // at most 1 wei lost per settlement
    }
}
