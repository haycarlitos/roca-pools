use seedless_contracts::interfaces::i_credit_pool::{
    ICreditPoolDispatcher, ICreditPoolDispatcherTrait, PoolStatus,
};
use seedless_contracts::mocks::mock_erc20::{IMockERC20Dispatcher, IMockERC20DispatcherTrait};
use snforge_std_deprecated::{
    ContractClassTrait, DeclareResultTrait, declare, start_cheat_block_timestamp,
    start_cheat_caller_address, stop_cheat_block_timestamp, stop_cheat_caller_address,
};
use starknet::{ContractAddress, contract_address_const};

// Constants
const USDC_DECIMALS: u8 = 6;
const ONE_USDC: u256 = 1_000_000; // 1 USDC = 10^6
const SECONDS_PER_DAY: u64 = 86400;

fn FACTORY() -> ContractAddress {
    contract_address_const::<'FACTORY'>()
}

fn PLATFORM_WALLET() -> ContractAddress {
    contract_address_const::<'PLATFORM'>()
}

fn FOUNDER() -> ContractAddress {
    contract_address_const::<'FOUNDER'>()
}

fn LENDER1() -> ContractAddress {
    contract_address_const::<'LENDER1'>()
}

fn LENDER2() -> ContractAddress {
    contract_address_const::<'LENDER2'>()
}

/// Deploy mock USDC and return dispatcher
fn deploy_usdc() -> IMockERC20Dispatcher {
    let usdc_class = declare("MockERC20").unwrap().contract_class();
    let mut calldata: Array<felt252> = array![];
    calldata.append('USDC');
    calldata.append('USDC');
    calldata.append(USDC_DECIMALS.into());
    let (usdc_address, _) = usdc_class.deploy(@calldata).unwrap();
    IMockERC20Dispatcher { contract_address: usdc_address }
}

/// Deploy credit pool and return dispatcher
fn deploy_pool() -> ICreditPoolDispatcher {
    let pool_class = declare("CreditPool").unwrap().contract_class();
    let (pool_address, _) = pool_class.deploy(@array![]).unwrap();
    ICreditPoolDispatcher { contract_address: pool_address }
}

/// Initialize pool with standard test parameters
fn initialize_pool(pool: ICreditPoolDispatcher, usdc: ContractAddress, funding_deadline: u64) {
    pool
        .initialize(
            FACTORY(),
            FOUNDER(),
            usdc,
            PLATFORM_WALLET(),
            50, // 0.5% repayment fee
            10_000 * ONE_USDC, // $10,000 cap
            1000, // 10% annual rate
            365, // 1 year duration
            30, // monthly interval
            funding_deadline,
            'DATA_ROOM_HASH',
            100, // max lenders: high enough not to interfere
            0, // no minimum deposit
            false // no allowlist: these pools are deployed without a live factory
        );
}

// ============================================
// DEPOSIT & WITHDRAW BEFORE BORROW
// ============================================

#[test]
fn test_deposit_withdraw_before_borrow() {
    let usdc = deploy_usdc();
    let pool = deploy_pool();
    let pool_address = pool.contract_address;

    // Funding deadline: 30 days from now
    let funding_deadline: u64 = 30 * SECONDS_PER_DAY;
    initialize_pool(pool, usdc.contract_address, funding_deadline);

    // Activate pool
    start_cheat_caller_address(pool_address, FOUNDER());
    pool.activate();
    stop_cheat_caller_address(pool_address);

    // Mint USDC to lender
    let deposit_amount = 1_000 * ONE_USDC; // $1,000
    usdc.mint(LENDER1(), deposit_amount);

    // Lender approves and deposits
    start_cheat_caller_address(usdc.contract_address, LENDER1());
    usdc.approve(pool_address, deposit_amount);
    stop_cheat_caller_address(usdc.contract_address);

    start_cheat_caller_address(pool_address, LENDER1());
    pool.deposit(deposit_amount);
    stop_cheat_caller_address(pool_address);

    // Verify deposit
    let info = pool.get_pool_info();
    assert(info.total_deposited == deposit_amount, 'Wrong total deposited');
    assert(info.lender_count == 1, 'Should have 1 lender');

    let position = pool.get_position(LENDER1());
    assert(position.deposited == deposit_amount, 'Wrong position deposited');

    // Verify pool received USDC
    assert(usdc.balance_of(pool_address) == deposit_amount, 'Pool should have USDC');

    // Lender withdraws before borrow
    start_cheat_caller_address(pool_address, LENDER1());
    pool.withdraw();
    stop_cheat_caller_address(pool_address);

    // Verify lender got USDC back
    assert(usdc.balance_of(LENDER1()) == deposit_amount, 'Lender should have USDC back');
    assert(usdc.balance_of(pool_address) == 0, 'Pool should be empty');

    // A full exit before the money is lent out unwinds the participation
    // entirely: the accounting follows the cash, and the roster slot is
    // returned so the pool can still be filled by someone else.
    //
    // The historical fact that they deposited is not lost, it lives in the
    // Deposited and Withdrawn events. What is cleared is only current state.
    let info_after = pool.get_pool_info();
    assert(info_after.total_deposited == 0, 'Accounting follows the cash');
    assert(info_after.lender_count == 0, 'Roster slot returned');
    assert(!pool.is_lender(LENDER1()), 'No longer a lender');

    let position_after = pool.get_position(LENDER1());
    assert(position_after.deposited == 0, 'Position cleared');
    assert(position_after.withdrawn == 0, 'Position cleared');
}

