#!/usr/bin/env bash
#
# Add or remove investors on the PoolFactory allowlist.
#
# Every factory-created pool has the allowlist ON — create_pool hardcodes
# `allowlist_enabled: true` and there is no argument to disable it, on the
# reasoning that a placement which CAN be created without its eligibility gate
# eventually will be, by accident. So `deposit` calls back into the factory:
#
#     if self.allowlist_enabled.read() {
#         assert(factory.is_authorized(caller), 'Lender not authorized');
#     }
#
# Which means a wallet that is not on the allowlist cannot deposit into any
# pool, including your own during a rehearsal. This is the step that unblocks
# that, and it is a step, not an optional extra.
#
# WHO CAN RUN THIS: the compliance officer. The factory constructor seeds that
# to the OWNER ("the owner holds compliance until it is delegated"), so before
# any delegation the owner key is the one that works here.
#
# In production the two roles are held by different people — funds and
# whitelist deliberately separated, so the key that must be reachable within
# minutes of a sanctions hit does not also carry fee, class-hash and
# factory-pause authority. During a rehearsal one person holds both, which is
# fine precisely because there is no third-party money at stake.
#
# WHY A SCRIPT AND NOT THE ADMIN UI: the app proposes this through the
# multisig, which is correct for production and unusable before a multisig
# exists. Keeping the privileged write out of the browser is the point; this
# is the deliberate, reviewable version of the same call.
#
# REVOCATION STOPS NEW EXPOSURE, IT DOES NOT SEIZE. A revoked lender can still
# withdraw everything they are owed — `test_revoked_lender_can_still_withdraw`
# locks that in. A compliance action that traps funds is not a compliance
# action.
#
# Usage:
#   STARKNET_RPC_URL=... ./scripts/authorize.sh --factory 0x... --lp 0x... --dry-run
#   STARKNET_RPC_URL=... ./scripts/authorize.sh --factory 0x... --lp 0x...
#   STARKNET_RPC_URL=... ./scripts/authorize.sh --factory 0x... --lp 0x... --revoke
#   STARKNET_RPC_URL=... ./scripts/authorize.sh --factory 0x... --check 0x...
#
# Requires: sncast at the version in .tool-versions, and a funded sncast
# account that currently holds the compliance role.

set -euo pipefail

FACTORY=""
LP=""
CHECK=""
REVOKE=0
DRY_RUN=0
ACCOUNT="${STARKNET_ACCOUNT:-roca-deployer}"

usage() {
  sed -n '2,47p' "$0" | sed 's/^# \{0,1\}//'
  exit "${1:-0}"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --factory)  FACTORY="$2"; shift 2 ;;
    --lp)       LP="$2"; shift 2 ;;
    --check)    CHECK="$2"; shift 2 ;;
    --revoke)   REVOKE=1; shift ;;
    --dry-run)  DRY_RUN=1; shift ;;
    --account)  ACCOUNT="$2"; shift 2 ;;
    -h|--help)  usage 0 ;;
    *) echo "unknown argument: $1" >&2; usage 1 ;;
  esac
done

die() { echo "error: $*" >&2; exit 1; }

command -v sncast >/dev/null || die "sncast not found. Install starknet-foundry 0.53.0."
[[ -n "${STARKNET_RPC_URL:-}" ]] || die "STARKNET_RPC_URL is not set."
[[ -n "$FACTORY" ]] || die "--factory is required (the PoolFactory address)."

is_felt() { [[ "$1" =~ ^0x[0-9a-fA-F]{1,64}$ ]]; }
is_felt "$FACTORY" || die "not a felt address: $FACTORY"

# ---- read-only check -------------------------------------------------------
# Worth having as its own mode. "Did the authorization land" is the question
# you actually have after running this, and the answer should not depend on
# the indexer having caught up.

if [[ -n "$CHECK" ]]; then
  is_felt "$CHECK" || die "not a felt address: $CHECK"
  echo "==> is_authorized($CHECK)"
  out="$(sncast call --url "$STARKNET_RPC_URL" \
          --contract-address "$FACTORY" \
          --function is_authorized \
          --calldata "$CHECK" 2>&1)" || { echo "$out" >&2; die "call failed"; }
  if grep -qE '0x1\b|\[0x1\]' <<<"$out"; then
    echo "    AUTHORIZED — this wallet can deposit"
  elif grep -qE '0x0\b|\[0x0\]' <<<"$out"; then
    echo "    NOT authorized — deposits from this wallet will revert"
  else
    echo "$out"
    die "could not parse is_authorized result"
  fi
  exit 0
fi

# ---- write -----------------------------------------------------------------

[[ -n "$LP" ]] || die "--lp is required (the investor wallet), or use --check."
is_felt "$LP" || die "not a felt address: $LP"

# The factory rejects the zero address. Failing here names the reason rather
# than surfacing it as an opaque revert after a signature.
#
# Done as a STRING test, not arithmetic: bash integers are 64-bit and a felt is
# not, so `$((16#...))` truncates a full-length address after 16 hex digits.
# That both prints a warning to stderr and, on a heavily zero-padded address,
# can truncate to 0 and reject a perfectly good wallet.
is_zero_felt() {
  local hex="${1#0x}"
  # sed, not `${hex##+(0)}` — that needs extglob, and without it the strip
  # silently does nothing and every zero address sails through.
  hex="$(printf '%s' "$hex" | sed 's/^0*//')"
  [[ -z "$hex" ]]
}
is_zero_felt "$LP" && die "--lp cannot be the zero address"

FLAG=1
VERB="authorize"
if [[ "$REVOKE" == "1" ]]; then
  FLAG=0
  VERB="REVOKE"
fi

cat <<EOF

  action    $VERB
  factory   $FACTORY
  lp        $LP
  account   $ACCOUNT  (must currently hold the compliance role)

EOF

if [[ "$REVOKE" == "1" ]]; then
  echo "  note: revocation stops NEW deposits only. This wallet keeps the"
  echo "        right to withdraw everything it is owed."
  echo
fi

if [[ "$DRY_RUN" == "1" ]]; then
  echo "dry run — nothing sent."
  echo "would: invoke set_lp_authorization($LP, $FLAG) on $FACTORY"
  exit 0
fi

echo "==> set_lp_authorization($LP, $FLAG)"
out="$(sncast --account "$ACCOUNT" invoke --url "$STARKNET_RPC_URL" \
        --contract-address "$FACTORY" \
        --function set_lp_authorization \
        --calldata "$LP" "$FLAG" 2>&1)" || {
  echo "$out" >&2
  # The most likely failure by far, and the least obvious from the raw revert.
  if grep -qi 'compliance' <<<"$out"; then
    die "this account does not hold the compliance role on that factory"
  fi
  die "invoke failed"
}
echo "$out"

# Confirm against the chain rather than trusting the invoke's own output. The
# transaction can land and still not do what you meant if the wrong factory or
# the wrong flag was passed.
echo
echo "==> verifying"
sleep 3
"$0" --factory "$FACTORY" --check "$LP" || {
  echo "    could not verify yet — the transaction may still be pending." >&2
  echo "    re-run: $0 --factory $FACTORY --check $LP" >&2
}
