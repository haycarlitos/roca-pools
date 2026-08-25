//! Delta re-review — repayment accepted in Defaulted (HEAD 178cf98).
//!
//! The newly reachable interleaving that no prior test covers:
//!   L1 withdraws -> pool defaults -> recovery -> L2 withdraws -> further
//!   recovery -> L1 withdraws again, with a third lender never touched.
//!
//! Property under test at every step:
//!   (S) pool USDC balance == total_repaid - sum(withdrawn)  [never negative]
//!   (N) each lender withdrawn <= floor(total_repaid * deposited / total_dep)
//!       and sum(entitlements) <= total_repaid
//! plus: total_deposited is never written after borrow, across the Borrowed ->
//! Defaulted status change.

use seedless_contracts::interfaces::i_credit_pool::{
    ICreditPoolDispatcher, ICreditPoolDispatcherTrait, PoolStatus,
};
use seedless_contracts::mocks::mock_erc20::{IMockERC20Dispatcher, IMockERC20DispatcherTrait};
use snforge_std_deprecated::{
    ContractClassTrait, DeclareResultTrait, declare, start_cheat_block_timestamp,
    start_cheat_caller_address, stop_cheat_block_timestamp, stop_cheat_caller_address,
};
use starknet::{ContractAddress, contract_address_const};

const ONE_USDC: u256 = 1_000_000;
const DAY: u64 = 86400;
const PRECISION: u256 = 1_000_000_000_000_000_000;

fn FOUNDER() -> ContractAddress {
    contract_address_const::<'FOUNDER'>()
}
fn FACTORY() -> ContractAddress {
    contract_address_const::<'FACTORY'>()
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
            FACTORY(),
            FOUNDER(),
            usdc,
            PLATFORM(),
            0,
            100_000 * ONE_USDC,
            1000, // 10%
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

fn entitlement(deposited: u256, total_deposited: u256, total_repaid: u256) -> u256 {
    let share = (deposited * PRECISION) / total_deposited;
    (total_repaid * share) / PRECISION
}

fn check(usdc: IMockERC20Dispatcher, pool: ICreditPoolDispatcher, total_dep: u256) {
    let info = pool.get_pool_info();
    let r = info.total_repaid;
    // total_deposited must stay frozen at the borrowed amount across the default.
    assert(info.total_deposited == total_dep, 'denominator moved');

    let w1 = pool.get_position(L1()).withdrawn;
    let w2 = pool.get_position(L2()).withdrawn;
    let w3 = pool.get_position(L3()).withdrawn;
    let bal = usdc.balance_of(pool.contract_address);

    // (S) solvency identity
    assert(bal + w1 + w2 + w3 == r, 'insolvent: owes > holds');
    // (N) no over-credit, per lender and in aggregate
    assert(w1 <= entitlement(1_000 * ONE_USDC, total_dep, r), 'L1 over');
    assert(w2 <= entitlement(2_000 * ONE_USDC, total_dep, r), 'L2 over');
    assert(w3 <= entitlement(3_000 * ONE_USDC, total_dep, r), 'L3 over');
    let esum = entitlement(1_000 * ONE_USDC, total_dep, r)
        + entitlement(2_000 * ONE_USDC, total_dep, r)
        + entitlement(3_000 * ONE_USDC, total_dep, r);
    assert(esum <= r, 'entitlements exceed repaid');
}

#[test]
fn test_interleaved_withdraw_across_default_stays_solvent() {
    let usdc = deploy_usdc();
    let pool = deploy_pool();
    init_pool(pool, usdc.contract_address);

    start_cheat_caller_address(pool.contract_address, FOUNDER());
    pool.activate();
    stop_cheat_caller_address(pool.contract_address);

    deposit_as(usdc, pool, L1(), 1_000 * ONE_USDC);
    deposit_as(usdc, pool, L2(), 2_000 * ONE_USDC);
    deposit_as(usdc, pool, L3(), 3_000 * ONE_USDC);
    let total_dep = 6_000 * ONE_USDC; // owed = 6600

    start_cheat_caller_address(pool.contract_address, FOUNDER());
    pool.borrow();
    stop_cheat_caller_address(pool.contract_address);

    // Borrowed: a first partial repayment, then L1 exits early.
    repay_as(usdc, pool, 900 * ONE_USDC);
    check(usdc, pool, total_dep);
    withdraw_as(pool, L1());
    check(usdc, pool, total_dep);

    // The factory defaults the pool (duration long past).
    start_cheat_block_timestamp(pool.contract_address, 400 * DAY);
    start_cheat_caller_address(pool.contract_address, FACTORY());
    pool.mark_defaulted();
    stop_cheat_caller_address(pool.contract_address);
    assert(pool.get_pool_info().status == PoolStatus::Defaulted, 'defaulted');
    check(usdc, pool, total_dep);

    // Recovery #1 arrives in Defaulted; L2 withdraws.
    repay_as(usdc, pool, 1_500 * ONE_USDC);
    check(usdc, pool, total_dep);
    withdraw_as(pool, L2());
    check(usdc, pool, total_dep);

    // Recovery #2 arrives; L1 comes back for their grown share.
    repay_as(usdc, pool, 1_200 * ONE_USDC);
    check(usdc, pool, total_dep);
    withdraw_as(pool, L1());
    check(usdc, pool, total_dep);

    // L3 never touched until now; must still be fully payable, never short.
    withdraw_as(pool, L3());
    check(usdc, pool, total_dep);
    stop_cheat_block_timestamp(pool.contract_address);

    // Everyone drains again at the end; pool cannot owe more than it holds.
    withdraw_as(pool, L2());
    check(usdc, pool, total_dep);
    let residue = usdc.balance_of(pool.contract_address);
    // total_repaid so far = 900+1500+1200 = 3600; sum of entitlements <= that,
    // residue is only truncation dust.
    assert(residue < 10, 'residue is dust only');
}

#[test]
fn test_full_recovery_after_default_stays_defaulted() {
    // A full recovery does NOT relabel a defaulted pool: repay's completion
    // branch is gated on `status == Borrowed` (fffb6d8), so reaching total_owed
    // leaves the pool Defaulted. Paying late does not make the payment on time,
    // and payout is identical either way (same pro-rata branch).
    let usdc = deploy_usdc();
    let pool = deploy_pool();
    init_pool(pool, usdc.contract_address);

    start_cheat_caller_address(pool.contract_address, FOUNDER());
    pool.activate();
    stop_cheat_caller_address(pool.contract_address);
    deposit_as(usdc, pool, L1(), 1_000 * ONE_USDC);
    start_cheat_caller_address(pool.contract_address, FOUNDER());
    pool.borrow();
    stop_cheat_caller_address(pool.contract_address);

    start_cheat_block_timestamp(pool.contract_address, 400 * DAY);
    start_cheat_caller_address(pool.contract_address, FACTORY());
    pool.mark_defaulted();
    stop_cheat_caller_address(pool.contract_address);
    assert(pool.get_pool_info().status == PoolStatus::Defaulted, 'defaulted first');

    // Full recovery: owed = 1000 + 100 = 1100.
    repay_as(usdc, pool, 1_100 * ONE_USDC);
    stop_cheat_block_timestamp(pool.contract_address);

    let status = pool.get_pool_info().status;
    // The point: a full recovery must NOT relabel it Completed.
    assert(status == PoolStatus::Defaulted, 'stays defaulted');
}
