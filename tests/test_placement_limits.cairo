//! Placement limits: minimum ticket, lender cap, and roster slot release.
//!
//! The cap and the minimum only work together. A minimum ticket alone does not
//! stop roster squatting, because the ticket is refundable before `borrow`: one
//! wallet could deposit the minimum, withdraw it, keep the slot, and repeat
//! until the pool is unfillable at zero capital cost. Releasing the slot on a
//! full pre-borrow exit is what makes the minimum bind.

use seedless_contracts::interfaces::i_credit_pool::{
    ICreditPoolDispatcher, ICreditPoolDispatcherTrait,
};
use seedless_contracts::mocks::mock_erc20::{IMockERC20Dispatcher, IMockERC20DispatcherTrait};
use snforge_std_deprecated::{
    ContractClassTrait, DeclareResultTrait, declare, start_cheat_caller_address,
    stop_cheat_caller_address,
};
use starknet::{ContractAddress, contract_address_const};

const USDC_DECIMALS: u8 = 6;
const ONE_USDC: u256 = 1_000_000;
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
fn LENDER3() -> ContractAddress {
    contract_address_const::<'LENDER3'>()
}

fn deploy_usdc() -> IMockERC20Dispatcher {
    let c = declare("MockERC20").unwrap().contract_class();
    let (a, _) = c.deploy(@array!['USDC', 'USDC', USDC_DECIMALS.into()]).unwrap();
    IMockERC20Dispatcher { contract_address: a }
}

fn deploy_pool() -> ICreditPoolDispatcher {
    let c = declare("CreditPool").unwrap().contract_class();
    let (a, _) = c.deploy(@array![]).unwrap();
    ICreditPoolDispatcher { contract_address: a }
}

/// Pool with an explicit roster cap and minimum ticket, already Active.
fn setup(
    max_lenders: u32, min_deposit: u256, cap: u256,
) -> (IMockERC20Dispatcher, ICreditPoolDispatcher) {
    let usdc = deploy_usdc();
    let pool = deploy_pool();
    pool
        .initialize(
            FACTORY(),
            FOUNDER(),
            usdc.contract_address,
            PLATFORM_WALLET(),
            50,
            cap,
            1000,
            365,
            30,
            30 * SECONDS_PER_DAY,
            'DATA_ROOM_HASH',
            max_lenders,
            min_deposit,
            false,
        );
    start_cheat_caller_address(pool.contract_address, FOUNDER());
    pool.activate();
    stop_cheat_caller_address(pool.contract_address);
    (usdc, pool)
}

