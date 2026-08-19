#[starknet::contract]
pub mod PoolFactory {
    use core::num::traits::Zero;
    use core::pedersen::pedersen;
    use openzeppelin_access::ownable::OwnableComponent;
    use openzeppelin_security::pausable::PausableComponent;
    use openzeppelin_token::erc20::interface::{IERC20Dispatcher, IERC20DispatcherTrait};
    use seedless_contracts::interfaces::i_credit_pool::{
        ICreditPoolDispatcher, ICreditPoolDispatcherTrait,
    };
    use seedless_contracts::interfaces::i_pool_factory::{FactoryConfig, IPoolFactory};
    use starknet::storage::{
        Map, StorageMapReadAccess, StorageMapWriteAccess, StoragePointerReadAccess,
        StoragePointerWriteAccess,
    };
    use starknet::syscalls::deploy_syscall;
    use starknet::{
        ClassHash, ContractAddress, SyscallResultTrait, get_block_timestamp, get_caller_address,
        get_contract_address,
    };

    // Components
    component!(path: OwnableComponent, storage: ownable, event: OwnableEvent);
    component!(path: PausableComponent, storage: pausable, event: PausableEvent);

    #[abi(embed_v0)]
    impl OwnableImpl = OwnableComponent::OwnableMixinImpl<ContractState>;
    impl OwnableInternalImpl = OwnableComponent::InternalImpl<ContractState>;

    #[abi(embed_v0)]
    impl PausableImpl = PausableComponent::PausableImpl<ContractState>;
    impl PausableInternalImpl = PausableComponent::InternalImpl<ContractState>;

    // Constants
    // Fees default to zero. The first placement charges neither a creation
    // nor a repayment fee, and a fee that has to be switched off after deploy
    // is a fee that gets charged by accident in between. `set_fees` can still
    // raise them later; the cap bounds the creation fee once it is non-zero.
    //
    // Note for anyone changing these: `repayment_fee_bps` is read at
    // `create_pool` and written into the pool, so it is fixed for the life of
    // every pool created afterwards. Changing it here does not affect pools
    // that already exist.
    const CREATION_FEE_CAP_DEFAULT: u256 = 199_000_000; // $199 ceiling if ever enabled
    const CREATION_FEE_BPS_DEFAULT: u16 = 0;
    const REPAYMENT_FEE_BPS_DEFAULT: u16 = 0;
    const BPS_DENOMINATOR: u256 = 10_000;
    // Bounded so one call cannot exceed a block's step limit and revert the
    // whole batch. Fifty storage writes plus events sits well inside it.
    const MAX_AUTHORIZATION_BATCH: u32 = 50;

    #[storage]
    struct Storage {
        #[substorage(v0)]
        ownable: OwnableComponent::Storage,
        #[substorage(v0)]
        pausable: PausableComponent::Storage,
        // Configuration
        platform_wallet: ContractAddress,
        credit_pool_class_hash: ClassHash,
        usdc_address: ContractAddress,
        // Fee parameters
        creation_fee_cap: u256,
        creation_fee_bps: u16,
        repayment_fee_bps: u16,
        // Lender allowlist. Read by every pool on every deposit.
        lp_authorized: Map<ContractAddress, bool>,
        compliance_officer: ContractAddress,
        // Pool registry
        pool_count: u64,
        pools: Map<u64, ContractAddress>,
        is_valid_pool: Map<ContractAddress, bool>,
    }

    #[event]
    #[derive(Drop, starknet::Event)]
    pub enum Event {
        #[flat]
        OwnableEvent: OwnableComponent::Event,
        #[flat]
        PausableEvent: PausableComponent::Event,
        PoolCreated: PoolCreated,
        FeesUpdated: FeesUpdated,
        PlatformWalletUpdated: PlatformWalletUpdated,
        PoolClassHashUpdated: PoolClassHashUpdated,
        LpAuthorizationChanged: LpAuthorizationChanged,
        ComplianceOfficerChanged: ComplianceOfficerChanged,
    }

    /// Emitted on every authorization change. Not telemetry: the off-chain
    /// system needs this to prove its own records agree with the chain, and
    /// the chain is what actually gates a deposit.
    #[derive(Drop, starknet::Event)]
    pub struct LpAuthorizationChanged {
        #[key]
        pub lp: ContractAddress,
        pub authorized: bool,
        pub by: ContractAddress,
    }

    #[derive(Drop, starknet::Event)]
    pub struct ComplianceOfficerChanged {
        pub previous: ContractAddress,
        pub current: ContractAddress,
    }

    #[derive(Drop, starknet::Event)]
    pub struct PoolCreated {
        #[key]
        pub pool_address: ContractAddress,
        #[key]
        pub founder: ContractAddress,
        pub cap_amount: u256,
        pub rate_bps: u16,
        pub duration_days: u32,
        pub interval_days: u32,
        pub funding_deadline: u64,
        pub creation_fee: u256,
        pub timestamp: u64,
    }

