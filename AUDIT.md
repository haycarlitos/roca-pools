# Audit Brief

Prepared for an external review of `roca-pools`. Written by the team, so read
the Known Issues section as a starting point rather than a boundary.

## What this system is

Lenders deposit USDC into a `CreditPool`. The pool's founder borrows the full
balance once, off-ramps it to Mexican pesos, and originates payroll-deducted
consumer loans off chain. Repayments come back as USDC and lenders withdraw
principal plus interest pro rata.

The important consequence for a reviewer: **the pool holds no collateral.**
The asset backing it is a salary deduction agreement enforced off chain. On
chain there is only cash accounting. Nothing here should be read as a
collateralised lending protocol, and there is no liquidation logic because
there is nothing to liquidate.

## Scope

In scope:

| File | Lines | Role |
|---|---|---|
| `src/credit_pool.cairo` | 804 | Per-vintage pool. Holds funds. |
| `src/pool_factory.cairo` | 313 | Deploys pools, owns fee config and the pool class hash. |
| `src/audit_registry.cairo` | 191 | Anchors reconciled payroll batches. Holds no funds. |
| `src/interfaces/*.cairo` | 280 | Public interfaces and structs. |

Out of scope: `src/mocks/mock_erc20.cairo` (test only), the off-chain
application, and the Chipi wallet stack used to sign transactions.

Dependencies: `openzeppelin_token` v1.0.0 (ERC20 interfaces only) and
`openzeppelin_security` (reentrancy guard), pinned in `Scarb.lock`.

## Build

Toolchain pins in `.tool-versions` are load-bearing: a different Scarb
produces a different class hash from identical source.

```
mise install          # scarb 2.11.4, starknet-foundry 0.53.0
scarb build
scarb test            # 36 tests
```

## Invariants

These are the properties we believe hold. They are stated here because two of
them were never written down before, and one of those turned out to be false.

**Funds**

1. A lender can always withdraw at least what they deposited, minus what they
   already withdrew, in every state where the pool has not lent the money out.
2. `withdraw` is never blocked by `pause`. Pausing stops new exposure; it must
   never trap a lender.
3. After `borrow`, a lender's entitlement is `total_repaid * deposited / total_deposited`,
   minus what they already withdrew.
4. **`total_deposited` equals the pool's USDC balance in every pre-borrow
   state** (`Pending`, `Active`, `Expired`, `Cancelled`). Held by decrementing
   on withdrawal; frozen after `borrow`, where it becomes the pro-rata
   denominator. Was false before, see known issue 1.

**Access**

5. Only `founder` may call `borrow`, `repay`, `lower_rate`, `activate`, `cancel`.
6. Only the factory may `unpause` and `mark_defaulted`.
7. Either founder or factory may `pause`.
8. `expire` is permissionless by design, callable by anyone once the funding
   deadline has passed. It only moves a stalled pool to a state where lenders
   can exit.

**Lifecycle**

9. `Pending -> Active -> Borrowed -> Completed` is the only path through which
   money moves. `Cancelled`, `Expired` and `Defaulted` are terminal and all
   three leave withdrawal open.

   `Defaulted` accepts repayment so a recovery can still reach lenders, but it
   does **not** transition onward: a full recovery leaves the pool `Defaulted`
   rather than relabelling it `Completed`. Paying late does not make a payment
   on time, and `status` is the field most readers use to judge performance.
   The 2026-08-19 delta review found the transition initially reachable; it is
   now gated on `Borrowed` and covered by
   `test_a_full_recovery_does_not_relabel_a_defaulted_pool`.
10. `borrow` may happen at most once, and takes the entire balance.
11. `lower_rate` can only decrease. The rate is frozen into `borrow_rate_bps`
    at `borrow` time so later changes cannot alter an existing obligation.

**Placement**

12. `lender_count` never exceeds `max_lenders_limit`, and the limit is never 0.
13. A full pre-borrow exit releases the roster slot and clears the position,
    so `lenders[0..lender_count)` stays dense with no duplicates and no holes.
