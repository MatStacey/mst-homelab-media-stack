#!/usr/bin/env bash
# qBittorrent: replace the rotating one-time temp password (printed to
# container logs on first start) with a permanent WebUI login. qBittorrent's
# WebUI requires a Referer header matching the host, and a successful login
# returns HTTP 204 (not 200) - both easy to miss if you're going off memory
# of a "normal" REST API.

_qbt_login_ok() { [ "$1" = "200" ] || [ "$1" = "204" ]; }

# qBittorrent logs its current one-time temp password on every startup log
# line until a permanent password is set; the most recent line wins.
_qbt_temp_password() {
  docker logs qbittorrent 2>&1 | grep -i "temporary password" | tail -1 | grep -oE '[^ ]+$'
}

configure_qbittorrent() {
  local base_url="http://localhost:$STACK_SERVICES_QBITTORRENT_PORT"
  log "Configuring qBittorrent..."
  local cookies
  cookies="$(mktemp)"

  local already_logged_in_code
  already_logged_in_code="$(curl -s -c "$cookies" -X POST "$base_url/api/v2/auth/login" \
    -H "Referer: $base_url" --data "username=${ADMIN_USERNAME}&password=${ADMIN_PASSWORD}" -w '%{http_code}' -o /dev/null)"

  if _qbt_login_ok "$already_logged_in_code"; then
    log "qBittorrent: login already set for $ADMIN_USERNAME, skipping"
    rm -f "$cookies"
    return
  fi

  local temp_password
  temp_password="$(_qbt_temp_password)"
  if [ -z "$temp_password" ]; then
    warn "qBittorrent: could not find a temporary password in logs; if this isn't a fresh container, log in and change the password by hand."
    rm -f "$cookies"
    return
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
    rm -f "$cookies"
    return
  fi

  curl -s -b "$cookies" -X POST "$base_url/api/v2/app/setPreferences" \
    --data-urlencode "json={\"web_ui_username\":\"$ADMIN_USERNAME\",\"web_ui_password\":\"$ADMIN_PASSWORD\"}" >/dev/null
  log "qBittorrent: login set for $ADMIN_USERNAME"
  rm -f "$cookies"
}
