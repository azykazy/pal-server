#!/usr/bin/env bash
# Palworld を安全に停止する: REST API で save → shutdown → compose down → Blob バックアップ
# (セーブデータ破損を防ぐため、コンテナを直接 kill しない)
set -u
cd /opt/palworld

# ADMIN_PASSWORD / STORAGE_ACCOUNT は fetch-secrets.sh が .env に書き込む
[ -f /opt/palworld/.env ] && . /opt/palworld/.env

API="http://127.0.0.1:8212/v1/api"
CRED="admin:${ADMIN_PASSWORD:-}"

if docker compose ps --status running 2>/dev/null | grep -q palworld-server; then
  curl -fsS --max-time 30 -u "$CRED" -X POST "$API/save" || true
  curl -fsS --max-time 10 -u "$CRED" -X POST "$API/shutdown" \
    -H "Content-Type: application/json" \
    -d '{"waittime":10,"message":"Server is shutting down."}' || true
  sleep 20
fi

docker compose down --timeout 60 || true

# ── セーブデータを Blob Storage にバックアップ ──────────────────
if [ -n "${STORAGE_ACCOUNT:-}" ]; then
  SAVE_BASE=/opt/palworld/data/Pal/Saved/SaveGames/0
  WORLD_DIR=$(find "$SAVE_BASE" -maxdepth 1 -mindepth 1 -type d 2>/dev/null | head -1)
  if [ -n "$WORLD_DIR" ]; then
    BACKUP_NAME="$(date -u +%Y%m%d-%H%M%S).tar.gz"
    echo "セーブデータをバックアップ中: $BACKUP_NAME"
    if tar -czf "/tmp/$BACKUP_NAME" -C "$SAVE_BASE" "$(basename "$WORLD_DIR")"; then
      STORAGE_TOKEN=$(curl -fsS --max-time 15 -H "Metadata: true" \
        "http://169.254.169.254/metadata/identity/oauth2/token?api-version=2018-02-01&resource=https%3A%2F%2Fstorage.azure.com" \
        | jq -r .access_token)
      if curl -fsS --max-time 120 -X PUT \
          -H "Authorization: Bearer $STORAGE_TOKEN" \
          -H "x-ms-version: 2020-10-02" \
          -H "x-ms-blob-type: BlockBlob" \
          -H "Content-Type: application/gzip" \
          --data-binary @"/tmp/$BACKUP_NAME" \
          "https://${STORAGE_ACCOUNT}.blob.core.windows.net/save-backup/$BACKUP_NAME"; then
        echo "バックアップ完了: save-backup/$BACKUP_NAME"
        # 起動時の検証に使う latest.json を更新する
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
      rm -f "/tmp/$BACKUP_NAME"
    else
      echo "tar 失敗 (バックアップをスキップ)" >&2
    fi
  else
    echo "セーブデータが見つかりません (バックアップをスキップ)"
  fi
fi
