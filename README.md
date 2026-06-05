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

LP app (production): https://rocabeneficios.vercel.app — investors
onboard with a **passkey** (no seed phrase, no gas) via
[Chipi](https://chipipay.com) wallet infrastructure.

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
  transaction — LP positions are verifiable on Starkscan, not in a
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

```bash
# scarb 2.11.x · starknet-foundry 0.53.x
scarb build
snforge test
```

## What's not in this repo

The lending platform that operates on top of these contracts
(underwriting, company agreements, payroll integration, loan servicing,
and the LP application: passkey onboarding, guardian recovery, multisig
treasury console) is proprietary. This repository is the complete
on-chain layer: everything an LP's funds actually touch.

## License

MIT
