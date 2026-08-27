//! Audit of 9508e95 — the post-borrow withdrawal underflow.
//!
//! The bug: `_calculate_withdrawal` computed `deposited - withdrawn` unguarded.
//! Once a lender's cumulative `withdrawn` passes their `deposited` (i.e. they
//! have collected any interest), that subtraction underflows and the whole
//! function panics with 'u256_sub Overflow'. Because `withdraw` calls
//! `_calculate_withdrawal` first, the lender can no longer withdraw at all, so
//! entitlement arriving afterwards is permanently stranded.
//!
//! The suite never caught it because every withdrawal test took the entire
//! entitlement in one call — the one path that never leaves withdrawn >
//! deposited with anything still owed.
//!
//! These tests drive the multi-lender, multi-repayment, partial-withdrawal
//! interleaving that does. On the FIXED class (0x04efa2d3...) they pass. On the
//! deployed buggy class they panic at the second withdrawal — check out the
//! pre-fix commit and `test_partial_profitable_withdraw_then_remainder` fails
//! with 'u256_sub Overflow'.

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

fn FACTORY() -> ContractAddress {
    contract_address_const::<'FACTORY'>()
}
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

// Fee-free pool so total_repaid == gross repaid and the solvency identity is exact.
fn init_pool(pool: ICreditPoolDispatcher, usdc: ContractAddress) {
    pool
        .initialize(
            FACTORY(), FOUNDER(), usdc, PLATFORM(), 0, 100_000 * ONE_USDC, 1000, 365, 30,
            30 * DAY, 'HASH', 100, 0, false,
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

fn setup_borrowed(usdc: IMockERC20Dispatcher, pool: ICreditPoolDispatcher) {
    init_pool(pool, usdc.contract_address);
    start_cheat_caller_address(pool.contract_address, FOUNDER());
    pool.activate();
    stop_cheat_caller_address(pool.contract_address);
}

// ===========================================================================
// The exact bug: a profitable partial exit, then more repayment.
// ===========================================================================
#[test]
fn test_partial_profitable_withdraw_then_remainder() {
    let usdc = deploy_usdc();
    let pool = deploy_pool();
    setup_borrowed(usdc, pool);

    // Two equal lenders; borrow 2000; owed = 2200 at 10%.
    deposit_as(usdc, pool, L1(), 1_000 * ONE_USDC);
    deposit_as(usdc, pool, L2(), 1_000 * ONE_USDC);
    start_cheat_caller_address(pool.contract_address, FOUNDER());
    pool.borrow();
    stop_cheat_caller_address(pool.contract_address);

    // Repay 2100. L1 entitlement = 2100 * 1000/2000 = 1050 > their 1000 deposit.
    repay_as(usdc, pool, 2_100 * ONE_USDC);
    withdraw_as(pool, L1()); // withdrawn_L1 = 1050 -> now EXCEEDS deposited 1000
    let p = pool.get_position(L1());
    assert(p.withdrawn > p.deposited, 'L1 collected interest');

    // The final 100 arrives. Pre-fix, this next call panics u256_sub Overflow
    // (in get_available_withdrawal AND withdraw), stranding L1's remaining 50.
    repay_as(usdc, pool, 100 * ONE_USDC); // total_repaid = 2200 (complete)

    // View must not revert.
    let avail = pool.get_available_withdrawal(L1());
    assert(avail.available == 50 * ONE_USDC, 'L1 owed the final 50');
    // And principal is fully returned, so it is all interest.
    assert(avail.principal_part == 0, 'principal already returned');
    assert(avail.interest_part == 50 * ONE_USDC, 'remainder is interest');

    // The stranded entitlement is now reachable.
    withdraw_as(pool, L1());
    assert(usdc.balance_of(L1()) == 1_100 * ONE_USDC, 'L1 made whole: 1000 + 100');

    // L2 (never partially withdrew) is also whole.
    withdraw_as(pool, L2());
    assert(usdc.balance_of(L2()) == 1_100 * ONE_USDC, 'L2 made whole');

    // Pool paid out exactly what it took in; nothing stranded.
    assert(usdc.balance_of(pool.contract_address) == 0, 'pool fully drained');
}

// ===========================================================================
// The exact mainnet symptom: get_available_withdrawal reverts on a pool
// repaid in full, once the caller has already withdrawn past their principal.
// The VIEW itself must stay total (pre-fix it panicked u256_sub Overflow).
// ===========================================================================
#[test]
fn test_view_does_not_revert_after_full_withdrawal_past_principal() {
    let usdc = deploy_usdc();
    let pool = deploy_pool();
    setup_borrowed(usdc, pool);

    deposit_as(usdc, pool, L1(), 1_000 * ONE_USDC);
    start_cheat_caller_address(pool.contract_address, FOUNDER());
    pool.borrow();
    stop_cheat_caller_address(pool.contract_address);

    // Repay in full (owed = 1100) and let L1 take the whole entitlement.
    repay_as(usdc, pool, 1_100 * ONE_USDC);
    withdraw_as(pool, L1());
    let p = pool.get_position(L1());
    assert(p.withdrawn == 1_100 * ONE_USDC && p.withdrawn > p.deposited, 'withdrawn past principal');

    // Pre-fix, this view call panics because max_principal = 1000 - 1100
    // underflows. It must return cleanly with everything owed = 0.
    let a = pool.get_available_withdrawal(L1());
    assert(a.available == 0, 'nothing left');
    assert(a.principal_part == 0, 'principal returned');
    assert(a.interest_part == 0, 'no underflow, coherent');
}

// ===========================================================================
// Solvency sweep: three uneven lenders, interleaved partial withdrawals and
// repayments, some crossing principal. Pool never owes more than it holds; no
// withdrawal reverts.
// ===========================================================================
fn entitlement(dep: u256, total_dep: u256, total_repaid: u256) -> u256 {
    let share = (dep * PRECISION) / total_dep;
    (total_repaid * share) / PRECISION
}

fn check_solvent(usdc: IMockERC20Dispatcher, pool: ICreditPoolDispatcher, total_dep: u256) {
    let r = pool.get_pool_info().total_repaid;
    let w1 = pool.get_position(L1()).withdrawn;
    let w2 = pool.get_position(L2()).withdrawn;
    let w3 = pool.get_position(L3()).withdrawn;
    let bal = usdc.balance_of(pool.contract_address);
    assert(bal + w1 + w2 + w3 == r, 'insolvent: owes != holds');
    assert(w1 <= entitlement(1_000 * ONE_USDC, total_dep, r), 'L1 over');
    assert(w2 <= entitlement(3_000 * ONE_USDC, total_dep, r), 'L2 over');
    assert(w3 <= entitlement(500 * ONE_USDC, total_dep, r), 'L3 over');
}

#[test]
fn test_multilender_interleaved_solvency_across_principal_crossing() {
    let usdc = deploy_usdc();
    let pool = deploy_pool();
    setup_borrowed(usdc, pool);

    deposit_as(usdc, pool, L1(), 1_000 * ONE_USDC);
    deposit_as(usdc, pool, L2(), 3_000 * ONE_USDC);
    deposit_as(usdc, pool, L3(), 500 * ONE_USDC);
    let total = 4_500 * ONE_USDC; // owed = 4950

    start_cheat_caller_address(pool.contract_address, FOUNDER());
    pool.borrow();
    stop_cheat_caller_address(pool.contract_address);

    repay_as(usdc, pool, 2_000 * ONE_USDC);
    check_solvent(usdc, pool, total);
    withdraw_as(pool, L1());
    withdraw_as(pool, L3());
    check_solvent(usdc, pool, total);

    repay_as(usdc, pool, 2_000 * ONE_USDC);
    check_solvent(usdc, pool, total);
    withdraw_as(pool, L1()); // L1 likely crosses principal here
    withdraw_as(pool, L2());
    check_solvent(usdc, pool, total);

    repay_as(usdc, pool, 950 * ONE_USDC); // completes: total_repaid = 4950
    assert(pool.get_pool_info().status == PoolStatus::Completed, 'completed');
    check_solvent(usdc, pool, total);

    // Everyone drains; the last withdrawer is not short.
    withdraw_as(pool, L1());
    withdraw_as(pool, L2());
    withdraw_as(pool, L3());
    check_solvent(usdc, pool, total);

    // Each got principal + 10%, minus at most truncation dust.
    assert(usdc.balance_of(L1()) + 3 >= 1_100 * ONE_USDC, 'L1 ~1100');
    assert(usdc.balance_of(L2()) + 3 >= 3_300 * ONE_USDC, 'L2 ~3300');
    assert(usdc.balance_of(L3()) + 3 >= 550 * ONE_USDC, 'L3 ~550');
    assert(usdc.balance_of(pool.contract_address) < 10, 'only dust stranded');
}
