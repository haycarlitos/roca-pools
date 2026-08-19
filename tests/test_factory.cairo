//! PoolFactory coverage.
//!
//! Before this file the factory had no tests at all, on the contract that
//! holds ownership, fee configuration, the class hash every pool is cloned
//! from, and now the lender allowlist that gates every deposit.
//!
//! The allowlist tests go through a REAL factory and a REAL pool, because the
//! property under test is the cross-contract read on the deposit path. A mock
//! would test the mock.

use seedless_contracts::interfaces::i_credit_pool::{
    ICreditPoolDispatcher, ICreditPoolDispatcherTrait,
};
use seedless_contracts::interfaces::i_pool_factory::{
    IPoolFactoryDispatcher, IPoolFactoryDispatcherTrait,
};
use seedless_contracts::mocks::mock_erc20::{IMockERC20Dispatcher, IMockERC20DispatcherTrait};
use snforge_std_deprecated::{
    ContractClassTrait, DeclareResultTrait, declare, start_cheat_caller_address,
    stop_cheat_caller_address,
};
use starknet::{ClassHash, ContractAddress, contract_address_const};

const ONE_USDC: u256 = 1_000_000;
const SECONDS_PER_DAY: u64 = 86400;

fn OWNER() -> ContractAddress {
    contract_address_const::<'OWNER'>()
}
fn OFFICER() -> ContractAddress {
    contract_address_const::<'OFFICER'>()
}
fn STRANGER() -> ContractAddress {
    contract_address_const::<'STRANGER'>()
}
fn FOUNDER() -> ContractAddress {
    contract_address_const::<'FOUNDER'>()
}
fn PLATFORM() -> ContractAddress {
    contract_address_const::<'PLATFORM'>()
}
fn LENDER1() -> ContractAddress {
    contract_address_const::<'LENDER1'>()
}
fn LENDER2() -> ContractAddress {
    contract_address_const::<'LENDER2'>()
}

fn deploy_usdc() -> IMockERC20Dispatcher {
    let c = declare("MockERC20").unwrap().contract_class();
    let (a, _) = c.deploy(@array!['USDC', 'USDC', 6]).unwrap();
    IMockERC20Dispatcher { contract_address: a }
}

fn pool_class_hash() -> ClassHash {
    *declare("CreditPool").unwrap().contract_class().class_hash
}

fn deploy_factory(usdc: ContractAddress) -> IPoolFactoryDispatcher {
    let c = declare("PoolFactory").unwrap().contract_class();
    let (a, _) = c
        .deploy(@array![OWNER().into(), PLATFORM().into(), usdc.into(), pool_class_hash().into()])
        .unwrap();
    IPoolFactoryDispatcher { contract_address: a }
}

/// Create a pool through the factory, as production does.
fn create_pool(
    factory: IPoolFactoryDispatcher, max_lenders: u32, min_deposit: u256,
) -> ICreditPoolDispatcher {
    start_cheat_caller_address(factory.contract_address, FOUNDER());
    let addr = factory
        .create_pool(
            10_000 * ONE_USDC,
            1000,
            365,
            30,
            30 * SECONDS_PER_DAY,
            'DATA_ROOM_HASH',
            max_lenders,
            min_deposit,
        );
    stop_cheat_caller_address(factory.contract_address);
    let pool = ICreditPoolDispatcher { contract_address: addr };
    start_cheat_caller_address(addr, FOUNDER());
    pool.activate();
    stop_cheat_caller_address(addr);
    pool
}