14. The minimum ticket applies only to a lender joining, never to a top-up,
    and never blocks a deposit of exactly the remaining headroom.
15. Deposits are gated on the factory allowlist; **withdrawals never are.**

**Registry**

16. A `cep_hash` can be anchored at most once, across all batches, forever.
17. `verify_loan_inclusion` returns false for an unanchored batch rather than
    reverting.

## Known Issues

Found by us, disclosed here so review time is not spent rediscovering them.

### 1. `total_deposited` was not decremented on withdrawal (High, FIXED)

`total_deposited` has exactly two writes: `0` at `initialize` (line 236) and
`new_total` in `deposit` (line 297). `withdraw` never reduces it, but
`_calculate_withdrawal` (line 750) permits a full exit while status is
`Pending` or `Active`.

So a pre-borrow withdrawal leaves `total_deposited` above the pool's real USDC
balance. Then `borrow` (line 369) reads `total_deposited` and transfers exactly
that amount (line 382), which now exceeds the balance, and the transfer
reverts. **The pool can never be funded.** Lenders are not robbed, they exit
through `expire`, but the vintage is dead.

Two smaller effects: cap headroom is permanently consumed via the
`total_deposited + amount <= cap_amount` check in `deposit`, and after
`borrow` the inflated denominator dilutes every remaining lender's pro-rata
share.

Not yet triggered on mainnet: all live pools hold 0 USDC.

`test_deposit_withdraw_before_borrow` (tests/test_lifecycle.cairo:85) covers
this exact path and passes. It asserts the lender got their USDC back and that
`position.withdrawn` is correct, then stops. It never re-reads
`total_deposited` and never calls `borrow` afterwards. The happy path was
tested; the invariant was not.

**Fixed.** `withdraw` now decrements `total_deposited` in the four pre-borrow
states, and leaves it frozen once the pool is `Borrowed` where it is the
pro-rata denominator. Two regression tests were written first and observed to
fail against the old code:

- `test_total_deposited_tracks_balance_after_pre_borrow_withdraw` failed with
  `total_deposited must follow`
- `test_borrow_still_works_after_a_lender_exits_pre_borrow` failed with
  `Insufficient balance`, which is the bricked pool, reproduced

`test_deposit_withdraw_before_borrow` was updated: it now asserts the
invariant it previously walked past.

### 2. `deposit` had no authorization (High, FIXED)

Any address can deposit into any pool. There is no allowlist and no entrypoint
to populate one. Investor eligibility is enforced only in the off-chain
application, which means it is not enforced.

**Fixed.** The allowlist lives on the **factory**, and every pool reads
through to it on deposit. Per-pool lists were rejected: revocation after a
sanctions hit has to be one transaction, not one per pool per investor.

Compliance is a role distinct from ownership. The owner can redirect fees, swap
the pool class and pause the factory; the key that must be reachable within
minutes of a hit should not carry all of that. `set_compliance_officer` is
owner-only, everything else is officer-only, and the owner loses authorization
rights once it delegates.

`create_pool` always passes `allowlist_enabled: true`. The flag exists so a
pool can be deployed standalone in tests without a live factory; a
factory-created pool is always gated.

The cost, accepted deliberately: a cross-contract read on every deposit, making
the factory a liveness dependency for deposits across all pools. It fails
closed.

### 3. No lender cap and no minimum deposit (Medium, FIXED)

`lender_count` is tracked and never bounded. Combined with issue 2, an
adversary can fill the lender roster with dust. And because
`position.deposited` is never reset, a lender who fully exits before `borrow`
still occupies their slot forever.

A minimum-ticket guard alone does not fix this, since the ticket is refundable
before `borrow`.

**Fixed**, as three pieces that only work together:

- `max_lenders_limit`, checked when a lender joins, never on a top-up
- `min_deposit_amount`, checked on the first deposit only, with an explicit
  exception for a deposit of exactly the remaining headroom. Without that, once
  the headroom drops below the minimum the last slice of the pool is unsellable
  and a cap-triggered activation can never fire.
