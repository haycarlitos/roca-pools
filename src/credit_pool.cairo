#[starknet::contract]
pub mod CreditPool {
    use core::num::traits::Zero;
    use openzeppelin_security::reentrancyguard::ReentrancyGuardComponent;
    use openzeppelin_token::erc20::interface::{IERC20Dispatcher, IERC20DispatcherTrait};
    use seedless_contracts::interfaces::i_credit_pool::{
        ICreditPool, LenderPosition, PoolInfo, PoolStatus, WithdrawalInfo,
    };
    use seedless_contracts::interfaces::i_pool_factory::{
        IPoolFactoryDispatcher, IPoolFactoryDispatcherTrait,
    };
    use starknet::storage::{
        Map, StorageMapReadAccess, StorageMapWriteAccess, StoragePointerReadAccess,
        StoragePointerWriteAccess,
    };
    use starknet::{ContractAddress, get_block_timestamp, get_caller_address, get_contract_address};

    // Component
    component!(
        path: ReentrancyGuardComponent, storage: reentrancy_guard, event: ReentrancyGuardEvent,
    );
    impl ReentrancyGuardInternalImpl = ReentrancyGuardComponent::InternalImpl<ContractState>;

    // Constants
    const BPS_DENOMINATOR: u256 = 10_000;
    const PRECISION: u256 = 1_000_000_000_000_000_000; // 18 decimals for pro-rata calculations
    const SECONDS_PER_DAY: u64 = 86400;

    #[storage]
    struct Storage {
        #[substorage(v0)]
        reentrancy_guard: ReentrancyGuardComponent::Storage,
        // Initialization flag
        initialized: bool,
        // Immutable config (set once during initialize)
        factory: ContractAddress,
        founder: ContractAddress,
        usdc: ContractAddress,
        platform_wallet: ContractAddress,
        repayment_fee_bps: u16,
        cap_amount: u256,
        initial_rate_bps: u16,
        duration_days: u32,
        interval_days: u32,
        data_room_hash: felt252,
        created_at: u64,
        funding_deadline: u64,
        // Placement limits. Both are immutable for the life of the pool.
        max_lenders_limit: u32,
        min_deposit_amount: u256,
        allowlist_enabled: bool,
        // Mutable state
        status: PoolStatus,
        current_rate_bps: u16,
        borrow_rate_bps: u16, // Locked rate at borrow time
        total_deposited: u256,
        total_borrowed: u256,
        total_repaid: u256,
        principal_repaid: u256, // Track principal portion repaid
        borrowed_at: u64,
        last_repayment_at: u64, // Last repayment timestamp (for overdue detection)
        paused: bool, // Emergency pause flag
        // Lender tracking
        lender_count: u32,
        lenders: Map<u32, ContractAddress>,
        lender_index: Map<ContractAddress, u32>, // address -> index+1 (0 means not a lender)
        positions: Map<ContractAddress, LenderPosition>,
    }

    #[event]
    #[derive(Drop, starknet::Event)]
    pub enum Event {
        #[flat]
        ReentrancyGuardEvent: ReentrancyGuardComponent::Event,
        Deposited: Deposited,
        Withdrawn: Withdrawn,
        Borrowed: Borrowed,
        Repaid: Repaid,
        RateLowered: RateLowered,
        StatusChanged: StatusChanged,
        PoolCancelled: PoolCancelled,
        PoolExpired: PoolExpired,
        PoolPaused: PoolPaused,
        PoolUnpaused: PoolUnpaused,
    }

    #[derive(Drop, starknet::Event)]
    pub struct Deposited {
        #[key]
        pub pool: ContractAddress,
        #[key]
        pub lender: ContractAddress,
        pub amount: u256,
        pub pool_total_deposited: u256,
        pub timestamp: u64,
    }

    #[derive(Drop, starknet::Event)]
    pub struct Withdrawn {
        #[key]
        pub pool: ContractAddress,
        #[key]
        pub lender: ContractAddress,
        pub amount: u256,
        pub principal_part: u256,
        pub interest_part: u256,
        pub timestamp: u64,
    }

