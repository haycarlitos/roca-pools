//! Independent audit — pro-rata withdrawal verification.
//!
//! The authors name `_calculate_withdrawal` as their weakest, least-tested
//! area: several lenders, uneven deposits, partial repayments, interleaved
//! withdrawals, rounding at the boundaries. This drives exactly that and
//! asserts the two properties that matter:
//!
//!   (S) Solvency: at every step the pool's USDC balance equals
//!       total_repaid - (sum of all withdrawals). It is never negative, so a
//!       withdrawal transfer can never revert for lack of funds — the last
//!       withdrawer is never short.
//!   (N) No over-extraction: no lender's cumulative withdrawal ever exceeds
//!       floor(total_repaid * deposited / total_deposited), their exact
//!       entitlement, and the sum of all entitlements never exceeds
//!       total_repaid.
//!
//! These are PASSING tests. They document the property rather than an exploit.

use seedless_contracts::interfaces::i_credit_pool::{
    ICreditPoolDispatcher, ICreditPoolDispatcherTrait, PoolStatus,
};
use seedless_contracts::mocks::mock_erc20::{IMockERC20Dispatcher, IMockERC20DispatcherTrait};
use snforge_std_deprecated::{
    ContractClassTrait, DeclareResultTrait, declare, start_cheat_caller_address,
    stop_cheat_caller_address,
};
use starknet::{ContractAddress, contract_address_const};

const ONE_USDC: u256 = 1_000_000;
const DAY: u64 = 86400;
const PRECISION: u256 = 1_000_000_000_000_000_000;

fn FOUNDER() -> ContractAddress {
    contract_address_const::<'FOUNDER'>()
}
fn PLATFORM() -> ContractAddress {
    contract_address_const::<'PLATFORM'>()
}
fn L1() -> ContractAddress {
    contract_address_const::<'L1'>()
}
fn L2() -> ContractAddress {
    contract_address_const::<'L2'>()
}
fn L3() -> ContractAddress {
    contract_address_const::<'L3'>()
}

fn deploy_usdc() -> IMockERC20Dispatcher {
    let c = declare("MockERC20").unwrap().contract_class();
    let (a, _) = c.deploy(@array!['USDC', 'USDC', 6]).unwrap();
    IMockERC20Dispatcher { contract_address: a }
}

fn deploy_pool() -> ICreditPoolDispatcher {
    let c = declare("CreditPool").unwrap().contract_class();
    let (a, _) = c.deploy(@array![]).unwrap();
    ICreditPoolDispatcher { contract_address: a }
}

/// Pool with NO repayment fee, so total_repaid == gross repaid and the
/// solvency identity is exact.
fn init_pool(pool: ICreditPoolDispatcher, usdc: ContractAddress, rate_bps: u16) {
    pool
        .initialize(
            contract_address_const::<'FACTORY'>(),
            FOUNDER(),
            usdc,
            PLATFORM(),
            0, // repayment_fee_bps = 0
            100_000 * ONE_USDC, // cap
            rate_bps,
            365,
            30,
            30 * DAY,
            'HASH',
            100,
            0,
            false,
        );
}

fn deposit_as(
    usdc: IMockERC20Dispatcher, pool: ICreditPoolDispatcher, who: ContractAddress, amount: u256,
) {
    usdc.mint(who, amount);
    start_cheat_caller_address(usdc.contract_address, who);
    usdc.approve(pool.contract_address, amount);
    stop_cheat_caller_address(usdc.contract_address);
    start_cheat_caller_address(pool.contract_address, who);
    pool.deposit(amount);
    stop_cheat_caller_address(pool.contract_address);
}

fn repay_as(usdc: IMockERC20Dispatcher, pool: ICreditPoolDispatcher, amount: u256) {
    // Founder already holds the borrowed amount; top up so it can always pay.
    usdc.mint(FOUNDER(), amount);
    start_cheat_caller_address(usdc.contract_address, FOUNDER());
    usdc.approve(pool.contract_address, amount);
    stop_cheat_caller_address(usdc.contract_address);
    start_cheat_caller_address(pool.contract_address, FOUNDER());
    pool.repay(amount);
    stop_cheat_caller_address(pool.contract_address);
}

fn withdraw_as(pool: ICreditPoolDispatcher, who: ContractAddress) {
    start_cheat_caller_address(pool.contract_address, who);
    pool.withdraw();
    stop_cheat_caller_address(pool.contract_address);
}