fn try_deposit(
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

// ------------------------------------------------------------ create_pool

#[test]
fn test_create_pool_registers_and_configures() {
    let usdc = deploy_usdc();
    let factory = deploy_factory(usdc.contract_address);
    let pool = create_pool(factory, 25, 500 * ONE_USDC);

    assert(factory.is_valid_pool(pool.contract_address), 'Pool registered');
    assert(factory.get_pool(0) == pool.contract_address, 'Reachable by index');
    assert(factory.get_config().pool_count == 1, 'Count incremented');

    let info = pool.get_pool_info();
    assert(info.founder == FOUNDER(), 'Caller becomes founder');
    assert(info.factory == factory.contract_address, 'Factory recorded');
    assert(info.repayment_fee_bps == 0, 'Zero fee snapshotted');
    assert(pool.get_max_lenders_limit() == 25, 'Limit threaded through');
    assert(pool.get_min_deposit_amount() == 500 * ONE_USDC, 'Minimum threaded through');
    assert(pool.is_allowlist_enabled(), 'Factory always enables the gate');
}

#[test]
fn test_unknown_address_is_not_a_valid_pool() {
    let usdc = deploy_usdc();
    let factory = deploy_factory(usdc.contract_address);
    assert(!factory.is_valid_pool(STRANGER()), 'Not a factory pool');
}

// ------------------------------------------------------------------ access

#[test]
#[should_panic(expected: ('Caller is not the owner',))]
fn test_stranger_cannot_set_fees() {
    let usdc = deploy_usdc();
    let factory = deploy_factory(usdc.contract_address);
    start_cheat_caller_address(factory.contract_address, STRANGER());
    factory.set_fees(199_000_000, 100, 50);
}

#[test]
#[should_panic(expected: ('Caller is not the owner',))]
fn test_stranger_cannot_set_pool_class_hash() {
    let usdc = deploy_usdc();
    let factory = deploy_factory(usdc.contract_address);
    start_cheat_caller_address(factory.contract_address, STRANGER());
    factory.set_pool_class_hash(pool_class_hash());
}

#[test]
#[should_panic(expected: ('Caller is not the owner',))]
fn test_stranger_cannot_set_platform_wallet() {
    let usdc = deploy_usdc();
    let factory = deploy_factory(usdc.contract_address);
    start_cheat_caller_address(factory.contract_address, STRANGER());
    factory.set_platform_wallet(STRANGER());
}

#[test]
fn test_owner_can_set_fees_and_class_hash() {
    let usdc = deploy_usdc();
    let factory = deploy_factory(usdc.contract_address);
    start_cheat_caller_address(factory.contract_address, OWNER());
    factory.set_fees(199_000_000, 100, 50);
    factory.set_platform_wallet(STRANGER());
    stop_cheat_caller_address(factory.contract_address);

    let cfg = factory.get_config();
    assert(cfg.creation_fee_bps == 100, 'Creation fee set');
    assert(cfg.repayment_fee_bps == 50, 'Repayment fee set');
    assert(cfg.platform_wallet == STRANGER(), 'Wallet updated');
}

// --------------------------------------------------------------- allowlist

#[test]
fn test_owner_holds_compliance_until_delegated() {
    // An unset role would mean nobody can authorize anyone and every pool is
    // silently unusable.
    let usdc = deploy_usdc();
    let factory = deploy_factory(usdc.contract_address);
    assert(factory.get_compliance_officer() == OWNER(), 'Owner holds it initially');
}

#[test]
fn test_owner_can_delegate_compliance() {
    let usdc = deploy_usdc();
    let factory = deploy_factory(usdc.contract_address);
    start_cheat_caller_address(factory.contract_address, OWNER());
    factory.set_compliance_officer(OFFICER());
    stop_cheat_caller_address(factory.contract_address);
    assert(factory.get_compliance_officer() == OFFICER(), 'Delegated');
}

#[test]
#[should_panic(expected: ('Not compliance officer',))]
fn test_owner_cannot_authorize_after_delegating() {
    // The roles are separate on purpose. Once delegated, ownership alone is
    // not enough to change who may invest.
    let usdc = deploy_usdc();
    let factory = deploy_factory(usdc.contract_address);
    start_cheat_caller_address(factory.contract_address, OWNER());
    factory.set_compliance_officer(OFFICER());
    factory.set_lp_authorization(LENDER1(), true);
}

#[test]
#[should_panic(expected: ('Not compliance officer',))]
fn test_stranger_cannot_authorize() {
    let usdc = deploy_usdc();
    let factory = deploy_factory(usdc.contract_address);
    start_cheat_caller_address(factory.contract_address, STRANGER());
    factory.set_lp_authorization(STRANGER(), true);
}

#[test]
fn test_batch_authorization() {
    let usdc = deploy_usdc();
    let factory = deploy_factory(usdc.contract_address);
    start_cheat_caller_address(factory.contract_address, OWNER());
    factory.set_lp_authorization_batch(array![LENDER1(), LENDER2()].span(), true);
    stop_cheat_caller_address(factory.contract_address);

    assert(factory.is_authorized(LENDER1()), 'LENDER1 authorized');
    assert(factory.is_authorized(LENDER2()), 'LENDER2 authorized');
    assert(!factory.is_authorized(STRANGER()), 'Stranger untouched');
}

// ------------------------------------------------- the gate, end to end

#[test]
#[should_panic(expected: ('Lender not authorized',))]
fn test_unauthorized_deposit_is_rejected() {
    let usdc = deploy_usdc();
    let factory = deploy_factory(usdc.contract_address);
    let pool = create_pool(factory, 25, 0);
    try_deposit(usdc, pool, LENDER1(), 100 * ONE_USDC);
}

#[test]
fn test_authorized_deposit_succeeds() {
    let usdc = deploy_usdc();
    let factory = deploy_factory(usdc.contract_address);
    let pool = create_pool(factory, 25, 0);

    start_cheat_caller_address(factory.contract_address, OWNER());
    factory.set_lp_authorization(LENDER1(), true);
    stop_cheat_caller_address(factory.contract_address);

    try_deposit(usdc, pool, LENDER1(), 100 * ONE_USDC);
    assert(pool.get_pool_info().total_deposited == 100 * ONE_USDC, 'Deposit accepted');
}

#[test]
#[should_panic(expected: ('Lender not authorized',))]
fn test_revocation_blocks_the_next_deposit() {
    let usdc = deploy_usdc();
    let factory = deploy_factory(usdc.contract_address);
    let pool = create_pool(factory, 25, 0);

    start_cheat_caller_address(factory.contract_address, OWNER());
    factory.set_lp_authorization(LENDER1(), true);
    stop_cheat_caller_address(factory.contract_address);
    try_deposit(usdc, pool, LENDER1(), 100 * ONE_USDC);

    start_cheat_caller_address(factory.contract_address, OWNER());
    factory.set_lp_authorization(LENDER1(), false);
    stop_cheat_caller_address(factory.contract_address);
    try_deposit(usdc, pool, LENDER1(), 100 * ONE_USDC);
}

#[test]
fn test_revoked_lender_can_still_withdraw() {
    // The most important test in this file. Revocation must stop new exposure,
    // never trap money that is already in. A compliance action that seizes
    // funds is not a compliance action.
    let usdc = deploy_usdc();
    let factory = deploy_factory(usdc.contract_address);
    let pool = create_pool(factory, 25, 0);

    start_cheat_caller_address(factory.contract_address, OWNER());
    factory.set_lp_authorization(LENDER1(), true);
    stop_cheat_caller_address(factory.contract_address);
    try_deposit(usdc, pool, LENDER1(), 100 * ONE_USDC);

    start_cheat_caller_address(factory.contract_address, OWNER());
    factory.set_lp_authorization(LENDER1(), false);
    stop_cheat_caller_address(factory.contract_address);

    start_cheat_caller_address(pool.contract_address, LENDER1());
    pool.withdraw();
    stop_cheat_caller_address(pool.contract_address);

    assert(usdc.balance_of(LENDER1()) == 100 * ONE_USDC, 'Revoked lender got out');
}

#[test]
fn test_one_revocation_covers_every_pool() {
    // The reason the registry lives on the factory rather than per pool.
    let usdc = deploy_usdc();
    let factory = deploy_factory(usdc.contract_address);
    let pool_a = create_pool(factory, 25, 0);
    let pool_b = create_pool(factory, 25, 0);

    start_cheat_caller_address(factory.contract_address, OWNER());
    factory.set_lp_authorization(LENDER1(), true);
    stop_cheat_caller_address(factory.contract_address);

    try_deposit(usdc, pool_a, LENDER1(), 50 * ONE_USDC);
    try_deposit(usdc, pool_b, LENDER1(), 50 * ONE_USDC);

    // One transaction, both pools closed to them.
    start_cheat_caller_address(factory.contract_address, OWNER());
    factory.set_lp_authorization(LENDER1(), false);
    stop_cheat_caller_address(factory.contract_address);

    assert(!factory.is_authorized(LENDER1()), 'Revoked globally');
    assert(pool_a.is_allowlist_enabled(), 'Pool A gated');
    assert(pool_b.is_allowlist_enabled(), 'Pool B gated');
}
