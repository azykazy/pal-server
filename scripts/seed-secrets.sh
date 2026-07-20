#!/usr/bin/env bash
# Key Vault にシークレットを投入し、Blob Storage にゲーム設定をアップロードする。
# 未指定のパスワードはランダム生成する。
#
# 使い方:
#   mise run seed-secrets                          # パスワード自動生成
#   DISCORD_WEBHOOK_URL=https://... mise run seed-secrets
#   SERVER_PASSWORD=xxx ADMIN_PASSWORD=yyy mise run seed-secrets
set -euo pipefail
cd "$(dirname "$0")/.."

VAULT=$(terraform -chdir=terraform output -raw key_vault_name)
STORAGE=$(terraform -chdir=terraform output -raw storage_account_name)

SERVER_PASSWORD="${SERVER_PASSWORD:-$(printf '%04d' $((RANDOM % 9000 + 1000)))}"
ADMIN_PASSWORD="${ADMIN_PASSWORD:-$(openssl rand -base64 32 | LC_ALL=C tr -dc 'A-Za-z0-9' | cut -c1-20)}"

az keyvault secret set --vault-name "$VAULT" --name server-password --value "$SERVER_PASSWORD" --output none
az keyvault secret set --vault-name "$VAULT" --name admin-password --value "$ADMIN_PASSWORD" --output none

if [ -n "${DISCORD_WEBHOOK_URL:-}" ]; then
  az keyvault secret set --vault-name "$VAULT" --name discord-webhook-url --value "$DISCORD_WEBHOOK_URL" --output none
  echo "discord-webhook-url を設定しました"
else
  echo "DISCORD_WEBHOOK_URL が未指定のためスキップしました (自動停止通知を使う場合は後で設定)"
fi

echo "Key Vault '$VAULT' に server-password / admin-password を設定しました"
echo "サーバー参加パスワードの確認: az keyvault secret show --vault-name $VAULT --name server-password --query value -o tsv"

# ── ゲーム設定を Blob Storage にアップロード ────────────────────
az storage blob upload \
  --account-name "$STORAGE" \
  --container-name "game-config" \
  --name "settings.env" \
  --file "vm/game-settings.env" \
  --auth-mode login \
  --overwrite \
  --output none
echo "ゲーム設定を Blob Storage ($STORAGE/game-config/settings.env) にアップロードしました"
