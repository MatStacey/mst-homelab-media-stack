#!/usr/bin/env bash
# First-run configuration for the media stack: brings the stack up, then wires
# together Sonarr/Radarr/Prowlarr/Bazarr/qBittorrent/Jellyfin/Jellyseerr via
# their REST APIs (same steps you'd otherwise click through in each web UI).
#
# Safe to re-run: every step checks current state first and skips anything
# already configured.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR/.." || exit 1

log()  { echo "==> $*"; }
warn() { echo "!!  $*" >&2; }
die()  { echo "xx  $*" >&2; exit 1; }

command -v docker >/dev/null || die "docker is required"
command -v python3 >/dev/null || die "python3 is required (used to parse API responses)"
docker compose version >/dev/null 2>&1 || die "docker compose plugin is required"

[ -f .env ] || die "No .env found. Run: cp .env.example .env, fill in TZ, then re-run this script."
set -a
# shellcheck disable=SC1091
source .env
set +a

# --- credentials: use .env if set, otherwise prompt (never written back to .env) ---
if [ -z "${ADMIN_USERNAME:-}" ]; then
  read -rp "Admin username to use for all service logins: " ADMIN_USERNAME
fi
if [ -z "${ADMIN_PASSWORD:-}" ]; then
  read -rsp "Admin password to use for all service logins: " ADMIN_PASSWORD
  echo
fi
[ -n "$ADMIN_USERNAME" ] && [ -n "$ADMIN_PASSWORD" ] || die "Username and password are both required."
# these get embedded into JSON payloads below; quotes/backslashes would corrupt them
case "$ADMIN_USERNAME$ADMIN_PASSWORD" in
  *'"'*|*'\'*) die 'Username/password must not contain " or \ characters (they get embedded in JSON API calls).' ;;
esac

# --- indexers: .env value wins; unset falls back to this curated list; explicitly empty means "none" ---
DEFAULT_INDEXERS="YTS,Knaben,1337x,EZTV,The Pirate Bay"
PROWLARR_INDEXERS="${PROWLARR_INDEXERS-$DEFAULT_INDEXERS}"

MOVIES_PATH="/data/media/movies"
TV_PATH="/data/media/tv"

# ---------------------------------------------------------------------------
# generic helpers
# ---------------------------------------------------------------------------

# run curl inside a container (most services aren't published to the host)
cin() { local container="$1"; shift; docker exec "$container" curl -s "$@"; }

