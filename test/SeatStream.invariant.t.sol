// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {SeatStream} from "../src/SeatStream.sol";

/// A depositor contract that rejects every ETH transfer.
contract Sink {
    receive() external payable {
        revert("sink");
    }
}

contract Handler is Test {
    SeatStream public s;
    uint256 public keeperPk;
    address public payee;
    address[] public actors;
    address public sink;
    address public sinkRecovery;
    uint256 public totalIn;
    uint256 public totalOut;
    uint256 public lastClaimable;
    bool public claimableDecreasedWithoutClaim;
    bool public replaySucceeded;

    mapping(uint256 => bytes) internal lastSig;
    mapping(uint256 => uint256) internal lastDeadline;
    mapping(uint256 => address) internal lastActor;

    constructor(SeatStream s_, uint256 keeperPk_, address payee_) {
        s = s_;
        keeperPk = keeperPk_;
        payee = payee_;
        for (uint256 i; i < 5; ++i) {
            address a = makeAddr(string(abi.encodePacked("actor", vm.toString(i))));
            actors.push(a);
            vm.deal(a, 1000 ether);
        }
        sink = address(new Sink());
        vm.deal(sink, 1000 ether);
        actors.push(sink);
        sinkRecovery = makeAddr("sinkRecovery");
    }

    function _check() internal {
        if (s.claimable() < lastClaimable) claimableDecreasedWithoutClaim = true;
        lastClaimable = s.claimable();
    }

    function _out(address to) internal view returns (uint256) {
        return to.balance;
    }

    function _sign(uint256 tokenId, address a, uint256 deadline) internal view returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 ss) = vm.sign(keeperPk, s.openDigest(tokenId, a, s.openNonce(tokenId), deadline));
        return abi.encodePacked(r, ss, v);
    }

    function open(uint256 actorSeed, uint256 tokenId, uint256 amount) external {
        address a = actors[actorSeed % actors.length];
        tokenId = tokenId % 10;
        amount = bound(amount, s.price(), 5 ether);
        (address depositor,,,) = s.positionOf(tokenId);
        if (depositor != address(0)) return;
        uint256 deadline = block.timestamp + 1 hours;
        bytes memory sg = _sign(tokenId, a, deadline);
        vm.prank(a);
        s.open{value: amount}(tokenId, deadline, sg);
        lastSig[tokenId] = sg;
        lastDeadline[tokenId] = deadline;
        lastActor[tokenId] = a;
        totalIn += amount;
        _check();
    }

    /// Tries to reopen with the last used signature. Must never succeed.
    function replay(uint256 tokenId) external {
        tokenId = tokenId % 10;
        if (lastSig[tokenId].length == 0) return;
        (address depositor,,,) = s.positionOf(tokenId);
        if (depositor != address(0) || block.timestamp > lastDeadline[tokenId]) return;
        uint256 p = s.price();
        vm.prank(lastActor[tokenId]);
        try s.open{value: p}(tokenId, lastDeadline[tokenId], lastSig[tokenId]) {
            replaySucceeded = true;
            totalIn += p;
        } catch {}
        _check();
    }

    function deposit(uint256 tokenId, uint256 amount) external {
        tokenId = tokenId % 10;
        (address depositor,,,) = s.positionOf(tokenId);
        if (depositor == address(0)) return;
        amount = bound(amount, 1, 2 ether);
        vm.prank(depositor);
        s.deposit{value: amount}(tokenId);
        totalIn += amount;
        _check();
    }

    function withdraw(uint256 tokenId) external {
        tokenId = tokenId % 10;
        (address depositor,,,) = s.positionOf(tokenId);
        if (depositor == address(0)) return;
        address to = depositor == sink ? sinkRecovery : depositor;
        uint256 before = _out(to);
        vm.prank(depositor);
        if (depositor == sink) s.withdrawTo(tokenId, sinkRecovery);
        else s.withdraw(tokenId);
        totalOut += _out(to) - before;
        _check();
    }

    function release(uint256 tokenId, bool byKeeper) external {
        tokenId = tokenId % 10;
        (address depositor,,,) = s.positionOf(tokenId);
        if (depositor == address(0)) return;
        uint256 before = depositor.balance;
        vm.prank(byKeeper ? vm.addr(keeperPk) : payee);
        s.release(tokenId);
        if (depositor != sink) totalOut += depositor.balance - before; // the sink's refund is credited, not pushed
        _check();
    }

    function collectSinkRefund() external {
        if (s.refunds(sink) == 0) return;
        uint256 before = sinkRecovery.balance;
        vm.prank(sink);
        s.collectRefundTo(sinkRecovery);
        totalOut += sinkRecovery.balance - before;
        _check();
    }

    function revoke(uint256 tokenId, bool byKeeper) external {
        tokenId = tokenId % 10;
        vm.prank(byKeeper ? vm.addr(keeperPk) : payee);
        s.revokeOpens(tokenId);
        _check();
    }

    function pause(uint256 tokenId) external {
        tokenId = tokenId % 10;
        (address depositor,, bool paused,) = s.positionOf(tokenId);
        if (depositor == address(0) || paused) return;
        vm.prank(vm.addr(keeperPk));
        s.pause(tokenId);
        _check();
    }

    function resume(uint256 tokenId) external {
        tokenId = tokenId % 10;
        (address depositor,, bool paused,) = s.positionOf(tokenId);
        if (depositor == address(0) || !paused) return;
        vm.prank(vm.addr(keeperPk));
        s.resume(tokenId);
        _check();
    }

    function claim() external {
        uint256[] memory ids = new uint256[](10);
        for (uint256 i; i < 10; ++i) {
            ids[i] = i;
        }
        if (s.pendingClaim(ids) == 0) return;
        uint256 before = payee.balance;
        s.claim(ids);
        totalOut += payee.balance - before;
        lastClaimable = 0;
    }

    function warp(uint256 secs) external {
        vm.warp(block.timestamp + bound(secs, 1, 20 days));
    }
}

contract SeatStreamInvariantTest is Test {
    SeatStream s;
    Handler h;
    address payee = makeAddr("payee");
    uint256 keeperPk = 0xA11CE;

    function setUp() public {
        vm.warp(1_700_000_000);
        s = new SeatStream(0.05 ether, payee, vm.addr(keeperPk));
        h = new Handler(s, keeperPk, payee);
        targetContract(address(h));
    }

    /// The contract holds exactly: claimable + every open position's stored balance + credited refunds.
    function invariant_solvency() public view {
        uint256[] memory ids = new uint256[](10);
        for (uint256 i; i < 10; ++i) {
            ids[i] = i;
        }
        uint256 live;
        for (uint256 i; i < 10; ++i) {
            (, uint256 bal,,) = s.positionOf(i);
            live += bal;
        }
        assertEq(address(s).balance, s.pendingClaim(ids) + live + s.refunds(h.sink()));
    }

    function invariant_conservation() public view {
        assertEq(h.totalIn(), h.totalOut() + address(s).balance);
    }

    function invariant_claimable_only_drops_on_claim() public view {
        assertFalse(h.claimableDecreasedWithoutClaim());
    }

    function invariant_open_signatures_are_single_use() public view {
        assertFalse(h.replaySucceeded());
    }
}