- roster slot release on a full pre-borrow exit, via swap-and-pop over the
  index-addressed `lenders` array

The swap-and-pop is the risky part, since a wrong index write corrupts
`get_lender` for an unrelated lender rather than failing loudly. It is covered
for remove-middle, remove-last, remove-only and remove-then-rejoin, with
assertions on density and absence of duplicates.

Slot release changes observable behaviour: after a full pre-borrow exit the
position reads as zero rather than retaining `withdrawn`. The historical fact
is preserved in the `Deposited` and `Withdrawn` events; only current state is
cleared.

### Not defects, but worth knowing

- **`withdraw` is all-or-nothing.** It takes no amount and pays the full
  available balance. Deliberate: partial withdrawal would force a
  principal-versus-interest ordering decision, which has tax consequences.
- **No upgrade path.** No `upgrade`, no `replace_class_syscall`. Deployed pools
  are immutable. `set_pool_class_hash` on the factory affects new deployments
  only.
- **`expire` is permissionless.** Intentional, see invariant 8.

## Test Coverage

**82 tests, all passing**, against scarb 2.11.4 and starknet-foundry 0.53.0.

| File | Tests | Covers |
|---|---|---|
| `test_credit_pool.cairo` | 13 | Init, deposits, rate, pool info, fee arithmetic |
| `test_lifecycle.cairo` | 11 | Activate, borrow, repay, expire, cancel, default, accounting invariant |
| `test_pause.cairo` | 15 | Pause and unpause, and that withdrawals survive both |
| `test_placement_limits.cairo` | 11 | Minimum ticket, roster cap, slot release, swap-and-pop edges |
| `test_factory.cairo` | 16 | create_pool, access control, allowlist end to end |
| `test_audit_registry.cairo` | 16 | Anchoring, replay rejection, Merkle inclusion |

The factory previously had **no tests at all**. It now has coverage for
`create_pool`, `set_fees`, `set_pool_class_hash`, `set_platform_wallet`, the
compliance role, and the deposit gate exercised through a real factory and a
real pool rather than a mock.

Gaps we are still aware of:

- No multi-lender pro-rata test after partial repayment with uneven deposit
  timing. This is the arithmetic we most want reviewed.
- No test for repayment exceeding the amount owed.
- No fuzzing or property-based testing of any kind.
- Merkle proofs are tested at depths 0, 1 and 2 only.
- No test builds a tree wide enough to need an odd-node level.
- No test for a factory that is paused while a deposit is in flight.

## Threat Model

Assumed trusted: the factory owner (can change fees and the pool class hash for
future pools, cannot touch deployed pools or their funds) and the pool founder
(receives the entire balance at `borrow`; the design assumes they are the
servicer and legally obligated to repay).

Assumed hostile: every other caller, including lenders.

Explicitly not defended against: a founder who borrows and does not repay.
That is credit risk, handled by `mark_defaulted` and off-chain legal recourse,
not by the contract.

## What We Most Want Reviewed

1. The withdrawal maths in `_calculate_withdrawal`, especially pro-rata after
   partial repayment with several lenders and uneven deposit timing.
2. Whether issue 1 has consequences beyond the ones described, particularly
   in the `Defaulted` and `Expired` paths.
3. Reentrancy around `borrow` and `repay`. A guard is present; we would like
   confirmation it is correctly placed rather than merely present.
4. Fee arithmetic in `repay`: the platform fee is taken on the total including
   both principal and interest, and we would like that confirmed as intended
   rather than as rounding drift.
5. Whether the fixes for issues 1 to 3 introduce anything new, especially the
   swap-and-pop deregistration and the cross-contract allowlist read on the
   deposit path.
6. `AuditRegistry.verify_loan_inclusion`: the sorted-pair Poseidon
   construction. The interface takes the leaf's components and builds the leaf
   inside the contract, so an internal node cannot be presented as a leaf
   against a truncated proof. We would like that reasoning checked, and to know
   whether explicit domain separation between leaf and node hashing is still
   warranted on top of it.
