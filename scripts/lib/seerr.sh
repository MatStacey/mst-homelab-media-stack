#!/usr/bin/env bash
# Seerr (the merged successor to Overseerr/Jellyseerr): bootstrap the admin
# account via Jellyfin login, then connect Sonarr/Radarr as request-management
# backends.
#
# Seerr has no curl binary in its image, so every call here is relayed
# through the sonarr container (same docker network) via `cin sonarr`.
# The bootstrap call requires an explicit serverType:2 (JELLYFIN) field or
# it fails with a NO_ADMIN_USER error.

# Prints "id name" (space-separated) for the picked quality profile - name
# last since it may itself contain spaces (e.g. "HD - 720p/1080p"), and
# callers only need $1 split off, with the remainder taken as the name.
_find_quality_profile() {
  local key="$1" port="$2" api_version="$3" container="$4" preferred_name="$5"
  local profiles_json
  profiles_json="$(cin "$container" -H "X-Api-Key: $key" "http://localhost:$port/api/$api_version/qualityprofile")"
  echo "$(echo "$profiles_json" | $PY quality-profile-id "$preferred_name") $(echo "$profiles_json" | $PY quality-profile-name "$preferred_name")"
}

# Connect Seerr to a Sonarr/Radarr instance, or - if already connected - make
# sure it's still pointed at the preferred quality profile (stack.yaml's
# seerr.preferred_quality_profile_{sonarr,radarr}), correcting it in place if
# not. KIND is "sonarr" or "radarr"; EXTRA_FIELDS is additional JSON object
# fields specific to that kind (season folders/language profile for Sonarr,
# minimum availability for Radarr).
_link_seerr_app() {
  local base_url="$1" cookies="$2" kind="$3" hostname="$4" port="$5" key="$6" path="$7" extra_fields="$8"
  local preferred_profile quality_profile
  if [ "$kind" = "sonarr" ]; then
    preferred_profile="$STACK_SEERR_PREFERRED_QUALITY_PROFILE_SONARR"
    quality_profile="$(_find_quality_profile "$SONARR_KEY" "$STACK_SERVICES_SONARR_PORT" "$STACK_SERVICES_SONARR_API_VERSION" sonarr "$preferred_profile")"
  else
    preferred_profile="$STACK_SEERR_PREFERRED_QUALITY_PROFILE_RADARR"
    quality_profile="$(_find_quality_profile "$RADARR_KEY" "$STACK_SERVICES_RADARR_PORT" "$STACK_SERVICES_RADARR_API_VERSION" radarr "$preferred_profile")"
  fi
  local quality_profile_id="${quality_profile%% *}" quality_profile_name="${quality_profile#* }"

  local existing_settings
  existing_settings="$(cin sonarr -b "$cookies" "$base_url/api/v1/settings/$kind")"
  local existing_id
  existing_id="$(echo "$existing_settings" | $PY seerr-app-field "$hostname" id)"
  if [ -n "$existing_id" ]; then
    local existing_profile_id
    existing_profile_id="$(echo "$existing_settings" | $PY seerr-app-field "$hostname" activeProfileId)"
    if [ "$existing_profile_id" = "$quality_profile_id" ]; then
      log "Seerr: $kind already connected with the preferred quality profile, skipping"
      return
    fi
    cin sonarr -b "$cookies" -X PUT "$base_url/api/v1/settings/$kind/$existing_id" -H "Content-Type: application/json" -d "{
      \"name\": \"${kind^}\", \"hostname\": \"$hostname\", \"port\": $port, \"apiKey\": \"$key\",
      \"useSsl\": false, \"baseUrl\": \"\", \"activeProfileId\": $quality_profile_id, \"activeProfileName\": \"$quality_profile_name\", \"activeDirectory\": \"$path\",
      \"is4k\": false, \"isDefault\": true, \"externalUrl\": \"\", \"syncEnabled\": true,
      \"preventSearch\": false, \"tagRequests\": false $extra_fields}" >/dev/null
    log "Seerr: $kind quality profile updated to '$quality_profile_name'"
    return
  fi

  cin sonarr -b "$cookies" -X POST "$base_url/api/v1/settings/$kind" -H "Content-Type: application/json" -d "{
    \"name\": \"${kind^}\", \"hostname\": \"$hostname\", \"port\": $port, \"apiKey\": \"$key\",
    \"useSsl\": false, \"baseUrl\": \"\", \"activeProfileId\": $quality_profile_id, \"activeProfileName\": \"$quality_profile_name\", \"activeDirectory\": \"$path\",
    \"is4k\": false, \"isDefault\": true, \"externalUrl\": \"\", \"syncEnabled\": true,
    \"preventSearch\": false, \"tagRequests\": false $extra_fields}" >/dev/null
  log "Seerr: connected to $kind"
}

