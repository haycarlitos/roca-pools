# OWASP Smart Contract Top 10 (2026)

Our contracts against the [OWASP Smart Contract Top 10:
2026](https://scs.owasp.org/sctop10/), the standard awareness list for smart
contract risk. The 2026 edition is ranked from 122 deduplicated incidents
covering roughly $905M of 2025 losses, so the ordering reflects what actually
takes money rather than what is most discussed.

Where a category does not apply, the structural reason is given. "Not
applicable" is a claim a reviewer should be able to check in one read.

---

## SC01:2026 — Access Control

**The top category, and the one that matches our risk profile most closely.**

| Surface | Restricted to | Test |
|---|---|---|
| `borrow`, `repay`, `lower_rate`, `activate`, `cancel` | pool founder | `test_omar_c1_*` |
| `unpause`, `mark_defaulted` | factory | `test_factory_can_unpause` |
| `unpause_pool`, `pause_pool`, `mark_pool_defaulted` | factory owner | `test_owner_can_unpause_a_pool_through_the_factory`, `test_owner_can_mark_a_pool_defaulted_through_the_factory`, `test_forwarder_refuses_a_foreign_pool` |
| `pause` | founder or factory | `test_founder_can_pause`, `test_factory_can_pause` |
| `set_fees`, `set_pool_class_hash`, `set_platform_wallet` | factory owner | `test_stranger_cannot_*` |
| `set_lp_authorization`, batch | compliance officer | `test_stranger_cannot_authorize` |
| `set_compliance_officer` | factory owner | `test_owner_can_delegate_compliance` |
| `register_batch` | registry servicer | `test_stranger_cannot_anchor` |
| `set_servicer` | registry owner | `test_servicer_cannot_appoint_servicers` |
| `expire` | **anyone, deliberately** | `test_opus_h1_*` |
| `initialize` | once, ever | `test_omar_c1_pool_cannot_be_reinitialized` |

Two design points a reviewer should weigh rather than assume:

**Compliance is separate from ownership.** The owner can redirect fees, swap the
pool class and pause the factory. The compliance officer can only change who may
invest. Delegating compliance removes that power from the owner rather than
sharing it. The reasoning: the key that must be reachable within minutes of a
sanctions hit should not also be able to redirect fee revenue.

**`expire` is permissionless on purpose.** It has one effect, in one direction,
only after a deadline, and its only consequence is that lenders can withdraw. A
stranger calling it gains nothing. Requiring a privileged caller would mean a
stalled pool needs Roca to be alive for lenders to exit.

## SC02:2026 — Business Logic

The category that produced our worst real bug.

`total_deposited` was incremented on deposit and never decremented on
withdrawal, while `borrow` transfers exactly `total_deposited`. A single
pre-borrow exit therefore made `borrow` try to move more USDC than the pool
held, reverting permanently and killing the vintage. Every low-level check
passed; the economic rule was broken. That is precisely SC02.

It was fixed after being reproduced by a test that failed with `Insufficient
balance` against the deployed logic. Full write-up in `AUDIT.md`, known issue 1.

Related logic rules now carrying tests:

- A minimum ticket does not bind unless the roster slot is released on a full
  pre-borrow exit, because the ticket is refundable before `borrow`.
- Once the remaining headroom is below the minimum, that remainder must still
  be depositable or the pool can never reach its cap.
- `total_deposited` must be frozen after `borrow`, where it becomes the
  pro-rata denominator.

## SC03:2026 — Price Oracle Manipulation

**Not applicable.** No oracle, no price feed, no on-chain valuation. USDC is
accounted at face value in its own units. The MXN/USD conversion happens off
chain and is recorded, not trusted for any on-chain decision.

## SC04:2026 — Flash Loan Facilitated Attacks

**Not applicable in the usual shape**, and worth saying why rather than
asserting it.

A flash loan needs an atomic profit. Our pools have no price to move, no
governance token to borrow, and no share price to inflate. A lender's
entitlement is `total_repaid * deposited / total_deposited`, which is fixed by
deposits made before `borrow` and repayments made after it. Depositing and
withdrawing inside one transaction returns exactly what went in.

The one flash-loan-adjacent vector is roster squatting: cycling capital to
occupy every lender slot. That is closed by releasing the slot on a full
pre-borrow exit, tested in `test_placement_limits.cairo`.

## SC05:2026 — Input Validation

`initialize` rejects: zero factory, founder, token or platform wallet; zero cap;
a rate outside 1 to 10000 bps; a repayment fee above 10000 bps; zero duration or
interval; an interval longer than the duration; a funding deadline in the past;
and a lender limit of zero.

`AuditRegistry.register_batch` rejects a zero `cep_hash`, a zero `merkle_root`
and a zero total, so an anchored batch always attests to something.

Covered by `test_omar_l1_*` and `test_omar_m1_*`.

## SC06:2026 — Unchecked External Calls

Every ERC20 call is checked:

```cairo
let success = usdc.transfer_from(caller, pool_address, amount);
assert(success, 'Transfer failed');
```

A failed transfer reverts the whole call, so a position is never credited for
money that did not arrive. Tested in `test_omar_h1_*`.

The cross-contract allowlist read in `deposit` fails closed: if the factory is
unreachable the deposit reverts rather than proceeding ungated.

## SC07:2026 — Arithmetic Errors

Interest and fees are basis points over `u256` with a 10000 denominator, and
Cairo's `u256` traps on overflow and underflow rather than wrapping.

Rounding is not yet independently reviewed at the boundaries. It is our
**first** named request to an external auditor: multi-lender pro-rata after
partial repayment with uneven deposit timing. See `AUDIT.md`, "What We Most
Want Reviewed".

## SC08:2026 — Reentrancy

`ReentrancyGuardComponent` on `deposit`, `withdraw`, `borrow` and `repay`, with
the guard entered before any external call, including the factory allowlist
read.

Proven rather than asserted: `src/mocks/reentrant_erc20.cairo` is a token that
calls `withdraw` back into the pool that is paying it. The guard stops it, and
`test_opus_m2_reentrant_withdraw_is_blocked` fails loudly if that ever changes.

Reentrancy fell from #2 to #8 in the 2026 list. It is still the one we test
adversarially rather than by inspection, because it is cheap to test and
expensive to be wrong about.

## SC09:2026 — Integer Overflow and Underflow

Cairo `u256` and `u32` arithmetic panics on overflow and underflow. There is no
`unchecked` equivalent in use.

The place this mattered: `_deregister_lender` computes `count - 1`, so it
asserts `count > 0` first rather than relying on the caller. Underflow there
would panic, but panicking for the wrong reason hides the real invariant.

## SC10:2026 — Proxy and Upgradeability

**No proxy, no upgrade path, no `replace_class_syscall`.** Deployed pools are
immutable for their entire life.

`PoolFactory.set_pool_class_hash` changes the class used for **future**
deployments only. Existing pools keep the class they were born with.

New in 2026 and now a top-10 entry. Our exposure is zero by construction, and
the cost is stated plainly rather than sold as a feature: a bug in a deployed
pool cannot be patched. It has to be paused, expired, and replaced. That is why
the accounting bug above was fixed before this class was declared rather than
after.

---

## Summary

| | |
|---|---|
| Directly applicable | SC01, SC02, SC05, SC06, SC07, SC08, SC09 |
| Not applicable, structurally | SC03 (no oracle), SC04 (no atomic profit), SC10 (no upgrade path) |
| Weakest area | SC07. Rounding at the pro-rata boundaries is untested against an adversary and is our first ask of an external auditor. |
| Strongest area | SC10, by having nothing there at all, at the cost of immutability. |

Sources: [OWASP Smart Contract Top 10:
2026](https://scs.owasp.org/sctop10/) · [OWASP project
page](https://owasp.org/www-project-smart-contract-top-10/)
