#!/usr/bin/env bash
# Writes each configured account's Ranked Solo/Duo stats to its own JSON
# file that Caddy serves statically, for Homepage's League of Legends
# customapi widgets to poll (Riot's API can't be queried directly from a
# single customapi call - it needs two chained requests across two
# different regional hosts). Also mirrors the official rank emblem for
# each account's current tier from Community Dragon, used as that
# service's Homepage icon.
#
# Accounts: RIOT_GAME_NAME#RIOT_TAG_LINE (the "Main" account) plus every
# "GameName#TagLine" pair in the comma-separated RIOT_SMURF_ACCOUNTS.
#
# RIOT_DEV_API_KEY is a development key from the Riot Developer Portal and
# expires 24h after generation. Once it expires this script starts logging
# 403s and every widget freezes on its last-known values - regenerate the
# key at developer.riotgames.com and update it in .env, no restart needed
# since it's read fresh from .env every loop.
#
# Meant to run continuously (see systemd/riot-stats-update.service) - install
# with:
#   cp systemd/riot-stats-update.service ~/.config/systemd/user/
#   systemctl --user daemon-reload
#   systemctl --user enable --now riot-stats-update.service
set -uo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1

UPDATE_INTERVAL_SECS=600
STATS_OUTPUT_DIR="caddy/site"
BADGE_OUTPUT_DIR="config/homepage/icons"
BADGE_BASE_URL="https://raw.communitydragon.org/latest/plugins/rcp-fe-lol-static-assets/global/default/images/ranked-emblem"
# Community Dragon's emblem PNGs sit on a mostly-empty ~2560x1440 canvas -
# too small a fraction of the frame to read at icon size, so trim the
# transparent padding via a throwaway ImageMagick container (avoids adding
# an image-processing dependency to the host).
IMAGEMAGICK_IMAGE="dpokidov/imagemagick:7.1.2-12"
PATCH_NOTES_URL="https://www.leagueoflegends.com/en-gb/news/tags/patch-notes/"
PATCH_NOTES_OUTPUT_FILE="${STATS_OUTPUT_DIR}/lol-patch-notes.json"
USER_AGENT="Mozilla/5.0"
# Derived from RIOT_TAG_LINE=EUW - adjust both if your accounts are on a
# different platform (e.g. na1/americas, kr/asia) - see:
# https://developer.riotgames.com/docs/lol#routing-values. All accounts
# share one platform/region here since they're all EUW.
RIOT_PLATFORM="${RIOT_PLATFORM:-euw1}"
RIOT_REGION="${RIOT_REGION:-europe}"

# Read from .env directly - sourcing it breaks on values containing spaces.
env_var() {
  [ -n "${!1:-}" ] && { echo "${!1}"; return; }
  [ -f .env ] && grep -m1 "^$1=" .env | cut -d= -f2- | tr -d '"'
}

# Lowercased, alphanumeric-only account name - used for output filenames.
slugify() {
  echo "$1" | tr '[:upper:]' '[:lower:]' | tr -cd 'a-z0-9'
}

fetch_account() {
  local api_key="$1" game_name="$2" tag_line="$3"
  local slug output_file badge_output_file
  slug="$(slugify "$game_name")"
  output_file="${STATS_OUTPUT_DIR}/riot-stats-${slug}.json"
  badge_output_file="${BADGE_OUTPUT_DIR}/riot-rank-badge-${slug}.png"

  local game_name_enc tag_line_enc
  game_name_enc="$(python3 -c 'import sys, urllib.parse; print(urllib.parse.quote(sys.argv[1]))' "$game_name")"
  tag_line_enc="$(python3 -c 'import sys, urllib.parse; print(urllib.parse.quote(sys.argv[1]))' "$tag_line")"

  local puuid
  puuid="$(curl -sf -H "X-Riot-Token: $api_key" \
    "https://${RIOT_REGION}.api.riotgames.com/riot/account/v1/accounts/by-riot-id/${game_name_enc}/${tag_line_enc}" \
    | jq -er '.puuid')" || { echo "$(date -Is) riot-stats-update: account lookup failed for $game_name#$tag_line" >&2; return 1; }

  local entries
  entries="$(curl -sf -H "X-Riot-Token: $api_key" \
    "https://${RIOT_PLATFORM}.api.riotgames.com/lol/league/v4/entries/by-puuid/${puuid}")" \
    || { echo "$(date -Is) riot-stats-update: league entries lookup failed for $game_name#$tag_line" >&2; return 1; }

  local tmp_file
  tmp_file="${output_file}.tmp"
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
' > "$tmp_file" && mv "$tmp_file" "$output_file"

  # Official Riot rank emblem for the current Solo/Duo tier - no emblem
  # exists for Unranked, so the badge just keeps its last-known image then.
  local tier
  tier="$(echo "$entries" | jq -r '.[] | select(.queueType == "RANKED_SOLO_5x5") | .tier // empty' | tr '[:upper:]' '[:lower:]')"
  if [ -n "$tier" ]; then
    local badge_raw="${badge_output_file}.raw.tmp" badge_trimmed="${badge_output_file}.tmp"
    curl -sf "${BADGE_BASE_URL}/emblem-${tier}.png" -o "$badge_raw" \
      && docker run --rm --entrypoint magick --user "$(id -u):$(id -g)" \
           -v "$(pwd)/${BADGE_OUTPUT_DIR}:/data" "$IMAGEMAGICK_IMAGE" \
           "/data/$(basename "$badge_raw")" -trim +repage "/data/$(basename "$badge_trimmed")" \
      && mv "$badge_trimmed" "$badge_output_file"
    rm -f "$badge_raw"
  fi

  echo "$(date -Is) riot-stats-update: wrote $output_file"
}

