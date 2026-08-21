use starknet::{ClassHash, ContractAddress};

/// Pool creation parameters
#[derive(Drop, Serde, Copy)]
pub struct PoolParams {
    pub cap_amount: u256,
    pub rate_bps: u16,
    pub duration_days: u32,
    pub interval_days: u32,
    pub data_room_hash: felt252,
}

/// Factory configuration
#[derive(Drop, Serde, Copy)]
pub struct FactoryConfig {
    pub owner: ContractAddress,
    pub platform_wallet: ContractAddress,
    pub usdc_address: ContractAddress,
    pub credit_pool_class_hash: ClassHash,
    pub creation_fee_cap: u256,
    pub creation_fee_bps: u16,
    pub repayment_fee_bps: u16,
    pub pool_count: u64,
    pub paused: bool,
}

#[starknet::interface]
pub trait IPoolFactory<TContractState> {
    /// Deploy a new credit pool contract
    /// Returns the deployed pool address
    fn create_pool(
        ref self: TContractState,
        cap_amount: u256,
        rate_bps: u16,
        duration_days: u32,
        interval_days: u32,
        funding_deadline: u64,
        data_room_hash: felt252,
        max_lenders_limit: u32,
        min_deposit_amount: u256,
    ) -> ContractAddress;

    /// Update the pool class hash for new deployments
    fn set_pool_class_hash(ref self: TContractState, class_hash: ClassHash);

    /// Update the platform wallet that receives fees
    fn set_platform_wallet(ref self: TContractState, wallet: ContractAddress);

    /// Update fee parameters
    fn set_fees(
        ref self: TContractState,
        creation_fee_cap: u256,
        creation_fee_bps: u16,
        repayment_fee_bps: u16,
    );

    /// Pause the factory (prevents new pool creation)
    fn pause(ref self: TContractState);

    /// Unpause the factory
    fn unpause(ref self: TContractState);

    // View functions

    /// Calculate creation fee for a given cap amount
    fn get_creation_fee(self: @TContractState, cap_amount: u256) -> u256;

    /// Check if an address is a valid pool deployed by this factory
    fn is_valid_pool(self: @TContractState, pool: ContractAddress) -> bool;

    /// Get pool address by index
    fn get_pool(self: @TContractState, index: u64) -> ContractAddress;

    /// Get factory configuration
    fn get_config(self: @TContractState) -> FactoryConfig;

    /// Get the current repayment fee in basis points
    fn get_repayment_fee_bps(self: @TContractState) -> u16;

    // ---- Lender allowlist ---------------------------------------------------
    //
    // The registry lives on the FACTORY, not on each pool, and every pool reads
    // through to it. That is the whole point: when an investor has to be
    // removed, it is one transaction rather than one per pool per investor, and
    // the delay between "we must revoke" and "revoked everywhere" is what
    // matters in a sanctions case.
    //
    // The cost of that choice is a cross-contract call on every deposit, and a
    // factory that becomes a liveness dependency for deposits across all pools.
    // It fails closed, which is the right direction.

    /// Authorize or revoke a single lender. Compliance officer only.
    fn set_lp_authorization(ref self: TContractState, lp: ContractAddress, authorized: bool);

    /// Same, in bulk. Bounded so the call cannot exceed a block's step limit.
    fn set_lp_authorization_batch(
        ref self: TContractState, lps: Span<ContractAddress>, authorized: bool,
    );

    /// Whether this address may deposit into pools from this factory.
    fn is_authorized(self: @TContractState, lp: ContractAddress) -> bool;

    /// Set the address allowed to change authorizations. Owner only.
    ///
    /// Deliberately separate from ownership: the owner can redirect fees, swap
    /// the pool class and pause the factory. The key that must be reachable
    /// within minutes of a sanctions hit should not also carry all of that.
    fn set_compliance_officer(ref self: TContractState, officer: ContractAddress);
    fn get_compliance_officer(self: @TContractState) -> ContractAddress;

    /// Forwarders for the pool entrypoints that are gated on `caller == factory`.
    ///
    /// `CreditPool::unpause` and `CreditPool::mark_defaulted` both assert the
    /// caller is the factory *contract*. Without a function here that makes the
    /// factory the caller, neither is reachable by anyone: the owner is the
    /// factory's owner, not the factory, so calling the pool directly reverts.
    ///
    /// For `unpause` that is not a missing feature but a stuck pool. A founder
    /// may pause unilaterally (`caller == founder || caller == factory`) while
    /// only the factory may lift it, so without the forwarder any paused pool
    /// stays paused forever, with deposit, borrow and repay frozen. Withdrawal
    /// stays open by design, so lenders can still exit — but the pool is dead.
    ///
    /// Owner-gated rather than compliance-gated: both are statements about a
    /// borrower and the health of a placement, not about who may invest.

    /// Lift a pause on a pool this factory deployed. Owner only.
    fn unpause_pool(ref self: TContractState, pool: ContractAddress);

    /// Pause a pool this factory deployed. Owner only.
    ///
    /// The pool already accepts the factory as a pauser; this is the missing
    /// half that lets Roca stop a pool it did not found.
    fn pause_pool(ref self: TContractState, pool: ContractAddress);

    /// Declare a borrowed pool in default. Owner only.
    ///
    /// The pool enforces when this is permissible (term elapsed, or two
    /// intervals without a payment). It does not stop repayment and it does not
    /// stop withdrawal.
    fn mark_pool_defaulted(ref self: TContractState, pool: ContractAddress);
}