#[test]
#[should_panic(expected: ('Funding deadline passed',))]
fn test_cannot_deposit_after_deadline() {
    let usdc = deploy_usdc();
    let pool = deploy_pool();
    let pool_address = pool.contract_address;

    // Short deadline: 1 day
    let funding_deadline: u64 = SECONDS_PER_DAY;
    initialize_pool(pool, usdc.contract_address, funding_deadline);

    // Activate pool
    start_cheat_caller_address(pool_address, FOUNDER());
    pool.activate();
    stop_cheat_caller_address(pool_address);

    // Mint USDC to lender
    let deposit_amount = 1_000 * ONE_USDC;
    usdc.mint(LENDER1(), deposit_amount);

    // Approve
    start_cheat_caller_address(usdc.contract_address, LENDER1());
    usdc.approve(pool_address, deposit_amount);
    stop_cheat_caller_address(usdc.contract_address);

    // Fast forward past deadline
    start_cheat_block_timestamp(pool_address, funding_deadline + 1);

    // Try to deposit - should fail
    start_cheat_caller_address(pool_address, LENDER1());
    pool.deposit(deposit_amount);
    stop_cheat_caller_address(pool_address);
}

// ============================================
// FULL BORROW & REPAY CYCLE
// ============================================

#[test]
fn test_full_borrow_repay_cycle() {
    let usdc = deploy_usdc();
    let pool = deploy_pool();
    let pool_address = pool.contract_address;

    let funding_deadline: u64 = 30 * SECONDS_PER_DAY;
    initialize_pool(pool, usdc.contract_address, funding_deadline);

    // Activate pool
    start_cheat_caller_address(pool_address, FOUNDER());
    pool.activate();
    stop_cheat_caller_address(pool_address);

    // Lender1 deposits $5,000
    let deposit1 = 5_000 * ONE_USDC;
    usdc.mint(LENDER1(), deposit1);
    start_cheat_caller_address(usdc.contract_address, LENDER1());
    usdc.approve(pool_address, deposit1);
    stop_cheat_caller_address(usdc.contract_address);
    start_cheat_caller_address(pool_address, LENDER1());
    pool.deposit(deposit1);
    stop_cheat_caller_address(pool_address);

    // Lender2 deposits $5,000
    let deposit2 = 5_000 * ONE_USDC;
    usdc.mint(LENDER2(), deposit2);
    start_cheat_caller_address(usdc.contract_address, LENDER2());
    usdc.approve(pool_address, deposit2);
    stop_cheat_caller_address(usdc.contract_address);
    start_cheat_caller_address(pool_address, LENDER2());
    pool.deposit(deposit2);
    stop_cheat_caller_address(pool_address);

    let info_before_borrow = pool.get_pool_info();
    assert(info_before_borrow.total_deposited == 10_000 * ONE_USDC, 'Should have $10k deposited');
    assert(info_before_borrow.lender_count == 2, 'Should have 2 lenders');

    // Founder borrows at timestamp 1 day
    let borrow_time: u64 = SECONDS_PER_DAY;
    start_cheat_block_timestamp(pool_address, borrow_time);
    start_cheat_caller_address(pool_address, FOUNDER());
    pool.borrow();
    stop_cheat_caller_address(pool_address);
    stop_cheat_block_timestamp(pool_address);

    let info_after_borrow = pool.get_pool_info();
    assert(info_after_borrow.status == PoolStatus::Borrowed, 'Should be Borrowed');
    assert(info_after_borrow.total_borrowed == 10_000 * ONE_USDC, 'Should have borrowed $10k');
    assert(info_after_borrow.borrow_rate_bps == 1000, 'Rate should be locked at 10%');
    assert(usdc.balance_of(FOUNDER()) == 10_000 * ONE_USDC, 'Founder should have $10k');

    // Calculate total owed: principal + 10% interest = $11,000
    // With 0.5% platform fee on repayment:
    // amount_to_pool = repay_amount - (repay_amount * 50 / 10000)
    // amount_to_pool = repay_amount * 9950 / 10000
    // To get amount_to_pool = 11,000, we need:
    // repay_amount = 11,000 * 10000 / 9950 = 11,055.276...
    //
    // But we need to be careful not to exceed remaining balance.
    // Let's repay exactly what's owed in smaller chunks to avoid rounding issues.

    // Mint enough USDC to founder for repayment
    let repay_amount = 11_056 * ONE_USDC;
    usdc.mint(FOUNDER(), repay_amount);

    // Founder approves
    start_cheat_caller_address(usdc.contract_address, FOUNDER());
    usdc.approve(pool_address, repay_amount);
    stop_cheat_caller_address(usdc.contract_address);

    // Calculate: to deliver exactly 11,000 USDC to pool
    // amount_to_pool = repay * 9950 / 10000
    // repay = 11,000,000,000 * 10000 / 9950 = 11,055,276,381.9...
    // Round down to avoid exceeding: 11,055,276,381
    let exact_repay = 11_055_276_381_u256;

    start_cheat_caller_address(pool_address, FOUNDER());
    pool.repay(exact_repay);
    stop_cheat_caller_address(pool_address);

    let info_after_repay = pool.get_pool_info();
    assert(info_after_repay.status == PoolStatus::Completed, 'Should be Completed');

    // Platform should have received fee
    // fee = exact_repay * 50 / 10000 = 11,055,276,382 * 0.005 = 55,276,381.91 ≈ 55,276,381
    let platform_balance = usdc.balance_of(PLATFORM_WALLET());
    assert(platform_balance > 0, 'Platform should have fee');

    // Lenders withdraw their share
    start_cheat_caller_address(pool_address, LENDER1());
    pool.withdraw();
    stop_cheat_caller_address(pool_address);

    start_cheat_caller_address(pool_address, LENDER2());
    pool.withdraw();
    stop_cheat_caller_address(pool_address);

    // Each lender should have received ~$5,500 (principal + 10% interest)
    let lender1_balance = usdc.balance_of(LENDER1());
    let lender2_balance = usdc.balance_of(LENDER2());

    // Should be approximately $5,500 each (within rounding)
    assert(lender1_balance >= 5_400 * ONE_USDC, 'Lender1 should have ~$5.5k');
    assert(lender2_balance >= 5_400 * ONE_USDC, 'Lender2 should have ~$5.5k');
}

