#!/usr/bin/env bash
# Vault (optional, "vault" in COMPOSE_PROFILES): fetches the genuinely
# user-supplied secrets (admin login, VPN credentials, Tailscale auth key)
# from the existing, standalone mst-vault project instead of
# ~/secrets/homelab.sh. This stack is a *client* of that Vault instance,
# not its own deployment - mst-vault owns init/unseal/the KV engine itself
# (see ~/vcs/personal/mst-vault/README.md). See
# scripts/vault-migrate-secrets.sh for the one-time step that populates it.

MST_VAULT_DIR="$HOME/vcs/personal/mst-vault"
MST_VAULT_INIT_FILE="$MST_VAULT_DIR/secrets/vault-init.json"

_vault_cli() {
  local token="$1"; shift
  docker exec -e VAULT_ADDR="http://127.0.0.1:$STACK_VAULT_PORT" -e VAULT_TOKEN="$token" \
    "$STACK_VAULT_CONTAINER" vault "$@"
}

# Vault re-seals itself on every container restart. Rather than duplicating
# mst-vault's own unseal logic (3-of-5 Shamir keys, read from its init
# file), just run its own script - it's already idempotent (prints "Vault
# is already unsealed." and exits 0 if there's nothing to do).
_vault_unseal() {
  [ -f "$MST_VAULT_INIT_FILE" ] || die "Vault: $MST_VAULT_INIT_FILE not found - run $MST_VAULT_DIR/scripts/init.sh first (see its README)."
  "$MST_VAULT_DIR/scripts/unseal.sh"
}

configure_vault() {
  log "Configuring Vault..."
  wait_for_container "Vault" "$STACK_VAULT_CONTAINER" \
    || die "Vault: container '$STACK_VAULT_CONTAINER' isn't reachable - start it first: cd $MST_VAULT_DIR && docker compose up -d"
  _vault_unseal
}

# Reads secret/mst-homelab-media-stack/{admin,vpn,tailscale} from Vault and
# sets the same shell vars ~/secrets/homelab.sh would have set, so every
# downstream line in setup.sh/scripts/lib/*.sh needs zero changes.
# WIREGUARD_*/VPN_USER/VPN_PASSWORD/TS_AUTHKEY are exported (docker
# compose's own variable substitution reads the shell environment, same
# reason TS_AUTHKEY was already exported before this change) -
# ADMIN_USERNAME/PASSWORD stay bash-local, matching the existing convention
# exactly.
fetch_secrets_from_vault() {
  local root_token
  root_token="$($PY get-field root_token < "$MST_VAULT_INIT_FILE")"
  local kv="$STACK_VAULT_KV_MOUNT/$STACK_VAULT_KV_PATH"

  local admin_json vpn_json ts_json
  admin_json="$(_vault_cli "$root_token" kv get -format=json "$kv/admin" 2>/dev/null || true)"
  vpn_json="$(_vault_cli "$root_token" kv get -format=json "$kv/vpn" 2>/dev/null || true)"
  ts_json="$(_vault_cli "$root_token" kv get -format=json "$kv/tailscale" 2>/dev/null || true)"

  [ -n "$admin_json" ] && ADMIN_USERNAME="$(echo "$admin_json" | $PY get-field data.data.username)"
  [ -n "$admin_json" ] && ADMIN_PASSWORD="$(echo "$admin_json" | $PY get-field data.data.password)"
  if [ -n "$vpn_json" ]; then
    export WIREGUARD_PRIVATE_KEY="$(echo "$vpn_json" | $PY get-field data.data.wireguard_private_key)"
    export WIREGUARD_PRESHARED_KEY="$(echo "$vpn_json" | $PY get-field data.data.wireguard_preshared_key)"
    export VPN_USER="$(echo "$vpn_json" | $PY get-field data.data.user)"
    export VPN_PASSWORD="$(echo "$vpn_json" | $PY get-field data.data.password)"
  fi
  [ -n "$ts_json" ] && export TS_AUTHKEY="$(echo "$ts_json" | $PY get-field data.data.authkey)"
  log "Vault: fetched secrets from $kv/{admin,vpn,tailscale}"
}
