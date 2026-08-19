/// A token that attacks the contract it is paying.
///
/// Real USDC does not do this. The point is that `CreditPool` calls
/// `transfer` before it has finished its own bookkeeping in some orderings, and
/// "we use a well-behaved token" is an assumption rather than a guarantee: the
/// token address is set at initialize, and a pool pointed at a hostile token
/// is a configuration mistake, not an impossibility.
///
/// On `transfer`, if a target is armed, this calls `withdraw()` back into it
/// before returning. If the reentrancy guard is doing its job the whole
/// transaction reverts.
#[starknet::contract]
pub mod ReentrantERC20 {
    use core::num::traits::Zero;
    use seedless_contracts::interfaces::i_credit_pool::{
        ICreditPoolDispatcher, ICreditPoolDispatcherTrait,
    };
    use starknet::storage::{
        Map, StoragePathEntry, StoragePointerReadAccess, StoragePointerWriteAccess,
    };
    use starknet::{ContractAddress, get_caller_address};

    #[storage]
    struct Storage {
        balances: Map<ContractAddress, u256>,
        allowances: Map<(ContractAddress, ContractAddress), u256>,
        /// Armed target. Zero means behave like an ordinary token.
        reenter_into: ContractAddress,
        /// Re-enter once. Without this the callback recurses until it runs out
        /// of steps and the test proves nothing about the guard.
        fired: bool,
    }

    #[constructor]
    fn constructor(ref self: ContractState) {}

    #[abi(embed_v0)]
    impl ReentrantERC20Impl of super::IReentrantERC20<ContractState> {
        fn mint(ref self: ContractState, to: ContractAddress, amount: u256) {
            self.balances.entry(to).write(self.balances.entry(to).read() + amount);
        }

        fn arm(ref self: ContractState, target: ContractAddress) {
            self.reenter_into.write(target);
            self.fired.write(false);
        }

        fn balance_of(self: @ContractState, account: ContractAddress) -> u256 {
            self.balances.entry(account).read()
        }

        fn allowance(
            self: @ContractState, owner: ContractAddress, spender: ContractAddress,
        ) -> u256 {
            self.allowances.entry((owner, spender)).read()
        }

        fn approve(ref self: ContractState, spender: ContractAddress, amount: u256) -> bool {
            self.allowances.entry((get_caller_address(), spender)).write(amount);
            true
        }

        fn transfer(ref self: ContractState, recipient: ContractAddress, amount: u256) -> bool {
            let from = get_caller_address();
            let bal = self.balances.entry(from).read();
            assert(bal >= amount, 'Insufficient balance');
            self.balances.entry(from).write(bal - amount);
            self.balances.entry(recipient).write(self.balances.entry(recipient).read() + amount);

            // The attack. `from` is the pool paying a lender out.
            let target = self.reenter_into.read();
            if !target.is_zero() && !self.fired.read() {
                self.fired.write(true);
                ICreditPoolDispatcher { contract_address: target }.withdraw();
            }
            true
        }

        fn transfer_from(
            ref self: ContractState,
            sender: ContractAddress,
            recipient: ContractAddress,
            amount: u256,
        ) -> bool {
            let spender = get_caller_address();
            let allowed = self.allowances.entry((sender, spender)).read();
            assert(allowed >= amount, 'Insufficient allowance');
            self.allowances.entry((sender, spender)).write(allowed - amount);
            let bal = self.balances.entry(sender).read();
            assert(bal >= amount, 'Insufficient balance');
            self.balances.entry(sender).write(bal - amount);
            self.balances.entry(recipient).write(self.balances.entry(recipient).read() + amount);
            true
        }
    }
}

#[starknet::interface]
pub trait IReentrantERC20<TContractState> {
    fn mint(ref self: TContractState, to: starknet::ContractAddress, amount: u256);
    fn arm(ref self: TContractState, target: starknet::ContractAddress);
    fn balance_of(self: @TContractState, account: starknet::ContractAddress) -> u256;
    fn allowance(
        self: @TContractState, owner: starknet::ContractAddress, spender: starknet::ContractAddress,
    ) -> u256;
    fn approve(ref self: TContractState, spender: starknet::ContractAddress, amount: u256) -> bool;
    fn transfer(
        ref self: TContractState, recipient: starknet::ContractAddress, amount: u256,
    ) -> bool;
    fn transfer_from(
        ref self: TContractState,
        sender: starknet::ContractAddress,
        recipient: starknet::ContractAddress,
        amount: u256,
    ) -> bool;
}
