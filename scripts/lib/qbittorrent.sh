#!/usr/bin/env bash
# qBittorrent: replace the rotating one-time temp password (printed to
# container logs on first start) with a permanent WebUI login, then apply
# File Exclusions from scripts/config/qbittorrent-exclusions. qBittorrent's
# WebUI requires a Referer header matching the host, and a successful login
# returns HTTP 204 (not 200) - both easy to miss if you're going off memory
# of a "normal" REST API.

_qbt_login_ok() { [ "$1" = "200" ] || [ "$1" = "204" ]; }

# qBittorrent logs its current one-time temp password on every startup log
# line until a permanent password is set; the most recent line wins.
_qbt_temp_password() {
  docker logs qbittorrent 2>&1 | grep -i "temporary password" | tail -1 | grep -oE '[^ ]+$'
}

# Ensure COOKIES holds a valid qBittorrent WebUI session, setting a
# permanent ADMIN_USERNAME/ADMIN_PASSWORD login in place of the rotating
# temp password if one isn't already set. Returns 1 (with COOKIES left
# unauthenticated) if no valid session could be established.
_ensure_qbt_login() {
  local base_url="$1" cookies="$2"
  local already_logged_in_code
  already_logged_in_code="$(curl -s -c "$cookies" -X POST "$base_url/api/v2/auth/login" \
    -H "Referer: $base_url" --data "username=${ADMIN_USERNAME}&password=${ADMIN_PASSWORD}" -w '%{http_code}' -o /dev/null)"
  if _qbt_login_ok "$already_logged_in_code"; then
    log "qBittorrent: login already set for $ADMIN_USERNAME, skipping"
    return 0
  fi

  local temp_password
  temp_password="$(_qbt_temp_password)"
  if [ -z "$temp_password" ]; then
    warn "qBittorrent: could not find a temporary password in logs; if this isn't a fresh container, log in and change the password by hand."
    return 1
  fi

  local login_succeeded="" code _
  for _ in 1 2 3; do
    code="$(curl -s -c "$cookies" -X POST "$base_url/api/v2/auth/login" \
      -H "Referer: $base_url" --data "username=admin&password=${temp_password}" -w '%{http_code}' -o /dev/null)"
    _qbt_login_ok "$code" && { login_succeeded=1; break; }
    temp_password="$(_qbt_temp_password)"
    sleep 1
  done

  if [ -z "$login_succeeded" ]; then
    warn "qBittorrent: could not log in with the temporary password from the logs - set the WebUI login manually."
    return 1
  fi

  curl -s -b "$cookies" -X POST "$base_url/api/v2/app/setPreferences" \
    --data-urlencode "json={\"web_ui_username\":\"$ADMIN_USERNAME\",\"web_ui_password\":\"$ADMIN_PASSWORD\"}" >/dev/null
  log "qBittorrent: login set for $ADMIN_USERNAME"
}

# Enable File Exclusions (Settings > Downloads) with the patterns in
# scripts/config/qbittorrent-exclusions, one glob per line. Idempotent.
_configure_qbt_file_exclusions() {
  local base_url="$1" cookies="$2"
  local exclusions_file="$SCRIPT_DIR/config/qbittorrent-exclusions"

  local already_configured
  already_configured="$(curl -s -b "$cookies" "$base_url/api/v2/app/preferences" | $PY qbt-exclusions-configured "$exclusions_file")"
  if [ "$already_configured" = "yes" ]; then
    log "qBittorrent: file exclusions already configured, skipping"
    return
  fi

  local payload_file
  payload_file="$(mktemp)"
  $PY qbt-exclusions-payload "$exclusions_file" > "$payload_file"
  curl -s -b "$cookies" -X POST "$base_url/api/v2/app/setPreferences" --data-urlencode "json@$payload_file" >/dev/null
  rm -f "$payload_file"
  log "qBittorrent: file exclusions configured"
}

# Point qBittorrent's default save path under /data (the mount every *arr
# container shares with it) instead of the image's own default of
# /downloads, which isn't mounted to anything - Sonarr/Radarr flag a health
# warning otherwise, since they can't see completed downloads at all. Idempotent.
_ensure_qbt_save_path() {
  local base_url="$1" cookies="$2"
  local current_path
  current_path="$(curl -s -b "$cookies" "$base_url/api/v2/app/preferences" | $PY get-field save_path)"
  if [ "$current_path" = "$STACK_PATHS_DOWNLOADS" ]; then
    log "qBittorrent: save path already set to $STACK_PATHS_DOWNLOADS, skipping"
    return
  fi
  curl -s -b "$cookies" -X POST "$base_url/api/v2/app/setPreferences" \
    --data-urlencode "json={\"save_path\":\"$STACK_PATHS_DOWNLOADS\"}" >/dev/null
  log "qBittorrent: save path set to $STACK_PATHS_DOWNLOADS"
}