fn fund_and_deposit(
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

// ---------------------------------------------------------------- minimum

#[test]
#[should_panic(expected: ('Below min deposit',))]
fn test_first_deposit_below_minimum_is_rejected() {
    let (usdc, pool) = setup(10, 500 * ONE_USDC, 10_000 * ONE_USDC);
    fund_and_deposit(usdc, pool, LENDER1(), 100 * ONE_USDC);
}

#[test]
fn test_top_up_may_be_below_the_minimum() {
    // The minimum gates joining, not adding. An existing lender must not have
    // to clear it twice.
    let (usdc, pool) = setup(10, 500 * ONE_USDC, 10_000 * ONE_USDC);
    fund_and_deposit(usdc, pool, LENDER1(), 500 * ONE_USDC);
    fund_and_deposit(usdc, pool, LENDER1(), 1 * ONE_USDC);

    let info = pool.get_pool_info();
    assert(info.total_deposited == 501 * ONE_USDC, 'Top-up accepted');
    assert(info.lender_count == 1, 'Still one lender');
}

#[test]
fn test_remaining_headroom_below_minimum_is_still_fillable() {
    // Without this exception the last slice of every pool is unsellable and a
    // cap-triggered activation could never fire.
    let cap = 1_000 * ONE_USDC;
    let (usdc, pool) = setup(10, 400 * ONE_USDC, cap);
    fund_and_deposit(usdc, pool, LENDER1(), 800 * ONE_USDC);

    // 200 left, which is below the 400 minimum, but it is exactly the rest.
    fund_and_deposit(usdc, pool, LENDER2(), 200 * ONE_USDC);

    let info = pool.get_pool_info();
    assert(info.total_deposited == cap, 'Pool reached its cap');
    assert(info.lender_count == 2, 'Both lenders counted');
}

// ------------------------------------------------------------- roster cap

#[test]
#[should_panic(expected: ('Max lenders reached',))]
fn test_roster_cap_blocks_the_next_lender() {
    let (usdc, pool) = setup(2, 0, 10_000 * ONE_USDC);
    fund_and_deposit(usdc, pool, LENDER1(), 100 * ONE_USDC);
    fund_and_deposit(usdc, pool, LENDER2(), 100 * ONE_USDC);
    fund_and_deposit(usdc, pool, LENDER3(), 100 * ONE_USDC);
}

#[test]
fn test_existing_lender_can_top_up_a_full_pool() {
    // The cap counts lenders, not deposits. A full roster must not freeze the
    // lenders already in it.
    let (usdc, pool) = setup(2, 0, 10_000 * ONE_USDC);
    fund_and_deposit(usdc, pool, LENDER1(), 100 * ONE_USDC);
    fund_and_deposit(usdc, pool, LENDER2(), 100 * ONE_USDC);
    fund_and_deposit(usdc, pool, LENDER1(), 50 * ONE_USDC);

    let info = pool.get_pool_info();
    assert(info.lender_count == 2, 'Roster unchanged');
    assert(info.total_deposited == 250 * ONE_USDC, 'Top-up accepted');
}

#[test]
fn test_exiting_frees_a_slot_for_someone_else() {
    // The squatting fix, stated as behaviour.
    let (usdc, pool) = setup(2, 0, 10_000 * ONE_USDC);
    fund_and_deposit(usdc, pool, LENDER1(), 100 * ONE_USDC);
    fund_and_deposit(usdc, pool, LENDER2(), 100 * ONE_USDC);

    start_cheat_caller_address(pool.contract_address, LENDER1());
    pool.withdraw();
    stop_cheat_caller_address(pool.contract_address);

    assert(pool.get_pool_info().lender_count == 1, 'Slot released');
    fund_and_deposit(usdc, pool, LENDER3(), 100 * ONE_USDC);
    assert(pool.get_pool_info().lender_count == 2, 'Slot reused');
}

// ------------------------------------------------- swap-and-pop correctness

#[test]
fn test_removing_the_middle_lender_keeps_enumeration_intact() {
    // The dangerous case. Removing slot 1 of 0,1,2 moves the tail into it, and
    // a wrong index write here silently corrupts lookups for an unrelated
    // lender rather than failing loudly.
    let (usdc, pool) = setup(5, 0, 10_000 * ONE_USDC);
    fund_and_deposit(usdc, pool, LENDER1(), 100 * ONE_USDC);
    fund_and_deposit(usdc, pool, LENDER2(), 100 * ONE_USDC);
    fund_and_deposit(usdc, pool, LENDER3(), 100 * ONE_USDC);

    start_cheat_caller_address(pool.contract_address, LENDER2());
    pool.withdraw();
    stop_cheat_caller_address(pool.contract_address);

    assert(pool.get_pool_info().lender_count == 2, 'Two lenders left');
    assert(!pool.is_lender(LENDER2()), 'LENDER2 removed');
    assert(pool.is_lender(LENDER1()), 'LENDER1 intact');
    assert(pool.is_lender(LENDER3()), 'LENDER3 intact');

    // Both survivors must still be reachable by index, in some order, with no
    // duplicates and no holes.
    let a = pool.get_lender(0);
    let b = pool.get_lender(1);
    assert(a != b, 'No duplicate entries');
    let covers_1 = a == LENDER1() || b == LENDER1();
    let covers_3 = a == LENDER3() || b == LENDER3();
    assert(covers_1 && covers_3, 'Both survivors reachable');
}

#[test]
fn test_removing_the_last_lender_takes_the_no_move_path() {
    let (usdc, pool) = setup(5, 0, 10_000 * ONE_USDC);
    fund_and_deposit(usdc, pool, LENDER1(), 100 * ONE_USDC);
    fund_and_deposit(usdc, pool, LENDER2(), 100 * ONE_USDC);

    start_cheat_caller_address(pool.contract_address, LENDER2());
    pool.withdraw();
    stop_cheat_caller_address(pool.contract_address);

    assert(pool.get_pool_info().lender_count == 1, 'One lender left');
    assert(pool.get_lender(0) == LENDER1(), 'LENDER1 still at slot 0');
    assert(!pool.is_lender(LENDER2()), 'LENDER2 removed');
}

#[test]
fn test_removing_the_only_lender_empties_the_roster() {
    let (usdc, pool) = setup(5, 0, 10_000 * ONE_USDC);
    fund_and_deposit(usdc, pool, LENDER1(), 100 * ONE_USDC);

    start_cheat_caller_address(pool.contract_address, LENDER1());
    pool.withdraw();
    stop_cheat_caller_address(pool.contract_address);

    assert(pool.get_pool_info().lender_count == 0, 'Roster empty');
    assert(!pool.is_lender(LENDER1()), 'Not a lender');
}

#[test]
fn test_rejoining_after_a_full_exit_registers_once() {
    // Leaving and coming back must not leave a stale index behind or
    // double-count the lender.
    let (usdc, pool) = setup(5, 0, 10_000 * ONE_USDC);
    fund_and_deposit(usdc, pool, LENDER1(), 100 * ONE_USDC);

    start_cheat_caller_address(pool.contract_address, LENDER1());
    pool.withdraw();
    stop_cheat_caller_address(pool.contract_address);

    fund_and_deposit(usdc, pool, LENDER1(), 100 * ONE_USDC);

    let info = pool.get_pool_info();
    assert(info.lender_count == 1, 'Counted once');
    assert(info.total_deposited == 100 * ONE_USDC, 'Accounting correct');
    assert(pool.get_lender(0) == LENDER1(), 'Reachable at slot 0');
}

#[test]
#[should_panic(expected: ('Max lenders must be positive',))]
fn test_a_pool_that_admits_nobody_is_rejected_at_birth() {
    let usdc = deploy_usdc();
    let pool = deploy_pool();
    pool
        .initialize(
            FACTORY(),
            FOUNDER(),
            usdc.contract_address,
            PLATFORM_WALLET(),
            50,
            10_000 * ONE_USDC,
            1000,
            365,
            30,
            30 * SECONDS_PER_DAY,
            'DATA_ROOM_HASH',
            0,
            0,
            false,
        );
}

#[test]
#[should_panic(expected: ('Min exceeds cap',))]
fn test_minimum_larger_than_the_pool_is_rejected() {
    // Otherwise the only permitted deposit is the one that takes the entire
    // cap, via the remaining-headroom exception. Legal, useless, and a typo
    // away from a pool nobody can enter.
    let usdc = deploy_usdc();
    let pool = deploy_pool();
    pool
        .initialize(
            FACTORY(),
            FOUNDER(),
            usdc.contract_address,
            PLATFORM_WALLET(),
            50,
            1_000 * ONE_USDC,
            1000,
            365,
            30,
            30 * SECONDS_PER_DAY,
            'DATA_ROOM_HASH',
            10,
            2_000 * ONE_USDC,
            false,
        );
}

#[test]
fn test_hundred_usdc_minimum_on_a_ten_thousand_pool() {
    // The configuration actually being shipped: $100 minimum, $10k cap.
    let cap = 10_000 * ONE_USDC;
    let min = 100 * ONE_USDC;
    let (usdc, pool) = setup(49, min, cap);

    assert(pool.get_min_deposit_amount() == min, 'Minimum recorded');
    assert(pool.get_max_lenders_limit() == 49, 'Limit recorded');

    // Exactly the minimum is accepted.
    fund_and_deposit(usdc, pool, LENDER1(), min);
    assert(pool.get_pool_info().total_deposited == min, 'Minimum accepted');

    // A larger first ticket is accepted too: the minimum is a floor, not a size.
    fund_and_deposit(usdc, pool, LENDER2(), 2_500 * ONE_USDC);
    assert(pool.get_pool_info().lender_count == 2, 'Both counted');
}

// ============================================================================
// Oversubscription and the race for the last slice
// ============================================================================

#[test]
#[should_panic(expected: ('Exceeds pool cap',))]
fn test_a_pool_cannot_be_oversubscribed() {
    // Hard ceiling. The pool never accepts more than its cap, so there is no
    // pro-rata refund path to get wrong and no surplus sitting in the contract.
    let cap = 1_000 * ONE_USDC;
    let (usdc, pool) = setup(10, 0, cap);
    fund_and_deposit(usdc, pool, LENDER1(), 900 * ONE_USDC);
    fund_and_deposit(usdc, pool, LENDER2(), 200 * ONE_USDC);
}

#[test]
fn test_the_loser_of_the_last_slice_keeps_their_money() {
    // Two investors want the final 100. Starknet sequences them, so one lands
    // and one reverts. The point of this test is what happens to the loser:
    // the revert is atomic, so their USDC never left their wallet and their
    // allowance is untouched. They can deposit into the next pool immediately.
    let cap = 1_000 * ONE_USDC;
    let (usdc, pool) = setup(10, 0, cap);
    fund_and_deposit(usdc, pool, LENDER1(), 900 * ONE_USDC);

    // The winner takes the remainder.
    fund_and_deposit(usdc, pool, LENDER2(), 100 * ONE_USDC);
    assert(pool.get_pool_info().total_deposited == cap, 'Pool full');

    // The loser was funded and approved but never got in.
    usdc.mint(LENDER3(), 100 * ONE_USDC);
    start_cheat_caller_address(usdc.contract_address, LENDER3());
    usdc.approve(pool.contract_address, 100 * ONE_USDC);
    stop_cheat_caller_address(usdc.contract_address);

    // Their balance is intact: nothing was taken by the attempt.
    assert(usdc.balance_of(LENDER3()) == 100 * ONE_USDC, 'Loser keeps their funds');
    assert(!pool.is_lender(LENDER3()), 'Loser is not a lender');
    assert(pool.get_pool_info().lender_count == 2, 'Roster unchanged');
}

#[test]
fn test_the_last_slice_is_reachable_even_below_the_minimum() {
    // The race is only fair if the remainder is actually depositable. With a
    // 500 minimum and 100 left, a new investor must still be able to take it,
    // or the pool stalls one deposit short of its cap forever.
    let cap = 1_000 * ONE_USDC;
    let (usdc, pool) = setup(10, 500 * ONE_USDC, cap);
    fund_and_deposit(usdc, pool, LENDER1(), 900 * ONE_USDC);

    fund_and_deposit(usdc, pool, LENDER2(), 100 * ONE_USDC);
    assert(pool.get_pool_info().total_deposited == cap, 'Remainder taken');
}

#[test]
#[should_panic(expected: ('Below min deposit',))]
fn test_a_partial_bite_at_the_remainder_is_still_refused() {
    // The exception is exact-remainder only. Depositing 50 of the last 100
    // would leave a 50 tail that is below the minimum and not the remainder
    // either, which is the state that strands a pool.
    let cap = 1_000 * ONE_USDC;
    let (usdc, pool) = setup(10, 500 * ONE_USDC, cap);
    fund_and_deposit(usdc, pool, LENDER1(), 900 * ONE_USDC);
    fund_and_deposit(usdc, pool, LENDER2(), 50 * ONE_USDC);
}

#[test]
fn test_an_existing_investor_can_top_up_the_remainder() {
    // The other way the last slice gets filled: someone already in adds it.
    // No roster slot is consumed, so this works even on a full roster.
    let cap = 1_100 * ONE_USDC;
    let (usdc, pool) = setup(2, 500 * ONE_USDC, cap);
    fund_and_deposit(usdc, pool, LENDER1(), 500 * ONE_USDC);
    fund_and_deposit(usdc, pool, LENDER2(), 500 * ONE_USDC);
    // Roster is full at 2 and the last 100 is below the 500 minimum. Neither
    // stops an existing investor: the minimum gates joining, not adding.
    fund_and_deposit(usdc, pool, LENDER1(), 100 * ONE_USDC);

    let info = pool.get_pool_info();
    assert(info.total_deposited == cap, 'Filled by a top-up');
    assert(info.lender_count == 2, 'Roster still full');
}
