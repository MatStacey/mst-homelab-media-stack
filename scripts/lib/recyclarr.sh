#!/usr/bin/env bash
# Recyclarr: keeps Sonarr/Radarr quality profiles and custom formats in sync
# with the community-maintained TRaSH Guides. Recyclarr re-syncs on its own
# built-in cron schedule (CRON_SCHEDULE in docker-compose.yml's recyclarr
# service) - setup.sh only needs to get its config file in place once and
# trigger an initial sync.

# Generate the config file for one TRaSH Guides template (via `recyclarr
# config create`) if it isn't already present, then patch in the real
# base_url/api key - config-template YAML has extensive explanatory
# comments, so a plain line substitution is used (see
# cmd_recyclarr_patch_config in api.py) rather than a full YAML parse+dump,
# which would silently discard them.
_configure_recyclarr_instance() {
  local template="$1" base_url="$2" key="$3"
  local config_file="/config/configs/$template.yml"
  if docker exec recyclarr test -f "$config_file"; then
    log "Recyclarr: $template config already present, skipping"
  else
    docker exec recyclarr recyclarr config create --template "$template" >/dev/null
    log "Recyclarr: created $template config"
  fi

  local local_copy
  local_copy="$(mktemp)"
  docker cp "recyclarr:$config_file" "$local_copy" >/dev/null
  $PY recyclarr-patch-config "$local_copy" "$base_url" "$key"
  docker cp "$local_copy" "recyclarr:$config_file" >/dev/null
  rm -f "$local_copy"
}

configure_recyclarr() {
  log "Configuring Recyclarr..."
  _configure_recyclarr_instance "$STACK_RECYCLARR_SONARR_TEMPLATE" "http://sonarr:$STACK_SERVICES_SONARR_PORT" "$SONARR_KEY"
  _configure_recyclarr_instance "$STACK_RECYCLARR_RADARR_TEMPLATE" "http://radarr:$STACK_SERVICES_RADARR_PORT" "$RADARR_KEY"
  if docker exec recyclarr recyclarr sync >/dev/null 2>&1; then
    log "Recyclarr: synced quality profiles/custom formats"
  else
    warn "Recyclarr: initial sync failed - check 'docker logs recyclarr'"
  fi
}
