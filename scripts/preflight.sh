#!/usr/bin/env bash
#
# Preflight for scripts/deploy.sh, and post-deploy verification.
#
# deploy.sh is correct but assumes a working bench: pinned toolchain, an sncast
# account, and gas. When any of those is missing it fails partway, and a
# half-finished declare is confusing to unwind. This checks first.
#
# The important thing this encodes: the DECLARING ACCOUNT NEEDS NO PRIVILEGES.
# Class hashes are global and `owner` is constructor calldata, so any funded
# wallet can declare and deploy a factory owned by someone else entirely. The
# original roca-deployer key is not required for a redeploy.
#
# Chipi's paymaster cannot help here. Outside execution wraps `Call[]`, which
# is invoke only; `declare` is its own transaction type the account signs and
# pays for. Sponsorship applies to create_pool and every LP action after this
# bootstrap, not to the bootstrap itself.
#
# Usage:
#   STARKNET_RPC_URL=... ./scripts/preflight.sh --owner 0x<treasury>
#   STARKNET_RPC_URL=... ./scripts/preflight.sh --verify 0x<factory>

set -euo pipefail

OWNER=""; ACCOUNT="${STARKNET_ACCOUNT:-roca-deployer}"; VERIFY=""
STRK="0x04718f5a0fc34cc1af16a1cdee98ffb20c31f5cd61d6ab07201858f4287c938d"
ETH="0x049d36570d4e46f48e99674bd3fcc84644ddd6b96f7c741b1562b82f9e004dc7"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --owner)   OWNER="$2"; shift 2 ;;
    --account) ACCOUNT="$2"; shift 2 ;;
    --verify)  VERIFY="$2"; shift 2 ;;
    *) echo "unknown flag: $1" >&2; exit 2 ;;
  esac
done

ok=0; bad=0
pass() { printf '  \033[32mok\033[0m   %s\n' "$1"; ok=$((ok+1)); }
fail() { printf '  \033[31mFAIL\033[0m %s\n' "$1"; bad=$((bad+1)); }
note() { printf '  \033[36mnote\033[0m %s\n' "$1"; }
warn() { printf '  \033[33mwarn\033[0m %s\n' "$1"; }

rpc_call() { # $1=contract $2=selector $3..=calldata
  local c="$1" s="$2"; shift 2
  local cd=""; for a in "$@"; do cd="$cd\"$a\","; done; cd="${cd%,}"
  curl -s "$STARKNET_RPC_URL" -H 'content-type: application/json' -d \
    "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"starknet_call\",\"params\":[{\"contract_address\":\"$c\",\"entry_point_selector\":\"$s\",\"calldata\":[$cd]},\"latest\"]}"
}

# ---------------------------------------------------------------- verify mode
if [[ -n "$VERIFY" ]]; then
  echo "verifying factory $VERIFY"
  echo "  read it with sncast:"
  echo "    sncast call --url \$STARKNET_RPC_URL \\"
  echo "      --contract-address $VERIFY --function get_config"
  echo
  echo "  assert, in order:"
  echo "    owner              == your treasury address (NOT an LP wallet)"
  echo "    creation_fee_bps   == 0"
  echo "    repayment_fee_bps  == 0"
  echo "    credit_pool_class_hash == the CreditPool class you just declared"
  echo "    usdc_address       == 0x033068f6539f8e6e6b131e6b2b814e6c34a5224bc66947c47dab9dfee93b35fb"
  echo
  echo "  repayment_fee_bps is snapshotted into each pool at create_pool, so a"
  echo "  non-zero value here is permanent for every pool created afterwards."
  exit 0
fi

# -------------------------------------------------------------- preflight mode
echo "== toolchain =="
while read -r tool want; do
  [[ "$tool" =~ ^#|^$ ]] && continue
  # Map the .tool-versions name to the binary it actually installs. Splitting
  # the name on a dash looked clever and asked for `starknet`, which is not a
  # command, so a correctly installed toolchain reported as missing.
  case "$tool" in
    scarb)            probe=scarb  ;;
    starknet-foundry) probe=sncast ;;
    *)                probe="$tool";;
  esac
  if ! command -v "$probe" >/dev/null 2>&1; then
    fail "$tool not installed (need $want; looked for '$probe') -> mise install"
    continue
  fi
  case "$tool" in
    scarb) have="$(scarb --version 2>/dev/null | head -1 | awk '{print $2}')" ;;
    starknet-foundry) have="$(sncast --version 2>/dev/null | head -1 | awk '{print $2}')" ;;
    *) have="" ;;
  esac
  if [[ "$have" == "$want" ]]; then pass "$tool $have"
  else warn "$tool is $have, pinned to $want (a different compiler = a different class hash)"; fi
done < .tool-versions

