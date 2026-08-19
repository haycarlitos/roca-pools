use starknet::ContractAddress;

/// One reconciled payroll-deduction batch, anchored on chain.
///
/// Deliberately small. The registry proves that a repayment corresponds to a
/// real, central-bank-signed transfer and that the transfer was not counted
/// twice. It is not a place to publish the loan book.
#[derive(Drop, Serde, Copy, starknet::Store)]
pub struct BatchRecord {
    /// poseidon(amount, clave_rastreo, timestamp) over the Banxico CEP.
    pub cep_hash: felt252,
    /// Poseidon root over the salted per-loan deduction leaves.
    pub merkle_root: felt252,
    /// Batch total in centavos. Integer, never a float.
    pub total_mxn_centavos: u128,
    pub anchored_at: u64,
    pub anchored_by: ContractAddress,
}

#[starknet::interface]
pub trait IAuditRegistry<TContractState> {
    /// Anchor a batch. Servicer only, and only once per batch_id or cep_hash.
    ///
    /// Batches are PORTFOLIO level, not pool level: one employer transfer
    /// covers loans that were routed across several pools, so binding a batch
    /// to a single pool would make the sum of its deductions disagree with the
    /// receipt total, and splitting the receipt would destroy the tie to the
    /// clave de rastreo that makes it evidence in the first place.
    fn register_batch(
        ref self: TContractState,
        batch_id: u64,
        cep_hash: felt252,
        merkle_root: felt252,
        total_mxn_centavos: u128,
    );

    /// Verify a loan's deduction was in an anchored batch.
    ///
    /// Takes the leaf's COMPONENTS, not a precomputed leaf, and builds
    /// `poseidon(loan_id, amount_centavos, period, salt)` itself. That is a
    /// security property, not ergonomics: internal nodes are hashed with the
    /// same function, so an interface accepting a ready-made leaf would happily
    /// verify an internal node against a shorter proof and answer true for
    /// something that is not a deduction at all. Building the leaf here makes
    /// that unreachable, because reversing an internal node into four
    /// components is a preimage problem.
    ///
    /// The salt is per-item, 256-bit, and kept off chain: loan ids are
    /// sequential and payroll deductions sit in a narrow band, so unsalted
    /// leaves would be brute-forceable from the published root and would leak
    /// the loan book the anchoring exists to protect.
    ///
    /// Call this as a read. Sending it in a transaction puts the salt in
    /// public calldata and undoes that protection.
    fn verify_loan_inclusion(
        self: @TContractState,
        batch_id: u64,
        loan_id: felt252,
        amount_centavos: felt252,
        period: felt252,
        salt: felt252,
        proof: Span<felt252>,
    ) -> bool;

    /// Whether this CEP has already been anchored. The anti-double-count gate.
    fn is_cep_processed(self: @TContractState, cep_hash: felt252) -> bool;

    fn get_batch(self: @TContractState, batch_id: u64) -> BatchRecord;
    fn get_batch_count(self: @TContractState) -> u64;

    // ---- administration -----------------------------------------------------
    fn set_servicer(ref self: TContractState, servicer: ContractAddress, allowed: bool);
    fn is_servicer(self: @TContractState, account: ContractAddress) -> bool;
}