    #[derive(Drop, starknet::Event)]
    pub struct Borrowed {
        #[key]
        pub pool: ContractAddress,
        #[key]
        pub founder: ContractAddress,
        pub amount: u256,
        pub timestamp: u64,
    }

    #[derive(Drop, starknet::Event)]
    pub struct Repaid {
        #[key]
        pub pool: ContractAddress,
        #[key]
        pub founder: ContractAddress,
        pub amount_total: u256,
        pub principal_part: u256,
        pub interest_part: u256,
        pub platform_fee: u256,
        pub remaining_balance: u256,
        pub timestamp: u64,
    }

    #[derive(Drop, starknet::Event)]
    pub struct RateLowered {
        #[key]
        pub pool: ContractAddress,
        pub old_rate_bps: u16,
        pub new_rate_bps: u16,
        pub timestamp: u64,
    }

    #[derive(Drop, starknet::Event)]
    pub struct StatusChanged {
        #[key]
        pub pool: ContractAddress,
        pub old_status: PoolStatus,
        pub new_status: PoolStatus,
        pub timestamp: u64,
    }

    #[derive(Drop, starknet::Event)]
    pub struct PoolCancelled {
        #[key]
        pub pool: ContractAddress,
        #[key]
        pub founder: ContractAddress,
        pub timestamp: u64,
    }

    #[derive(Drop, starknet::Event)]
    pub struct PoolExpired {
        #[key]
        pub pool: ContractAddress,
        pub funding_deadline: u64,
        pub timestamp: u64,
    }

    #[derive(Drop, starknet::Event)]
    pub struct PoolPaused {
        #[key]
        pub pool: ContractAddress,
        #[key]
        pub paused_by: ContractAddress,
        pub timestamp: u64,
    }

    #[derive(Drop, starknet::Event)]
    pub struct PoolUnpaused {
        #[key]
        pub pool: ContractAddress,
        #[key]
        pub unpaused_by: ContractAddress,
        pub timestamp: u64,
    }

    #[abi(embed_v0)]
    impl CreditPoolImpl of ICreditPool<ContractState> {
        fn initialize(
            ref self: ContractState,
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
            max_lenders_limit: u32,
            min_deposit_amount: u256,
            allowlist_enabled: bool,
        ) {
            // Can only initialize once
            assert(!self.initialized.read(), 'Already initialized');
            self.initialized.write(true);

            // Validate addresses
            assert(!factory.is_zero(), 'Invalid factory');
            assert(!founder.is_zero(), 'Invalid founder');
            assert(!usdc.is_zero(), 'Invalid USDC');
            assert(!platform_wallet.is_zero(), 'Invalid platform wallet');

            // Validate numeric parameters
            assert(cap_amount > 0, 'Cap must be positive');
            assert(rate_bps > 0 && rate_bps <= 10000, 'Invalid rate');
            // Matches PoolFactory.set_fees, which caps this at 1000. The two
            // bounds disagreeing was unreachable through create_pool, since the
            // factory passes its own capped value, but a pool deployed directly
            // could have been initialized with a 100% repayment fee.
            assert(repayment_fee_bps <= 1000, 'Repayment fee max 10%');
            assert(duration_days > 0, 'Duration must be positive');
            assert(interval_days > 0, 'Interval must be positive');
            assert(interval_days <= duration_days, 'Interval exceeds duration');

            // Validate funding deadline
            let now = get_block_timestamp();
            assert(funding_deadline > now, 'Deadline must be in future');

            // Store immutable config
            self.factory.write(factory);
            self.founder.write(founder);
            self.usdc.write(usdc);
            self.platform_wallet.write(platform_wallet);
            self.repayment_fee_bps.write(repayment_fee_bps);
            self.cap_amount.write(cap_amount);
            self.initial_rate_bps.write(rate_bps);
            self.duration_days.write(duration_days);
            self.interval_days.write(interval_days);
            self.data_room_hash.write(data_room_hash);
            self.created_at.write(now);
            self.funding_deadline.write(funding_deadline);
            // A pool that admits no lenders can never fund, so reject it at
            // birth rather than leaving a permanently dead pool on chain.
            assert(max_lenders_limit > 0, 'Max lenders must be positive');
            self.max_lenders_limit.write(max_lenders_limit);
            // min_deposit_amount may be 0, meaning no minimum. It may not
            // exceed the cap: a pool whose minimum ticket is larger than the
            // pool itself can only ever be filled by the single deposit that
            // takes the whole cap, which is a configuration mistake rather
            // than a product.
            assert(min_deposit_amount <= cap_amount, 'Min exceeds cap');
            self.min_deposit_amount.write(min_deposit_amount);
            self.allowlist_enabled.write(allowlist_enabled);

            // Initialize mutable state
            self.status.write(PoolStatus::Pending);
            self.current_rate_bps.write(rate_bps);
            self.borrow_rate_bps.write(0); // Set when borrowing
            self.total_deposited.write(0);
            self.total_borrowed.write(0);
            self.total_repaid.write(0);
            self.principal_repaid.write(0);
            self.borrowed_at.write(0);
            self.last_repayment_at.write(0);
            self.paused.write(false);
            self.lender_count.write(0);
        }

