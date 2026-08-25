//! Delta re-review of 5e313ed — reachability-aware evidence.
//!
//! The existing suite reaches the factory-gated pool entrypoints by cheating
//! the caller to a FACTORY() constant against a bare pool. That proves the
//! assert fires; it says nothing about whether a real on-chain caller can
//! satisfy it. These tests drive the NEW owner-gated forwarders through a REAL
//! factory and a REAL pool, so msg.sender into the pool is the factory
//! contract itself — the only address its `caller == factory` check accepts.
//!
//! Two properties under test:
//!   A. Withdrawal survives a pause applied through the newly reachable
//!      owner -> factory -> pool path (inviolable property, invariant 2).
//!   B. A full recovery does not relabel a defaulted pool (invariant 9),
//!      exercised through the real mark_pool_defaulted forwarder rather than a
//!      cheated caller.
//!
//! Both PASS: the diff is safe on these axes. They are verification, not
//! exploits — no Critical/High was found in the diff to reproduce.

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
const DAY: u64 = 86400;

fn OWNER() -> ContractAddress {
    contract_address_const::<'OWNER'>()
}
fn PLATFORM() -> ContractAddress {
    contract_address_const::<'PLATFORM'>()
}
fn FOUNDER() -> ContractAddress {
    contract_address_const::<'FOUNDER'>()
}
fn LENDER1() -> ContractAddress {
    contract_address_const::<'LENDER1'>()
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

// Create + activate a pool through the factory exactly as production does.
fn create_pool(factory: IPoolFactoryDispatcher) -> ICreditPoolDispatcher {
    start_cheat_caller_address(factory.contract_address, FOUNDER());
    let addr = factory.create_pool(10_000 * ONE_USDC, 1000, 365, 30, 30 * DAY, 'HASH', 100, 0);
    stop_cheat_caller_address(factory.contract_address);
    let pool = ICreditPoolDispatcher { contract_address: addr };
    start_cheat_caller_address(addr, FOUNDER());
    pool.activate();
    stop_cheat_caller_address(addr);
    pool
}

// Compliance officer defaults to the owner, so OWNER authorizes lenders.
fn authorize(factory: IPoolFactoryDispatcher, lp: ContractAddress) {
    start_cheat_caller_address(factory.contract_address, OWNER());
    factory.set_lp_authorization(lp, true);
    stop_cheat_caller_address(factory.contract_address);
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

// PROPERTY A — withdrawal is never blocked by pause, including the pause the
// owner can now apply through the factory. Reached end-to-end: OWNER calls the
// factory, the factory calls the pool.
#[test]
fn test_withdrawal_survives_an_owner_pause_through_the_factory() {
    let usdc = deploy_usdc();
    let factory = deploy_factory(usdc.contract_address);
    authorize(factory, LENDER1());
    let pool = create_pool(factory);

    deposit_as(usdc, pool, LENDER1(), 1_000 * ONE_USDC);

    // NEW authority: the owner pauses a pool it did not found, via the factory.
    start_cheat_caller_address(factory.contract_address, OWNER());
    factory.pause_pool(pool.contract_address);
    stop_cheat_caller_address(factory.contract_address);
    assert(pool.get_pool_info().paused, 'pool is paused by owner');

    // The lender can still exit in full while the pool is owner-paused.
    start_cheat_caller_address(pool.contract_address, LENDER1());
    pool.withdraw();
    stop_cheat_caller_address(pool.contract_address);
    assert(usdc.balance_of(LENDER1()) == 1_000 * ONE_USDC, 'withdrawal not blocked by pause');
    assert(pool.get_pool_info().paused, 'still paused after withdraw');

    // And the owner can lift it — the entrypoint that used to be unreachable.
    start_cheat_caller_address(factory.contract_address, OWNER());
    factory.unpause_pool(pool.contract_address);
    stop_cheat_caller_address(factory.contract_address);
    assert(!pool.get_pool_info().paused, 'owner can unpause');
}

// PROPERTY B — a full recovery does not relabel a defaulted pool, driven
// through the real mark_pool_defaulted forwarder (owner -> factory -> pool).
#[test]
fn test_full_recovery_through_factory_keeps_pool_defaulted() {
    let usdc = deploy_usdc();
    let factory = deploy_factory(usdc.contract_address);
    authorize(factory, LENDER1());
    let pool = create_pool(factory);

    deposit_as(usdc, pool, LENDER1(), 1_000 * ONE_USDC); // owed = 1100 at 10%

    start_cheat_caller_address(pool.contract_address, FOUNDER());
    pool.borrow();
    stop_cheat_caller_address(pool.contract_address);

    // Term elapses; owner defaults the pool through the factory forwarder.
    start_cheat_block_timestamp(pool.contract_address, 400 * DAY);
    start_cheat_caller_address(factory.contract_address, OWNER());
    factory.mark_pool_defaulted(pool.contract_address);
    stop_cheat_caller_address(factory.contract_address);
    assert(pool.get_pool_info().status == PoolStatus::Defaulted, 'defaulted');

    // Founder recovers and repays the FULL amount owed.
    usdc.mint(FOUNDER(), 1_100 * ONE_USDC);
    start_cheat_caller_address(usdc.contract_address, FOUNDER());
    usdc.approve(pool.contract_address, 1_100 * ONE_USDC);
    stop_cheat_caller_address(usdc.contract_address);
    start_cheat_caller_address(pool.contract_address, FOUNDER());
    pool.repay(1_100 * ONE_USDC);
    stop_cheat_caller_address(pool.contract_address);

    // Full recovery must NOT relabel it Completed (fffb6d8 / invariant 9).
    assert(pool.get_pool_info().status == PoolStatus::Defaulted, 'stays defaulted after recovery');

    // Lender is still paid in full pro-rata, in the Defaulted state.
    start_cheat_caller_address(pool.contract_address, LENDER1());
    pool.withdraw();
    stop_cheat_caller_address(pool.contract_address);
    stop_cheat_block_timestamp(pool.contract_address);
    assert(usdc.balance_of(LENDER1()) == 1_100 * ONE_USDC, 'lender paid in full');
}
