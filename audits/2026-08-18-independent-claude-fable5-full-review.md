# Independent security review — roca-pools

- **Date:** 2026-08-18
- **Reviewer:** Independent adversarial review, AI-assisted (Claude Fable 5), at the request of the Roca team
- **Type:** Full first-pass review of the on-chain contracts
- **Tree reviewed:** the tree that became `2ac50a0` (`credit_pool.cairo`, `pool_factory.cairo`, `audit_registry.cairo`, interfaces, `scripts/deploy.sh`, `scripts/preflight.sh`)
- **Build:** scarb 2.11.4 / starknet-foundry 0.53.0 as pinned; suite passing.
- **Evidence:** `tests/audit_prorata.cairo` (added by this review; passing verification tests)

## Verdict

**Ready to declare on mainnet from a funds-safety standpoint. No Critical or High findings.** The two prior High bugs recorded in `AUDIT.md` are genuinely fixed and their fixes are correct. The hardest arithmetic (`_calculate_withdrawal`) is conservative and provably solvent, and I could not break either of the two inviolable properties. What remains is a short list of Low / Informational hardening items plus residual *off-chain* trust assumptions (founder credit risk, factory/owner trust) that are inherent to the design, not code defects.

Because there are no Critical/High findings, there are no failing tests to deliver. Instead the review ships passing verification tests that would have failed had the money paths been wrong.

## The two inviolable properties — neither could be broken

**"Withdrawal is never blocked."** `withdraw` has no pause check and no allowlist check, and every terminal state yields a positive `available`: `Cancelled`/`Expired` return full principal (`deposited - withdrawn`), `Completed`/`Defaulted` return pro-rata of `total_repaid`. The only assert inside the post-borrow calculation, `position.deposited <= total_deposited`, can never fire: `total_deposited` is frozen at borrow and equals the sum of surviving positions, so each summand is `<=` it, permanently. Two caveats that are *not* contract defects: `Defaulted` with zero repayments reverts `'Nothing to withdraw'` because there is genuinely nothing owed; and real Circle USDC carries its own blocklist, so a token-level sanction could block the final `transfer` — outside this system's control.

**"No oversubscription; the loser of the last-slice race keeps their funds."** The cap check `total_deposited + amount <= cap_amount` runs on every deposit under sequential execution and the reentrancy guard; the losing deposit reverts *before* `transfer_from`, so no funds move. Covered by the existing `test_a_pool_cannot_be_oversubscribed` and `test_the_loser_of_the_last_slice_keeps_their_money`.

## Priority areas

1. **Pro-rata withdrawal arithmetic — verified safe (only dust).** The double truncation rounds down twice, so every lender is under-credited by at most a few micro-USDC and the sum of entitlements is always `<= total_repaid`. Solvency holds under interleaved partial repayments and withdrawals, with the last withdrawer never short (formal argument: `entitlement_X(R) + Σ_{j≠X} withdrawn_j ≤ Σ entitlement_j(R) ≤ R`). Verified by `test_prorata_interleaved_partial_repay_and_withdraw` and `test_prorata_last_withdrawer_not_short_after_default`. Only residue is stranded dust (< 10 micro-USDC), an Informational item.
2. **Accounting fix / freeze boundary — exactly right.** The `withdraw` decrement set (`Pending, Active, Expired, Cancelled`) is identical to the pre-borrow branch in `_calculate_withdrawal`, so the two never disagree about which side of the borrow boundary a state is on. A pre-borrow exit correctly shrinks the denominator so survivors are not diluted, and `borrow` moves the real balance — `test_pre_borrow_exit_shrinks_the_prorata_denominator`.
3. **Swap-and-pop deregistration — correct.** `_deregister_lender` writes the moved lender's one-based index as `slot+1`, skips the move when removing the tail, and cannot alias the removed lender. Could not construct a sequence breaking density, duplicating, or orphaning an index; existing `test_placement_limits.cairo` coverage is genuine.
4. **Cross-contract allowlist read — safe re-entry surface.** The reentrancy guard is entered before `factory.is_authorized` and before `transfer_from`, and is shared across `deposit`/`withdraw`/`borrow`/`repay`; `is_authorized` is a pure map read. Fails closed as a liveness dependency. Griefing is bounded to blocking deposits, never withdrawals.
5. **`verify_loan_inclusion` — reasoning holds.** Because the leaf is built internally from four components while nodes hash two, presenting an internal node as a leaf requires a Poseidon second-preimage. Sorted-pair construction is sound. Explicit leaf/node domain tags would be defense-in-depth, not required. Contract holds no funds.
6. **Lifecycle — no trap, no second borrow.** `borrow` requires `Active` and is one-shot; every terminal state leaves withdrawal open; `expire` is only reachable after the deadline (when `borrow` is already impossible).

## Findings (all Low / Informational — none block mainnet)

- **[Low] `Defaulted` is terminal and irreversibly blocks `repay`.** Once the factory calls `mark_defaulted`, the founder can no longer `repay`, so a later recovery cannot be distributed on chain — no cure path. Funds already in the pool stay fully withdrawable, so nothing is trapped, but *not* defaulting is strictly better for lenders than defaulting honestly, which is the wrong incentive. (This item was the basis for the subsequent code change reviewed on 2026-08-19.)
- **[Low] `repay`/`deposit` transfer before final state writes (interaction-before-effect).** Safety rests entirely on the correctly-placed reentrancy guard. Fine today, but the ordering is load-bearing; a refactor that moves a transfer outside the guard would reintroduce a real bug.
- **[Info] Pro-rata truncation strands sub-cent dust** permanently in the pool (a few micro-USDC). No lender loss beyond rounding.
- **[Info] `initialize` allows `repayment_fee_bps` up to 10000 (100%)** while the factory's `set_fees` caps at 1000. Not reachable on mainnet (factory passes its capped value), but the two bounds should agree. (Fixed on 2026-08-19.)
- **[Info] Invariant 4 is breakable by a direct token donation.** A donation makes balance exceed `total_deposited`. Harmless — `borrow` only pulls `total_deposited`.
- **[Info] Trust anchor is `is_valid_pool`, not the pool class.** Anyone can deploy the `CreditPool` class directly and initialize it with `allowlist_enabled: false`; such a pool is not factory-registered. The off-chain app/indexer must surface only factory-registered pools.
- **[Info] `deploy.sh` class-hash parsing is positional** (`grep ... | head -1`); the `CREDIT_POOL_CLASS != FACTORY_CLASS` guard catches the worst case, but parsing the labeled field would be more robust.

## Invariants (AUDIT.md)

16 of 17 verified. Invariant 4 holds for the intended flow but is breakable-but-harmless by a direct donation. None found false in a way the authors would care about.

## Out of scope

The design's real risk is off-chain and by explicit assumption: the founder can borrow and never repay (credit risk, no on-chain collateral), and the factory owner / compliance officer are trusted. Those are where the money risk lives, and no amount of Cairo correctness changes that.