    #[derive(Drop, starknet::Event)]
    pub struct FeesUpdated {
        pub creation_fee_cap: u256,
        pub creation_fee_bps: u16,
        pub repayment_fee_bps: u16,
    }

    #[derive(Drop, starknet::Event)]
    pub struct PlatformWalletUpdated {
        pub old_wallet: ContractAddress,
        pub new_wallet: ContractAddress,
    }

    #[derive(Drop, starknet::Event)]
    pub struct PoolClassHashUpdated {
        pub old_class_hash: ClassHash,
        pub new_class_hash: ClassHash,
    }

    #[constructor]
    fn constructor(
        ref self: ContractState,
        owner: ContractAddress,
        platform_wallet: ContractAddress,
        usdc_address: ContractAddress,
        credit_pool_class_hash: ClassHash,
    ) {
        // Validate owner before initializing
        assert(!owner.is_zero(), 'Invalid owner');

        // Initialize ownable
        self.ownable.initializer(owner);

        // Validate addresses
        assert(!platform_wallet.is_zero(), 'Invalid platform wallet');
        assert(!usdc_address.is_zero(), 'Invalid USDC address');

        // Set configuration
        self.platform_wallet.write(platform_wallet);
        self.usdc_address.write(usdc_address);
        self.credit_pool_class_hash.write(credit_pool_class_hash);

        // The owner holds compliance until it is delegated. Leaving this
        // unset would mean nobody can authorize a lender and every pool is
        // unusable until someone notices.
        self.compliance_officer.write(owner);

        // Set default fees
        self.creation_fee_cap.write(CREATION_FEE_CAP_DEFAULT);
        self.creation_fee_bps.write(CREATION_FEE_BPS_DEFAULT);
        self.repayment_fee_bps.write(REPAYMENT_FEE_BPS_DEFAULT);

        // Initialize pool count
        self.pool_count.write(0);
    }

    #[abi(embed_v0)]
    impl PoolFactoryImpl of IPoolFactory<ContractState> {
        fn create_pool(
            ref self: ContractState,
            cap_amount: u256,
            rate_bps: u16,
            duration_days: u32,
            interval_days: u32,
            funding_deadline: u64,
            data_room_hash: felt252,
            max_lenders_limit: u32,
            min_deposit_amount: u256,
        ) -> ContractAddress {
            // Check not paused
            self.pausable.assert_not_paused();

            let caller = get_caller_address();
            let timestamp = get_block_timestamp();

            // Validate parameters
            assert(cap_amount > 0, 'Cap amount must be positive');
            assert(rate_bps > 0 && rate_bps <= 10000, 'Invalid rate');
            assert(duration_days > 0, 'Duration must be positive');
            assert(interval_days > 0 && interval_days <= duration_days, 'Invalid interval');
            assert(funding_deadline > timestamp, 'Deadline must be in future');

            // Calculate and collect creation fee
            let creation_fee = self._calculate_creation_fee(cap_amount);
            if creation_fee > 0 {
                let usdc = IERC20Dispatcher { contract_address: self.usdc_address.read() };
                let platform_wallet = self.platform_wallet.read();
                let success = usdc.transfer_from(caller, platform_wallet, creation_fee);
                assert(success, 'Fee transfer failed');
            }

            // Deploy new pool contract
            let class_hash = self.credit_pool_class_hash.read();
            let pool_count = self.pool_count.read();

            // Create unique salt using Pedersen hash to prevent collisions
            let salt: felt252 = pedersen(pool_count.into(), caller.into());

            // Deploy with empty constructor data
            let (pool_address, _) = deploy_syscall(class_hash, salt, array![].span(), false)
                .unwrap_syscall();

            // Initialize the pool
            let pool = ICreditPoolDispatcher { contract_address: pool_address };
            pool
                .initialize(
                    get_contract_address(),
                    caller,
                    self.usdc_address.read(),
                    self.platform_wallet.read(),
                    self.repayment_fee_bps.read(),
                    cap_amount,
                    rate_bps,
                    duration_days,
                    interval_days,
                    funding_deadline,
                    data_room_hash,
                    max_lenders_limit,
                    min_deposit_amount,
                    // Always on for factory-created pools. A placement that can be
                    // created without its eligibility gate is a placement that
                    // will be, eventually, by accident.
                    true,
                );

            // Register pool
            self.pools.write(pool_count, pool_address);
            self.is_valid_pool.write(pool_address, true);
            self.pool_count.write(pool_count + 1);

            // Emit event
            self
                .emit(
                    PoolCreated {
                        pool_address,
                        founder: caller,
                        cap_amount,
                        rate_bps,
                        duration_days,
                        interval_days,
                        funding_deadline,
                        creation_fee,
                        timestamp,
                    },
                );

            pool_address
        }

        fn set_pool_class_hash(ref self: ContractState, class_hash: ClassHash) {
            self.ownable.assert_only_owner();
            let old_class_hash = self.credit_pool_class_hash.read();
            self.credit_pool_class_hash.write(class_hash);
            self.emit(PoolClassHashUpdated { old_class_hash, new_class_hash: class_hash });
        }

