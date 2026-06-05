use starknet::ContractAddress;
use starknet::contract_address_const;
use snforge_std_deprecated::{
    declare, ContractClassTrait, DeclareResultTrait,
    start_cheat_caller_address, stop_cheat_caller_address,
    start_cheat_block_timestamp, stop_cheat_block_timestamp,
};

use seedless_contracts::interfaces::i_pool_factory::{
    IPoolFactoryDispatcher, IPoolFactoryDispatcherTrait
};
use seedless_contracts::interfaces::i_credit_pool::{
    ICreditPoolDispatcher, ICreditPoolDispatcherTrait, PoolStatus
};

fn OWNER() -> ContractAddress {
    contract_address_const::<'OWNER'>()
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

fn USDC() -> ContractAddress {
    contract_address_const::<'USDC'>()
}

// Funding deadline: 30 days from timestamp 0 (2592000 seconds)
const FUNDING_DEADLINE: u64 = 2592000;

fn deploy_factory(pool_class_hash: starknet::ClassHash) -> ContractAddress {
    let factory_class = declare("PoolFactory").unwrap().contract_class();

    let mut calldata: Array<felt252> = array![];
    calldata.append(OWNER().into());
    calldata.append(PLATFORM_WALLET().into());
    calldata.append(USDC().into());
    calldata.append(pool_class_hash.into());

    let (factory_address, _) = factory_class.deploy(@calldata).unwrap();
    factory_address
}

#[test]
fn test_factory_deployment() {
    let pool_class = declare("CreditPool").unwrap().contract_class();
    let factory_address = deploy_factory(*pool_class.class_hash);

    let factory = IPoolFactoryDispatcher { contract_address: factory_address };
    let config = factory.get_config();

    assert(config.owner == OWNER(), 'Wrong owner');
    assert(config.platform_wallet == PLATFORM_WALLET(), 'Wrong platform wallet');
    assert(config.usdc_address == USDC(), 'Wrong USDC address');
    assert(config.pool_count == 0, 'Pool count should be 0');
    assert(!config.paused, 'Should not be paused');
}

#[test]
fn test_creation_fee_calculation() {
    let pool_class = declare("CreditPool").unwrap().contract_class();
    let factory_address = deploy_factory(*pool_class.class_hash);
    let factory = IPoolFactoryDispatcher { contract_address: factory_address };

    // Test 1% fee (below cap)
    let small_amount: u256 = 10_000_000_000; // $10,000
    let fee1 = factory.get_creation_fee(small_amount);
    assert(fee1 == 100_000_000, 'Should be 1% = $100'); // $100

    // Test fee cap ($199)
    let large_amount: u256 = 50_000_000_000; // $50,000
    let fee2 = factory.get_creation_fee(large_amount);
    assert(fee2 == 199_000_000, 'Should be capped at $199');
}

#[test]
fn test_pool_info() {
    let pool_class = declare("CreditPool").unwrap().contract_class();
    let (pool_address, _) = pool_class.deploy(@array![]).unwrap();

    let pool = ICreditPoolDispatcher { contract_address: pool_address };

    // Initialize the pool
    pool.initialize(
        contract_address_const::<'FACTORY'>(),
        FOUNDER(),
        USDC(),
        PLATFORM_WALLET(),
        50, // 0.5% repayment fee
        10_000_000_000, // $10,000 cap
        1500, // 15% rate
        365, // 1 year duration
        30, // monthly payments
        FUNDING_DEADLINE,
        'DATA_ROOM_HASH',
    );

    let info = pool.get_pool_info();

    assert(info.founder == FOUNDER(), 'Wrong founder');
    assert(info.cap_amount == 10_000_000_000, 'Wrong cap');
    assert(info.initial_rate_bps == 1500, 'Wrong rate');
    assert(info.current_rate_bps == 1500, 'Current rate should match');
    assert(info.duration_days == 365, 'Wrong duration');
    assert(info.interval_days == 30, 'Wrong interval');
    assert(info.status == PoolStatus::Pending, 'Should be pending');
    assert(info.total_deposited == 0, 'No deposits yet');
    assert(info.lender_count == 0, 'No lenders yet');
}

#[test]
fn test_rate_lowering() {
    let pool_class = declare("CreditPool").unwrap().contract_class();
    let (pool_address, _) = pool_class.deploy(@array![]).unwrap();

    let pool = ICreditPoolDispatcher { contract_address: pool_address };

    pool.initialize(
        contract_address_const::<'FACTORY'>(),
        FOUNDER(),
        USDC(),
        PLATFORM_WALLET(),
        50,
        10_000_000_000,
        1500, // 15% initial rate
        365,
        30,
        FUNDING_DEADLINE,
        'DATA_ROOM_HASH',
    );

    // Lower rate as founder
    start_cheat_caller_address(pool_address, FOUNDER());
    pool.lower_rate(1200); // Lower to 12%
    stop_cheat_caller_address(pool_address);

    let info = pool.get_pool_info();
    assert(info.current_rate_bps == 1200, 'Rate should be 12%');
    assert(info.initial_rate_bps == 1500, 'Initial rate unchanged');
}

#[test]
#[should_panic(expected: ('Can only lower rate',))]
fn test_cannot_increase_rate() {
    let pool_class = declare("CreditPool").unwrap().contract_class();
    let (pool_address, _) = pool_class.deploy(@array![]).unwrap();

    let pool = ICreditPoolDispatcher { contract_address: pool_address };

    pool.initialize(
        contract_address_const::<'FACTORY'>(),
        FOUNDER(),
        USDC(),
        PLATFORM_WALLET(),
        50,
        10_000_000_000,
        1500,
        365,
        30,
        FUNDING_DEADLINE,
        'DATA_ROOM_HASH',
    );

    // Try to increase rate - should fail
    start_cheat_caller_address(pool_address, FOUNDER());
    pool.lower_rate(1800); // Try to increase to 18%
    stop_cheat_caller_address(pool_address);
}

#[test]
fn test_pool_activation() {
    let pool_class = declare("CreditPool").unwrap().contract_class();
    let (pool_address, _) = pool_class.deploy(@array![]).unwrap();

    let pool = ICreditPoolDispatcher { contract_address: pool_address };

    pool.initialize(
        contract_address_const::<'FACTORY'>(),
        FOUNDER(),
        USDC(),
        PLATFORM_WALLET(),
        50,
        10_000_000_000,
        1500,
        365,
        30,
        FUNDING_DEADLINE,
        'DATA_ROOM_HASH',
    );

    let info_before = pool.get_pool_info();
    assert(info_before.status == PoolStatus::Pending, 'Should be pending');

    // Activate as founder
    start_cheat_caller_address(pool_address, FOUNDER());
    pool.activate();
    stop_cheat_caller_address(pool_address);

    let info_after = pool.get_pool_info();
    assert(info_after.status == PoolStatus::Active, 'Should be active');
}

#[test]
#[should_panic(expected: ('Only founder',))]
fn test_only_founder_can_activate() {
    let pool_class = declare("CreditPool").unwrap().contract_class();
    let (pool_address, _) = pool_class.deploy(@array![]).unwrap();

    let pool = ICreditPoolDispatcher { contract_address: pool_address };

    pool.initialize(
        contract_address_const::<'FACTORY'>(),
        FOUNDER(),
        USDC(),
        PLATFORM_WALLET(),
        50,
        10_000_000_000,
        1500,
        365,
        30,
        FUNDING_DEADLINE,
        'DATA_ROOM_HASH',
    );

    // Try to activate as non-founder - should fail
    start_cheat_caller_address(pool_address, LENDER1());
    pool.activate();
    stop_cheat_caller_address(pool_address);
}

#[test]
fn test_expire_pool() {
    let pool_class = declare("CreditPool").unwrap().contract_class();
    let (pool_address, _) = pool_class.deploy(@array![]).unwrap();

    let pool = ICreditPoolDispatcher { contract_address: pool_address };

    // Use a short deadline for testing (1 day = 86400 seconds)
    let short_deadline: u64 = 86400;

    pool.initialize(
        contract_address_const::<'FACTORY'>(),
        FOUNDER(),
        USDC(),
        PLATFORM_WALLET(),
        50,
        10_000_000_000,
        1500,
        365,
        30,
        short_deadline,
        'DATA_ROOM_HASH',
    );

    // Activate the pool
    start_cheat_caller_address(pool_address, FOUNDER());
    pool.activate();
    stop_cheat_caller_address(pool_address);

    let info_before = pool.get_pool_info();
    assert(info_before.status == PoolStatus::Active, 'Should be active');

    // Fast forward past the deadline
    start_cheat_block_timestamp(pool_address, short_deadline + 1);

    // Anyone can call expire after deadline
    start_cheat_caller_address(pool_address, LENDER1());
    pool.expire();
    stop_cheat_caller_address(pool_address);

    stop_cheat_block_timestamp(pool_address);

    let info_after = pool.get_pool_info();
    assert(info_after.status == PoolStatus::Expired, 'Should be expired');
}

#[test]
#[should_panic(expected: ('Deadline not passed',))]
fn test_cannot_expire_before_deadline() {
    let pool_class = declare("CreditPool").unwrap().contract_class();
    let (pool_address, _) = pool_class.deploy(@array![]).unwrap();

    let pool = ICreditPoolDispatcher { contract_address: pool_address };

    pool.initialize(
        contract_address_const::<'FACTORY'>(),
        FOUNDER(),
        USDC(),
        PLATFORM_WALLET(),
        50,
        10_000_000_000,
        1500,
        365,
        30,
        FUNDING_DEADLINE,
        'DATA_ROOM_HASH',
    );

    // Try to expire before deadline - should fail
    pool.expire();
}

#[test]
fn test_cancel_pool() {
    let pool_class = declare("CreditPool").unwrap().contract_class();
    let (pool_address, _) = pool_class.deploy(@array![]).unwrap();

    let pool = ICreditPoolDispatcher { contract_address: pool_address };

    pool.initialize(
        contract_address_const::<'FACTORY'>(),
        FOUNDER(),
        USDC(),
        PLATFORM_WALLET(),
        50,
        10_000_000_000,
        1500,
        365,
        30,
        FUNDING_DEADLINE,
        'DATA_ROOM_HASH',
    );

    let info_before = pool.get_pool_info();
    assert(info_before.status == PoolStatus::Pending, 'Should be pending');

    // Founder cancels the pool
    start_cheat_caller_address(pool_address, FOUNDER());
    pool.cancel();
    stop_cheat_caller_address(pool_address);

    let info_after = pool.get_pool_info();
    assert(info_after.status == PoolStatus::Cancelled, 'Should be cancelled');
}

#[test]
#[should_panic(expected: ('Only founder',))]
fn test_only_founder_can_cancel() {
    let pool_class = declare("CreditPool").unwrap().contract_class();
    let (pool_address, _) = pool_class.deploy(@array![]).unwrap();

    let pool = ICreditPoolDispatcher { contract_address: pool_address };

    pool.initialize(
        contract_address_const::<'FACTORY'>(),
        FOUNDER(),
        USDC(),
        PLATFORM_WALLET(),
        50,
        10_000_000_000,
        1500,
        365,
        30,
        FUNDING_DEADLINE,
        'DATA_ROOM_HASH',
    );

    // Non-founder tries to cancel - should fail
    start_cheat_caller_address(pool_address, LENDER1());
    pool.cancel();
    stop_cheat_caller_address(pool_address);
}

#[test]
fn test_pool_info_includes_last_repayment_at() {
    let pool_class = declare("CreditPool").unwrap().contract_class();
    let (pool_address, _) = pool_class.deploy(@array![]).unwrap();

    let pool = ICreditPoolDispatcher { contract_address: pool_address };

    pool.initialize(
        contract_address_const::<'FACTORY'>(),
        FOUNDER(),
        USDC(),
        PLATFORM_WALLET(),
        50,
        10_000_000_000,
        1500,
        365,
        30,
        FUNDING_DEADLINE,
        'DATA_ROOM_HASH',
    );

    let info = pool.get_pool_info();

    // Before borrowing, last_repayment_at should be 0
    assert(info.last_repayment_at == 0, 'Should be 0 before borrow');
    assert(info.interval_days == 30, 'Should have interval_days');
}
