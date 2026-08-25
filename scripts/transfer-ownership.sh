#!/usr/bin/env bash
#
# Hand the PoolFactory to its permanent owner — normally the treasury multisig.
#
# READ THIS FIRST. The factory uses OpenZeppelin's one-step OwnableComponent,
# not OwnableTwoStep. There is no `accept_ownership`, no pending-owner state and
# no undo:
#
#     transfer_ownership(X)  →  X is the owner, immediately and forever.
#
# If X is a typo, an address with nothing deployed at it, or a wallet nobody
# controls, the factory is bricked in the only ways that matter: fees can never
# be changed, the pool class can never be updated, no pool can ever be unpaused
# or marked defaulted, and the compliance officer can never be rotated. Deployed
# pools keep working and lenders can always withdraw — the funds are not at
# risk — but the factory becomes permanently unadministrable.
#
# So this script does the checks a person cannot reliably do at a terminal at
# 11pm: it reads the current owner, refuses the zero address and a no-op
# transfer, and above all REFUSES AN ADDRESS WITH NO CONTRACT DEPLOYED AT IT.
# That last one is the guard that catches a mistyped felt, because a multisig
# is a deployed contract and a typo almost never is.
#
# Run this AFTER the rehearsal, not before. While you are still shaking out the
# deployment you want a single key that can fix things; the handover is the
# last step before real investor money, not the first.
#
# Never call `renounce_ownership`. It is in the ABI because it ships with the
# OZ mixin. It permanently removes the owner and there is no recovery.
#
# Usage:
#   STARKNET_RPC_URL=... ./scripts/transfer-ownership.sh --factory 0x... --new-owner 0x... --dry-run
#   STARKNET_RPC_URL=... ./scripts/transfer-ownership.sh --factory 0x... --new-owner 0x...
#   STARKNET_RPC_URL=... ./scripts/transfer-ownership.sh --factory 0x... --show
#
# Requires: sncast at the version in .tool-versions, and the sncast account
# that is the CURRENT owner.

set -euo pipefail

FACTORY=""
NEW_OWNER=""
SHOW=0
DRY_RUN=0
ALLOW_EOA=0
ACCOUNT="${STARKNET_ACCOUNT:-roca-deployer}"

usage() {
  sed -n '2,37p' "$0" | sed 's/^# \{0,1\}//'
  exit "${1:-0}"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --factory)    FACTORY="$2"; shift 2 ;;
    --new-owner)  NEW_OWNER="$2"; shift 2 ;;
    --show)       SHOW=1; shift ;;
    --dry-run)    DRY_RUN=1; shift ;;
    # Escape hatch for handing the factory to a plain account rather than a
    # contract wallet. Deliberately verbose: if you are typing this, say why.
    --i-know-it-is-not-a-contract) ALLOW_EOA=1; shift ;;
    --account)    ACCOUNT="$2"; shift 2 ;;
    -h|--help)    usage 0 ;;
    *) echo "unknown argument: $1" >&2; usage 1 ;;
  esac
done

die() { echo "error: $*" >&2; exit 1; }

command -v sncast >/dev/null || die "sncast not found. Install starknet-foundry 0.53.0."
[[ -n "${STARKNET_RPC_URL:-}" ]] || die "STARKNET_RPC_URL is not set."
[[ -n "$FACTORY" ]] || die "--factory is required."

is_felt() { [[ "$1" =~ ^0x[0-9a-fA-F]{1,64}$ ]]; }
is_felt "$FACTORY" || die "not a felt address: $FACTORY"

# String strip, not arithmetic: bash integers are 64-bit and a felt is not, so
# `$((16#...))` truncates and can call a padded address zero.
is_zero_felt() {
  local hex="${1#0x}"
  hex="$(printf '%s' "$hex" | sed 's/^0*//')"
  [[ -z "$hex" ]]
}

