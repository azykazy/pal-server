#!/usr/bin/env bash
# 起動時に GitHub から最新コードを pull し、VM 上のスクリプトを更新する。
# palworld.service の ExecStartPre として fetch-secrets.sh より前に実行される。
# git 取得に失敗してもサーバー起動を阻害しないよう、エラーは警告に留めて exit 0 する。

PALWORLD_DIR="${PALWORLD_DIR:-/opt/palworld}"
REPO_DIR="$PALWORLD_DIR/repo"
CONFIG_FILE="$PALWORLD_DIR/.vm-config"

log()  { echo "[self-update] $*"; }
warn() { echo "[self-update] ⚠️  $*" >&2; }

if [ ! -f "$CONFIG_FILE" ]; then
  log ".vm-config がありません。スキップします"
  exit 0
fi

# shellcheck disable=SC1090
. "$CONFIG_FILE"

if [ -z "${REPO_URL:-}" ]; then
  log "REPO_URL が未設定です。スキップします"
  exit 0
fi

# ── git clone または pull ────────────────────────────────────────────
if [ -d "$REPO_DIR/.git" ]; then
  log "git pull: $REPO_URL"
  if ! git -C "$REPO_DIR" pull --ff-only --quiet 2>&1; then
    warn "git pull 失敗。既存スクリプトを継続使用します"
    exit 0
  fi
else
  log "git clone: $REPO_URL"
  if ! git clone --depth=1 --quiet "$REPO_URL" "$REPO_DIR" 2>&1; then
    warn "git clone 失敗。スキップします"
    exit 0
  fi
fi

# ── 非テンプレートファイルをコピー ───────────────────────────────────
# install はコピー先を別 inode に置き換えるため、実行中スクリプトへの上書きが安全
install -m 0700 "$REPO_DIR/vm/palworld-stop.sh"        "$PALWORLD_DIR/palworld-stop.sh"
install -m 0700 "$REPO_DIR/vm/palworld-start-check.sh" "$PALWORLD_DIR/palworld-start-check.sh"
install -m 0700 "$REPO_DIR/vm/self-update.sh"          "$PALWORLD_DIR/self-update.sh"

# ── tftpl をレンダリング ──────────────────────────────────────────────
# Terraform 変数 ${VAR} を置換し、Terraform エスケープ $${...} を ${...} に展開する。
# sed -i は Linux 構文 (macOS と異なり空文字引数不要)
render_tftpl() {
  local src="$1" dst="$2"
  shift 2
  local tmp
  tmp=$(mktemp)
  cp "$src" "$tmp"
  while [ $# -ge 2 ]; do
    local key="$1" val="$2"
    shift 2
    sed -i "s|\${${key}}|${val}|g" "$tmp"
  done
  sed 's/\$\$/$/g' "$tmp" > "$dst"
  rm -f "$tmp"
  chmod +x "$dst"
}

render_tftpl "$REPO_DIR/vm/fetch-secrets.sh.tftpl" "$PALWORLD_DIR/fetch-secrets.sh" \
  key_vault_uri          "${KEY_VAULT_URI}" \
  game_settings_blob_url "${GAME_SETTINGS_BLOB_URL}" \
  storage_account_name   "${STORAGE_ACCOUNT_NAME}"

render_tftpl "$REPO_DIR/vm/auto-stop.sh.tftpl" "/usr/local/bin/auto-stop.sh" \
  idle_checks "${IDLE_CHECKS}"

log "✅ スクリプト更新完了"
