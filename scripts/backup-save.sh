#!/usr/bin/env bash
# サーバーを停止せずにセーブデータを手動バックアップする。
# 起動中のサーバーに REST API で save を要求してから Blob にアップロードする。
#
# 使い方: bash scripts/backup-save.sh
set -euo pipefail
cd "$(dirname "$0")/.."

RG="${RG:-pal-server}"
VM="${VM:-vm-palworld}"

echo "バックアップを開始します..."

az vm run-command invoke -g "$RG" -n "$VM" \
  --command-id RunShellScript \
  --scripts '
    set -eu
    PALWORLD_DIR="${PALWORLD_DIR:-/opt/palworld}"
    cd "$PALWORLD_DIR"

    [ -f "$PALWORLD_DIR/.env" ] && . "$PALWORLD_DIR/.env"

    # サーバーが起動中であれば REST API でセーブを要求する
    if docker compose ps --status running 2>/dev/null | grep -q palworld-server; then
      NETRC=$(mktemp)
      chmod 600 "$NETRC"
      printf "machine 127.0.0.1 login admin password %s\n" "${ADMIN_PASSWORD:-}" > "$NETRC"
      echo "サーバーにセーブを要求中..."
      curl -fsS --max-time 30 --netrc-file "$NETRC" -X POST "http://127.0.0.1:8212/v1/api/save" \
        && echo "セーブ完了" \
        || echo "セーブ要求失敗（続行）"
      rm -f "$NETRC"
      sleep 3
    else
      echo "サーバーは停止中（そのままバックアップ）"
    fi

    PALWORLD_DATA_DIR="${PALWORLD_DATA_DIR:-$PALWORLD_DIR/data}"
    SAVE_BASE="$PALWORLD_DATA_DIR/Pal/Saved/SaveGames/0"
    SETTINGS="$PALWORLD_DATA_DIR/Pal/Saved/Config/LinuxServer/GameUserSettings.ini"

    WORLD_HASH=$(sed -n "s/^DedicatedServerName=//p" "$SETTINGS" 2>/dev/null | head -1 | tr -d "[:space:]" || true)
    WORLD_DIR="${SAVE_BASE}/${WORLD_HASH}"

    if [ -z "$WORLD_HASH" ] || [ ! -d "$WORLD_DIR" ]; then
      echo "ERROR: セーブデータが見つかりません" >&2
      exit 1
    fi

    BACKUP_NAME="manual-$(date -u +%Y%m%d-%H%M%S).tar.gz"
    echo "バックアップ作成中: $BACKUP_NAME"

    if ! tar -czf "/tmp/$BACKUP_NAME" -C "$SAVE_BASE" "$(basename "$WORLD_DIR")"; then
      echo "ERROR: tar 失敗" >&2
      exit 1
    fi

    IMDS_RESPONSE=$(curl -fsS --max-time 15 -H "Metadata: true" \
      "http://169.254.169.254/metadata/identity/oauth2/token?api-version=2018-02-01&resource=https%3A%2F%2Fstorage.azure.com" 2>&1) || true
    STORAGE_TOKEN=$(echo "$IMDS_RESPONSE" | jq -r .access_token 2>/dev/null || true)

    if [ -z "${STORAGE_TOKEN:-}" ] || [ "$STORAGE_TOKEN" = "null" ]; then
      echo "ERROR: IMDS トークン取得失敗: $IMDS_RESPONSE" >&2
      rm -f "/tmp/$BACKUP_NAME"
      exit 1
    fi

    if curl -fsS --max-time 120 -X PUT \
        -H "Authorization: Bearer $STORAGE_TOKEN" \
        -H "x-ms-version: 2020-10-02" \
        -H "x-ms-blob-type: BlockBlob" \
        -H "Content-Type: application/gzip" \
        --data-binary @"/tmp/$BACKUP_NAME" \
        "https://${STORAGE_ACCOUNT}.blob.core.windows.net/save-backup/$BACKUP_NAME"; then
      WORLD_ID=$(basename "$WORLD_DIR")
      FILE_COUNT=$(find "$WORLD_DIR" -type f 2>/dev/null | wc -l | tr -d " ")
      echo "バックアップ完了: save-backup/$BACKUP_NAME (ワールド: $WORLD_ID, ファイル数: $FILE_COUNT)"
    else
      echo "ERROR: Blob へのアップロードに失敗しました" >&2
      rm -f "/tmp/$BACKUP_NAME"
      exit 1
    fi

    rm -f "/tmp/$BACKUP_NAME"
  ' \
  --query "value[0].message" -o tsv 2>/dev/null \
  | sed 's/^Enable succeeded:[[:space:]]*//'
