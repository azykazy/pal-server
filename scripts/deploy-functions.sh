#!/usr/bin/env bash
# Functions のコードを zip 化して Flex Consumption にデプロイする。
#
# 注意: `az functionapp deployment source config-zip` と Terraform の zip_deploy_file は
# Flex 非対応の SCM_DO_BUILD_DURING_DEPLOYMENT を注入して失敗するため使わない。
# OneDeploy API (/api/publish) を直接呼ぶ。
set -euo pipefail
cd "$(dirname "$0")/.."

bash scripts/build-functions.sh

APP=$(terraform -chdir=terraform output -raw function_app_name)
RG=$(terraform -chdir=terraform output -raw resource_group_name)
TOKEN=$(az account get-access-token --query accessToken -o tsv)
SCM="https://$APP.scm.azurewebsites.net"

HTTP=$(curl -s -o /dev/null -w '%{http_code}' -X POST \
  -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/zip" \
  --data-binary @dist/functions.zip \
  "$SCM/api/publish?RemoteBuild=false&Deployer=deploy-functions" --max-time 300)
if [ "$HTTP" != "202" ] && [ "$HTTP" != "200" ]; then
  echo "publish に失敗しました (HTTP $HTTP)" >&2
  exit 1
fi

echo "デプロイ受理 (HTTP $HTTP)。完了を待機中..."
for i in $(seq 1 30); do
  sleep 15
  STATUS=$(curl -fsS -H "Authorization: Bearer $TOKEN" "$SCM/api/deployments/latest" | jq -r .status)
  case "$STATUS" in
    4) echo "デプロイ完了。関数一覧:";
       az functionapp function list --resource-group "$RG" --name "$APP" --query "[].name" -o tsv;
       exit 0 ;;
    3) echo "デプロイ失敗:" >&2;
       curl -fsS -H "Authorization: Bearer $TOKEN" "$SCM/api/deployments/latest" | jq -r .status_text >&2;
       exit 1 ;;
    *) echo "  進行中 (status=$STATUS)" ;;
  esac
done
echo "タイムアウト。Portal のデプロイセンターで状況を確認してください" >&2
exit 1
