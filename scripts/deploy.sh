#!/usr/bin/env bash
#
# Deploy PoolFactory (and the CreditPool class it clones) to Starknet.
#
# The mainnet factory at 0x070bd23697b102a152f6d9c322a795cd42466c43d106a420a2d8d3e046cc2673
# was deployed by hand and the steps existed only in someone's shell history,
# which meant the deployment could not be reproduced or reviewed. This is that
# process, written down.
#
# Order matters: PoolFactory's constructor takes the CreditPool CLASS HASH,
# because create_pool deploys pools from that class. So CreditPool must be
# declared first, and the factory is permanently bound to whatever class hash
# it was given — there is a set_pool_class_hash() to change it later, but the
# pools already deployed keep the old class.
#
# Usage:
#   STARKNET_RPC_URL=... ./scripts/deploy.sh --dry-run
#   STARKNET_RPC_URL=... ./scripts/deploy.sh \
#       --owner 0x... --platform-wallet 0x... --usdc 0x...
#
# Requires: scarb + sncast at the versions in .tool-versions, and an sncast
# account named in snfoundry.toml, funded on the target network.

set -euo pipefail

DRY_RUN=0
OWNER=""
PLATFORM_WALLET=""
USDC=""
ACCOUNT="${STARKNET_ACCOUNT:-roca-deployer}"

# Native USDC on Starknet mainnet (Circle). Same constant as the app's
# credit-pool.ts — if you are deploying to another network, pass --usdc.
USDC_MAINNET="0x033068f6539f8e6e6b131e6b2b814e6c34a5224bc66947c47dab9dfee93b35fb"

usage() {
  sed -n '2,25p' "$0" | sed 's/^# \{0,1\}//'
  exit "${1:-0}"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run)          DRY_RUN=1; shift ;;
    --owner)            OWNER="$2"; shift 2 ;;
    --platform-wallet)  PLATFORM_WALLET="$2"; shift 2 ;;
    --usdc)             USDC="$2"; shift 2 ;;
    --account)          ACCOUNT="$2"; shift 2 ;;
    -h|--help)          usage 0 ;;
    *) echo "unknown argument: $1" >&2; usage 1 ;;
  esac
done

die() { echo "error: $*" >&2; exit 1; }

# sncast 0.53 flag placement, which is not symmetric and is easy to get wrong:
#   --account is a GLOBAL option and goes BEFORE the subcommand
#   --url     is a SUBCOMMAND option and goes AFTER it
# i.e.  sncast --account NAME declare --url URL --contract-name X
# Putting --url first fails with "unexpected argument '--url' found", and the
# tip it prints ("'declare --url' exists") is the whole explanation.

# ---- preflight -------------------------------------------------------------

command -v scarb >/dev/null || die "scarb not found. Install the pins in .tool-versions (asdf install / mise install)."
command -v sncast >/dev/null || die "sncast not found. Install starknet-foundry 0.53.0."
[[ -n "${STARKNET_RPC_URL:-}" ]] || die "STARKNET_RPC_URL is not set."

USDC="${USDC:-$USDC_MAINNET}"
[[ -n "$OWNER" ]] || die "--owner is required (the address that can call set_fees / pause)."
[[ -n "$PLATFORM_WALLET" ]] || die "--platform-wallet is required (receives creation and repayment fees)."

for addr in "$OWNER" "$PLATFORM_WALLET" "$USDC"; do
  [[ "$addr" =~ ^0x[0-9a-fA-F]{1,64}$ ]] || die "not a felt address: $addr"
done

CHAIN_ID="$(sncast show-config --url "$STARKNET_RPC_URL" 2>/dev/null | grep -i chain || true)"

cat <<EOF

  network         ${CHAIN_ID:-（from STARKNET_RPC_URL）}
  account         $ACCOUNT
  owner           $OWNER
  platform_wallet $PLATFORM_WALLET
  usdc            $USDC

EOF

if [[ "$DRY_RUN" == "1" ]]; then
  echo "dry run — nothing declared or deployed."
  echo "would: scarb build → declare CreditPool → declare PoolFactory → deploy PoolFactory"
  exit 0
fi

# ---- build -----------------------------------------------------------------

echo "==> scarb build"
scarb build

# ---- declare ---------------------------------------------------------------
# Declaring an already-declared class is not an error worth stopping for: the
# class hash is deterministic, so a repeat run should reuse it rather than
# fail. Parse the hash out of either outcome.

