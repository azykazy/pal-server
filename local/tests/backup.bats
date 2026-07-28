#!/usr/bin/env bats
# B1-B7: palworld-stop.sh backup tests
# Run: bats local/tests/backup.bats
# Requires: bats-core (brew install bats-core)

load helpers

setup() {
  setup_common
}

teardown() {
  teardown_common
}

@test "B1: save data exists -> tar.gz uploaded to save-backup" {
  make_save_data "$PALWORLD_DATA_DIR" "WORLD001" 3

  run bash -c "$REPO_ROOT/vm/palworld-stop.sh 2>&1"

  [ "$status" -eq 0 ]
  ls "$BLOB_STORE/save-backup/"*.tar.gz > /dev/null 2>&1
}

@test "B2: latest.json has correct world_id / file_count / timestamp" {
  make_save_data "$PALWORLD_DATA_DIR" "WORLD002" 5

  run bash -c "$REPO_ROOT/vm/palworld-stop.sh 2>&1"

  [ "$status" -eq 0 ]
  [ -f "$BLOB_STORE/save-backup/latest.json" ]

  world_id=$(jq -r '.world_id' "$BLOB_STORE/save-backup/latest.json")
  file_count=$(jq -r '.file_count' "$BLOB_STORE/save-backup/latest.json")
  timestamp=$(jq -r '.timestamp' "$BLOB_STORE/save-backup/latest.json")

  [ "$world_id" = "WORLD002" ]
  [ "$file_count" -eq 5 ]
  echo "$timestamp" | grep -qE '^[0-9]{4}-[0-9]{2}-[0-9]{2}T'
}

@test "B3: save dir missing -> skip backup, exit 0" {
  local ini_dir="$PALWORLD_DATA_DIR/Pal/Saved/Config/LinuxServer"
  mkdir -p "$ini_dir"
  echo "DedicatedServerName=NOEXIST" > "$ini_dir/GameUserSettings.ini"

  run bash -c "$REPO_ROOT/vm/palworld-stop.sh 2>&1"

  [ "$status" -eq 0 ]
  [ -z "$(find "${BLOB_STORE}" -name '*.tar.gz' 2>/dev/null)" ]
}

@test "B4: GameUserSettings.ini missing -> skip backup, exit 0" {
  local save_base="$PALWORLD_DATA_DIR/Pal/Saved/SaveGames/0/WORLD004"
  mkdir -p "$save_base"
  echo "data" > "$save_base/file1.sav"

  run bash -c "$REPO_ROOT/vm/palworld-stop.sh 2>&1"

  [ "$status" -eq 0 ]
  [ -z "$(find "${BLOB_STORE}" -name '*.tar.gz' 2>/dev/null)" ]
}

@test "B5: duplicate DedicatedServerName lines -> correct world_id in backup" {
  local ini_dir="$PALWORLD_DATA_DIR/Pal/Saved/Config/LinuxServer"
  local save_base="$PALWORLD_DATA_DIR/Pal/Saved/SaveGames/0/WORLD005"
  mkdir -p "$save_base" "$ini_dir"
  echo "data" > "$save_base/file.sav"
  printf 'DedicatedServerName=WORLD005\nDedicatedServerName=WORLD005\n' \
    > "$ini_dir/GameUserSettings.ini"

  run bash -c "$REPO_ROOT/vm/palworld-stop.sh 2>&1"

  [ "$status" -eq 0 ]
  [ -f "$BLOB_STORE/save-backup/latest.json" ]
  world_id=$(jq -r '.world_id' "$BLOB_STORE/save-backup/latest.json")
  [ "$world_id" = "WORLD005" ]
}

@test "B6: tar compression fails -> skip backup, exit 0 (server stop continues)" {
  make_save_data "$PALWORLD_DATA_DIR" "WORLD006" 2
  export TAR_CREATE_FAIL=true

  run bash -c "$REPO_ROOT/vm/palworld-stop.sh 2>&1"

  [ "$status" -eq 0 ]
  [ -z "$(find "${BLOB_STORE}" -name '*.tar.gz' 2>/dev/null)" ]
}

@test "B7: az upload fails -> exit 0 (server stop is not blocked)" {
  make_save_data "$PALWORLD_DATA_DIR" "WORLD007" 2
  export AZ_UPLOAD_FAIL=true

  run bash -c "$REPO_ROOT/vm/palworld-stop.sh 2>&1"

  [ "$status" -eq 0 ]
}
