#!/usr/bin/env bash
# Palworld を安全に停止する: REST API で save → shutdown → compose down → Blob バックアップ
# (セーブデータ破損を防ぐため、コンテナを直接 kill しない)
#
# LOCAL_DEV=true のとき:
#   - PALWORLD_DIR で作業ディレクトリを指定 (デフォルト: /opt/palworld)
#   - Blob アップロードを IMDS+curl ではなく az storage CLI (Azurite) で行う
#   - AZURITE_CONNECTION_STRING で接続先を指定
set -u

PALWORLD_DIR="${PALWORLD_DIR:-/opt/palworld}"
cd "$PALWORLD_DIR"

# ADMIN_PASSWORD / STORAGE_ACCOUNT は fetch-secrets.sh が .env に書き込む
[ -f "$PALWORLD_DIR/.env" ] && . "$PALWORLD_DIR/.env"

API="http://127.0.0.1:8212/v1/api"

# ADMIN_PASSWORD をコマンドライン引数に露出させないため netrc で認証
NETRC=$(mktemp)
chmod 600 "$NETRC"
printf 'machine 127.0.0.1 login admin password %s\n' "${ADMIN_PASSWORD:-}" > "$NETRC"
trap 'rm -f "$NETRC"' EXIT

if docker compose ps --status running 2>/dev/null | grep -q palworld-server; then
  curl -fsS --max-time 30 --netrc-file "$NETRC" -X POST "$API/save" || true
  curl -fsS --max-time 10 --netrc-file "$NETRC" -X POST "$API/shutdown" \
    -H "Content-Type: application/json" \
    -d '{"waittime":10,"message":"Server is shutting down."}' || true
  for i in $(seq 1 20); do
    docker compose ps --status running 2>/dev/null | grep -q palworld-server || break
    sleep 1
  done
fi

if [ "${LOCAL_DEV:-false}" = "true" ]; then
  # ローカル: Azurite を残して palworld だけ停止
  docker compose stop palworld 2>/dev/null || true
  docker compose rm -f palworld 2>/dev/null || true
else
  docker compose down --timeout 60 || true
fi

# ── セーブデータをバックアップ ──────────────────────────────────
# パスはローカル開発時に PALWORLD_DATA_DIR で上書き可能
PALWORLD_DATA_DIR="${PALWORLD_DATA_DIR:-$PALWORLD_DIR/data}"
SAVE_BASE="$PALWORLD_DATA_DIR/Pal/Saved/SaveGames/0"
SETTINGS="$PALWORLD_DATA_DIR/Pal/Saved/Config/LinuxServer/GameUserSettings.ini"

# sed で取得 (GNU grep -oP がない macOS でも動作)
WORLD_HASH=$(sed -n 's/^DedicatedServerName=//p' "$SETTINGS" 2>/dev/null | head -1 | tr -d '[:space:]' || true)
WORLD_DIR="${SAVE_BASE}/${WORLD_HASH}"

if [ -z "$WORLD_HASH" ] || [ ! -d "$WORLD_DIR" ]; then
  echo "セーブデータが見つかりません (バックアップをスキップ)"
  exit 0
fi

BACKUP_NAME="$(date -u +%Y%m%d-%H%M%S).tar.gz"
echo "セーブデータをバックアップ中: $BACKUP_NAME"

if ! tar -czf "/tmp/$BACKUP_NAME" -C "$SAVE_BASE" "$(basename "$WORLD_DIR")"; then
  echo "tar 失敗 (バックアップをスキップ)" >&2
  exit 0
fi

if [ "${LOCAL_DEV:-false}" = "true" ]; then
  # ローカル: az storage CLI で Azurite にアップロード
  CONN="${AZURITE_CONNECTION_STRING:-UseDevelopmentStorage=true}"
  az storage blob upload \
    --container-name save-backup \
    --name "$BACKUP_NAME" \
    --file "/tmp/$BACKUP_NAME" \
    --connection-string "$CONN" \
    --overwrite \
    --output none

  WORLD_ID=$(basename "$WORLD_DIR")
  FILE_COUNT=$(find "$WORLD_DIR" -type f 2>/dev/null | wc -l | tr -d ' ')
  LATEST_JSON=$(jq -n \
    --arg filename "$BACKUP_NAME" \
    --arg world_id "$WORLD_ID" \
    --argjson file_count "$FILE_COUNT" \
    --arg timestamp "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    '{filename: $filename, world_id: $world_id, file_count: $file_count, timestamp: $timestamp}')
  echo "$LATEST_JSON" > "/tmp/$BACKUP_NAME.json"
  az storage blob upload \
    --container-name save-backup \
    --name latest.json \
    --file "/tmp/$BACKUP_NAME.json" \
    --connection-string "$CONN" \
    --overwrite \
    --output none
  rm -f "/tmp/$BACKUP_NAME.json"
  echo "バックアップ完了: save-backup/$BACKUP_NAME (ワールド: $WORLD_ID, ファイル数: $FILE_COUNT)"
else
  # Azure VM: IMDS Managed Identity でトークン取得 → Blob Storage に curl でアップロード
  STORAGE_TOKEN=$(curl -fsS --max-time 15 -H "Metadata: true" \
    "http://169.254.169.254/metadata/identity/oauth2/token?api-version=2018-02-01&resource=https%3A%2F%2Fstorage.azure.com" \
    | jq -r .access_token) || true
  if [ -z "${STORAGE_TOKEN:-}" ] || [ "$STORAGE_TOKEN" = "null" ]; then
    echo "IMDS トークン取得失敗 (バックアップをスキップ)" >&2
  elif curl -fsS --max-time 120 -X PUT \
      -H "Authorization: Bearer $STORAGE_TOKEN" \
      -H "x-ms-version: 2020-10-02" \
      -H "x-ms-blob-type: BlockBlob" \
      -H "Content-Type: application/gzip" \
      --data-binary @"/tmp/$BACKUP_NAME" \
      "https://${STORAGE_ACCOUNT}.blob.core.windows.net/save-backup/$BACKUP_NAME"; then
    echo "バックアップ完了: save-backup/$BACKUP_NAME"
    WORLD_ID=$(basename "$WORLD_DIR")
    FILE_COUNT=$(find "$WORLD_DIR" -type f 2>/dev/null | wc -l | tr -d ' ')
    LATEST_JSON=$(jq -n \
      --arg filename "$BACKUP_NAME" \
      --arg world_id "$WORLD_ID" \
      --argjson file_count "$FILE_COUNT" \
      --arg timestamp "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
      '{filename: $filename, world_id: $world_id, file_count: $file_count, timestamp: $timestamp}')
    if curl -fsS --max-time 30 -X PUT \
        -H "Authorization: Bearer $STORAGE_TOKEN" \
        -H "x-ms-version: 2020-10-02" \
        -H "x-ms-blob-type: BlockBlob" \
        -H "Content-Type: application/json" \
        --data-binary "$LATEST_JSON" \
        "https://${STORAGE_ACCOUNT}.blob.core.windows.net/save-backup/latest.json"; then
      echo "latest.json 更新完了 (ワールド: $WORLD_ID, ファイル数: $FILE_COUNT)"
    else
      echo "latest.json 更新失敗 (停止処理は継続)" >&2
    fi
  else
    echo "バックアップ失敗 (停止処理は継続)" >&2
  fi
fi

rm -f "/tmp/$BACKUP_NAME"
