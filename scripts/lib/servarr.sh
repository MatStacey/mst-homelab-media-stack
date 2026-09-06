#!/usr/bin/env bash
# Shared building blocks for Sonarr and Radarr, which expose near-identical
# APIs (the "*arr" family). Service-specific files (sonarr.sh, radarr.sh)
# call these with their own container/port/API-version/key.

# Set forms-based web UI login on a Sonarr/Radarr/Prowlarr instance.
# Skips if $ADMIN_USERNAME is already the configured login.
configure_servarr_auth() {
  local name="$1" container="$2" port="$3" api_version="$4" key="$5"
  local host_config current_user current_method
  host_config="$(cin "$container" -H "X-Api-Key: $key" "http://localhost:$port/api/$api_version/config/host")"
  current_user="$(echo "$host_config" | $PY get-field username)"
  current_method="$(echo "$host_config" | $PY get-field authenticationMethod)"
  if [ "$current_user" = "$ADMIN_USERNAME" ] && [ "$current_method" = "forms" ]; then
    log "$name: login already set for $ADMIN_USERNAME, skipping"
    return
  fi
  local host_config_id host_config_file
  host_config_id="$(echo "$host_config" | $PY get-field id)"
  host_config_file="$(mktemp)"
  echo "$host_config" | $PY merge-host-auth "$ADMIN_USERNAME" "$ADMIN_PASSWORD" > "$host_config_file"
  _docker_cp_and_remove_local "$host_config_file" "$container" /tmp/host.json
  cin "$container" -X PUT -H "X-Api-Key: $key" -H "Content-Type: application/json" \
    "http://localhost:$port/api/$api_version/config/host/$host_config_id" --data @/tmp/host.json >/dev/null
  _docker_rm_in_container "$container" /tmp/host.json
  log "$name: login set for $ADMIN_USERNAME"
}

# Set the *arr app's log level (Settings > General > Logging). Idempotent.
configure_servarr_loglevel() {
  local name="$1" container="$2" port="$3" api_version="$4" key="$5"
  local host_config current_level
  host_config="$(cin "$container" -H "X-Api-Key: $key" "http://localhost:$port/api/$api_version/config/host")"
  current_level="$(echo "$host_config" | $PY get-field logLevel)"
  if [ "$current_level" = "$STACK_SERVARR_LOG_LEVEL" ]; then
    log "$name: log level already set to $STACK_SERVARR_LOG_LEVEL, skipping"
    return
  fi
  local host_config_id host_config_file
  host_config_id="$(echo "$host_config" | $PY get-field id)"
  host_config_file="$(mktemp)"
  echo "$host_config" | $PY merge-field logLevel "$STACK_SERVARR_LOG_LEVEL" > "$host_config_file"
  _docker_cp_and_remove_local "$host_config_file" "$container" /tmp/host.json
  cin "$container" -X PUT -H "X-Api-Key: $key" -H "Content-Type: application/json" \
    "http://localhost:$port/api/$api_version/config/host/$host_config_id" --data @/tmp/host.json >/dev/null
  _docker_rm_in_container "$container" /tmp/host.json
  log "$name: log level set to $STACK_SERVARR_LOG_LEVEL"
}

# Ensure PATH exists as a root folder. Idempotent.
configure_servarr_rootfolder() {
  local name="$1" container="$2" port="$3" api_version="$4" key="$5" path="$6"
  local already_exists
  already_exists="$(cin "$container" -H "X-Api-Key: $key" "http://localhost:$port/api/$api_version/rootfolder" | $PY has-root-folder "$path")"
  if [ "$already_exists" = "yes" ]; then
    log "$name: root folder $path already present, skipping"
    return
  fi
  cin "$container" -X POST -H "X-Api-Key: $key" -H "Content-Type: application/json" \
    "http://localhost:$port/api/$api_version/rootfolder" -d "{\"path\":\"$path\"}" >/dev/null
  log "$name: added root folder $path"
}

# Connect a *arr app to Jellyfin as a notification target, so a completed
# import triggers an immediate, targeted Jellyfin library scan instead of
# waiting on Jellyfin's own real-time-monitor/periodic scan. Idempotent.
configure_servarr_jellyfin_notification() {
  local name="$1" container="$2" port="$3" api_version="$4" key="$5"
  local already_exists
  already_exists="$(cin "$container" -H "X-Api-Key: $key" "http://localhost:$port/api/$api_version/notification" | $PY has-notification Jellyfin)"
  if [ "$already_exists" = "yes" ]; then
    log "$name: Jellyfin notification already configured, skipping"
    return
  fi
  cin "$container" -X POST -H "X-Api-Key: $key" -H "Content-Type: application/json" \
    "http://localhost:$port/api/$api_version/notification" -d "{
      \"name\": \"Jellyfin\", \"implementation\": \"MediaBrowser\", \"configContract\": \"MediaBrowserSettings\",
      \"onDownload\": true, \"onUpgrade\": true,
      \"fields\": [
        {\"name\":\"host\",\"value\":\"jellyfin\"}, {\"name\":\"port\",\"value\":$STACK_SERVICES_JELLYFIN_PORT},
        {\"name\":\"useSsl\",\"value\":false}, {\"name\":\"apiKey\",\"value\":\"$JELLYFIN_KEY\"},
        {\"name\":\"notify\",\"value\":false}, {\"name\":\"updateLibrary\",\"value\":true}
      ]}" >/dev/null
  log "$name: connected Jellyfin notification (library auto-refresh on import)"
}

# Add qBittorrent as a download client under the given completed-download CATEGORY.
# Idempotent (checks for any existing QBittorrent-implementation client first).
configure_servarr_downloadclient() {
  local name="$1" container="$2" port="$3" api_version="$4" key="$5" category="$6"
  local already_exists
  already_exists="$(cin "$container" -H "X-Api-Key: $key" "http://localhost:$port/api/$api_version/downloadclient" | $PY has-download-client QBittorrent)"
  if [ "$already_exists" = "yes" ]; then
    log "$name: qBittorrent download client already present, skipping"
    return
  fi
  local category_field_name="tvCategory"
  [ "$category" = "movies-radarr" ] && category_field_name="movieCategory"
  cin "$container" -X POST -H "X-Api-Key: $key" -H "Content-Type: application/json" \
    "http://localhost:$port/api/$api_version/downloadclient" -d "{
      \"enable\": true, \"protocol\": \"torrent\", \"priority\": 1,
      \"removeCompletedDownloads\": true, \"removeFailedDownloads\": true,
      \"name\": \"qBittorrent\", \"implementation\": \"QBittorrent\", \"configContract\": \"QBittorrentSettings\",
      \"fields\": [
        {\"name\":\"host\",\"value\":\"qbittorrent\"}, {\"name\":\"port\",\"value\":$STACK_SERVICES_QBITTORRENT_PORT},
        {\"name\":\"useSsl\",\"value\":false}, {\"name\":\"username\",\"value\":\"$ADMIN_USERNAME\"},
        {\"name\":\"password\",\"value\":\"$ADMIN_PASSWORD\"}, {\"name\":\"$category_field_name\",\"value\":\"$category\"},
        {\"name\":\"initialState\",\"value\":0}
      ]}" >/dev/null
  log "$name: added qBittorrent download client (category: $category)"
}
