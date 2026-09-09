#!/usr/bin/env bash
# One-time: copies today's secrets (.env + ~/secrets/homelab.sh) into the
# existing mst-vault instance, at secret/mst-homelab-media-stack/. Run once
# after enabling "vault" in COMPOSE_PROFILES and bringing mst-vault up
# (see ~/vcs/personal/mst-vault/README.md - it must already be initialized
# and unsealed). Safe to re-run, but don't re-run it after you've started
# rotating secrets directly in Vault - it will overwrite Vault's values
# with whatever's still in .env/the secrets file.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$SCRIPT_DIR/lib"
# shellcheck disable=SC2034  # consumed by lib/common.sh's load_stack_config
CONFIG_FILE="$SCRIPT_DIR/config/stack.yaml"
cd "$SCRIPT_DIR/.." || exit 1

# shellcheck source=lib/common.sh
source "$LIB_DIR/common.sh"
load_stack_config

[ -f .env ] || die "No .env found. Run: cp .env.example .env, fill in TZ, then re-run this script."
set -a
# shellcheck disable=SC1091
source .env
set +a
if [ -f "$HOME/secrets/homelab.sh" ]; then
  # shellcheck disable=SC1091
  source "$HOME/secrets/homelab.sh"
fi

MST_VAULT_DIR="$HOME/vcs/personal/mst-vault"
MST_VAULT_INIT_FILE="$MST_VAULT_DIR/secrets/vault-init.json"
[ -f "$MST_VAULT_INIT_FILE" ] || die "$MST_VAULT_INIT_FILE not found - run $MST_VAULT_DIR/scripts/init.sh first (see its README)."

ROOT_TOKEN="$($PY get-field root_token < "$MST_VAULT_INIT_FILE")"
KV="$STACK_VAULT_KV_MOUNT/$STACK_VAULT_KV_PATH"
kv_put() {
  docker exec -e VAULT_ADDR="http://127.0.0.1:$STACK_VAULT_PORT" -e VAULT_TOKEN="$ROOT_TOKEN" \
    "$STACK_VAULT_CONTAINER" vault kv put "$KV/$@"
}

if [ -n "${ADMIN_USERNAME:-}" ] && [ -n "${ADMIN_PASSWORD:-}" ]; then
  kv_put admin username="$ADMIN_USERNAME" password="$ADMIN_PASSWORD"
else
  warn "ADMIN_USERNAME/ADMIN_PASSWORD not set in .env or ~/secrets/homelab.sh - skipping $KV/admin"
fi

kv_put vpn \
  wireguard_private_key="${WIREGUARD_PRIVATE_KEY:-}" \
  wireguard_preshared_key="${WIREGUARD_PRESHARED_KEY:-}" \
  user="${VPN_USER:-}" \
  password="${VPN_PASSWORD:-}"

if [ -n "${TS_AUTHKEY:-}" ]; then
  kv_put tailscale authkey="$TS_AUTHKEY"
else
  warn "TS_AUTHKEY not set in ~/secrets/homelab.sh - skipping $KV/tailscale"
fi

log "Migrated secrets into Vault at $KV/{admin,vpn,tailscale}"