# Raise qBittorrent's active-torrent limits above its own conservative
# defaults (3 downloads/3 uploads/5 total) so Sonarr/Radarr grabs run in
# parallel instead of queueing behind each other. Idempotent.
_ensure_qbt_active_limits() {
  local base_url="$1" cookies="$2"
  local prefs current_downloads current_uploads current_torrents
  prefs="$(curl -s -b "$cookies" "$base_url/api/v2/app/preferences")"
  current_downloads="$(echo "$prefs" | $PY get-field max_active_downloads)"
  current_uploads="$(echo "$prefs" | $PY get-field max_active_uploads)"
  current_torrents="$(echo "$prefs" | $PY get-field max_active_torrents)"
  if [ "$current_downloads" = "$STACK_QBITTORRENT_MAX_ACTIVE_DOWNLOADS" ] \
    && [ "$current_uploads" = "$STACK_QBITTORRENT_MAX_ACTIVE_UPLOADS" ] \
    && [ "$current_torrents" = "$STACK_QBITTORRENT_MAX_ACTIVE_TORRENTS" ]; then
    log "qBittorrent: active-torrent limits already configured, skipping"
    return
  fi
  curl -s -b "$cookies" -X POST "$base_url/api/v2/app/setPreferences" \
    --data-urlencode "json={\"max_active_downloads\":$STACK_QBITTORRENT_MAX_ACTIVE_DOWNLOADS,\"max_active_uploads\":$STACK_QBITTORRENT_MAX_ACTIVE_UPLOADS,\"max_active_torrents\":$STACK_QBITTORRENT_MAX_ACTIVE_TORRENTS}" >/dev/null
  log "qBittorrent: active-torrent limits raised to $STACK_QBITTORRENT_MAX_ACTIVE_DOWNLOADS/$STACK_QBITTORRENT_MAX_ACTIVE_UPLOADS/$STACK_QBITTORRENT_MAX_ACTIVE_TORRENTS (downloads/uploads/total)"
}

# Let Gluetun's port-forward-sync hook (scripts/gluetun-port-forward-hook.sh,
# which runs as localhost inside the shared VPN network namespace) update
# qBittorrent's listening port without needing WebUI credentials. Only
# affects requests that are genuinely on loopback - LAN/Caddy traffic still
# arrives over homelab_net and still needs the normal WebUI login. Idempotent.
_ensure_qbt_bypass_local_auth() {
  local base_url="$1" cookies="$2"
  local current
  current="$(curl -s -b "$cookies" "$base_url/api/v2/app/preferences" | $PY get-field bypass_local_auth)"
  if [ "$current" = "True" ]; then
    log "qBittorrent: localhost auth bypass already enabled, skipping"
    return
  fi
  curl -s -b "$cookies" -X POST "$base_url/api/v2/app/setPreferences" \
    --data-urlencode "json={\"bypass_local_auth\":true}" >/dev/null
  log "qBittorrent: localhost auth bypass enabled (needed for Gluetun's port-forward sync hook)"
}

# Match qBittorrent's listening port to Gluetun's current VPN-forwarded port.
# Gluetun's own port-forward-up-command hook (see docker-compose.yml/
# scripts/gluetun-port-forward-hook.sh) keeps this in sync going forward, but
# only fires on the NEXT port change - this closes the gap for whatever port
# was already forwarded before this script got here. A no-op in novpn mode,
# or vpn mode without VPN_PORT_FORWARDING=on, since gluetun won't have a
# forwarded-port file at all.
_ensure_qbt_listen_port() {
  local base_url="$1" cookies="$2"
  local forwarded_port
  forwarded_port="$(docker exec gluetun cat /tmp/gluetun/forwarded_port 2>/dev/null)" || return
  [ -n "$forwarded_port" ] || return

  local current_port
  current_port="$(curl -s -b "$cookies" "$base_url/api/v2/app/preferences" | $PY get-field listen_port)"
  if [ "$current_port" = "$forwarded_port" ]; then
    log "qBittorrent: listening port already matches Gluetun's forwarded port ($forwarded_port), skipping"
    return
  fi
  curl -s -b "$cookies" -X POST "$base_url/api/v2/app/setPreferences" \
    --data-urlencode "json={\"listen_port\":$forwarded_port}" >/dev/null
  log "qBittorrent: listening port set to Gluetun's forwarded port ($forwarded_port)"
}

# Scan every completed download with ClamAV before Sonarr/Radarr import it -
# see scripts/config/qbt-clamav-scan.sh for what the script itself does on a
# match. Idempotent.
_ensure_qbt_clamav_scan() {
  local base_url="$1" cookies="$2"
  local program='/scripts/clamav-scan.sh "%F" "%I"'
  local prefs current_enabled current_program
  prefs="$(curl -s -b "$cookies" "$base_url/api/v2/app/preferences")"
  current_enabled="$(echo "$prefs" | $PY get-field autorun_enabled)"
  current_program="$(echo "$prefs" | $PY get-field autorun_program)"
  if [ "$current_enabled" = "True" ] && [ "$current_program" = "$program" ]; then
    log "qBittorrent: ClamAV completion scan already configured, skipping"
    return
  fi
  local payload_file
  payload_file="$(mktemp)"
  $PY qbt-clamav-scan-payload > "$payload_file"
  curl -s -b "$cookies" -X POST "$base_url/api/v2/app/setPreferences" --data-urlencode "json@$payload_file" >/dev/null
  rm -f "$payload_file"
  log "qBittorrent: ClamAV completion scan configured"
}

configure_qbittorrent() {
  local base_url="http://localhost:$STACK_SERVICES_QBITTORRENT_PORT"
  log "Configuring qBittorrent..."
  local cookies
  cookies="$(mktemp)"

  if _ensure_qbt_login "$base_url" "$cookies"; then
    _configure_qbt_file_exclusions "$base_url" "$cookies"
    _ensure_qbt_save_path "$base_url" "$cookies"
    _ensure_qbt_active_limits "$base_url" "$cookies"
    _ensure_qbt_bypass_local_auth "$base_url" "$cookies"
    _ensure_qbt_listen_port "$base_url" "$cookies"
    _ensure_qbt_clamav_scan "$base_url" "$cookies"
  fi

  rm -f "$cookies"
}
