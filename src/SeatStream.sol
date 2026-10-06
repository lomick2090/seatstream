// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {EIP712} from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title SeatStream
/// @notice Prepaid, per-second payment for running an IdentityMD seat, one position per identity NFT token id.
/// Holders deposit native ETH; it streams to `payee` at `price` per `PERIOD` until the balance runs out (no debt).
/// The depositor can withdraw the unstreamed balance at any time, which closes the position.
/// Opening needs a single-use keeper authorization (per-token nonce) whose deadline is at most MAX_OPEN_WINDOW away.
/// The payee can permanently stop new opens and top-ups (disableOpens); every way out keeps working.
/// No admin, no upgrades, immutable price and roles.
contract SeatStream is EIP712, ReentrancyGuard {
    uint256 public constant PERIOD = 30 days;
    uint256 public constant MAX_OPEN_WINDOW = 2 days;
    bytes32 public constant OPEN_TYPEHASH =
        keccak256("Open(uint256 tokenId,address depositor,uint256 nonce,uint256 deadline)");
    uint256 private constant RELEASE_GAS = 50_000;

    /// @notice Wei streamed per PERIOD.
    uint256 public immutable price;
    /// @notice Receives streamed ETH; may release positions, revoke authorizations and disable opens.
    address public immutable payee;
    /// @notice Signs open authorizations, pauses and resumes for operator downtime; may release and revoke.
    address public immutable keeper;

    struct Position {
        address depositor;
        uint64 lastUpdate;
        bool paused;
        uint256 balance;
    }

    mapping(uint256 tokenId => Position) private _positions;
    /// @notice Refunds a release could not push (the depositor rejected ETH); collect with collectRefund().
    mapping(address depositor => uint256) public refunds;
    /// @notice The nonce the next Open authorization for a token must carry. Every open and revokeOpens bump it.
    mapping(uint256 tokenId => uint256) public openNonce;
    /// @notice Streamed and not yet claimed.
    uint256 public claimable;
    /// @notice Set once by the payee: no new opens or top-ups from then on.
    bool public opensDisabled;

    event Opened(uint256 indexed tokenId, address indexed depositor, uint256 amount);
    event Deposited(uint256 indexed tokenId, address indexed depositor, uint256 amount);
    event Withdrawn(uint256 indexed tokenId, address indexed depositor, uint256 amount);
    event Released(uint256 indexed tokenId, address indexed depositor, uint256 refunded, bool pushed);
    event Paused(uint256 indexed tokenId);
    event Resumed(uint256 indexed tokenId);
    event Claimed(uint256 amount);
    event RefundCollected(address indexed depositor, uint256 amount);
    event OpensRevoked(uint256 indexed tokenId, uint256 nextNonce);
    event OpensDisabled();

    error PriceTooLow();
    error ZeroAddress();
    error ZeroAmount();
    error Expired();
    error DeadlineTooFar();
    error Frozen();
    error PositionOpen();
    error NoPosition();
    error BelowMinimum();
    error BadSignature();
    error NotDepositor();
    error NotOperator();
    error NotKeeper();
    error NotPayee();
    error AlreadyPaused();
    error NotPaused();
    error TransferFailed();

    constructor(uint256 price_, address payee_, address keeper_) EIP712("SeatStream", "1") {
        // Below PERIOD wei per period, per-second accrual floors to zero and nothing would ever stream.
        if (price_ < PERIOD) revert PriceTooLow();
        if (payee_ == address(0) || keeper_ == address(0)) revert ZeroAddress();
        price = price_;
        payee = payee_;
        keeper = keeper_;
    }

    // ---------------------------------------------------------------- holder

    /// @notice Open the position for `tokenId` with at least one period's price, authorized by the keeper
    /// for the current openNonce(tokenId). The authorization is used up.
    function open(uint256 tokenId, uint256 deadline, bytes calldata signature) external payable nonReentrant {
        if (opensDisabled) revert Frozen();
        if (block.timestamp > deadline) revert Expired();
        if (deadline > block.timestamp + MAX_OPEN_WINDOW) revert DeadlineTooFar();
        Position storage p = _positions[tokenId];
        if (p.depositor != address(0)) revert PositionOpen();
        if (msg.value < price) revert BelowMinimum();
        uint256 nonce = openNonce[tokenId];
        (address signer, ECDSA.RecoverError err,) =
            ECDSA.tryRecover(openDigest(tokenId, msg.sender, nonce, deadline), signature);
        if (err != ECDSA.RecoverError.NoError || signer != keeper) revert BadSignature();
        openNonce[tokenId] = nonce + 1;
        p.depositor = msg.sender;
        p.lastUpdate = uint64(block.timestamp);
        p.paused = false;
        p.balance = msg.value;
        emit Opened(tokenId, msg.sender, msg.value);
    }

    /// @notice Top up; any amount. Restarts streaming from now if the balance had run out.
    function deposit(uint256 tokenId) external payable nonReentrant {
        if (opensDisabled) revert Frozen();
        if (msg.value == 0) revert ZeroAmount();
        Position storage p = _positions[tokenId];
        if (p.depositor == address(0)) revert NoPosition();
        if (p.depositor != msg.sender) revert NotDepositor();
        _settle(p);
        p.balance += msg.value;
        emit Deposited(tokenId, msg.sender, msg.value);
    }

    /// @notice Take back everything not yet streamed and close the position (stops the service).
    function withdraw(uint256 tokenId) external nonReentrant {
        _withdraw(tokenId, msg.sender);
    }

    /// @notice Same as withdraw, but the ETH goes to `to` (for depositor contracts that cannot receive ETH).
    function withdrawTo(uint256 tokenId, address to) external nonReentrant {
        if (to == address(0)) revert ZeroAddress();
        _withdraw(tokenId, to);
    }

    /// @notice Collect a refund that a release could not push.
    function collectRefund() external nonReentrant {
        _collectRefund(msg.sender);
    }

    /// @notice Same as collectRefund, but the ETH goes to `to`.
    function collectRefundTo(address to) external nonReentrant {
        if (to == address(0)) revert ZeroAddress();
        _collectRefund(to);
    }

    // -------------------------------------------------------------- operator

    /// @notice End the service for `tokenId` and refund the unstreamed balance to its depositor.
    function release(uint256 tokenId) external nonReentrant {
        if (msg.sender != payee && msg.sender != keeper) revert NotOperator();
        Position storage p = _positions[tokenId];
        address depositor = p.depositor;
        if (depositor == address(0)) revert NoPosition();
        _settle(p);
        uint256 amount = p.balance;
        delete _positions[tokenId];
        bool pushed = true;
        if (amount > 0) {
            bool ok;
            // Capped gas and no returndata copy: a hostile depositor can neither block nor bloat a release.
            assembly ("memory-safe") {
                ok := call(RELEASE_GAS, depositor, amount, 0, 0, 0, 0)
            }
            if (!ok) {
                refunds[depositor] += amount;
                pushed = false;
            }
        }
        emit Released(tokenId, depositor, amount, pushed);
    }

    /// @notice Invalidate every outstanding Open authorization for `tokenId`.
    function revokeOpens(uint256 tokenId) external {
        if (msg.sender != payee && msg.sender != keeper) revert NotOperator();
        uint256 next = openNonce[tokenId] + 1;
        openNonce[tokenId] = next;
        emit OpensRevoked(tokenId, next);
    }

    /// @notice Permanently stop new opens and top-ups (for a stolen keeper key or a wind-down). Payee only.
    function disableOpens() external {
        if (msg.sender != payee) revert NotPayee();
        if (opensDisabled) revert Frozen();
        opensDisabled = true;
        emit OpensDisabled();
    }

    /// @notice Stop streaming while the operator's service is down; paidUntil moves out by the paused time.
    function pause(uint256 tokenId) external {
        if (msg.sender != keeper) revert NotKeeper();
        Position storage p = _positions[tokenId];
        if (p.depositor == address(0)) revert NoPosition();
        if (p.paused) revert AlreadyPaused();
        _settle(p);
        p.paused = true;
        emit Paused(tokenId);
    }

    function resume(uint256 tokenId) external {
        if (msg.sender != keeper) revert NotKeeper();
        Position storage p = _positions[tokenId];
        if (p.depositor == address(0)) revert NoPosition();
        if (!p.paused) revert NotPaused();
        p.paused = false;
        p.lastUpdate = uint64(block.timestamp);
        emit Resumed(tokenId);
    }

    /// @notice Settle the listed positions and pay everything streamed so far to the payee. Anyone may call.
    function claim(uint256[] calldata tokenIds) external nonReentrant {
        for (uint256 i; i < tokenIds.length; ++i) {
            Position storage p = _positions[tokenIds[i]];
            if (p.depositor != address(0)) _settle(p);
        }
        uint256 amount = claimable;
        if (amount == 0) revert ZeroAmount();
        claimable = 0;
        emit Claimed(amount);
        _send(payee, amount);
    }

    // ----------------------------------------------------------------- views

    function positionOf(uint256 tokenId)
        external
        view
        returns (address depositor, uint256 balance, bool paused, uint256 paidUntil_)
    {
        Position memory p = _positions[tokenId];
        if (p.depositor == address(0)) return (address(0), 0, false, 0);
        balance = p.balance - _due(p);
        return (p.depositor, balance, p.paused, block.timestamp + (balance * PERIOD) / price);
    }

    function paidUntil(uint256 tokenId) external view returns (uint256) {
        Position memory p = _positions[tokenId];
        if (p.depositor == address(0)) return 0;
        return block.timestamp + ((p.balance - _due(p)) * PERIOD) / price;
    }

    function pendingClaim(uint256[] calldata tokenIds) external view returns (uint256 total) {
        total = claimable;
        for (uint256 i; i < tokenIds.length; ++i) {
            Position memory p = _positions[tokenIds[i]];
            if (p.depositor != address(0)) total += _due(p);
        }
    }

    function openDigest(uint256 tokenId, address depositor, uint256 nonce, uint256 deadline)
        public
        view
        returns (bytes32)
    {
        return _hashTypedDataV4(keccak256(abi.encode(OPEN_TYPEHASH, tokenId, depositor, nonce, deadline)));
    }

    // -------------------------------------------------------------- internal

    function _withdraw(uint256 tokenId, address to) private {
        Position storage p = _positions[tokenId];
        if (p.depositor == address(0)) revert NoPosition();
        if (p.depositor != msg.sender) revert NotDepositor();
        _settle(p);
        uint256 amount = p.balance;
        delete _positions[tokenId];
        emit Withdrawn(tokenId, msg.sender, amount);
        if (amount > 0) _send(to, amount);
    }

    function _collectRefund(address to) private {
        uint256 amount = refunds[msg.sender];
        if (amount == 0) revert ZeroAmount();
        refunds[msg.sender] = 0;
        emit RefundCollected(msg.sender, amount);
        _send(to, amount);
    }

    function _due(Position memory p) private view returns (uint256 due) {
        if (p.paused || p.balance == 0) return 0;
        due = ((block.timestamp - p.lastUpdate) * price) / PERIOD;
        if (due > p.balance) due = p.balance;
    }

    function _settle(Position storage p) private {
        uint256 due = _due(p);
        if (due > 0) {
            p.balance -= due;
            claimable += due;
        }
        p.lastUpdate = uint64(block.timestamp);
    }

    function _send(address to, uint256 amount) private {
        (bool ok,) = to.call{value: amount}("");
        if (!ok) revert TransferFailed();
    }
}
