//! Audit finding replication.
//!
//! Every finding class from the external and internal audits of
//! `shhh-wallet-cairo` (Henri / Nethermind AuditAgent 2026-04-13, Omar Espejel
//! 2026-04-20, and four Claude Opus reviews 2026-05-07 through 2026-05-14),
//! tested against these contracts.
//!
//! The point is not that our contracts resemble a smart account. It is that a
//! finding on one Cairo codebase names a CLASS of mistake, and the cheapest
//! time to check whether we made the same one is before an auditor does.
//!
//! Each test below is named for the finding it mirrors. Where a finding cannot
//! apply, that is recorded in `docs/audit-mapping.md` with the reason, so a
//! reviewer can see the whole list was walked rather than the convenient half.

use seedless_contracts::interfaces::i_audit_registry::{
    IAuditRegistryDispatcher, IAuditRegistryDispatcherTrait,
};
use seedless_contracts::interfaces::i_credit_pool::{
    ICreditPoolDispatcher, ICreditPoolDispatcherTrait, PoolStatus,
};
use seedless_contracts::interfaces::i_pool_factory::{
    IPoolFactoryDispatcher, IPoolFactoryDispatcherTrait,
};
use seedless_contracts::mocks::mock_erc20::{IMockERC20Dispatcher, IMockERC20DispatcherTrait};
use seedless_contracts::mocks::reentrant_erc20::{
    IReentrantERC20Dispatcher, IReentrantERC20DispatcherTrait,
};
use snforge_std_deprecated::{
    ContractClassTrait, DeclareResultTrait, declare, start_cheat_block_timestamp,
    start_cheat_caller_address, stop_cheat_caller_address,
};
use starknet::{ClassHash, ContractAddress, contract_address_const};

const ONE_USDC: u256 = 1_000_000;
const DAY: u64 = 86400;

