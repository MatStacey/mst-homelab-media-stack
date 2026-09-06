#!/bin/sh
# Gluetun VPN_PORT_FORWARDING_UP_COMMAND hook: keeps qBittorrent's listening
# port in sync with the VPN provider's forwarded port. ProtonVPN can rotate
# this over time, so a one-time manual port set silently goes stale - this
# runs every time Gluetun (re)negotiates a forwarded port.
#
# Runs inside the gluetun container, which shares qBittorrent's network
# namespace in vpn mode, so "localhost" here reaches qBittorrent directly.
# Relies on qBittorrent's "bypass authentication for clients on localhost"
# setting (enabled by scripts/lib/qbittorrent.sh's _ensure_qbt_bypass_local_auth)
# so this needs no WebUI credentials - gluetun has no access to them anyway.
set -eu

port="$1"

wget -qO- \
  --header "Referer: http://localhost:8080" \
  --post-data "json={\"listen_port\":${port}}" \
  "http://localhost:8080/api/v2/app/setPreferences" >/dev/null

echo "gluetun-port-forward-hook: set qBittorrent listen_port to ${port}"
