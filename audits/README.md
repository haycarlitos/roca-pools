# Audits

Every security review of these contracts lives here, each alongside our
response. New reports append to the table chronologically, oldest first.

Reports are published whether or not they are flattering. A findings list that
only appears once it is closed is a marketing artifact.

| Date | Reviewer | Type | Report | Response | Findings |
|---|---|---|---|---|---|
| 2026-08-18 | Roca, AI-assisted (Claude Opus 5) | Internal pre-audit self-review | [`../AUDIT.md`](../AUDIT.md) | Fixed in the same cycle, before any investor funds | 2 High + 1 Medium, all closed |
| 2026-08-18 | Roca, AI-assisted | Cross-codebase finding replication | [`../docs/audit-mapping.md`](../docs/audit-mapping.md) | Both defects fixed same day | 2 found in new code |
| 2026-08-18 | Independent, AI-assisted (Claude Fable 5) | Full on-chain review | [`2026-08-18-independent-claude-fable5-full-review.md`](2026-08-18-independent-claude-fable5-full-review.md) | Ready to declare; 1 Low acted on (see next row) | 0 Critical/High, 2 Low, 5 Info |
| 2026-08-19 | Independent, AI-assisted (Claude Fable 5) | Delta re-review (repay after default) | [`2026-08-19-independent-claude-fable5-defaulted-repay-delta.md`](2026-08-19-independent-claude-fable5-defaulted-repay-delta.md) | Verdict holds; invariant 9 wording to be corrected | 0 Critical/High, 1 Low, 2 Info |

**No independent external audit by a human firm has been performed.** The reviews
above are AI-assisted, adversarial, and published in full regardless of outcome,
but they are not a substitute for a paid external audit. Anyone describing these
contracts as audited is overstating it, and that includes us.

## Status

Three findings from the internal review, all closed:

1. **High** — `total_deposited` was not decremented on withdrawal, so a
   pre-borrow exit made `borrow` revert permanently and killed the vintage.
   Reproduced by a failing test before the fix.
2. **High** — `deposit` had no authorization. Closed by a factory-level
   allowlist that every pool reads.
3. **Medium** — no investor cap and no minimum ticket. Closed together with
   roster slot release, because a minimum ticket does not bind on its own.

Two further defects surfaced by replicating the
[`shhh-wallet-cairo`](https://github.com/haycarlitos/shhh-wallet-cairo) finding
list against our code, both in `AuditRegistry`, both fixed the day it was
written:

- An unbounded Merkle proof loop over caller-supplied data.
- An interface that accepted a precomputed leaf, letting an internal node be
  presented as a leaf and verify against a truncated proof.

## Method

Three passes, in order:

1. **Invariants written down first**, including ones nobody had stated. One of
   them turned out to be false, which is how the accounting bug was found.
2. **Cross-codebase replication.** Every finding from the six reviews of
   `shhh-wallet-cairo` walked against these contracts, applicable or not, with
   the reason recorded either way. See
   [`../docs/audit-mapping.md`](../docs/audit-mapping.md).
3. **Standards mapping.** [OWASP Smart Contract Top 10
   2026](https://scs.owasp.org/sctop10/), category by category, including the
   three that do not apply and why. See
   [`../docs/owasp-scs-top10.md`](../docs/owasp-scs-top10.md).

Regression tests were written **before** the fixes and observed to fail. The
failure text is recorded in `AUDIT.md` so a reviewer can confirm the bug was
real rather than take our word that it was.

## What we want from an external audit

Scope: `CreditPool`, `PoolFactory`, `AuditRegistry`, plus the deployment
scripts.

Named starting points, in priority order:

1. Pro-rata withdrawal arithmetic with multiple lenders, partial repayment and
   uneven deposit timing. Our weakest area and least adversarially tested.
2. Whether the accounting fix has consequences in the `Defaulted` and `Expired`
   paths that we missed.
3. The swap-and-pop roster deregistration, where a wrong index write corrupts
   lookups for an unrelated investor rather than failing loudly.
4. The cross-contract allowlist read on the deposit path, as a re-entry and
   liveness surface.
5. `AuditRegistry.verify_loan_inclusion`: the sorted-pair Poseidon construction
   and whether explicit leaf/node domain separation is warranted on top of the
   component-based leaf construction.

## Naming

`YYYY-MM-DD-<reviewer>-<medium>.md`, with the response letter in `../docs/`.
