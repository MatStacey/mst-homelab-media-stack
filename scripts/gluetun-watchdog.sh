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
# Watches gluetun's health-status transitions and, whenever it becomes
# healthy again, restarts any netns-sharing dependent that's still running
# (to rejoin the fresh namespace) and starts any that have since exited -
# e.g. because they lost the netns mid-request and crashed, or because a
# previous gluetun recovery happened before this watchdog was up to see it.
# Dependents that don't exist at all yet are left alone - a fresh `docker
# compose up` brings them up in the right order on its own, so touching them
# mid-startup would just race it.
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
  local to_restart=() to_start=()
  local pair service container running
  for pair in $DEPENDENTS; do
    service="${pair%%:*}"
    container="${pair#*:}"
    running="$(docker inspect -f '{{.State.Running}}' "$container" 2>/dev/null)"
    case "$running" in
      true) to_restart+=("$service") ;;
      false) to_start+=("$service") ;;
      *) ;; # container doesn't exist - leave it for `docker compose up`
    esac
  done

  if [ ${#to_restart[@]} -gt 0 ]; then
    echo "$(date -Is) gluetun-watchdog: gluetun is healthy again, restarting ${to_restart[*]}"
    docker compose restart "${to_restart[@]}"
  fi
  if [ ${#to_start[@]} -gt 0 ]; then
    echo "$(date -Is) gluetun-watchdog: gluetun is healthy again, starting exited dependents: ${to_start[*]}"
    docker compose start "${to_start[@]}"
  fi
}

echo "$(date -Is) gluetun-watchdog: watching for gluetun health transitions"

# Catch up on startup: if gluetun is already healthy (e.g. it and this
# watchdog both came up at a host reboot, or the watchdog restarted after
# gluetun's last recovery), the transition already happened and `docker
# events` below would never see it - so check the current state once up
# front instead of only reacting to future transitions.
if [ "$(docker inspect -f '{{.State.Health.Status}}' gluetun 2>/dev/null)" = "healthy" ]; then
  restart_dependents
fi

docker events --filter container=gluetun --filter event=health_status --format '{{.Action}}' |
  while IFS= read -r status; do
    [ "$status" = "health_status: healthy" ] && restart_dependents
  done
