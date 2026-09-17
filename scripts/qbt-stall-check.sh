#!/usr/bin/env bash
# Detects qBittorrent downloads stuck at 0 B/s (e.g. after gluetun loses its
# VPN connection but qBittorrent's WebUI stays reachable) and reports health
# to an Uptime Kuma push monitor. A reachable WebUI isn't enough on its own -
# see gluetun-watchdog.sh for the related "container up but netns dead" case.
#
# Meant to run continuously (see systemd/qbt-stall-check.service) - install
# with:
#   cp systemd/qbt-stall-check.service ~/.config/systemd/user/
#   systemctl --user daemon-reload
#   systemctl --user enable --now qbt-stall-check.service
set -uo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1
[ -f .env ] && set -a && source .env && set +a

QBT_URL="http://localhost:8080"
CHECK_INTERVAL_SECS=300
STALL_THRESHOLD_CHECKS=3

: "${UPTIME_KUMA_QBT_PUSH_URL:?Set UPTIME_KUMA_QBT_PUSH_URL in .env (Uptime Kumas Push monitor URL)}"

push_kuma() {
  local status="$1" msg="$2"
  curl -s -G "$UPTIME_KUMA_QBT_PUSH_URL" \
    --data-urlencode "status=$status" \
    --data-urlencode "msg=$msg" >/dev/null
}

# Sum of dlspeed across torrents qBittorrent considers actively downloading.
# Empty/unreachable API response reads as 0 torrents, not a stall - a
# separate service check already covers "qBittorrent is down".
downloading_speed_sum() {
  curl -s "$QBT_URL/api/v2/torrents/info?filter=downloading" |
    python3 -c '
import json, sys
try:
    torrents = json.load(sys.stdin)
except ValueError:
    torrents = []
print(len(torrents), sum(t.get("dlspeed", 0) for t in torrents))
'
}

echo "$(date -Is) qbt-stall-check: watching for stalled downloads every ${CHECK_INTERVAL_SECS}s"
stall_count=0
while true; do
  read -r active_count speed_sum <<<"$(downloading_speed_sum)"

  if [ "${active_count:-0}" -eq 0 ] || [ "${speed_sum:-0}" -gt 0 ]; then
    stall_count=0
    push_kuma up "${active_count:-0} torrent(s) downloading, ${speed_sum:-0} B/s"
  else
    stall_count=$((stall_count + 1))
    echo "$(date -Is) qbt-stall-check: 0 B/s with $active_count active torrent(s), stall_count=$stall_count"
    if [ "$stall_count" -ge "$STALL_THRESHOLD_CHECKS" ]; then
      push_kuma down "$active_count torrent(s) stuck at 0 B/s for $((stall_count * CHECK_INTERVAL_SECS / 60)) min"
    else
      push_kuma up "$active_count torrent(s) at 0 B/s, within stall threshold ($stall_count/$STALL_THRESHOLD_CHECKS)"
    fi
  fi

  sleep "$CHECK_INTERVAL_SECS"
done
