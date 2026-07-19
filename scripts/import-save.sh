#!/usr/bin/env bash
# Blob (save-import コンテナ) にアップロードされたセーブ zip を VM に取り込み、
# ワールドを差し替える。VM が停止していれば IP を付けて起動し、プロビジョニング完了を待つ。
#
# 使い方: bash scripts/import-save.sh <blob名 (例: world.zip)>
set -euo pipefail
cd "$(dirname "$0")/.."

# terraform 不要 (Azure Cloud Shell でも実行可)。環境変数で上書き可能
BLOB_NAME="${1:?使い方: import-save.sh <blob名>}"
RG="${RG:-pal-server}"
VM="${VM:-vm-palworld}"
SA="${SA:-$(az storage account list -g "$RG" --query "[?starts_with(name,'stpalworld')].name" -o tsv)}"
PIP_NAME="${PIP_NAME:-pip-palworld}"
NIC_NAME="${NIC_NAME:-nic-palworld}"

echo "== 1/5 VM の起動 (必要なら Public IP を作成・接続) =="
STATE=$(az vm get-instance-view -g "$RG" -n "$VM" --query "instanceView.statuses[?starts_with(code,'PowerState/')].code | [0]" -o tsv)
if [ "$STATE" != "PowerState/running" ]; then
  az network public-ip show -g "$RG" -n "$PIP_NAME" -o none 2>/dev/null || \
    az network public-ip create -g "$RG" -n "$PIP_NAME" --sku Standard --allocation-method Static -o none
  az network nic ip-config update -g "$RG" --nic-name "$NIC_NAME" -n internal \
    --public-ip-address "$PIP_NAME" -o none
  az vm start -g "$RG" -n "$VM" -o none
fi

echo "== 2/5 プロビジョニング完了待ち (初回は10分程度) =="
for i in $(seq 1 40); do
  OUT=$(az vm run-command invoke -g "$RG" -n "$VM" --command-id RunShellScript \
    --scripts "test -f /var/lib/palworld-provisioned && echo READY || echo WAIT" \
    --query "value[0].message" -o tsv 2>/dev/null || echo "")
  if echo "$OUT" | grep -q READY; then echo "provisioned"; break; fi
  echo "  waiting ($i)..."
  sleep 30
done

echo "== 3/5 サーバーを一度起動してひな形を生成 → 停止 =="
az vm run-command invoke -g "$RG" -n "$VM" --command-id RunShellScript --scripts "
  systemctl start palworld.service
  for i in \$(seq 1 30); do
    test -f /opt/palworld/data/Pal/Saved/Config/LinuxServer/GameUserSettings.ini && break
    sleep 10
  done
  systemctl stop palworld.service
" --query "value[0].message" -o tsv | tail -3

echo "== 4/5 セーブ zip を VM へ取り込み =="
EXPIRY=$(date -u -v+1H '+%Y-%m-%dT%H:%MZ' 2>/dev/null || date -u -d '+1 hour' '+%Y-%m-%dT%H:%MZ')
SAS=$(az storage blob generate-sas --account-name "$SA" -c save-import -n "$BLOB_NAME" \
  --permissions r --expiry "$EXPIRY" --https-only -o tsv \
  --account-key "$(az storage account keys list -g "$RG" -n "$SA" --query '[0].value' -o tsv)")
URL="https://$SA.blob.core.windows.net/save-import/$BLOB_NAME?$SAS"

az vm run-command invoke -g "$RG" -n "$VM" --command-id RunShellScript --scripts "
  set -e
  cd /tmp && rm -rf save-import && mkdir save-import && cd save-import
  curl -fsS -o world.zip '$URL'
  python3 -m zipfile -e world.zip extracted/
  WORLD_DIR=\$(find extracted -maxdepth 3 -name Level.sav -printf '%h\n' | head -1)
  [ -n \"\$WORLD_DIR\" ] || { echo 'Level.sav が見つかりません'; exit 1; }
  HASH=\$(basename \"\$WORLD_DIR\")
  DEST=/opt/palworld/data/Pal/Saved/SaveGames/0/\$HASH
  rm -rf \"\$DEST\" && mkdir -p \"\$DEST\"
  cp -a \"\$WORLD_DIR\"/. \"\$DEST\"/
  chown -R 1000:1000 /opt/palworld/data/Pal/Saved/SaveGames
  sed -i \"s/DedicatedServerName=.*/DedicatedServerName=\$HASH/\" /opt/palworld/data/Pal/Saved/Config/LinuxServer/GameUserSettings.ini
  echo \"imported world: \$HASH\"
" --query "value[0].message" -o tsv | tail -5

echo "== 5/5 サーバーを再起動 =="
az vm run-command invoke -g "$RG" -n "$VM" --command-id RunShellScript \
  --scripts "systemctl start palworld.service" -o none
IP=$(az network public-ip show -g "$RG" -n "$PIP_NAME" --query ipAddress -o tsv)
echo "完了。接続先: $IP:8211 (ワールド読み込みに数分かかります)"
echo "次はフェーズ2: ホストが一度ログインしてから scripts/fix-host-save.sh を実行してください"
