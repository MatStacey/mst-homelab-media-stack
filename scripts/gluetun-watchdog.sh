#!/usr/bin/env bash
# Restarts VPN-routed services after gluetun (re)starts.
#
# Containers using `network_mode: "service:gluetun"` (qbittorrent-vpn,
# prowlarr-vpn, byparr-vpn) join gluetun's network namespace at the point
# they're created. If gluetun's own container process restarts later - a VPN
# reconnect, a failed healthcheck, a host reboot - Docker doesn't move those
# containers to the new namespace, so they silently go unreachable on their
# published ports even though `docker ps` still shows them "running".
#
# Watches gluetun's health-status transitions and restarts its netns-sharing
# dependents whenever it becomes healthy again. Only restarts dependents that
# are already running - a fresh `docker compose up` brings them up in the
# right order on its own, so restarting them mid-startup would just race it.
#
# Meant to run continuously (see systemd/gluetun-watchdog.service) - install
# with:
#   mkdir -p ~/.config/systemd/user
#   cp systemd/gluetun-watchdog.service ~/.config/systemd/user/
#   systemctl --user daemon-reload
#   systemctl --user enable --now gluetun-watchdog.service
set -uo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1

# compose service name -> its actual container name. These differ for the
# "-vpn" variants, which reuse their "novpn" sibling's container_name (see
# the mutually-exclusive-variants comment in docker-compose.yml) - `docker
# compose restart` needs the service name, `docker inspect` needs the
# container name.
DEPENDENTS="qbittorrent-vpn:qbittorrent-vpn prowlarr-vpn:prowlarr byparr-vpn:byparr"

restart_dependents() {
  local to_restart=()
  local pair service container
  for pair in $DEPENDENTS; do
    service="${pair%%:*}"
    container="${pair#*:}"
    if [ "$(docker inspect -f '{{.State.Running}}' "$container" 2>/dev/null)" = "true" ]; then
      to_restart+=("$service")
    fi
  done
  [ ${#to_restart[@]} -eq 0 ] && return

  echo "$(date -Is) gluetun-watchdog: gluetun is healthy again, restarting ${to_restart[*]}"
  docker compose restart "${to_restart[@]}"
}

echo "$(date -Is) gluetun-watchdog: watching for gluetun health transitions"
docker events --filter container=gluetun --filter event=health_status --format '{{.Action}}' |
  while IFS= read -r status; do
    [ "$status" = "health_status: healthy" ] && restart_dependents
  done
