#[starknet::contract]
pub mod PoolFactory {
    use starknet::{
        ContractAddress, ClassHash, get_caller_address, get_block_timestamp,
        get_contract_address, syscalls::deploy_syscall, SyscallResultTrait
    };
    use core::pedersen::pedersen;
    use starknet::storage::{
        StoragePointerReadAccess, StoragePointerWriteAccess,
        Map, StorageMapReadAccess, StorageMapWriteAccess
    };
    use core::num::traits::Zero;
    use openzeppelin_access::ownable::OwnableComponent;
    use openzeppelin_security::pausable::PausableComponent;
    use openzeppelin_token::erc20::interface::{IERC20Dispatcher, IERC20DispatcherTrait};
    use seedless_contracts::interfaces::i_pool_factory::{IPoolFactory, FactoryConfig};
    use seedless_contracts::interfaces::i_credit_pool::{ICreditPoolDispatcher, ICreditPoolDispatcherTrait};

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
    const CREATION_FEE_CAP_DEFAULT: u256 = 199_000_000; // $199 in USDC (6 decimals)
    const CREATION_FEE_BPS_DEFAULT: u16 = 100;          // 1%
    const REPAYMENT_FEE_BPS_DEFAULT: u16 = 50;          // 0.5%
    const BPS_DENOMINATOR: u256 = 10_000;

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
            let (pool_address, _) = deploy_syscall(
                class_hash,
                salt,
                array![].span(),
                false
            ).unwrap_syscall();

            // Initialize the pool
            let pool = ICreditPoolDispatcher { contract_address: pool_address };
            pool.initialize(
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
            );

            // Register pool
            self.pools.write(pool_count, pool_address);
            self.is_valid_pool.write(pool_address, true);
            self.pool_count.write(pool_count + 1);

            // Emit event
            self.emit(PoolCreated {
                pool_address,
                founder: caller,
                cap_amount,
                rate_bps,
                duration_days,
                interval_days,
                funding_deadline,
                creation_fee,
                timestamp,
            });

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

        fn get_repayment_fee_bps(self: @ContractState) -> u16 {
            self.repayment_fee_bps.read()
        }
    }

    // Internal functions
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
