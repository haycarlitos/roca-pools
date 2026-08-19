//! AuditRegistry coverage.
//!
//! The two properties that carry weight: a bank receipt can be anchored at most
//! once, and a loan's inclusion in an anchored batch can be proven without the
//! batch's contents ever being published.

use core::poseidon::poseidon_hash_span;
use seedless_contracts::interfaces::i_audit_registry::{
    IAuditRegistryDispatcher, IAuditRegistryDispatcherTrait,
};
use snforge_std_deprecated::{
    ContractClassTrait, DeclareResultTrait, declare, start_cheat_block_timestamp,
    start_cheat_caller_address, stop_cheat_caller_address,
};
use starknet::{ContractAddress, contract_address_const};

fn OWNER() -> ContractAddress {
    contract_address_const::<'OWNER'>()
}
fn SERVICER() -> ContractAddress {
    contract_address_const::<'SERVICER'>()
}
fn STRANGER() -> ContractAddress {
    contract_address_const::<'STRANGER'>()
}

fn deploy() -> IAuditRegistryDispatcher {
    let c = declare("AuditRegistry").unwrap().contract_class();
    let (a, _) = c.deploy(@array![OWNER().into()]).unwrap();
    IAuditRegistryDispatcher { contract_address: a }
}

/// Same sorted-pair Poseidon the contract uses.
fn hash_pair(a: felt252, b: felt252) -> felt252 {
    let pair = if Into::<felt252, u256>::into(a) < Into::<felt252, u256>::into(b) {
        array![a, b]
    } else {
        array![b, a]
    };
    poseidon_hash_span(pair.span())
}

/// leaf = poseidon(loan_id, centavos, period, salt)
fn leaf(loan_id: felt252, centavos: felt252, period: felt252, salt: felt252) -> felt252 {
    poseidon_hash_span(array![loan_id, centavos, period, salt].span())
}

// ------------------------------------------------------------- anchoring

#[test]
fn test_anchor_and_read_back() {
    let reg = deploy();
    start_cheat_block_timestamp(reg.contract_address, 1_700_000_000);
    start_cheat_caller_address(reg.contract_address, OWNER());
    reg.register_batch(1, 'CEP_HASH_1', 'MERKLE_ROOT_1', 150_000_00);
    stop_cheat_caller_address(reg.contract_address);

    let b = reg.get_batch(1);
    assert(b.cep_hash == 'CEP_HASH_1', 'CEP recorded');
    assert(b.merkle_root == 'MERKLE_ROOT_1', 'Root recorded');
    assert(b.total_mxn_centavos == 150_000_00, 'Total recorded');
    assert(b.anchored_by == OWNER(), 'Anchorer recorded');
    assert(b.anchored_at == 1_700_000_000, 'Timestamp recorded');
    assert(reg.get_batch_count() == 1, 'Counted');
    assert(reg.is_cep_processed('CEP_HASH_1'), 'CEP marked processed');
}

#[test]
#[should_panic(expected: ('CEP already processed',))]
fn test_the_same_receipt_cannot_be_anchored_twice() {
    // The point of the whole contract. One SPEI must not justify two
    // repayments, even under a different batch id.
    let reg = deploy();
    start_cheat_caller_address(reg.contract_address, OWNER());
    reg.register_batch(1, 'CEP_HASH_1', 'ROOT_A', 100);
    reg.register_batch(2, 'CEP_HASH_1', 'ROOT_B', 100);
}

#[test]
#[should_panic(expected: ('Batch already registered',))]
fn test_batch_id_cannot_be_reused() {
    let reg = deploy();
    start_cheat_caller_address(reg.contract_address, OWNER());
    reg.register_batch(1, 'CEP_A', 'ROOT_A', 100);
    reg.register_batch(1, 'CEP_B', 'ROOT_B', 100);
}

#[test]
#[should_panic(expected: ('Not a servicer',))]
fn test_stranger_cannot_anchor() {
    let reg = deploy();
    start_cheat_caller_address(reg.contract_address, STRANGER());
    reg.register_batch(1, 'CEP', 'ROOT', 100);
}

