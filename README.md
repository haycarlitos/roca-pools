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

## How a pool works

```
PoolFactory.create_pool(cap, rate_bps, duration, interval, deadline, data_room)
        │  whoever calls becomes the pool's `founder`
        ▼
CreditPool (one per partner company)
  LPs:      deposit(amount)            → pro-rata position, until cap / deadline
  Founder:  borrow()                   → draws capital to fund payroll loans
            repay(amount)              → returns principal + yield as repayments land
  LPs:      withdraw()                 → principal + accrued yield, as capital frees
  Lifecycle: activate / cancel / expire / pause / unpause · lower_rate
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
in that order. Order matters — the factory clones pools from the class hash it
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
sweep — the pools keep working on chain, but the app stops seeing them.

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