// ============================================
// EXPIRED POOL WITHDRAWAL
// ============================================

#[test]
fn test_withdraw_after_expired() {
    let usdc = deploy_usdc();
    let pool = deploy_pool();
    let pool_address = pool.contract_address;

    // Short deadline: 1 day
    let funding_deadline: u64 = SECONDS_PER_DAY;
    initialize_pool(pool, usdc.contract_address, funding_deadline);

    // Activate pool
    start_cheat_caller_address(pool_address, FOUNDER());
    pool.activate();
    stop_cheat_caller_address(pool_address);

    // Lender deposits
    let deposit_amount = 1_000 * ONE_USDC;
    usdc.mint(LENDER1(), deposit_amount);
    start_cheat_caller_address(usdc.contract_address, LENDER1());
    usdc.approve(pool_address, deposit_amount);
    stop_cheat_caller_address(usdc.contract_address);
    start_cheat_caller_address(pool_address, LENDER1());
    pool.deposit(deposit_amount);
    stop_cheat_caller_address(pool_address);

    // Fast forward past deadline
    start_cheat_block_timestamp(pool_address, funding_deadline + 1);

    // Anyone expires the pool
    pool.expire();

    let info = pool.get_pool_info();
    assert(info.status == PoolStatus::Expired, 'Should be Expired');

    // Lender withdraws from expired pool
    start_cheat_caller_address(pool_address, LENDER1());
    pool.withdraw();
    stop_cheat_caller_address(pool_address);

    stop_cheat_block_timestamp(pool_address);

    // Lender should have full deposit back
    assert(usdc.balance_of(LENDER1()) == deposit_amount, 'Should have full deposit back');
}