        fn set_platform_wallet(ref self: ContractState, wallet: ContractAddress) {
            self.ownable.assert_only_owner();
            assert(!wallet.is_zero(), 'Invalid wallet');
            let old_wallet = self.platform_wallet.read();
            self.platform_wallet.write(wallet);
            self.emit(PlatformWalletUpdated { old_wallet, new_wallet: wallet });
        }

        fn set_fees(
            ref self: ContractState,
            creation_fee_cap: u256,
            creation_fee_bps: u16,
            repayment_fee_bps: u16,
        ) {
            self.ownable.assert_only_owner();
            assert(creation_fee_bps <= 1000, 'Creation fee max 10%');
            assert(repayment_fee_bps <= 1000, 'Repayment fee max 10%');

            self.creation_fee_cap.write(creation_fee_cap);
            self.creation_fee_bps.write(creation_fee_bps);
            self.repayment_fee_bps.write(repayment_fee_bps);

            self.emit(FeesUpdated { creation_fee_cap, creation_fee_bps, repayment_fee_bps });
        }

        fn pause(ref self: ContractState) {
            self.ownable.assert_only_owner();
            self.pausable.pause();
        }

        fn unpause(ref self: ContractState) {
            self.ownable.assert_only_owner();
            self.pausable.unpause();
        }

        // View functions

        fn get_creation_fee(self: @ContractState, cap_amount: u256) -> u256 {
            self._calculate_creation_fee(cap_amount)
        }

        fn is_valid_pool(self: @ContractState, pool: ContractAddress) -> bool {
            self.is_valid_pool.read(pool)
        }

        fn get_pool(self: @ContractState, index: u64) -> ContractAddress {
            assert(index < self.pool_count.read(), 'Index out of bounds');
            self.pools.read(index)
        }

        fn get_config(self: @ContractState) -> FactoryConfig {
            FactoryConfig {
                owner: self.ownable.owner(),
                platform_wallet: self.platform_wallet.read(),
                usdc_address: self.usdc_address.read(),
                credit_pool_class_hash: self.credit_pool_class_hash.read(),
                creation_fee_cap: self.creation_fee_cap.read(),
                creation_fee_bps: self.creation_fee_bps.read(),
                repayment_fee_bps: self.repayment_fee_bps.read(),
                pool_count: self.pool_count.read(),
                paused: self.pausable.is_paused(),
            }
        }

        fn set_lp_authorization(ref self: ContractState, lp: ContractAddress, authorized: bool) {
            self._assert_only_compliance();
            self._set_lp_authorization(lp, authorized);
        }

        fn set_lp_authorization_batch(
            ref self: ContractState, lps: Span<ContractAddress>, authorized: bool,
        ) {
            self._assert_only_compliance();
            let len: u32 = lps.len();
            assert(len <= MAX_AUTHORIZATION_BATCH, 'Batch too large');
            let mut i: u32 = 0;
            while i < len {
                self._set_lp_authorization(*lps.at(i), authorized);
                i += 1;
            };
        }

        fn is_authorized(self: @ContractState, lp: ContractAddress) -> bool {
            self.lp_authorized.read(lp)
        }

        fn set_compliance_officer(ref self: ContractState, officer: ContractAddress) {
            self.ownable.assert_only_owner();
            assert(!officer.is_zero(), 'Invalid compliance officer');
            let previous = self.compliance_officer.read();
            self.compliance_officer.write(officer);
            self.emit(ComplianceOfficerChanged { previous, current: officer });
        }

        fn get_compliance_officer(self: @ContractState) -> ContractAddress {
            self.compliance_officer.read()
        }

        fn get_repayment_fee_bps(self: @ContractState) -> u16 {
            self.repayment_fee_bps.read()
        }
    }

    // Internal functions
    #[generate_trait]
    impl AllowlistInternalImpl of AllowlistInternalTrait {
        fn _assert_only_compliance(self: @ContractState) {
            let caller = get_caller_address();
            assert(caller == self.compliance_officer.read(), 'Not compliance officer');
        }

        fn _set_lp_authorization(ref self: ContractState, lp: ContractAddress, authorized: bool) {
            assert(!lp.is_zero(), 'Invalid lender address');
            self.lp_authorized.write(lp, authorized);
            self.emit(LpAuthorizationChanged { lp, authorized, by: get_caller_address() });
        }
    }

    #[generate_trait]
    impl InternalImpl of InternalTrait {
        fn _calculate_creation_fee(self: @ContractState, cap_amount: u256) -> u256 {
            // Fee = min(cap, cap_amount * bps / 10000)
            let bps: u256 = self.creation_fee_bps.read().into();
            let percentage_fee = (cap_amount * bps) / BPS_DENOMINATOR;
            let fee_cap = self.creation_fee_cap.read();

            if percentage_fee < fee_cap {
                percentage_fee
            } else {
                fee_cap
            }
        }
    }
}
