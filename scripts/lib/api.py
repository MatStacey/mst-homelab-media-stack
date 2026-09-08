#!/usr/bin/env python3
"""JSON/YAML helpers for scripts/setup.sh.

Every subcommand here replaces an inline `python3 -c "..."` heredoc that used
to live directly in setup.sh. Keeping them in one file (instead of scattered
bash heredocs) means:
  - arguments are passed as real argv/stdin, not interpolated into a source
    string (the old approach broke, or worse silently miscompiled, if a
    value contained a quote or backslash)
  - each transformation is unit-testable and has one place to fix bugs
  - setup.sh's bash stays about "what to call", not "how to parse JSON"

Usage: python3 api.py <subcommand> [args...]  (see each function's docstring)
"""

import argparse
import json
import sys
import urllib.parse
from collections.abc import Callable
from dataclasses import dataclass, field

# Boolean-ish results are printed as these literal strings, not True/False,
# because the caller is always bash (scripts/lib/*.sh), which reads stdout
# with `[ "$result" = "yes" ]`. Defined once here so every subcommand agrees
# on the exact spelling.
YES = "yes"
NO = "no"


def _load_stdin_json():
    return json.load(sys.stdin)


@dataclass
class JsonObjectResult:
    """Outcome of trying to read a JSON object from stdin: exactly one of
    `value`/`error` is set. `error` covers both failure modes - malformed
    JSON and valid JSON that isn't an object - so a caller needs exactly one
    guard (`if result.error`) instead of a parse-error check followed by a
    separate isinstance check.
    """

    value: dict | None = None
    error: str | None = None


def _read_stdin_json_object():
    """Parse stdin as JSON and require the result to be an object (dict).

    Used by subcommands that read live HTTP response bodies which can
    legitimately come back malformed (an error page, an empty body) or
    well-formed but not an object - unlike most subcommands here, which
    trust their input is already-valid JSON from a successful API call and
    let a parse failure crash loudly.
    """
    try:
        data = json.load(sys.stdin)
    except (json.JSONDecodeError, ValueError) as parse_error:
        return JsonObjectResult(error=f"could not parse JSON on stdin ({parse_error})")
    if not isinstance(data, dict):
        return JsonObjectResult(error=f"expected a JSON object on stdin, got {type(data).__name__}")
    return JsonObjectResult(value=data)


def _load_json_file(path):
    with open(path, encoding="utf-8") as json_file:
        return json.load(json_file)


def _parse_list_index(segment, length):
    """Return SEGMENT as a valid index into a list of LENGTH, or None if
    SEGMENT isn't an integer (optionally negative) or is out of range."""
    if not segment.removeprefix("-").isdigit():
        return None
    index = int(segment)
    if index < -length or index >= length:
        return None
    return index


def cmd_yaml_to_env(args):
    """Flatten a YAML file into `NAME=value` lines, one per scalar leaf.

    Nested keys join with underscores and get the given --prefix, e.g.
    services.sonarr.port -> STACK_SERVICES_SONARR_PORT=8989. Lists are
    emitted as a single comma-joined value. Consumed by
    scripts/lib/common.sh via `source <(...)`, so output must be valid,
    already-quoted-safe `NAME=value` shell assignment lines.
    """
    import yaml  # local import: only needed for this subcommand

    with open(args.path, encoding="utf-8") as yaml_file:
        yaml_document = yaml.safe_load(yaml_file)

    def shell_quote(value):
        return "'" + value.replace("'", "'\\''") + "'"

    def walk(value, env_var_name):
        if isinstance(value, dict):
            for key, child_value in value.items():
                walk(child_value, f"{env_var_name}_{key}".upper())
            return
        if isinstance(value, list):
            joined = ",".join(str(item) for item in value)
            print(f"{env_var_name}={shell_quote(joined)}")
            return
        print(f"{env_var_name}={shell_quote('' if value is None else str(value))}")

    walk(yaml_document, args.prefix)