        fn deposit(ref self: ContractState, amount: u256) {
            self.reentrancy_guard.start();

            // Check not paused
            assert(!self.paused.read(), 'Pool is paused');

            let caller = get_caller_address();
            let pool_address = get_contract_address();
            let timestamp = get_block_timestamp();
            let status = self.status.read();

            // Can only deposit in Pending or Active status
            assert(
                status == PoolStatus::Pending || status == PoolStatus::Active,
                'Pool not accepting deposits',
            );

            // Check funding deadline has not passed
            let deadline = self.funding_deadline.read();
            assert(timestamp < deadline, 'Funding deadline passed');

            // Validate amount
            assert(amount > 0, 'Amount must be positive');

            // Check cap
            let total_deposited = self.total_deposited.read();
            let cap_amount = self.cap_amount.read();
            assert(total_deposited + amount <= cap_amount, 'Exceeds pool cap');

            // Eligibility, read from the factory's registry so a revocation
            // is one transaction and takes effect across every pool at once.
            //
            // Checked on deposit only. `withdraw` is deliberately NOT gated:
            // a revoked lender must always be able to exit, or a compliance
            // action becomes a seizure.
            if self.allowlist_enabled.read() {
                let factory = IPoolFactoryDispatcher { contract_address: self.factory.read() };
                assert(factory.is_authorized(caller), 'Lender not authorized');
            }

            // Placement limits apply only to someone joining the roster. An
            // existing lender topping up must never be turned away because the
            // pool is full, and must not have to clear the minimum twice.
            let joining = self.positions.read(caller).deposited == 0;
            if joining {
                assert(
                    self.lender_count.read() < self.max_lenders_limit.read(), 'Max lenders reached',
                );
                // The exception matters: once the remaining headroom is
                // smaller than the minimum ticket, the last slice of the pool
                // would be unsellable and a cap-triggered activation could
                // never fire. Allow exactly the remainder.
                let min_deposit = self.min_deposit_amount.read();
                if min_deposit > 0 {
                    let remaining = cap_amount - total_deposited;
                    assert(amount >= min_deposit || amount == remaining, 'Below min deposit');
                }
            }

            // Transfer USDC from lender
            let usdc = IERC20Dispatcher { contract_address: self.usdc.read() };
            let success = usdc.transfer_from(caller, pool_address, amount);
            assert(success, 'Transfer failed');

            // Update lender position
            let mut position = self.positions.read(caller);
            let is_new_lender = position.deposited == 0;

            position.deposited = position.deposited + amount;
            self.positions.write(caller, position);

            // Register new lender
            if is_new_lender {
                let lender_count = self.lender_count.read();
                self.lenders.write(lender_count, caller);
                self.lender_index.write(caller, lender_count + 1);
                self.lender_count.write(lender_count + 1);
            }

            // Update total deposited
            let new_total = total_deposited + amount;
            self.total_deposited.write(new_total);

            self
                .emit(
                    Deposited {
                        pool: pool_address,
                        lender: caller,
                        amount,
                        pool_total_deposited: new_total,
                        timestamp,
                    },
                );

            self.reentrancy_guard.end();
        }

