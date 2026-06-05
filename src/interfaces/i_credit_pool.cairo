use starknet::ContractAddress;

/// Pool status enum
#[derive(Drop, Serde, Copy, PartialEq, starknet::Store, Default)]
pub enum PoolStatus {
    #[default]
    Pending,    // Initial state, accepting deposits, not yet activated
    Active,     // Activated by founder, accepting deposits
    Borrowed,   // Founder has borrowed funds
    Completed,  // Fully repaid
    Defaulted,  // Marked as defaulted
    Expired,    // Funding deadline passed without borrowing
    Cancelled,  // Founder cancelled the pool
}

/// Lender position in the pool
#[derive(Drop, Serde, Copy, starknet::Store)]
pub struct LenderPosition {
    pub deposited: u256,      // Total deposited by lender
    pub withdrawn: u256,      // Total withdrawn by lender
}

/// Full pool information
#[derive(Drop, Serde, Copy)]
pub struct PoolInfo {
    // Immutable config
    pub factory: ContractAddress,
    pub founder: ContractAddress,
    pub usdc: ContractAddress,
    pub platform_wallet: ContractAddress,
    pub repayment_fee_bps: u16,
    pub cap_amount: u256,
    pub initial_rate_bps: u16,
    pub duration_days: u32,
    pub interval_days: u32,
    pub data_room_hash: felt252,
    pub created_at: u64,
    pub funding_deadline: u64,
    // Mutable state
    pub status: PoolStatus,
    pub current_rate_bps: u16,
    pub borrow_rate_bps: u16,      // Rate locked at borrow time
    pub total_deposited: u256,
    pub total_borrowed: u256,
    pub total_repaid: u256,
    pub principal_repaid: u256,    // Principal portion repaid
    pub borrowed_at: u64,
    pub last_repayment_at: u64,    // Last repayment timestamp (for overdue detection)
    pub lender_count: u32,
    pub paused: bool,              // Emergency pause status
}

/// Withdrawal calculation result
#[derive(Drop, Serde, Copy)]
pub struct WithdrawalInfo {
    pub available: u256,
    pub principal_part: u256,
    pub interest_part: u256,
}

#[starknet::interface]
pub trait ICreditPool<TContractState> {
    /// Initialize pool (called by factory during deployment)
    fn initialize(
        ref self: TContractState,
        factory: ContractAddress,
        founder: ContractAddress,
        usdc: ContractAddress,
        platform_wallet: ContractAddress,
        repayment_fee_bps: u16,
        cap_amount: u256,
        rate_bps: u16,
        duration_days: u32,
        interval_days: u32,
        funding_deadline: u64,
        data_room_hash: felt252,
    );

    /// Deposit USDC into the pool (lenders)
    fn deposit(ref self: TContractState, amount: u256);

    /// Withdraw available balance (lenders)
    fn withdraw(ref self: TContractState);

    /// Borrow all deposited funds (founder only)
    fn borrow(ref self: TContractState);

    /// Repay loan amount (founder only)
    /// @notice Platform fee (repayment_fee_bps) is calculated on the total amount
    /// including both principal and interest components. The fee is deducted before
    /// the remaining amount is credited to the pool for lender withdrawals.
    fn repay(ref self: TContractState, amount: u256);

    /// Lower interest rate (founder only, can only decrease)
    fn lower_rate(ref self: TContractState, new_rate_bps: u16);

    /// Activate pool for lending (founder only, Pending -> Active)
    fn activate(ref self: TContractState);

    /// Mark pool as defaulted (factory/admin only)
    fn mark_defaulted(ref self: TContractState);

    /// Cancel pool (founder only, during funding phase)
    fn cancel(ref self: TContractState);

    /// Expire pool (anyone can call after funding deadline passes)
    fn expire(ref self: TContractState);

    /// Pause pool (founder or factory can pause)
    /// When paused: deposit, borrow, repay are blocked
    /// Withdrawals remain enabled to protect lenders
    fn pause(ref self: TContractState);

    /// Unpause pool (factory only - prevents malicious founder lock)
    fn unpause(ref self: TContractState);

    // View functions

    /// Get full pool information
    fn get_pool_info(self: @TContractState) -> PoolInfo;

    /// Get lender's position
    fn get_position(self: @TContractState, lender: ContractAddress) -> LenderPosition;

    /// Calculate available withdrawal for a lender
    fn get_available_withdrawal(self: @TContractState, lender: ContractAddress) -> WithdrawalInfo;

    /// Get lender address by index
    fn get_lender(self: @TContractState, index: u32) -> ContractAddress;

    /// Check if address is a lender
    fn is_lender(self: @TContractState, address: ContractAddress) -> bool;
}
