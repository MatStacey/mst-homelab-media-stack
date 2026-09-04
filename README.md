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
   - `vpn` — qBittorrent's traffic is routed through Gluetun; also set
     `PIA_USER`, `PIA_PASSWORD`, `PIA_REGION`, and `LAN_SUBNET`

   Both modes are always reachable at `qbittorrent:8080` on `homelab_net`,
   so nothing downstream needs to change when you switch.

3. Bring up the stack:

   ```bash
   docker compose up -d
   ```

4. Visit each service's `*.media.lan` address (or its published port
   directly) to finish first-run setup, then wire up indexers in Prowlarr
   and point Sonarr/Radarr/Bazarr/Jellyseerr at each other.

## Notes

- Per-service state lives under `./config/<service>/` (git-ignored).
- `.env` holds secrets and is git-ignored — only `.env.example` is
  committed.
- TLS: the Caddyfile currently serves plain HTTP over the LAN pseudo-domain.
  Adding a real domain + `email` directive to `caddy/Caddyfile` enables
  automatic Let's Encrypt TLS with no other changes needed.