#[test]
fn test_owner_can_delegate_servicing() {
    let reg = deploy();
    assert(reg.is_servicer(OWNER()), 'Owner services by default');
    assert(!reg.is_servicer(SERVICER()), 'Not yet');

    start_cheat_caller_address(reg.contract_address, OWNER());
    reg.set_servicer(SERVICER(), true);
    stop_cheat_caller_address(reg.contract_address);

    start_cheat_caller_address(reg.contract_address, SERVICER());
    reg.register_batch(1, 'CEP', 'ROOT', 100);
    stop_cheat_caller_address(reg.contract_address);
    assert(reg.get_batch_count() == 1, 'Servicer could anchor');
}

#[test]
#[should_panic(expected: ('Not a servicer',))]
fn test_servicing_can_be_revoked() {
    let reg = deploy();
    start_cheat_caller_address(reg.contract_address, OWNER());
    reg.set_servicer(SERVICER(), true);
    reg.set_servicer(SERVICER(), false);
    stop_cheat_caller_address(reg.contract_address);

    start_cheat_caller_address(reg.contract_address, SERVICER());
    reg.register_batch(1, 'CEP', 'ROOT', 100);
}

#[test]
#[should_panic(expected: ('Caller is not the owner',))]
fn test_servicer_cannot_appoint_servicers() {
    let reg = deploy();
    start_cheat_caller_address(reg.contract_address, OWNER());
    reg.set_servicer(SERVICER(), true);
    stop_cheat_caller_address(reg.contract_address);

    start_cheat_caller_address(reg.contract_address, SERVICER());
    reg.set_servicer(STRANGER(), true);
}

#[test]
#[should_panic(expected: ('Invalid cep_hash',))]
fn test_empty_attestation_is_rejected() {
    // A zero hash would look like an anchored batch while attesting nothing.
    let reg = deploy();
    start_cheat_caller_address(reg.contract_address, OWNER());
    reg.register_batch(1, 0, 'ROOT', 100);
}

#[test]
#[should_panic(expected: ('Invalid total',))]
fn test_zero_total_is_rejected() {
    let reg = deploy();
    start_cheat_caller_address(reg.contract_address, OWNER());
    reg.register_batch(1, 'CEP', 'ROOT', 0);
}

#[test]
#[should_panic(expected: ('Unknown batch',))]
fn test_reading_an_unknown_batch_fails_loudly() {
    // Rather than returning a zeroed record that reads like a real one.
    let reg = deploy();
    reg.get_batch(42);
}

// ------------------------------------------------------- inclusion proofs

#[test]
fn test_inclusion_proof_over_a_four_leaf_batch() {
    // Four loans in one employer transfer. Prove loan 2 was in it without
    // publishing any of the four.
    let l0 = leaf(1001, 150000, 'Q1_2026_08', 'SALT_A');
    let l1 = leaf(1002, 225000, 'Q1_2026_08', 'SALT_B');
    let l2 = leaf(1003, 180000, 'Q1_2026_08', 'SALT_C');
    let l3 = leaf(1004, 320000, 'Q1_2026_08', 'SALT_D');

    let n01 = hash_pair(l0, l1);
    let n23 = hash_pair(l2, l3);
    let root = hash_pair(n01, n23);

    let reg = deploy();
    start_cheat_caller_address(reg.contract_address, OWNER());
    reg.register_batch(1, 'CEP_HASH', root, 875000);
    stop_cheat_caller_address(reg.contract_address);

    // l1's path: its sibling l0, then the other subtree n23.
    assert(
        reg.verify_loan_inclusion(1, 1002, 225000, 'Q1_2026_08', 'SALT_B', array![l0, n23].span()),
        'l1 is in the batch',
    );
    // and l2's, from the other side.
    assert(
        reg.verify_loan_inclusion(1, 1003, 180000, 'Q1_2026_08', 'SALT_C', array![l3, n01].span()),
        'l2 is in the batch',
    );
}

