#!/bin/sh
# Runs inside the qbittorrent container on every torrent completion (wired
# up as its "Run external program on torrent completion" preference by
# _ensure_qbt_clamav_scan in scripts/lib/qbittorrent.sh). Scans the
# completed content against the ClamAV definitions the clamav container
# keeps updated (shared read-only at /var/lib/clamav - see docker-compose.yml)
# using clamscan directly rather than talking to clamd over the network, so
# there's no daemon-availability dependency.
#
# On a positive match, deletes the torrent and its files via qBittorrent's
# own WebUI API (bypass_local_auth already covers this, since it's a
# loopback request from inside the same container) so Sonarr/Radarr never
# see a completed download to import.
set -u

content_path="$1"
torrent_hash="$2"
log_file="/config/clamav-scan.log"

scan_output="$(clamscan --database=/var/lib/clamav --recursive --infected --no-summary "$content_path" 2>&1)"
scan_status=$?

case "$scan_status" in
  0)
    ;;
  1)
    curl -s "http://localhost:8080/api/v2/torrents/delete?hashes=$torrent_hash&deleteFiles=true" >/dev/null
    echo "$(date -Iseconds) INFECTED - deleted torrent $torrent_hash ($content_path): $scan_output" >> "$log_file"
    ;;
  *)
    echo "$(date -Iseconds) SCAN ERROR (status $scan_status) for $content_path: $scan_output" >> "$log_file"
    ;;
esac
