#!/usr/bin/env bash
# Key Vault にシークレットを投入する (Terraform には値を通さない)。
# 未指定のパスワードはランダム生成する。
#
# 使い方:
#   mise run seed-secrets                          # パスワード自動生成
#   DISCORD_WEBHOOK_URL=https://... mise run seed-secrets
#   SERVER_PASSWORD=xxx ADMIN_PASSWORD=yyy mise run seed-secrets  # 値を指定
set -euo pipefail
cd "$(dirname "$0")/.."

VAULT=$(terraform -chdir=terraform output -raw key_vault_name)

SERVER_PASSWORD="${SERVER_PASSWORD:-$(tr -dc 'A-Za-z0-9' </dev/urandom | head -c 14)}"
ADMIN_PASSWORD="${ADMIN_PASSWORD:-$(tr -dc 'A-Za-z0-9' </dev/urandom | head -c 20)}"

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
