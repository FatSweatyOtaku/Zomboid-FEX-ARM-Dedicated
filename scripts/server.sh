#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

# Native ARM64 DepotDownloader release. Pin so deployments are reproducible.
DEPOT_VERSION="DepotDownloader_3.4.0"
DEPOT_URL="https://github.com/SteamRE/DepotDownloader/releases/download/${DEPOT_VERSION}/DepotDownloader-linux-arm64.zip"
DEPOT_DIR="$ROOT/.tools/${DEPOT_VERSION}"

usage() {
  cat <<'HELP'
Usage: sudo bash scripts/server.sh {install|update|start|stop|restart|logs|status}

install : generate password, install dedicated server with ARM64 DepotDownloader, patch JVM, start
update  : stop server, update/validate game with DepotDownloader, patch JVM, start
start   : start existing server (game checks configured Workshop items)
stop    : graceful stop
restart : graceful stop/start (game checks configured Workshop items)
logs    : follow logs (Ctrl+C stops watching only)
status  : show container status

Game: Steam anonymous app 380870, Linux x86_64 depots, downloaded by native ARM64 binary.
Saves are preserved. This script does not wipe worlds, reset mods, or update Docker images.
HELP
}

if [[ "${EUID}" -ne 0 ]]; then
  echo 'Run as root or with sudo.' >&2
  exit 1
fi

for name in docker python3; do
  command -v "$name" >/dev/null || { echo "Missing dependency: $name" >&2; exit 1; }
done
docker compose version >/dev/null || { echo 'Docker Compose v2 is required.' >&2; exit 1; }

if [[ "$(uname -m)" != aarch64 ]]; then
  echo 'This deployment targets an ARM64/aarch64 Linux host.' >&2
  exit 1
fi

ACTION="${1:-}"
if [[ ! -f .env ]]; then
  if [[ "$ACTION" != install ]]; then
    echo 'No .env found. Run sudo bash scripts/server.sh install first.' >&2
    exit 1
  fi
  command -v openssl >/dev/null || { echo 'Install openssl first.' >&2; exit 1; }
  password="$(openssl rand -hex 20)"
  umask 077
  printf 'SERVER_NAME=servertest\nADMIN_PASSWORD=%s\nPZ_HEAP_GB=6\n' "$password" > .env
  chmod 600 .env
  echo 'Created .env with random admin password. Keep it private.'
fi

set -a
# shellcheck disable=SC1091
source "$ROOT/.env"
set +a

[[ "${SERVER_NAME:-}" =~ ^[A-Za-z0-9_-]+$ ]] || { echo 'Invalid SERVER_NAME.' >&2; exit 1; }
[[ "${ADMIN_PASSWORD:-}" =~ ^[A-Za-z0-9_-]{12,}$ ]] || { echo 'ADMIN_PASSWORD must be >=12 letters/numbers/underscore/hyphen.' >&2; exit 1; }
[[ "${PZ_HEAP_GB:-}" =~ ^[0-9]+$ ]] || { echo 'PZ_HEAP_GB must be a number.' >&2; exit 1; }
(( PZ_HEAP_GB >= 2 && PZ_HEAP_GB <= 8 )) || { echo 'Choose PZ_HEAP_GB=2..8 for 10GB container limit.' >&2; exit 1; }

COMPOSE=(docker compose -f "$ROOT/compose.yaml")

ensure_depotdownloader() {
  if [[ -x "$DEPOT_DIR/DepotDownloader" ]]; then
    return
  fi
  for name in curl unzip find; do
    command -v "$name" >/dev/null || { echo "Missing dependency: $name" >&2; exit 1; }
  done

  mkdir -p "$ROOT/.tools"
  local temp bin
  temp="$(mktemp -d "$ROOT/.tools/.download-XXXXXXXX")"
  echo "Downloading native ARM64 DepotDownloader ${DEPOT_VERSION}..."
  if ! curl --fail --location --retry 3 --silent --show-error \
      "$DEPOT_URL" -o "$temp/release.zip"; then
    rm -rf "$temp"
    echo 'DepotDownloader release download failed.' >&2
    exit 1
  fi
  mkdir -p "$temp/unpacked"
  if ! unzip -q "$temp/release.zip" -d "$temp/unpacked"; then
    rm -rf "$temp"
    echo 'DepotDownloader ZIP extraction failed.' >&2
    exit 1
  fi

  bin="$(find "$temp/unpacked" -type f -name DepotDownloader -print -quit)"
  if [[ -z "$bin" ]]; then
    rm -rf "$temp"
    echo 'DepotDownloader binary missing from release archive.' >&2
    exit 1
  fi
  mkdir -p "$DEPOT_DIR"
  cp -a "$(dirname "$bin")/." "$DEPOT_DIR/"
  chmod 755 "$DEPOT_DIR/DepotDownloader"
  rm -rf "$temp"
}

prepare_persistent_volumes() {
  # Running as root only for initial ownership repair of empty volumes.
  "${COMPOSE[@]}" run --rm --no-deps --user 0 --entrypoint /bin/sh server \
    -c 'for p in /project-zomboid /project-zomboid-config /home/steam/.steam /home/steam/Steam; do mkdir -p "$p"; chown 1001:1001 "$p"; done'
}

run_depotdownloader() {
  ensure_depotdownloader
  docker volume create pzfex-game >/dev/null
  local game
  game="$(docker volume inspect -f '{{.Mountpoint}}' pzfex-game)"
  [[ -d "$game" ]] || { echo 'Docker game volume missing.' >&2; exit 1; }

  echo 'Downloading/validating Project Zomboid dedicated server app 380870...'
  "$DEPOT_DIR/DepotDownloader" \
    -app 380870 -os linux -osarch 64 \
    -dir "$game" -validate

  [[ -f "$game/ProjectZomboid64" ]] || {
    echo 'Expected ProjectZomboid64 not found after DepotDownloader.' >&2
    exit 1
  }
  [[ -f "$game/ProjectZomboid64.json" ]] || {
    echo 'Expected ProjectZomboid64.json not found after DepotDownloader.' >&2
    exit 1
  }
  python3 "$ROOT/scripts/patch-jvm.py" "$game/ProjectZomboid64.json" "$PZ_HEAP_GB"
  chown -R 1001:1001 "$game"
}

case "$ACTION" in
  install)
    "${COMPOSE[@]}" pull server
    run_depotdownloader
    prepare_persistent_volumes
    "${COMPOSE[@]}" up -d server
    echo 'Server starting; inspect with sudo bash scripts/server.sh logs'
    ;;
  update)
    "${COMPOSE[@]}" stop -t 90 server
    echo 'Server stopped for updating. If update fails, it stays stopped to avoid loading incomplete files.'
    run_depotdownloader
    prepare_persistent_volumes
    "${COMPOSE[@]}" up -d server
    ;;
  start)
    "${COMPOSE[@]}" up -d server
    ;;
  stop)
    "${COMPOSE[@]}" stop -t 90 server
    ;;
  restart)
    "${COMPOSE[@]}" stop -t 90 server
    "${COMPOSE[@]}" up -d server
    ;;
  logs)
    "${COMPOSE[@]}" logs -f --tail 200 server
    ;;
  status)
    "${COMPOSE[@]}" ps -a
    ;;
  *)
    usage
    exit 2
    ;;
esac
