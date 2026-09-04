# Shared plumbing for the privileged mainnet scripts.
#
# Extracted because both `authorize.sh` and `set-compliance-officer.sh` sign
# owner/compliance-gated writes, and the two traps below are the ones that made
# a FAILED transaction look like a successful one. Duplicating that logic is how
# the second script ends up missing the fix the first one got.
#
# Source it, then use `require_write_rpc` before signing and `sn_invoke` in
# place of a bare `sncast invoke`.

# ---- target ----------------------------------------------------------------
#
# sncast takes either an explicit --url or a --network alias. The alias is the
# escape hatch worth keeping: the read-only endpoints that break these scripts
# are always custom URLs, and `--network mainnet` uses sncast's own default,
# which accepts writes.
# Sets TARGET, deliberately as a global array rather than something captured
# from stdout: `mapfile` is bash 4 and macOS ships 3.2, and word-splitting a
# string would break the moment a URL contained a shell metacharacter.
sn_set_target() {
  if [[ -n "${STARKNET_RPC_URL:-}" ]]; then
    TARGET=(--url "$STARKNET_RPC_URL")
  else
    TARGET=(--network mainnet)
  fi
}

# ---- write capability ------------------------------------------------------
#
# Reachable is not the same as usable. A read-only endpoint answers every view
# call perfectly and then refuses starknet_addInvokeTransaction, so the failure
# lands AFTER the confirmation prompt and reads as a transaction error rather
# than a configuration one. Starkscan's gateway does exactly this: reads and
# simulations in its pilot scope, `method_not_supported_in_pilot` on writes.
#
# Deliberately invalid params: a live method answers with a validation error
# (-32602), a missing one answers -32601. Nothing can be created either way, so
# this is safe to run against mainnet.
require_write_rpc() {
  [[ -n "${STARKNET_RPC_URL:-}" ]] || return 0   # --network mainnet accepts writes

  local code
  code=$(curl -s --max-time 20 "$STARKNET_RPC_URL" \
           -H 'content-type: application/json' \
           -d '{"jsonrpc":"2.0","id":1,"method":"starknet_addInvokeTransaction","params":[{}]}' \
         | sed -n 's/.*"code":\(-[0-9]*\).*/\1/p' | head -1)

  case "$code" in
    -32601)
      echo "error: this RPC is READ-ONLY (starknet_addInvokeTransaction not supported)" >&2
      echo "       Views work, writes do not, so the signature would be wasted." >&2
      echo "       Unset STARKNET_RPC_URL to use sncast's mainnet default, which" >&2
      echo "       accepts writes." >&2
      exit 1
      ;;
    "") echo "warning: could not determine whether the RPC accepts writes" >&2 ;;
  esac
}

# ---- invoke ----------------------------------------------------------------
#
# `sncast invoke` EXITS 0 ON FAILURE for RPC-level errors. A plain
# `sncast ... || die` therefore never fires: the error text is printed by the
# success path, the script continues, and the run reads as if the transaction
# landed. This was observed against a read-only gateway, where the whole
# invocation failed and the script went on to "verifying".
#
# So the output is inspected as well as the exit code. Prints the output and
# returns non-zero when either says it failed.
sn_invoke() {
  local out rc
  out="$(sncast "$@" 2>&1)"; rc=$?
  printf '%s\n' "$out"

  if [[ $rc -ne 0 ]]; then return "$rc"; fi
  # sncast prints `Error:` / `error:` on the failures it exits 0 for. Matched at
  # line start so a transaction hash containing the letters cannot trip it.
  if grep -qE '^[[:space:]]*(Error|error):' <<<"$out"; then return 1; fi
  return 0
}