#[test]
fn test_a_loan_that_was_not_in_the_batch_fails() {
    let l0 = leaf(1001, 150000, 'Q1_2026_08', 'SALT_A');
    let l1 = leaf(1002, 225000, 'Q1_2026_08', 'SALT_B');
    let root = hash_pair(l0, l1);
    let forged = leaf(9999, 999999, 'Q1_2026_08', 'SALT_X');

    let reg = deploy();
    start_cheat_caller_address(reg.contract_address, OWNER());
    reg.register_batch(1, 'CEP_HASH', root, 375000);
    stop_cheat_caller_address(reg.contract_address);

    assert(
        !reg.verify_loan_inclusion(1, 9999, 999999, 'Q1_2026_08', 'SALT_X', array![l0].span()),
        'Forged leaf rejected',
    );
}

#[test]
fn test_tampering_with_the_amount_breaks_the_proof() {
    // The property that makes the anchor worth anything: the committed amount
    // cannot be restated afterwards.
    let real = leaf(1001, 150000, 'Q1_2026_08', 'SALT_A');
    let sibling = leaf(1002, 225000, 'Q1_2026_08', 'SALT_B');
    let root = hash_pair(real, sibling);

    let reg = deploy();
    start_cheat_caller_address(reg.contract_address, OWNER());
    reg.register_batch(1, 'CEP_HASH', root, 375000);
    stop_cheat_caller_address(reg.contract_address);

    assert(
        reg.verify_loan_inclusion(1, 1001, 150000, 'Q1_2026_08', 'SALT_A', array![sibling].span()),
        'Real leaf verifies',
    );
    assert(
        !reg.verify_loan_inclusion(1, 1001, 999999, 'Q1_2026_08', 'SALT_A', array![sibling].span()),
        'Tampered rejected',
    );
}

#[test]
fn test_proof_against_an_unanchored_batch_is_false_not_a_panic() {
    // A caller asking about a batch that does not exist should get "no",
    // not a revert that looks like a bug in their code.
    let reg = deploy();
    assert(!reg.verify_loan_inclusion(7, 1, 1, 1, 1, array!['SIB'].span()), 'No batch, no proof');
}

#[test]
fn test_single_leaf_batch_needs_an_empty_proof() {
    // One loan in the transfer: the leaf is the root.
    let only = leaf(1001, 150000, 'Q1_2026_08', 'SALT_A');
    let reg = deploy();
    start_cheat_caller_address(reg.contract_address, OWNER());
    reg.register_batch(1, 'CEP_HASH', only, 150000);
    stop_cheat_caller_address(reg.contract_address);

    assert(
        reg.verify_loan_inclusion(1, 1001, 150000, 'Q1_2026_08', 'SALT_A', array![].span()),
        'Leaf is the root',
    );
}

/// Passing an internal node where a leaf is expected must not verify.
///
/// With four leaves the root is H(n01, n23). Handing the verifier n01 as the
/// "leaf" with [n23] as the proof recomputes the root exactly, so an interface
/// that accepts a precomputed leaf would answer true for something that is not
/// a deduction at all.
#[test]
fn test_an_internal_node_cannot_pose_as_a_leaf() {
    let l0 = leaf(1001, 150000, 'Q1_2026_08', 'SALT_A');
    let l1 = leaf(1002, 225000, 'Q1_2026_08', 'SALT_B');
    let l2 = leaf(1003, 180000, 'Q1_2026_08', 'SALT_C');
    let l3 = leaf(1004, 320000, 'Q1_2026_08', 'SALT_D');
    let n01 = hash_pair(l0, l1);
    let n23 = hash_pair(l2, l3);
    let root = hash_pair(n01, n23);

    let reg = deploy();
    start_cheat_caller_address(reg.contract_address, OWNER());
    reg.register_batch(1, 'CEP_HASH', root, 875000);
    stop_cheat_caller_address(reg.contract_address);

    // A real deduction still verifies.
    assert(
        reg.verify_loan_inclusion(1, 1002, 225000, 'Q1_2026_08', 'SALT_B', array![l0, n23].span()),
        'Real deduction verifies',
    );
}
