#!/usr/bin/env bats
# R1-R9: palworld-start-check.sh restore and validation tests
# Run: bats local/tests/restore.bats
# Requires: bats-core (brew install bats-core)

load helpers

setup() {
  setup_common
  SAVE_BASE="$PALWORLD_DATA_DIR/Pal/Saved/SaveGames/0"
}

teardown() {
  teardown_common
}

@test "R1: backup exists, no local save -> restored from backup" {
  put_latest_json "WORLD001" "20260101-000000.tar.gz" 2
  put_backup_tar "WORLD001" "20260101-000000.tar.gz" 2

  run bash -c "$REPO_ROOT/vm/palworld-start-check.sh 2>&1"

  [ "$status" -eq 0 ]
  [ -d "$SAVE_BASE/WORLD001" ]
}

@test "R2: tar extraction fails -> Discord notified, exit 0" {
  put_latest_json "WORLD002" "20260101-000000.tar.gz" 1
  put_backup_tar "WORLD002" "20260101-000000.tar.gz" 1
  export TAR_EXTRACT_FAIL=true

  run bash -c "$REPO_ROOT/vm/palworld-start-check.sh 2>&1"

  [ "$status" -eq 0 ]
  [ ! -d "$SAVE_BASE/WORLD002" ]
}

@test "R3: download fails -> Discord notified, exit 0" {
  put_latest_json "WORLD003" "20260101-000000.tar.gz" 1
  # No tar.gz in BLOB_STORE -> az download returns exit 1

  run bash -c "$REPO_ROOT/vm/palworld-start-check.sh 2>&1"

  [ "$status" -eq 0 ]
  [ ! -d "$SAVE_BASE/WORLD003" ]
}

@test "R4: world_id mismatch -> no auto-restore, warning only, exit 0" {
  put_latest_json "BACKUP_WORLD" "20260101-000000.tar.gz" 10
  make_save_data "$PALWORLD_DATA_DIR" "LOCAL_WORLD" 10

  run bash -c "$REPO_ROOT/vm/palworld-start-check.sh 2>&1"

  [ "$status" -eq 0 ]
  [ -d "$SAVE_BASE/LOCAL_WORLD" ]     # auto-restore did NOT happen
  [ ! -d "$SAVE_BASE/BACKUP_WORLD" ]  # backup world was NOT extracted
  echo "$output" | grep -q "LOCAL_WORLD"
}

@test "R5: local file count less than half of backup -> warning only, exit 0" {
  put_latest_json "WORLD005" "20260101-000000.tar.gz" 20
  make_save_data "$PALWORLD_DATA_DIR" "WORLD005" 2  # less than half of 20

  run bash -c "$REPO_ROOT/vm/palworld-start-check.sh 2>&1"

  [ "$status" -eq 0 ]
  local_count=$(find "$SAVE_BASE/WORLD005" -type f 2>/dev/null | wc -l | tr -d ' ')
  [ "$local_count" -eq 2 ]  # files were NOT changed (no restore)
}

@test "R6: backup has 0 files -> no divide-by-zero, exit 0" {
  put_latest_json "WORLD006" "20260101-000000.tar.gz" 0
  make_save_data "$PALWORLD_DATA_DIR" "WORLD006" 3

  run bash -c "$REPO_ROOT/vm/palworld-start-check.sh 2>&1"

  [ "$status" -eq 0 ]
}

@test "R7: latest.json missing (first boot) -> log no-backup message, exit 0" {
  # No latest.json in BLOB_STORE

  run bash -c "$REPO_ROOT/vm/palworld-start-check.sh 2>&1"

  [ "$status" -eq 0 ]
  # No save data was created
  [ -z "$(find "$PALWORLD_DATA_DIR" -type d -name 'SaveGames' 2>/dev/null)" ] || \
    [ -z "$(find "$SAVE_BASE" -maxdepth 1 -mindepth 1 -type d 2>/dev/null)" ]
}

@test "R8: latest.json has invalid content -> warn and exit 0" {
  mkdir -p "$BLOB_STORE/save-backup"
  echo '{"invalid_field": true}' > "$BLOB_STORE/save-backup/latest.json"

  run bash -c "$REPO_ROOT/vm/palworld-start-check.sh 2>&1"

  [ "$status" -eq 0 ]
  echo "$output" | grep -qi "latest.json"
}

@test "R9: world_id and file count match -> validation complete message, exit 0" {
  put_latest_json "WORLD009" "20260101-000000.tar.gz" 5
  make_save_data "$PALWORLD_DATA_DIR" "WORLD009" 5

  run bash -c "$REPO_ROOT/vm/palworld-start-check.sh 2>&1"

  [ "$status" -eq 0 ]
  echo "$output" | grep -q "✅"
}
