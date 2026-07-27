#!/usr/bin/env bash
# VM起動時にローカルセーブデータをBlob Storageのバックアップと比較・検証する。
# セーブが消失していれば自動復元し、不整合があれば Discord に通知する。
# systemd ExecStartPre で実行されるため、常に exit 0 で終了してサーバー起動を阻害しない。
set -u

log()  { echo "[start-check] $*"; }
warn() { echo "[start-check] ⚠️  $*" >&2; }

[ -f /opt/palworld/.env ] && . /opt/palworld/.env

SAVE_BASE=/opt/palworld/data/Pal/Saved/SaveGames/0

if [ -z "${STORAGE_ACCOUNT:-}" ]; then
  log "STORAGE_ACCOUNT 未設定 (スキップ)"
  exit 0
fi

# IMDS からストレージトークン取得
STORAGE_TOKEN=$(curl -fsS --max-time 15 \
  -H "Metadata: true" \
  "http://169.254.169.254/metadata/identity/oauth2/token?api-version=2018-02-01&resource=https%3A%2F%2Fstorage.azure.com" \
  | jq -r .access_token 2>/dev/null) || { warn "ストレージトークン取得失敗 (スキップ)"; exit 0; }

CONTAINER_URL="https://${STORAGE_ACCOUNT}.blob.core.windows.net/save-backup"

# Blob Storage から latest.json を取得
LATEST=$(curl -fsS --max-time 15 \
  -H "Authorization: Bearer $STORAGE_TOKEN" \
  -H "x-ms-version: 2020-10-02" \
  "$CONTAINER_URL/latest.json" 2>/dev/null) || { log "バックアップ情報なし (初回起動の可能性)"; exit 0; }

BACKUP_FILENAME=$(echo "$LATEST" | jq -r '.filename // empty')
BACKUP_WORLD_ID=$(echo "$LATEST" | jq -r '.world_id // empty')
BACKUP_FILE_COUNT=$(echo "$LATEST" | jq -r '.file_count // 0')
BACKUP_TIMESTAMP=$(echo "$LATEST" | jq -r '.timestamp // empty')

if [ -z "$BACKUP_FILENAME" ] || [ -z "$BACKUP_WORLD_ID" ]; then
  warn "latest.json の内容が不正 (スキップ)"
  exit 0
fi

log "最新バックアップ: $BACKUP_FILENAME (ワールド: $BACKUP_WORLD_ID, ファイル数: $BACKUP_FILE_COUNT, 時刻: $BACKUP_TIMESTAMP)"

notify_discord() {
  local msg="$1"
  if [ -n "${DISCORD_WEBHOOK_URL:-}" ]; then
    curl -fsS --max-time 10 -X POST "$DISCORD_WEBHOOK_URL" \
      -H "Content-Type: application/json" \
      -d "$(jq -n --arg content "$msg" '{content: $content}')" || true
  fi
}

restore_from_backup() {
  log "バックアップから復元中: $BACKUP_FILENAME"
  local tmp="/tmp/palworld-restore-$BACKUP_FILENAME"
  mkdir -p "$SAVE_BASE"
  if curl -fsS --max-time 300 \
      -H "Authorization: Bearer $STORAGE_TOKEN" \
      -H "x-ms-version: 2020-10-02" \
      "$CONTAINER_URL/$BACKUP_FILENAME" \
      -o "$tmp"; then
    if tar -xzf "$tmp" -C "$SAVE_BASE"; then
      log "✅ 復元完了: $SAVE_BASE/$BACKUP_WORLD_ID"
      notify_discord "✅ **Palworld セーブデータを復元しました**\nバックアップ: \`$BACKUP_FILENAME\` ($BACKUP_TIMESTAMP)"
    else
      warn "tar 展開失敗"
      notify_discord "⚠️ **Palworld セーブデータ復元失敗**\n\`tar\` の展開に失敗しました。手動で確認してください。"
    fi
    rm -f "$tmp"
  else
    warn "バックアップダウンロード失敗"
    notify_discord "⚠️ **Palworld セーブデータ復元失敗**\nバックアップのダウンロードに失敗しました。"
    rm -f "$tmp" 2>/dev/null || true
  fi
}

# ── ローカルセーブを確認 ─────────────────────────────────────────────
LOCAL_WORLD_DIR=$(find "$SAVE_BASE" -maxdepth 1 -mindepth 1 -type d 2>/dev/null | head -1)

# ケース1: ローカルセーブが存在しない → バックアップから復元
if [ -z "$LOCAL_WORLD_DIR" ]; then
  warn "ローカルセーブデータが見つかりません。バックアップから復元します"
  notify_discord "⚠️ **Palworld セーブデータが見つかりません**\nバックアップ (\`$BACKUP_FILENAME\`) から復元を試みます..."
  restore_from_backup
  exit 0
fi

LOCAL_WORLD_ID=$(basename "$LOCAL_WORLD_DIR")
LOCAL_FILE_COUNT=$(find "$LOCAL_WORLD_DIR" -type f 2>/dev/null | wc -l | tr -d ' ')

log "ローカルセーブ: ワールド=$LOCAL_WORLD_ID, ファイル数=$LOCAL_FILE_COUNT"

# ケース2: ワールドID不一致 → 警告のみ (自動復元はしない)
if [ "$LOCAL_WORLD_ID" != "$BACKUP_WORLD_ID" ]; then
  warn "ワールドIDが不一致: ローカル=$LOCAL_WORLD_ID バックアップ=$BACKUP_WORLD_ID"
  notify_discord "⚠️ **Palworld セーブデータ警告**\nワールドIDが不一致です。手動で確認してください。\nローカル: \`$LOCAL_WORLD_ID\`\nバックアップ: \`$BACKUP_WORLD_ID\`"
  exit 0
fi

# ケース3: ファイル数がバックアップの半分未満 → 警告のみ
if [ "$BACKUP_FILE_COUNT" -gt 0 ] && [ "$LOCAL_FILE_COUNT" -lt "$((BACKUP_FILE_COUNT / 2))" ]; then
  warn "ローカルファイル数が少なすぎます: ローカル=$LOCAL_FILE_COUNT / バックアップ=$BACKUP_FILE_COUNT"
  notify_discord "⚠️ **Palworld セーブデータ警告**\nセーブファイル数が異常に少ない可能性があります。\nローカル: $LOCAL_FILE_COUNT ファイル / バックアップ: $BACKUP_FILE_COUNT ファイル\n手動での確認をお勧めします。"
  exit 0
fi

# 正常
log "✅ セーブデータ検証完了: 正常 (ワールド: $LOCAL_WORLD_ID, ファイル数: $LOCAL_FILE_COUNT / バックアップ: $BACKUP_FILE_COUNT)"
exit 0
