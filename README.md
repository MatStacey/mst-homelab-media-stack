# Media Homelab

A self-contained Docker Compose media stack — qBittorrent, Prowlarr, Sonarr,
Radarr, Bazarr, Jellyfin, dovi_convert, and Seerr — sitting behind a Caddy
reverse proxy on a private Docker network, with an optional VPN-routed mode
via Gluetun for qBittorrent, Prowlarr, and Byparr. ClamAV scans every
completed download, Recyclarr keeps Sonarr/Radarr's quality profiles in
sync, Homepage is the dashboard/landing page, Tailscale gives optional
remote access over a private mesh, and Vault is an optional secrets store
provided by a separate, pre-existing project.

<svg viewBox="0 0 1320 662" xmlns="http://www.w3.org/2000/svg" role="img" aria-label="Media homelab architecture diagram">
  <rect x="0" y="0" width="1320" height="662" fill="#F5F6F8"/>
  <rect x="30" y="20" width="150" height="40" rx="9" fill="#F5F6F8" stroke="#8A94A6" stroke-width="1.4" stroke-dasharray="5 4"/>
  <text x="46" y="44" font-family="Helvetica, Arial, sans-serif" font-size="12.5" font-weight="600" fill="#1A2233">LAN Client</text>
  <rect x="440" y="20" width="170" height="40" rx="9" fill="#F5F6F8" stroke="#8A94A6" stroke-width="1.4" stroke-dasharray="5 4"/>
  <text x="456" y="44" font-family="Helvetica, Arial, sans-serif" font-size="12.5" font-weight="600" fill="#1A2233">Tailscale Mesh</text>
  <rect x="1040" y="20" width="190" height="44" rx="9" fill="#F5F6F8" stroke="#8A94A6" stroke-width="1.4" stroke-dasharray="5 4"/>
  <text x="1056" y="39" font-family="Helvetica, Arial, sans-serif" font-size="12.5" font-weight="600" fill="#1A2233">Vault</text>
  <text x="1056" y="55" font-family="Helvetica, Arial, sans-serif" font-size="10" fill="#5B667A">mst-vault, optional</text>
  <rect x="30" y="104" width="170" height="50" rx="9" fill="#FFFFFF" stroke="#D6DCE5" stroke-width="1.4"/>
  <rect x="30" y="107" width="5" height="44" rx="2" fill="#3B6FD1"/>
  <text x="44" y="133" font-family="Helvetica, Arial, sans-serif" font-size="12.5" font-weight="600" fill="#1A2233">Caddy</text>
  <rect x="440" y="104" width="170" height="50" rx="9" fill="#FFFFFF" stroke="#D6DCE5" stroke-width="1.4"/>
  <rect x="440" y="107" width="5" height="44" rx="2" fill="#3B6FD1"/>
  <text x="454" y="133" font-family="Helvetica, Arial, sans-serif" font-size="12.5" font-weight="600" fill="#1A2233">Tailscale</text>
  <rect x="30" y="214" width="150" height="46" rx="9" fill="#FFFFFF" stroke="#D6DCE5" stroke-width="1.4"/>
  <rect x="30" y="217" width="5" height="40" rx="2" fill="#7A5AC7"/>
  <text x="44" y="241" font-family="Helvetica, Arial, sans-serif" font-size="12.5" font-weight="600" fill="#1A2233">Homepage</text>
  <rect x="220" y="214" width="150" height="46" rx="9" fill="#FFFFFF" stroke="#D6DCE5" stroke-width="1.4"/>
  <rect x="220" y="217" width="5" height="40" rx="2" fill="#7A5AC7"/>
  <text x="234" y="241" font-family="Helvetica, Arial, sans-serif" font-size="12.5" font-weight="600" fill="#1A2233">Seerr</text>
  <rect x="30" y="306" width="150" height="46" rx="9" fill="#FFFFFF" stroke="#D6DCE5" stroke-width="1.4"/>
  <rect x="30" y="309" width="5" height="40" rx="2" fill="#4B4FBD"/>
  <text x="44" y="333" font-family="Helvetica, Arial, sans-serif" font-size="12.5" font-weight="600" fill="#1A2233">Sonarr</text>
  <rect x="220" y="306" width="150" height="46" rx="9" fill="#FFFFFF" stroke="#D6DCE5" stroke-width="1.4"/>
  <rect x="220" y="309" width="5" height="40" rx="2" fill="#4B4FBD"/>
  <text x="234" y="333" font-family="Helvetica, Arial, sans-serif" font-size="12.5" font-weight="600" fill="#1A2233">Radarr</text>
  <rect x="410" y="306" width="150" height="46" rx="9" fill="#FFFFFF" stroke="#D6DCE5" stroke-width="1.4"/>
  <rect x="410" y="309" width="5" height="40" rx="2" fill="#4B4FBD"/>
  <text x="424" y="333" font-family="Helvetica, Arial, sans-serif" font-size="12.5" font-weight="600" fill="#1A2233">Bazarr</text>
  <rect x="600" y="306" width="150" height="46" rx="9" fill="#FFFFFF" stroke="#D6DCE5" stroke-width="1.4"/>
  <rect x="600" y="309" width="5" height="40" rx="2" fill="#4B4FBD"/>
  <text x="614" y="333" font-family="Helvetica, Arial, sans-serif" font-size="12.5" font-weight="600" fill="#1A2233">Prowlarr</text>
  <rect x="800" y="306" width="150" height="46" rx="9" fill="#FFFFFF" stroke="#D6DCE5" stroke-width="1.4"/>
  <rect x="800" y="309" width="5" height="40" rx="2" fill="#4B4FBD"/>
  <text x="814" y="333" font-family="Helvetica, Arial, sans-serif" font-size="12.5" font-weight="600" fill="#1A2233">Byparr</text>
  <rect x="1040" y="306" width="150" height="46" rx="9" fill="#FFFFFF" stroke="#D6DCE5" stroke-width="1.4"/>
  <rect x="1040" y="309" width="5" height="40" rx="2" fill="#4B4FBD"/>
  <text x="1054" y="333" font-family="Helvetica, Arial, sans-serif" font-size="12.5" font-weight="600" fill="#1A2233">Recyclarr</text>
  <rect x="30" y="404" width="170" height="46" rx="9" fill="#FFFFFF" stroke="#D6DCE5" stroke-width="1.4"/>
  <rect x="30" y="407" width="5" height="40" rx="2" fill="#2F8F46"/>
  <text x="44" y="431" font-family="Helvetica, Arial, sans-serif" font-size="12.5" font-weight="600" fill="#1A2233">qBittorrent</text>
  <rect x="240" y="404" width="140" height="46" rx="9" fill="#FFFFFF" stroke="#D6DCE5" stroke-width="1.4"/>
  <rect x="240" y="407" width="5" height="40" rx="2" fill="#2F8F46"/>
  <text x="254" y="431" font-family="Helvetica, Arial, sans-serif" font-size="12.5" font-weight="600" fill="#1A2233">ClamAV</text>
  <rect x="420" y="404" width="170" height="46" rx="9" fill="#FFFFFF" stroke="#D6DCE5" stroke-width="1.4"/>
  <rect x="420" y="407" width="5" height="40" rx="2" fill="#2F8F46"/>
  <text x="434" y="424" font-family="Helvetica, Arial, sans-serif" font-size="12.5" font-weight="600" fill="#1A2233">Gluetun</text>
  <text x="434" y="440" font-family="Helvetica, Arial, sans-serif" font-size="10" fill="#5B667A">profile: vpn</text>
  <rect x="630" y="404" width="160" height="46" rx="9" fill="#F5F6F8" stroke="#8A94A6" stroke-width="1.4" stroke-dasharray="5 4"/>
  <text x="646" y="431" font-family="Helvetica, Arial, sans-serif" font-size="12.5" font-weight="600" fill="#1A2233">VPN Provider</text>
  <rect x="30" y="496" width="150" height="46" rx="9" fill="#FFFFFF" stroke="#D6DCE5" stroke-width="1.4"/>
  <rect x="30" y="499" width="5" height="40" rx="2" fill="#C9711A"/>
  <text x="44" y="523" font-family="Helvetica, Arial, sans-serif" font-size="12.5" font-weight="600" fill="#1A2233">Jellyfin</text>
  <rect x="220" y="496" width="160" height="46" rx="9" fill="#FFFFFF" stroke="#D6DCE5" stroke-width="1.4"/>
  <rect x="220" y="499" width="5" height="40" rx="2" fill="#C9711A"/>
  <text x="234" y="523" font-family="Helvetica, Arial, sans-serif" font-size="12.5" font-weight="600" fill="#1A2233">dovi_convert</text>
  <rect x="30" y="588" width="760" height="54" rx="9" fill="#FFFFFF" stroke="#D6DCE5" stroke-width="1.4"/>
  <rect x="30" y="591" width="5" height="48" rx="2" fill="#586174"/>
  <text x="44" y="612" font-family="Helvetica, Arial, sans-serif" font-size="12.5" font-weight="600" fill="#1A2233">Media Storage</text>
  <text x="44" y="628" font-family="Helvetica, Arial, sans-serif" font-size="10" fill="#5B667A">$MEDIA_DATA_PATH</text>
  <path d="M105,60 L115,104" stroke="#94A0B4" stroke-width="1.6" fill="none"/>
  <polygon points="110.5,96 115,104 119.5,96" fill="#94A0B4"/>
  <rect x="67.35" y="69" width="75.3" height="13" fill="#F5F6F8"/>
  <text x="105" y="80" font-family="Helvetica, Arial, sans-serif" font-size="10" fill="#5B667A" text-anchor="middle">*.media.lan</text>
  <path d="M525,60 L525,104" stroke="#94A0B4" stroke-width="1.6" fill="none"/>
  <polygon points="520.5,96 525,104 529.5,96" fill="#94A0B4"/>
  <rect x="496.8" y="69" width="56.4" height="13" fill="#F5F6F8"/>
  <text x="525" y="80" font-family="Helvetica, Arial, sans-serif" font-size="10" fill="#5B667A" text-anchor="middle">*.ts.net</text>
  <path d="M440,129 L200,129" stroke="#94A0B4" stroke-width="1.6" fill="none" stroke-dasharray="4 4"/>
  <polygon points="208,124.5 200,129 208,133.5" fill="#94A0B4"/>
  <path d="M115,154 L12,196" stroke="#2F8F46" stroke-width="1.6" fill="none"/>
  <path d="M12,196 L12,486" stroke="#2F8F46" stroke-width="1.6" fill="none"/>
  <rect x="53" y="177" width="88" height="13" fill="#F5F6F8"/>
  <text x="56" y="188" font-family="Helvetica, Arial, sans-serif" font-size="10" fill="#2F8F46" text-anchor="start">reverse_proxy</text>
  <path d="M12,196 L90,196 L90,214" stroke="#2F8F46" stroke-width="1.6" fill="none"/>
  <polygon points="85.5,206 90,214 94.5,206" fill="#2F8F46"/>
  <path d="M12,196 L295,196 L295,214" stroke="#2F8F46" stroke-width="1.6" fill="none"/>
  <polygon points="290.5,206 295,214 299.5,206" fill="#2F8F46"/>
  <path d="M12,296 L105,296 L105,306" stroke="#2F8F46" stroke-width="1.6" fill="none"/>
  <polygon points="100.5,298 105,306 109.5,298" fill="#2F8F46"/>
  <path d="M12,296 L295,296 L295,306" stroke="#2F8F46" stroke-width="1.6" fill="none"/>
  <polygon points="290.5,298 295,306 299.5,298" fill="#2F8F46"/>
  <path d="M12,296 L485,296 L485,306" stroke="#2F8F46" stroke-width="1.6" fill="none"/>
  <polygon points="480.5,298 485,306 489.5,298" fill="#2F8F46"/>
  <path d="M12,296 L675,296 L675,306" stroke="#2F8F46" stroke-width="1.6" fill="none"/>
  <polygon points="670.5,298 675,306 679.5,298" fill="#2F8F46"/>
  <path d="M12,392 L100,392 L100,404" stroke="#2F8F46" stroke-width="1.6" fill="none"/>
  <polygon points="95.5,396 100,404 104.5,396" fill="#2F8F46"/>
  <path d="M12,486 L90,486 L90,496" stroke="#2F8F46" stroke-width="1.6" fill="none"/>
  <polygon points="85.5,488 90,496 94.5,488" fill="#2F8F46"/>
  <path d="M12,486 L300,486 L300,496" stroke="#2F8F46" stroke-width="1.6" fill="none"/>
  <polygon points="295.5,488 300,496 304.5,488" fill="#2F8F46"/>
  <path d="M525,154 L525,206 L966,206" stroke="#94A0B4" stroke-width="1.6" fill="none" stroke-dasharray="4 4"/>
  <path d="M966,206 L966,480" stroke="#94A0B4" stroke-width="1.6" fill="none" stroke-dasharray="4 4"/>
  <path d="M966,206 L370,237" stroke="#94A0B4" stroke-width="1.6" fill="none" stroke-dasharray="4 4"/>
  <polygon points="378,232.5 370,237 378,241.5" fill="#94A0B4"/>
  <rect x="925.2" y="187" width="81.6" height="13" fill="#F5F6F8"/>
  <text x="966" y="198" font-family="Helvetica, Arial, sans-serif" font-size="10" fill="#5B667A" text-anchor="middle">direct serve</text>
  <path d="M966,206 L120,206 L120,214" stroke="#94A0B4" stroke-width="1.6" fill="none" stroke-dasharray="4 4"/>
  <polygon points="115.5,206 120,214 124.5,206" fill="#94A0B4"/>
  <path d="M966,398 L130,398 L130,404" stroke="#94A0B4" stroke-width="1.6" fill="none" stroke-dasharray="4 4"/>
  <polygon points="125.5,396 130,404 134.5,396" fill="#94A0B4"/>
  <path d="M966,480 L120,480 L120,496" stroke="#94A0B4" stroke-width="1.6" fill="none" stroke-dasharray="4 4"/>
  <polygon points="115.5,488 120,496 124.5,488" fill="#94A0B4"/>
  <path d="M295,260 L295,306" stroke="#2F8F46" stroke-width="1.6" fill="none"/>
  <polygon points="290.5,298 295,306 299.5,298" fill="#2F8F46"/>
  <path d="M295,260 L295,288 L105,288 L105,306" stroke="#2F8F46" stroke-width="1.6" fill="none"/>
  <polygon points="100.5,298 105,306 109.5,298" fill="#2F8F46"/>
  <path d="M220,237 L205,237 L205,519 L180,519" stroke="#2F8F46" stroke-width="1.6" fill="none"/>
  <polygon points="188,514.5 180,519 188,523.5" fill="#2F8F46"/>
  <path d="M1115,306 L1115,280 L105,280 L105,306" stroke="#94A0B4" stroke-width="1.6" fill="none" stroke-dasharray="4 4"/>
  <polygon points="100.5,298 105,306 109.5,298" fill="#94A0B4"/>
  <path d="M1115,280 L295,280 L295,306" stroke="#94A0B4" stroke-width="1.6" fill="none" stroke-dasharray="4 4"/>
  <polygon points="290.5,298 295,306 299.5,298" fill="#94A0B4"/>
  <rect x="496.05" y="271" width="88" height="13" fill="#F5F6F8"/>
  <text x="540" y="282" font-family="Helvetica, Arial, sans-serif" font-size="10" fill="#5B667A" text-anchor="middle">sync profiles</text>
  <path d="M105,352 L105,372 L675,372 L675,306" stroke="#2F8F46" stroke-width="1.6" fill="none"/>
  <path d="M295,352 L295,372 L675,372 L675,306" stroke="#2F8F46" stroke-width="1.6" fill="none"/>
  <polygon points="670.5,298 675,306 679.5,298" fill="#2F8F46"/>
  <path d="M105,352 L105,384 L115,384 L115,404" stroke="#2F8F46" stroke-width="1.6" fill="none"/>
  <path d="M295,352 L295,384 L115,384 L115,404" stroke="#2F8F46" stroke-width="1.6" fill="none"/>
  <polygon points="110.5,396 115,404 119.5,396" fill="#2F8F46"/>
  <path d="M750,329 L800,329" stroke="#94A0B4" stroke-width="1.6" fill="none" stroke-dasharray="4 4"/>
  <polygon points="792,324.5 800,329 792,333.5" fill="#94A0B4"/>
  <rect x="727.9" y="308" width="94.2" height="13" fill="#F5F6F8"/>
  <text x="775" y="319" font-family="Helvetica, Arial, sans-serif" font-size="10" fill="#5B667A" text-anchor="middle">bypass captcha</text>
  <path d="M115,450 L115,468 L505,468 L505,450" stroke="#C9711A" stroke-width="1.6" fill="none" stroke-dasharray="4 4"/>
  <polygon points="500.5,458 505,450 509.5,458" fill="#C9711A"/>
  <path d="M675,352 L675,478 L540,478 L540,450" stroke="#C9711A" stroke-width="1.6" fill="none" stroke-dasharray="4 4"/>
  <path d="M875,352 L875,488 L560,488 L560,450" stroke="#C9711A" stroke-width="1.6" fill="none" stroke-dasharray="4 4"/>
  <rect x="106.8" y="471" width="56.4" height="13" fill="#F5F6F8"/>
  <text x="135" y="482" font-family="Helvetica, Arial, sans-serif" font-size="10" fill="#C9711A" text-anchor="middle">optional</text>
  <path d="M590,427 L630,427" stroke="#C9711A" stroke-width="2" fill="none"/>
  <polygon points="622,422.5 630,427 622,431.5" fill="#C9711A"/>
  <rect x="576.15" y="406" width="62.7" height="13" fill="#F5F6F8"/>
  <text x="607.5" y="417" font-family="Helvetica, Arial, sans-serif" font-size="10" fill="#C9711A" text-anchor="middle">WireGuard</text>
  <path d="M200,427 L240,427" stroke="#94A0B4" stroke-width="1.6" fill="none" stroke-dasharray="4 4"/>
  <polygon points="232,422.5 240,427 232,431.5" fill="#94A0B4"/>
  <rect x="196.9" y="406" width="31.2" height="13" fill="#F5F6F8"/>
  <text x="212.5" y="417" font-family="Helvetica, Arial, sans-serif" font-size="10" fill="#5B667A" text-anchor="middle">scan</text>
  <path d="M180,237 L220,237" stroke="#94A0B4" stroke-width="1.6" fill="none" stroke-dasharray="4 4"/>
  <polygon points="212,232.5 220,237 212,241.5" fill="#94A0B4"/>
  <path d="M105,214 L105,198 L1215,198 L1215,519" stroke="#94A0B4" stroke-width="1.6" fill="none" stroke-dasharray="4 4"/>
  <path d="M1215,519 L180,519" stroke="#94A0B4" stroke-width="1.6" fill="none" stroke-dasharray="4 4"/>
  <polygon points="188,514.5 180,519 188,523.5" fill="#94A0B4"/>
  <path d="M1215,519 L1215,427 L200,427" stroke="#94A0B4" stroke-width="1.6" fill="none" stroke-dasharray="4 4"/>
  <polygon points="208,422.5 200,427 208,431.5" fill="#94A0B4"/>
  <rect x="1158.45" y="177" width="113.1" height="13" fill="#F5F6F8"/>
  <text x="1215" y="188" font-family="Helvetica, Arial, sans-serif" font-size="10" fill="#5B667A" text-anchor="middle">dashboard widgets</text>
  <path d="M1135,64 L1135,62 L1270,62 L1270,129" stroke="#C9711A" stroke-width="1.6" fill="none" stroke-dasharray="4 4"/>
  <path d="M1270,129 L610,129" stroke="#C9711A" stroke-width="1.6" fill="none" stroke-dasharray="4 4"/>
  <polygon points="618,124.5 610,129 618,133.5" fill="#C9711A"/>
  <path d="M1270,129 L1270,427 L590,427" stroke="#C9711A" stroke-width="1.6" fill="none" stroke-dasharray="4 4"/>
  <polygon points="598,422.5 590,427 598,431.5" fill="#C9711A"/>
  <rect x="1244.95" y="41" width="50.1" height="13" fill="#F5F6F8"/>
  <text x="1270" y="52" font-family="Helvetica, Arial, sans-serif" font-size="10" fill="#C9711A" text-anchor="middle">secrets</text>
  <path d="M105,352 L105,360 L210,360 L210,588" stroke="#2F8F46" stroke-width="1.6" fill="none"/>
  <polygon points="205.5,580 210,588 214.5,580" fill="#2F8F46"/>
  <path d="M295,352 L295,366 L400,366 L400,588" stroke="#2F8F46" stroke-width="1.6" fill="none"/>
  <polygon points="395.5,580 400,588 404.5,580" fill="#2F8F46"/>
  <path d="M485,352 L485,372 L610,372 L610,588" stroke="#2F8F46" stroke-width="1.6" fill="none"/>
  <polygon points="605.5,580 610,588 614.5,580" fill="#2F8F46"/>
  <path d="M115,450 L115,460 L200,460 L200,588" stroke="#2F8F46" stroke-width="1.6" fill="none"/>
  <polygon points="195.5,580 200,588 204.5,580" fill="#2F8F46"/>
  <path d="M105,542 L105,580 L105,588" stroke="#94A0B4" stroke-width="1.6" fill="none" stroke-dasharray="4 4"/>
  <polygon points="100.5,580 105,588 109.5,580" fill="#94A0B4"/>
  <rect x="131.65" y="569" width="62.7" height="13" fill="#F5F6F8"/>
  <text x="163" y="580" font-family="Helvetica, Arial, sans-serif" font-size="10" fill="#5B667A" text-anchor="middle">read only</text>
  <path d="M300,542 L300,584 L300,588" stroke="#2F8F46" stroke-width="1.6" fill="none"/>
  <polygon points="295.5,580 300,588 304.5,580" fill="#2F8F46"/>
