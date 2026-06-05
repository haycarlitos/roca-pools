use starknet::ContractAddress;
use starknet::contract_address_const;
use snforge_std_deprecated::{
    declare, ContractClassTrait, DeclareResultTrait,
    start_cheat_caller_address, stop_cheat_caller_address,
    start_cheat_block_timestamp, stop_cheat_block_timestamp,
};

use seedless_contracts::interfaces::i_credit_pool::{
    ICreditPoolDispatcher, ICreditPoolDispatcherTrait, PoolStatus
};
use seedless_contracts::mocks::mock_erc20::{
    IMockERC20Dispatcher, IMockERC20DispatcherTrait
};

// Constants
const USDC_DECIMALS: u8 = 6;
const ONE_USDC: u256 = 1_000_000;
const SECONDS_PER_DAY: u64 = 86400;
const FUNDING_DEADLINE: u64 = 30 * 86400; // 30 days

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

fn RANDOM_USER() -> ContractAddress {
    contract_address_const::<'RANDOM'>()
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
fn initialize_pool(pool: ICreditPoolDispatcher, usdc: ContractAddress) {
    pool.initialize(
        FACTORY(),
        FOUNDER(),
        usdc,
        PLATFORM_WALLET(),
        50, // 0.5% repayment fee
        10_000 * ONE_USDC, // $10,000 cap
        1000, // 10% annual rate
        365, // 1 year duration
        30, // monthly interval
        FUNDING_DEADLINE,
        'DATA_ROOM_HASH',
    );
}

// ============================================
// PAUSE AUTHORIZATION TESTS
// ============================================

#[test]
fn test_founder_can_pause() {
    let usdc = deploy_usdc();
    let pool = deploy_pool();
    let pool_address = pool.contract_address;

    initialize_pool(pool, usdc.contract_address);

    // Verify not paused initially
    let info_before = pool.get_pool_info();
    assert(!info_before.paused, 'Should not be paused initially');

    // Founder pauses
    start_cheat_caller_address(pool_address, FOUNDER());
    pool.pause();
    stop_cheat_caller_address(pool_address);

    let info_after = pool.get_pool_info();
    assert(info_after.paused, 'Should be paused');
}

#[test]
fn test_factory_can_pause() {
    let usdc = deploy_usdc();
    let pool = deploy_pool();
    let pool_address = pool.contract_address;

    initialize_pool(pool, usdc.contract_address);

    // Factory pauses
    start_cheat_caller_address(pool_address, FACTORY());
    pool.pause();
    stop_cheat_caller_address(pool_address);

    let info = pool.get_pool_info();
    assert(info.paused, 'Should be paused');
}

#[test]
#[should_panic(expected: ('Not authorized to pause',))]
fn test_random_user_cannot_pause() {
    let usdc = deploy_usdc();
    let pool = deploy_pool();
    let pool_address = pool.contract_address;

    initialize_pool(pool, usdc.contract_address);

    // Random user tries to pause - should fail
    start_cheat_caller_address(pool_address, RANDOM_USER());
    pool.pause();
    stop_cheat_caller_address(pool_address);
}

#[test]
#[should_panic(expected: ('Not authorized to pause',))]
fn test_lender_cannot_pause() {
    let usdc = deploy_usdc();
    let pool = deploy_pool();
    let pool_address = pool.contract_address;

    initialize_pool(pool, usdc.contract_address);

    // Lender tries to pause - should fail
    start_cheat_caller_address(pool_address, LENDER1());
    pool.pause();
    stop_cheat_caller_address(pool_address);
}

// ============================================
// UNPAUSE AUTHORIZATION TESTS
// ============================================

#[test]
fn test_factory_can_unpause() {
    let usdc = deploy_usdc();
    let pool = deploy_pool();
    let pool_address = pool.contract_address;

    initialize_pool(pool, usdc.contract_address);

    // Founder pauses
    start_cheat_caller_address(pool_address, FOUNDER());
    pool.pause();
    stop_cheat_caller_address(pool_address);

    // Factory unpauses
    start_cheat_caller_address(pool_address, FACTORY());
    pool.unpause();
    stop_cheat_caller_address(pool_address);

    let info = pool.get_pool_info();
    assert(!info.paused, 'Should be unpaused');
}

#[test]
#[should_panic(expected: ('Only factory can unpause',))]
fn test_founder_cannot_unpause() {
    let usdc = deploy_usdc();
    let pool = deploy_pool();
    let pool_address = pool.contract_address;

    initialize_pool(pool, usdc.contract_address);

    // Founder pauses
    start_cheat_caller_address(pool_address, FOUNDER());
    pool.pause();
    stop_cheat_caller_address(pool_address);

    // Founder tries to unpause - should fail (only factory can unpause)
    start_cheat_caller_address(pool_address, FOUNDER());
    pool.unpause();
    stop_cheat_caller_address(pool_address);
}

// ============================================
// PAUSE STATE TESTS
// ============================================

#[test]
#[should_panic(expected: ('Already paused',))]
fn test_cannot_pause_twice() {
    let usdc = deploy_usdc();
    let pool = deploy_pool();
    let pool_address = pool.contract_address;

    initialize_pool(pool, usdc.contract_address);

    // Pause once
    start_cheat_caller_address(pool_address, FOUNDER());
    pool.pause();

    // Try to pause again - should fail
    pool.pause();
    stop_cheat_caller_address(pool_address);
}

#[test]
#[should_panic(expected: ('Not paused',))]
fn test_cannot_unpause_when_not_paused() {
    let usdc = deploy_usdc();
    let pool = deploy_pool();
    let pool_address = pool.contract_address;

    initialize_pool(pool, usdc.contract_address);

    // Try to unpause when not paused - should fail
    start_cheat_caller_address(pool_address, FACTORY());
    pool.unpause();
    stop_cheat_caller_address(pool_address);
}

// ============================================
// PAUSED OPERATIONS TESTS
// ============================================

#[test]
#[should_panic(expected: ('Pool is paused',))]
fn test_cannot_deposit_when_paused() {
    let usdc = deploy_usdc();
    let pool = deploy_pool();
    let pool_address = pool.contract_address;

    initialize_pool(pool, usdc.contract_address);

    // Activate pool
    start_cheat_caller_address(pool_address, FOUNDER());
    pool.activate();
    stop_cheat_caller_address(pool_address);

    // Pause the pool
    start_cheat_caller_address(pool_address, FOUNDER());
    pool.pause();
    stop_cheat_caller_address(pool_address);

    // Mint USDC to lender and approve
    let deposit_amount = 1_000 * ONE_USDC;
    usdc.mint(LENDER1(), deposit_amount);
    start_cheat_caller_address(usdc.contract_address, LENDER1());
    usdc.approve(pool_address, deposit_amount);
    stop_cheat_caller_address(usdc.contract_address);

    // Try to deposit - should fail
    start_cheat_caller_address(pool_address, LENDER1());
    pool.deposit(deposit_amount);
    stop_cheat_caller_address(pool_address);
}

#[test]
#[should_panic(expected: ('Pool is paused',))]
fn test_cannot_borrow_when_paused() {
    let usdc = deploy_usdc();
    let pool = deploy_pool();
    let pool_address = pool.contract_address;

    initialize_pool(pool, usdc.contract_address);

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

    // Pause the pool
    start_cheat_caller_address(pool_address, FOUNDER());
    pool.pause();
    stop_cheat_caller_address(pool_address);

    // Try to borrow - should fail
    start_cheat_caller_address(pool_address, FOUNDER());
    pool.borrow();
    stop_cheat_caller_address(pool_address);
}

#[test]
#[should_panic(expected: ('Pool is paused',))]
fn test_cannot_repay_when_paused() {
    let usdc = deploy_usdc();
    let pool = deploy_pool();
    let pool_address = pool.contract_address;

    initialize_pool(pool, usdc.contract_address);

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
    start_cheat_caller_address(pool_address, FOUNDER());
    pool.borrow();
    stop_cheat_caller_address(pool_address);

    // Pause the pool (by factory since founder borrowed)
    start_cheat_caller_address(pool_address, FACTORY());
    pool.pause();
    stop_cheat_caller_address(pool_address);

    // Mint USDC for repayment
    let repay_amount = 100 * ONE_USDC;
    usdc.mint(FOUNDER(), repay_amount);
    start_cheat_caller_address(usdc.contract_address, FOUNDER());
    usdc.approve(pool_address, repay_amount);
    stop_cheat_caller_address(usdc.contract_address);

    // Try to repay - should fail
    start_cheat_caller_address(pool_address, FOUNDER());
    pool.repay(repay_amount);
    stop_cheat_caller_address(pool_address);
}

// ============================================
// LENDER PROTECTION - WITHDRAW WHEN PAUSED
// ============================================

#[test]
fn test_can_withdraw_when_paused() {
    let usdc = deploy_usdc();
    let pool = deploy_pool();
    let pool_address = pool.contract_address;

    initialize_pool(pool, usdc.contract_address);

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

    // Verify deposit
    assert(usdc.balance_of(LENDER1()) == 0, 'Lender should have 0 USDC');
    assert(usdc.balance_of(pool_address) == deposit_amount, 'Pool should have deposit');

    // Pause the pool
    start_cheat_caller_address(pool_address, FOUNDER());
    pool.pause();
    stop_cheat_caller_address(pool_address);

    // Lender can still withdraw when paused (lender protection)
    start_cheat_caller_address(pool_address, LENDER1());
    pool.withdraw();
    stop_cheat_caller_address(pool_address);

    // Verify lender got funds back
    assert(usdc.balance_of(LENDER1()) == deposit_amount, 'Lender should have USDC back');
}

// ============================================
// FULL PAUSE/UNPAUSE CYCLE
// ============================================

#[test]
fn test_full_pause_unpause_cycle() {
    let usdc = deploy_usdc();
    let pool = deploy_pool();
    let pool_address = pool.contract_address;

    initialize_pool(pool, usdc.contract_address);

    // Activate pool
    start_cheat_caller_address(pool_address, FOUNDER());
    pool.activate();
    stop_cheat_caller_address(pool_address);

    let info1 = pool.get_pool_info();
    assert(!info1.paused, 'Should not be paused');

    // Founder pauses
    start_cheat_caller_address(pool_address, FOUNDER());
    pool.pause();
    stop_cheat_caller_address(pool_address);

    let info2 = pool.get_pool_info();
    assert(info2.paused, 'Should be paused');

    // Factory unpauses
    start_cheat_caller_address(pool_address, FACTORY());
    pool.unpause();
    stop_cheat_caller_address(pool_address);

    let info3 = pool.get_pool_info();
    assert(!info3.paused, 'Should be unpaused');

    // Now operations should work again
    let deposit_amount = 1_000 * ONE_USDC;
    usdc.mint(LENDER1(), deposit_amount);
    start_cheat_caller_address(usdc.contract_address, LENDER1());
    usdc.approve(pool_address, deposit_amount);
    stop_cheat_caller_address(usdc.contract_address);

    // Deposit should succeed after unpause
    start_cheat_caller_address(pool_address, LENDER1());
    pool.deposit(deposit_amount);
    stop_cheat_caller_address(pool_address);

    let info4 = pool.get_pool_info();
    assert(info4.total_deposited == deposit_amount, 'Deposit should succeed');
}

// ============================================
// EXPIRE AND CANCEL STILL WORK WHEN PAUSED
// ============================================

#[test]
fn test_can_expire_when_paused() {
    let usdc = deploy_usdc();
    let pool = deploy_pool();
    let pool_address = pool.contract_address;

    // Use short deadline
    let short_deadline: u64 = SECONDS_PER_DAY;
    pool.initialize(
        FACTORY(),
        FOUNDER(),
        usdc.contract_address,
        PLATFORM_WALLET(),
        50,
        10_000 * ONE_USDC,
        1000,
        365,
        30,
        short_deadline,
        'DATA_ROOM_HASH',
    );

    // Activate pool
    start_cheat_caller_address(pool_address, FOUNDER());
    pool.activate();
    stop_cheat_caller_address(pool_address);

    // Pause the pool
    start_cheat_caller_address(pool_address, FOUNDER());
    pool.pause();
    stop_cheat_caller_address(pool_address);

    // Fast forward past deadline
    start_cheat_block_timestamp(pool_address, short_deadline + 1);

    // Expire should still work when paused
    pool.expire();

    stop_cheat_block_timestamp(pool_address);

    let info = pool.get_pool_info();
    assert(info.status == PoolStatus::Expired, 'Should be expired');
}

#[test]
fn test_can_cancel_when_paused() {
    let usdc = deploy_usdc();
    let pool = deploy_pool();
    let pool_address = pool.contract_address;

    initialize_pool(pool, usdc.contract_address);

    // Pause the pool
    start_cheat_caller_address(pool_address, FOUNDER());
    pool.pause();
    stop_cheat_caller_address(pool_address);

    // Cancel should still work when paused
    start_cheat_caller_address(pool_address, FOUNDER());
    pool.cancel();
    stop_cheat_caller_address(pool_address);

    let info = pool.get_pool_info();
    assert(info.status == PoolStatus::Cancelled, 'Should be cancelled');
}
