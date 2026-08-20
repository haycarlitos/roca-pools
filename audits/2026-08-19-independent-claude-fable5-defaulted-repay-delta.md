# Delta re-review — repayment accepted after default

- **Date:** 2026-08-19
- **Reviewer:** Independent adversarial review, AI-assisted (Claude Fable 5)
- **Type:** Focused adversarial re-review of a money-path change
- **Delta:** `2ac50a0 → 178cf98`, two changes in `src/credit_pool.cairo`
- **Evidence:** `tests/audit_default_repay.cairo` (added by this review; passing)

This is not a full re-audit. It reviews the delta only and states whether the 2026-08-18 verdict ("ready to declare, no Critical or High") still stands.

## The delta

1. **`repay` widened** from `status == Borrowed` to `Borrowed || Defaulted`. Rationale: `mark_defaulted` is factory-only and was irreversible, so blocking repayment afterwards meant a recovery collected from the loan book could never be distributed through the pool — which made *not* defaulting strictly better for lenders than defaulting honestly. (This closes the Low finding from the 2026-08-18 review.)
2. **`initialize` fee ceiling tightened** from `<= 10000` to `<= 1000`, matching `PoolFactory.set_fees`.

## Verdict

**The 2026-08-18 "ready to declare" still holds at HEAD.** The widened `repay` does not strand, over-credit, or under-credit anyone through `_calculate_withdrawal`. Nothing in the delta rises to Critical, High, or Medium. Two things are now technically inaccurate — invariant 9's claim that `Defaulted` is terminal, and the new code comment's claim that "the status stays Defaulted" — but both are benign: funds stay safe and withdrawal stays open in every case. They are Low / Informational.

## The central question — answered: No

Accepting repayment in `Defaulted` cannot break solvency, and the reason is structural, not numeric. **Status is not an input to the pro-rata arithmetic.** The only two inputs are `total_deposited` (frozen at `borrow`; `repay` never writes it in either `Borrowed` or `Defaulted`) and `total_repaid` (monotonic, capped at `total_owed` by the overpayment guard, in both states). `mark_defaulted` writes only the status. So inserting a default into a repay/withdraw interleaving is a no-op for the money math, and the prior solvency proof carries over verbatim:

```
entitlement_X(R) + Σ_{j≠X} withdrawn_j ≤ Σ_j entitlement_j(R) ≤ R = pool inflow
```

none of whose terms depends on status. I constructed the exact newly-reachable sequence — L1 withdraws → default → recovery → L2 withdraws → further recovery → L1 withdraws again, with L3 untouched until the end — and asserted at every step that the pool holds exactly `total_repaid − Σ withdrawn` (never negative), that no lender exceeds `floor(total_repaid × deposited / total_deposited)`, that the entitlement sum never exceeds `total_repaid`, and that `total_deposited` never moves across the status change. It passes: `test_interleaved_withdraw_across_default_stays_solvent`. The last withdrawer is never short, and double truncation behaves identically whether `total_repaid` grows within `Borrowed` or across the `Borrowed→Defaulted` boundary.

## Findings

- **[Low] Invariant 9 is now false: `Defaulted` is no longer terminal.** `repay`'s completion branch still runs on the widened path, so a recovery reaching `total_owed` calls `_set_status(Completed)` — a new `Defaulted → Completed` transition, which AUDIT.md invariant 9 denies. Proven by `test_full_recovery_after_default_flips_status_to_completed`. **Impact: none to funds** — `Completed` is itself terminal and withdrawal stays open pro-rata throughout. Documentation/spec defect; re-word invariant 9.
- **[Info] The code comment contradicts the code.** The comment "The status stays Defaulted … a recovery does not undo it" is true only for a *partial* recovery; a full recovery flips it to `Completed`. Off-chain readers keying on current status would not see that a fully-recovered pool was ever defaulted (the `StatusChanged` events still carry the history).
- **[Info] Platform fee is now skimmed from post-default recoveries.** With `repayment_fee_bps > 0`, every recovery repaid in `Defaulted` routes the fee to `platform_wallet` before crediting lenders. Mainnet fee is 0 by default, so no live impact, but it is a policy question the delta silently answers "yes".

## Other items examined

- **`mark_defaulted` incentives:** no new gain vector. It moves no money, is factory-only, and payout is now identical before and after default. The change *removes* the perverse incentive (withholding an honest default). Re-default is impossible (`mark_defaulted` requires `Borrowed`).
- **`withdraw` state sets:** `Defaulted` is correctly excluded from the `total_deposited`-decrement set, so the denominator stays frozen. No state is on the wrong side of the borrow boundary.
- **Reentrancy:** the guarded region in `repay` is byte-identical to the audited version; only the status assert widened, inside the guard. No regression; `test_opus_m2_reentrant_withdraw_is_blocked` still valid.
- **Change 2 blast radius:** tightening `initialize` breaks nothing. It is one-shot (existing pools keep their fee), and the factory always passes `<= 1000` (`set_fees` caps it, constructor defaults 0), so `create_pool` never trips the new assert. A directly-deployed pool with fee > 1000 is now rejected at birth — the intended effect.
- **The two shipped tests:** both pass for the right reason but are narrow. `test_a_defaulted_pool_can_still_receive_and_distribute_a_recovery` uses a single lender and a partial recovery, exercising neither multi-lender interleaving nor the `Defaulted→Completed` flip; `test_repay_is_still_refused_before_the_money_is_drawn` tests only `Active`. `tests/audit_default_repay.cairo` fills those gaps.

## Invariants under the widened repay

- **1, 3, 4, 15 — still hold.** Inv 3 (post-borrow entitlement) and Inv 4 (`total_deposited` frozen after borrow) are load-bearing here and both hold: `repay` writes `total_repaid`/`principal_repaid`/`last_repayment_at`, never `total_deposited`. Inv 1 and 15 are in paths the delta does not touch.
- **9 — no longer holds as written.** `Defaulted → Completed` now exists. Benign (withdrawal stays open, funds safe), but the stated invariant is technically false and should be corrected.

## Bottom line

The delta is safe. The widened repay is an arithmetic no-op for solvency because status is not an input to the pro-rata math, and the newly-reachable interleaving stays solvent at every step. The only thing the previous verdict "no longer covers" is invariant 9's terminal-state claim and the accompanying comment — both benign documentation corrections. "Ready to declare" stands.
