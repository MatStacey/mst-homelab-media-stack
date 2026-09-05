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

configure_qbittorrent() {
  local base_url="http://localhost:$STACK_SERVICES_QBITTORRENT_PORT"
  log "Configuring qBittorrent..."
  local cookies
  cookies="$(mktemp)"

  if _ensure_qbt_login "$base_url" "$cookies"; then
    _configure_qbt_file_exclusions "$base_url" "$cookies"
  fi

  rm -f "$cookies"
}