// ============================================
// CANCELLED POOL WITHDRAWAL
// ============================================

#[test]
fn test_withdraw_after_cancelled() {
    let usdc = deploy_usdc();
    let pool = deploy_pool();
    let pool_address = pool.contract_address;

    let funding_deadline: u64 = 30 * SECONDS_PER_DAY;
    initialize_pool(pool, usdc.contract_address, funding_deadline);

    // Activate pool
    start_cheat_caller_address(pool_address, FOUNDER());
    pool.activate();
    stop_cheat_caller_address(pool_address);

    // Lender deposits
    let deposit_amount = 1_000 * ONE_USDC;
    usdc.mint(LENDER1(), deposit_amount);
    start_cheat_caller_address(usdc.contract_address, LENDER1());
    usdc.approve(pool_address, deposit_amount);
    stop_cheat_caller_address(usdc.contract_address);
    start_cheat_caller_address(pool_address, LENDER1());
    pool.deposit(deposit_amount);
    stop_cheat_caller_address(pool_address);

    // Founder cancels
    start_cheat_caller_address(pool_address, FOUNDER());
    pool.cancel();
    stop_cheat_caller_address(pool_address);

    let info = pool.get_pool_info();
    assert(info.status == PoolStatus::Cancelled, 'Should be Cancelled');

    // Lender withdraws from cancelled pool
    start_cheat_caller_address(pool_address, LENDER1());
    pool.withdraw();
    stop_cheat_caller_address(pool_address);

    // Lender should have full deposit back
    assert(usdc.balance_of(LENDER1()) == deposit_amount, 'Should have full deposit back');
}

// ============================================
// DEFAULT SCENARIOS
// ============================================

#[test]
fn test_default_after_duration_expired() {
    let usdc = deploy_usdc();
    let pool = deploy_pool();
    let pool_address = pool.contract_address;

    let funding_deadline: u64 = 30 * SECONDS_PER_DAY;
    initialize_pool(pool, usdc.contract_address, funding_deadline);

    // Activate pool
    start_cheat_caller_address(pool_address, FOUNDER());
    pool.activate();
    stop_cheat_caller_address(pool_address);

    // Lender deposits
    let deposit_amount = 1_000 * ONE_USDC;
    usdc.mint(LENDER1(), deposit_amount);
    start_cheat_caller_address(usdc.contract_address, LENDER1());
    usdc.approve(pool_address, deposit_amount);
    stop_cheat_caller_address(usdc.contract_address);
    start_cheat_caller_address(pool_address, LENDER1());
    pool.deposit(deposit_amount);
    stop_cheat_caller_address(pool_address);

    // Founder borrows
    let borrow_time: u64 = SECONDS_PER_DAY;
    start_cheat_block_timestamp(pool_address, borrow_time);
    start_cheat_caller_address(pool_address, FOUNDER());
    pool.borrow();
    stop_cheat_caller_address(pool_address);

    // Fast forward past duration (365 days)
    let after_duration = borrow_time + (366 * SECONDS_PER_DAY);
    start_cheat_block_timestamp(pool_address, after_duration);

    // Factory marks as defaulted
    start_cheat_caller_address(pool_address, FACTORY());
    pool.mark_defaulted();
    stop_cheat_caller_address(pool_address);

    stop_cheat_block_timestamp(pool_address);

    let info = pool.get_pool_info();
    assert(info.status == PoolStatus::Defaulted, 'Should be Defaulted');
}

