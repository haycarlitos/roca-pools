# RoCa Pools: payroll-collateralized lending, funded on-chain

Cairo smart contracts powering **RoCa Beneficios**' on-chain funding:
USDC pools on **Starknet mainnet** that fund payroll-secured loans for
formal employees in Mexico.

> **The collateral is a salary, not a token.** RoCa signs with the
> *employer*; loan repayment is deducted from payroll by the company
> itself, before the worker is ever paid. 15 years operating,
> 91 partner companies, 100% company retention.

## Live on mainnet

| Contract | Address |
|---|---|
| PoolFactory | [`0x070bd23697b102a152f6d9c322a795cd42466c43d106a420a2d8d3e046cc2673`](https://starkscan.co/contract/0x070bd23697b102a152f6d9c322a795cd42466c43d106a420a2d8d3e046cc2673) |
| USDC (Starknet) | [`0x033068f6539f8e6e6b131e6b2b814e6c34a5224bc66947c47dab9dfee93b35fb`](https://starkscan.co/contract/0x033068f6539f8e6e6b131e6b2b814e6c34a5224bc66947c47dab9dfee93b35fb) |

LP app (production): https://rocabeneficios.vercel.app, where investors
onboard with a **passkey** (no seed phrase, no gas) via
[Chipi](https://chipipay.com) wallet infrastructure.


## Security and audit

| Document | For |
|---|---|
| [SECURITY.md](SECURITY.md) | Reporting a vulnerability. Scope, timelines, what counts. |
| [AUDIT.md](AUDIT.md) | Auditors. Invariants, findings, coverage, threat model. |
| [audits/](audits/) | Every review and our response, published whether or not it flatters us. |
| [docs/audit-mapping.md](docs/audit-mapping.md) | Findings from another codebase's audits, walked against ours. |
| [docs/owasp-scs-top10.md](docs/owasp-scs-top10.md) | OWASP Smart Contract Top 10 2026, category by category. |
| [docs/for-investors.md](docs/for-investors.md) | Investors. What the code guarantees and what it does not. |
| [docs/compliance.md](docs/compliance.md) | Counsel and regulators. Enforced on chain vs human control. |

**No independent external audit has been performed.** Internal review only. Three
findings were found and fixed before any investor funds entered a pool, and two
more were found in new code by replicating another project's audit list. All are
documented with the tests that reproduce them.

## Architecture

Two contracts, plus a third that holds no funds.

```
                        ┌──────────────────────────────────────┐
   compliance officer ─→│             PoolFactory              │
                        │  · deploys pools (founder = caller)  │
                        │  · investor allowlist ───────────────┼──┐
   owner ──────────────→│  · fees, pool class hash             │  │ read on
                        │  · global pause                      │  │ every
                        └───────────────┬──────────────────────┘  │ deposit
                                        │ create_pool             │
                   ┌────────────────────┼────────────────────┐    │
                   ↓                    ↓                    ↓    │
        ┌────────────────┐   ┌────────────────┐   ┌────────────────┐
        │   CreditPool   │   │   CreditPool   │   │   CreditPool   │
        │    vintage 1   │   │    vintage 2   │   │    vintage 3   │
        └────────────────┘   └────────────────┘   └────────────────┘
              ↑     │
   deposit /  │     │ borrow, once, to the founder
   withdraw   │     ↓
        [ investors ]    [ pool founder ] ──→ off-chain: USDC to MXN,
                                              payroll lending, collection

        ┌────────────────────────────────────────────────────────┐
        │  AuditRegistry, holds no funds                         │
        │  anchors payroll batches to signed bank receipts       │
        └────────────────────────────────────────────────────────┘
```

**A pool is a funding round, not a product.** Its cap, rate, term, payment
interval, funding deadline, investor limit and minimum ticket are fixed at
creation and can never be changed. Only the rate can move, downward, and only
before the money is drawn. Changing any other term means creating a new pool.

**The allowlist lives on the factory, not on each pool.** That is deliberate:
revoking an investor after a sanctions hit has to be one transaction, not one
per pool per investor. The consequence is that every pool from a factory shares
one investor base, so two placements with different eligibility rules need two
factories. See [`docs/compliance.md`](docs/compliance.md).

**Nothing here can be upgraded.** No proxy, no `replace_class_syscall`. The
rules an investor read when they deposited apply for the pool's entire life. The
cost is that a bug in a live pool cannot be patched: it is paused, expired, and
replaced by a new class for new pools.

## Roles

Four distinct roles. They are separated rather than collapsed into an admin key
because they need different response times, different custody and, in one case,
a different person.

| Role | Can | Cannot |
|---|---|---|
| **Investor** | Deposit into a pool they are authorized for; withdraw their own position at any time | Touch anyone else's position or any pool setting |
| **Pool founder** | Draw the balance of *their* pool once, repay it, move it through its lifecycle | Touch another pool, the factory, or anyone's position. Set per pool at creation, as the caller of `create_pool` |
| **Factory owner** | Set fees, set the pool class for future deployments, pause the factory, appoint the compliance officer, transfer ownership | Touch a deployed pool or any funds inside one |
| **Compliance officer** | Authorize and revoke investors, individually or in batches of up to 50 | Change fees, the pool class, or the pause state. Cannot move funds |

### Why the compliance officer is separate from the owner

This is the one that needs explaining, because collapsing it into the owner
would be the obvious default.

The two keys have opposite operational profiles. Factory ownership is used
rarely and deliberately: set a fee, publish a new pool class, pause everything.
It is the right thing to keep in cold storage or behind a multisig with a
deliberate signing ceremony.

Investor authorization is the opposite. A sanctions hit, an expired
verification, an investor who must be removed today. Those need a key that
someone can reach within minutes, from wherever they are.

If those are the same key, one of two bad things is true: either the key that
can redirect fee revenue and swap the pool class is sitting somewhere reachable
in minutes, or a compliance action waits on a signing ceremony. Neither is
acceptable, so the roles are split.

Two properties follow, both tested:

- **Delegating removes the power.** Once the owner appoints a compliance
  officer, the owner can no longer authorize investors. It is a handover, not a
  second copy.
- **The officer cannot escalate.** They hold no authority over fees, the pool
  class, or the pause.

Until an officer is appointed the owner holds the role, so a freshly deployed
factory is never in a state where nobody can authorize anyone.

**What this role does not do.** It records a decision; it does not make one.
Identity verification, sanctions screening and the judgement about who may
participate all happen off chain. The officer's key is the last step that makes
an already-made decision effective on chain.

### Who holds what, in practice

The intended production split is two people: **one responsible for funds, one
for the whitelist.** They map to the keys as follows, and the mapping is worth
stating because only one of these keys can move money.

| Key | Held by | Can move investor funds? |
|---|---|---|
| **Pool founder** | Funds owner (a 2-of-3 multisig) | **Yes** — `borrow()` transfers the entire pool balance to the founder |
| **Factory owner** | Funds owner | No |
| **Compliance officer** | Whitelist owner | No |

The founder key is the one that must be a multisig. A single key that can call
`borrow()` on a funded pool can take the whole placement in one transaction.
The factory owner cannot: `platform_wallet` is frozen into each pool at
`initialize` and `repay` pays from the pool's own copy, and `set_pool_class_hash`
only affects pools deployed afterwards — so a compromised owner key can grief
(pause, mislabel) but cannot reach deposits.

Conversely the compliance key should **not** be a multisig. It exists to be
reachable in minutes; a signing ceremony defeats it.

**During a rehearsal one person holds every role.** That is deliberate and it
is safe for exactly one reason: the only money at risk is the operator's own.
The founder is fixed per pool at `create_pool` and can never be changed, so a
pool founded by a personal wallet is founded by that wallet forever — which
means the rehearsal pool must never be reused for real investor capital.

Authorization during a rehearsal runs through
[`scripts/authorize.sh`](scripts/authorize.sh), not the admin UI: the app
proposes this call through the multisig, which is correct for production and
unusable before a multisig exists.

## How a pool works

```
PoolFactory.create_pool(cap, rate_bps, duration, interval, deadline, data_room)
        │  whoever calls becomes the pool's `founder`
        ↓
CreditPool (one per vintage — many employers per pool)
  LPs:      deposit(amount)            → pro-rata position, until cap / deadline
  Founder:  borrow()                   → draws capital to fund payroll loans
            repay(amount)              → returns principal + yield as repayments land
  LPs:      withdraw()                 → principal + accrued yield, as capital frees
  Lifecycle: activate / cancel / expire / pause · lower_rate
  Owner (via factory): unpause_pool / pause_pool / mark_pool_defaulted
```

- `borrow`, `repay`, `lower_rate` and lifecycle transitions assert
  `caller == founder`.
- In production the founder is a **2-of-3 passkey multisig** (SHHH
  account on Starknet): no single person, including RoCa's own
  founder, can move pooled funds alone. Spend approvals expire in ~2h;
  owner-set and threshold changes carry 48h on-chain timelocks.
- Creation charges a fee of `min(cap × 1%, 199 USDC)` to the factory.
- Every deposit, borrow, repayment and withdrawal is a public mainnet
  transaction. LP positions are verifiable on Starkscan, not in a
  spreadsheet.

## Layout

```
src/
  pool_factory.cairo      # deploys + registers pools, creation fee
  credit_pool.cairo       # deposits, borrow/repay, pro-rata yield, lifecycle
  interfaces/             # i_pool_factory, i_credit_pool
  mocks/mock_erc20.cairo  # test token
tests/
  test_credit_pool.cairo  # core deposit/borrow/repay/withdraw math
  test_lifecycle.cairo    # status machine + deadline/cap edges
  test_pause.cairo        # pause semantics
```

## Build & test

Toolchain versions are pinned in `.tool-versions` (asdf/mise). They are not
cosmetic: a class hash is a function of the compiler version, so building
with a different Scarb produces a different class than the one deployed.

```bash
asdf install          # or: mise install
scarb build
snforge test
```

## Deploy

```bash
export STARKNET_RPC_URL=...          # never committed; ours carries an API key
./scripts/deploy.sh --dry-run --owner 0x... --platform-wallet 0x...
./scripts/deploy.sh --owner 0x... --platform-wallet 0x...
```

The script declares `CreditPool`, declares `PoolFactory`, then deploys the
factory with `(owner, platform_wallet, usdc_address, credit_pool_class_hash)`
in that order. Order matters: the factory clones pools from the class hash it
is constructed with, and `create_pool` is permanently bound to it for every
pool it creates. Re-declaring an already-declared class is treated as success,
so re-runs are safe.

Requires an `sncast` account named in `snfoundry.toml`, funded on the target
network.

### What the live factory was deployed with

Read back from `get_config()` on mainnet, for comparison after any redeploy:

| | |
|---|---|
| owner | `0x06152df0e70bedbf7c8256f9e26eda77ba8785db3d8b7dc545a62886f618d5c0` |
| platform_wallet | same as owner |
| usdc_address | `0x033068f6539f8e6e6b131e6b2b814e6c34a5224bc66947c47dab9dfee93b35fb` |
| credit_pool_class_hash | `0x07d50032f6d6d9e15b8a550d686c6737e2ecca2a51c9ee397235f946382502cc` |
| creation_fee_cap | 199 USDC |
| creation_fee_bps | 100 (1%) |
| repayment_fee_bps | 50 (0.5%) |

Fees are storage, not constants: `set_fees()` changes them on a live factory
with no redeploy. The values above are the constructor defaults, still
unchanged on mainnet.

### After deploying

A new factory starts with `pool_count = 0`, and the app reads a single
`NEXT_PUBLIC_POOL_FACTORY_ADDRESS`. Pointing it at a new factory makes every
existing pool invisible to pool discovery and to the indexer's reconcile
sweep. The pools keep working on chain, but the app stops seeing them.

Because `NEXT_PUBLIC_*` is inlined at build time, changing the address needs a
**rebuild**, not just a redeploy. Then regenerate the ABIs the app parses
against, which are dumped from the deployed class rather than hand-written:

```bash
npx tsx scripts/dump-abi.ts   # in the roca-beneficios repo
```

## What's not in this repo

The lending platform that operates on top of these contracts
(underwriting, company agreements, payroll integration, loan servicing,
and the LP application: passkey onboarding, guardian recovery, multisig
treasury console) is proprietary. This repository is the complete
on-chain layer: everything an LP's funds actually touch.

## License

MIT
