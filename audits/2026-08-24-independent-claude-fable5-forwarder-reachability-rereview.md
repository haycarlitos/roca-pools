# Delta re-review — factory forwarders, and a systematic reachability sweep

- **Date:** 2026-08-24
- **Reviewer:** Independent adversarial review, AI-assisted (Claude Fable 5)
- **Type:** Focused adversarial re-review of an access-control change, plus a full reachability sweep of all three contracts
- **Delta:** `7662a42 → 5e313ed`, reviewed at `079d3cd`. `+32` in `src/interfaces/i_pool_factory.cairo`, `+28` in `src/pool_factory.cairo`, `+168` in `tests/test_factory.cairo`. No other `src/` change.
- **Evidence:** `tests/audit_reachability_5e313ed.cairo`, `tests/audit_prorata.cairo` (both added by this review; passing). 139 tests pass at `079d3cd`, up from 132.

This is not a full re-audit. It reviews `5e313ed` and states whether the 2026-08-18 verdict ("ready to declare, no Critical or High") still stands. It also closes a gap the two prior reviews left open, and which is the reason `5e313ed` had to exist at all.

## Why this review exists

`CreditPool::unpause` and `CreditPool::mark_defaulted` assert `caller == self.factory.read()`. The factory contract had **no function that called into a pool**, so neither entrypoint had any possible caller: the factory's *owner* is not the factory, and an owner calling the pool directly reverts.

For `unpause` that was not a missing feature but a permanently frozen pool. A founder may pause unilaterally (`caller == founder || caller == factory`) while only the factory may lift it, so any paused pool would have stayed paused forever with deposit, borrow and repay dead. Withdrawal stays open by design, so lenders could still exit — but the pool was finished.

**Two prior audits missed this and 132 tests passed over it.** The cause is structural and worth naming, because it generalises: every test reached these entrypoints by cheating the caller address to a `FACTORY()` constant against a bare pool. That proves the assert fires. It says nothing about whether any real on-chain caller can satisfy it. `test_factory_can_unpause` passed while the path was unreachable in production.

The lesson for future reviews of this codebase: **access control that is correct but unreachable is still a defect, and a passing test is not evidence that a path is reachable.** For every privileged entrypoint, name the concrete on-chain address that can call it and trace how it gets there.

## Verdict on `5e313ed` — ship

`5e313ed` adds three owner-gated forwarders — `unpause_pool`, `pause_pool`, `mark_pool_defaulted` — each asserting `assert_only_owner`, then `_assert_own_pool`, then dispatching into the pool. Four properties were examined adversarially:

- **`_assert_own_pool` cannot be poisoned.** `is_valid_pool.write` appears exactly once in the codebase (`src/pool_factory.cairo:249`), inside `create_pool`, against the address `deploy_syscall` just returned. It is write-once, never cleared, and never settable by an argument. An owner cannot point a forwarder at an arbitrary contract. Covered by `test_forwarder_refuses_a_foreign_pool`.
- **The forwarders move no funds.** They write `paused` and `status` only. Neither is an input to `_calculate_withdrawal`, whose only inputs are `total_deposited` and `total_repaid`. So the new owner authority cannot alter any lender's entitlement.
- **The inviolable property holds.** `withdraw` does not read `paused` — its only guards are `position.deposited > 0` and `withdrawal_info.available > 0`. An owner who pauses a pool through the new path cannot trap a lender. Proven on the real path by `test_withdrawal_survives_an_owner_pause_through_the_factory`.
- **No reentrancy is introduced.** The three forwarded pool functions make no external calls: `pause` and `unpause` write storage and emit; `mark_defaulted` reads storage and calls `_set_status`. The factory holds no state across the dispatch. There is no window to re-enter.

The pool also keeps deciding *when* an action is permissible; the forwarder only decides *who* may ask. `test_forwarder_does_not_bypass_the_pool_own_rules` asserts a premature default still reverts with `Pool not borrowed`.

**Nothing in this diff rises to Critical, High, or Medium.** The 2026-08-18 verdict stands at `079d3cd`.

## Reachability sweep — all three contracts

The deliverable the two prior reviews lacked. Every caller gate in `src/`, with the concrete address that can satisfy it. 22 gates total.

| Contract | Entrypoints | Gate | Who can actually call it | Reachable |
|---|---|---|---|---|
| `credit_pool` | `borrow`, `repay`, `lower_rate`, `activate`, `cancel` | `caller == founder` | The founder set at `initialize` — in production the 2-of-3 multisig | Yes |
| `credit_pool` | `pause` | `caller == founder \|\| caller == factory` | Founder directly; factory via `pause_pool` | Yes |
| `credit_pool` | `unpause` | `caller == factory` | **Only** via `PoolFactory::unpause_pool` | Yes — **as of `5e313ed`; previously unreachable** |
| `credit_pool` | `mark_defaulted` | `caller == factory` | **Only** via `PoolFactory::mark_pool_defaulted` | Yes — **as of `5e313ed`; previously unreachable** |
| `credit_pool` | `expire` | permissionless by design | Anyone, after the funding deadline | Yes |
| `credit_pool` | `deposit`, `withdraw` | lender-facing; `deposit` additionally checks `factory.is_authorized` | Any allowlisted address / any lender with a position | Yes |
| `credit_pool` | `initialize` | one-shot, re-init guarded | The factory, inside `create_pool` | Yes |
| `pool_factory` | `set_fees`, `set_platform_wallet`, `set_pool_class_hash`, `pause`, `unpause`, `set_compliance_officer`, `unpause_pool`, `pause_pool`, `mark_pool_defaulted`, `transfer_ownership` | `assert_only_owner` | The factory owner | Yes |
| `pool_factory` | `set_lp_authorization`, `set_lp_authorization_batch` | `_assert_only_compliance` | The compliance officer; the owner holds the role until delegated | Yes |
| `pool_factory` | `create_pool` | permissionless, `assert_not_paused` | Anyone — caller becomes founder | Yes (see Low-1) |
| `audit_registry` | `register_batch` | `servicers[caller]` | The owner, seeded as a servicer in the constructor | Yes |
| `audit_registry` | `set_servicer` | `assert_only_owner` | The registry owner | Yes |

