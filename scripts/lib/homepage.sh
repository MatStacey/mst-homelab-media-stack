#!/usr/bin/env bash
# Homepage: a self-hosted dashboard with live widgets for every service in
# this stack. Generated once from this stack's own ports/API keys
# (services.yaml) - once that file exists, setup.sh leaves it alone, so feel
# free to edit it by hand afterward to rearrange things.

configure_homepage() {
  log "Configuring Homepage..."
  if docker exec homepage test -f /app/config/services.yaml; then
    log "Homepage: services.yaml already present, skipping (edit it by hand to customize)"
    return
  fi

  local payload_file
  payload_file="$(mktemp)"
  cat > "$payload_file" <<EOF
{
  "sonarr": {"port": $STACK_SERVICES_SONARR_PORT, "key": "$SONARR_KEY"},
  "radarr": {"port": $STACK_SERVICES_RADARR_PORT, "key": "$RADARR_KEY"},
  "prowlarr": {"port": $STACK_SERVICES_PROWLARR_PORT, "key": "$PROWLARR_KEY"},
  "bazarr": {"port": $STACK_SERVICES_BAZARR_PORT, "key": "$BAZARR_KEY"},
  "jellyfin": {"port": $STACK_SERVICES_JELLYFIN_PORT, "key": "$JELLYFIN_KEY"},
  "seerr": {"port": $STACK_SERVICES_SEERR_PORT, "key": "$SEERR_KEY"},
  "qbittorrent": {"port": $STACK_SERVICES_QBITTORRENT_PORT, "username": "$ADMIN_USERNAME", "password": "$ADMIN_PASSWORD"}
}
EOF

  local services_yaml
  services_yaml="$(mktemp)"
  $PY homepage-services-config < "$payload_file" > "$services_yaml"
  rm -f "$payload_file"

  _docker_cp_and_remove_local "$services_yaml" homepage /app/config/services.yaml
  docker restart homepage >/dev/null
  log "Homepage: generated services.yaml"
}