felt_eq() {
  # `tr`, not `${a,,}` — that is bash 4 and macOS ships bash 3.2, where it is a
  # syntax error rather than a wrong answer. This script has to run on the
  # machine doing the deploy.
  local a b
  a="$(printf '%s' "${1#0x}" | sed 's/^0*//' | tr 'A-F' 'a-f')"
  b="$(printf '%s' "${2#0x}" | sed 's/^0*//' | tr 'A-F' 'a-f')"
  [[ "$a" == "$b" ]]
}

# ---- current owner ---------------------------------------------------------

read_owner() {
  local out
  out="$(sncast --url "$STARKNET_RPC_URL" call \
          --contract-address "$FACTORY" \
          --function owner 2>&1)" || { echo "$out" >&2; die "could not read owner"; }
  grep -oE '0x[0-9a-fA-F]{1,64}' <<<"$out" | tail -1
}

# Local validation first. A malformed or zero address should be rejected
# instantly, not after a network round trip that may itself fail and mask it.
if [[ "$SHOW" != "1" ]]; then
  [[ -n "$NEW_OWNER" ]] || die "--new-owner is required, or use --show."
  is_felt "$NEW_OWNER" || die "not a felt address: $NEW_OWNER"
  is_zero_felt "$NEW_OWNER" && die "--new-owner cannot be the zero address (that is renounce, not transfer)"
fi

CURRENT="$(read_owner)"
[[ -n "$CURRENT" ]] || die "could not parse the current owner"

if [[ "$SHOW" == "1" ]]; then
  echo "factory        $FACTORY"
  echo "current owner  $CURRENT"
  exit 0
fi

if felt_eq "$CURRENT" "$NEW_OWNER"; then
  echo "already owned by $NEW_OWNER — nothing to do."
  exit 0
fi

# ---- the guard that matters ------------------------------------------------
# A mistyped felt is a valid-looking address with nothing at it. A multisig is
# a deployed contract. So "is there code here" separates the two cases better
# than any amount of squinting at hex.

echo "==> checking there is a contract at $NEW_OWNER"
CLASS_OUT="$(sncast --url "$STARKNET_RPC_URL" call \
              --contract-address "$NEW_OWNER" \
              --function get_version 2>&1 || true)"

HAS_CODE=1
if grep -qiE 'not deployed|does not exist|ContractNotFound|is not declared' <<<"$CLASS_OUT"; then
  HAS_CODE=0
fi

if [[ "$HAS_CODE" == "0" ]]; then
  if [[ "$ALLOW_EOA" == "1" ]]; then
    echo "    no contract found — proceeding anyway (--i-know-it-is-not-a-contract)"
  else
    echo >&2
    echo "  There is no contract deployed at:" >&2
    echo "    $NEW_OWNER" >&2
    echo >&2
    echo "  This is what a mistyped address looks like. Ownership is one-step" >&2
    echo "  and irreversible, so transferring here would permanently brick the" >&2
    echo "  factory's administration." >&2
    echo >&2
    echo "  If the target really is a plain account and not a contract wallet," >&2
    echo "  re-run with --i-know-it-is-not-a-contract." >&2
    exit 1
  fi
else
  echo "    contract found"
fi

# ---- confirm ---------------------------------------------------------------

cat <<EOF

  factory        $FACTORY
  current owner  $CURRENT
  NEW OWNER      $NEW_OWNER
  signing as     $ACCOUNT  (must be the current owner)

  This is ONE-STEP and IRREVERSIBLE. There is no accept_ownership.
  After this transaction, $ACCOUNT can no longer administer the factory.

EOF

if [[ "$DRY_RUN" == "1" ]]; then
  echo "dry run — nothing sent."
  echo "would: invoke transfer_ownership($NEW_OWNER) on $FACTORY"
  exit 0
fi

# Typing the address back is the only confirmation that catches the failure
# this script exists to prevent. y/N would not.
echo "Retype the NEW OWNER address to confirm:"
read -r TYPED
felt_eq "$TYPED" "$NEW_OWNER" || die "addresses do not match — nothing sent."

echo "==> transfer_ownership($NEW_OWNER)"
out="$(sncast --url "$STARKNET_RPC_URL" --account "$ACCOUNT" invoke \
        --contract-address "$FACTORY" \
        --function transfer_ownership \
        --calldata "$NEW_OWNER" 2>&1)" || {
  echo "$out" >&2
  if grep -qi 'not the owner' <<<"$out"; then
    die "$ACCOUNT is not the current owner ($CURRENT)"
  fi
  die "invoke failed"
}
echo "$out"

# Verify against the chain. The transaction landing is not the same as the
# owner having changed to the address you meant.
echo
echo "==> verifying"
sleep 3
AFTER="$(read_owner || true)"
if [[ -n "$AFTER" ]] && felt_eq "$AFTER" "$NEW_OWNER"; then
  echo "    owner is now $AFTER"
else
  echo "    owner still reads as ${AFTER:-unknown} — the tx may be pending." >&2
  echo "    re-check: $0 --factory $FACTORY --show" >&2
fi