#[test]
fn test_default_after_payment_overdue() {
    let usdc = deploy_usdc();
    let pool = deploy_pool();
    let pool_address = pool.contract_address;

    let funding_deadline: u64 = 30 * SECONDS_PER_DAY;
    initialize_pool(pool, usdc.contract_address, funding_deadline);

    // Activate pool
    start_cheat_caller_address(pool_address, FOUNDER());
    pool.activate();
    stop_cheat_caller_address(pool_address);

    // Lender deposits
    let deposit_amount = 1_000 * ONE_USDC;
    usdc.mint(LENDER1(), deposit_amount);
    start_cheat_caller_address(usdc.contract_address, LENDER1());
    usdc.approve(pool_address, deposit_amount);
    stop_cheat_caller_address(usdc.contract_address);
    start_cheat_caller_address(pool_address, LENDER1());
    pool.deposit(deposit_amount);
    stop_cheat_caller_address(pool_address);

    // Founder borrows at day 1
    let borrow_time: u64 = SECONDS_PER_DAY;
    start_cheat_block_timestamp(pool_address, borrow_time);
    start_cheat_caller_address(pool_address, FOUNDER());
    pool.borrow();
    stop_cheat_caller_address(pool_address);

    // Fast forward 61 days (> 2 * 30 day interval = 60 days grace period)
    // This should trigger payment overdue default
    let overdue_time = borrow_time + (61 * SECONDS_PER_DAY);
    start_cheat_block_timestamp(pool_address, overdue_time);

    // Factory marks as defaulted due to overdue payment
    start_cheat_caller_address(pool_address, FACTORY());
    pool.mark_defaulted();
    stop_cheat_caller_address(pool_address);

    stop_cheat_block_timestamp(pool_address);

    let info = pool.get_pool_info();
    assert(info.status == PoolStatus::Defaulted, 'Should be Defaulted');
}

#[test]
#[should_panic(expected: ('Not defaultable yet',))]
fn test_cannot_default_before_grace_period() {
    let usdc = deploy_usdc();
    let pool = deploy_pool();
    let pool_address = pool.contract_address;

    let funding_deadline: u64 = 30 * SECONDS_PER_DAY;
    initialize_pool(pool, usdc.contract_address, funding_deadline);

    // Activate pool
    start_cheat_caller_address(pool_address, FOUNDER());
    pool.activate();
    stop_cheat_caller_address(pool_address);

    // Lender deposits
    let deposit_amount = 1_000 * ONE_USDC;
    usdc.mint(LENDER1(), deposit_amount);
    start_cheat_caller_address(usdc.contract_address, LENDER1());
    usdc.approve(pool_address, deposit_amount);
    stop_cheat_caller_address(usdc.contract_address);
    start_cheat_caller_address(pool_address, LENDER1());
    pool.deposit(deposit_amount);
    stop_cheat_caller_address(pool_address);

    // Founder borrows
    let borrow_time: u64 = SECONDS_PER_DAY;
    start_cheat_block_timestamp(pool_address, borrow_time);
    start_cheat_caller_address(pool_address, FOUNDER());
    pool.borrow();
    stop_cheat_caller_address(pool_address);

    // Try to default after only 30 days (before 60 day grace period)
    let too_early = borrow_time + (30 * SECONDS_PER_DAY);
    start_cheat_block_timestamp(pool_address, too_early);

    // Should fail - not defaultable yet
    start_cheat_caller_address(pool_address, FACTORY());
    pool.mark_defaulted();
    stop_cheat_caller_address(pool_address);
}

#[test]
fn test_repayment_resets_overdue_timer() {
    let usdc = deploy_usdc();
    let pool = deploy_pool();
    let pool_address = pool.contract_address;

    let funding_deadline: u64 = 30 * SECONDS_PER_DAY;
    initialize_pool(pool, usdc.contract_address, funding_deadline);

    // Activate pool
    start_cheat_caller_address(pool_address, FOUNDER());
    pool.activate();
    stop_cheat_caller_address(pool_address);

    // Lender deposits
    let deposit_amount = 1_000 * ONE_USDC;
    usdc.mint(LENDER1(), deposit_amount);
    start_cheat_caller_address(usdc.contract_address, LENDER1());
    usdc.approve(pool_address, deposit_amount);
    stop_cheat_caller_address(usdc.contract_address);
    start_cheat_caller_address(pool_address, LENDER1());
    pool.deposit(deposit_amount);
    stop_cheat_caller_address(pool_address);

    // Founder borrows at day 1
    let borrow_time: u64 = SECONDS_PER_DAY;
    start_cheat_block_timestamp(pool_address, borrow_time);
    start_cheat_caller_address(pool_address, FOUNDER());
    pool.borrow();
    stop_cheat_caller_address(pool_address);

    // Fast forward 50 days (within 60 day grace)
    let repay_time = borrow_time + (50 * SECONDS_PER_DAY);
    start_cheat_block_timestamp(pool_address, repay_time);

    // Founder makes a partial repayment
    let partial_repay = 100 * ONE_USDC; // $100
    usdc.mint(FOUNDER(), partial_repay);
    start_cheat_caller_address(usdc.contract_address, FOUNDER());
    usdc.approve(pool_address, partial_repay);
    stop_cheat_caller_address(usdc.contract_address);
    start_cheat_caller_address(pool_address, FOUNDER());
    pool.repay(partial_repay);
    stop_cheat_caller_address(pool_address);

    // Verify last_repayment_at was updated
    let info = pool.get_pool_info();
    assert(info.last_repayment_at == repay_time, 'Should update last_repayment');

    stop_cheat_block_timestamp(pool_address);
}

