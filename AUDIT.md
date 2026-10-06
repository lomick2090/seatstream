# Audits

## IdentityMD network audit (2026-10-06)

| | |
|---|---|
| Job | `447e95b3-559a-458c-ad24-5d60a04ac7dd` (template `audit`, paid 0.5 IMD, tx `0xff64745553b96db538c45b4c99b3fdf0181d14ec9fe0f0f31727db172b4dbdf4`) |
| Commit audited | `b2d19e75658d2b982554d16ce4206e453d7fdbb1` |
| Report | https://api.imd.fun/jobs/447e95b3-559a-458c-ad24-5d60a04ac7dd/report.md |
| Submissions | https://api.imd.fun/jobs/447e95b3-559a-458c-ad24-5d60a04ac7dd/submissions |

Four specialists (math, permissions, economics, control flow) each audited the code at that commit and ran the test suite (all passing). The judge step did not run: its sandbox failed (`bwrap: setting up uid map: Permission denied`), so it could not reproduce anything, and the published report's "none kept" reflects that failure, not a refutation. We treat the four specialist reports as the audit result.

Specialist findings and what we did:

| Finding | Raised by | Severity | Resolution |
|---|---|---|---|
| `deposit()` accepts top-ups only from the depositor, while the README said anyone can top up | economics, permissions | Low | Documentation error. Depositor-only top-ups are the intended design (asserted by `test_deposit_rules`). README corrected; no code change. |
| `pendingClaim` counts a repeated token id twice, so the view can overstate | math, permissions | Low | View-only; `claim` pays the right amount because a second settlement of the same position streams 0. Documented in the NatSpec and README: ids must be distinct. The operator API always passes distinct ids. |

The control-flow specialist found no defects. The economics specialist found nothing that lets anyone take depositor or payee funds.

## Internal audits (2026-10-06)

Two multi-agent reviews before and after the fixes, each with four or five independent lenses and proof-of-concept verification of every Medium-or-worse finding.

- The first found that keeper Open signatures could be replayed after a withdraw or release (now a per-token nonce), plus hardening items: an on-chain deadline cap, a payee freeze, `withdrawTo` / `collectRefundTo`, a release call that ignores returndata, a minimum price, and deploy-script checks.
- The re-audit of the fixed code found nothing Medium or worse, confirmed each fix, and confirmed that a signature cannot be replayed across the Base and Ethereum deployments (the EIP-712 domain binds chain id and contract).
