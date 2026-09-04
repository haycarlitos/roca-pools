#!/usr/bin/env bash
# Rotate the factory's compliance officer — the key that decides who may
# deposit.
#
# Owner-gated. The factory seeds the owner as officer at deployment, so on a
# fresh deploy this is the step that hands the role to whichever wallet the
# product actually signs with. Without it the admin console can read the role
# but never exercise it: `set_lp_authorization` reverts for everyone else, so
# an investor approved in the database can never be authorized on chain.
#
# Deliberately NOT a deploy step. The officer is a live operational key and
# rotating it is a decision, not a default — it belongs in a run with someone
# watching, which is also why the target is echoed and confirmed before send.
set -euo pipefail

# shellcheck source=scripts/lib/starknet.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/starknet.sh"

die() { echo "error: $*" >&2; exit 1; }

FACTORY=""; OFFICER=""; ACCOUNT="${SNCAST_ACCOUNT:-roca-deployer}"; DRY_RUN=0; CHECK=0

usage() {
  cat <<'USAGE'
usage:
  set-compliance-officer.sh --factory 0x… --officer 0x…   assign the role
  set-compliance-officer.sh --factory 0x… --check         read who holds it

options:
  --account NAME   sncast account (default: roca-deployer, or $SNCAST_ACCOUNT)
  --dry-run        print the call without sending it

env:
  STARKNET_RPC_URL   optional; must be WRITE-capable. Unset it to use
                     sncast's mainnet default, which accepts writes.
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --factory) FACTORY="${2:-}"; shift 2 ;;
    --officer) OFFICER="${2:-}"; shift 2 ;;
    --account) ACCOUNT="${2:-}"; shift 2 ;;
    --check)   CHECK=1; shift ;;
    --dry-run) DRY_RUN=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
done

[[ -n "$FACTORY" ]] || die "--factory is required"

is_felt() { [[ "$1" =~ ^0x[0-9a-fA-F]{1,64}$ ]]; }
is_felt "$FACTORY" || die "--factory is not a felt: $FACTORY"

sn_set_target

read_officer() {
  sncast --account "$ACCOUNT" call "${TARGET[@]}" \
    --contract-address "$FACTORY" --function get_compliance_officer 2>&1
}

# The felt as a bare lowercase hex string, for comparison. Padding differs
# between what the caller types and what the node renders, so the addresses
# are normalised rather than string-matched.
officer_felt() {
  local out
  out="$(read_officer)" || return 1
  sed -n 's/.*ContractAddress(\(0x[0-9a-fA-F]*\)).*/\1/p' <<<"$out" | head -1
}

norm() { python3 -c "import sys; print(hex(int(sys.argv[1],16)))" "$1" 2>/dev/null; }

if [[ "$CHECK" == "1" ]]; then
  echo "==> get_compliance_officer($FACTORY)"
  read_officer | grep -E "Response:" || die "read failed"
  exit 0
fi

[[ -n "$OFFICER" ]] || die "--officer is required (or pass --check)"
is_felt "$OFFICER" || die "--officer is not a felt: $OFFICER"
# The contract rejects zero, but failing here costs no fee and says why.
# Matched as text rather than arithmetic: $((16#...)) overflows on a full
# 64-hex-digit felt, so the numeric form would error on valid input.
if [[ "$OFFICER" =~ ^0x0*$ ]]; then
  die "--officer is zero; the factory rejects that"
fi

echo "==> current officer"
read_officer | grep -E "Response:" || echo "    (could not read)"
echo
echo "==> new officer: $OFFICER"
echo "    signing with account: $ACCOUNT (must be the factory OWNER)"

if [[ "$DRY_RUN" == "1" ]]; then
  echo "dry run — nothing sent."
  echo "would: invoke set_compliance_officer($OFFICER) on $FACTORY"
  exit 0
fi

# Before spending a signature: an endpoint that serves views happily and
# refuses writes fails AFTER this point and reads as a transaction error.
require_write_rpc

if ! sn_invoke --account "$ACCOUNT" invoke "${TARGET[@]}" \
       --contract-address "$FACTORY" --function set_compliance_officer \
       --calldata "$OFFICER"; then
  # The failure worth naming: the wrong signer, which surfaces as an opaque
  # revert otherwise.
  die "invoke failed (if it mentions Ownable, this account is not the owner)"
fi

# Confirm against the chain rather than trusting the invoke's own output. The
# transaction can land and still not do what you meant if the wrong factory was
# passed — and sncast can report success for a write that never happened, which
# is exactly what this comparison catches.
echo
echo "==> verifying"
sleep 5
got="$(officer_felt || true)"
if [[ -z "$got" ]]; then
  die "could not read the officer back; re-run with --check in a moment"
fi
if [[ "$(norm "$got")" != "$(norm "$OFFICER")" ]]; then
  echo "    on chain: $got" >&2
  echo "    expected: $OFFICER" >&2
  die "the officer did NOT change — the transaction did not take effect"
fi
echo "    confirmed: $got"
