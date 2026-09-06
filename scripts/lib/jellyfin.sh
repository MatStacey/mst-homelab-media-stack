#!/usr/bin/env bash
# Jellyfin: complete the first-run startup wizard (server name, admin user,
# remote access) if needed, then ensure the Movies/TV libraries exist.

# Run the first-run startup wizard if it hasn't been completed yet. Idempotent.
_ensure_jellyfin_wizard_complete() {
  local base_url="$1"
  local wizard_done
  wizard_done="$(cin jellyfin "$base_url/System/Info/Public" | $PY jellyfin-wizard-completed)"
  if [ "$wizard_done" != "no" ]; then
    log "Jellyfin: startup wizard already completed, skipping"
    return
  fi
  cin jellyfin -X POST "$base_url/Startup/Configuration" -H "Content-Type: application/json" \
    -d "{\"ServerName\":\"$STACK_JELLYFIN_SERVER_NAME\",\"UICulture\":\"$STACK_JELLYFIN_UI_CULTURE\",\"MetadataCountryCode\":\"$STACK_JELLYFIN_METADATA_COUNTRY_CODE\",\"PreferredMetadataLanguage\":\"$STACK_JELLYFIN_PREFERRED_METADATA_LANGUAGE\"}" >/dev/null
  cin jellyfin -X POST "$base_url/Startup/User" -H "Content-Type: application/json" \
    -d "{\"Name\":\"$ADMIN_USERNAME\",\"Password\":\"$ADMIN_PASSWORD\"}" >/dev/null
  cin jellyfin -X POST "$base_url/Startup/RemoteAccess" -H "Content-Type: application/json" \
    -d '{"EnableRemoteAccess":true,"EnableAutomaticPortMapping":false}' >/dev/null
  cin jellyfin -X POST "$base_url/Startup/Complete" >/dev/null
  log "Jellyfin: startup wizard completed, admin user $ADMIN_USERNAME created"
}

# Ensure a library named NAME (Jellyfin collection type COLLECTION_TYPE)
# exists pointing at PATH. Idempotent.
_add_jellyfin_library() {
  local base_url="$1" library_name="$2" collection_type="$3" path="$4" token="$5"
  local already_exists
  already_exists="$(cin jellyfin -H "X-Emby-Token: $token" "$base_url/Library/VirtualFolders" | $PY has-jellyfin-library "$path")"
  if [ "$already_exists" = "yes" ]; then
    log "Jellyfin: library for $path already present, skipping"
    return
  fi
  local encoded_name
  encoded_name="$($PY url-encode "$library_name")"
  cin jellyfin -X POST "$base_url/Library/VirtualFolders?name=${encoded_name}&collectionType=$collection_type&refreshLibrary=false" \
    -H "X-Emby-Token: $token" -H "Content-Type: application/json" \
    -d "{\"LibraryOptions\":{\"PathInfos\":[{\"Path\":\"$path\"}],\"EnablePhotos\":false,\"EnableRealtimeMonitor\":true}}" >/dev/null
  log "Jellyfin: added '$library_name' library ($path)"
}

# Turn on real-time filesystem monitoring for the library covering PATH, so
# new files are picked up immediately instead of waiting for a periodic scan.
# Idempotent, and fixes libraries that predate _add_jellyfin_library setting
# this explicitly at creation time (this stack's original TV Shows library
# had it off while Movies had it on - an inconsistency, not a deliberate
# choice - hence fixing existing libraries here rather than only new ones).
_ensure_jellyfin_realtime_monitor() {
  local base_url="$1" path="$2" token="$3"
  local payload
  payload="$(cin jellyfin -H "X-Emby-Token: $token" "$base_url/Library/VirtualFolders" | $PY jellyfin-realtime-monitor-payload "$path")"
  if [ -z "$payload" ]; then
    log "Jellyfin: real-time monitoring already enabled for $path, skipping"
    return
  fi
  local payload_file
  payload_file="$(mktemp)"
  echo "$payload" > "$payload_file"
  _docker_cp_and_remove_local "$payload_file" jellyfin /tmp/libopts.json
  cin jellyfin -X POST "$base_url/Library/VirtualFolders/LibraryOptions" \
    -H "X-Emby-Token: $token" -H "Content-Type: application/json" --data @/tmp/libopts.json >/dev/null
  _docker_rm_in_container jellyfin /tmp/libopts.json
  log "Jellyfin: enabled real-time monitoring for $path"
}

# Find (or mint) a persistent Jellyfin API key named APP_NAME, for services
# (Homepage) that need long-lived access rather than the short-lived session
# token this script uses for itself. Idempotent: reuses a same-named key.
_ensure_jellyfin_api_key() {
  local base_url="$1" token="$2" app_name="$3"
  local existing_key
  existing_key="$(cin jellyfin -H "X-Emby-Token: $token" "$base_url/Auth/Keys" | $PY jellyfin-api-key "$app_name")"
  if [ -n "$existing_key" ]; then
    echo "$existing_key"
    return
  fi
  cin jellyfin -X POST "$base_url/Auth/Keys?app=$app_name" -H "X-Emby-Token: $token" >/dev/null
  cin jellyfin -H "X-Emby-Token: $token" "$base_url/Auth/Keys" | $PY jellyfin-api-key "$app_name"
}

configure_jellyfin() {
  local base_url="http://localhost:$STACK_SERVICES_JELLYFIN_PORT"
  log "Configuring Jellyfin..."
  wait_for_http "Jellyfin" jellyfin "$base_url/System/Info/Public"
  _ensure_jellyfin_wizard_complete "$base_url"

  local auth_response token
  auth_response="$(cin jellyfin -X POST "$base_url/Users/AuthenticateByName" \
    -H "Content-Type: application/json" \
    -H 'X-Emby-Authorization: MediaBrowser Client="setup.sh", Device="setup.sh", DeviceId="setup-script", Version="1.0.0"' \
    -d "{\"Username\":\"$ADMIN_USERNAME\",\"Pw\":\"$ADMIN_PASSWORD\"}")"
  token="$(echo "$auth_response" | $PY extract-token AccessToken)"

  if [ -z "$token" ]; then
    warn "Jellyfin: could not log in as $ADMIN_USERNAME (wizard may have been completed earlier with different credentials) - skipping library setup"
    return
  fi

  _add_jellyfin_library "$base_url" "Movies" "movies" "$STACK_PATHS_MOVIES" "$token"
  _add_jellyfin_library "$base_url" "TV Shows" "tvshows" "$STACK_PATHS_TV" "$token"
  _ensure_jellyfin_realtime_monitor "$base_url" "$STACK_PATHS_MOVIES" "$token"
  _ensure_jellyfin_realtime_monitor "$base_url" "$STACK_PATHS_TV" "$token"
  cin jellyfin -X POST "$base_url/Library/Refresh" -H "X-Emby-Token: $token" >/dev/null

  # shellcheck disable=SC2034  # consumed by lib/homepage.sh's configure_homepage
  JELLYFIN_KEY="$(_ensure_jellyfin_api_key "$base_url" "$token" Homepage)"
}
