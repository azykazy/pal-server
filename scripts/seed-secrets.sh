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
FUNC_NAME=$(terraform -chdir=terraform output -raw function_app_name)
STORAGE=$(terraform -chdir=terraform output -raw storage_account_name)
RG=$(terraform -chdir=terraform output -raw resource_group_name)

SERVER_PASSWORD="${SERVER_PASSWORD:-$(printf '%04d' $((RANDOM % 9000 + 1000)))}"
ADMIN_PASSWORD="${ADMIN_PASSWORD:-$(openssl rand -base64 32 | LC_ALL=C tr -dc 'A-Za-z0-9' | cut -c1-20)}"

az keyvault secret set --vault-name "$VAULT" --name server-password --value "$SERVER_PASSWORD" --output none
az keyvault secret set --vault-name "$VAULT" --name admin-password --value "$ADMIN_PASSWORD" --output none

# Function Key を az CLI から取得して Key Vault に格納する。
# Terraform state / cloud-init には Function Key を含めないことで漏洩リスクを低減する。
FUNC_HOSTNAME=$(az functionapp show --name "$FUNC_NAME" --resource-group "$RG" --query defaultHostName -o tsv)
FUNC_KEY=$(az functionapp keys list --name "$FUNC_NAME" --resource-group "$RG" --query functionKeys.default -o tsv)
INTERNAL_STOP_URL="https://$FUNC_HOSTNAME/api/internal-stop?code=$FUNC_KEY"
az keyvault secret set --vault-name "$VAULT" --name internal-stop-url --value "$INTERNAL_STOP_URL" --output none
echo "internal-stop-url を Key Vault に設定しました"

if [ -n "${DISCORD_WEBHOOK_URL:-}" ]; then
  az keyvault secret set --vault-name "$VAULT" --name discord-webhook-url --value "$DISCORD_WEBHOOK_URL" --output none
  echo "discord-webhook-url を設定しました"
else
  echo "DISCORD_WEBHOOK_URL が未指定のためスキップしました (自動停止通知を使う場合は後で設定)"
fi

echo "Key Vault '$VAULT' に server-password / admin-password を設定しました"
echo "サーバー参加パスワードの確認: az keyvault secret show --vault-name $VAULT --name server-password --query value -o tsv"

# ── ゲーム設定を Blob Storage にアップロード ────────────────────
STORAGE_KEY=$(az storage account keys list --account-name "$STORAGE" --resource-group "$RG" --query "[0].value" -o tsv)
az storage blob upload \
  --account-name "$STORAGE" \
  --account-key "$STORAGE_KEY" \
  --container-name "game-config" \
  --name "settings.env" \
  --file "vm/game-settings.env" \
  --overwrite \
  --output none
echo "ゲーム設定を Blob Storage ($STORAGE/game-config/settings.env) にアップロードしました"
