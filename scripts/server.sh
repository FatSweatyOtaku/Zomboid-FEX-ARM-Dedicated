#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

usage() {
  cat <<'HELP'
Usage: sudo ./scripts/server.sh {install|update|start|stop|restart|logs|status}

install : create private .env, SteamCMD install/validate PZ, apply FEX JVM flags, start
update  : stop PZ, SteamCMD game update/validate, apply flags, restart
start   : start existing server (also checks configured Workshop items)
stop    : graceful stop
restart : graceful stop/start (also checks configured Workshop items)
logs    : follow server logs (Ctrl+C stops watching only)
status  : show container status

Saves are preserved; no automatic world wipe is provided.
HELP
}

if [[ "${EUID}" -ne 0 ]]; then
  echo 'Run with sudo/root so Docker volumes can be configured.' >&2
  exit 1
fi

command -v docker >/dev/null || { echo 'Docker is required.' >&2; exit 1; }
docker compose version >/dev/null || { echo 'Docker Compose v2 is required.' >&2; exit 1; }

if [[ "$(uname -m)" != aarch64 ]]; then
  echo 'This deployment targets an ARM64/aarch64 Linux host.' >&2
  exit 1
fi

if [[ ! -f .env ]]; then
  if [[ "${1:-}" != install ]]; then
    echo 'No .env found. Run sudo ./scripts/server.sh install first.' >&2
    exit 1
  fi
  command -v openssl >/dev/null || { echo 'Install openssl first.' >&2; exit 1; }
  password="$(openssl rand -hex 20)"
  umask 077
  printf 'SERVER_NAME=servertest\nADMIN_PASSWORD=%s\nPZ_HEAP_GB=6\n' "$password" > .env
  chmod 600 .env
  echo 'Created .env with an automatically generated admin password.'
  echo 'Store .env privately; never commit it to GitHub.'
fi

set -a
# shellcheck disable=SC1091
source .env
set +a

[[ "${SERVER_NAME:-}" =~ ^[A-Za-z0-9_-]+$ ]] || { echo 'Invalid SERVER_NAME.' >&2; exit 1; }
[[ "${ADMIN_PASSWORD:-}" =~ ^[A-Za-z0-9_-]{12,}$ ]] || { echo 'ADMIN_PASSWORD must be >=12 letters/numbers/underscore/hyphen.' >&2; exit 1; }
[[ "${PZ_HEAP_GB:-}" =~ ^[0-9]+$ ]] || { echo 'PZ_HEAP_GB must be a number.' >&2; exit 1; }
(( PZ_HEAP_GB >= 2 && PZ_HEAP_GB <= 8 )) || { echo 'Choose PZ_HEAP_GB=2..8 for the 10GB container limit.' >&2; exit 1; }

COMPOSE=(docker compose -f "$ROOT/compose.yaml")

prepare_config_volume() {
  "${COMPOSE[@]}" run --rm --no-deps --user 0 --entrypoint /bin/sh server \
    -c 'chown -R 1001:1001 /project-zomboid-config'
}

run_steamcmd() {
  "${COMPOSE[@]}" --profile tools run --rm --no-deps installer
  mountpoint="$(docker volume inspect -f '{{.Mountpoint}}' pzfex-game)"
  [[ -f "$mountpoint/ProjectZomboid64" ]] || { echo 'Game executable missing after SteamCMD.' >&2; exit 1; }
  python3 "$ROOT/scripts/patch-jvm.py" "$mountpoint/ProjectZomboid64.json" "$PZ_HEAP_GB"
}

case "${1:-}" in
  install)
    "${COMPOSE[@]}" pull installer server
    run_steamcmd
    prepare_config_volume
    "${COMPOSE[@]}" up -d server
    echo 'Server starting; inspect with sudo ./scripts/server.sh logs'
    ;;
  update)
    "${COMPOSE[@]}" stop -t 90 server
    run_steamcmd
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
  *) usage; exit 2 ;;
esac
