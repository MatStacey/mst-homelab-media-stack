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
    """
    indexer_schemas = _load_json_file(args.schema_json)
    matched_schema = next((schema for schema in indexer_schemas if schema["name"] == args.name), None)
    if matched_schema is None:
        print(f"prowlarr-indexer-payload: '{args.name}' is not a known indexer name", file=sys.stderr)
        sys.exit(1)
    payload = json.loads(json.dumps(matched_schema))
    payload["appProfileId"] = args.app_profile_id
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


def cmd_has_application(args):
    """Print yes/no: does the Prowlarr applications list on stdin include NAME."""
    applications = _load_stdin_json()
    print(YES if any(application["name"] == args.name for application in applications) else NO)


def cmd_quality_profile_id(args):
    """Pick a quality profile id from a Sonarr/Radarr qualityprofile list (stdin).

    Prefers PREFERRED_NAME if present, otherwise falls back to the first
    profile in the list (every *arr install ships with at least one).
    """
    quality_profiles = _load_stdin_json()
    matching_profiles = [profile for profile in quality_profiles if profile["name"] == args.preferred_name]
    print((matching_profiles or quality_profiles)[0]["id"])


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


def cmd_has_jellyseerr_app(args):
    """Print yes/no: does the Jellyseerr settings list on stdin include HOSTNAME."""
    configured_apps = _load_stdin_json()
    print(YES if any(app["hostname"] == args.hostname for app in configured_apps) else NO)


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
    ]),
    Subcommand("indexer-add-succeeded", cmd_indexer_add_succeeded),
    Subcommand("has-application", cmd_has_application, arguments=[("name", {})]),
    Subcommand("quality-profile-id", cmd_quality_profile_id, arguments=[("preferred_name", {})]),
    Subcommand("bazarr-needs-setup", cmd_bazarr_needs_setup, arguments=[("username", {})]),
    Subcommand("jellyfin-wizard-completed", cmd_jellyfin_wizard_completed),
    Subcommand("extract-token", cmd_extract_token, arguments=[("field", {})]),
    Subcommand("has-jellyfin-library", cmd_has_jellyfin_library, arguments=[("path", {})]),
    Subcommand("has-jellyseerr-app", cmd_has_jellyseerr_app, arguments=[("hostname", {})]),
    Subcommand("qbt-exclusions-configured", cmd_qbt_exclusions_configured, arguments=[("exclusions_file", {})]),
    Subcommand("qbt-exclusions-payload", cmd_qbt_exclusions_payload, arguments=[("exclusions_file", {})]),
    Subcommand("url-encode", cmd_url_encode, arguments=[("value", {})]),
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
