# What happens to your money

Written for investors, not engineers. The technical version is
[`../AUDIT.md`](../AUDIT.md).

---

## 1. What you are actually buying

You lend dollars to Roca under a mutuo agreement: a fixed-term loan contract
with a fixed rate, denominated in dollars. Roca owes you your capital plus
that rate. That obligation does not depend on how any individual borrower
performs.

Roca uses those funds to lend pesos to employees of companies it has an
agreement with, and the employees repay through payroll deduction, collected
before the money ever reaches their account. That portfolio is Roca's asset
and Roca's risk. Payroll-deducted credit is among the most reliably collected
forms of lending there are, which is why Roca can carry that risk and still
owe you a fixed rate.

The contract in this repository is the **cash register**, not the loan. It
records who put money in, how much came back, and what each investor can
withdraw. Your obligation lives in the mutuo you sign.

**Your legal claim is against Roca**, under that mutuo. It is enforceable in
court like any formal credit, and it can be resolved through arbitration: an
arbitral award is enforceable in more than 170 countries under the New York
Convention. If Roca fails to pay, your recourse is that instrument, and it is
a strong one.

---

## 2. The journey, step by step

### Step 1: Your wallet

Roca creates a wallet for you inside the app. You do not need to know
anything about crypto, and you never hold a volatile asset: the pool is
denominated in USDC, a dollar token.

**The key is yours, not ours.** It is encrypted in your browser using a key
derived from a passkey, the same Face ID, Touch ID or Windows Hello you
already use. Roca never sees it and **cannot sign on your behalf**, which is
the point: we cannot move your money even if we wanted to, even if compelled.

The consequence is the honest half. **If you lose the passkey and have not
set up recovery, the wallet is gone.** Nobody can restore it. That is why the
app pushes you to enrol a recovery backup before your wallet holds anything
worth losing: a guardian key, held by Roca, that can only START a recovery.
It cannot move funds, and every recovery is timelocked 24 hours so you can
see it happening and cancel it. If you would rather not have Roca hold a
guardian key, say so; you then accept that losing the passkey is final.

### Step 2: Identity verification

You verify your identity through **didit**, an independent provider. You
upload your document and take a selfie on their system.

**Roca never receives your documents.** We receive a yes or no, and a
reference number. Your passport photo, your ID scan and the biometric check
live with the provider, not with us and not on any blockchain.

The same check screens against sanctions and politically-exposed-person
lists. That is a legal requirement, not a judgment about you.

### Step 3: Approval

Passing identity verification does not automatically let you invest. Roca
still has to accept you into the placement, which is a human decision made
against the offering's own rules.

These two steps are separate on purpose. The provider decides whether you
are who you say you are. Roca decides who may participate. Collapsing them
would make a software vendor the gatekeeper of a regulated offering.

### Step 4: Review and deposit

Once approved, your address is added to an on-chain list. Only addresses on
it can deposit.

You will see the pool's terms before you commit: size, rate, term, payment
interval, funding deadline, minimum ticket and the maximum number of
investors. **None of those can be changed after the pool is created.** Not
by Roca, not by anyone. There is no administrative key that can alter a live
pool.

If two investors go for the last available slice at the same time, one lands
and the other's transaction reverts. The one who misses out **keeps their
money**; the failure is atomic, so nothing leaves their wallet.

### Step 5: While the pool runs

Roca draws the full balance once, converts it to pesos, and lends it out. As
payroll collects each period, the pesos are converted back to dollars and
paid into the pool. The pool distributes what arrives in proportion to what
each investor deposited; what Roca owes you in total is set by your mutuo.

You can withdraw whatever is available to you at any time. You do not have
to wait for the term to end.

---

## 3. What the software guarantees

- **Nobody can withdraw money they did not put in.** Your share is computed
  from your own deposit and the payments received, and nobody can edit it.
- **Roca cannot take more than the pool holds.** The draw happens once and is
  fixed at the amount investors actually deposited.
- **You can always take out what is available to you.** There is no state,
  including an emergency freeze, in which withdrawal is blocked.
- **Only approved investors can deposit.**
- **The terms cannot change** after the pool is created.

## What backs the rest

The software keeps the register. The mutuo carries the obligation:

- Roca owes you your capital plus a fixed rate, in dollars. Individual
  borrower performance is Roca's risk, not yours.
- The exchange rate is Roca's risk, not yours. Your mutuo is denominated in
  dollars; Roca converts to pesos and back, and carries the movement in
  between.
- The mutuo is enforceable in court and arbitrable internationally under the
  New York Convention.