# pull one field out of a JSON blob on stdin, python expression referencing `d`
jf() { python3 -c "
import json,sys
d=json.load(sys.stdin)
print($1)
"; }

wait_for_http() {
  local desc="$1" container="$2" url="$3" timeout="${4:-120}"; shift 4 || true
  local waited=0
  log "Waiting for $desc..."
  until docker exec "$container" curl -sf "$@" "$url" >/dev/null 2>&1; do
    sleep 3; waited=$((waited + 3))
    [ "$waited" -ge "$timeout" ] && { warn "$desc did not become reachable within ${timeout}s"; return 1; }
  done
}

# jellyseerr's image has no curl, so check it by relaying through sonarr (same docker network)
wait_for_jellyseerr() {
  local timeout="${1:-120}" waited=0
  log "Waiting for Jellyseerr..."
  until cin sonarr -sf "http://jellyseerr:5055/api/v1/status" >/dev/null 2>&1; do
    sleep 3; waited=$((waited + 3))
    [ "$waited" -ge "$timeout" ] && { warn "Jellyseerr did not become reachable within ${timeout}s"; return 1; }
  done
}

wait_for_file() {
  local desc="$1" path="$2" timeout="${3:-120}" waited=0
  log "Waiting for $desc..."
  until [ -s "$path" ]; do
    sleep 3; waited=$((waited + 3))
    [ "$waited" -ge "$timeout" ] && { warn "$desc never appeared at $path"; return 1; }
  done
}

servarr_apikey() { grep -oE '<ApiKey>[^<]+' "config/$1/config.xml" | cut -d'>' -f2; }

# ---------------------------------------------------------------------------
log "Bringing up the stack..."
docker compose up -d

wait_for_file "Sonarr config" "config/sonarr/config.xml"
wait_for_file "Radarr config" "config/radarr/config.xml"
wait_for_file "Prowlarr config" "config/prowlarr/config.xml"
wait_for_file "Bazarr config" "config/bazarr/config/config.yaml"

SONARR_KEY="$(servarr_apikey sonarr)"
RADARR_KEY="$(servarr_apikey radarr)"
PROWLARR_KEY="$(servarr_apikey prowlarr)"
BAZARR_KEY="$(grep -A3 '^auth:' config/bazarr/config/config.yaml | grep 'apikey:' | sed -E 's/.*apikey: *//')"

wait_for_http "Sonarr API" sonarr "http://localhost:8989/api/v3/system/status?apikey=$SONARR_KEY"
wait_for_http "Radarr API" radarr "http://localhost:7878/api/v3/system/status?apikey=$RADARR_KEY"
wait_for_http "Prowlarr API" prowlarr "http://localhost:9696/api/v1/system/status?apikey=$PROWLARR_KEY"
wait_for_http "Bazarr API" bazarr "http://localhost:6767/api/system/status" 120 -H "X-API-KEY: $BAZARR_KEY"

# ---------------------------------------------------------------------------
# Sonarr / Radarr: root folder, forms auth, qBittorrent download client
# ---------------------------------------------------------------------------
configure_servarr_auth() {
  local name="$1" container="$2" port="$3" apiver="$4" key="$5"
  local host_cfg current_user
  host_cfg="$(cin "$container" -H "X-Api-Key: $key" "http://localhost:$port/api/$apiver/config/host")"
  current_user="$(echo "$host_cfg" | jf "d.get('username','')")"
  if [ "$current_user" = "$ADMIN_USERNAME" ] && [ "$(echo "$host_cfg" | jf "d.get('authenticationMethod','')")" = "forms" ]; then
    log "$name: login already set for $ADMIN_USERNAME, skipping"
    return
  fi
  local id tmp
  id="$(echo "$host_cfg" | jf "d['id']")"
  tmp="$(mktemp)"
  echo "$host_cfg" | python3 -c "
import json,sys
d=json.load(sys.stdin)
d['authenticationMethod']='forms'
d['authenticationRequired']='enabled'
d['username']='$ADMIN_USERNAME'
d['password']='$ADMIN_PASSWORD'
d['passwordConfirmation']='$ADMIN_PASSWORD'
json.dump(d, sys.stdout)
" > "$tmp"
  docker cp "$tmp" "$container:/tmp/host.json" >/dev/null
  rm -f "$tmp"
  cin "$container" -X PUT -H "X-Api-Key: $key" -H "Content-Type: application/json" \
    "http://localhost:$port/api/$apiver/config/host/$id" --data @/tmp/host.json >/dev/null
  docker exec "$container" rm -f /tmp/host.json
  log "$name: login set for $ADMIN_USERNAME"
}

configure_servarr_rootfolder() {
  local name="$1" container="$2" port="$3" apiver="$4" key="$5" path="$6"
  local existing
  existing="$(cin "$container" -H "X-Api-Key: $key" "http://localhost:$port/api/$apiver/rootfolder" | jf "'yes' if any(x['path']=='$path' for x in d) else 'no'")"
  if [ "$existing" = "yes" ]; then
    log "$name: root folder $path already present, skipping"
  else
    cin "$container" -X POST -H "X-Api-Key: $key" -H "Content-Type: application/json" \
      "http://localhost:$port/api/$apiver/rootfolder" -d "{\"path\":\"$path\"}" >/dev/null
    log "$name: added root folder $path"
  fi
}

configure_servarr_downloadclient() {
  local name="$1" container="$2" port="$3" apiver="$4" key="$5" category="$6"
  local existing
  existing="$(cin "$container" -H "X-Api-Key: $key" "http://localhost:$port/api/$apiver/downloadclient" | jf "'yes' if any(x['implementation']=='QBittorrent' for x in d) else 'no'")"
  if [ "$existing" = "yes" ]; then
    log "$name: qBittorrent download client already present, skipping"
    return
  fi
  local cat_field="tvCategory"
  [ "$category" = "movies-radarr" ] && cat_field="movieCategory"
  cin "$container" -X POST -H "X-Api-Key: $key" -H "Content-Type: application/json" \
    "http://localhost:$port/api/$apiver/downloadclient" -d "{
      \"enable\": true, \"protocol\": \"torrent\", \"priority\": 1,
      \"removeCompletedDownloads\": true, \"removeFailedDownloads\": true,
      \"name\": \"qBittorrent\", \"implementation\": \"QBittorrent\", \"configContract\": \"QBittorrentSettings\",
      \"fields\": [
        {\"name\":\"host\",\"value\":\"qbittorrent\"}, {\"name\":\"port\",\"value\":8080},
        {\"name\":\"useSsl\",\"value\":false}, {\"name\":\"username\",\"value\":\"$ADMIN_USERNAME\"},
        {\"name\":\"password\",\"value\":\"$ADMIN_PASSWORD\"}, {\"name\":\"$cat_field\",\"value\":\"$category\"},
        {\"name\":\"initialState\",\"value\":0}
      ]}" >/dev/null
  log "$name: added qBittorrent download client (category: $category)"
}

log "Configuring Sonarr..."
configure_servarr_auth        "Sonarr" sonarr 8989 v3 "$SONARR_KEY"
configure_servarr_rootfolder  "Sonarr" sonarr 8989 v3 "$SONARR_KEY" "$TV_PATH"
configure_servarr_downloadclient "Sonarr" sonarr 8989 v3 "$SONARR_KEY" "tv-sonarr"

log "Configuring Radarr..."
configure_servarr_auth        "Radarr" radarr 7878 v3 "$RADARR_KEY"
configure_servarr_rootfolder  "Radarr" radarr 7878 v3 "$RADARR_KEY" "$MOVIES_PATH"
configure_servarr_downloadclient "Radarr" radarr 7878 v3 "$RADARR_KEY" "movies-radarr"

# ---------------------------------------------------------------------------
# Prowlarr: forms auth, indexers, app sync to Sonarr/Radarr
# ---------------------------------------------------------------------------
log "Configuring Prowlarr..."
configure_servarr_auth "Prowlarr" prowlarr 9696 v1 "$PROWLARR_KEY"

if [ -z "$PROWLARR_INDEXERS" ]; then
  log "Prowlarr: PROWLARR_INDEXERS is empty, skipping indexer setup"
else
  APP_PROFILE_ID="$(cin prowlarr -H "X-Api-Key: $PROWLARR_KEY" "http://localhost:9696/api/v1/appprofile" | jf "d[0]['id']")"
  SCHEMA_JSON="$(mktemp)"
  cin prowlarr -H "X-Api-Key: $PROWLARR_KEY" "http://localhost:9696/api/v1/indexer/schema" > "$SCHEMA_JSON"
  EXISTING_JSON="$(mktemp)"
  cin prowlarr -H "X-Api-Key: $PROWLARR_KEY" "http://localhost:9696/api/v1/indexer" > "$EXISTING_JSON"

  IFS=',' read -ra INDEXER_LIST <<< "$PROWLARR_INDEXERS"
  for raw_name in "${INDEXER_LIST[@]}"; do
    name="$(echo "$raw_name" | sed 's/^ *//;s/ *$//')"
    [ -z "$name" ] && continue

    already="$(python3 -c "
import json
existing = json.load(open('$EXISTING_JSON'))
print('yes' if any(x['name']=='$name' for x in existing) else 'no')
")"
    if [ "$already" = "yes" ]; then
      log "Prowlarr: indexer '$name' already added, skipping"
      continue
    fi

    payload="$(mktemp)"
    found="$(python3 -c "
import json
schema = json.load(open('$SCHEMA_JSON'))
entry = next((c for c in schema if c['name']=='$name'), None)
if entry is None:
    print('no')
else:
    payload = json.loads(json.dumps(entry))
    payload['appProfileId'] = $APP_PROFILE_ID
    base_url = entry['indexerUrls'][0]
    for f in payload['fields']:
        if f['name']=='baseUrl':
            f['value'] = base_url
    json.dump(payload, open('$payload', 'w'))
    print('yes')
")"
    if [ "$found" != "yes" ]; then
      warn "Prowlarr: '$name' is not a known indexer name, skipping"
      rm -f "$payload"
      continue
    fi

    docker cp "$payload" prowlarr:/tmp/idx.json >/dev/null
    rm -f "$payload"
    result="$(cin prowlarr -X POST -H "X-Api-Key: $PROWLARR_KEY" -H "Content-Type: application/json" \
      "http://localhost:9696/api/v1/indexer" --data @/tmp/idx.json)"
    if echo "$result" | python3 -c "import json,sys; d=json.load(sys.stdin); sys.exit(0 if isinstance(d,dict) and 'id' in d else 1)" 2>/dev/null; then
      log "Prowlarr: added indexer '$name'"
    else
      warn "Prowlarr: could not connect to '$name' (site may be unreachable from this network) - skipped"
    fi
  done
  docker exec prowlarr rm -f /tmp/idx.json 2>/dev/null || true
  rm -f "$SCHEMA_JSON" "$EXISTING_JSON"
fi

configure_prowlarr_app() {
  local app_name="$1" impl="$2" contract="$3" base_url="$4" key="$5" categories="$6"
  local existing
  existing="$(cin prowlarr -H "X-Api-Key: $PROWLARR_KEY" "http://localhost:9696/api/v1/applications" | jf "'yes' if any(x['name']=='$app_name' for x in d) else 'no'")"
  if [ "$existing" = "yes" ]; then
    log "Prowlarr: app sync for $app_name already configured, skipping"
    return
  fi
  cin prowlarr -X POST -H "X-Api-Key: $PROWLARR_KEY" -H "Content-Type: application/json" \
    "http://localhost:9696/api/v1/applications" -d "{
      \"name\": \"$app_name\", \"implementation\": \"$impl\", \"configContract\": \"$contract\", \"syncLevel\": \"fullSync\",
      \"fields\": [
        {\"name\":\"prowlarrUrl\",\"value\":\"http://prowlarr:9696\"},
        {\"name\":\"baseUrl\",\"value\":\"$base_url\"},
        {\"name\":\"apiKey\",\"value\":\"$key\"},
        {\"name\":\"syncCategories\",\"value\":$categories}
      ]}" >/dev/null
  log "Prowlarr: synced app $app_name"
}

configure_prowlarr_app "Sonarr" "Sonarr" "SonarrSettings" "http://sonarr:8989" "$SONARR_KEY" "[5000,5030,5040,5045,5070,5080]"
configure_prowlarr_app "Radarr" "Radarr" "RadarrSettings" "http://radarr:7878" "$RADARR_KEY" "[2000,2010,2030,2040,2045,2060,2070]"
cin prowlarr -X POST -H "X-Api-Key: $PROWLARR_KEY" -H "Content-Type: application/json" \
  "http://localhost:9696/api/v1/command" -d '{"name":"ApplicationIndexerSync"}' >/dev/null

# ---------------------------------------------------------------------------
# qBittorrent: permanent WebUI login (replaces the rotating temp password)
# ---------------------------------------------------------------------------
log "Configuring qBittorrent..."
QBT_COOKIES="$(mktemp)"
already_ok="$(curl -s -c "$QBT_COOKIES" -X POST "http://localhost:8080/api/v2/auth/login" \
  -H "Referer: http://localhost:8080" --data "username=${ADMIN_USERNAME}&password=${ADMIN_PASSWORD}" -w '%{http_code}' -o /dev/null)"
if [ "$already_ok" = "200" ] || [ "$already_ok" = "204" ]; then
  log "qBittorrent: login already set for $ADMIN_USERNAME, skipping"
else
  TEMP_PW="$(docker logs qbittorrent 2>&1 | grep -i "temporary password" | tail -1 | grep -oE '[^ ]+$')"
  if [ -z "$TEMP_PW" ]; then
    warn "qBittorrent: could not find a temporary password in logs; if this isn't a fresh container, log in and change the password by hand."
  else
    ok=""
    for _ in 1 2 3; do
      code="$(curl -s -c "$QBT_COOKIES" -X POST "http://localhost:8080/api/v2/auth/login" \
        -H "Referer: http://localhost:8080" --data "username=admin&password=${TEMP_PW}" -w '%{http_code}' -o /dev/null)"
      { [ "$code" = "200" ] || [ "$code" = "204" ]; } && { ok=1; break; }
      TEMP_PW="$(docker logs qbittorrent 2>&1 | grep -i "temporary password" | tail -1 | grep -oE '[^ ]+$')"
      sleep 1
    done
    if [ -n "$ok" ]; then
      curl -s -b "$QBT_COOKIES" -X POST "http://localhost:8080/api/v2/app/setPreferences" \
        --data-urlencode "json={\"web_ui_username\":\"$ADMIN_USERNAME\",\"web_ui_password\":\"$ADMIN_PASSWORD\"}" >/dev/null
      log "qBittorrent: login set for $ADMIN_USERNAME"
    else
      warn "qBittorrent: could not log in with the temporary password from the logs - set the WebUI login manually."
    fi
  fi
fi
rm -f "$QBT_COOKIES"

# ---------------------------------------------------------------------------
# Bazarr: forms auth, Sonarr/Radarr connection, English subtitle profile
# ---------------------------------------------------------------------------
log "Configuring Bazarr..."
BZ_SETTINGS="$(cin bazarr -H "X-API-KEY: $BAZARR_KEY" "http://localhost:6767/api/system/settings")"
bz_needs_auth="$(echo "$BZ_SETTINGS" | jf "'no' if d['auth']['type']=='form' and d['auth']['username']=='$ADMIN_USERNAME' else 'yes'")"
bz_needs_links="$(echo "$BZ_SETTINGS" | jf "'no' if d['general']['use_sonarr'] and d['general']['use_radarr'] else 'yes'")"

if [ "$bz_needs_auth" = "no" ] && [ "$bz_needs_links" = "no" ]; then
  log "Bazarr: already configured, skipping"
else
  LANG_PROFILES='[{"profileId":1,"name":"English","cutoff":null,"items":[{"id":1,"language":"en","forced":"False","hi":"False","audio_exclude":"False","audio_only_include":"False"}],"mustContain":[],"mustNotContain":[],"originalFormat":null,"tag":null}]'
  cin bazarr -X POST "http://localhost:6767/api/system/settings" -H "X-API-KEY: $BAZARR_KEY" \
    --data-urlencode "languages-enabled=en" \
    --data-urlencode "languages-profiles=${LANG_PROFILES}" \
    --data-urlencode "settings-general-use_sonarr=true" \
    --data-urlencode "settings-general-use_radarr=true" \
    --data-urlencode "settings-general-serie_default_enabled=true" \
    --data-urlencode "settings-general-serie_default_profile=1" \
    --data-urlencode "settings-general-movie_default_enabled=true" \
    --data-urlencode "settings-general-movie_default_profile=1" \
    --data-urlencode "settings-sonarr-ip=sonarr" \
    --data-urlencode "settings-sonarr-port=8989" \
    --data-urlencode "settings-sonarr-apikey=${SONARR_KEY}" \
    --data-urlencode "settings-sonarr-base_url=/" \
    --data-urlencode "settings-radarr-ip=radarr" \
    --data-urlencode "settings-radarr-port=7878" \
    --data-urlencode "settings-radarr-apikey=${RADARR_KEY}" \
    --data-urlencode "settings-radarr-base_url=/" \
    --data-urlencode "settings-auth-type=form" \
    --data-urlencode "settings-auth-username=${ADMIN_USERNAME}" \
    --data-urlencode "settings-auth-password=${ADMIN_PASSWORD}" >/dev/null
  log "Bazarr: configured (Sonarr/Radarr link, English subtitles, login for $ADMIN_USERNAME)"
  if [ "$bz_needs_auth" = "yes" ]; then
    log "Bazarr: restarting so the new login takes effect..."
    docker restart bazarr >/dev/null
    wait_for_http "Bazarr API" bazarr "http://localhost:6767/api/system/status" 60 -H "X-API-KEY: $BAZARR_KEY"
  fi
fi

# ---------------------------------------------------------------------------
# Jellyfin: startup wizard + admin user + libraries
# ---------------------------------------------------------------------------
log "Configuring Jellyfin..."
wait_for_http "Jellyfin" jellyfin "http://localhost:8096/System/Info/Public"
JF_PUBLIC="$(cin jellyfin "http://localhost:8096/System/Info/Public")"
if [ "$(echo "$JF_PUBLIC" | jf "d['StartupWizardCompleted']")" = "False" ]; then
  cin jellyfin -X POST "http://localhost:8096/Startup/Configuration" -H "Content-Type: application/json" \
    -d '{"ServerName":"Jellyfin","UICulture":"en-US","MetadataCountryCode":"US","PreferredMetadataLanguage":"en"}' >/dev/null
  cin jellyfin -X POST "http://localhost:8096/Startup/User" -H "Content-Type: application/json" \
    -d "{\"Name\":\"$ADMIN_USERNAME\",\"Password\":\"$ADMIN_PASSWORD\"}" >/dev/null
  cin jellyfin -X POST "http://localhost:8096/Startup/RemoteAccess" -H "Content-Type: application/json" \
    -d '{"EnableRemoteAccess":true,"EnableAutomaticPortMapping":false}' >/dev/null
  cin jellyfin -X POST "http://localhost:8096/Startup/Complete" >/dev/null
  log "Jellyfin: startup wizard completed, admin user $ADMIN_USERNAME created"
else
  log "Jellyfin: startup wizard already completed, skipping"
fi

JF_AUTH="$(cin jellyfin -X POST "http://localhost:8096/Users/AuthenticateByName" \
  -H "Content-Type: application/json" \
  -H 'X-Emby-Authorization: MediaBrowser Client="setup.sh", Device="setup.sh", DeviceId="setup-script", Version="1.0.0"' \
  -d "{\"Username\":\"$ADMIN_USERNAME\",\"Pw\":\"$ADMIN_PASSWORD\"}")"
JF_TOKEN="$(echo "$JF_AUTH" | jf "d.get('AccessToken','')" 2>/dev/null || true)"

if [ -z "$JF_TOKEN" ]; then
  warn "Jellyfin: could not log in as $ADMIN_USERNAME (wizard may have been completed earlier with different credentials) - skipping library setup"
else
  add_jellyfin_library() {
    local jf_name="$1" collection_type="$2" path="$3"
    local existing
    existing="$(cin jellyfin -H "X-Emby-Token: $JF_TOKEN" "http://localhost:8096/Library/VirtualFolders" | jf "'yes' if any('$path' in x['Locations'] for x in d) else 'no'")"
    if [ "$existing" = "yes" ]; then
      log "Jellyfin: library for $path already present, skipping"
      return
    fi
    cin jellyfin -X POST "http://localhost:8096/Library/VirtualFolders?name=$(python3 -c "import urllib.parse;print(urllib.parse.quote('$jf_name'))")&collectionType=$collection_type&refreshLibrary=false" \
      -H "X-Emby-Token: $JF_TOKEN" -H "Content-Type: application/json" \
      -d "{\"LibraryOptions\":{\"PathInfos\":[{\"Path\":\"$path\"}],\"EnablePhotos\":false}}" >/dev/null
    log "Jellyfin: added '$jf_name' library ($path)"
  }
  add_jellyfin_library "Movies" "movies" "$MOVIES_PATH"
  add_jellyfin_library "TV Shows" "tvshows" "$TV_PATH"
  cin jellyfin -X POST "http://localhost:8096/Library/Refresh" -H "X-Emby-Token: $JF_TOKEN" >/dev/null
fi

# ---------------------------------------------------------------------------
# Jellyseerr: bootstrap admin via Jellyfin login, connect Sonarr/Radarr
# ---------------------------------------------------------------------------
log "Configuring Jellyseerr..."
wait_for_jellyseerr

# initial call configures the Jellyfin connection (fails harmlessly if already set)
cin sonarr -s -X POST "http://jellyseerr:5055/api/v1/auth/jellyfin" -H "Content-Type: application/json" \
  -d "{\"username\":\"$ADMIN_USERNAME\",\"password\":\"$ADMIN_PASSWORD\",\"hostname\":\"jellyfin\",\"port\":8096,\"useSsl\":false,\"urlBase\":\"\",\"email\":\"${ADMIN_USERNAME}@homelab.lan\",\"serverType\":2}" >/dev/null 2>&1 || true

JS_COOKIES="/tmp/setup-js-cookies.txt"
js_login_code="$(cin sonarr -c "$JS_COOKIES" -X POST "http://jellyseerr:5055/api/v1/auth/jellyfin" \
  -H "Content-Type: application/json" -d "{\"username\":\"$ADMIN_USERNAME\",\"password\":\"$ADMIN_PASSWORD\"}" -o /dev/null -w '%{http_code}')"

if [ "$js_login_code" != "200" ]; then
  warn "Jellyseerr: could not sign in as $ADMIN_USERNAME (mediaServerType may already be set to something else) - skipping"
else
  find_quality_profile_id() {
    local key="$1" port="$2" apiver="$3" container="$4"
    cin "$container" -H "X-Api-Key: $key" "http://localhost:$port/api/$apiver/qualityprofile" | python3 -c "
import json,sys
d=json.load(sys.stdin)
preferred=[p for p in d if p['name']=='HD - 720p/1080p']
print((preferred or d)[0]['id'])
"
  }

  link_jellyseerr_app() {
    local kind="$1" hostname="$2" port="$3" key="$4" path="$5" extra="$6"
    local already
    already="$(cin sonarr -b "$JS_COOKIES" "http://jellyseerr:5055/api/v1/settings/$kind" | jf "'yes' if any(x['hostname']=='$hostname' for x in d) else 'no'")"
    if [ "$already" = "yes" ]; then
      log "Jellyseerr: $kind already connected, skipping"
      return
    fi
    local qp
    if [ "$kind" = "sonarr" ]; then
      qp="$(find_quality_profile_id "$SONARR_KEY" 8989 v3 sonarr)"
    else
      qp="$(find_quality_profile_id "$RADARR_KEY" 7878 v3 radarr)"
    fi
    cin sonarr -b "$JS_COOKIES" -X POST "http://jellyseerr:5055/api/v1/settings/$kind" -H "Content-Type: application/json" -d "{
      \"name\": \"${kind^}\", \"hostname\": \"$hostname\", \"port\": $port, \"apiKey\": \"$key\",
      \"useSsl\": false, \"baseUrl\": \"\", \"activeProfileId\": $qp, \"activeDirectory\": \"$path\",
      \"is4k\": false, \"isDefault\": true, \"externalUrl\": \"\", \"syncEnabled\": true,
      \"preventSearch\": false, \"tagRequests\": false $extra}" >/dev/null
    log "Jellyseerr: connected to $kind"
  }
  link_jellyseerr_app sonarr sonarr 8989 "$SONARR_KEY" "$TV_PATH" ', "enableSeasonFolders": true, "activeLanguageProfileId": 1'
  link_jellyseerr_app radarr radarr 7878 "$RADARR_KEY" "$MOVIES_PATH" ', "minimumAvailability": "released"'
fi
docker exec sonarr rm -f "$JS_COOKIES" 2>/dev/null || true

log "Done. Services (once your hosts file / DNS resolves *.media.lan to this machine):"
for h in sonarr radarr prowlarr bazarr jellyfin jellyseerr qbittorrent; do
  echo "  - http://$h.media.lan"
done
log "Login for Sonarr/Radarr/Prowlarr/Bazarr/qBittorrent/Jellyfin: $ADMIN_USERNAME / (the password you provided)"