/// The contract's own entitlement formula, recomputed independently so the
/// test does not merely echo the contract.
fn entitlement(deposited: u256, total_deposited: u256, total_repaid: u256) -> u256 {
    let share = (deposited * PRECISION) / total_deposited;
    (total_repaid * share) / PRECISION
}

/// Assert solvency (S) and no-over-extraction (N) for the whole roster.
fn check_invariants(
    usdc: IMockERC20Dispatcher, pool: ICreditPoolDispatcher, total_deposited: u256,
) {
    let info = pool.get_pool_info();
    let total_repaid = info.total_repaid;

    let p1 = pool.get_position(L1());
    let p2 = pool.get_position(L2());
    let p3 = pool.get_position(L3());
    let total_withdrawn = p1.withdrawn + p2.withdrawn + p3.withdrawn;

    // (S) Pool balance is exactly what came in minus what went out.
    let bal = usdc.balance_of(pool.contract_address);
    assert(bal + total_withdrawn == total_repaid, 'solvency identity broken');

    // (N) Each lender's cumulative withdrawal is within their exact entitlement.
    assert(p1.withdrawn <= entitlement(p1.deposited, total_deposited, total_repaid), 'L1 over');
    assert(p2.withdrawn <= entitlement(p2.deposited, total_deposited, total_repaid), 'L2 over');
    assert(p3.withdrawn <= entitlement(p3.deposited, total_deposited, total_repaid), 'L3 over');

    // (N) Sum of entitlements never exceeds what was repaid.
    let e_sum = entitlement(p1.deposited, total_deposited, total_repaid)
        + entitlement(p2.deposited, total_deposited, total_repaid)
        + entitlement(p3.deposited, total_deposited, total_repaid);
    assert(e_sum <= total_repaid, 'entitlements exceed repaid');
}

fn setup_borrowed(rate_bps: u16) -> (IMockERC20Dispatcher, ICreditPoolDispatcher, u256) {
    let usdc = deploy_usdc();
    let pool = deploy_pool();
    init_pool(pool, usdc.contract_address, rate_bps);

    start_cheat_caller_address(pool.contract_address, FOUNDER());
    pool.activate();
    stop_cheat_caller_address(pool.contract_address);

    // Uneven deposits, uneven timing (three separate deposit calls).
    deposit_as(usdc, pool, L1(), 1_000 * ONE_USDC);
    deposit_as(usdc, pool, L2(), 3_000 * ONE_USDC);
    deposit_as(usdc, pool, L3(), 2_500 * ONE_USDC);
    let total_deposited = 6_500 * ONE_USDC;

    start_cheat_caller_address(pool.contract_address, FOUNDER());
    pool.borrow();
    stop_cheat_caller_address(pool.contract_address);

    (usdc, pool, total_deposited)
}

#[test]
fn test_prorata_interleaved_partial_repay_and_withdraw() {
    let (usdc, pool, total) = setup_borrowed(1000); // 10% -> owed 7150

    // Repay 2000, L1 exits early.
    repay_as(usdc, pool, 2_000 * ONE_USDC);
    check_invariants(usdc, pool, total);
    withdraw_as(pool, L1());
    check_invariants(usdc, pool, total);

    // Repay 3000, L3 exits.
    repay_as(usdc, pool, 3_000 * ONE_USDC);
    check_invariants(usdc, pool, total);
    withdraw_as(pool, L3());
    check_invariants(usdc, pool, total);

    // L1 comes back for more after their share grew.
    withdraw_as(pool, L1());
    check_invariants(usdc, pool, total);

    // Final payment completes the pool: 2000 + 3000 + 2150 = 7150.
    repay_as(usdc, pool, 2_150 * ONE_USDC);
    assert(pool.get_pool_info().status == PoolStatus::Completed, 'should be completed');
    check_invariants(usdc, pool, total);

    // Everyone drains to their entitlement.
    withdraw_as(pool, L1());
    withdraw_as(pool, L2());
    withdraw_as(pool, L3());
    check_invariants(usdc, pool, total);

    // After full completion each lender has principal + ~10%, minus at most a
    // few micro-USDC of truncation dust. Confirm the shortfall is only dust.
    let p1 = pool.get_position(L1());
    let p2 = pool.get_position(L2());
    let p3 = pool.get_position(L3());
    // Fair (real-valued) payouts: 1100, 3300, 2750 USDC.
    assert(p1.withdrawn <= 1_100 * ONE_USDC && p1.withdrawn + 5 >= 1_100 * ONE_USDC, 'L1 dust');
    assert(p2.withdrawn <= 3_300 * ONE_USDC && p2.withdrawn + 5 >= 3_300 * ONE_USDC, 'L2 dust');
    assert(p3.withdrawn <= 2_750 * ONE_USDC && p3.withdrawn + 5 >= 2_750 * ONE_USDC, 'L3 dust');

    // Any residue left in the pool is stranded dust, and it is tiny.
    let residue = usdc.balance_of(pool.contract_address);
    assert(residue < 10, 'residue must be dust');
}

