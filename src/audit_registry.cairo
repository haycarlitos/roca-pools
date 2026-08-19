/// AuditRegistry
///
/// Anchors reconciled payroll-deduction batches so a repayment can be tied to
/// a Banco de Mexico CEP (the signed receipt for a SPEI transfer) and cannot be
/// counted twice.
///
/// It holds no funds and moves no money. The worst outcome of a bug here is a
/// wrong attestation, not a loss, which is why it is a separate contract rather
/// than more surface on CreditPool.
///
/// What is deliberately NOT here: amounts per borrower, employer identity,
/// payroll periods per person, or anything else that would put the loan book on
/// a public ledger. Only a commitment and a total.
#[starknet::contract]
pub mod AuditRegistry {
    use core::num::traits::Zero;
    use core::poseidon::poseidon_hash_span;
    use openzeppelin_access::ownable::OwnableComponent;
    use seedless_contracts::interfaces::i_audit_registry::{BatchRecord, IAuditRegistry};
    use starknet::storage::{
        Map, StoragePathEntry, StoragePointerReadAccess, StoragePointerWriteAccess,
    };
    use starknet::{ContractAddress, get_block_timestamp, get_caller_address};

    /// Ceiling on Merkle proof length. Depth 32 covers 4.29 billion leaves,
    /// which is far beyond any payroll batch this will ever anchor.
    ///
    /// Bounded because an unbounded loop over caller-supplied data is a step
    /// exhaustion vector the moment another contract calls this on chain. Off
    /// chain the caller only burns their own compute, which is why this is
    /// cheap insurance rather than a live bug.
    const MAX_PROOF_DEPTH: u32 = 32;

    component!(path: OwnableComponent, storage: ownable, event: OwnableEvent);

    #[abi(embed_v0)]
    impl OwnableMixinImpl = OwnableComponent::OwnableMixinImpl<ContractState>;
    impl OwnableInternalImpl = OwnableComponent::InternalImpl<ContractState>;

    #[storage]
    struct Storage {
        #[substorage(v0)]
        ownable: OwnableComponent::Storage,
        batches: Map<u64, BatchRecord>,
        /// Set once a batch_id is used. A separate flag because a zeroed
        /// BatchRecord is indistinguishable from an anchored batch whose
        /// hashes happen to be zero.
        batch_exists: Map<u64, bool>,
        /// The anti-replay index: a CEP may be anchored at most once, ever.
        cep_processed: Map<felt252, bool>,
        batch_count: u64,
        servicers: Map<ContractAddress, bool>,
    }

    #[event]
    #[derive(Drop, starknet::Event)]
    pub enum Event {
        #[flat]
        OwnableEvent: OwnableComponent::Event,
        BatchRegistered: BatchRegistered,
        ServicerUpdated: ServicerUpdated,
    }

    #[derive(Drop, starknet::Event)]
    pub struct BatchRegistered {
        #[key]
        pub batch_id: u64,
        #[key]
        pub cep_hash: felt252,
        pub merkle_root: felt252,
        pub total_mxn_centavos: u128,
        pub anchored_by: ContractAddress,
        pub timestamp: u64,
    }

    #[derive(Drop, starknet::Event)]
    pub struct ServicerUpdated {
        #[key]
        pub servicer: ContractAddress,
        pub allowed: bool,
    }

    #[constructor]
    fn constructor(ref self: ContractState, owner: ContractAddress) {
        assert(!owner.is_zero(), 'Invalid owner');
        self.ownable.initializer(owner);
        // The owner services by default, so the registry is never deployed
        // into a state where nothing can be anchored.
        self.servicers.entry(owner).write(true);
    }

    #[abi(embed_v0)]
    impl AuditRegistryImpl of IAuditRegistry<ContractState> {
        fn register_batch(
            ref self: ContractState,
            batch_id: u64,
            cep_hash: felt252,
            merkle_root: felt252,
            total_mxn_centavos: u128,
        ) {
            let caller = get_caller_address();
            assert(self.servicers.entry(caller).read(), 'Not a servicer');

            // Anchoring nothing would be an attestation that says nothing while
            // looking like one that says something.
            assert(cep_hash != 0, 'Invalid cep_hash');
            assert(merkle_root != 0, 'Invalid merkle_root');
            assert(total_mxn_centavos > 0, 'Invalid total');

            // Two independent uniqueness rules. batch_id stops an accidental
            // overwrite; cep_hash stops the same bank receipt being used to
            // justify a second repayment, which is the one that matters.
            assert(!self.batch_exists.entry(batch_id).read(), 'Batch already registered');
            assert(!self.cep_processed.entry(cep_hash).read(), 'CEP already processed');

            let timestamp = get_block_timestamp();
            self
                .batches
                .entry(batch_id)
                .write(
                    BatchRecord {
                        cep_hash,
                        merkle_root,
                        total_mxn_centavos,
                        anchored_at: timestamp,
                        anchored_by: caller,
                    },
                );
            self.batch_exists.entry(batch_id).write(true);
            self.cep_processed.entry(cep_hash).write(true);
            self.batch_count.write(self.batch_count.read() + 1);

            self
                .emit(
                    BatchRegistered {
                        batch_id,
                        cep_hash,
                        merkle_root,
                        total_mxn_centavos,
                        anchored_by: caller,
                        timestamp,
                    },
                );
        }

        fn verify_loan_inclusion(
            self: @ContractState,
            batch_id: u64,
            loan_id: felt252,
            amount_centavos: felt252,
            period: felt252,
            salt: felt252,
            proof: Span<felt252>,
        ) -> bool {
            if !self.batch_exists.entry(batch_id).read() {
                return false;
            }
            let root = self.batches.entry(batch_id).read().merkle_root;

            // Built here, never accepted from the caller. See the interface
            // docs: taking a ready-made leaf would let an internal node be
            // presented as one and verify against a truncated proof.
            let leaf = poseidon_hash_span(array![loan_id, amount_centavos, period, salt].span());

            // Sorted-pair Poseidon. Sorting removes the need to carry left and
            // right flags alongside the proof, and keeps the root independent
            // of sibling order at each level.
            let n = proof.len();
            if n > MAX_PROOF_DEPTH {
                return false;
            }

            let mut computed = leaf;
            let mut i: u32 = 0;
            while i < n {
                let sibling = *proof.at(i);
                let pair = if Into::<
                    felt252, u256,
                    >::into(computed) < Into::<
                    felt252, u256,
                >::into(sibling) {
                    array![computed, sibling]
                } else {
                    array![sibling, computed]
                };
                computed = poseidon_hash_span(pair.span());
                i += 1;
            }
            computed == root
        }

        fn is_cep_processed(self: @ContractState, cep_hash: felt252) -> bool {
            self.cep_processed.entry(cep_hash).read()
        }

        fn get_batch(self: @ContractState, batch_id: u64) -> BatchRecord {
            assert(self.batch_exists.entry(batch_id).read(), 'Unknown batch');
            self.batches.entry(batch_id).read()
        }

        fn get_batch_count(self: @ContractState) -> u64 {
            self.batch_count.read()
        }

        fn set_servicer(ref self: ContractState, servicer: ContractAddress, allowed: bool) {
            self.ownable.assert_only_owner();
            assert(!servicer.is_zero(), 'Invalid servicer');
            self.servicers.entry(servicer).write(allowed);
            self.emit(ServicerUpdated { servicer, allowed });
        }

        fn is_servicer(self: @ContractState, account: ContractAddress) -> bool {
            self.servicers.entry(account).read()
        }
    }
}
