#!/usr/bin/env bash
# Writes RIOT_GAME_NAME#RIOT_TAG_LINE's Ranked Solo/Duo stats to a JSON file
# that Caddy serves statically, for Homepage's League of Legends customapi
# widget to poll (Riot's API can't be queried directly from a single
# customapi call - it needs two chained requests across two different
# regional hosts). Also mirrors the official rank emblem for the current
# tier from Community Dragon, used as that service's Homepage icon.
#
# RIOT_DEV_API_KEY is a development key from the Riot Developer Portal and
# expires 24h after generation. Once it expires this script starts logging
# 403s and the widget freezes on its last-known values - regenerate the key
# at developer.riotgames.com and update it in .env, no restart needed since
# it's read fresh from .env every loop.
#
# Meant to run continuously (see systemd/riot-stats-update.service) - install
# with:
#   cp systemd/riot-stats-update.service ~/.config/systemd/user/
#   systemctl --user daemon-reload
#   systemctl --user enable --now riot-stats-update.service
set -uo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1

UPDATE_INTERVAL_SECS=600
OUTPUT_FILE="caddy/site/riot-stats.json"
BADGE_OUTPUT_FILE="config/homepage/icons/riot-rank-badge.png"
BADGE_BASE_URL="https://raw.communitydragon.org/latest/plugins/rcp-fe-lol-static-assets/global/default/images/ranked-emblem"
# Community Dragon's emblem PNGs sit on a mostly-empty ~2560x1440 canvas -
# too small a fraction of the frame to read at icon size, so trim the
# transparent padding via a throwaway ImageMagick container (avoids adding
# an image-processing dependency to the host).
IMAGEMAGICK_IMAGE="dpokidov/imagemagick:7.1.2-12"
# Derived from RIOT_TAG_LINE=EUW - adjust both if your account is on a
# different platform (e.g. na1/americas, kr/asia) - see:
# https://developer.riotgames.com/docs/lol#routing-values
RIOT_PLATFORM="${RIOT_PLATFORM:-euw1}"
RIOT_REGION="${RIOT_REGION:-europe}"

# Read from .env directly - sourcing it breaks on values containing spaces.
env_var() {
  [ -n "${!1:-}" ] && { echo "${!1}"; return; }
  [ -f .env ] && grep -m1 "^$1=" .env | cut -d= -f2- | tr -d '"'
}

fetch_and_write() {
  local api_key game_name tag_line
  api_key="$(env_var RIOT_DEV_API_KEY)"
  game_name="$(env_var RIOT_GAME_NAME)"
  tag_line="$(env_var RIOT_TAG_LINE)"
  if [ -z "$api_key" ] || [ -z "$game_name" ] || [ -z "$tag_line" ]; then
    echo "$(date -Is) riot-stats-update: RIOT_DEV_API_KEY/RIOT_GAME_NAME/RIOT_TAG_LINE not set (see .env.example)" >&2
    return 1
  fi

  local game_name_enc tag_line_enc
  game_name_enc="$(python3 -c 'import sys, urllib.parse; print(urllib.parse.quote(sys.argv[1]))' "$game_name")"
  tag_line_enc="$(python3 -c 'import sys, urllib.parse; print(urllib.parse.quote(sys.argv[1]))' "$tag_line")"

  local puuid
  puuid="$(curl -sf -H "X-Riot-Token: $api_key" \
    "https://${RIOT_REGION}.api.riotgames.com/riot/account/v1/accounts/by-riot-id/${game_name_enc}/${tag_line_enc}" \
    | jq -er '.puuid')" || { echo "$(date -Is) riot-stats-update: account lookup failed" >&2; return 1; }

  local entries
  entries="$(curl -sf -H "X-Riot-Token: $api_key" \
    "https://${RIOT_PLATFORM}.api.riotgames.com/lol/league/v4/entries/by-puuid/${puuid}")" \
    || { echo "$(date -Is) riot-stats-update: league entries lookup failed" >&2; return 1; }

  local tmp_file
  tmp_file="${OUTPUT_FILE}.tmp"
  echo "$entries" | python3 -c '
import json, sys

entries = json.load(sys.stdin)
solo = next((e for e in entries if e.get("queueType") == "RANKED_SOLO_5x5"), None)

if solo is None:
    stats = {"rank": "Unranked", "leaguePoints": 0, "wins": 0, "losses": 0}
else:
    rank_name = solo["tier"].capitalize() + " " + solo["rank"]
    stats = {
        "rank": rank_name,
        "leaguePoints": solo["leaguePoints"],
        "wins": solo["wins"],
        "losses": solo["losses"],
    }

json.dump(stats, sys.stdout)
' > "$tmp_file" && mv "$tmp_file" "$OUTPUT_FILE"

  # Official Riot rank emblem for the current Solo/Duo tier - no emblem
  # exists for Unranked, so the badge just keeps its last-known image then.
  local tier
  tier="$(echo "$entries" | jq -r '.[] | select(.queueType == "RANKED_SOLO_5x5") | .tier // empty' | tr '[:upper:]' '[:lower:]')"
  if [ -n "$tier" ]; then
    local badge_raw="${BADGE_OUTPUT_FILE}.raw.tmp" badge_trimmed="${BADGE_OUTPUT_FILE}.tmp"
    curl -sf "${BADGE_BASE_URL}/emblem-${tier}.png" -o "$badge_raw" \
      && docker run --rm --entrypoint magick --user "$(id -u):$(id -g)" \
           -v "$(pwd)/config/homepage/icons:/data" "$IMAGEMAGICK_IMAGE" \
           "/data/$(basename "$badge_raw")" -trim +repage "/data/$(basename "$badge_trimmed")" \
      && mv "$badge_trimmed" "$BADGE_OUTPUT_FILE"
    rm -f "$badge_raw"
  fi
}

main() {
  echo "$(date -Is) riot-stats-update: updating every ${UPDATE_INTERVAL_SECS}s"
  while true; do
    fetch_and_write && echo "$(date -Is) riot-stats-update: wrote $OUTPUT_FILE"
    sleep "$UPDATE_INTERVAL_SECS"
  done
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  main
fi
