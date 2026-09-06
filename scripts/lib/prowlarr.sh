#!/usr/bin/env bash
# Prowlarr: forms auth, indexer setup, and app sync to Sonarr/Radarr.
# Requires servarr.sh (shared *arr auth function) and PROWLARR_KEY/SONARR_KEY/
# RADARR_KEY to already be set by setup.sh.

# Build and POST one indexer payload, optionally tagged so Prowlarr routes it
# through the Byparr proxy. Exit code distinguishes "not a known indexer name"
# (1, not worth retrying) from "add failed" (2, e.g. unreachable/challenged -
# worth a Byparr retry).
_post_prowlarr_indexer() {
  local name="$1" schema_json="$2" app_profile_id="$3" tag_id="${4:-}"
  local tag_args=()
  [ -n "$tag_id" ] && tag_args=(--tag-id "$tag_id")

  local payload_file
  payload_file="$(mktemp)"
  if ! $PY prowlarr-indexer-payload "$schema_json" "$name" "$app_profile_id" "${tag_args[@]}" > "$payload_file"; then
    rm -f "$payload_file"
    return 1
  fi

  _docker_cp_and_remove_local "$payload_file" prowlarr /tmp/idx.json
  local add_response
  add_response="$(cin prowlarr -X POST -H "X-Api-Key: $PROWLARR_KEY" -H "Content-Type: application/json" \
    "http://localhost:$STACK_SERVICES_PROWLARR_PORT/api/v1/indexer" --data @/tmp/idx.json)"
  [ "$(echo "$add_response" | $PY indexer-add-succeeded)" = "yes" ] || return 2
}

# Add one Prowlarr indexer by NAME if it isn't already configured. Looks NAME
# up against Prowlarr's own indexer schema (so only real, known indexer names
# work). If the plain add fails and FLARESOLVERR_TAG_ID is set, retries once
# through the Byparr proxy before reporting - rather than failing the whole
# script - that the tracker site couldn't be reached.
_add_prowlarr_indexer() {
  local name="$1" schema_json="$2" existing_json="$3" app_profile_id="$4" flaresolverr_tag_id="${5:-}"
  local already_exists
  already_exists="$($PY prowlarr-indexer-exists "$existing_json" "$name")"
  if [ "$already_exists" = "yes" ]; then
    log "Prowlarr: indexer '$name' already added, skipping"
    return
  fi

  _post_prowlarr_indexer "$name" "$schema_json" "$app_profile_id"
  local status=$?
  if [ "$status" -eq 0 ]; then
    log "Prowlarr: added indexer '$name'"
    return
  fi
  if [ "$status" -eq 1 ]; then
    warn "Prowlarr: '$name' is not a known indexer name, skipping"
    return
  fi

  if [ -n "$flaresolverr_tag_id" ] && _post_prowlarr_indexer "$name" "$schema_json" "$app_profile_id" "$flaresolverr_tag_id"; then
    log "Prowlarr: added indexer '$name' via Byparr"
    return
  fi
  warn "Prowlarr: could not connect to '$name' (site may be unreachable from this network) - skipped"
}

# Find-or-create the Prowlarr tag that links indexers to the Byparr proxy, and
# the Byparr FlareSolverr-type proxy itself tagged with it. Echoes the tag id
# so _add_prowlarr_indexer can retry failed indexers through it.
_configure_byparr_proxy() {
  local tag_label="$STACK_PROWLARR_FLARESOLVERR_TAG"
  local tag_id
  tag_id="$(cin prowlarr -H "X-Api-Key: $PROWLARR_KEY" "http://localhost:$STACK_SERVICES_PROWLARR_PORT/api/v1/tag" | $PY find-tag-id "$tag_label")"
  if [ -z "$tag_id" ]; then
    tag_id="$(cin prowlarr -X POST -H "X-Api-Key: $PROWLARR_KEY" -H "Content-Type: application/json" \
      "http://localhost:$STACK_SERVICES_PROWLARR_PORT/api/v1/tag" -d "{\"label\":\"$tag_label\"}" | $PY get-field id)"
    log "Prowlarr: created '$tag_label' tag"
  fi

  local already_exists
  already_exists="$(cin prowlarr -H "X-Api-Key: $PROWLARR_KEY" "http://localhost:$STACK_SERVICES_PROWLARR_PORT/api/v1/indexerproxy" | $PY has-indexerproxy "Byparr")"
  if [ "$already_exists" != "yes" ]; then
    cin prowlarr -X POST -H "X-Api-Key: $PROWLARR_KEY" -H "Content-Type: application/json" \
      "http://localhost:$STACK_SERVICES_PROWLARR_PORT/api/v1/indexerproxy" -d "{
        \"name\": \"Byparr\", \"implementation\": \"FlareSolverr\", \"configContract\": \"FlareSolverrSettings\",
        \"tags\": [$tag_id],
        \"fields\": [
          {\"name\":\"host\",\"value\":\"http://byparr:$STACK_SERVICES_BYPARR_PORT/\"},
          {\"name\":\"requestTimeout\",\"value\":$STACK_PROWLARR_FLARESOLVERR_REQUEST_TIMEOUT}
        ]}" >/dev/null
    log "Prowlarr: added Byparr FlareSolverr proxy"
  fi

  echo "$tag_id"
}