fetch_patch_notes() {
  local page tmp_file="${PATCH_NOTES_OUTPUT_FILE}.tmp"
  page="$(curl -sfL -A "$USER_AGENT" "$PATCH_NOTES_URL")" \
    || { echo "$(date -Is) riot-stats-update: patch notes page fetch failed" >&2; return 1; }

  echo "$page" | python3 -c '
import datetime, html, json, re, sys

next_data = re.search(r"<script id=\"__NEXT_DATA__\"[^>]*>(.*?)</script>", sys.stdin.read(), re.S)
if next_data is None:
    sys.exit(1)

articles = []

def collect(node):
    if isinstance(node, dict):
        if "publishedAt" in node and re.fullmatch(r"League of Legends Patch [\w.]+ Notes", str(node.get("title"))):
            articles.append(node)
        for child in node.values():
            collect(child)
    elif isinstance(node, list):
        for child in node:
            collect(child)

collect(json.loads(next_data.group(1)))
if not articles:
    sys.exit(1)

latest = max(articles, key=lambda a: a["publishedAt"])
published = datetime.datetime.fromisoformat(latest["publishedAt"].replace("Z", "+00:00"))
summary = re.sub(r"<[^>]+>", "", html.unescape(latest["description"]["body"])).strip()

json.dump({
    "patch": re.search(r"Patch ([\w.]+) Notes", latest["title"]).group(1),
    "published": published.strftime("%d %b %Y"),
    "summary": summary,
}, sys.stdout)
' > "$tmp_file" \
    && mv "$tmp_file" "$PATCH_NOTES_OUTPUT_FILE" \
    || { rm -f "$tmp_file"; echo "$(date -Is) riot-stats-update: patch notes not found in page" >&2; return 1; }

  echo "$(date -Is) riot-stats-update: wrote $PATCH_NOTES_OUTPUT_FILE"
}

fetch_all() {
  local api_key main_game main_tag smurfs
  api_key="$(env_var RIOT_DEV_API_KEY)"
  main_game="$(env_var RIOT_GAME_NAME)"
  main_tag="$(env_var RIOT_TAG_LINE)"
  smurfs="$(env_var RIOT_SMURF_ACCOUNTS)"
  if [ -z "$api_key" ] || [ -z "$main_game" ] || [ -z "$main_tag" ]; then
    echo "$(date -Is) riot-stats-update: RIOT_DEV_API_KEY/RIOT_GAME_NAME/RIOT_TAG_LINE not set (see .env.example)" >&2
    return 1
  fi

  fetch_account "$api_key" "$main_game" "$main_tag"

  local account game tag
  IFS=',' read -ra accounts <<<"$smurfs"
  for account in "${accounts[@]}"; do
    [ -n "$account" ] || continue
    game="${account%%#*}"
    tag="${account#*#}"
    fetch_account "$api_key" "$game" "$tag"
  done
}

main() {
  echo "$(date -Is) riot-stats-update: updating every ${UPDATE_INTERVAL_SECS}s"
  while true; do
    fetch_patch_notes
    fetch_all
    sleep "$UPDATE_INTERVAL_SECS"
  done
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  main
fi
