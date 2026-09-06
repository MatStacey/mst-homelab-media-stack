#!/usr/bin/env bash
# Sonarr: forms auth, TV root folder, qBittorrent download client.
# Requires servarr.sh to be sourced first (shared *arr functions) and
# SONARR_KEY to already be set by setup.sh from config/sonarr/config.xml.

configure_sonarr() {
  local port="$STACK_SERVICES_SONARR_PORT" api_version="$STACK_SERVICES_SONARR_API_VERSION"
  log "Configuring Sonarr..."
  configure_servarr_auth           "Sonarr" sonarr "$port" "$api_version" "$SONARR_KEY"
  configure_servarr_loglevel       "Sonarr" sonarr "$port" "$api_version" "$SONARR_KEY"
  configure_servarr_rootfolder     "Sonarr" sonarr "$port" "$api_version" "$SONARR_KEY" "$STACK_PATHS_TV"
  configure_servarr_downloadclient "Sonarr" sonarr "$port" "$api_version" "$SONARR_KEY" "tv-sonarr"
}
