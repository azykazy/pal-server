#!/usr/bin/env bash
# ローカル動作確認環境の初回セットアップ。
# Azurite を起動し save-backup コンテナを作成する。
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
COMPOSE="docker compose -f $SCRIPT_DIR/docker-compose.yml"

log() { echo "[setup] $*"; }
err() { echo "[setup] エラー: $*" >&2; exit 1; }

echo "=== ローカル動作確認環境 セットアップ ==="

# ── 前提チェック ────────────────────────────────────────────
command -v docker >/dev/null 2>&1 || err "docker が見つかりません"
command -v az     >/dev/null 2>&1 || err "az CLI が見つかりません (https://learn.microsoft.com/cli/azure/install-azure-cli)"
command -v jq     >/dev/null 2>&1 || err "jq が見つかりません (brew install jq)"

# ── .env 生成 ───────────────────────────────────────────────
if [ ! -f "$SCRIPT_DIR/.env" ]; then
  cp "$SCRIPT_DIR/.env.example" "$SCRIPT_DIR/.env"
  log ".env を作成しました。必要に応じて編集: local/.env"
else
  log ".env は既に存在します (スキップ)"
fi

. "$SCRIPT_DIR/.env"

# ── palworld-data ディレクトリ ──────────────────────────────
mkdir -p "$SCRIPT_DIR/palworld-data"
log "palworld-data/ を確認"

# ── Azurite 起動 ────────────────────────────────────────────
log "Azurite を起動中..."
$COMPOSE up -d azurite

log -n "Azurite の起動を待機中"
for i in $(seq 1 30); do
  if curl -s --max-time 2 "http://127.0.0.1:10000/devstoreaccount1" -o /dev/null 2>&1; then
    echo ""
    log "Azurite 起動完了"
    break
  fi
  printf "."
  sleep 1
  if [ "$i" -eq 30 ]; then
    echo ""
    err "Azurite が 30 秒以内に起動しませんでした"
  fi
done

# ── save-backup コンテナ作成 ────────────────────────────────
CONN="${AZURITE_CONNECTION_STRING:-UseDevelopmentStorage=true}"

if az storage container show \
    --name save-backup \
    --connection-string "$CONN" \
    --output none 2>/dev/null; then
  log "save-backup コンテナは既に存在します"
else
  az storage container create \
    --name save-backup \
    --connection-string "$CONN" \
    --output none
  log "save-backup コンテナを作成しました"
fi

echo ""
echo "=== セットアップ完了 ==="
echo ""
echo "動作確認の手順:"
echo "  1. local/simulate-start.sh   # VM 起動を模倣（セーブ検証 → サーバー起動）"
echo "  2. (ゲームをプレイ)"
echo "  3. local/simulate-stop.sh    # VM 停止を模倣（セーブ → バックアップ → 停止）"
echo "  4. local/simulate-start.sh   # 再起動・セーブ復元フローを確認"
echo ""
echo "Palworld 接続先: 127.0.0.1:${GAME_PORT:-8211}"
echo "REST API:        http://127.0.0.1:8212/v1/api"
