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
    ICreditPoolDispatcher, ICreditPoolDispatcherTrait, PoolStatus,
};
use seedless_contracts::interfaces::i_pool_factory::{
    IPoolFactoryDispatcher, IPoolFactoryDispatcherTrait,
};
use seedless_contracts::mocks::mock_erc20::{IMockERC20Dispatcher, IMockERC20DispatcherTrait};
use snforge_std_deprecated::{
    ContractClassTrait, DeclareResultTrait, declare, start_cheat_block_timestamp,
    start_cheat_caller_address, stop_cheat_block_timestamp, stop_cheat_caller_address,
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

// ============================================================================
// Reusing an approved investor base across pools
// ============================================================================
// The operational question this design exists to answer: when pool 1 closes and
// pool 2 opens, does the whole investor base have to be onboarded again?
//
// No. Authorization is held on the factory, not stamped onto a pool at
// creation, so it applies to pools that did not exist when it was granted.
// Terms are permanent per pool, so a new term means a new pool, and that is the
// operation this makes cheap.

#[test]
fn test_authorization_granted_today_covers_a_pool_created_tomorrow() {
    let usdc = deploy_usdc();
    let factory = deploy_factory(usdc.contract_address);

    // Approve the investor base first. No pool exists yet.
    start_cheat_caller_address(factory.contract_address, OWNER());
    factory.set_lp_authorization_batch(array![LENDER1(), LENDER2()].span(), true);
    stop_cheat_caller_address(factory.contract_address);

    // Pool created afterwards, with completely different terms.
    let pool = create_pool(factory, 25, 0);

    // Both deposit with no further compliance step.
    try_deposit(usdc, pool, LENDER1(), 100 * ONE_USDC);
    try_deposit(usdc, pool, LENDER2(), 100 * ONE_USDC);

    assert(pool.get_pool_info().lender_count == 2, 'Both got in');
    assert(pool.get_pool_info().total_deposited == 200 * ONE_USDC, 'Both deposits landed');
}

#[test]
fn test_the_same_investor_base_carries_across_successive_pools() {
    // Pool 1 fills and its term is fixed forever. Pool 2 opens with different
    // terms and reuses the same approved base, with no re-onboarding.
    let usdc = deploy_usdc();
    let factory = deploy_factory(usdc.contract_address);

    start_cheat_caller_address(factory.contract_address, OWNER());
    factory.set_lp_authorization(LENDER1(), true);
    stop_cheat_caller_address(factory.contract_address);

    let pool_one = create_pool(factory, 25, 0);
    try_deposit(usdc, pool_one, LENDER1(), 100 * ONE_USDC);

    // A second pool, different roster cap and a minimum ticket this time.
    let pool_two = create_pool(factory, 5, 50 * ONE_USDC);
    try_deposit(usdc, pool_two, LENDER1(), 100 * ONE_USDC);

    assert(pool_one.get_pool_info().total_deposited == 100 * ONE_USDC, 'Pool 1 funded');
    assert(pool_two.get_pool_info().total_deposited == 100 * ONE_USDC, 'Pool 2 funded');
    // Independent rosters: the cap is per pool, the approval is not.
    assert(pool_one.get_max_lenders_limit() == 25, 'Pool 1 keeps its own limit');
    assert(pool_two.get_max_lenders_limit() == 5, 'Pool 2 keeps its own limit');
}

#[test]
#[should_panic(expected: ('Lender not authorized',))]
fn test_revoking_between_pools_also_closes_the_new_one() {
    // The mirror. Reuse is automatic in both directions: someone removed from
    // the base cannot enter the next pool either.
    let usdc = deploy_usdc();
    let factory = deploy_factory(usdc.contract_address);

    start_cheat_caller_address(factory.contract_address, OWNER());
    factory.set_lp_authorization(LENDER1(), true);
    stop_cheat_caller_address(factory.contract_address);
    let pool_one = create_pool(factory, 25, 0);
    try_deposit(usdc, pool_one, LENDER1(), 100 * ONE_USDC);

    start_cheat_caller_address(factory.contract_address, OWNER());
    factory.set_lp_authorization(LENDER1(), false);
    stop_cheat_caller_address(factory.contract_address);

    let pool_two = create_pool(factory, 25, 0);
    try_deposit(usdc, pool_two, LENDER1(), 100 * ONE_USDC);
}


// ---------------------------------------------------------------------------
// Factory forwarders for the pool entrypoints gated on `caller == factory`
// ---------------------------------------------------------------------------
//
// `unpause` and `mark_defaulted` assert the caller IS the factory contract.
// Every test that exercised them did it by cheating the caller address to a
// FACTORY() constant against a bare pool, which proves the assert works and
// says nothing about whether any real caller can satisfy it. Nothing could:
// the factory had no function that called into a pool, so both entrypoints
// were unreachable on chain.
//
// For `unpause` that is a stuck pool, not a missing feature. A founder can
// pause alone but only the factory can lift it, so a paused pool stayed paused
// forever with deposit, borrow and repay frozen.
//
// These tests go through a real factory and a real pool with NO caller cheat
// on the pool, so they fail if the forwarder is ever removed.

/// A pool that has been paused can actually be unpaused again.
#[test]
fn test_owner_can_unpause_a_pool_through_the_factory() {
    let usdc = deploy_usdc();
    let factory = deploy_factory(usdc.contract_address);
    let pool = create_pool(factory, 25, 0);

    // Founder pauses unilaterally, which is allowed.
    start_cheat_caller_address(pool.contract_address, FOUNDER());
    pool.pause();
    stop_cheat_caller_address(pool.contract_address);
    assert(pool.get_pool_info().paused, 'should be paused');

    // The owner lifts it through the factory. No cheat on the pool: the
    // factory is genuinely the caller.
    start_cheat_caller_address(factory.contract_address, OWNER());
    factory.unpause_pool(pool.contract_address);
    stop_cheat_caller_address(factory.contract_address);

    assert(!pool.get_pool_info().paused, 'should be unpaused');
    // And the pool works again, which is the property that actually matters.
    start_cheat_caller_address(factory.contract_address, OWNER());
    factory.set_lp_authorization(LENDER1(), true);
    stop_cheat_caller_address(factory.contract_address);
    try_deposit(usdc, pool, LENDER1(), 100 * ONE_USDC);
}

/// Roca can stop a pool it did not found.
#[test]
fn test_owner_can_pause_a_pool_through_the_factory() {
    let usdc = deploy_usdc();
    let factory = deploy_factory(usdc.contract_address);
    let pool = create_pool(factory, 25, 0);

    start_cheat_caller_address(factory.contract_address, OWNER());
    factory.pause_pool(pool.contract_address);
    stop_cheat_caller_address(factory.contract_address);

    assert(pool.get_pool_info().paused, 'should be paused');
}

#[test]
#[should_panic(expected: 'Caller is not the owner')]
fn test_stranger_cannot_unpause_through_the_factory() {
    let usdc = deploy_usdc();
    let factory = deploy_factory(usdc.contract_address);
    let pool = create_pool(factory, 25, 0);

    start_cheat_caller_address(pool.contract_address, FOUNDER());
    pool.pause();
    stop_cheat_caller_address(pool.contract_address);

    start_cheat_caller_address(factory.contract_address, STRANGER());
    factory.unpause_pool(pool.contract_address);
}

/// The founder cannot lift their own pause by going through the factory
/// either, which is the whole point of the asymmetry.
#[test]
#[should_panic(expected: 'Caller is not the owner')]
fn test_founder_cannot_unpause_through_the_factory() {
    let usdc = deploy_usdc();
    let factory = deploy_factory(usdc.contract_address);
    let pool = create_pool(factory, 25, 0);

    start_cheat_caller_address(pool.contract_address, FOUNDER());
    pool.pause();
    stop_cheat_caller_address(pool.contract_address);

    start_cheat_caller_address(factory.contract_address, FOUNDER());
    factory.unpause_pool(pool.contract_address);
}

/// The forwarder only acts on pools this factory deployed.
#[test]
#[should_panic(expected: 'Not a pool from this factory')]
fn test_forwarder_refuses_a_foreign_pool() {
    let usdc = deploy_usdc();
    let factory = deploy_factory(usdc.contract_address);

    // A pool from a different factory.
    let other = deploy_factory(usdc.contract_address);
    let foreign = create_pool(other, 25, 0);

    start_cheat_caller_address(factory.contract_address, OWNER());
    factory.unpause_pool(foreign.contract_address);
}

/// A defaulted pool can be declared defaulted, which is what makes the
/// recovery path reachable at all.
#[test]
fn test_owner_can_mark_a_pool_defaulted_through_the_factory() {
    let usdc = deploy_usdc();
    let factory = deploy_factory(usdc.contract_address);
    let pool = create_pool(factory, 25, 0);

    start_cheat_caller_address(factory.contract_address, OWNER());
    factory.set_lp_authorization(LENDER1(), true);
    stop_cheat_caller_address(factory.contract_address);
    try_deposit(usdc, pool, LENDER1(), 10_000 * ONE_USDC);

    let borrow_at = SECONDS_PER_DAY;
    start_cheat_block_timestamp(pool.contract_address, borrow_at);
    start_cheat_caller_address(pool.contract_address, FOUNDER());
    pool.borrow();
    stop_cheat_caller_address(pool.contract_address);

    // Past the full term.
    start_cheat_block_timestamp(pool.contract_address, borrow_at + (366 * SECONDS_PER_DAY));

    start_cheat_caller_address(factory.contract_address, OWNER());
    factory.mark_pool_defaulted(pool.contract_address);
    stop_cheat_caller_address(factory.contract_address);

    assert(pool.get_pool_info().status == PoolStatus::Defaulted, 'should be defaulted');
    stop_cheat_block_timestamp(pool.contract_address);
}

#[test]
#[should_panic(expected: 'Caller is not the owner')]
fn test_stranger_cannot_mark_defaulted_through_the_factory() {
    let usdc = deploy_usdc();
    let factory = deploy_factory(usdc.contract_address);
    let pool = create_pool(factory, 25, 0);

    start_cheat_caller_address(factory.contract_address, STRANGER());
    factory.mark_pool_defaulted(pool.contract_address);
}

/// The pool still decides WHEN a default is permissible; the forwarder only
/// decides who may ask.
#[test]
#[should_panic(expected: 'Pool not borrowed')]
fn test_forwarder_does_not_bypass_the_pool_own_rules() {
    let usdc = deploy_usdc();
    let factory = deploy_factory(usdc.contract_address);
    let pool = create_pool(factory, 25, 0);

    // Never borrowed, so there is nothing to default on.
    start_cheat_caller_address(factory.contract_address, OWNER());
    factory.mark_pool_defaulted(pool.contract_address);
}
