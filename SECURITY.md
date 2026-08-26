# Security Policy

## Scope

The contracts in `src/`, deployed to Starknet mainnet. There is no testnet
deployment: this project is mainnet only, deliberately.

| Contract | Mainnet |
|---|---|
| **PoolFactory (V2, current)** | `0x02a8ceba3ddea00f9b8137d7977a58b9e0a7ce28e065d02efb9694c4f850e9ac` |
| CreditPool (class, V2) | `0x07ec75b2685a7c5e712a3d9067d94305aa6d00d3ece70dfb4f00b7aef526f4af` |
| PoolFactory (class, V2) | `0x039086a75895b79304cb1a6fc4eeef4abc289b295b056463ba2383af3ee388bc` |
| PoolFactory (V1, superseded) | `0x070bd23697b102a152f6d9c322a795cd42466c43d106a420a2d8d3e046cc2673` |
| CreditPool (class, V1) | `0x07d50032f6d6d9e15b8a550d686c6737e2ecca2a51c9ee397235f946382502cc` |

V2 deployed 2026-08-26. Reports against either version are in scope; V1 is
still on chain and its pools still hold the invariants they were audited
under, but new work targets V2.

The off-chain application that reads and writes these contracts is a separate,
closed repository and is out of scope here.

## Reporting

Email **security@rocabeneficios.com** with a description, the affected contract,
and a reproduction if you have one. Please do not open a public issue for
anything that puts funds at risk.

| | |
|---|---|
| Acknowledgement | within 3 business days |
| Triage and severity | within 10 business days |
| Coordinated disclosure | 90 days, or sooner by agreement once a fix is live |

If a report affects live pools we will say so plainly, including whether funds
moved.

There is no bug bounty program. That is a statement of fact, not of how much a
report is worth to us.

## What is worth reporting

- Anything that lets an address withdraw funds it did not deposit
- Anything that permanently prevents a lender from withdrawing what they are owed
- Anything that lets a non-founder call `borrow`, `repay`, or a lifecycle transition
- Anything that lets a non-owner change factory configuration, or a
  non-compliance-officer change the investor allowlist
- Anything that lets a revoked investor be blocked from withdrawing
- Any reuse of an already-anchored bank receipt in the registry
- Accounting that diverges from a contract's actual USDC balance

The last one is the class that has already bitten us. See
[`AUDIT.md`](AUDIT.md) known issue 1.

## What is already known

Read [`AUDIT.md`](AUDIT.md) before reporting. Every finding we know about is
there with severity and status, including two we found in our own new code by
replicating another project's audit. A report that restates one is still
welcome; you will get a link rather than a surprise.

## Assurance status

**No independent external audit has been performed.** Internal review only, plus
systematic replication of the finding list from
[`shhh-wallet-cairo`](https://github.com/haycarlitos/shhh-wallet-cairo) and a
mapping against the [OWASP Smart Contract Top 10
2026](https://scs.owasp.org/sctop10/).

We state this in every document rather than in a footnote, because "reviewed"
and "audited" are different words and the difference is the entire value of the
second one.

## Operational notes

`pause()` blocks deposit, borrow and repay. **Withdrawals stay enabled while
paused**, deliberately: pausing is for stopping new exposure, never for trapping
lenders. Only the factory can `unpause`, so a compromised or absent founder
cannot lock a pool shut.

Revoking an investor's authorization blocks new deposits and **never** blocks
withdrawal, for the same reason. A compliance action that seizes funds is not a
compliance action.

Deployed pools are immutable. There is no upgrade path, so the response to a
discovered bug is pause, expire, let lenders exit, and deploy a corrected class
for new pools.
