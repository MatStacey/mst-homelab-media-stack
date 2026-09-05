#!/usr/bin/env bash
# Shared helpers sourced by every scripts/lib/<service>.sh file and by
# setup.sh itself. Nothing in here talks to a specific service - it's just
# logging, config loading, HTTP/file polling, and the docker-exec-curl
# wrapper every service script builds on.

# LIB_DIR/CONFIG_FILE are set by setup.sh before sourcing this file.
PY="python3 $LIB_DIR/api.py"

log()  { echo "==> $*"; }
warn() { echo "!!  $*" >&2; }
die()  { echo "xx  $*" >&2; exit 1; }

# Load scripts/config/stack.yaml into STACK_* shell variables (e.g.
# services.sonarr.port -> $STACK_SERVICES_SONARR_PORT). Must run before any
# lib file references those variables.
load_stack_config() {
  local exports
  exports="$($PY yaml-to-env "$CONFIG_FILE")" || die "Failed to parse $CONFIG_FILE (is PyYAML installed? pip install -r scripts/requirements.txt)"
  eval "$exports"
}

# Run curl inside a container (most services aren't published to the host).
cin() { local container="$1"; shift; docker exec "$container" curl -s "$@"; }

# Poll COMMAND (a command and its args) every 3s, logging DESC, until it
# exits 0 or TIMEOUT seconds pass. Warns and returns 1 on timeout. Shared by
# wait_for_http/wait_for_jellyseerr/wait_for_file so the poll/timeout logic
# exists in one place.
_poll_until() {
  local desc="$1" timeout="$2"; shift 2
  local waited=0
  log "Waiting for $desc..."
  until "$@" >/dev/null 2>&1; do
    sleep 3; waited=$((waited + 3))
    [ "$waited" -ge "$timeout" ] && { warn "$desc did not become ready within ${timeout}s"; return 1; }
  done
}

wait_for_http() {
  local desc="$1" container="$2" url="$3" timeout="${4:-120}"; shift 4 || true
  _poll_until "$desc" "$timeout" docker exec "$container" curl -sf "$@" "$url"
}

# jellyseerr's image has no curl, so check it by relaying through sonarr (same docker network).
wait_for_jellyseerr() {
  local timeout="${1:-120}"
  _poll_until "Jellyseerr" "$timeout" cin sonarr -sf "http://jellyseerr:$STACK_SERVICES_JELLYSEERR_PORT/api/v1/status"
}

wait_for_file() {
  local desc="$1" path="$2" timeout="${3:-120}"
  _poll_until "$desc" "$timeout" test -s "$path"
}

servarr_apikey() { grep -oE '<ApiKey>[^<]+' "$1" | cut -d'>' -f2; }

# Copy local file LOCAL_PATH into CONTAINER at CONTAINER_PATH, then delete
# the local temp copy. Used for payloads too large/complex for a single -d flag.
_docker_cp_and_remove_local() {
  local local_path="$1" container="$2" container_path="$3"
  docker cp "$local_path" "$container:$container_path" >/dev/null
  rm -f "$local_path"
}

# Best-effort delete of CONTAINER_PATH inside CONTAINER (e.g. a payload temp
# file after use) - never fails the caller even if the container is gone.
_docker_rm_in_container() {
  docker exec "$1" rm -f "$2" 2>/dev/null || true
}
