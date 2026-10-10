#!/usr/bin/env bash
# Brings Plane up. Safe to re-run at any time.
#
#   ./start.sh            full stack in Docker (built from this checkout)
#   ./start.sh --build    same, rebuilding the images first
#   ./start.sh dev        databases + API in Docker, frontends with `pnpm dev`
#
# When ../infra-dev exists (override with INFRA_DEV=<path>) the stack goes
# through its Traefik; otherwise it is served on LISTEN_HTTP_PORT from .env.
set -euo pipefail
SELF=$(realpath "${BASH_SOURCE[0]}")
cd "$(dirname "$SELF")"

INFRA_DEV=${INFRA_DEV:-../infra-dev}

mode=stack
args=()
for arg in "$@"; do
  case $arg in
    dev) mode=dev ;;
    --build) args+=(--build) ;;
    -h|--help) sed -n '2,9p' "$SELF" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown argument: $arg (see ./start.sh --help)" >&2; exit 1 ;;
  esac
done

# Fresh clone: generate the .env files. setup.sh overwrites them, so only
# run it when they are missing.
if [[ ! -f .env || ! -f apps/api/.env ]]; then
  echo "==> generating .env files"
  ./setup.sh
fi

if [[ $mode == stack ]]; then
  if [[ -x $INFRA_DEV/start.sh ]]; then
    exec "$INFRA_DEV/start.sh" "${args[@]}" plane
  fi
  echo "==> $INFRA_DEV not found, starting standalone"
  [[ ${#args[@]} -gt 0 ]] && docker compose build
  docker compose up -d
  echo "ready: $(grep -E '^PLANE_URL=' .env | cut -d= -f2-)"
  exit 0
fi

# dev mode -------------------------------------------------------------------

[[ ${#args[@]} -eq 0 ]] || { echo "--build does not apply to dev mode" >&2; exit 1; }

want_node=$(cat .node-version)
if command -v mise >/dev/null || [[ -x $HOME/.local/bin/mise ]]; then
  mise=$(command -v mise || echo "$HOME/.local/bin/mise")
  "$mise" install --quiet
  eval "$("$mise" env -s bash)"
fi
have_node=$(node -v 2>/dev/null || true)
if [[ ${have_node#v} != "$want_node" ]]; then
  echo "need node $want_node, found ${have_node:-none} (install mise: https://mise.jdx.dev)" >&2
  exit 1
fi
command -v pnpm >/dev/null || corepack enable pnpm

# Reinstall only when the lockfile changed since the last install.
if [[ ! -f node_modules/.modules.yaml || pnpm-lock.yaml -nt node_modules/.modules.yaml ]]; then
  echo "==> installing dependencies"
  pnpm install --frozen-lockfile
fi

echo "==> databases + API"
if [[ -x $INFRA_DEV/bin/stack ]]; then
  "$INFRA_DEV/bin/doctor" plane-dev
  "$INFRA_DEV/bin/stack" plane-dev up
else
  docker compose -f docker-compose-local.yml up -d
fi

echo "==> frontends (web :3000, admin :3001, space :3002, live :3100)"
exec pnpm dev
