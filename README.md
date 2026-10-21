# Project Zomboid Build 42 Dedicated Server on ARM64 / FEX-Emu

A **vanilla, no-Workshop-mods** Docker Compose starting point for running the x86_64 Project Zomboid dedicated server on an **ARM64 Linux VPS**, using [FEX-Emu](https://github.com/FEX-Emu/FEX). Based on the architecture used for my personal Zomboid server on Oracle Cloud Always Free (Ampere A1, 4 OCPUs / 24 GiB).

> **Public preview / not yet independently end-to-end tested on a new VPS.** Steam, FEX, and Project Zomboid Build 42 change frequently. Contributions and verified installation reports are welcome.

## Requirements

- Linux **aarch64/ARM64** host (Oracle Cloud Ampere A1 is an example)
- Docker Engine, Docker Compose v2, Bash, Python 3, OpenSSL, cURL, unzip
- Recommended 4 OCPUs, 24 GiB RAM, 20+ GiB free disk and network access
- root/sudo permission to Docker and host-mounted volumes

Uses [supersunho/docker-fex-emu](https://github.com/supersunho/docker-fex-emu) to **run** the x86_64 game server and [SteamRE/DepotDownloader](https://github.com/SteamRE/DepotDownloader) to **download and update** the official Linux x86_64 game depots. SteamCMD previously failed under emulation, so the installer downloads a **native ARM64 DepotDownloader** release instead. This project does **not** bundle or redistribute game/Steam binaries. DepotDownloader requests Steam app `380870` anonymously.

## Quick start

```bash
git clone https://github.com/FatSweatyOtaku/Zomboid-FEX-ARM-Dedicated.git
cd Zomboid-FEX-ARM-Dedicated
sudo bash scripts/server.sh install
sudo bash scripts/server.sh logs
```

The install script creates a private `.env` with a **random 40-character hexadecimal admin password**, downloads and validates the dedicated server using native ARM64 DepotDownloader, applies FEX-specific JVM safeguards to the downloaded `ProjectZomboid64.json`, and starts the server. Retrieve the generated admin password using `sudo cat .env`; store it securely. First install downloads multiple gigabytes.

Default server name is `servertest`. Project Zomboid generates its default `servertest.ini` and `servertest_SandboxVars.lua` on first run. **No Workshop IDs or Mod IDs are configured.** Edit `.env` *before first startup* to change `SERVER_NAME` or `PZ_HEAP_GB` (default 6). The example caps the container at 10 GiB and 3 CPU cores.

### Networking

Allow **inbound UDP 16261 and 16262** in your cloud provider's ingress/security lists and your VPS firewall. The example also exposes Steam discovery UDP 8766/8767. Keep SSH restricted and never expose Docker's Unix socket or daemon TCP port publicly. RCON is not published by default.

### Commands

```bash
sudo bash scripts/server.sh install  # install/validate game & start
sudo bash scripts/server.sh update   # stop, update game with DepotDownloader, patch JVM, start
sudo bash scripts/server.sh restart  # triggers game's Workshop checks, if mods exist
sudo bash scripts/server.sh start
sudo bash scripts/server.sh stop
sudo bash scripts/server.sh status
sudo bash scripts/server.sh logs
```

Ctrl+C when following logs stops watching, **not** the server. Successful boots normally show `*** SERVER STARTED ****`. `update` uses DepotDownloader's `-validate` mode to check and update the game installation, not your Docker image. Run `docker compose pull` deliberately when updating upstream containers and read changelogs first.

## Persistence

Docker keeps four named volumes across image updates/restarts:

| Volume | Holds |
| --- | --- |
| `pzfex-game` | Dedicated server and Workshop downloads |
| `pzfex-config` | Generated INI, sandbox variables, world saves, player DB |
| `pzfex-steam-home` | Steam runtime data |
| `pzfex-steamapps` | Steam data |

Find the configuration path using:

```bash
sudo docker volume inspect -f '{{.Mountpoint}}' pzfex-config
```

The server's generated INI lives under `Server/servertest.ini` inside that volume, with its matching SandboxVars Lua alongside it. Stop the server before modifying them. For later Workshop use, `WorkshopItems=` requires numeric Workshop IDs, and `Mods=` requires the separate internal Mod IDs. They are **not interchangeable**.

**Do not delete `pzfex-config` unless you intend to lose the world and player data.** This repo deliberately has no world-wipe command. Back up volumes before migrations or major updates.

## FEX JVM workaround

`scripts/patch-jvm.py` edits only `vmArgs` in the official launcher JSON, retaining the rest of Steam's file. It configures ParallelGC, tier-1 JIT and targeted JVM compilation exclusions tested with this FEX setup; default Java max heap is 6 GiB. This is an experimental compatibility safeguard, not a guarantee. The install/update helper reapplies it after DepotDownloader validation.

## Troubleshooting

- Installation fails: look for the earliest DepotDownloader error; verify that GitHub releases and Steam content servers are reachable and that your ARM64 host meets the native .NET runtime's dependencies. Do not start with half-installed game files.
- Server fails to start: use `sudo bash scripts/server.sh logs`; check for missing `ProjectZomboid64`, JVM errors, and Script/WorldDictionary exceptions.
- Unable to connect: check the cloud ingress list **and** local host firewall and verify client/server versions match.
- Mods conflict: add in small batches and watch logs. A missing or removed Workshop item can block all clients.
- On a non-ARM host: this setup intentionally refuses to install; use a native AMD64 server distribution instead.
- Download method: the helper pins DepotDownloader release `DepotDownloader_3.4.0` and caches it under the ignored `.tools/` directory. It asks for **Linux, 64-bit depots** (`-app 380870 -os linux -osarch 64`). Game updates may overwrite `ProjectZomboid64.json`; the helper reapplies the FEX JVM flags afterward.

## License / third-party content

Steam, Project Zomboid, FEX-Emu, and upstream Docker images remain subject to their own licenses and terms. This example includes deployment definitions and helper scripts only.
