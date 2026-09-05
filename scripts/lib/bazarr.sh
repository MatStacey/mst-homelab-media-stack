#!/usr/bin/env bash
# Bazarr: connect to Sonarr/Radarr, set an English subtitle profile as the
# default for both, and enable forms-based web UI login.
#
# Bazarr's settings API is a plain Flask form POST, not JSON: every field
# name must be prefixed "settings-<section>-<key>" (e.g.
# "settings-general-use_sonarr"), and booleans must be the lowercase string
# literals "true"/"false" - "True"/"False" fail Bazarr's own type validation.
# Auth changes only take effect after a container restart.

configure_bazarr() {
  local base_url="http://localhost:$STACK_SERVICES_BAZARR_PORT"
  log "Configuring Bazarr..."

  local settings needs_auth needs_links
  settings="$(cin bazarr -H "X-API-KEY: $BAZARR_KEY" "$base_url/api/system/settings")"
  read -r needs_auth needs_links <<< "$(echo "$settings" | $PY bazarr-needs-setup "$ADMIN_USERNAME")"

  if [ "$needs_auth" = "no" ] && [ "$needs_links" = "no" ]; then
    log "Bazarr: already configured, skipping"
    return
  fi

  local lang_profiles
  lang_profiles="$(cat "$SCRIPT_DIR/config/bazarr-language-profile.json")"

  cin bazarr -X POST "$base_url/api/system/settings" -H "X-API-KEY: $BAZARR_KEY" \
    --data-urlencode "languages-enabled=en" \
    --data-urlencode "languages-profiles=${lang_profiles}" \
    --data-urlencode "settings-general-use_sonarr=true" \
    --data-urlencode "settings-general-use_radarr=true" \
    --data-urlencode "settings-general-serie_default_enabled=true" \
    --data-urlencode "settings-general-serie_default_profile=1" \
    --data-urlencode "settings-general-movie_default_enabled=true" \
    --data-urlencode "settings-general-movie_default_profile=1" \
    --data-urlencode "settings-sonarr-ip=sonarr" \
    --data-urlencode "settings-sonarr-port=$STACK_SERVICES_SONARR_PORT" \
    --data-urlencode "settings-sonarr-apikey=${SONARR_KEY}" \
    --data-urlencode "settings-sonarr-base_url=/" \
    --data-urlencode "settings-radarr-ip=radarr" \
    --data-urlencode "settings-radarr-port=$STACK_SERVICES_RADARR_PORT" \
    --data-urlencode "settings-radarr-apikey=${RADARR_KEY}" \
    --data-urlencode "settings-radarr-base_url=/" \
    --data-urlencode "settings-auth-type=form" \
    --data-urlencode "settings-auth-username=${ADMIN_USERNAME}" \
    --data-urlencode "settings-auth-password=${ADMIN_PASSWORD}" >/dev/null
  log "Bazarr: configured (Sonarr/Radarr link, English subtitles, login for $ADMIN_USERNAME)"

  if [ "$needs_auth" = "yes" ]; then
    log "Bazarr: restarting so the new login takes effect..."
    docker restart bazarr >/dev/null
    wait_for_http "Bazarr API" bazarr "$base_url/api/system/status" 60 -H "X-API-KEY: $BAZARR_KEY"
  fi
}
