# What the contracts do with your money

Written for investors, not engineers. If you want the technical version, read
[`../AUDIT.md`](../AUDIT.md).

## What you are actually buying

You lend pesos to Roca. Roca lends those pesos to employees of companies it has
an agreement with, and the employees repay through payroll deduction. Your
return comes from the interest on those loans.

The contract in this repository is the **cash register**, not the loan. It
records who put money in, how much came back, and what each investor is owed.
The loans themselves are ordinary Mexican credit agreements, on paper, enforced
in Mexican courts.

**Your legal claim is against Roca**, under the instrument you signed. It is not
a claim on the software, on any specific borrower, or on the pool. If Roca fails
to pay, your recourse is the contract you signed, not this code.

## What the software guarantees, and what it does not

**It does guarantee:**

- Nobody can withdraw money they did not put in. Your share is calculated from
  what you deposited and what has been repaid, and no one can edit it.
- Roca cannot take more than the pool holds. Roca draws the money once, at the
  start, and the amount is fixed by what investors actually deposited.
- You can always take out what you are owed. There is no state, including an
  emergency freeze, in which withdrawal is blocked. See "the pause" below.
- Only approved investors can put money in. Every deposit is checked against a
  list Roca maintains.

**It does not guarantee:**

- **That you get your money back.** If borrowers stop paying, there is less to
  distribute. The software records that faithfully; it does not prevent it.
- **That Roca repays.** The contract cannot force it. It records a default when
  one happens and nothing more.
- **That the peso holds its value against the dollar.** Loans are in pesos, the
  pool is in dollars, and the exchange rate moves.

Anyone who tells you a smart contract removes credit risk is describing
something other than this.

## The pause, and why it cannot trap you

Roca can freeze a pool. Freezing stops new deposits and stops Roca drawing or
repaying.

**Freezing does not stop withdrawals.** That is deliberate and it is enforced by
the code, not by policy: the withdrawal path has no pause check in it, and a
test fails the build if anyone adds one. A freeze is for stopping new exposure,
never for holding onto your money.

The same is true if Roca removes you from the approved investor list. You cannot
put more in. You can always take out what is there.

## What we got wrong, and how you would know

A pool that has been fully funded and then partially withdrawn from, before Roca
draws the money, could end up unable to start at all. Investors would have got
every peso back through the normal exit, but the pool would have been dead.

We found it ourselves, before any investor money was in a pool, and fixed it. It
is written up in full as "known issue 1" in [`../AUDIT.md`](../AUDIT.md),
including the test that reproduces the failure.

We are telling you this because a project that reports no bugs has either found
none or is not saying. The first is rare. You should expect the list to keep
growing, and you should expect to be able to read it.

## How to check any of this yourself

You do not have to take our word for it, and you do not need to read Cairo.

**Your position:** every deposit, withdrawal and repayment is a public record on
Starknet. Ask Roca for the pool address and you can see the full history on
[Starkscan](https://starkscan.co), including money you did not send.

**The rules:** this repository is public. The contracts deployed on Starknet are
built from this source with a pinned compiler, so the code you read is the code
that runs.

**The tests:** every rule above has a test. They run on every change, and a
change that breaks one cannot merge.

**What has not been reviewed:** we have not yet had an independent external
audit of these contracts. That is scheduled and it has not happened. Anyone
presenting this as audited is overstating it, including us if we ever do.

## What we do not put on the public record

No borrower name, tax ID, salary, or individual loan amount is ever written to
the blockchain. What goes on chain is the total, plus a cryptographic
fingerprint that lets an auditor confirm a repayment matches a real bank
transfer without revealing who paid what.

That is a deliberate trade. Investors get proof that the money moved. Borrowers
keep their financial life private. Neither is sacrificed for the other.

## Questions worth asking us

If you are evaluating this, these are the questions we would want you to ask,
and we should be able to answer all of them in writing:

1. Has an independent auditor reviewed the contracts? Which one, and can I read
   the report and your response?
2. Who controls the keys that can pause a pool or change the investor list, and
   what happens if that person is unavailable?
3. What happens to my money if Roca stops operating tomorrow?
4. How is the peso-dollar exchange rate handled, and who bears that risk?
5. What is the maximum number of investors in a pool, and why that number?