        fn withdraw(ref self: ContractState) {
            self.reentrancy_guard.start();

            let caller = get_caller_address();
            let pool_address = get_contract_address();
            let timestamp = get_block_timestamp();

            // Check lender has a position
            let position = self.positions.read(caller);
            assert(position.deposited > 0, 'No position');

            // Calculate available withdrawal
            let withdrawal_info = self._calculate_withdrawal(caller);
            assert(withdrawal_info.available > 0, 'Nothing to withdraw');

            // Accounting must follow the money. Before the funds are lent out,
            // a withdrawal returns principal the pool no longer holds, so
            // `total_deposited` has to come down with it. Leaving it inflated
            // breaks three things: `borrow` sends `total_deposited` and would
            // try to transfer more USDC than the pool holds, reverting
            // permanently and killing the vintage; the cap check in `deposit`
            // keeps consuming headroom that was handed back; and the figure
            // stops matching the contract's real balance.
            //
            // Only in the pre-borrow states. Once status is Borrowed,
            // `total_deposited` is the pro-rata denominator in
            // `_calculate_withdrawal` and MUST stay frozen, or an exit would
            // silently inflate everyone else's share.
            let status_now = self.status.read();
            if status_now == PoolStatus::Pending
                || status_now == PoolStatus::Active
                || status_now == PoolStatus::Expired
                || status_now == PoolStatus::Cancelled {
                let deposited_total = self.total_deposited.read();
                self.total_deposited.write(deposited_total - withdrawal_info.available);
            }

            // Update position
            let mut updated_position = position;
            updated_position.withdrawn = position.withdrawn + withdrawal_info.available;

            // A lender who takes everything back before the money is lent out
            // was never part of the placement, so their roster slot has to go
            // back to the pool. Without this the minimum ticket does not bind:
            // the ticket is refundable pre-borrow, so one wallet could cycle
            // the same funds through every slot and leave the pool
            // permanently unfillable at no capital cost. It also strands an
            // honest lender who simply changed their mind.
            //
            // Deliberately NOT done post-borrow: `positions` is the pro-rata
            // record for the rest of the term.
            let pre_borrow = status_now == PoolStatus::Pending
                || status_now == PoolStatus::Active
                || status_now == PoolStatus::Expired
                || status_now == PoolStatus::Cancelled;
            if pre_borrow && updated_position.withdrawn == position.deposited {
                self.positions.write(caller, LenderPosition { deposited: 0, withdrawn: 0 });
                self._deregister_lender(caller);
            } else {
                self.positions.write(caller, updated_position);
            }

            // Transfer USDC to lender
            let usdc = IERC20Dispatcher { contract_address: self.usdc.read() };
            let success = usdc.transfer(caller, withdrawal_info.available);
            assert(success, 'Transfer failed');

            self
                .emit(
                    Withdrawn {
                        pool: pool_address,
                        lender: caller,
                        amount: withdrawal_info.available,
                        principal_part: withdrawal_info.principal_part,
                        interest_part: withdrawal_info.interest_part,
                        timestamp,
                    },
                );

            self.reentrancy_guard.end();
        }

