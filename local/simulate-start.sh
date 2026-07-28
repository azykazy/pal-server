#!/usr/bin/env bash
# Azure VM の起動シーケンスをローカルで模倣する。
# vm/palworld-start-check.sh を LOCAL_DEV=true モードで実行するラッパー。
#
# systemd palworld.service の対応:
#   ExecStartPre: fetch-secrets.sh  → local/.env を直接読み込む
#   ExecStartPre: palworld-start-check.sh → LOCAL_DEV モードで実行
#   ExecStart:    docker compose up  → palworld コンテナを起動
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
COMPOSE="docker compose -f $SCRIPT_DIR/docker-compose.yml"

[ -f "$SCRIPT_DIR/.env" ] || {
  echo "エラー: local/.env が見つかりません。先に local/setup.sh を実行してください。"
  exit 1
}
. "$SCRIPT_DIR/.env"

# ── Azurite が起動していなければ起動 ───────────────────────────
if ! curl -s --max-time 2 "http://127.0.0.1:10000/devstoreaccount1" -o /dev/null 2>&1; then
  echo "[simulate-start] Azurite を起動中..."
  $COMPOSE up -d azurite
  for i in $(seq 1 30); do
    if curl -s --max-time 2 "http://127.0.0.1:10000/devstoreaccount1" -o /dev/null 2>&1; then
      break
    fi
    sleep 1
    [ "$i" -eq 30 ] && { echo "[simulate-start] ⚠️  Azurite が起動しませんでした" >&2; exit 1; }
  done
fi

# ── ExecStartPre: palworld-start-check.sh (LOCAL_DEV モード) ───
export LOCAL_DEV=true
export PALWORLD_DIR="$SCRIPT_DIR"
export PALWORLD_DATA_DIR="$SCRIPT_DIR/palworld-data"
export AZURITE_CONNECTION_STRING="${AZURITE_CONNECTION_STRING:-UseDevelopmentStorage=true}"
export DISCORD_WEBHOOK_URL="${DISCORD_WEBHOOK_URL:-}"

chmod +x "$REPO_ROOT/vm/palworld-start-check.sh"
"$REPO_ROOT/vm/palworld-start-check.sh"

# ── ExecStart: docker compose up ───────────────────────────────
echo "[simulate-start] === Palworld サーバー起動 ==="
$COMPOSE up -d palworld

echo ""
echo "[simulate-start] ✅ 起動完了"
echo "[simulate-start]   接続先:  127.0.0.1:${GAME_PORT:-8211}"
echo "[simulate-start]   REST API: http://127.0.0.1:8212/v1/api"
echo "[simulate-start]   ログ:    docker logs -f palworld-server"
echo ""
echo "[simulate-start] 注意: 初回起動時はゲーム本体のダウンロード (~20GB) のため接続可能になるまで時間がかかります"
