#!/usr/bin/env bash
# Radarr: forms auth, movies root folder, qBittorrent download client.
# Requires servarr.sh to be sourced first (shared *arr functions) and
# RADARR_KEY to already be set by setup.sh from config/radarr/config.xml.

configure_radarr() {
  local port="$STACK_SERVICES_RADARR_PORT" api_version="$STACK_SERVICES_RADARR_API_VERSION"
  log "Configuring Radarr..."
  configure_servarr_auth           "Radarr" radarr "$port" "$api_version" "$RADARR_KEY"
  configure_servarr_loglevel       "Radarr" radarr "$port" "$api_version" "$RADARR_KEY"
  configure_servarr_rootfolder     "Radarr" radarr "$port" "$api_version" "$RADARR_KEY" "$STACK_PATHS_MOVIES"
  configure_servarr_downloadclient "Radarr" radarr "$port" "$api_version" "$RADARR_KEY" "movies-radarr"
}
