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
PATCH_NOTES_BASE_URL="https://www.leagueoflegends.com"
PATCH_NOTES_URL="${PATCH_NOTES_BASE_URL}/en-gb/news/tags/patch-notes/"
PATCH_NOTES_OUTPUT_FILE="${STATS_OUTPUT_DIR}/lol-patch-notes.json"
PATCH_NOTES_HTML_FILE="${STATS_OUTPUT_DIR}/lol-patch-notes.html"
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

# Finds the latest patch's article path/title/publish date from the
# patch-notes tag page's embedded article list.
find_latest_patch_article() {
  local tag_page
  tag_page="$(curl -sfL -A "$USER_AGENT" "$PATCH_NOTES_URL")" \
    || { echo "$(date -Is) riot-stats-update: patch notes index fetch failed" >&2; return 1; }

  echo "$tag_page" | python3 -c '
import datetime, json, re, sys

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

json.dump({
    "patch": re.search(r"Patch ([\w.]+) Notes", latest["title"]).group(1),
    "published": published.strftime("%d %b %Y"),
    "path": latest["action"]["payload"]["url"],
}, sys.stdout)
'
}

# Fetches the full patch notes article, mirrors it as a standalone page
# (BADGE_OUTPUT_DIR-style static file Caddy serves), and writes a longer
# plain-text excerpt into the stats JSON for the widget's Summary field.
fetch_patch_notes() {
  local article_json patch published article_path article_url
  article_json="$(find_latest_patch_article)" \
    || { echo "$(date -Is) riot-stats-update: patch notes not found on index page" >&2; return 1; }
  patch="$(echo "$article_json" | jq -r .patch)"
  published="$(echo "$article_json" | jq -r .published)"
  article_path="$(echo "$article_json" | jq -r .path)"
  article_url="${PATCH_NOTES_BASE_URL}${article_path}"

  local article_page
  article_page="$(curl -sfL -A "$USER_AGENT" "$article_url")" \
    || { echo "$(date -Is) riot-stats-update: patch notes article fetch failed ($article_url)" >&2; return 1; }

  local html_tmp="${PATCH_NOTES_HTML_FILE}.tmp" json_tmp="${PATCH_NOTES_OUTPUT_FILE}.tmp"
  echo "$article_page" | python3 -c '
import html, json, re, sys

patch, published, article_url, html_out, json_out = sys.argv[1:6]
page = sys.stdin.read()

next_data = re.search(r"<script id=\"__NEXT_DATA__\"[^>]*>(.*?)</script>", page, re.S)
if next_data is None:
    sys.exit(1)
blades = json.loads(next_data.group(1))["props"]["pageProps"]["page"]["blades"]
rich = next((b for b in blades if b.get("type") == "patchNotesRichText"), None)
if rich is None:
    sys.exit(1)
body = rich["richText"]["body"]

summary = ""
intro = re.search(r"<blockquote class=\"blockquote context\">.*?<p>(.*?)</p>", body, re.S)
if intro:
    summary = re.sub(r"<[^>]+>", "", html.unescape(intro.group(1))).strip()
    summary = re.sub(r"\s+", " ", summary)
    if len(summary) > 500:
        summary = summary[:500].rsplit(" ", 1)[0] + "…"

page_html = """<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<title>Patch {patch} Notes</title>
<meta name="viewport" content="width=device-width, initial-scale=1">
<style>
  body {{ background: #101418; color: #e6e6e6; font-family: system-ui, sans-serif; max-width: 900px; margin: 0 auto; padding: 24px 16px 64px; line-height: 1.5; }}
  h1 {{ font-size: 1.6rem; }}
  a {{ color: #7dd3fc; }}
  img {{ max-width: 100%; height: auto; }}
  blockquote {{ border-left: 3px solid #334155; margin: 0; padding: 8px 16px; background: #1a2028; }}
</style>
</head>
<body>
<h1>League of Legends Patch {patch} Notes</h1>
<p><a href="{article_url}">View on leagueoflegends.com</a> &middot; Released {published}</p>
{body}
</body>
</html>
""".format(patch=patch, published=published, article_url=article_url, body=body)

with open(html_out, "w") as f:
    f.write(page_html)

with open(json_out, "w") as f:
    json.dump({"patch": patch, "published": published, "summary": summary}, f)
' "$patch" "$published" "$article_url" "$html_tmp" "$json_tmp" \
    || { rm -f "$html_tmp" "$json_tmp"; echo "$(date -Is) riot-stats-update: patch notes article body not found ($article_url)" >&2; return 1; }

  mv "$html_tmp" "$PATCH_NOTES_HTML_FILE"
  mv "$json_tmp" "$PATCH_NOTES_OUTPUT_FILE"
  echo "$(date -Is) riot-stats-update: wrote $PATCH_NOTES_OUTPUT_FILE and $PATCH_NOTES_HTML_FILE"
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