What no contract can remove is counterparty risk: that Roca itself pays.
Roca's capacity to pay depends on its portfolio, and if collections
deteriorate badly enough, so does that capacity. The software records that
faithfully; it does not prevent it. Anyone who tells you a smart contract
removes counterparty risk is describing something other than this.

---

## 4. The questions worth asking

### What if I lose my phone?

If you enrolled a recovery backup, you start a recovery and get access back
after the 24-hour window. If you did not, the wallet is unrecoverable. This
is the single most important thing to get right at the start, and it takes
about a minute.

### What if Roca disappears tomorrow?

Two cases, and the answer is better than you might expect.

**Before Roca draws the money:** you can get everything back **without any
cooperation from Roca at all.** Withdrawal requires only your own signature.
If the funding deadline has passed and nobody has done anything, any person
on earth can trigger the pool's expiry, which opens the exit for everyone.
There is no step that requires a Roca employee to be alive, willing, or
reachable.

**After Roca draws the money:** the pesos are out in real loans. The pool
distributes whatever repayments arrive, and your claim for the rest is
against Roca under the mutuo you signed: enforceable in court, arbitrable
internationally. Your recourse is legal rather than technical. No software
design changes that.

### Can Roca freeze my money?

Roca can freeze a pool, which stops new deposits and stops Roca drawing or
repaying. **It does not stop withdrawals**, and that is enforced by the code
rather than by policy: the withdrawal path contains no freeze check, and a
test fails the build if anyone adds one.

The same holds if Roca removes you from the approved list. You cannot add
more. You can always take out what is there.

### Who else can see my investment?

Every deposit, withdrawal and repayment is public on Starknet, tied to a
wallet address. The address is not your name, but anyone who learns it can
see that address's full history. If that matters to you, ask before you
deposit.

Your identity documents are not public and are not on the blockchain.

### What do you publish about the borrowers?

Nothing identifying. No name, tax ID, salary, employer or individual loan
amount is ever written to the blockchain.

What goes on chain is the total plus a cryptographic fingerprint, which lets
an auditor confirm that a repayment matches a real bank transfer (the CEP
receipt Banxico issues for every SPEI) without revealing who paid what.
Investors get proof the money moved; borrowers keep their financial life
private.

### Has this been audited?

**Not by an external firm yet**, and we will not describe internal work as
if it were. What exists today: AI-assisted audits, more than 120 automatic
tests that run on every change, systematic replication of another project's
audit findings against this code, and a mapping against the OWASP Smart
Contract Top 10. The full report is [`../AUDIT.md`](../AUDIT.md).

An external audit is planned. Ask us where it stands; if anyone tells you
these contracts carry an external audit today, they are wrong.

---

## 5. What we got wrong

A pool that had been funded and then partially withdrawn from, before Roca
drew the money, could end up unable to start at all. Every investor would
have got every peso back through the normal exit, but the pool would have
been dead.

We found it ourselves, before any investor money was in a pool, and fixed
it. The full write-up is "known issue 1" in [`../AUDIT.md`](../AUDIT.md),
including the test that reproduces the failure.

Two more were found the same week by taking another project's published
audit findings and checking whether we had made the same mistakes. We had,
twice, in code written days earlier.

We tell you this because a project reporting no bugs has either found none
or is not saying. Expect the list to keep growing, and expect to be able to
read it.

---

## 6. How to check any of this yourself

You do not need to take our word for it, and you do not need to read code.

**Your position.** Ask Roca for the pool address. Paste it into
[Starkscan](https://starkscan.co) and you will see every deposit, withdrawal
and repayment, including transactions we did not tell you about.

**The rules.** This repository is public. The contracts on Starknet are
built from this source with a pinned compiler, so the code you can read is
the code that runs.

**The tests.** Every guarantee in section 3 has a test. They run on every
change and a change that breaks one cannot be merged.

**What is not yet true.** The pools live on Starknet today were deployed
before the investor allowlist, the investor cap and the minimum ticket
existed, and they cannot be upgraded to include them. Those protections
apply to pools created from the new contracts. Ask which class your pool was
deployed from.

---

## 7. Five questions to ask us in writing

1. Has an independent external auditor reviewed the contracts? Which firm,
   and may I read the report and your response?
2. Who holds the keys that can pause a pool or change the investor list, and
   what happens if that person is unavailable?
3. Which contract class is my pool deployed from, and does it enforce the
   investor allowlist on chain?
4. Confirm in writing that my mutuo is dollar-denominated at a fixed rate,
   and that the peso-dollar conversion risk between collection and repayment
   sits with Roca.
5. What is the maximum number of investors in this pool, and how was that
   number chosen?

We should be able to answer all five in writing. If we cannot, that is
information too.
