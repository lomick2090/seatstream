# SeatStream

A prepaid, per-second ETH payment stream for running an IdentityMD seat, one position per identity NFT token id. The same contract is deployed once on Base (8453) and once on Ethereum (1), with the same payee, keeper and price. It is not deployed yet.

## Audit scope

- In scope: `src/SeatStream.sol`, and the deploy script `script/Deploy.s.sol`.
- Context only: `test/` (unit, fuzz and invariant tests), `testnet/MockIdentity721.sol` and `script/DeployMockIdentity.s.sol` (testnet-only stand-in for the NFT collection; it refuses to deploy on Base or Ethereum).
- Out of scope: `lib/` (vendored OpenZeppelin Contracts 5.1 and forge-std, unmodified).

## How it works

- A holder opens a position for a token id with at least one period's price (0.05 ETH per 30 days on mainnets). The open needs an EIP-712 `Open(uint256 tokenId,address depositor,uint256 nonce,uint256 deadline)` signature from the keeper, where `nonce` is `openNonce(tokenId)`. Every open bumps the nonce, so a signature works once. The deadline must be at most 2 days ahead when `open` runs.
- The balance streams to the payee by the second until it runs out. There is no debt and no grace period. Anyone can top up any amount with `deposit`.
- The depositor can take back the unstreamed balance at any time with `withdraw`, or `withdrawTo` another address.
- Roles are immutable and there is no admin or upgrade path.
  - Payee (a cold wallet): receives `claim`, may `release` a position, `revokeOpens`, and call the one-way `disableOpens()` that blocks `open` and `deposit` (every exit keeps working).
  - Keeper (a hot key on the operator's box): signs opens, may `pause` and `resume` streaming during operator downtime, `release` and `revokeOpens`.
- `release` refunds the unstreamed balance to the depositor with a 50,000 gas call that ignores returndata. If the push fails, the refund is credited to `refunds` for `collectRefund` / `collectRefundTo`.

## Threat model

- A stolen keeper key must not let anyone take depositor or payee funds. Griefing (squats that get released, pauses, resumes, revokes) is the accepted worst case, and `disableOpens()` from the payee stops new opens on that chain.
- Depositors are untrusted: they may be contracts that revert, reenter, burn gas or return large data.
- The payee is trusted, but must not reach unstreamed balances.
- An off-chain API stops a token from holding positions on both chains. On chain, each deployment allows one position per token id.

## Known and accepted

- Settlement rounds down in the depositor's favour (under 1 wei per settlement), and anyone can trigger settlement through `claim`.
- ETH forced in by selfdestruct or as a coinbase is unrecoverable. Accounting never reads `address(this).balance`.
- The 2-day deadline bound is checked when `open` runs, not when the keeper signs. The keeper only signs short deadlines for the current nonce.
- `paidUntil` is a floor and can sit up to 1 second before the balance runs out.

## Build and test

```
forge build
forge test
```

The invariant suite runs with `fail_on_revert = true`. `script/Deploy.s.sol` pins the price to 0.05 ETH on Base and Ethereum, needs `SEATSTREAM_CHAIN_ID` to match the RPC there, and requires a payee with no code.