</svg>

**Reading the diagram:** solid lines are the main request/download/import path;
dashed lines are secondary relationships (sync, scan, remote-access fan-out,
secrets). Dashed-border boxes are external to this compose file (Tailscale's
own network, the VPN provider, and the separate `mst-vault` project).

| | |
|---|---|
| 🔵 blue | Access — Caddy, Tailscale |
| 🟣 violet | Requests & dashboard — Seerr, Homepage |
| 🟪 indigo | Automation — Sonarr, Radarr, Bazarr, Prowlarr, Byparr, Recyclarr |
| 🟢 green | Downloads & security — qBittorrent, Gluetun, ClamAV |
| 🟠 orange | Media & playback — Jellyfin, dovi_convert |
| ⬛ slate | Storage |
| ⚪ dashed | External to this stack — LAN/Tailscale clients, VPN provider, Vault |

## Services

| Service | Purpose | LAN address (via Caddy) |
|---|---|---|
| qBittorrent | Torrent client | `qbittorrent.media.lan` |
| Gluetun | VPN gateway for qBittorrent/Prowlarr/Byparr (optional) | — |
| Prowlarr | Indexer manager | `prowlarr.media.lan` |
| Sonarr | TV show automation | `sonarr.media.lan` |
| Radarr | Movie automation | `radarr.media.lan` |
| Bazarr | Subtitle automation | `bazarr.media.lan` |
| Jellyfin | Media server | `jellyfin.media.lan` |
| dovi_convert | Converts Dolby Vision Profile 7 titles to 8.1 for wider client compatibility (see Notes) | `dovi-convert.media.lan` |
| Seerr | Media request UI | `seerr.media.lan` |
| Byparr | Cloudflare/anti-bot bypass for Prowlarr indexers | — |
| Recyclarr | Syncs TRaSH Guides quality profiles/custom formats into Sonarr/Radarr | — |
| ClamAV | Scans every completed download before Sonarr/Radarr import it (see Notes) | — |
| Homepage | Dashboard with live widgets for the whole stack | `status.media.lan` |
| Caddy | Reverse proxy / gateway, plus a static landing page | `:80` / `:443` |
| *(landing page)* | Tile grid linking to every service above | `homepage.media.lan` |
| Tailscale | Optional remote access over a private mesh network (see Setup step 5) | `<node>.<tailnet>.ts.net` |
| Vault | Optional secrets store for admin/VPN/Tailscale credentials (see [Vault (optional)](#vault-optional)) | — |

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
- A host directory for media/downloads, set via `MEDIA_DATA_PATH` in `.env`
  (default: `/opt/media-data`, mounted read-write into qBittorrent/*arr and
  read-only into Jellyfin). `downloads/` and `media/` under it must stay on
  the same filesystem — Sonarr/Radarr hardlink finished downloads straight
  into the library rather than copying them, which only works within one
  filesystem.
- LAN DNS entries (or hosts-file entries) resolving `*.media.lan` to this
  host, or edit `caddy/Caddyfile` to suit your own domain
- (Optional, for GPU hardware transcoding) An NVIDIA GPU with
  `nvidia-container-toolkit` installed on the host — see [GPU hardware
  transcoding](#gpu-hardware-transcoding-jellyfin) below

## Setup

1. Copy the environment template and fill in real values:

   ```bash
   cp .env.example .env
   ```

2. Choose network mode by setting `COMPOSE_PROFILES` in `.env`:
   - `novpn` — qBittorrent/Prowlarr/Byparr all connect directly (default, no
     extra config)
   - `vpn` — all three are routed through Gluetun instead

   Both modes are always reachable at the same hostnames (`qbittorrent`,
   `prowlarr`, `byparr` on `homelab_net`, plus `qbittorrent:8080` published
   to the LAN), so nothing downstream needs to change when you switch.
   `vpn` mode is mainly useful for indexers `setup.sh` reports as
   unreachable due to an ISP/network-level block rather than a
   Cloudflare-style challenge (which Byparr alone already handles) - note
   that in this mode, Prowlarr (and anything that depends on reaching it,
   like Sonarr/Radarr's indexer sync and its Caddy route) goes down if the
   VPN tunnel does, which isn't a concern in `novpn` mode.

   For `vpn` mode, Gluetun (the container that runs the tunnel) supports 30+
   VPN providers — see `.env.example` for ready-to-uncomment blocks for
   **Private Internet Access** (default, WireGuard, supports port
   forwarding), **ProtonVPN** (WireGuard, also supports port forwarding on
   paid plans), and **Mullvad** — all three have solid no-logging track
   records and work cleanly through Gluetun. Any other provider Gluetun
   supports (NordVPN, Surfshark, AirVPN, Windscribe, ...) works the same
   way: set `VPN_SERVICE_PROVIDER` to that provider's Gluetun name and fill
   in whichever variables its page on the
   [Gluetun wiki](https://github.com/qdm12/gluetun-wiki/tree/main/setup/providers)
   calls for — the compose file's `gluetun` service reads Gluetun's own
   variable names directly, so nothing else needs to change.

   With port forwarding on, `setup.sh` also keeps qBittorrent's listening
   port in sync with whatever port the VPN provider forwards (see
   `scripts/gluetun-port-forward-hook.sh`) - without this, incoming peer
   connections silently can't reach you, which hurts speed on
   less-popular torrents. Since `qbittorrent-vpn`/`prowlarr-vpn`/`byparr-vpn`
   share Gluetun's network namespace, they also go unreachable (though
   still shown "running") whenever Gluetun's own container restarts -
   `scripts/gluetun-watchdog.sh` + `systemd/gluetun-watchdog.service` restart
   them automatically when that happens. Install it once with:
   ```
   mkdir -p ~/.config/systemd/user
   cp systemd/gluetun-watchdog.service ~/.config/systemd/user/
   systemctl --user daemon-reload
   systemctl --user enable --now gluetun-watchdog.service
   sudo loginctl enable-linger "$USER"   # keeps it running without a login session
   ```

3. Bring up and configure the stack:

   ```bash
   docker compose up -d
   ./scripts/setup.sh
   ```

   `scripts/setup.sh` brings the containers up (if not already) and then
   wires them together via each app's API: Sonarr/Radarr get their root
   folders, qBittorrent download client, and Prowlarr indexers; Bazarr gets
   connected to Sonarr/Radarr with an English subtitle profile; Jellyfin's
   setup wizard is completed with your Movies/TV libraries; Seerr signs
   in through Jellyfin and connects to Sonarr/Radarr. It prompts for a
   shared admin username/password if `ADMIN_USERNAME`/`ADMIN_PASSWORD`
   aren't set in `.env` or in `~/secrets/homelab.sh` (a plain
   `ADMIN_USERNAME=...`/`ADMIN_PASSWORD=...` shell file outside this repo,
   for running it unattended), and picks a curated set of public indexers unless
   `PROWLARR_INDEXERS` says otherwise (see `.env.example`). It's safe to
   re-run — every step checks current state first and skips what's already
   configured. Requires `python3` with the `PyYAML` package (`pip install
   -r scripts/requirements.txt`) in addition to Docker.

   Any indexer that fails to add on the first attempt is retried once
   through Byparr, a Cloudflare/anti-bot bypass proxy Prowlarr talks to via
   its own "FlareSolverr"-compatible indexer proxy type — this only helps
   indexers behind a Cloudflare JS challenge, not sites blocked at the
   network/DNS/ISP level (no in-network proxy can bypass that; a VPN would
   be needed instead).

   Sonarr/Radarr also get a Recyclarr config generated from a curated
   TRaSH Guides quality-profile template (`recyclarr.sonarr_template`/
   `radarr_template` in `stack.yaml`), synced once immediately and then
   kept current on Recyclarr's own daily cron schedule with no further
   help from this script.

   Finally, a Homepage dashboard (`status.media.lan`) is generated with live
   widgets for every service above, wired up using the same API keys this
   script already collected. It's only generated once - the file
   (`config/homepage/services.yaml`) is left alone on later runs, so you can
   freely rearrange it by hand afterward. `homepage.media.lan` itself is a
   separate, simple static landing page (`caddy/site/index.html`) with a
   tile per service, meant as the everyday starting point for anyone on the
   LAN - Homepage's own dashboard app can't be served under a subpath of
   the same domain (a known upstream limitation), hence the two different
   addresses.

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
     `jellyfin.sh`, `seerr.sh`, `recyclarr.sh`, `homepage.sh`), each
     exposing a single `configure_<service>` entry point. `setup.sh`
     itself is just the orchestrator that sources these and calls them in
     order.

4. Add hosts-file entries (or LAN DNS records) pointing `*.media.lan` at
   this machine so Caddy's reverse proxy addresses resolve, then visit
   `https://homepage.media.lan` to get a tile for every service (or go
   straight to `https://sonarr.media.lan` etc.) and log in with the admin
   credentials from step 3. Your browser will warn about an untrusted
   certificate until you install Caddy's local CA root certificate — see
   TLS below.

5. **Optional: remote access via Tailscale.** Everything above is LAN-only.
   To reach the stack from anywhere, authorized via your Google (or GitHub/
   Microsoft) account, without exposing any public ports or DNS:

   - Create a free account at [tailscale.com](https://tailscale.com) if you
     don't have one, and sign in with Google - this is device-level tailnet
     membership (only devices you've authorized this way can reach
     anything below), not per-request app authentication like the
     OAuth2-Proxy diagram at the top of this README describes - a
     materially simpler model, well suited to "just let me and my household
     in from anywhere."
   - In the admin console, enable **HTTPS Certificates** under *DNS* /
     *Settings* if not already on - required for the automatic per-node
     certificates below.
   - Generate an auth key (*Settings → Keys → Generate auth key* -
     reusable, not ephemeral, is easiest) and add it as a new line in
     `~/secrets/homelab.sh` (the same file used for
     `ADMIN_USERNAME`/`ADMIN_PASSWORD` - see step 3):
     ```
     TS_AUTHKEY=tskey-...
     ```
   - Bring it up: `docker compose up -d tailscale` (or a full
     `./scripts/setup.sh` run, which exports `TS_AUTHKEY` for you). If no
     key was found, `docker logs tailscale` prints a one-time login URL
     instead - open it and sign in.
   - `tailscale/serve-config.json` declares what's reachable and gets a
     real, publicly-trusted certificate automatically (Tailscale's
     `${TS_CERT_DOMAIN}` placeholder resolves to this node's own MagicDNS
     name) - by default the landing page, Jellyfin, Seerr, qBittorrent, and
     the Homepage status dashboard, matching the LAN scope above. Edit it
     to add or remove services; each needs its own port (path-based routing
     on one port doesn't work for apps like Homepage that hardcode
     root-relative asset paths - see the landing-page/status-dashboard split
     above for why).
   - Once authenticated, find your node's MagicDNS name (`docker exec
     tailscale tailscale status`, or the admin console) and add
     `<name>:3000` to `HOMEPAGE_ALLOWED_HOSTS` in `docker-compose.yml`
     (comma-separated), then `docker compose up -d homepage` once - Homepage
     rejects requests whose `Host` header isn't an exact match including the
     port, and this hostname can't be known ahead of time.
   - If a Tailscale URL fails to connect from a device that also runs
     another VPN client (ProtonVPN, etc.), that's very likely the cause,
     not this stack - confirmed live in this project's own setup: a second
     VPN's routing can capture traffic meant for Tailscale's own tunnel
     even with its kill switch off. Disconnecting the other VPN (or setting
     up split-tunneling to exclude Tailscale, if it supports that) resolves
     it.
   - From any device signed into the same tailnet:
     `https://media-stack.<your-tailnet>.ts.net` (landing page) and
     `:8096`/`:5055`/`:8080`/`:3000` for the rest - no certificate warnings,
     no DNS setup, works the same on cellular data as at home.

## GPU hardware transcoding (Jellyfin)

`docker-compose.yml`'s `jellyfin` service already requests the GPU (an
NVIDIA `deploy.resources.reservations.devices` entry, plus
`NVIDIA_DRIVER_CAPABILITIES=compute,video,utility` so NVENC/NVDEC are
actually exposed, not just CUDA compute). It's hardcoded to NVIDIA — swap
the `driver: nvidia` device reservation for the Intel/AMD VAAPI approach
(bind-mounting `/dev/dri` instead) if this ever runs on different
hardware.

Two things still need doing on the host itself, once, since they're
privileged and outside Docker's reach:

1. **Install `nvidia-container-toolkit`** so Docker can actually hand a
   GPU to a container (`nvidia-smi` working on the host isn't enough by
   itself):

   ```bash
   curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey | sudo gpg --dearmor -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg
   curl -s -L https://nvidia.github.io/libnvidia-container/stable/deb/nvidia-container-toolkit.list | \
     sed 's#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://#g' | \
     sudo tee /etc/apt/sources.list.d/nvidia-container-toolkit.list
   sudo apt-get update
   sudo apt-get install -y nvidia-container-toolkit
   sudo nvidia-ctk runtime configure --runtime=docker
   sudo systemctl restart docker
   ```

   Verify it worked:

   ```bash
   docker run --rm --gpus all nvidia/cuda:12.4.1-base-ubuntu22.04 nvidia-smi
   ```

   That should print the same GPU table `nvidia-smi` shows on the host. If
   it instead errors with something like "could not select device driver
   ... with capabilities: [[gpu]]", the toolkit isn't installed/configured
   yet — redo the steps above rather than touching the compose file.

2. **Enable it in Jellyfin's dashboard**, after `docker compose up -d
   jellyfin` picks up the GPU reservation: *Dashboard → Playback* → set
   *Hardware acceleration* to `Nvidia NVENC`, tick the codecs you want
   hardware-decoded (H.264/HEVC/AV1 as your GPU generation supports), and
   save. Confirm it's actually being used during a transcode from
   *Dashboard → Dashboard* → the active playback session should show
   `(hw)` next to the video codec, not just the codec name alone.

## Vault (optional)

By default, this stack's secrets - `ADMIN_USERNAME`/`ADMIN_PASSWORD`, VPN
credentials, Tailscale's `TS_AUTHKEY` - live in plaintext in `.env` and
`~/secrets/homelab.sh`. Adding `vault` to `COMPOSE_PROFILES` moves those
into [mst-vault](../mst-vault) instead - a separate, standalone
HashiCorp Vault deployment on this same machine, shared with other tooling
(see its own README) - with `scripts/setup.sh` fetching them from there
rather than reading the files directly. This repo is only ever a *client*
of that Vault instance; it doesn't deploy or manage Vault itself.

**Scope**: only the secrets above. Each *arr app's own API key (Sonarr,
Radarr, Prowlarr, Bazarr, Jellyfin, Seerr) still gets auto-generated by that
service on first boot and read out of its own config file, exactly as
before - those never leave the local Docker network today, so routing them
through Vault too wouldn't add real security for real added complexity.

**Prerequisite**: mst-vault must already be running, initialized, and
unsealed at least once (`cd ~/vcs/personal/mst-vault && docker compose up -d
&& ./scripts/init.sh` - see its README). This stack unseals it automatically
on every `setup.sh` run after that (Vault reseals on every restart; mst-vault's
own `scripts/unseal.sh` handles it using the keys from its `secrets/vault-init.json`
- 3-of-5 Shamir shares, manually generated by `init.sh`, not something this
repo generates or stores its own copy of).

**Enable it**:

1. Add `vault` to `COMPOSE_PROFILES` in `.env` (e.g. `novpn,vault` or
   `vpn,vault`).
2. Run `./scripts/vault-migrate-secrets.sh` once - copies whatever's
   currently in `.env`/`~/secrets/homelab.sh` into Vault at
   `secret/mst-homelab-media-stack/{admin,vpn,tailscale}`.
3. Run `./scripts/setup.sh` - its log should show "Vault: fetched secrets
   from secret/mst-homelab-media-stack/...", and every step that needs
   those credentials (service logins, Tailscale auth, Gluetun's VPN
   connection) works exactly as before, just sourced from Vault.

Verify directly at any point:

```bash
cd ~/vcs/personal/mst-vault && source scripts/vault-env.sh
vault kv get secret/mst-homelab-media-stack/admin
```

**Disable it**: remove `vault` from `COMPOSE_PROFILES`. `scripts/setup.sh`
falls straight back to `.env`/`~/secrets/homelab.sh`/an interactive prompt,
identical to before this feature existed.

## Notes

- Per-service state lives under `./config/<service>/` (git-ignored).
- `.env` holds secrets and is git-ignored — only `.env.example` is
  committed.
- **dovi_convert**: open `dovi-convert.media.lan` for its web terminal, `cd`
  to `/data/media/...` and run `dovi_convert scan` on a title's folder to
  check it, then `dovi_convert convert <file>` to convert it. It backs up
  the original automatically (add `--delete` once you've confirmed the
  converted file plays correctly, to reclaim the space) and **skips
  "Complex FEL" files by default** — those use the enhancement layer for
  real brightness data rather than just redundant mapping, so converting
  them loses picture quality rather than just compatibility. Don't pass
  `--force` on a file it flagged as Complex FEL unless you've actually read
  why (its own docs explain the tradeoff) and decided it's worth it.
- **TLS**: `*.media.lan` isn't a real, publicly-resolvable domain, so it can
  never get a publicly-trusted Let's Encrypt certificate. The Caddyfile's
  `local_certs` option tells Caddy to self-sign one from its own internal CA
  instead — you still get real HTTPS (with an automatic HTTP→HTTPS
  redirect), but every device needs that CA's root certificate installed as
  trusted, or it'll show a certificate warning.

  After bringing the stack up, grab the root certificate with:

  ```bash
  docker cp caddy:/data/caddy/pki/authorities/local/root.crt ./config/caddy/local-ca-root.crt
  ```

  Then install it as a trusted root CA:
  - **Windows**: double-click the file → *Install Certificate* → *Local
    Machine* → *Place all certificates in the following store* → *Trusted
    Root Certification Authorities*.
  - **macOS**: double-click to add to Keychain Access, then find it and set
    *When using this certificate* to *Always Trust*.
  - **Android**: Settings → Security → *Encryption & credentials* → *Install
    a certificate* → *CA certificate*.
  - **iOS**: AirDrop or email yourself the file, install the resulting
    profile under Settings → *General* → *VPN & Device Management*, then
    enable full trust for it under Settings → *General* → *About* →
    *Certificate Trust Settings*.
  - **Linux**: copy it to `/usr/local/share/ca-certificates/`
    (as a `.crt` file) and run `sudo update-ca-certificates`; Firefox keeps
    its own certificate store separate from the OS, so it also needs
    importing under `about:preferences#privacy` → *View Certificates* →
    *Authorities* → *Import*.

  Some devices — smart TVs, some mobile apps — can't accept a custom CA at
  all. For those, keep using qBittorrent's/Jellyfin's/Seerr's own published
  ports directly (`http://<lan-ip>:8080`, `:8096`, `:5055`) instead of the
  Caddy route - e.g. the official Jellyfin app on an Android TV, which
  doesn't use the OS's user-added CA trust store the way a browser does.

  If you'd rather have genuinely publicly-trusted certificates with no
  per-device setup, and you own a domain on a DNS provider Caddy supports,
  swap `local_certs` for an `email` directive and a
  [DNS-challenge provider module](https://caddyserver.com/docs/automatic-https#dns-challenge)
  instead — the domain never needs to be internet-reachable, it's only used
  to prove ownership for the certificate.

- **LAN access from other devices (phones, smart TVs, etc.)**: those direct
  ports need to be reachable from the rest of your LAN, not just this
  machine. If this host runs under **WSL2 with mirrored networking**
  (`networkingMode=mirrored` in `.wslconfig`) - which shares the Windows
  host's real IP instead of a separate NAT'd one - Docker's published ports
  are already on that shared IP, but Windows Firewall still blocks other
  devices from reaching them until you add inbound allow rules (run as
  Administrator; scoped to the `Private` profile so nothing gets exposed via
  a VPN's own virtual adapter, which Windows typically marks `Public`):
  ```powershell
  New-NetFirewallRule -DisplayName "Homelab - Jellyfin" -Direction Inbound -Protocol TCP -LocalPort 8096 -Profile Private -Action Allow
  New-NetFirewallRule -DisplayName "Homelab - Jellyfin Discovery" -Direction Inbound -Protocol UDP -LocalPort 7359 -Profile Private -Action Allow
  New-NetFirewallRule -DisplayName "Homelab - Seerr" -Direction Inbound -Protocol TCP -LocalPort 5055 -Profile Private -Action Allow
  New-NetFirewallRule -DisplayName "Homelab - qBittorrent WebUI" -Direction Inbound -Protocol TCP -LocalPort 8080 -Profile Private -Action Allow
  New-NetFirewallRule -DisplayName "Homelab - Landing Page" -Direction Inbound -Protocol TCP -LocalPort 8888 -Profile Private -Action Allow
  ```
  The landing page itself (normally `homepage.media.lan`, see above) is also
  reachable this way at `http://<lan-ip>:8888` - plain HTTP on its own port,
  no hostname/DNS/certificate needed, for devices that can't resolve
  `*.media.lan` or don't accept the local CA.
  Test from an *actual other device* (phone browser, the TV app), not from
  this machine testing its own LAN IP — Windows commonly fails to "hairpin"
  a connection back to its own external address, which looks identical to a
  real block but isn't one.

- **Download safeguards**: several independent layers, each catching a
  different failure mode - no single one of these can guarantee a download
  is safe or correct, which is why there are several:
  - **File-type exclusions** (`scripts/config/qbittorrent-exclusions`):
    qBittorrent refuses to ever save executables, scripts, or other
    non-media file types, regardless of what's inside a torrent.
  - **ClamAV scan on completion** (`scripts/config/qbt-clamav-scan.sh`):
    every completed download is scanned against ClamAV's definitions (kept
    updated by the `clamav` container, shared read-only into qBittorrent)
    before Sonarr/Radarr ever see it. A match deletes the torrent and its
    files immediately - check `config/qbittorrent/clamav-scan.log` for a
    history of anything caught.
  - **Trusted-release scoring + minimum seeders**: Sonarr/Radarr's quality
    profiles are Recyclarr-managed (not their own zero-signal stock
    profiles - see below), so every grab is scored against TRaSH Guides'
    custom formats (trusted release groups favored, known-bad/obfuscated/
    fake releases penalized) rather than picked by resolution match alone.
    Every indexer also has a `minimum_seeders` floor (`scripts/config/
    stack.yaml`, default 5) to filter out just-published bait torrents with
    no real swarm behind them yet.
  - **What none of this can do**: verify that a video file's actual
    *content* matches its filename/label - that would need perceptual
    video/audio fingerprinting, which none of these tools do. If a
    correctly-named file turns out to have the wrong content after playing
    it, the recovery path is Radarr/Sonarr's own history: find the download
    in its History tab, "Mark as Failed" - this blocklists that specific
    release and triggers a re-search, so the next grab comes from a
    different (hopefully correct) release.

- **Quality profiles** (Recyclarr-managed, `config/recyclarr/configs/`):
  Radarr has three - `HD Bluray + WEB` (1080p ceiling), `WEBDL 2160p
  (Combined)` (1080p or 4K WEB-DL, upgrades toward 4K when available - this
  is Seerr's default, see `scripts/config/stack.yaml`'s
  `seerr.preferred_quality_profile_radarr`), and `Remux 2160p (Combined)`
  (same but includes much larger Bluray-disk/Remux tiers too, for when
  quality matters more than disk space - pick it manually per-request in
  Seerr's advanced options). Sonarr has `WEB-1080p`. All of them carry the
  same TRaSH Guides custom-format scoring described above.