def cmd_get_field(args):
    """Print one field from a JSON document on stdin, addressed by dotted PATH.

    PATH segments are dict keys or (if numeric) list indices, e.g.
    "username", "config.id", or "0.id". Prints an empty string if any
    segment is missing, rather than erroring - callers treat "" as "not
    set yet".
    """
    document = _load_stdin_json()
    current_value = document
    for segment in args.path.split("."):
        if not isinstance(current_value, (list, dict)):
            break

        if isinstance(current_value, dict):
            current_value = current_value.get(segment)
            continue

        list_index = _parse_list_index(segment, len(current_value))
        if list_index is None:
            current_value = None
            continue

        current_value = current_value[list_index]
    print("" if current_value is None else current_value)


def cmd_merge_host_auth(args):
    """Merge forms-auth fields into a Sonarr/Radarr/Prowlarr config/host payload.

    Reads the current config/host JSON from stdin, sets it to forms auth
    with the given username/password, and prints the full object back out
    ready to PUT. Requires passwordConfirmation to match Password or the
    *arr apps reject the update with 400.
    """
    host_config = _load_stdin_json()
    host_config["authenticationMethod"] = "forms"
    host_config["authenticationRequired"] = "enabled"
    host_config["username"] = args.username
    host_config["password"] = args.password
    host_config["passwordConfirmation"] = args.password
    json.dump(host_config, sys.stdout)


def cmd_merge_field(args):
    """Set one top-level FIELD to VALUE in a JSON document on stdin, and print
    the full object back out ready to PUT. Shared by any config that just
    needs one field changed in place without disturbing the rest (e.g. the
    *arr apps' config/host logLevel)."""
    document = _load_stdin_json()
    document[args.field] = args.value
    json.dump(document, sys.stdout)


def cmd_has_root_folder(args):
    """Print yes/no: does the rootfolder list on stdin already contain PATH?"""
    root_folders = _load_stdin_json()
    print(YES if any(folder["path"] == args.path for folder in root_folders) else NO)


def cmd_has_download_client(args):
    """Print yes/no: does the downloadclient list on stdin include IMPLEMENTATION?"""
    download_clients = _load_stdin_json()
    print(YES if any(client["implementation"] == args.implementation for client in download_clients) else NO)


def cmd_prowlarr_indexer_exists(args):
    """Print yes/no: is NAME already present in the indexer list at EXISTING_JSON."""
    existing_indexers = _load_json_file(args.existing_json)
    print(YES if any(indexer["name"] == args.name for indexer in existing_indexers) else NO)


def cmd_prowlarr_indexer_payload(args):
    """Build a Prowlarr "add indexer" payload for NAME from a schema dump.

    Looks NAME up in the indexer schema (SCHEMA_JSON, from GET
    /api/v1/indexer/schema), stamps in appProfileId and the schema's first
    known base URL, and prints the resulting payload JSON. Exits 1 with
    nothing on stdout if NAME isn't a recognised indexer.

    If --tag-id is given, the indexer is tagged with it - Prowlarr routes an
    indexer's requests through any indexer proxy (e.g. the Byparr
    FlareSolverr-compatible proxy) that shares one of its tags.
    """
    indexer_schemas = _load_json_file(args.schema_json)
    matched_schema = next((schema for schema in indexer_schemas if schema["name"] == args.name), None)
    if matched_schema is None:
        print(f"prowlarr-indexer-payload: '{args.name}' is not a known indexer name", file=sys.stderr)
        sys.exit(1)
    payload = json.loads(json.dumps(matched_schema))
    payload["appProfileId"] = args.app_profile_id
    if args.tag_id is not None:
        payload["tags"] = [args.tag_id]
    base_url = matched_schema["indexerUrls"][0]
    for payload_field in payload["fields"]:
        if payload_field["name"] == "baseUrl":
            payload_field["value"] = base_url
    json.dump(payload, sys.stdout)


def cmd_indexer_add_succeeded(_args):
    """Print yes/no: did a POST /api/v1/indexer response (stdin) succeed?

    Prowlarr returns the created indexer object (with an "id") on success,
    or an error body otherwise - e.g. when the tracker site itself is
    unreachable from this network.
    """
    indexer = _read_stdin_json_object().value
    if indexer is None:
        print(NO)
        return
    print(YES if "id" in indexer else NO)


def cmd_has_named_entry(args):
    """Print yes/no: does a JSON list of {"name": ...} objects on stdin include
    NAME. Shared by Prowlarr's applications and indexer proxy lists - same
    shape, same check."""
    entries = _load_stdin_json()
    print(YES if any(entry["name"] == args.name for entry in entries) else NO)