**Result: `unpause` and `mark_defaulted` were the only two orphaned entrypoints, and both are now reachable.** Nothing else in the codebase has a gate no address can satisfy.

`AuditRegistry`'s constructor seeds the owner as a servicer with the comment "the registry is never deployed into a state where nothing can be anchored" — the author had already reasoned about this exact failure mode there. The gap was specific to the pool/factory boundary.

## Findings

- **[Low, pre-existing — not introduced by this diff] The allowlist is factory-wide while `create_pool` is permissionless.** Anyone may call `create_pool` and becomes that pool's founder, and `is_authorized` is checked against the *factory*, not against the specific pool. So an investor allowlisted for a legitimate placement is, on chain, equally authorized to deposit into a pool deployed by a stranger — who can then `borrow` the balance and never repay. The contracts contain nothing that distinguishes a Roca-curated pool from a rogue one. **Contained entirely off chain**, by the fact that investors reach pools through Roca's product rather than by address. Worth stating plainly because the on-chain surface does not enforce what the product implies. A per-pool allowlist, or gating `create_pool` on the owner, would close it; both are design changes, not fixes to this diff.
- **[Low] The owner can pause a `Defaulted` pool and block recovery repayment.** `pause_pool` is not restricted by status, and `repay` is pause-gated, so an owner can stop a recovery from reaching lenders. Withdrawal stays open throughout, so nothing already earned is trapped, and the owner is trusted by construction. This is griefing, not theft, and it applies equally to the pre-existing founder-side `pause`. Recorded because the new forwarder makes it reachable by a second party.
- **[Informational] Reentrancy is unreachable today, but rests on the pool class being honest.** The claim "the forwarders introduce no reentrancy" depends on the deployed `CreditPool` making no external calls in the three forwarded functions, which is true of the audited class. A malicious class installed via `set_pool_class_hash` would invalidate it — but that is already inside owner trust and would be catastrophic by many other routes first. No action; noted so the assumption is written down rather than assumed.

## An interaction nobody had documented

**Pausing the factory does not freeze deposits into existing pools.**

`PoolFactory::pause` engages the `Pausable` component, and `create_pool` calls `assert_not_paused` — so no new pools can be deployed. But `is_authorized` is a plain view (`self: @ContractState`) with no pause gate, and `CreditPool::deposit` reads it as a view. Existing pools therefore keep taking deposits with the factory fully paused.

This is the correct behaviour: a factory-level brake should stop new issuance without freezing capital already committed to a live placement, and freezing deposits would strand a pool mid-funding. It is recorded here because it is the opposite of what most readers assume "pause the factory" means, and someone will assume the opposite during an incident. **To stop deposits into a specific pool, use `pause_pool`. Pausing the factory is not a substitute.**

## What could not be verified

Stated explicitly, because a review that only lists what it checked overstates its own coverage.

1. **That `owner` is genuinely the 2-of-3 passkey multisig.** Every "the owner is trusted" argument above — including the disposition of both Low findings and the Informational one — rests on this. It is a deployment fact, not a property of the source: the constructor accepts any address. Verifying it requires reading the owner address off the deployed factory and confirming it against the multisig, after deployment. **Until that is done, the owner-trust assumption in this report is unverified.**
2. **Token-level behaviour of real USDC.** These tests use a mock ERC-20. Circle's USDC carries a blocklist, and a blocked lender's `withdraw` would revert inside the token transfer even though the pool logic permits it. That would breach the "withdrawal is never blocked" property from the lender's point of view, by a mechanism entirely outside these contracts and outside Roca's control. Worth knowing; not fixable here.
3. **The off-chain curation that contains Low-1.** The severity assigned above assumes investors only ever reach pools through Roca's product. That is a claim about the application and its operations, not about the contracts, and this review has no evidence for it either way.

## A note on the lineage

While this review was being wired up, `main` sat red for four days. A stale test — `test_full_recovery_after_default_flips_status_to_completed` — was rebased onto the `fffb6d8` fix and pushed without re-running the suite, so it asserted the old `Defaulted → Completed` behaviour against code that had deliberately stopped doing that. The test was correct when written and became wrong under its own fix.

Fixed in PR #3 (renamed to `test_full_recovery_after_default_stays_defaulted`) and cited in invariant 9 via PR #4.

It is recorded here because this file's stated purpose is publishing the unflattering version, and "our own regression suite was red while we were auditing the thing it guards" is exactly that. It also rhymes with the defect this review exists to close: in both cases a green-or-ignored test was treated as evidence about code it was no longer describing.

## Bottom line

`5e313ed` is safe to ship. It restores two entrypoints that no address could reach, adds one genuinely new owner capability (`pause_pool`) that moves no funds, and cannot be pointed at a contract this factory did not deploy. The inviolable property — withdrawal is never blocked — holds on the newly reachable path and is now proven there rather than assumed.

The reachability sweep found no further orphaned entrypoints, which is the more useful result: the class of defect that got through two audits has now been checked systematically rather than incidentally.

The 2026-08-18 "ready to declare" stands, with the standing caveat that no independent external audit by a human firm has been performed, and with the owner-identity check in "What could not be verified" outstanding until deployment.
