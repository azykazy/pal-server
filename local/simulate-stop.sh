#!/usr/bin/env bash
# Azure VM の停止シーケンスをローカルで模倣する。
# vm/palworld-stop.sh を LOCAL_DEV=true モードで実行するラッパー。
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

[ -f "$SCRIPT_DIR/.env" ] || { echo "エラー: local/.env が見つかりません。先に local/setup.sh を実行してください。"; exit 1; }
. "$SCRIPT_DIR/.env"

export LOCAL_DEV=true
export PALWORLD_DIR="$SCRIPT_DIR"
export PALWORLD_DATA_DIR="$SCRIPT_DIR/palworld-data"
export AZURITE_CONNECTION_STRING="${AZURITE_CONNECTION_STRING:-UseDevelopmentStorage=true}"
export ADMIN_PASSWORD="${ADMIN_PASSWORD:-}"
export DISCORD_WEBHOOK_URL="${DISCORD_WEBHOOK_URL:-}"

exec "$REPO_ROOT/vm/palworld-stop.sh"