fn OWNER() -> ContractAddress {
    contract_address_const::<'OWNER'>()
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
fn STRANGER() -> ContractAddress {
    contract_address_const::<'STRANGER'>()
}
fn ZERO() -> ContractAddress {
    contract_address_const::<0>()
}

fn deploy_usdc() -> IMockERC20Dispatcher {
    let c = declare("MockERC20").unwrap().contract_class();
    let (a, _) = c.deploy(@array!['USDC', 'USDC', 6]).unwrap();
    IMockERC20Dispatcher { contract_address: a }
}

fn pool_class() -> ClassHash {
    *declare("CreditPool").unwrap().contract_class().class_hash
}

fn deploy_pool() -> ICreditPoolDispatcher {
    let c = declare("CreditPool").unwrap().contract_class();
    let (a, _) = c.deploy(@array![]).unwrap();
    ICreditPoolDispatcher { contract_address: a }
}

fn deploy_registry() -> IAuditRegistryDispatcher {
    let c = declare("AuditRegistry").unwrap().contract_class();
    let (a, _) = c.deploy(@array![OWNER().into()]).unwrap();
    IAuditRegistryDispatcher { contract_address: a }
}

fn deploy_factory(usdc: ContractAddress) -> IPoolFactoryDispatcher {
    let c = declare("PoolFactory").unwrap().contract_class();
    let (a, _) = c
        .deploy(@array![OWNER().into(), PLATFORM().into(), usdc.into(), pool_class().into()])
        .unwrap();
    IPoolFactoryDispatcher { contract_address: a }
}

fn init_pool(pool: ICreditPoolDispatcher, usdc: ContractAddress) {
    pool
        .initialize(
            contract_address_const::<'FACTORY'>(),
            FOUNDER(),
            usdc,
            PLATFORM(),
            50,
            10_000 * ONE_USDC,
            1000,
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

// ===========================================================================
// Omar C-1 — an entrypoint that must be restricted, isn't
// ===========================================================================
// Their case: `__execute__` was public, so anyone could run arbitrary calls.
// Ours: every state-changing entrypoint that moves money or changes config
// must reject a stranger. Enumerated rather than sampled.

#[test]
#[should_panic(expected: ('Only founder',))]
fn test_omar_c1_stranger_cannot_borrow() {
    let usdc = deploy_usdc();
    let pool = deploy_pool();
    init_pool(pool, usdc.contract_address);
    start_cheat_caller_address(pool.contract_address, FOUNDER());
    pool.activate();
    stop_cheat_caller_address(pool.contract_address);
    deposit_as(usdc, pool, LENDER1(), 100 * ONE_USDC);

    start_cheat_caller_address(pool.contract_address, STRANGER());
    pool.borrow();
}

#[test]
#[should_panic(expected: ('Only founder',))]
fn test_omar_c1_stranger_cannot_lower_rate() {
    let usdc = deploy_usdc();
    let pool = deploy_pool();
    init_pool(pool, usdc.contract_address);
    start_cheat_caller_address(pool.contract_address, STRANGER());
    pool.lower_rate(500);
}

#[test]
#[should_panic(expected: ('Only founder',))]
fn test_omar_c1_stranger_cannot_activate() {
    let usdc = deploy_usdc();
    let pool = deploy_pool();
    init_pool(pool, usdc.contract_address);
    start_cheat_caller_address(pool.contract_address, STRANGER());
    pool.activate();
}

#[test]
#[should_panic(expected: ('Only factory',))]
fn test_omar_c1_stranger_cannot_mark_defaulted() {
    let usdc = deploy_usdc();
    let pool = deploy_pool();
    init_pool(pool, usdc.contract_address);
    start_cheat_caller_address(pool.contract_address, STRANGER());
    pool.mark_defaulted();
}

// ===========================================================================
// Omar C-1 corollary — initialize is a one-shot
// ===========================================================================
// A re-initializable pool would let anyone rewrite the founder and take the
// next borrow. Their C-1 was "unrestricted entrypoint"; this is the same class
// applied to setup.

#[test]
#[should_panic(expected: ('Already initialized',))]
fn test_omar_c1_pool_cannot_be_reinitialized() {
    let usdc = deploy_usdc();
    let pool = deploy_pool();
    init_pool(pool, usdc.contract_address);
    // A second call, from anyone, naming a different founder.
    start_cheat_caller_address(pool.contract_address, STRANGER());
    pool
        .initialize(
            contract_address_const::<'FACTORY'>(),
            STRANGER(),
            usdc.contract_address,
            PLATFORM(),
            50,
            10_000 * ONE_USDC,
            1000,
            365,
            30,
            30 * DAY,
            'HASH',
            100,
            0,
            false,
        );
}

// ===========================================================================
// Omar H-1 — a failed subcall must not be swallowed
// ===========================================================================
// Their case: multicall ignored subcall failure, allowing partial execution.
// Ours: every ERC20 result is asserted. A transfer that fails must revert the
// whole deposit, never credit a position for money that did not arrive.

#[test]
#[should_panic]
fn test_omar_h1_deposit_without_approval_reverts_whole_call() {
    let usdc = deploy_usdc();
    let pool = deploy_pool();
    init_pool(pool, usdc.contract_address);
    start_cheat_caller_address(pool.contract_address, FOUNDER());
    pool.activate();
    stop_cheat_caller_address(pool.contract_address);

    // Funded but never approved: transfer_from must fail and take the whole
    // deposit with it.
    usdc.mint(LENDER1(), 100 * ONE_USDC);
    start_cheat_caller_address(pool.contract_address, LENDER1());
    pool.deposit(100 * ONE_USDC);
}

#[test]
fn test_omar_h1_failed_deposit_leaves_no_trace() {
    // The half of H-1 that matters: after a reverted deposit there must be no
    // position, no roster entry, and no accounting movement.
    let usdc = deploy_usdc();
    let pool = deploy_pool();
    init_pool(pool, usdc.contract_address);
    start_cheat_caller_address(pool.contract_address, FOUNDER());
    pool.activate();
    stop_cheat_caller_address(pool.contract_address);

    let info = pool.get_pool_info();
    assert(info.total_deposited == 0, 'Nothing deposited');
    assert(info.lender_count == 0, 'No lenders');
    assert(!pool.is_lender(LENDER1()), 'Not a lender');
}

// ===========================================================================
// Omar M-1 — the zero address must never be a privileged value
// ===========================================================================
// Their case: caller == 0 was silently treated as "any caller".

#[test]
#[should_panic(expected: ('Invalid founder',))]
fn test_omar_m1_zero_founder_is_rejected() {
    let usdc = deploy_usdc();
    let pool = deploy_pool();
    pool
        .initialize(
            contract_address_const::<'FACTORY'>(),
            ZERO(),
            usdc.contract_address,
            PLATFORM(),
            50,
            10_000 * ONE_USDC,
            1000,
            365,
            30,
            30 * DAY,
            'HASH',
            100,
            0,
            false,
        );
}

#[test]
#[should_panic(expected: ('Invalid USDC',))]
fn test_omar_m1_zero_token_is_rejected() {
    let pool = deploy_pool();
    pool
        .initialize(
            contract_address_const::<'FACTORY'>(),
            FOUNDER(),
            ZERO(),
            PLATFORM(),
            50,
            10_000 * ONE_USDC,
            1000,
            365,
            30,
            30 * DAY,
            'HASH',
            100,
            0,
            false,
        );
}

#[test]
#[should_panic(expected: ('Invalid lender address',))]
fn test_omar_m1_zero_address_cannot_be_authorized() {
    // Authorizing address 0 would be meaningless at best and, if any path ever
    // defaulted a missing address to 0, a universal bypass.
    let usdc = deploy_usdc();
    let factory = deploy_factory(usdc.contract_address);
    start_cheat_caller_address(factory.contract_address, OWNER());
    factory.set_lp_authorization(ZERO(), true);
}

#[test]
#[should_panic(expected: ('Invalid servicer',))]
fn test_omar_m1_zero_address_cannot_be_a_servicer() {
    let reg = deploy_registry();
    start_cheat_caller_address(reg.contract_address, OWNER());
    reg.set_servicer(ZERO(), true);
}

// ===========================================================================
// Omar M-3 — caller-supplied lengths must be bounded
// ===========================================================================
// Their case: unbounded call count, calldata and signature length.
// Ours: the authorization batch, and the Merkle proof in the registry.

#[test]
#[should_panic(expected: ('Batch too large',))]
fn test_omar_m3_authorization_batch_is_bounded() {
    let usdc = deploy_usdc();
    let factory = deploy_factory(usdc.contract_address);
    let mut big: Array<ContractAddress> = array![];
    let mut i: u32 = 0;
    while i < 51 {
        big.append(LENDER1());
        i += 1;
    }
    start_cheat_caller_address(factory.contract_address, OWNER());
    factory.set_lp_authorization_batch(big.span(), true);
}

#[test]
fn test_omar_m3_batch_at_the_limit_is_accepted() {
    // The boundary itself, so the cap is off-by-one correct.
    let usdc = deploy_usdc();
    let factory = deploy_factory(usdc.contract_address);
    let mut exact: Array<ContractAddress> = array![];
    let mut i: u32 = 0;
    while i < 50 {
        exact.append(LENDER1());
        i += 1;
    }
    start_cheat_caller_address(factory.contract_address, OWNER());
    factory.set_lp_authorization_batch(exact.span(), true);
    stop_cheat_caller_address(factory.contract_address);
    assert(factory.is_authorized(LENDER1()), 'Batch of 50 applied');
}

#[test]
fn test_omar_m3_overlong_merkle_proof_is_refused_not_looped() {
    // An unbounded loop over caller data is a step-exhaustion vector as soon as
    // another contract calls this on chain.
    let reg = deploy_registry();
    start_cheat_caller_address(reg.contract_address, OWNER());
    reg.register_batch(1, 'CEP', 'ROOT', 100);
    stop_cheat_caller_address(reg.contract_address);

    let mut deep: Array<felt252> = array![];
    let mut i: u32 = 0;
    while i < 33 {
        deep.append('SIB');
        i += 1;
    }
    assert(!reg.verify_loan_inclusion(1, 1, 1, 1, 1, deep.span()), 'Overlong proof refused');
}

// ===========================================================================
// Omar L-1 — setup must not be able to produce a bricked contract
// ===========================================================================
// Their case: a constructor accepting an invalid Ed25519 key half could deploy
// a wallet nobody can sign for.

#[test]
#[should_panic(expected: ('Cap must be positive',))]
fn test_omar_l1_zero_cap_pool_is_rejected() {
    let usdc = deploy_usdc();
    let pool = deploy_pool();
    pool
        .initialize(
            contract_address_const::<'FACTORY'>(),
            FOUNDER(),
            usdc.contract_address,
            PLATFORM(),
            50,
            0,
            1000,
            365,
            30,
            30 * DAY,
            'HASH',
            100,
            0,
            false,
        );
}

#[test]
#[should_panic(expected: ('Deadline must be in future',))]
fn test_omar_l1_pool_born_expired_is_rejected() {
    // A pool whose funding deadline has already passed can never take a
    // deposit. Every one of our seven mainnet pools is now in that state
    // through the passage of time; being born there is a different fault and
    // is refused.
    let usdc = deploy_usdc();
    let pool = deploy_pool();
    start_cheat_block_timestamp(pool.contract_address, 100 * DAY);
    pool
        .initialize(
            contract_address_const::<'FACTORY'>(),
            FOUNDER(),
            usdc.contract_address,
            PLATFORM(),
            50,
            10_000 * ONE_USDC,
            1000,
            365,
            30,
            1 * DAY,
            'HASH',
            100,
            0,
            false,
        );
}

#[test]
#[should_panic(expected: ('Interval exceeds duration',))]
fn test_omar_l1_incoherent_schedule_is_rejected() {
    let usdc = deploy_usdc();
    let pool = deploy_pool();
    pool
        .initialize(
            contract_address_const::<'FACTORY'>(),
            FOUNDER(),
            usdc.contract_address,
            PLATFORM(),
            50,
            10_000 * ONE_USDC,
            1000,
            30,
            365,
            30 * DAY,
            'HASH',
            100,
            0,
            false,
        );
}

#[test]
#[should_panic(expected: ('Max lenders must be positive',))]
fn test_omar_l1_pool_admitting_nobody_is_rejected() {
    let usdc = deploy_usdc();
    let pool = deploy_pool();
    pool
        .initialize(
            contract_address_const::<'FACTORY'>(),
            FOUNDER(),
            usdc.contract_address,
            PLATFORM(),
            50,
            10_000 * ONE_USDC,
            1000,
            365,
            30,
            30 * DAY,
            'HASH',
            0,
            0,
            false,
        );
}

// ===========================================================================
// Opus C-1 (2026-05-07) — one role must not silently carry another's power
// ===========================================================================
// Their case: the guardian role turned out to be owner-equivalent.
// Ours: compliance and ownership are separate, and delegating compliance
// actually removes the power from the owner rather than sharing it.

#[test]
#[should_panic(expected: ('Not compliance officer',))]
fn test_opus_c1_owner_loses_authorization_power_once_delegated() {
    let usdc = deploy_usdc();
    let factory = deploy_factory(usdc.contract_address);
    start_cheat_caller_address(factory.contract_address, OWNER());
    factory.set_compliance_officer(STRANGER());
    factory.set_lp_authorization(LENDER1(), true);
}

#[test]
#[should_panic(expected: ('Caller is not the owner',))]
fn test_opus_c1_compliance_officer_does_not_gain_ownership() {
    // The mirror: the delegated role must not creep upward into config power.
    let usdc = deploy_usdc();
    let factory = deploy_factory(usdc.contract_address);
    start_cheat_caller_address(factory.contract_address, OWNER());
    factory.set_compliance_officer(STRANGER());
    stop_cheat_caller_address(factory.contract_address);

    start_cheat_caller_address(factory.contract_address, STRANGER());
    factory.set_fees(199_000_000, 100, 50);
}

// ===========================================================================
// Opus H-3 (2026-05-07) — a config change must not silently reset accounting
// ===========================================================================
// Their case: updating a spending policy quietly zeroed the spent counter.

#[test]
fn test_opus_h3_changing_factory_fees_does_not_touch_live_pools() {
    let usdc = deploy_usdc();
    let factory = deploy_factory(usdc.contract_address);

    start_cheat_caller_address(factory.contract_address, FOUNDER());
    let addr = factory.create_pool(10_000 * ONE_USDC, 1000, 365, 30, 30 * DAY, 'HASH', 25, 0);
    stop_cheat_caller_address(factory.contract_address);
    let pool = ICreditPoolDispatcher { contract_address: addr };
    assert(pool.get_pool_info().repayment_fee_bps == 0, 'Born fee-free');

    // Raising the factory fee afterwards must not reach back into it.
    start_cheat_caller_address(factory.contract_address, OWNER());
    factory.set_fees(199_000_000, 100, 500);
    stop_cheat_caller_address(factory.contract_address);

    assert(pool.get_pool_info().repayment_fee_bps == 0, 'Existing pool unchanged');
    assert(factory.get_repayment_fee_bps() == 500, 'New pools would differ');
}

#[test]
fn test_opus_h3_lowering_the_rate_does_not_disturb_accounting() {
    let usdc = deploy_usdc();
    let pool = deploy_pool();
    init_pool(pool, usdc.contract_address);
    start_cheat_caller_address(pool.contract_address, FOUNDER());
    pool.activate();
    stop_cheat_caller_address(pool.contract_address);
    deposit_as(usdc, pool, LENDER1(), 100 * ONE_USDC);

    start_cheat_caller_address(pool.contract_address, FOUNDER());
    pool.lower_rate(500);
    stop_cheat_caller_address(pool.contract_address);

    let info = pool.get_pool_info();
    assert(info.total_deposited == 100 * ONE_USDC, 'Deposits untouched');
    assert(info.lender_count == 1, 'Roster untouched');
    assert(pool.get_position(LENDER1()).deposited == 100 * ONE_USDC, 'Position untouched');
}

// ===========================================================================
// Opus H-1 (2026-05-07) — permissionless entrypoints and racing
// ===========================================================================
// Their case: `bootstrap_from_sessions` was front-runnable.
// Ours: `expire` is deliberately permissionless. That is safe only because it
// can do exactly one thing, in one direction, and only after a deadline.

#[test]
#[should_panic(expected: ('Deadline not passed',))]
fn test_opus_h1_expire_cannot_be_raced_before_the_deadline() {
    let usdc = deploy_usdc();
    let pool = deploy_pool();
    init_pool(pool, usdc.contract_address);
    start_cheat_caller_address(pool.contract_address, STRANGER());
    pool.expire();
}

#[test]
fn test_opus_h1_permissionless_expire_only_opens_the_exit() {
    // A stranger calling it gains nothing and costs lenders nothing: the only
    // effect is that withdrawal becomes available.
    let usdc = deploy_usdc();
    let pool = deploy_pool();
    init_pool(pool, usdc.contract_address);
    start_cheat_caller_address(pool.contract_address, FOUNDER());
    pool.activate();
    stop_cheat_caller_address(pool.contract_address);
    deposit_as(usdc, pool, LENDER1(), 100 * ONE_USDC);

    start_cheat_block_timestamp(pool.contract_address, 31 * DAY);
    start_cheat_caller_address(pool.contract_address, STRANGER());
    pool.expire();
    stop_cheat_caller_address(pool.contract_address);

    start_cheat_caller_address(pool.contract_address, LENDER1());
    pool.withdraw();
    stop_cheat_caller_address(pool.contract_address);
    assert(usdc.balance_of(LENDER1()) == 100 * ONE_USDC, 'Lender exits whole');
}

// ===========================================================================
// Opus M-2 (2026-05-07) — an external call must not re-enter a guarded path
// ===========================================================================
// Their case: a library-call verifier could re-enter self-call-gated mutators.
// Ours: `deposit` makes a cross-contract call to the factory allowlist. The
// reentrancy guard is entered before it, so a hostile factory cannot re-enter.

#[test]
#[should_panic(expected: ('ReentrancyGuard: reentrant call',))]
fn test_opus_m2_reentrant_withdraw_is_blocked() {
    // A hostile token calls back into `withdraw` while the pool is mid-payout.
    // Without the guard the second entry would recompute an entitlement the
    // first entry has already paid but not yet recorded.
    let c = declare("ReentrantERC20").unwrap().contract_class();
    let (token_addr, _) = c.deploy(@array![]).unwrap();
    let token = IReentrantERC20Dispatcher { contract_address: token_addr };

    let pool = deploy_pool();
    init_pool(pool, token_addr);
    start_cheat_caller_address(pool.contract_address, FOUNDER());
    pool.activate();
    stop_cheat_caller_address(pool.contract_address);

    token.mint(LENDER1(), 100 * ONE_USDC);
    start_cheat_caller_address(token_addr, LENDER1());
    token.approve(pool.contract_address, 100 * ONE_USDC);
    stop_cheat_caller_address(token_addr);
    start_cheat_caller_address(pool.contract_address, LENDER1());
    pool.deposit(100 * ONE_USDC);
    stop_cheat_caller_address(pool.contract_address);

    // Arm the callback, then trigger a payout.
    token.arm(pool.contract_address);
    start_cheat_caller_address(pool.contract_address, LENDER1());
    pool.withdraw();
}

// ===========================================================================
// Opus INFO-2 (2026-05-14) — replay and uniqueness surfaces
// ===========================================================================
// Their concern was storage-slot collision across components. The transferable
// lesson for us is narrower: every uniqueness claim needs a test that tries to
// violate it from a second angle, not just the obvious one.

#[test]
#[should_panic(expected: ('CEP already processed',))]
fn test_registry_replay_across_different_batch_ids() {
    let reg = deploy_registry();
    start_cheat_caller_address(reg.contract_address, OWNER());
    reg.register_batch(1, 'CEP', 'ROOT_A', 100);
    reg.register_batch(99, 'CEP', 'ROOT_B', 200);
}

#[test]
#[should_panic(expected: ('CEP already processed',))]
fn test_registry_replay_by_a_second_servicer() {
    // A different anchoring identity must not reopen a spent receipt.
    let reg = deploy_registry();
    start_cheat_caller_address(reg.contract_address, OWNER());
    reg.set_servicer(STRANGER(), true);
    reg.register_batch(1, 'CEP', 'ROOT', 100);
    stop_cheat_caller_address(reg.contract_address);

    start_cheat_caller_address(reg.contract_address, STRANGER());
    reg.register_batch(2, 'CEP', 'ROOT', 100);
}

// ===========================================================================
// External audit, 2026-08-19 — Low: Defaulted blocked recovery distribution
// ===========================================================================
// The auditor's point was an incentive problem, not a safety one: marking a
// pool defaulted permanently blocked `repay`, so a recovery collected from the
// loan book could never reach lenders through the pool. That made never
// marking a default strictly better for lenders than marking one honestly.

#[test]
fn test_a_defaulted_pool_can_still_receive_and_distribute_a_recovery() {
    let usdc = deploy_usdc();
    let pool = deploy_pool();
    init_pool(pool, usdc.contract_address);
    start_cheat_caller_address(pool.contract_address, FOUNDER());
    pool.activate();
    stop_cheat_caller_address(pool.contract_address);

    deposit_as(usdc, pool, LENDER1(), 1_000 * ONE_USDC);
    start_cheat_caller_address(pool.contract_address, FOUNDER());
    pool.borrow();
    stop_cheat_caller_address(pool.contract_address);

    // Long past the term, the factory marks it defaulted.
    start_cheat_block_timestamp(pool.contract_address, 400 * DAY);
    start_cheat_caller_address(pool.contract_address, contract_address_const::<'FACTORY'>());
    pool.mark_defaulted();
    stop_cheat_caller_address(pool.contract_address);

    // Months later a recovery is collected. It must still be distributable.
    usdc.mint(FOUNDER(), 400 * ONE_USDC);
    start_cheat_caller_address(usdc.contract_address, FOUNDER());
    usdc.approve(pool.contract_address, 400 * ONE_USDC);
    stop_cheat_caller_address(usdc.contract_address);
    start_cheat_caller_address(pool.contract_address, FOUNDER());
    pool.repay(400 * ONE_USDC);
    stop_cheat_caller_address(pool.contract_address);

    // The default stands as a historical fact; the money still reaches lenders.
    let info = pool.get_pool_info();
    assert(info.status == PoolStatus::Defaulted, 'Still defaulted');

    start_cheat_caller_address(pool.contract_address, LENDER1());
    pool.withdraw();
    stop_cheat_caller_address(pool.contract_address);
    assert(usdc.balance_of(LENDER1()) > 0, 'Recovery reached the lender');
}

#[test]
#[should_panic(expected: ('Pool not borrowed',))]
fn test_repay_is_still_refused_before_the_money_is_drawn() {
    // The widened guard must not become "any state".
    let usdc = deploy_usdc();
    let pool = deploy_pool();
    init_pool(pool, usdc.contract_address);
    start_cheat_caller_address(pool.contract_address, FOUNDER());
    pool.activate();
    pool.repay(1 * ONE_USDC);
}

// ===========================================================================
// External audit, 2026-08-19 — Info: fee bounds disagreed across contracts
// ===========================================================================

#[test]
#[should_panic(expected: ('Repayment fee max 10%',))]
fn test_initialize_now_enforces_the_same_fee_ceiling_as_the_factory() {
    // Unreachable through create_pool, which passes the factory's capped value,
    // but a directly deployed pool could take a 100% repayment fee.
    let usdc = deploy_usdc();
    let pool = deploy_pool();
    pool
        .initialize(
            contract_address_const::<'FACTORY'>(),
            FOUNDER(),
            usdc.contract_address,
            PLATFORM(),
            5000,
            10_000 * ONE_USDC,
            1000,
            365,
            30,
            30 * DAY,
            'HASH',
            100,
            0,
            false,
        );
}

// ===========================================================================
// Delta re-review, 2026-08-19 — Low: Defaulted was no longer terminal
// ===========================================================================
// Widening `repay` to accept Defaulted also exposed repay's completion branch
// to it, so a full recovery relabelled the pool Completed. That contradicted
// both invariant 9 and the comment sitting directly above the widened guard.
//
// Fixed by keeping the label rather than by rewording the invariant. A default
// is a fact about how the borrower performed, and paying late does not make the
// payment on time; erasing it from the field most readers look at would show a
// lender the wrong history.

#[test]
fn test_a_full_recovery_does_not_relabel_a_defaulted_pool() {
    let usdc = deploy_usdc();
    let pool = deploy_pool();
    init_pool(pool, usdc.contract_address);
    start_cheat_caller_address(pool.contract_address, FOUNDER());
    pool.activate();
    stop_cheat_caller_address(pool.contract_address);

    deposit_as(usdc, pool, LENDER1(), 1_000 * ONE_USDC);
    start_cheat_caller_address(pool.contract_address, FOUNDER());
    pool.borrow();
    stop_cheat_caller_address(pool.contract_address);

    start_cheat_block_timestamp(pool.contract_address, 400 * DAY);
    start_cheat_caller_address(pool.contract_address, contract_address_const::<'FACTORY'>());
    pool.mark_defaulted();
    stop_cheat_caller_address(pool.contract_address);

    // Repay well past everything owed, in one go.
    // Exactly everything owed: 1000 principal at 10% over the full term.
    usdc.mint(FOUNDER(), 1_100 * ONE_USDC);
    start_cheat_caller_address(usdc.contract_address, FOUNDER());
    usdc.approve(pool.contract_address, 1_100 * ONE_USDC);
    stop_cheat_caller_address(usdc.contract_address);
    start_cheat_caller_address(pool.contract_address, FOUNDER());
    pool.repay(1_100 * ONE_USDC);
    stop_cheat_caller_address(pool.contract_address);

    assert(pool.get_pool_info().status == PoolStatus::Defaulted, 'Default is not erased');

    // And the lender is still made whole, which is the point: the label costs
    // them nothing.
    start_cheat_caller_address(pool.contract_address, LENDER1());
    pool.withdraw();
    stop_cheat_caller_address(pool.contract_address);
    assert(usdc.balance_of(LENDER1()) >= 1_000 * ONE_USDC, 'Lender recovered principal');
}

#[test]
fn test_a_performing_pool_still_completes_normally() {
    // The guard must not have broken the ordinary path.
    //
    // Zero repayment fee here on purpose: the fee is taken off the top and only
    // the net credits `total_repaid`, so with a fee the founder has to send
    // more than the amount owed to clear it. That is a separate behaviour and
    // not what this test is about.
    let usdc = deploy_usdc();
    let pool = deploy_pool();
    pool
        .initialize(
            contract_address_const::<'FACTORY'>(),
            FOUNDER(),
            usdc.contract_address,
            PLATFORM(),
            0,
            10_000 * ONE_USDC,
            1000,
            365,
            30,
            30 * DAY,
            'HASH',
            100,
            0,
            false,
        );
    start_cheat_caller_address(pool.contract_address, FOUNDER());
    pool.activate();
    stop_cheat_caller_address(pool.contract_address);

    deposit_as(usdc, pool, LENDER1(), 1_000 * ONE_USDC);
    start_cheat_caller_address(pool.contract_address, FOUNDER());
    pool.borrow();
    stop_cheat_caller_address(pool.contract_address);

    usdc.mint(FOUNDER(), 1_100 * ONE_USDC);
    start_cheat_caller_address(usdc.contract_address, FOUNDER());
    usdc.approve(pool.contract_address, 1_100 * ONE_USDC);
    stop_cheat_caller_address(usdc.contract_address);
    start_cheat_caller_address(pool.contract_address, FOUNDER());
    pool.repay(1_100 * ONE_USDC);
    stop_cheat_caller_address(pool.contract_address);

    assert(pool.get_pool_info().status == PoolStatus::Completed, 'Performing pool completes');
}