def cmd_find_tag_id(args):
    """Print the id of the Prowlarr tag named LABEL from a /api/v1/tag list on
    stdin, or nothing if no tag with that label exists yet."""
    tags = _load_stdin_json()
    matching_tag = next((tag for tag in tags if tag["label"] == args.label), None)
    print("" if matching_tag is None else matching_tag["id"])


def _pick_quality_profile(quality_profiles, preferred_name):
    """Prefer the profile named PREFERRED_NAME if present, otherwise fall
    back to the first profile in the list (every *arr install ships with at
    least one). Shared by cmd_quality_profile_id/cmd_quality_profile_name so
    a caller resolving both for the same list can't have them disagree."""
    matching_profiles = [profile for profile in quality_profiles if profile["name"] == preferred_name]
    return (matching_profiles or quality_profiles)[0]


def cmd_quality_profile_id(args):
    """Print the id of the picked quality profile from a Sonarr/Radarr
    qualityprofile list (stdin) - see _pick_quality_profile."""
    print(_pick_quality_profile(_load_stdin_json(), args.preferred_name)["id"])


def cmd_quality_profile_name(args):
    """Print the name of the picked quality profile from a Sonarr/Radarr
    qualityprofile list (stdin) - see _pick_quality_profile. Seerr's
    settings API requires both activeProfileId and activeProfileName in its
    update payload, and they must refer to the same profile - always derive
    both from one call to this and cmd_quality_profile_id against the same
    list, never assume PREFERRED_NAME was actually the match (it might have
    fallen back to the first profile instead)."""
    print(_pick_quality_profile(_load_stdin_json(), args.preferred_name)["name"])


def cmd_indexers_needing_min_seeders(args):
    """Print newline-separated ids of indexers (stdin: a Sonarr/Radarr
    /indexer list) whose "minimumSeeders" field isn't already VALUE.
    Indexers with no such field (non-torrent protocols) are left alone."""
    indexers = _load_stdin_json()
    target = str(args.value)
    for indexer in indexers:
        fields = {f["name"]: str(f.get("value")) for f in indexer.get("fields", [])}
        if "minimumSeeders" in fields and fields["minimumSeeders"] != target:
            print(indexer["id"])


def cmd_set_min_seeders(args):
    """Set "minimumSeeders" to VALUE inside a single indexer object's fields
    array (stdin), and print the full object back out ready to PUT."""
    indexer = _load_stdin_json()
    for indexer_field in indexer.get("fields", []):
        if indexer_field["name"] == "minimumSeeders":
            indexer_field["value"] = int(args.value)
    json.dump(indexer, sys.stdout)


def cmd_bazarr_needs_setup(args):
    """Print two space-separated yes/no flags: needs_auth needs_links.

    Reads Bazarr's /api/system/settings response from stdin and checks it
    against the target USERNAME, so setup.sh can skip work already done.
    """
    bazarr_settings = _load_stdin_json()
    needs_auth = (
        NO
        if bazarr_settings["auth"]["type"] == "form" and bazarr_settings["auth"]["username"] == args.username
        else YES
    )
    needs_links = (
        NO
        if bazarr_settings["general"]["use_sonarr"] and bazarr_settings["general"]["use_radarr"]
        else YES
    )
    print(f"{needs_auth} {needs_links}")


def cmd_jellyfin_wizard_completed(_args):
    """Print yes/no from a Jellyfin /System/Info/Public response on stdin."""
    jellyfin_status = _load_stdin_json()
    print(NO if jellyfin_status["StartupWizardCompleted"] is False else YES)


def cmd_extract_token(args):
    """Print one top-level string field from stdin JSON, or a blank line if absent.

    Callers (e.g. jellyfin.sh) treat a blank result as "field not present" -
    stdout must stay empty on failure. Parse errors are reported on stderr
    instead, so a bad response is still visible without corrupting stdout.
    """
    result = _read_stdin_json_object()
    response = result.value
    if response is None:
        print(f"extract-token: {result.error}", file=sys.stderr)
        print()
        return
    print(response.get(args.field, ""))


