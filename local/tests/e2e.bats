#!/usr/bin/env bats
# E1-E3: simulate-stop -> simulate-start integration tests
# Requires: Docker running, Azurite container available, local/.env present
# Run: bats local/tests/e2e.bats

load helpers

LOCAL_DIR="$REPO_ROOT/local"

setup() {
  command -v docker > /dev/null 2>&1 || skip "Docker not installed"
  docker info > /dev/null 2>&1 || skip "Docker not running"
  [ -f "$LOCAL_DIR/.env" ] || skip "local/.env not found (run local/setup.sh first)"

  TEST_DATA_DIR="$(mktemp -d)"
  SAVE_BASE="$TEST_DATA_DIR/Pal/Saved/SaveGames/0"
  make_save_data "$TEST_DATA_DIR" "TESTWORLD" 10
  export TEST_DATA_DIR SAVE_BASE
}

teardown() {
  rm -rf "${TEST_DATA_DIR:-}"
}

@test "E1: simulate-stop then simulate-start produces validation complete" {
  PALWORLD_DATA_DIR="$TEST_DATA_DIR" bash "$LOCAL_DIR/simulate-stop.sh"

  run bash -c "PALWORLD_DATA_DIR='$TEST_DATA_DIR' '$LOCAL_DIR/simulate-start.sh' 2>&1"

  [ "$status" -eq 0 ]
  echo "$output" | grep -q "✅"
}

@test "E2: simulate-stop then delete save then simulate-start restores data" {
  PALWORLD_DATA_DIR="$TEST_DATA_DIR" bash "$LOCAL_DIR/simulate-stop.sh"
  rm -rf "$SAVE_BASE/TESTWORLD"

  run bash -c "PALWORLD_DATA_DIR='$TEST_DATA_DIR' '$LOCAL_DIR/simulate-start.sh' 2>&1"

  [ "$status" -eq 0 ]
  [ -d "$SAVE_BASE/TESTWORLD" ]
}

@test "E3: simulate-stop then reduce files then simulate-start warns but continues" {
  PALWORLD_DATA_DIR="$TEST_DATA_DIR" bash "$LOCAL_DIR/simulate-stop.sh"
  find "$SAVE_BASE/TESTWORLD" -type f | tail -8 | xargs rm -f

  run bash -c "PALWORLD_DATA_DIR='$TEST_DATA_DIR' '$LOCAL_DIR/simulate-start.sh' 2>&1"

  [ "$status" -eq 0 ]
}