        fn borrow(ref self: ContractState) {
            self.reentrancy_guard.start();

            // Check not paused
            assert(!self.paused.read(), 'Pool is paused');

            let caller = get_caller_address();
            let pool_address = get_contract_address();
            let timestamp = get_block_timestamp();

            // Only founder can borrow
            assert(caller == self.founder.read(), 'Only founder');

            // Must be Active status
            let status = self.status.read();
            assert(status == PoolStatus::Active, 'Pool not active');

            // Check funding deadline has not passed
            let deadline = self.funding_deadline.read();
            assert(timestamp < deadline, 'Funding deadline passed');

            // Get amount to borrow (all deposited funds)
            let amount = self.total_deposited.read();
            assert(amount > 0, 'No funds to borrow');

            // Update state
            self.total_borrowed.write(amount);
            self.borrowed_at.write(timestamp);
            self.last_repayment_at.write(timestamp); // Initialize for overdue tracking
            // Lock the interest rate at borrow time
            self.borrow_rate_bps.write(self.current_rate_bps.read());
            self._set_status(PoolStatus::Borrowed);

            // Transfer USDC to founder
            let usdc = IERC20Dispatcher { contract_address: self.usdc.read() };
            let success = usdc.transfer(caller, amount);
            assert(success, 'Transfer failed');

            self.emit(Borrowed { pool: pool_address, founder: caller, amount, timestamp });

            self.reentrancy_guard.end();
        }

        fn repay(ref self: ContractState, amount: u256) {
            self.reentrancy_guard.start();

            // Check not paused
            assert(!self.paused.read(), 'Pool is paused');

            let caller = get_caller_address();
            let pool_address = get_contract_address();
            let timestamp = get_block_timestamp();

            // Only founder can repay
            assert(caller == self.founder.read(), 'Only founder');

            // Borrowed, or Defaulted. Accepting repayment after a default is
            // deliberate: `mark_defaulted` is a statement about the borrower,
            // and blocking repayment afterwards would mean a recovery collected
            // from the loan book could never be distributed to lenders through
            // the pool. That made never marking a default strictly better for
            // lenders than marking one honestly, which is the wrong incentive
            // to put in a contract.
            //
            // The status stays Defaulted. It is a historical fact, not a
            // balance, and a recovery does not undo it. Lenders withdraw
            // pro-rata of total_repaid in both states, so the payout path is
            // identical either way.
            let status = self.status.read();
            assert(
                status == PoolStatus::Borrowed || status == PoolStatus::Defaulted,
                'Pool not borrowed',
            );

            assert(amount > 0, 'Amount must be positive');

            // Calculate platform fee
            let fee_bps: u256 = self.repayment_fee_bps.read().into();
            let platform_fee = (amount * fee_bps) / BPS_DENOMINATOR;
            let amount_to_pool = amount - platform_fee;

            // Calculate remaining balance BEFORE this payment (Fix 2)
            let total_borrowed = self.total_borrowed.read();
            let rate_bps: u256 = self.borrow_rate_bps.read().into();
            let total_interest = (total_borrowed * rate_bps) / BPS_DENOMINATOR;
            let total_owed = total_borrowed + total_interest;

            // Capture old total BEFORE updating (Fix 1)
            let old_total_repaid = self.total_repaid.read();
            let remaining_before = if old_total_repaid >= total_owed {
                0
            } else {
                total_owed - old_total_repaid
            };

            // Prevent overpayment (Fix 2)
            assert(amount_to_pool <= remaining_before, 'Exceeds remaining balance');

            // Transfer from founder
            let usdc = IERC20Dispatcher { contract_address: self.usdc.read() };

            // Transfer platform fee
            if platform_fee > 0 {
                let success = usdc.transfer_from(caller, self.platform_wallet.read(), platform_fee);
                assert(success, 'Fee transfer failed');
            }

            // Transfer to pool for lenders
            let success = usdc.transfer_from(caller, pool_address, amount_to_pool);
            assert(success, 'Repayment transfer failed');

            // Update total repaid
            let new_total_repaid = old_total_repaid + amount_to_pool;
            self.total_repaid.write(new_total_repaid);

            // Calculate principal vs interest parts using pro-rata allocation
            let principal_repaid = self.principal_repaid.read();
            let remaining_principal = total_borrowed - principal_repaid;

            // Fix 1: Use old_total_repaid for interest calculation
            let interest_repaid = old_total_repaid - principal_repaid;
            let remaining_interest = if total_interest > interest_repaid {
                total_interest - interest_repaid
            } else {
                0
            };
            let total_remaining = remaining_principal + remaining_interest;

            // Pro-rata split of this payment
            let (principal_part, interest_part) = if total_remaining == 0 {
                (0, 0)
            } else {
                let principal_portion = (amount_to_pool * remaining_principal) / total_remaining;
                let interest_portion = amount_to_pool - principal_portion;
                (principal_portion, interest_portion)
            };

            // Update tracked principal repaid
            self.principal_repaid.write(principal_repaid + principal_part);

            // Update last repayment timestamp for overdue tracking
            self.last_repayment_at.write(timestamp);

            // Calculate remaining after this payment
            let remaining = if new_total_repaid >= total_owed {
                0
            } else {
                total_owed - new_total_repaid
            };

            // Check if fully repaid
            if remaining == 0 {
                self._set_status(PoolStatus::Completed);
            }

            self
                .emit(
                    Repaid {
                        pool: pool_address,
                        founder: caller,
                        amount_total: amount,
                        principal_part,
                        interest_part,
                        platform_fee,
                        remaining_balance: remaining,
                        timestamp,
                    },
                );

            self.reentrancy_guard.end();
        }