def cmd_has_jellyfin_library(args):
    """Print yes/no: does the VirtualFolders list on stdin already cover PATH?"""
    virtual_folders = _load_stdin_json()
    print(YES if any(args.path in library["Locations"] for library in virtual_folders) else NO)


def cmd_jellyfin_realtime_monitor_payload(args):
    """Print a ready-to-POST /Library/VirtualFolders/LibraryOptions body that
    turns on EnableRealtimeMonitor for the library whose Locations includes
    PATH (from a GET /Library/VirtualFolders response on stdin), preserving
    every other existing LibraryOptions field untouched. Prints nothing if no
    library covers that path, or it's already enabled - callers treat empty
    output as "nothing to do".
    """
    virtual_folders = _load_stdin_json()
    matching = next((library for library in virtual_folders if args.path in library["Locations"]), None)
    if matching is None or matching["LibraryOptions"]["EnableRealtimeMonitor"]:
        return
    library_options = dict(matching["LibraryOptions"])
    library_options["EnableRealtimeMonitor"] = True
    json.dump({"Id": matching["ItemId"], "LibraryOptions": library_options}, sys.stdout)


def cmd_jellyfin_api_key(args):
    """Print the AccessToken of the Jellyfin /Auth/Keys entry named APP_NAME
    (from a GET /Auth/Keys response on stdin), or nothing if no key with that
    name exists yet."""
    keys = _load_stdin_json()
    matching_key = next((key for key in keys["Items"] if key["AppName"] == args.app_name), None)
    print("" if matching_key is None else matching_key["AccessToken"])


def cmd_seerr_app_field(args):
    """Print one FIELD from the entry in a Seerr settings list (stdin) whose
    hostname matches HOSTNAME, or nothing if no such entry exists. Used both
    to check whether Sonarr/Radarr is already connected (via the "id" field)
    and to read its current activeProfileId, so _link_seerr_app can update an
    existing connection's profile in place instead of only wiring it once."""
    entries = _load_stdin_json()
    matching_entry = next((entry for entry in entries if entry.get("hostname") == args.hostname), None)
    print("" if matching_entry is None else matching_entry.get(args.field, ""))


def cmd_jellyfin_library_ids(_args):
    """Print each library's id, one per line, from a Seerr GET
    /settings/jellyfin/library response (a JSON array) on stdin."""
    libraries = _load_stdin_json()
    for library in libraries:
        print(library["id"])


def _read_exclusion_patterns(path):
    """Read a file of glob patterns (one per line, blank lines ignored) and
    join them the way qBittorrent stores its File Exclusions preference."""
    with open(path, encoding="utf-8") as exclusions_file:
        return "\n".join(line.strip() for line in exclusions_file if line.strip())


def cmd_qbt_exclusions_configured(args):
    """Print yes/no: does the qBittorrent preferences JSON on stdin already
    have File Exclusions enabled with exactly the patterns in EXCLUSIONS_FILE?"""
    preferences = _load_stdin_json()
    desired_patterns = _read_exclusion_patterns(args.exclusions_file)
    enabled = preferences.get("excluded_file_names_enabled") is True
    matches = preferences.get("excluded_file_names") == desired_patterns
    print(YES if enabled and matches else NO)


def cmd_qbt_exclusions_payload(args):
    """Build a qBittorrent setPreferences payload enabling File Exclusions
    with the patterns in EXCLUSIONS_FILE (one glob per line)."""
    payload = {
        "excluded_file_names_enabled": True,
        "excluded_file_names": _read_exclusion_patterns(args.exclusions_file),
    }
    json.dump(payload, sys.stdout)


def cmd_url_encode(args):
    """Print VALUE, percent-encoded for use in a query string."""
    print(urllib.parse.quote(args.value))


def cmd_recyclarr_patch_config(args):
    """Patch a Recyclarr config-template YAML file in place: fill in the
    real base_url/api_key for its one Sonarr/Radarr instance.

    Recyclarr's official config templates (from `recyclarr config create
    --template ...`) ship with extensive explanatory comments about which
    custom-format groups are enabled - a full YAML parse+dump would silently
    drop every one of them, so a plain per-line substitution is used
    instead, keyed on the two placeholder field names the templates always
    use ("base_url"/"api_key").
    """
    with open(args.config_file, encoding="utf-8") as config_file:
        lines = config_file.readlines()

    def patch_line(line):
        stripped = line.lstrip()
        indent = line[: len(line) - len(stripped)]
        if stripped.startswith("base_url:"):
            return f"{indent}base_url: {args.base_url}\n"
        if stripped.startswith("api_key:"):
            return f"{indent}api_key: {args.api_key}\n"
        return line

    with open(args.config_file, "w", encoding="utf-8") as config_file:
        config_file.writelines(patch_line(line) for line in lines)