_configure_prowlarr_indexers() {
  # .env value wins; unset falls back to the curated default in stack.yaml;
  # explicitly empty means "none" (see .env.example for this three-way rule).
  local indexers="${PROWLARR_INDEXERS-$STACK_PROWLARR_DEFAULT_INDEXERS}"
  if [ -z "$indexers" ]; then
    log "Prowlarr: PROWLARR_INDEXERS is empty, skipping indexer setup"
    return
  fi

  local flaresolverr_tag_id
  flaresolverr_tag_id="$(_configure_byparr_proxy)"

  local app_profile_id schema_json existing_json
  app_profile_id="$(cin prowlarr -H "X-Api-Key: $PROWLARR_KEY" "http://localhost:$STACK_SERVICES_PROWLARR_PORT/api/v1/appprofile" | $PY get-field 0.id)"
  schema_json="$(mktemp)"
  cin prowlarr -H "X-Api-Key: $PROWLARR_KEY" "http://localhost:$STACK_SERVICES_PROWLARR_PORT/api/v1/indexer/schema" > "$schema_json"
  existing_json="$(mktemp)"
  cin prowlarr -H "X-Api-Key: $PROWLARR_KEY" "http://localhost:$STACK_SERVICES_PROWLARR_PORT/api/v1/indexer" > "$existing_json"

  local raw_name name
  IFS=',' read -ra indexer_list <<< "$indexers"
  for raw_name in "${indexer_list[@]}"; do
    read -r name <<< "$raw_name"
    [ -z "$name" ] && continue
    _add_prowlarr_indexer "$name" "$schema_json" "$existing_json" "$app_profile_id" "$flaresolverr_tag_id"
  done

  _docker_rm_in_container prowlarr /tmp/idx.json
  rm -f "$schema_json" "$existing_json"
}

# Register one *arr app (Sonarr/Radarr) with Prowlarr so indexers sync to it.
# CATEGORIES is a JSON array literal, e.g. "[5000,5030]".
_configure_prowlarr_app() {
  local app_name="$1" implementation="$2" config_contract="$3" base_url="$4" key="$5" categories="$6"
  local already_exists
  already_exists="$(cin prowlarr -H "X-Api-Key: $PROWLARR_KEY" "http://localhost:$STACK_SERVICES_PROWLARR_PORT/api/v1/applications" | $PY has-application "$app_name")"
  if [ "$already_exists" = "yes" ]; then
    log "Prowlarr: app sync for $app_name already configured, skipping"
    return
  fi
  cin prowlarr -X POST -H "X-Api-Key: $PROWLARR_KEY" -H "Content-Type: application/json" \
    "http://localhost:$STACK_SERVICES_PROWLARR_PORT/api/v1/applications" -d "{
      \"name\": \"$app_name\", \"implementation\": \"$implementation\", \"configContract\": \"$config_contract\", \"syncLevel\": \"fullSync\",
      \"fields\": [
        {\"name\":\"prowlarrUrl\",\"value\":\"http://prowlarr:$STACK_SERVICES_PROWLARR_PORT\"},
        {\"name\":\"baseUrl\",\"value\":\"$base_url\"},
        {\"name\":\"apiKey\",\"value\":\"$key\"},
        {\"name\":\"syncCategories\",\"value\":$categories}
      ]}" >/dev/null
  log "Prowlarr: synced app $app_name"
}

configure_prowlarr() {
  log "Configuring Prowlarr..."
  configure_servarr_auth "Prowlarr" prowlarr "$STACK_SERVICES_PROWLARR_PORT" "$STACK_SERVICES_PROWLARR_API_VERSION" "$PROWLARR_KEY"
  configure_servarr_loglevel "Prowlarr" prowlarr "$STACK_SERVICES_PROWLARR_PORT" "$STACK_SERVICES_PROWLARR_API_VERSION" "$PROWLARR_KEY"
  _configure_prowlarr_indexers
  _configure_prowlarr_app "Sonarr" "Sonarr" "SonarrSettings" "http://sonarr:$STACK_SERVICES_SONARR_PORT" "$SONARR_KEY" "[$STACK_PROWLARR_SYNC_CATEGORIES_SONARR]"
  _configure_prowlarr_app "Radarr" "Radarr" "RadarrSettings" "http://radarr:$STACK_SERVICES_RADARR_PORT" "$RADARR_KEY" "[$STACK_PROWLARR_SYNC_CATEGORIES_RADARR]"
  cin prowlarr -X POST -H "X-Api-Key: $PROWLARR_KEY" -H "Content-Type: application/json" \
    "http://localhost:$STACK_SERVICES_PROWLARR_PORT/api/v1/command" -d '{"name":"ApplicationIndexerSync"}' >/dev/null
}