        fn lower_rate(ref self: ContractState, new_rate_bps: u16) {
            let caller = get_caller_address();
            let pool_address = get_contract_address();
            let timestamp = get_block_timestamp();

            // Only founder can lower rate
            assert(caller == self.founder.read(), 'Only founder');

            // Can only lower rate before borrowing (Pending or Active)
            let status = self.status.read();
            assert(
                status == PoolStatus::Pending || status == PoolStatus::Active,
                'Rate locked after borrow',
            );

            let current_rate = self.current_rate_bps.read();

            // Can only decrease, never increase
            assert(new_rate_bps < current_rate, 'Can only lower rate');
            assert(new_rate_bps > 0, 'Rate must be positive');

            self.current_rate_bps.write(new_rate_bps);

            self
                .emit(
                    RateLowered {
                        pool: pool_address, old_rate_bps: current_rate, new_rate_bps, timestamp,
                    },
                );
        }

        fn activate(ref self: ContractState) {
            let caller = get_caller_address();

            // Only founder can activate
            assert(caller == self.founder.read(), 'Only founder');

            // Must be Pending status
            let status = self.status.read();
            assert(status == PoolStatus::Pending, 'Pool not pending');

            self._set_status(PoolStatus::Active);
        }

        fn mark_defaulted(ref self: ContractState) {
            let caller = get_caller_address();

            // Only factory can mark as defaulted
            assert(caller == self.factory.read(), 'Only factory');

            let status = self.status.read();
            assert(status == PoolStatus::Borrowed, 'Pool not borrowed');

            let now = get_block_timestamp();
            let borrowed_at = self.borrowed_at.read();
            let duration_days: u64 = self.duration_days.read().into();
            let interval_days: u64 = self.interval_days.read().into();
            let last_repayment_at = self.last_repayment_at.read();

            // Can default if either:
            // 1. Full duration has expired
            // 2. No payment received for 2x interval_days (grace period)
            let duration_deadline = borrowed_at + (duration_days * SECONDS_PER_DAY);
            let duration_expired = now >= duration_deadline;

            let grace_period = interval_days * 2 * SECONDS_PER_DAY;
            let payment_overdue = now >= last_repayment_at + grace_period;

            assert(duration_expired || payment_overdue, 'Not defaultable yet');

            self._set_status(PoolStatus::Defaulted);
        }

        fn cancel(ref self: ContractState) {
            let caller = get_caller_address();
            let pool_address = get_contract_address();
            let timestamp = get_block_timestamp();

            // Only founder can cancel
            assert(caller == self.founder.read(), 'Only founder');

            // Can only cancel during funding phase (Pending or Active)
            let status = self.status.read();
            assert(
                status == PoolStatus::Pending || status == PoolStatus::Active,
                'Cannot cancel after borrow',
            );

            // Set status to Cancelled
            self._set_status(PoolStatus::Cancelled);

            self.emit(PoolCancelled { pool: pool_address, founder: caller, timestamp });
        }

