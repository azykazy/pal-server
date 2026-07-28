#!/usr/bin/env bash
# helpers.bash - bats テスト共通ヘルパー
# bats ファイルから load helpers で読み込む

_HELPERS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$_HELPERS_DIR/../.." && pwd)"
STUBS_DIR="$_HELPERS_DIR/stubs"

setup_common() {
  PALWORLD_DIR="$(mktemp -d)"
  PALWORLD_DATA_DIR="$PALWORLD_DIR/data"
  BLOB_STORE="$(mktemp -d)"
  STUB_DIR="$(mktemp -d)"

  export PALWORLD_DIR PALWORLD_DATA_DIR BLOB_STORE STUB_DIR
  export LOCAL_DEV=true
  export AZURITE_CONNECTION_STRING="stub"
  export ADMIN_PASSWORD=""
  export DISCORD_WEBHOOK_URL=""
  unset AZ_UPLOAD_FAIL AZ_DOWNLOAD_FAIL TAR_CREATE_FAIL TAR_EXTRACT_FAIL

  cp "$STUBS_DIR/az"     "$STUB_DIR/az"     && chmod +x "$STUB_DIR/az"
  cp "$STUBS_DIR/docker" "$STUB_DIR/docker" && chmod +x "$STUB_DIR/docker"
  cp "$STUBS_DIR/curl"   "$STUB_DIR/curl"   && chmod +x "$STUB_DIR/curl"
  cp "$STUBS_DIR/tar"    "$STUB_DIR/tar"    && chmod +x "$STUB_DIR/tar"

  export PATH="$STUB_DIR:$PATH"
}

teardown_common() {
  rm -rf "${PALWORLD_DIR:-}" "${STUB_DIR:-}" "${BLOB_STORE:-}"
}

# セーブデータのディレクトリ構造を作成する
# $1: PALWORLD_DATA_DIR
# $2: world_id
# $3: file_count (省略時 2)
make_save_data() {
  local data_dir="$1" world_id="$2" file_count="${3:-2}"
  local save_base="$data_dir/Pal/Saved/SaveGames/0"
  local ini_dir="$data_dir/Pal/Saved/Config/LinuxServer"

  mkdir -p "$save_base/$world_id" "$ini_dir"
  local i=1
  while [ "$i" -le "$file_count" ]; do
    echo "savedata$i" > "$save_base/$world_id/file$i.sav"
    i=$((i + 1))
  done
  echo "DedicatedServerName=$world_id" > "$ini_dir/GameUserSettings.ini"
}

# BLOB_STORE に latest.json を配置する
# $1: world_id
# $2: backup filename (e.g. 20260101-000000.tar.gz)
# $3: file_count (省略時 10)
put_latest_json() {
  local world_id="$1" filename="$2" file_count="${3:-10}"
  mkdir -p "$BLOB_STORE/save-backup"
  jq -n \
    --arg filename "$filename" \
    --arg world_id "$world_id" \
    --argjson file_count "$file_count" \
    --arg timestamp "2026-01-01T00:00:00Z" \
    '{filename: $filename, world_id: $world_id, file_count: $file_count, timestamp: $timestamp}' \
    > "$BLOB_STORE/save-backup/latest.json"
}

# BLOB_STORE にバックアップの tar.gz を配置する (実 tar を使う)
# $1: world_id
# $2: filename (e.g. 20260101-000000.tar.gz)
# $3: file_count (省略時 1)
put_backup_tar() {
  local world_id="$1" filename="$2" file_count="${3:-1}"
  local src
  src="$(mktemp -d)"
  mkdir -p "$src/$world_id"
  local i=1
  while [ "$i" -le "$file_count" ]; do
    echo "backup$i" > "$src/$world_id/file$i.sav"
    i=$((i + 1))
  done
  mkdir -p "$BLOB_STORE/save-backup"

  REAL_TAR=""
  for p in /usr/bin/tar /bin/tar /usr/local/bin/tar; do
    [ -x "$p" ] && REAL_TAR="$p" && break
  done
  "$REAL_TAR" -czf "$BLOB_STORE/save-backup/$filename" -C "$src" "$world_id"
  rm -rf "$src"
}