declare_contract() {
  local name="$1" out tmp rc
  echo "==> declare $name" >&2
  echo "    (sncast recompiles in release profile first, then estimates and" >&2
  echo "     submits — expect a minute or two before the class hash appears)" >&2

  # Stream sncast's output AND capture it. It used to be captured only, so a
  # declare was indistinguishable from a hang for well over a minute:
  # recompile, then fee estimation, then waiting for acceptance, all silent.
  # During the first real deploy that silence was twice read as a failure.
  #
  # tee goes to stderr so the function's stdout stays clean — the caller
  # captures it to read the class hash out.
  # --wait is not optional here. Without it sncast returns as soon as the
  # transaction is accepted by the gateway, not when it is included, so the
  # NEXT declare reads a stale nonce and dies with "Invalid transaction
  # nonce" — which is what happened on the first successful run: CreditPool
  # declared fine, PoolFactory failed immediately after.
  tmp="$(mktemp)"
  set +e
  sncast --account "$ACCOUNT" --wait \
    declare --url "$STARKNET_RPC_URL" --contract-name "$name" 2>&1 | tee "$tmp" >&2
  # Read PIPESTATUS immediately: any command in between overwrites it.
  rc=${PIPESTATUS[0]}
  set -e
  out="$(cat "$tmp")"; rm -f "$tmp"

  # Decide on the OUTPUT, not the exit code. sncast exits 0 when a class is
  # already declared while printing "Error: ... already declared", so gating
  # this on rc != 0 skipped the branch entirely and fell through to parsing a
  # hash that was never in the text.
  local hash
  hash="$(sed -n 's/.*Class Hash: *\(0x[0-9a-fA-F]*\).*/\1/p' <<<"$out" | head -1)"

  if [[ -n "$hash" ]]; then
    # Fresh declare. Match the labelled line rather than the first hex string:
    # the output also carries a transaction hash and two explorer URLs.
    echo "$hash"
    return 0
  fi

  if grep -qi 'already declared' <<<"$out"; then
    # Re-declaring an existing class is success, not failure — that is what
    # makes a re-run safe. But sncast's message carries no class hash, so
    # compute it locally: hashes are deterministic from the compiled Sierra,
    # which is the same property that makes the re-declare free.
    echo "    already declared, computing class hash locally" >&2
    hash="$(sncast utils class-hash --contract-name "$name" 2>&1 \
            | sed -n 's/.*Class Hash: *\(0x[0-9a-fA-F]*\).*/\1/p' | head -1)"
    [[ -n "$hash" ]] || die "class already declared but its hash could not be computed locally"
    echo "$hash"
    return 0
  fi

  if grep -qi 'invalid transaction nonce' <<<"$out"; then
    die "declare $name failed on a stale nonce: the previous transaction had
       not been included yet. Re-run — already-declared classes are free, so
       retrying costs nothing."
  fi

  die "declare $name failed (see output above)"
}

CREDIT_POOL_CLASS="$(declare_contract CreditPool)"
[[ -n "$CREDIT_POOL_CLASS" ]] || die "could not parse CreditPool class hash"
echo "    CreditPool class: $CREDIT_POOL_CLASS"

FACTORY_CLASS="$(declare_contract PoolFactory)"
[[ -n "$FACTORY_CLASS" ]] || die "could not parse PoolFactory class hash"
echo "    PoolFactory class: $FACTORY_CLASS"

# Two different contracts cannot share a class hash. If they match, the parse
# above picked the wrong number out of sncast's output — and deploying on that
# would bind the factory to a class that is not CreditPool, so create_pool
# would deploy the wrong contract. Stop here rather than find out on chain.
[[ "$CREDIT_POOL_CLASS" != "$FACTORY_CLASS" ]] || \
  die "CreditPool and PoolFactory parsed to the same class hash ($FACTORY_CLASS) — parsing is wrong, refusing to deploy"

# ---- deploy ----------------------------------------------------------------
# Constructor order is fixed by pool_factory.cairo:105 —
#   (owner, platform_wallet, usdc_address, credit_pool_class_hash)
# Getting it wrong deploys a factory that pays fees to the USDC contract.

echo "==> deploy PoolFactory"
# Streamed for the same reason as the declares: this waits on acceptance too.
DEPLOY_TMP="$(mktemp)"
set +e
sncast --account "$ACCOUNT" --wait \
  deploy --url "$STARKNET_RPC_URL" --class-hash "$FACTORY_CLASS" \
  --constructor-calldata "$OWNER" "$PLATFORM_WALLET" "$USDC" "$CREDIT_POOL_CLASS" 2>&1 \
  | tee "$DEPLOY_TMP"
DEPLOY_RC=${PIPESTATUS[0]}
set -e
DEPLOY_OUT="$(cat "$DEPLOY_TMP")"; rm -f "$DEPLOY_TMP"
[[ "$DEPLOY_RC" == "0" ]] || die "deploy failed (see output above)"

FACTORY_ADDRESS="$(grep -oE 'contract_address: *0x[0-9a-fA-F]+' <<<"$DEPLOY_OUT" | grep -oE '0x[0-9a-fA-F]+' | head -1)"
[[ -n "$FACTORY_ADDRESS" ]] || { echo "$DEPLOY_OUT" >&2; die "could not parse deployed address"; }

# ---- verify ----------------------------------------------------------------
# Read the config back rather than trusting the deploy succeeded as intended.

echo "==> verify get_config()"
sncast call --url "$STARKNET_RPC_URL" \
  --contract-address "$FACTORY_ADDRESS" --function get_config || \
  echo "    (verification call failed — check manually before using this factory)"

cat <<EOF

  ✓ PoolFactory deployed

    address            $FACTORY_ADDRESS
    factory class      $FACTORY_CLASS
    credit pool class  $CREDIT_POOL_CLASS

  Update the app, then REBUILD — NEXT_PUBLIC_* is inlined at build time, so a
  redeploy of the existing build keeps the old address:

    vercel env rm  NEXT_PUBLIC_POOL_FACTORY_ADDRESS production
    printf '%s' "$FACTORY_ADDRESS" | vercel env add NEXT_PUBLIC_POOL_FACTORY_ADDRESS production

  Then refresh the committed ABIs, which are dumped from the deployed class:

    npx tsx scripts/dump-abi.ts    # in roca-beneficios

  Existing pools stay bound to the OLD factory. The app reads one
  NEXT_PUBLIC_POOL_FACTORY_ADDRESS, so pointing it here makes those pools
  invisible to pool discovery and to the indexer's reconcile sweep.

EOF