        fn expire(ref self: ContractState) {
            let pool_address = get_contract_address();
            let timestamp = get_block_timestamp();
            let deadline = self.funding_deadline.read();

            // Can only expire after funding deadline has passed
            assert(timestamp >= deadline, 'Deadline not passed');

            // Can only expire during funding phase (Pending or Active)
            let status = self.status.read();
            assert(status == PoolStatus::Pending || status == PoolStatus::Active, 'Cannot expire');

            // Set status to Expired
            self._set_status(PoolStatus::Expired);

            self.emit(PoolExpired { pool: pool_address, funding_deadline: deadline, timestamp });
        }

        fn pause(ref self: ContractState) {
            let caller = get_caller_address();
            let pool_address = get_contract_address();
            let timestamp = get_block_timestamp();

            // Only founder or factory can pause
            let founder = self.founder.read();
            let factory = self.factory.read();
            assert(caller == founder || caller == factory, 'Not authorized to pause');

            // Cannot pause if already paused
            assert(!self.paused.read(), 'Already paused');

            self.paused.write(true);

            self.emit(PoolPaused { pool: pool_address, paused_by: caller, timestamp });
        }

        fn unpause(ref self: ContractState) {
            let caller = get_caller_address();
            let pool_address = get_contract_address();
            let timestamp = get_block_timestamp();

            // Only factory can unpause (prevents malicious founder lock)
            assert(caller == self.factory.read(), 'Only factory can unpause');

            // Cannot unpause if not paused
            assert(self.paused.read(), 'Not paused');

            self.paused.write(false);

            self.emit(PoolUnpaused { pool: pool_address, unpaused_by: caller, timestamp });
        }

        // View functions

        fn get_pool_info(self: @ContractState) -> PoolInfo {
            PoolInfo {
                factory: self.factory.read(),
                founder: self.founder.read(),
                usdc: self.usdc.read(),
                platform_wallet: self.platform_wallet.read(),
                repayment_fee_bps: self.repayment_fee_bps.read(),
                cap_amount: self.cap_amount.read(),
                initial_rate_bps: self.initial_rate_bps.read(),
                duration_days: self.duration_days.read(),
                interval_days: self.interval_days.read(),
                data_room_hash: self.data_room_hash.read(),
                created_at: self.created_at.read(),
                funding_deadline: self.funding_deadline.read(),
                status: self.status.read(),
                current_rate_bps: self.current_rate_bps.read(),
                borrow_rate_bps: self.borrow_rate_bps.read(),
                total_deposited: self.total_deposited.read(),
                total_borrowed: self.total_borrowed.read(),
                total_repaid: self.total_repaid.read(),
                principal_repaid: self.principal_repaid.read(),
                borrowed_at: self.borrowed_at.read(),
                last_repayment_at: self.last_repayment_at.read(),
                lender_count: self.lender_count.read(),
                paused: self.paused.read(),
            }
        }

        fn get_position(self: @ContractState, lender: ContractAddress) -> LenderPosition {
            self.positions.read(lender)
        }

        fn get_available_withdrawal(
            self: @ContractState, lender: ContractAddress,
        ) -> WithdrawalInfo {
            self._calculate_withdrawal(lender)
        }

        fn get_lender(self: @ContractState, index: u32) -> ContractAddress {
            assert(index < self.lender_count.read(), 'Index out of bounds');
            self.lenders.read(index)
        }

        fn is_lender(self: @ContractState, address: ContractAddress) -> bool {
            self.lender_index.read(address) > 0
        }

        fn get_max_lenders_limit(self: @ContractState) -> u32 {
            self.max_lenders_limit.read()
        }

        fn get_min_deposit_amount(self: @ContractState) -> u256 {
            self.min_deposit_amount.read()
        }

