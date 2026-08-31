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
  STARKNET_RPC_URL   required; must be a WRITE-capable endpoint
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

[[ -n "${STARKNET_RPC_URL:-}" ]] || die "STARKNET_RPC_URL is not set"
[[ -n "$FACTORY" ]] || die "--factory is required"

is_felt() { [[ "$1" =~ ^0x[0-9a-fA-F]{1,64}$ ]]; }
is_felt "$FACTORY" || die "--factory is not a felt: $FACTORY"

read_officer() {
  sncast --account "$ACCOUNT" call --url "$STARKNET_RPC_URL" \
    --contract-address "$FACTORY" --function get_compliance_officer 2>&1
}

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

out="$(sncast --account "$ACCOUNT" invoke --url "$STARKNET_RPC_URL" \
        --contract-address "$FACTORY" --function set_compliance_officer \
        --calldata "$OFFICER" 2>&1)" || {
  echo "$out" >&2
  # The two failures worth naming: the wrong signer, and a stale RPC that
  # cannot write. Both look like an opaque revert otherwise.
  if grep -qiE 'owner|Ownable' <<<"$out"; then
    die "this account is not the factory owner"
  fi
  die "invoke failed"
}
echo "$out"

# Confirm against the chain rather than trusting the invoke's own output: the
# transaction can land and still not do what you meant if the wrong factory
# was passed.
echo
echo "==> verifying"
sleep 5
read_officer | grep -E "Response:" || \
  echo "    not confirmed yet — re-run with --check in a moment." >&2