echo "== rpc =="
if [[ -z "${STARKNET_RPC_URL:-}" ]]; then fail "STARKNET_RPC_URL not set"
else
  cid=$(curl -s "$STARKNET_RPC_URL" -H 'content-type: application/json' \
        -d '{"jsonrpc":"2.0","id":1,"method":"starknet_chainId","params":[]}' \
        | sed -n 's/.*"result":"\([^"]*\)".*/\1/p')
  # 0x534e5f4d41494e == "SN_MAIN"
  if [[ "$cid" == "0x534e5f4d41494e" ]]; then pass "reachable, chain SN_MAIN"
  else fail "chain id $cid is not SN_MAIN (this project is mainnet only)"; fi

  # Reachable is not the same as usable. Read-only endpoints answer chainId
  # perfectly well and then refuse starknet_addDeclareTransaction, which is
  # the first thing a deploy needs — so this check used to pass on a node
  # that could never deploy, and the failure surfaced after `scarb build`
  # with a raw JSON-RPC error.
  #
  # Deliberately invalid params: a live method answers with a validation
  # error (-32602), a missing one answers -32601. Nothing can be created
  # either way, so this is safe to run against mainnet.
  wr=$(curl -s "$STARKNET_RPC_URL" -H 'content-type: application/json' \
       -d '{"jsonrpc":"2.0","id":1,"method":"starknet_addDeclareTransaction","params":[{}]}' \
       | sed -n 's/.*"code":\(-[0-9]*\).*/\1/p' | head -1)
  case "$wr" in
    -32601)
      fail "this RPC is READ-ONLY (starknet_addDeclareTransaction not supported)"
      echo "       reads work, declares do not. Use a write-capable endpoint;"
      echo "       sncast's own default works: --network mainnet"
      ;;
    "") warn "could not determine whether the RPC accepts writes" ;;
    *)  pass "RPC accepts writes" ;;
  esac
fi

echo "== deployer account '$ACCOUNT' =="
if ! command -v sncast >/dev/null 2>&1; then
  warn "sncast missing, cannot resolve the account address"
else
  ADDR="$( { sncast account list 2>/dev/null || true; } | grep -A5 "^- $ACCOUNT" | sed -n 's/.*address: *\(0x[0-9a-fA-F]*\).*/\1/p' | head -1 || true)"
  if [[ -z "$ADDR" ]]; then
    fail "no sncast account named '$ACCOUNT'"
    echo "       any funded wallet works. The declarer gets NO privileges:"
    echo "       sncast account import --name $ACCOUNT --network mainnet --address 0x... --private-key 0x... --type oz"
  else
    pass "account resolves to $ADDR"
    # STRK is the fee token. Starknet v3 transactions pay in STRK and sncast
    # 0.53 sends v3, so STRK is what a declare actually spends.
    #
    # ETH is the LEGACY fee token and is reported for information only. This
    # used to hard-fail on both, which blocked a deploy from a wallet holding
    # 30 STRK and no ETH — a wallet that could have declared and deployed
    # without trouble. A preflight that refuses a working configuration is
    # worse than no preflight, because the fix it demands is to move funds
    # that were never going to be spent.
    for pair in "STRK $STRK required" "ETH $ETH legacy"; do
      set -- $pair
      raw=$(rpc_call "$2" "0x2e4263afad30923c891518314c3c95dbe830a16874e8abc5777a9a20b54c76e" "$ADDR" \
            | sed -n 's/.*"result":\["\([^"]*\)".*/\1/p')
      if [[ -n "$raw" ]]; then
        human=$(python3 -c "print(int('$raw',16)/1e18)")
        if [[ "$3" == "legacy" ]]; then
          note "$1 balance $human (legacy fee token, not required for v3)"
        elif python3 -c "exit(0 if int('$raw',16) > 2*10**17 else 1)"; then
          pass "$1 balance $human"
        else
          fail "$1 balance $human is thin, fund before declaring"
        fi
      else warn "$1 balance unreadable"; fi
    done
  fi
fi

echo "== target =="
if [[ -z "$OWNER" ]]; then
  fail "--owner not given. This becomes the factory owner: the only address"
  echo "       that can call set_fees, set_pool_class_hash and pause. Use the"
  echo "       multisig treasury, never an LP wallet."
else
  pass "owner $OWNER"
  # 0x4094... is LP#1 and the emisora wallet. Never the owner.
  owner_lc="$(printf '%s' "$OWNER" | tr '[:upper:]' '[:lower:]')"
  if [[ "$owner_lc" == *"4094e2c3779f8f50a1014238d63f0b5aff5c4aa3c4de3cc80fe4bb9e5c18f6f"* ]]; then
    fail "that is LP#1's wallet. borrow() pays the founder; an investor wallet must not hold factory ownership."
  fi
fi

echo
printf 'checks passed: %d   failed: %d\n' "$ok" "$bad"
if [[ "$bad" -eq 0 && -n "$OWNER" ]]; then
  cat <<CMD

ready. dry run first:

  STARKNET_RPC_URL="\$STARKNET_RPC_URL" ./scripts/deploy.sh --dry-run \\
    --owner $OWNER --platform-wallet $OWNER --account $ACCOUNT

then for real, and verify the readback:

  STARKNET_RPC_URL="\$STARKNET_RPC_URL" ./scripts/deploy.sh \\
    --owner $OWNER --platform-wallet $OWNER --account $ACCOUNT
  ./scripts/preflight.sh --verify 0x<new factory>

then update NEXT_PUBLIC_POOL_FACTORY_ADDRESS in Vercel and push a commit:
env vars bind at build time, so a redeploy without a new build keeps the old one.
CMD
else
  echo "fix the failures above first."
  exit 1
fi
