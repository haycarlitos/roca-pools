# Compliance Notes

For counsel, auditors and regulators. Describes what the contracts **enforce**,
what they **record**, and what remains a human control.

Nothing here is legal advice or a legal opinion. Statutory analysis is
counsel's; this document only states accurately what the software does, so that
analysis rests on facts rather than on a description written by someone selling
the thing.

## Contracts in scope

| Contract | Role | Holds funds |
|---|---|---|
| `PoolFactory` | Deploys pools, holds fee config, holds the investor allowlist | No |
| `CreditPool` | One per funding vintage. Deposits, drawdown, repayment, withdrawal | **Yes** |
| `AuditRegistry` | Anchors reconciled payroll batches against bank receipts | No |

All on Starknet mainnet. There is no test deployment; the chain is the only
environment.

## What is enforced on chain

These cannot be bypassed by an application bug, an operator error, or a
compromised admin panel, because they are conditions inside the contract.

| Control | Mechanism |
|---|---|
| Only approved investors may deposit | `deposit` reads the factory allowlist. An unapproved address reverts. |
| Investor count per pool is capped | `deposit` refuses a new investor once the limit is reached. The limit is set at pool creation and cannot be raised afterwards. |
| Minimum ticket size | Enforced on an investor's first deposit. |
| Approval is revocable, immediately and everywhere | One transaction against the factory closes every pool to that investor at once. |
| **Revocation cannot seize funds** | The withdrawal path is not gated on approval. A revoked investor cannot add, and can always exit. |
| Roca cannot draw more than was deposited | `borrow` moves exactly the deposited balance, once. |
| Drawdown is once, and only from an active pool | Enforced by the lifecycle state machine. |
| A bank receipt cannot be counted twice | The registry rejects a `cep_hash` it has already anchored, permanently. |

## What is recorded but not enforced

The contracts are a ledger for these, not a control.

- **The reconciliation itself.** The invariant that deductions sum to the bank
  transfer total is checked off chain before anchoring. The chain stores the
  commitment, not the arithmetic.
- **Repayment obligation.** Nothing compels Roca to repay. The contract records
  a default; recovery is contractual and judicial.
- **FX.** Conversions are recorded off chain with rate and counterparty. No
  on-chain decision depends on a price.

## What remains a human control

Stated plainly because an "on-chain compliance" claim that quietly rests on a
person is worse than no claim.

| Control | Who | Note |
|---|---|---|
| Identity verification | KYC provider, off chain | The chain sees an address, never an identity. |
| AML, PEP and sanctions screening | Provider plus operator review | Must gate approval, not follow it. |
| The decision to approve an investor | Compliance officer | The on-chain allowlist records the decision; it does not make it. |
| Credit underwriting | Roca | Entirely off chain. |
| Peso disbursement and collection | Roca, through the banking system | The chain never touches pesos. |

## Personal data

**No personal data is written to any contract.** No name, tax ID, address,
salary, employer, or individual loan amount.

What appears on chain is: wallet addresses, dollar amounts at pool level,
timestamps, and cryptographic commitments.

The registry's Merkle leaves are built from a loan identifier, an amount, a
period and a **256-bit random salt held off chain**. The salt is load-bearing
rather than decorative: loan identifiers are sequential and payroll deductions
fall in a narrow band, so unsalted leaves would be brute-forceable from the
published root, which would put the loan book on a public ledger.

Inclusion proofs are designed to be run as reads. Submitting one in a
transaction would place the salt in public calldata and undo that protection.
This is documented at the interface.

## Segregation of duties

Three distinct roles, deliberately not collapsed:

- **Factory owner.** Fees, pool class, global pause. Cannot approve investors
  once compliance is delegated.
- **Compliance officer.** Investor approval and revocation only. No fee, class
  or pause authority.
- **Pool founder.** Draws and repays a specific pool. No authority over any
  other pool or over the factory.

The separation exists because the key that must be reachable within minutes of a
sanctions hit should not be the same key that can redirect fee revenue.

Delegating compliance **removes** the power from the owner rather than sharing
it, which is tested.

## Immutability, and what it costs

Deployed pools cannot be upgraded. No proxy, no `replace_class_syscall`, no
admin key that can change a live pool's logic.

The benefit: the rules an investor read when they deposited are the rules that
apply for the pool's whole life, and no key exists that can change them.

The cost, stated because it is the honest half: **a bug in a deployed pool
cannot be patched.** The response is to pause it, let it expire, let investors
withdraw, and deploy a corrected class for new pools. New pools use the new
class; existing pools keep the class they were born with.

## Current limitations

Written down because a compliance document that lists only strengths is a
marketing document.

1. **No independent external audit yet.** Internal review only, plus systematic
   replication of another codebase's audit findings. External review is planned
   and has not happened.
2. **The reconciliation invariant is off chain.** A reviewer must trust or
   verify the off-chain process that computes the Merkle root before anchoring.
3. **Rounding at the pro-rata boundaries is not independently reviewed.** It is
   our first named request to an external auditor.
4. **Pools already deployed predate these controls.** The seven pools on mainnet
   today have no allowlist, no investor cap and no minimum ticket, because those
   contracts do not contain them and cannot be upgraded. They hold no funds and
   are past their funding deadlines. New placements must use a newly deployed
   factory and class.

Point 4 matters most: any statement that deposits are gated on chain is true of
pools created from the new class, and false of the seven that exist now.

## Verification

Anything above can be checked without our cooperation:

- Contract source: this repository, public
- Deployed bytecode: derived from this source with a pinned compiler, class
  hashes in `docs/` at deploy time
- Every deposit, drawdown, repayment and withdrawal: public on Starknet
- Every approval and revocation: emitted as an event, publicly indexable
- Every anchored batch: public, with its receipt hash
- Tests: 109, run in CI on every change
