#!/usr/bin/env bash
# Reports qBittorrent transfer health to an Uptime Kuma push monitor: "down"
# when the API is unreachable, or when every torrent that should be
# downloading has sat at 0 B/s for STALL_THRESHOLD_CHECKS checks in a row.
# Complements gluetun-watchdog.sh (container up but VPN namespace dead).
#
# Queries via `docker exec` because qBittorrent only skips auth for requests
# originating inside its own network namespace, not its published port.
#
# Meant to run continuously (see systemd/qbt-stall-check.service) - install
# with:
#   cp systemd/qbt-stall-check.service ~/.config/systemd/user/
#   systemctl --user daemon-reload
#   systemctl --user enable --now qbt-stall-check.service
set -uo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1

# vpn profile first, then novpn (same container_name pairing as docker-compose.yml)
QBT_CONTAINERS="qbittorrent-vpn qbittorrent"
QBT_INTERNAL_URL="http://localhost:8080"
CHECK_INTERVAL_SECS=300
STALL_THRESHOLD_CHECKS=3
# States where qBittorrent is expected to be moving data (queued/stopped excluded)
DOWNLOADING_STATES="downloading forcedDL stalledDL metaDL forcedMetaDL"

# Read from .env directly - sourcing it breaks on values containing spaces.
if [ -z "${UPTIME_KUMA_QBT_PUSH_URL:-}" ] && [ -f .env ]; then
  UPTIME_KUMA_QBT_PUSH_URL="$(grep -m1 '^UPTIME_KUMA_QBT_PUSH_URL=' .env | cut -d= -f2- | tr -d '"')"
fi
[ -n "${UPTIME_KUMA_QBT_PUSH_URL:-}" ] || { echo "UPTIME_KUMA_QBT_PUSH_URL is not set (see .env.example)" >&2; exit 1; }

push_kuma() {
  local status="$1" msg="$2"
  curl -s -G "$UPTIME_KUMA_QBT_PUSH_URL" \
    --data-urlencode "status=$status" \
    --data-urlencode "msg=$msg" >/dev/null
}

find_qbt_container() {
  local name
  for name in $QBT_CONTAINERS; do
    if [ "$(docker inspect -f '{{.State.Running}}' "$name" 2>/dev/null)" = "true" ]; then
      echo "$name"
      return 0
    fi
  done
  return 1
}

# Prints "<expected-downloading count> <their combined dlspeed in B/s>".
# Non-zero exit if the container or API can't be reached.
downloading_speed_sum() {
  local container body
  container="$(find_qbt_container)" || return 1
  body="$(docker exec "$container" curl -sf "$QBT_INTERNAL_URL/api/v2/torrents/info")" || return 1
  DOWNLOADING_STATES="$DOWNLOADING_STATES" python3 -c '
import json, os, sys
states = set(os.environ["DOWNLOADING_STATES"].split())
torrents = [t for t in json.load(sys.stdin) if t.get("state") in states]
print(len(torrents), sum(t.get("dlspeed", 0) for t in torrents))
' <<<"$body"
}

main() {
  echo "$(date -Is) qbt-stall-check: checking every ${CHECK_INTERVAL_SECS}s"
  local stall_count=0 result active_count speed_sum
  while true; do
    if ! result="$(downloading_speed_sum)"; then
      echo "$(date -Is) qbt-stall-check: qBittorrent API unreachable"
      push_kuma down "qBittorrent API unreachable"
    else
      read -r active_count speed_sum <<<"$result"
      if [ "$active_count" -eq 0 ] || [ "$speed_sum" -gt 0 ]; then
        stall_count=0
        push_kuma up "$active_count torrent(s) downloading, $speed_sum B/s"
      else
        stall_count=$((stall_count + 1))
        echo "$(date -Is) qbt-stall-check: 0 B/s across $active_count torrent(s), stall_count=$stall_count"
        if [ "$stall_count" -ge "$STALL_THRESHOLD_CHECKS" ]; then
          push_kuma down "$active_count torrent(s) at 0 B/s for $((stall_count * CHECK_INTERVAL_SECS / 60)) min"
        else
          push_kuma up "$active_count torrent(s) at 0 B/s ($stall_count/$STALL_THRESHOLD_CHECKS checks)"
        fi
      fi
    fi
    sleep "$CHECK_INTERVAL_SECS"
  done
}

# Only run the loop when executed directly, so the functions can be sourced for testing.
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  main
fi
