#!/usr/bin/env bash
# 協力プレイのホストだったプレイヤーのデータを、専用サーバーで発番された新しい
# プレイヤー ID に引き継ぐ。
#
# 使用ツール: NFZ-441/Palworld-Co-op-to-Dedicated-Server-Migration-Tool
#   palworld-save-tools (pip 版) は Palworld v1.0 以降の PlM 形式に非対応のため、
#   PlM/PlZ 両対応の上記フォーク版を使用する。
#
# 前提: import-save.sh 済み + ホストが新サーバーに一度ログイン済み (新 ID の .sav が生成される)
# 使い方: bash scripts/fix-host-save.sh
#   → Players/ 配下の .sav を一覧表示し、新 GUID を選んで修正を実行する
set -euo pipefail
cd "$(dirname "$0")/.."

# terraform 不要 (Azure Cloud Shell でも実行可)。環境変数で上書き可能
RG="${RG:-pal-server}"
VM="${VM:-vm-palworld}"
OLD_GUID="00000000000000000000000000000001"

echo "== Players ディレクトリの確認 =="
az vm run-command invoke -g "$RG" -n "$VM" --command-id RunShellScript --scripts "
  W=\$(grep -oP 'DedicatedServerName=\K.*' /opt/palworld/data/Pal/Saved/Config/LinuxServer/GameUserSettings.ini)
  ls -la /opt/palworld/data/Pal/Saved/SaveGames/0/\$W/Players/
" --query "value[0].message" -o tsv | grep -E '\.sav|Players'

read -rp "ホストの新しい GUID (上の一覧の $OLD_GUID 以外の新しい .sav のファイル名、拡張子なし): " NEW_GUID
[ -n "$NEW_GUID" ] || { echo "GUID が空です"; exit 1; }

echo "== 修正ツールのセットアップと実行 (サーバー停止 → fix → 起動) =="
az vm run-command invoke -g "$RG" -n "$VM" --command-id RunShellScript --scripts "
  set -e
  systemctl stop palworld.service
  export DEBIAN_FRONTEND=noninteractive
  apt-get install -y -q python3-venv git >/dev/null

  # PlM/PlZ 両対応版をセットアップ (pip の palworld-save-tools は PlM 非対応)
  if [ ! -d /opt/psfix-v2 ]; then
    git clone -q https://github.com/NFZ-441/Palworld-Co-op-to-Dedicated-Server-Migration-Tool.git /opt/psfix-v2
    python3 -m venv /opt/psfix-v2/venv
    /opt/psfix-v2/venv/bin/pip install -q git+https://github.com/oMaN-Rod/pyooz.git
    cd /opt/psfix-v2 && git clone -q https://github.com/deafdudecomputers/PalworldSaveTools.git
  fi

  W=\$(grep -oP 'DedicatedServerName=\K.*' /opt/palworld/data/Pal/Saved/Config/LinuxServer/GameUserSettings.ini)
  SAVE=/opt/palworld/data/Pal/Saved/SaveGames/0/\$W
  cp -a \"\$SAVE\" \"/opt/palworld/save-backup-\$(date +%s)\"
  cd /opt/psfix-v2
  echo '' | /opt/psfix-v2/venv/bin/python fix_host_save.py \"\$SAVE\" $NEW_GUID $OLD_GUID --guild-fix
  chown -R 1000:1000 \"\$SAVE\"
  systemctl start palworld.service
  echo FIX_DONE
" --query "value[0].message" -o tsv | tail -10

echo "完了。ホストのキャラクターで再ログインして持ち物・拠点を確認してください。"
echo "(問題があれば /opt/palworld/save-backup-* にバックアップがあります)"
echo ""
echo "手持ちパルやインベントリが消えている場合は docs/SAVE-MIGRATION.md のトラブルシュートを参照してください。"
echo "(Level.sav をバックアップから復元して再 fix が必要な場合があります)"
