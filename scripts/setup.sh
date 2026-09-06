#!/usr/bin/env bash
# First-run configuration for the media stack: brings the stack up, then wires
# together Sonarr/Radarr/Prowlarr/Bazarr/qBittorrent/Jellyfin/Seerr/Recyclarr/
# Homepage via their REST APIs (same steps you'd otherwise click through in
# each web UI).
#
# Safe to re-run: every step checks current state first and skips anything
# already configured.
#
# Layout:
#   scripts/config/stack.yaml   - ports, paths, indexer/category/profile defaults
#   scripts/lib/api.py          - JSON/YAML parsing helpers (no inline python here)
#   scripts/lib/common.sh       - logging, config loading, HTTP/file polling, docker-exec-curl
#   scripts/lib/<service>.sh    - one file per service, each exposing configure_<service>
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$SCRIPT_DIR/lib"
# shellcheck disable=SC2034  # consumed by lib/common.sh's load_stack_config
CONFIG_FILE="$SCRIPT_DIR/config/stack.yaml"
cd "$SCRIPT_DIR/.." || exit 1

command -v docker >/dev/null || { echo "xx  docker is required" >&2; exit 1; }
command -v python3 >/dev/null || { echo "xx  python3 is required (used to parse API responses and stack.yaml)" >&2; exit 1; }
python3 -c "import yaml" >/dev/null 2>&1 || { echo "xx  python3's PyYAML module is required: pip install -r scripts/requirements.txt" >&2; exit 1; }
docker compose version >/dev/null 2>&1 || { echo "xx  docker compose plugin is required" >&2; exit 1; }

[ -f .env ] || { echo "xx  No .env found. Run: cp .env.example .env, fill in TZ, then re-run this script." >&2; exit 1; }
set -a
# shellcheck disable=SC1091
source .env
set +a

# shellcheck source=lib/common.sh
source "$LIB_DIR/common.sh"
load_stack_config

# shellcheck source=lib/servarr.sh
source "$LIB_DIR/servarr.sh"
# shellcheck source=lib/sonarr.sh
source "$LIB_DIR/sonarr.sh"
# shellcheck source=lib/radarr.sh
source "$LIB_DIR/radarr.sh"
# shellcheck source=lib/prowlarr.sh
source "$LIB_DIR/prowlarr.sh"
# shellcheck source=lib/qbittorrent.sh
source "$LIB_DIR/qbittorrent.sh"
# shellcheck source=lib/bazarr.sh
source "$LIB_DIR/bazarr.sh"
# shellcheck source=lib/jellyfin.sh
source "$LIB_DIR/jellyfin.sh"
# shellcheck source=lib/seerr.sh
source "$LIB_DIR/seerr.sh"
# shellcheck source=lib/recyclarr.sh
source "$LIB_DIR/recyclarr.sh"
# shellcheck source=lib/homepage.sh
source "$LIB_DIR/homepage.sh"

# --- credentials: use .env if set, then ~/secrets/homelab.sh if present,
# otherwise prompt (never written back to .env or the secrets file) ---
if [ -f "$HOME/secrets/homelab.sh" ]; then
  # shellcheck disable=SC1091
  source "$HOME/secrets/homelab.sh"
fi
if [ -z "${ADMIN_USERNAME:-}" ]; then
  read -rp "Admin username to use for all service logins: " ADMIN_USERNAME
fi
if [ -z "${ADMIN_PASSWORD:-}" ]; then
  read -rsp "Admin password to use for all service logins: " ADMIN_PASSWORD
  echo
fi
[ -n "$ADMIN_USERNAME" ] && [ -n "$ADMIN_PASSWORD" ] || die "Username and password are both required."
# these get embedded into JSON payloads below; quotes/backslashes would corrupt them
case "$ADMIN_USERNAME$ADMIN_PASSWORD" in
  *'"'*|*'\'*) die 'Username/password must not contain " or \ characters (they get embedded in JSON API calls).' ;;
