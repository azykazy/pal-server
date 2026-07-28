#!/usr/bin/env bash
# 既存 VM のシェルスクリプトをリポジトリの最新版で上書き更新する。
# cloud-init (custom_data) は lifecycle.ignore_changes で既存 VM に再適用されないため、
# このスクリプトで手動反映する。
#
# 使い方:
#   bash scripts/update-vm-scripts.sh
#
# 前提:
#   - terraform apply 済みで terraform output が取得可能
#   - az login 済みで対象リソースグループへの権限がある
set -euo pipefail
cd "$(dirname "$0")/.."

echo "=== VM スクリプト更新 ==="

# ── Terraform output から変数を取得 ─────────────────────────────────
RG=$(terraform -chdir=terraform output -raw resource_group_name)
VM=$(terraform -chdir=terraform output -raw vm_name)
KV_NAME=$(terraform -chdir=terraform output -raw key_vault_name)
STORAGE=$(terraform -chdir=terraform output -raw storage_account_name)

KEY_VAULT_URI="https://${KV_NAME}.vault.azure.net/"
GAME_SETTINGS_BLOB_URL="https://${STORAGE}.blob.core.windows.net/game-config/settings.env"

# idle_checks: 環境変数 > terraform.tfvars > デフォルト値 (6) の優先順で取得。
# CI 環境では IDLE_CHECKS 環境変数を渡すことで tfvars なしでも動作する。
IDLE_CHECKS=${IDLE_CHECKS:-$(grep -oP 'idle_checks\s*=\s*\K\d+' terraform/terraform.tfvars 2>/dev/null || echo "6")}

echo "対象 VM : ${RG} / ${VM}"
echo "Key Vault: ${KEY_VAULT_URI}"
echo "Storage  : ${STORAGE}"
echo "idle_checks: ${IDLE_CHECKS}"
echo ""

# ── テンプレートをレンダリングして一時ディレクトリに配置 ──────────────
TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

# tftpl: Terraform 変数 ${VAR} を置換 → Terraform エスケープ $${...} を ${...} に展開
render_tftpl() {
  local src="$1" dst="$2"
  shift 2
  # まず Terraform 変数を sed で置換し、その後 $$ → $ を展開する
  local tmp
  tmp=$(mktemp)
  cp "$src" "$tmp"
  while [ $# -ge 2 ]; do
    local key="$1" val="$2"
    shift 2
    sed -i '' "s|\${${key}}|${val}|g" "$tmp"
  done
  sed 's/\$\$/$/g' "$tmp" > "$dst"
  rm -f "$tmp"
}

render_tftpl vm/fetch-secrets.sh.tftpl    "$TMPDIR/fetch-secrets.sh" \
  key_vault_uri         "$KEY_VAULT_URI" \
  game_settings_blob_url "$GAME_SETTINGS_BLOB_URL" \
  storage_account_name  "$STORAGE"

render_tftpl vm/auto-stop.sh.tftpl "$TMPDIR/auto-stop.sh" \
  idle_checks "$IDLE_CHECKS"

cp vm/palworld-stop.sh          "$TMPDIR/palworld-stop.sh"
cp vm/palworld-start-check.sh   "$TMPDIR/palworld-start-check.sh"
cp vm/self-update.sh            "$TMPDIR/self-update.sh"

# .vm-config を生成 (self-update.sh がテンプレートレンダリングに使用)
cat > "$TMPDIR/.vm-config" << EOF
# VM スクリプト更新用の設定ファイル (update-vm-scripts.sh が生成)
KEY_VAULT_URI='${KEY_VAULT_URI}'
GAME_SETTINGS_BLOB_URL='${GAME_SETTINGS_BLOB_URL}'
STORAGE_ACCOUNT_NAME='${STORAGE}'
IDLE_CHECKS='${IDLE_CHECKS}'
REPO_URL='https://github.com/azykazy/pal-server.git'
EOF

# ── VM に転送・上書き ────────────────────────────────────────────────
upload_script() {
  local name="$1" dest="$2" perms="${3:-+x}"
  local src="$TMPDIR/${name}"
  local encoded
  encoded=$(base64 < "$src" | tr -d '\n')
  echo -n "  転送中: ${dest} ... "
  az vm run-command invoke \
      -g "$RG" -n "$VM" \
      --command-id RunShellScript \
      --scripts "echo '${encoded}' | base64 -d > ${dest} && chmod ${perms} ${dest}" \
      --output none
  echo "完了"
}

upload_script fetch-secrets.sh        /opt/palworld/fetch-secrets.sh
upload_script palworld-stop.sh        /opt/palworld/palworld-stop.sh
upload_script palworld-start-check.sh /opt/palworld/palworld-start-check.sh
upload_script auto-stop.sh            /opt/palworld/auto-stop.sh
upload_script self-update.sh          /opt/palworld/self-update.sh
upload_script .vm-config              /opt/palworld/.vm-config 600

# ── palworld.service に self-update.sh を ExecStartPre として追加 ──────
# 既に登録済みの場合はスキップ (冪等)
echo -n "  palworld.service を更新中 ... "
az vm run-command invoke \
    -g "$RG" -n "$VM" \
    --command-id RunShellScript \
    --scripts "
grep -q 'self-update.sh' /etc/systemd/system/palworld.service || {
  sed -i '/ExecStartPre=.*fetch-secrets/i ExecStartPre=-/opt/palworld/self-update.sh' \
    /etc/systemd/system/palworld.service
  systemctl daemon-reload
}
" \
    --output none
echo "完了"

echo ""
echo "✅ 全スクリプトを更新しました。"
echo "   次回サーバー起動時 (/palworld start) から git pull が自動実行されます。"