# (internal key, display name, dashboard-icons filename, description, extra
# widget fields) for every service Homepage gets a tile for. The Docker
# network hostname/port and any credentials come from stdin at generation
# time (see cmd_homepage_services_config); everything else about the
# dashboard's one static "Media" group is fixed here.
_HOMEPAGE_SERVICES = [
    ("sonarr", "Sonarr", "sonarr.png", "TV show automation", {"type": "sonarr", "enableQueue": True}),
    ("radarr", "Radarr", "radarr.png", "Movie automation", {"type": "radarr", "enableQueue": True}),
    ("prowlarr", "Prowlarr", "prowlarr.png", "Indexer manager", {"type": "prowlarr"}),
    ("bazarr", "Bazarr", "bazarr.png", "Subtitle automation", {"type": "bazarr"}),
    ("jellyfin", "Jellyfin", "jellyfin.png", "Media server", {"type": "jellyfin", "enableNowPlaying": True}),
    ("seerr", "Seerr", "seerr.png", "Media request UI", {"type": "seerr"}),
    ("qbittorrent", "qBittorrent", "qbittorrent.png", "Torrent client", {"type": "qbittorrent", "enableLeechProgress": True}),
]


def cmd_qbt_clamav_scan_payload(_args):
    """Build the qBittorrent setPreferences payload that wires up
    scripts/config/qbt-clamav-scan.sh as the "run external program on
    torrent completion" command. The program string embeds literal double
    quotes around %F/%I (so paths with spaces survive qBittorrent's own
    argument splitting), which would need error-prone manual escaping to
    embed safely in a hand-built JSON string in bash - json.dumps handles it
    for free."""
    program = '/scripts/clamav-scan.sh "%F" "%I"'
    json.dump({"autorun_enabled": True, "autorun_program": program}, sys.stdout)


def cmd_homepage_services_config(_args):
    """Build Homepage's services.yaml from per-service ports/credentials on
    stdin - a JSON object keyed by the internal service names in
    _HOMEPAGE_SERVICES, each value holding "port" plus either "key" or
    "username"/"password" (see scripts/lib/homepage.sh for exactly what it
    sends). Generated once on first setup; scripts/lib/homepage.sh skips
    calling this again once the file exists, so hand edits survive re-runs.
    """
    import yaml  # local import: only needed for this subcommand

    service_settings = _load_stdin_json()
    media_group = []
    for key, name, icon, description, widget_extra in _HOMEPAGE_SERVICES:
        settings = service_settings[key]
        widget = dict(widget_extra)
        widget["url"] = f"http://{key}:{settings['port']}"
        if "key" in settings:
            widget["key"] = settings["key"]
        if "username" in settings:
            widget["username"] = settings["username"]
            widget["password"] = settings["password"]
        media_group.append({name: {
            "icon": icon,
            "href": f"http://{key}.media.lan",
            "description": description,
            "widget": widget,
        }})
    print("---")
    yaml.safe_dump([{"Media": media_group}], sys.stdout, sort_keys=False)


@dataclass
class Subcommand:
    """One CLI subcommand: its name, handler, help text, and positional/optional
    arguments (as (arg name, add_argument kwargs) pairs). Walked by build_parser()
    below instead of one add_parser()/add_argument()/set_defaults() block per
    subcommand - trades explicit, individually-greppable argparse calls for a
    single declarative table. Revert to the explicit form if that trade isn't
    worth it to you.
    """

    name: str
    handler: Callable
    help: str | None = None
    arguments: list[tuple[str, dict]] = field(default_factory=list)


