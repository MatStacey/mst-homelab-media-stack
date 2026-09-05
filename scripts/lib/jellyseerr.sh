#!/usr/bin/env bash
# Jellyseerr: bootstrap the admin account via Jellyfin login, then connect
# Sonarr/Radarr as request-management backends.
#
# Jellyseerr has no curl binary in its image, so every call here is relayed
# through the sonarr container (same docker network) via `cin sonarr`.
# The bootstrap call requires an explicit serverType:2 (JELLYFIN) field or
# it fails with a NO_ADMIN_USER error.

_find_quality_profile_id() {
  local key="$1" port="$2" api_version="$3" container="$4"
  cin "$container" -H "X-Api-Key: $key" "http://localhost:$port/api/$api_version/qualityprofile" \
    | $PY quality-profile-id "$STACK_JELLYSEERR_PREFERRED_QUALITY_PROFILE"
}

# Connect Jellyseerr to a Sonarr/Radarr instance. KIND is "sonarr" or
# "radarr"; EXTRA_FIELDS is additional JSON object fields specific to that
# kind (season folders/language profile for Sonarr, minimum availability for Radarr).
_link_jellyseerr_app() {
  local base_url="$1" cookies="$2" kind="$3" hostname="$4" port="$5" key="$6" path="$7" extra_fields="$8"
  local already_connected
  already_connected="$(cin sonarr -b "$cookies" "$base_url/api/v1/settings/$kind" | $PY has-jellyseerr-app "$hostname")"
  if [ "$already_connected" = "yes" ]; then
    log "Jellyseerr: $kind already connected, skipping"
    return
  fi
  local quality_profile_id
  if [ "$kind" = "sonarr" ]; then
    quality_profile_id="$(_find_quality_profile_id "$SONARR_KEY" "$STACK_SERVICES_SONARR_PORT" "$STACK_SERVICES_SONARR_API_VERSION" sonarr)"
  else
    quality_profile_id="$(_find_quality_profile_id "$RADARR_KEY" "$STACK_SERVICES_RADARR_PORT" "$STACK_SERVICES_RADARR_API_VERSION" radarr)"
  fi
  cin sonarr -b "$cookies" -X POST "$base_url/api/v1/settings/$kind" -H "Content-Type: application/json" -d "{
    \"name\": \"${kind^}\", \"hostname\": \"$hostname\", \"port\": $port, \"apiKey\": \"$key\",
    \"useSsl\": false, \"baseUrl\": \"\", \"activeProfileId\": $quality_profile_id, \"activeDirectory\": \"$path\",
    \"is4k\": false, \"isDefault\": true, \"externalUrl\": \"\", \"syncEnabled\": true,
    \"preventSearch\": false, \"tagRequests\": false $extra_fields}" >/dev/null
  log "Jellyseerr: connected to $kind"
}

configure_jellyseerr() {
  local base_url="http://jellyseerr:$STACK_SERVICES_JELLYSEERR_PORT"
  log "Configuring Jellyseerr..."
  wait_for_jellyseerr

  # Initial call configures the Jellyfin connection; fails harmlessly if already set.
  cin sonarr -s -X POST "$base_url/api/v1/auth/jellyfin" -H "Content-Type: application/json" \
    -d "{\"username\":\"$ADMIN_USERNAME\",\"password\":\"$ADMIN_PASSWORD\",\"hostname\":\"jellyfin\",\"port\":$STACK_SERVICES_JELLYFIN_PORT,\"useSsl\":false,\"urlBase\":\"\",\"email\":\"${ADMIN_USERNAME}@homelab.lan\",\"serverType\":2}" >/dev/null 2>&1 || true

  local cookies="/tmp/setup-js-cookies.txt" login_code
  login_code="$(cin sonarr -c "$cookies" -X POST "$base_url/api/v1/auth/jellyfin" \
    -H "Content-Type: application/json" -d "{\"username\":\"$ADMIN_USERNAME\",\"password\":\"$ADMIN_PASSWORD\"}" -o /dev/null -w '%{http_code}')"

  if [ "$login_code" != "200" ]; then
    warn "Jellyseerr: could not sign in as $ADMIN_USERNAME (mediaServerType may already be set to something else) - skipping"
    docker exec sonarr rm -f "$cookies" 2>/dev/null || true
    return
  fi

  _link_jellyseerr_app "$base_url" "$cookies" sonarr sonarr "$STACK_SERVICES_SONARR_PORT" "$SONARR_KEY" "$STACK_PATHS_TV" \
    ', "enableSeasonFolders": true, "activeLanguageProfileId": 1'
  _link_jellyseerr_app "$base_url" "$cookies" radarr radarr "$STACK_SERVICES_RADARR_PORT" "$RADARR_KEY" "$STACK_PATHS_MOVIES" \
    ', "minimumAvailability": "released"'
  docker exec sonarr rm -f "$cookies" 2>/dev/null || true
}