        fn is_allowlist_enabled(self: @ContractState) -> bool {
            self.allowlist_enabled.read()
        }
    }

    // Internal functions
    #[generate_trait]
    impl InternalImpl of InternalTrait {
        /// Remove a lender from the roster, keeping `lenders` densely packed
        /// so `get_lender(index)` stays valid for every remaining lender.
        ///
        /// `lender_index` is one-based: 0 means "not a lender", so a stored
        /// value of N refers to slot N-1. That convention has to survive the
        /// move, which is the part that is easy to get wrong: writing the
        /// moved lender's index as its slot rather than slot+1 silently
        /// corrupts lookups for an unrelated address.
        fn _deregister_lender(ref self: ContractState, lender: ContractAddress) {
            let count = self.lender_count.read();
            assert(count > 0, 'No lenders to remove');

            let one_based = self.lender_index.read(lender);
            assert(one_based > 0, 'Lender not registered');

            let slot = one_based - 1;
            let last_slot = count - 1;

            if slot != last_slot {
                // Move the tail lender into the vacated slot and repoint it.
                let moved = self.lenders.read(last_slot);
                self.lenders.write(slot, moved);
                self.lender_index.write(moved, one_based);
            }

            // Clear the tail and forget this lender. `get_lender` bounds-checks
            // against `lender_count`, so the cleared slot is unreachable, but
            // leaving a stale address behind would be misleading to anyone
            // reading storage directly.
            self.lenders.write(last_slot, Zero::zero());
            self.lender_index.write(lender, 0);
            self.lender_count.write(last_slot);
        }

        fn _set_status(ref self: ContractState, new_status: PoolStatus) {
            let pool_address = get_contract_address();
            let timestamp = get_block_timestamp();
            let old_status = self.status.read();

            self.status.write(new_status);

            self.emit(StatusChanged { pool: pool_address, old_status, new_status, timestamp });
        }

        fn _calculate_withdrawal(self: @ContractState, lender: ContractAddress) -> WithdrawalInfo {
            let position = self.positions.read(lender);

            if position.deposited == 0 {
                return WithdrawalInfo { available: 0, principal_part: 0, interest_part: 0 };
            }

            let total_deposited = self.total_deposited.read();
            let total_repaid = self.total_repaid.read();
            let status = self.status.read();

            // Before borrowing OR pool expired/cancelled: can withdraw deposited amount
            if status == PoolStatus::Pending
                || status == PoolStatus::Active
                || status == PoolStatus::Expired
                || status == PoolStatus::Cancelled {
                let available = position.deposited - position.withdrawn;
                return WithdrawalInfo { available, principal_part: available, interest_part: 0 };
            }

            // After borrowing: pro-rata share of repayments
            // lender_share = lender_deposited / total_deposited
            // lender_entitlement = total_repaid * lender_share
            // available = lender_entitlement - already_withdrawn
            //
            // Rounding policy: all divisions round DOWN (truncate), which is conservative
            // for lender entitlements. This ensures the pool never owes more than available.
            // Cairo 2.x has built-in overflow protection on arithmetic operations.

            if total_deposited == 0 {
                return WithdrawalInfo { available: 0, principal_part: 0, interest_part: 0 };
            }

            // Bounds check: position cannot exceed total
            assert(position.deposited <= total_deposited, 'Invalid position');

            // Use high precision for pro-rata calculation (rounds down)
            let lender_share = (position.deposited * PRECISION) / total_deposited;
            let lender_entitlement = (total_repaid * lender_share) / PRECISION;
            let available = if lender_entitlement > position.withdrawn {
                lender_entitlement - position.withdrawn
            } else {
                0
            };

            // Calculate principal vs interest
            // Principal is capped at original deposit
            let max_principal = position.deposited - position.withdrawn;
            let principal_part = if available > max_principal {
                max_principal
            } else {
                available
            };
            let interest_part = available - principal_part;

            WithdrawalInfo { available, principal_part, interest_part }
        }
    }
}
