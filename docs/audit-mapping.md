# Audit Finding Mapping

Findings from the security reviews of
[`shhh-wallet-cairo`](https://github.com/haycarlitos/shhh-wallet-cairo),
walked one at a time against these contracts.

Both codebases are Cairo, both hold user funds, both were written by the same
team. A finding on one names a **class** of mistake, and the cheapest moment to
check whether we made the same one is before an auditor bills for it.

The whole list is here, including the findings that do not apply, with the
reason. A mapping that only lists the convenient half is not evidence of
anything.

**Source reviews:** Henri / Nethermind AuditAgent (2026-04-13), Omar Espejel
(2026-04-20), and four internal adversarial passes (2026-05-07, 05-10, 05-12,
05-14).

## Legend

| | |
|---|---|
| **Replicated** | Same class exists here. Named regression test in `tests/audit_replication.cairo`. |
| **Found** | The check surfaced a real defect in our code, now fixed. |
| **N/A** | Cannot apply, with the structural reason. |

---

## Henri / Nethermind AuditAgent, 2026-04-13

| Finding | Verdict | Where |
|---|---|---|
| Unrestricted `__execute__` | **Replicated** | We have no account entrypoint, but the class is "a state-changing entrypoint missing its guard". Every one is enumerated: `test_omar_c1_*`. |
| Non-atomic multicall | **Replicated** | We never batch user calls, but the class is "a failed subcall silently tolerated". Every ERC20 result is asserted: `test_omar_h1_*`. |
| Dead upgrade component wired with no entrypoint | **N/A, deliberate** | We have no upgrade component and no `replace_class_syscall`. Deployed pools are immutable. This is documented as a limitation in `AUDIT.md`, not an oversight. |

## Omar Espejel, 2026-04-20

| Finding | Verdict | Where |
|---|---|---|
| **C-1** Public `__execute__` allows unsigned arbitrary calls | **Replicated** | `test_omar_c1_stranger_cannot_borrow`, `_lower_rate`, `_activate`, `_mark_defaulted`, `_pool_cannot_be_reinitialized`. The re-init test is the sharpest: a second `initialize` would rewrite the founder and hand the next `borrow` to a stranger. |
| **H-1** Subcall failures silently swallowed | **Replicated** | `test_omar_h1_deposit_without_approval_reverts_whole_call`, `test_omar_h1_failed_deposit_leaves_no_trace`. |
| **H-2** Advertises SNIP-9 V2, implements custom signing | **N/A** | We advertise no signing interface and implement no SRC-5 introspection. Nothing to mismatch. |
| **M-1** `caller == 0` treated as unrestricted | **Replicated** | `test_omar_m1_zero_founder_is_rejected`, `_zero_token_is_rejected`, `_zero_address_cannot_be_authorized`, `_zero_address_cannot_be_a_servicer`. |
| **M-2** No maximum validity window for bearer signatures | **N/A** | We hold no signatures. The nearest analogue is `funding_deadline`, which is bounded below (must be in the future) but deliberately not above: a long funding window is a commercial choice, and a pool that never fills expires harmlessly. |
| **M-3** No bounds on call count, calldata or signature length | **Found** | The authorization batch was already capped at 50 (`test_omar_m3_authorization_batch_is_bounded`, plus the boundary case at exactly 50). **`AuditRegistry.verify_loan_inclusion` looped over a caller-supplied Merkle proof with no ceiling.** Now capped at depth 32: `test_omar_m3_overlong_merkle_proof_is_refused_not_looped`. |
| **M-4** Signature span bounds and trailing bytes unvalidated | **Partially replicated** | No signatures here. The equivalent caller-supplied structure is the Merkle proof, covered by M-3 above and by the inclusion tests. |
| **L-1** Constructor accepts invalid input, deploys a bricked wallet | **Replicated** | `test_omar_l1_zero_cap_pool_is_rejected`, `_pool_born_expired_is_rejected`, `_incoherent_schedule_is_rejected`, `_pool_admitting_nobody_is_rejected`. |
| **I-1** Custom hash should be SNIP-12 or explicitly tagged | **N/A** | We hash no messages. The registry's Poseidon usage is documented at its definition. |
| **I-2** Missing negative test vectors | **Replicated** | Negative cases carry equal weight throughout, most explicitly in the registry: forged leaf, tampered amount, internal-node-as-leaf, replay from two angles. |
| **I-3** Upgradeable component wired but unused | **N/A** | Same as Henri's third finding. |

## Internal review, 2026-05-07

| Finding | Verdict | Where |
|---|---|---|
| **C-1** Guardian role is silently owner-equivalent | **Replicated** | `test_opus_c1_owner_loses_authorization_power_once_delegated` and `test_opus_c1_compliance_officer_does_not_gain_ownership`. Delegating compliance genuinely **removes** the power from the owner rather than sharing it, and the officer gains no config rights. |
| **H-1** `bootstrap_from_sessions` is front-runnable | **Replicated** | Our only permissionless entrypoint is `expire`. `test_opus_h1_expire_cannot_be_raced_before_the_deadline` and `test_opus_h1_permissionless_expire_only_opens_the_exit`: a stranger calling it gains nothing, and its single effect is to open the exit. |
| **H-2** JWT `sub` binding is anchorless | **N/A** | No identity claims are parsed on chain. |
| **H-3** Policy update silently resets the spent counter | **Replicated** | `test_opus_h3_changing_factory_fees_does_not_touch_live_pools`, `test_opus_h3_lowering_the_rate_does_not_disturb_accounting`. |
| **M-1** `add_owner` accepts a malformed pubkey | **N/A** | No key material is registered. |
| **M-2** Library-call verifier re-enters guarded mutators | **Replicated** | `deposit` makes a cross-contract call to the factory allowlist, which is a genuine re-entry surface. The reentrancy guard is entered first. `test_opus_m2_reentrant_withdraw_is_blocked` proves it with a token built to attack the pool paying it (`src/mocks/reentrant_erc20.cairo`). |
| **M-3** Regression suite missing mirrors for several findings | **Replicated as method** | This document plus `tests/audit_replication.cairo` exist because of that finding, and CI runs the suite as a separately named gate. |
| **L-1** Dead op-kind constants | **N/A** | No dead constants; `scarb build` is warning-free. |
| **I-1** Unreachable entrypoint should say so inline | **Adopted as practice** | Intent is commented at the code, not only in docs. |
| **I-4/5/6** Domain binding, replay protection, cancel-window arithmetic | **Partially replicated** | Replay protection maps directly: `test_registry_replay_across_different_batch_ids`, `test_registry_replay_by_a_second_servicer`. |

## Internal review, 2026-05-10

| Finding | Verdict | Where |
|---|---|---|
| **H-1** An incomplete fix left one path unvalidated | **Replicated as method** | The lesson is that a fix applied to one call site is not applied to the class. When `total_deposited` was fixed in `withdraw`, every reader of it was re-checked: `deposit`'s cap test, `borrow`'s transfer amount, and the pro-rata denominator. |
| **M-2** A second path missed the same validation | **Replicated as method** | Same as above. |
| **M-3** The negative regression test did not exist | **Replicated** | Both accounting regression tests were written **before** the fix and observed to fail. Failure text recorded in `AUDIT.md`. |

## Internal review, 2026-05-12 and 05-14

| Finding | Verdict | Where |
|---|---|---|
| **C-1** Missing binding gate let a stranger capture a stranded wallet | **Replicated as method** | The transferable lesson is that an adversarial pass over a self-authored change finds what self-review does not. That pass is what caught the unbounded Merkle proof and the internal-node-as-leaf weakness in our own new registry code. |
| **L-1** Truncated calldata accepted; downstream catch was fragile | **Replicated** | Length validated where it is read rather than relied upon downstream: the proof depth ceiling and the batch cap. |
| **INFO-1** Fix pattern not propagated to a sibling function | **Replicated as method** | See 05-10 above. |
| **INFO-2** `#[substorage(v0)]` collision risk across components | **Acknowledged** | We use OZ `OwnableComponent`, `PausableComponent` and `ReentrancyGuardComponent` with `#[substorage(v0)]`. We add no field whose name could collide with a component's, and no component here preserves a slot across versions the way their account did. Recorded so a reviewer can confirm rather than assume. |

---

## What this exercise actually found

Two real defects in code written the same day, both in the new `AuditRegistry`:

1. **Unbounded Merkle proof loop** (Omar M-3 class). A caller-supplied array
   iterated with no ceiling. Harmless from an off-chain read, a step-exhaustion
   vector the moment another contract calls it. Capped at depth 32.

2. **Internal node accepted as a leaf** (Omar M-4 / L-1 class). The interface
   took a precomputed leaf. With four leaves the root is `H(n01, n23)`, so
   passing `n01` with `[n23]` as proof recomputes the root exactly and returns
   true for something that is not a deduction. The interface now takes the
   leaf's components and builds the leaf itself, which turns the attack into a
   preimage problem.

Neither was found by writing tests for what the code should do. Both were found
by walking someone else's finding list and asking whether we had done the same
thing.