# Sync Jellyfin's libraries into Seerr and enable them, then mark Seerr's
# own setup wizard complete. Without this, every visit to Seerr redirects to
# its multi-step setup wizard even though the Jellyfin/Sonarr/Radarr
# connections are already fully configured via the API calls above.
#
# Seerr has a single GET /jellyfin/library endpoint for both steps (no
# separate sync/enable endpoints): ?sync=true refreshes the library list from
# Jellyfin, and ?enable=id1,id2 sets exactly those ids enabled - passing
# neither would zero out enabled on every library, so the two query params
# must be combined into the same call once ids are known.
_finish_seerr_setup() {
  local base_url="$1" cookies="$2"
  local already_initialized
  already_initialized="$(cin sonarr -b "$cookies" "$base_url/api/v1/settings/public" | $PY get-field initialized)"
  if [ "$already_initialized" = "True" ]; then
    log "Seerr: setup already marked complete, skipping"
    return
  fi

  local sync_response sync_code sync_body
  sync_response="$(cin sonarr -b "$cookies" "$base_url/api/v1/settings/jellyfin/library?sync=true" -w '\n%{http_code}')"
  sync_code="$(echo "$sync_response" | tail -1)"
  sync_body="$(echo "$sync_response" | sed '$d')"
  if [ "$sync_code" != "200" ]; then
    warn "Seerr: library sync returned HTTP $sync_code - leaving setup wizard incomplete. Response: $sync_body"
    return
  fi

  local library_ids
  library_ids="$(echo "$sync_body" | $PY jellyfin-library-ids)"
  if [ -z "$library_ids" ]; then
    warn "Seerr: sync succeeded but returned no Jellyfin libraries - leaving setup wizard incomplete. Response: $sync_body"
    return
  fi

  local enable_param
  enable_param="$(echo "$library_ids" | paste -sd,)"
  local enable_code
  enable_code="$(cin sonarr -b "$cookies" "$base_url/api/v1/settings/jellyfin/library?enable=$enable_param" -o /dev/null -w '%{http_code}')"
  if [ "$enable_code" != "200" ]; then
    warn "Seerr: enabling libraries returned HTTP $enable_code - leaving setup wizard incomplete"
    return
  fi

  local init_code
  init_code="$(cin sonarr -b "$cookies" -X POST "$base_url/api/v1/settings/initialize" -o /dev/null -w '%{http_code}')"
  if [ "$init_code" != "200" ]; then
    warn "Seerr: marking setup complete returned HTTP $init_code"
    return
  fi
  log "Seerr: setup marked complete"
}

configure_seerr() {
  local base_url="http://seerr:$STACK_SERVICES_SEERR_PORT"
  log "Configuring Seerr..."
  wait_for_seerr

  # Initial call configures the Jellyfin connection; fails harmlessly if already set.
  cin sonarr -s -X POST "$base_url/api/v1/auth/jellyfin" -H "Content-Type: application/json" \
    -d "{\"username\":\"$ADMIN_USERNAME\",\"password\":\"$ADMIN_PASSWORD\",\"hostname\":\"jellyfin\",\"port\":$STACK_SERVICES_JELLYFIN_PORT,\"useSsl\":false,\"urlBase\":\"\",\"email\":\"${ADMIN_USERNAME}@homelab.lan\",\"serverType\":2}" >/dev/null 2>&1 || true

  local cookies="/tmp/setup-seerr-cookies.txt" login_code
  login_code="$(cin sonarr -c "$cookies" -X POST "$base_url/api/v1/auth/jellyfin" \
    -H "Content-Type: application/json" -d "{\"username\":\"$ADMIN_USERNAME\",\"password\":\"$ADMIN_PASSWORD\"}" -o /dev/null -w '%{http_code}')"

  if [ "$login_code" != "200" ]; then
    warn "Seerr: could not sign in as $ADMIN_USERNAME (mediaServerType may already be set to something else) - skipping"
    docker exec sonarr rm -f "$cookies" 2>/dev/null || true
    return
  fi

  _link_seerr_app "$base_url" "$cookies" sonarr sonarr "$STACK_SERVICES_SONARR_PORT" "$SONARR_KEY" "$STACK_PATHS_TV" \
    ', "enableSeasonFolders": true, "activeLanguageProfileId": 1'
  _link_seerr_app "$base_url" "$cookies" radarr radarr "$STACK_SERVICES_RADARR_PORT" "$RADARR_KEY" "$STACK_PATHS_MOVIES" \
    ', "minimumAvailability": "released"'
  _finish_seerr_setup "$base_url" "$cookies"

  # For services (Homepage) that need Seerr's own API key rather than a
  # session cookie like this script uses for itself. Only the admin account
  # gets this field back from /settings/main, which is exactly who we're
  # authenticated as here.
  # shellcheck disable=SC2034  # consumed by lib/homepage.sh's configure_homepage
  SEERR_KEY="$(cin sonarr -b "$cookies" "$base_url/api/v1/settings/main" | $PY get-field apiKey)"

  docker exec sonarr rm -f "$cookies" 2>/dev/null || true
}
