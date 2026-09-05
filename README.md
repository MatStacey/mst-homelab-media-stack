# Media Homelab

A self-contained Docker Compose media stack — qBittorrent, Prowlarr, Sonarr,
Radarr, Bazarr, Jellyfin, and Jellyseerr — sitting behind a Caddy reverse
proxy on a private Docker network, with an optional VPN-routed torrent
client via Gluetun.

## Services

| Service | Purpose | LAN address (via Caddy) |
|---|---|---|
| qBittorrent | Torrent client | `qbittorrent.media.lan` |
| Gluetun | VPN gateway for qBittorrent (optional) | — |
| Prowlarr | Indexer manager | `prowlarr.media.lan` |
| Sonarr | TV show automation | `sonarr.media.lan` |
| Radarr | Movie automation | `radarr.media.lan` |
| Bazarr | Subtitle automation | `bazarr.media.lan` |
| Jellyfin | Media server | `jellyfin.media.lan` |
| Jellyseerr | Media request UI | `jellyseerr.media.lan` |
| Caddy | Reverse proxy / gateway | `:80` / `:443` |

All services communicate over an internal `homelab_net` bridge network.
Caddy is the only intended ingress point; a few services (qBittorrent,
Jellyfin) also publish ports directly for LAN discovery/native app use.

## Prerequisites

- Docker Engine + Docker Compose plugin
- `python3` with the `PyYAML` package (`pip install -r scripts/requirements.txt`)
  — used by `scripts/setup.sh`. On Debian/Ubuntu-based systems this may fail
  with an "externally managed environment" error; use `apt install
  python3-yaml`, `pip install --user -r scripts/requirements.txt`, or a venv
  instead.
- A host directory for media/downloads (default: `/opt/media-data`, mounted
  read-write into qBittorrent/*arr and read-only into Jellyfin)
- LAN DNS entries (or hosts-file entries) resolving `*.media.lan` to this
  host, or edit `caddy/Caddyfile` to suit your own domain

## Setup

1. Copy the environment template and fill in real values:

   ```bash
   cp .env.example .env
   ```

2. Choose torrent mode by setting `COMPOSE_PROFILES` in `.env`:
   - `novpn` — qBittorrent connects directly (default, no extra config)
   - `vpn` — qBittorrent's traffic is routed through Gluetun

   Both modes are always reachable at `qbittorrent:8080` on `homelab_net`,
   so nothing downstream needs to change when you switch.

   For `vpn` mode, Gluetun (the container that runs the tunnel) supports 30+
   VPN providers — see `.env.example` for ready-to-uncomment blocks for
   **Private Internet Access** (default, WireGuard, supports port
   forwarding), **ProtonVPN**, and **Mullvad** — all three have solid
   no-logging track records and work cleanly for torrenting through Gluetun.
   Any other provider Gluetun supports (NordVPN, Surfshark, AirVPN,
   Windscribe, ...) works the same way: set `VPN_SERVICE_PROVIDER` to that
   provider's Gluetun name and fill in whichever variables its page on the
   [Gluetun wiki](https://github.com/qdm12/gluetun-wiki/tree/main/setup/providers)
   calls for — the compose file's `gluetun` service reads Gluetun's own
   variable names directly, so nothing else needs to change.

3. Bring up and configure the stack:

   ```bash
   docker compose up -d
   ./scripts/setup.sh
   ```

   `scripts/setup.sh` brings the containers up (if not already) and then
   wires them together via each app's API: Sonarr/Radarr get their root
   folders, qBittorrent download client, and Prowlarr indexers; Bazarr gets
   connected to Sonarr/Radarr with an English subtitle profile; Jellyfin's
   setup wizard is completed with your Movies/TV libraries; Jellyseerr signs
   in through Jellyfin and connects to Sonarr/Radarr. It prompts for a
   shared admin username/password if `ADMIN_USERNAME`/`ADMIN_PASSWORD`
   aren't set in `.env`, and picks a curated set of public indexers unless
   `PROWLARR_INDEXERS` says otherwise (see `.env.example`). It's safe to
   re-run — every step checks current state first and skips what's already
   configured. Requires `python3` with the `PyYAML` package (`pip install
   pyyaml`) in addition to Docker.

   The script is split by service for easy maintenance:
   - `scripts/config/stack.yaml` — ports, paths, default indexers, category
     IDs, and other values you're likely to want to tweak. Change behavior
     here before touching any script.
   - `scripts/config/bazarr-language-profile.json` — the English subtitle
     profile payload Bazarr gets configured with.
   - `scripts/lib/api.py` — all JSON/YAML parsing lives here as small,
     documented subcommands, rather than inline `python3 -c "..."` in bash.
   - `scripts/lib/common.sh` — shared logging/polling/docker-exec helpers.
   - `scripts/lib/servarr.sh` — building blocks shared by Sonarr and Radarr
     (near-identical *arr APIs): auth, root folder, download client.
   - `scripts/lib/<service>.sh` — one file per service (`sonarr.sh`,
     `radarr.sh`, `prowlarr.sh`, `qbittorrent.sh`, `bazarr.sh`,
     `jellyfin.sh`, `jellyseerr.sh`), each exposing a single
     `configure_<service>` entry point. `setup.sh` itself is just the
     orchestrator that sources these and calls them in order.

4. Add hosts-file entries (or LAN DNS records) pointing `*.media.lan` at
   this machine so Caddy's reverse proxy addresses resolve, then visit
   `http://sonarr.media.lan` etc. and log in with the admin credentials
   from step 3.

## Notes

- Per-service state lives under `./config/<service>/` (git-ignored).
- `.env` holds secrets and is git-ignored — only `.env.example` is
  committed.
- TLS: the Caddyfile currently serves plain HTTP over the LAN pseudo-domain.
  Adding a real domain + `email` directive to `caddy/Caddyfile` enables
  automatic Let's Encrypt TLS with no other changes needed.
