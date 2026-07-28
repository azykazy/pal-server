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

# idle_checks は terraform.tfvars から取得（なければデフォルト 12）
IDLE_CHECKS=$(grep -oP 'idle_checks\s*=\s*\K\d+' terraform/terraform.tfvars 2>/dev/null || echo "12")

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
    sed -i "s|\${${key}}|${val}|g" "$tmp"
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

# ── VM に転送・上書き ────────────────────────────────────────────────
upload_script() {
  local name="$1" dest="$2"
  local src="$TMPDIR/${name}"
  echo -n "  転送中: ${dest} ... "
  az vm run-command invoke \
      -g "$RG" -n "$VM" \
      --command-id RunShellScript \
      --scripts "$(printf 'cat > %s << '"'"'__SCRIPT_EOF__'"'"'\n' "$dest")$(cat "$src")
__SCRIPT_EOF__
chmod +x ${dest}" \
      --output none
  echo "完了"
}

upload_script fetch-secrets.sh      /opt/palworld/fetch-secrets.sh
upload_script palworld-stop.sh      /opt/palworld/palworld-stop.sh
upload_script palworld-start-check.sh /opt/palworld/palworld-start-check.sh
upload_script auto-stop.sh          /usr/local/bin/auto-stop.sh

echo ""
echo "✅ 全スクリプトを更新しました。"
echo "   次回サーバー起動時 (/palworld start) から新しいスクリプトが使用されます。"