// ============================================
// ACCOUNTING INVARIANT: total_deposited vs real balance
// ============================================

/// `total_deposited` must equal the pool's USDC balance while the pool is
/// still Pending or Active, because nothing has been lent out yet.
///
/// This is the invariant `test_deposit_withdraw_before_borrow` never asserted.
/// That test withdraws everything, checks the lender got their money and that
/// `position.withdrawn` is right, and stops. It passes while leaving the pool
/// claiming deposits it no longer holds.
#[test]
fn test_total_deposited_tracks_balance_after_pre_borrow_withdraw() {
    let usdc = deploy_usdc();
    let pool = deploy_pool();
    let pool_address = pool.contract_address;

    initialize_pool(pool, usdc.contract_address, 30 * SECONDS_PER_DAY);

    start_cheat_caller_address(pool_address, FOUNDER());
    pool.activate();
    stop_cheat_caller_address(pool_address);

    let amount = 1_000 * ONE_USDC;
    usdc.mint(LENDER1(), amount);

    start_cheat_caller_address(usdc.contract_address, LENDER1());
    usdc.approve(pool_address, amount);
    stop_cheat_caller_address(usdc.contract_address);

    start_cheat_caller_address(pool_address, LENDER1());
    pool.deposit(amount);
    pool.withdraw();
    stop_cheat_caller_address(pool_address);

    let info = pool.get_pool_info();
    assert(usdc.balance_of(pool_address) == 0, 'Pool should hold nothing');
    assert(info.total_deposited == 0, 'total_deposited must follow');
}

/// The consequence of the invariant above breaking: `borrow` sends
/// `total_deposited`, so an inflated figure makes the transfer exceed the
/// balance and the pool can never be funded.
///
/// LENDER2 deposits and stays. LENDER1 deposits and leaves before borrow.
/// The founder must still be able to borrow what is actually there.
#[test]
fn test_borrow_still_works_after_a_lender_exits_pre_borrow() {
    let usdc = deploy_usdc();
    let pool = deploy_pool();
    let pool_address = pool.contract_address;

    initialize_pool(pool, usdc.contract_address, 30 * SECONDS_PER_DAY);

    start_cheat_caller_address(pool_address, FOUNDER());
    pool.activate();
    stop_cheat_caller_address(pool_address);

    let stays = 2_000 * ONE_USDC;
    let leaves = 1_000 * ONE_USDC;
    usdc.mint(LENDER2(), stays);
    usdc.mint(LENDER1(), leaves);

    start_cheat_caller_address(usdc.contract_address, LENDER2());
    usdc.approve(pool_address, stays);
    stop_cheat_caller_address(usdc.contract_address);
    start_cheat_caller_address(pool_address, LENDER2());
    pool.deposit(stays);
    stop_cheat_caller_address(pool_address);

    start_cheat_caller_address(usdc.contract_address, LENDER1());
    usdc.approve(pool_address, leaves);
    stop_cheat_caller_address(usdc.contract_address);
    start_cheat_caller_address(pool_address, LENDER1());
    pool.deposit(leaves);
    pool.withdraw();
    stop_cheat_caller_address(pool_address);

    // Only LENDER2's money is left in the pool.
    assert(usdc.balance_of(pool_address) == stays, 'Only LENDER2 remains');

    start_cheat_caller_address(pool_address, FOUNDER());
    pool.borrow();
    stop_cheat_caller_address(pool_address);

    assert(usdc.balance_of(FOUNDER()) == stays, 'Founder gets what was there');
}