esac

# ---------------------------------------------------------------------------
ensure_owned_by_container_user config/seerr
ensure_owned_by_container_user config/recyclarr

log "Bringing up the stack..."
docker compose up -d

wait_for_file "Sonarr config"   "$STACK_SERVICES_SONARR_CONFIG_FILE"
wait_for_file "Radarr config"   "$STACK_SERVICES_RADARR_CONFIG_FILE"
wait_for_file "Prowlarr config" "$STACK_SERVICES_PROWLARR_CONFIG_FILE"
wait_for_file "Bazarr config"   "$STACK_SERVICES_BAZARR_CONFIG_FILE"
wait_for_container "Recyclarr" recyclarr
wait_for_container "Homepage" homepage

SONARR_KEY="$(servarr_apikey "$STACK_SERVICES_SONARR_CONFIG_FILE")"
RADARR_KEY="$(servarr_apikey "$STACK_SERVICES_RADARR_CONFIG_FILE")"
PROWLARR_KEY="$(servarr_apikey "$STACK_SERVICES_PROWLARR_CONFIG_FILE")"
BAZARR_KEY="$(grep -A3 '^auth:' "$STACK_SERVICES_BAZARR_CONFIG_FILE" | grep 'apikey:' | sed -E 's/.*apikey: *//')"
# Set for real inside configure_jellyfin/configure_seerr (their API keys don't
# exist until those steps run); initialized here so `set -u` doesn't choke on
# homepage.sh reading them if either step warns-and-skips instead.
# shellcheck disable=SC2034  # consumed by lib/homepage.sh's configure_homepage
JELLYFIN_KEY=""
# shellcheck disable=SC2034  # consumed by lib/homepage.sh's configure_homepage
SEERR_KEY=""

wait_for_http "Sonarr API"   sonarr   "http://localhost:$STACK_SERVICES_SONARR_PORT/api/$STACK_SERVICES_SONARR_API_VERSION/system/status?apikey=$SONARR_KEY"
wait_for_http "Radarr API"   radarr   "http://localhost:$STACK_SERVICES_RADARR_PORT/api/$STACK_SERVICES_RADARR_API_VERSION/system/status?apikey=$RADARR_KEY"
wait_for_http "Prowlarr API" prowlarr "http://localhost:$STACK_SERVICES_PROWLARR_PORT/api/$STACK_SERVICES_PROWLARR_API_VERSION/system/status?apikey=$PROWLARR_KEY"
wait_for_http "Bazarr API"   bazarr   "http://localhost:$STACK_SERVICES_BAZARR_PORT/api/system/status" 120 -H "X-API-KEY: $BAZARR_KEY"

configure_sonarr
configure_radarr
configure_prowlarr
configure_qbittorrent
configure_bazarr
configure_jellyfin
if [ -n "$JELLYFIN_KEY" ]; then
  configure_servarr_jellyfin_notification "Sonarr" sonarr "$STACK_SERVICES_SONARR_PORT" "$STACK_SERVICES_SONARR_API_VERSION" "$SONARR_KEY"
  configure_servarr_jellyfin_notification "Radarr" radarr "$STACK_SERVICES_RADARR_PORT" "$STACK_SERVICES_RADARR_API_VERSION" "$RADARR_KEY"
fi
configure_seerr
configure_recyclarr
configure_homepage

log "Done. Services (once your hosts file / DNS resolves *.media.lan to this machine):"
echo "  - https://homepage.media.lan (start here - a tile per service)"
for h in sonarr radarr prowlarr bazarr jellyfin seerr qbittorrent admin; do
  echo "  - https://$h.media.lan"
done
log "First visit will show a certificate warning until you install Caddy's local CA root - see README's TLS notes."
log "Login for Sonarr/Radarr/Prowlarr/Bazarr/qBittorrent/Jellyfin: $ADMIN_USERNAME / (the password you provided)"