#[test]
fn test_pre_borrow_exit_shrinks_the_prorata_denominator() {
    // The accounting fix: a lender who exits before borrow must not remain in
    // the pro-rata denominator afterwards, or survivors are silently diluted.
    let usdc = deploy_usdc();
    let pool = deploy_pool();
    init_pool(pool, usdc.contract_address, 1000); // 10%

    start_cheat_caller_address(pool.contract_address, FOUNDER());
    pool.activate();
    stop_cheat_caller_address(pool.contract_address);

    deposit_as(usdc, pool, L1(), 1_000 * ONE_USDC);
    deposit_as(usdc, pool, L2(), 2_000 * ONE_USDC);
    deposit_as(usdc, pool, L3(), 3_000 * ONE_USDC);
    assert(pool.get_pool_info().total_deposited == 6_000 * ONE_USDC, 'pre-exit total');

    // L2 changes their mind and fully exits before borrow.
    withdraw_as(pool, L2());
    let after = pool.get_pool_info();
    assert(after.total_deposited == 4_000 * ONE_USDC, 'denominator shrank');
    assert(after.lender_count == 2, 'slot released');
    assert(usdc.balance_of(pool.contract_address) == 4_000 * ONE_USDC, 'balance follows');

    // Borrow takes exactly the real balance, not the pre-exit figure.
    start_cheat_caller_address(pool.contract_address, FOUNDER());
    pool.borrow();
    stop_cheat_caller_address(pool.contract_address);
    assert(pool.get_pool_info().total_borrowed == 4_000 * ONE_USDC, 'borrowed real balance');
    assert(usdc.balance_of(FOUNDER()) == 4_000 * ONE_USDC, 'founder got real balance');

    // Repay to completion: owed = 4000 + 400 = 4400.
    repay_as(usdc, pool, 4_400 * ONE_USDC);
    assert(pool.get_pool_info().status == PoolStatus::Completed, 'completed');

    withdraw_as(pool, L1());
    withdraw_as(pool, L3());

    // Survivors split against 4000, not 6000. If the denominator had stayed
    // inflated, L1 would receive ~733 instead of 1100.
    let p1 = pool.get_position(L1());
    let p3 = pool.get_position(L3());
    assert(
        p1.withdrawn + 5 >= 1_100 * ONE_USDC && p1.withdrawn <= 1_100 * ONE_USDC, 'L1 undiluted',
    );
    assert(
        p3.withdrawn + 5 >= 3_300 * ONE_USDC && p3.withdrawn <= 3_300 * ONE_USDC, 'L3 undiluted',
    );
    assert(usdc.balance_of(pool.contract_address) < 10, 'no dilution residue');
}

#[test]
fn test_prorata_last_withdrawer_not_short_after_default() {
    // Partial repayment then default: the remaining lenders split what was
    // actually repaid, and the last one out is still paid in full.
    let (usdc, pool, total) = setup_borrowed(1000);

    repay_as(usdc, pool, 1_234 * ONE_USDC + 567); // deliberately not round
    check_invariants(usdc, pool, total);

    // Mark defaulted via the factory address used at init.
    start_cheat_caller_address(pool.contract_address, contract_address_const::<'FACTORY'>());
    // Move time far enough that duration has expired.
    snforge_std_deprecated::start_cheat_block_timestamp(pool.contract_address, 400 * DAY);
    pool.mark_defaulted();
    snforge_std_deprecated::stop_cheat_block_timestamp(pool.contract_address);
    stop_cheat_caller_address(pool.contract_address);
    assert(pool.get_pool_info().status == PoolStatus::Defaulted, 'defaulted');

    // All three withdraw in an adversarial order; none reverts, pool stays solvent.
    withdraw_as(pool, L3());
    check_invariants(usdc, pool, total);
    withdraw_as(pool, L1());
    check_invariants(usdc, pool, total);
    withdraw_as(pool, L2());
    check_invariants(usdc, pool, total);

    // The pool cannot pay out more than it received.
    let residue = usdc.balance_of(pool.contract_address);
    assert(residue < 10, 'no phantom funds');
}