SUBCOMMANDS = [
    Subcommand("yaml-to-env", cmd_yaml_to_env, "flatten a YAML file into shell NAME=value lines", [
        ("path", {}),
        ("--prefix", {"default": "STACK"}),
    ]),
    Subcommand("get-field", cmd_get_field, "print one dotted-path field from stdin JSON", [
        ("path", {}),
    ]),
    Subcommand("merge-host-auth", cmd_merge_host_auth, "build a config/host forms-auth payload", [
        ("username", {}),
        ("password", {}),
    ]),
    Subcommand("merge-field", cmd_merge_field, "set one top-level field in stdin JSON", [
        ("field", {}),
        ("value", {}),
    ]),
    Subcommand("has-root-folder", cmd_has_root_folder, arguments=[("path", {})]),
    Subcommand("has-download-client", cmd_has_download_client, arguments=[("implementation", {})]),
    Subcommand("prowlarr-indexer-exists", cmd_prowlarr_indexer_exists, arguments=[
        ("existing_json", {}),
        ("name", {}),
    ]),
    Subcommand("prowlarr-indexer-payload", cmd_prowlarr_indexer_payload, arguments=[
        ("schema_json", {}),
        ("name", {}),
        ("app_profile_id", {"type": int}),
        ("--tag-id", {"type": int}),
    ]),
    Subcommand("indexer-add-succeeded", cmd_indexer_add_succeeded),
    Subcommand("has-application", cmd_has_named_entry, arguments=[("name", {})]),
    Subcommand("has-indexerproxy", cmd_has_named_entry, arguments=[("name", {})]),
    Subcommand("has-notification", cmd_has_named_entry, arguments=[("name", {})]),
    Subcommand("find-tag-id", cmd_find_tag_id, arguments=[("label", {})]),
    Subcommand("quality-profile-id", cmd_quality_profile_id, arguments=[("preferred_name", {})]),
    Subcommand("quality-profile-name", cmd_quality_profile_name, arguments=[("preferred_name", {})]),
    Subcommand("indexers-needing-min-seeders", cmd_indexers_needing_min_seeders, arguments=[("value", {"type": int})]),
    Subcommand("set-min-seeders", cmd_set_min_seeders, arguments=[("value", {"type": int})]),
    Subcommand("bazarr-needs-setup", cmd_bazarr_needs_setup, arguments=[("username", {})]),
    Subcommand("jellyfin-wizard-completed", cmd_jellyfin_wizard_completed),
    Subcommand("extract-token", cmd_extract_token, arguments=[("field", {})]),
    Subcommand("has-jellyfin-library", cmd_has_jellyfin_library, arguments=[("path", {})]),
    Subcommand("jellyfin-realtime-monitor-payload", cmd_jellyfin_realtime_monitor_payload, arguments=[("path", {})]),
    Subcommand("jellyfin-api-key", cmd_jellyfin_api_key, arguments=[("app_name", {})]),
    Subcommand("seerr-app-field", cmd_seerr_app_field, arguments=[("hostname", {}), ("field", {})]),
    Subcommand("jellyfin-library-ids", cmd_jellyfin_library_ids),
    Subcommand("qbt-exclusions-configured", cmd_qbt_exclusions_configured, arguments=[("exclusions_file", {})]),
    Subcommand("qbt-exclusions-payload", cmd_qbt_exclusions_payload, arguments=[("exclusions_file", {})]),
    Subcommand("url-encode", cmd_url_encode, arguments=[("value", {})]),
    Subcommand("recyclarr-patch-config", cmd_recyclarr_patch_config, arguments=[
        ("config_file", {}),
        ("base_url", {}),
        ("api_key", {}),
    ]),
    Subcommand("qbt-clamav-scan-payload", cmd_qbt_clamav_scan_payload),
    Subcommand("homepage-services-config", cmd_homepage_services_config),
]


def build_parser():
    parser = argparse.ArgumentParser(description=__doc__)
    subparsers = parser.add_subparsers(dest="command", required=True)
    for subcommand in SUBCOMMANDS:
        subparser = subparsers.add_parser(subcommand.name, help=subcommand.help)
        for arg_name, kwargs in subcommand.arguments:
            subparser.add_argument(arg_name, **kwargs)
        subparser.set_defaults(func=subcommand.handler)
    return parser


def main():
    args = build_parser().parse_args()
    args.func(args)


if __name__ == "__main__":
    main()
