#!/usr/bin/env bash
# Palworld サーバーの設定を表示・変更するスクリプト
#
# 使い方:
#   mise run update-config                              # 現在の設定を表示
#   mise run update-config -- server-name "My Server"
#   mise run update-config -- max-players 16
#   mise run update-config -- idle-checks 12
#   mise run update-config -- vm-size Standard_D4as_v5
#   mise run update-config -- ssh-cidr "1.2.3.4/32"
#   mise run update-config -- server-password           # ランダム4桁
#   mise run update-config -- server-password 1234
#   mise run update-config -- admin-password            # ランダム生成
#   mise run update-config -- discord-webhook https://...
#   mise run update-config -- game-setting EXP_RATE 5  # 稼働中VMに直接反映

set -euo pipefail
cd "$(dirname "$0")/.."

TFVARS="terraform/terraform.tfvars"

# terraform.tfvars の値を設定する (既存行を更新、なければ追加)
tfvars_set() {
  local key="$1" formatted="$2"
  if [ ! -f "$TFVARS" ]; then
    echo "エラー: $TFVARS が存在しません。terraform.tfvars.example をコピーして作成してください。" >&2
    exit 1
  fi
  if grep -q "^${key} *=" "$TFVARS" 2>/dev/null; then
    sed -i '' "s|^${key} *=.*|${key} = ${formatted}|" "$TFVARS"
  else
    echo "${key} = ${formatted}" >> "$TFVARS"
  fi
  echo "✓ ${key} = ${formatted} を設定しました"
}

# Terraform の Key Vault 名を取得する
get_vault_name() {
  terraform -chdir=terraform output -raw key_vault_name 2>/dev/null || return 1
}

# vm/game-settings.env の特定キーを更新し Blob Storage に反映する
update_game_setting() {
  local key="$1" value="$2"
  local env_file="vm/game-settings.env"

  if [ ! -f "$env_file" ]; then
    echo "エラー: $env_file が存在しません。" >&2
    exit 1
  fi

  if grep -q "^${key}=" "$env_file" 2>/dev/null; then
    sed -i '' "s|^${key}=.*|${key}=${value}|" "$env_file"
  else
    echo "${key}=${value}" >> "$env_file"
  fi
  echo "✓ $env_file: ${key}=${value} を更新しました"

  local STORAGE RG STORAGE_KEY
  if ! STORAGE=$(terraform -chdir=terraform output -raw storage_account_name 2>/dev/null); then
    echo "警告: Blob へのアップロードをスキップ (terraform apply を先に実行してください)" >&2
    return 0
  fi

  RG=$(terraform -chdir=terraform output -raw resource_group_name)
  STORAGE_KEY=$(az storage account keys list --account-name "$STORAGE" --resource-group "$RG" --query "[0].value" -o tsv)
  az storage blob upload \
    --account-name "$STORAGE" \
    --account-key "$STORAGE_KEY" \
    --container-name "game-config" \
    --name "settings.env" \
    --file "$env_file" \
    --overwrite \
    --output none
  echo "✓ Blob Storage ($STORAGE/game-config/settings.env) を更新しました"
  echo "→ 次回サーバー起動時に反映されます (/palworld stop → /palworld start)"
}

# Key Vault シークレットを更新する
vault_set() {
  local name="$1" value="$2"
  local vault
  if ! vault=$(get_vault_name); then
    echo "エラー: Key Vault 名を取得できませんでした。terraform apply を先に実行してください。" >&2
    exit 1
  fi
  az keyvault secret set --vault-name "$vault" --name "$name" --value "$value" --output none
  echo "✓ Key Vault '$name' を更新しました"
}

# 現在の設定を表示する
show_config() {
  echo "=== Terraform 変数 ($TFVARS) ==="
  if [ -f "$TFVARS" ]; then
    grep -v "^#" "$TFVARS" | grep -v "^$" || true
  else
    echo "(ファイルが存在しません)"
  fi

  echo ""
  echo "=== Key Vault シークレット ==="
  local vault
  if ! vault=$(get_vault_name); then
    echo "(Key Vault に接続できません。terraform apply を実行してください)"
    return 0
  fi
  echo "Vault: $vault"
  az keyvault secret list --vault-name "$vault" --query "[].name" -o tsv 2>/dev/null \
    | while IFS= read -r name; do
        val=$(az keyvault secret show --vault-name "$vault" --name "$name" --query value -o tsv 2>/dev/null)
        if [[ "$name" == *password* ]]; then
          echo "  $name = ****"
        else
          echo "  $name = $val"
        fi
      done
}

print_usage() {
  cat <<'EOF'
使い方: mise run update-config -- [コマンド] [引数...]

コマンド:
  show                         現在の設定を表示する (デフォルト)
  server-name <名前>           サーバー表示名を変更する
  max-players <人数>           最大同時接続人数を変更する (デフォルト: 8)
  idle-checks <回数>           自動停止チェック回数を変更する (5分間隔 × 回数)
  vm-size <サイズ>             VM サイズを変更する (VM 再作成が発生)
  ssh-cidr [CIDR]              SSH 許可 CIDR を変更する (省略で非公開)
  server-password [値]         サーバーパスワードを変更する (省略でランダム4桁)
  admin-password [値]          管理者パスワードを変更する (省略でランダム生成)
  discord-webhook <URL>        Discord Webhook URL を設定する
  community on|off             コミュニティサーバーとして公開する (on でサーバーブラウザに表示)
  game-setting <KEY> <値>      ゲームバランス設定を変更し Blob に反映する

game-setting の KEY 例:
  EXP_RATE  PAL_CAPTURE_RATE  PLAYER_DAMAGE_RATE_ATTACK  COLLECTION_DROP_RATE
  (vm/game-settings.env を参照)

注意:
  Terraform 変数の変更は "terraform apply" で反映してください。
  Key Vault / Blob の変更はサーバー再起動 (/palworld stop → start) で反映されます。
EOF
}

COMMAND="${1:-show}"
shift || true

case "$COMMAND" in
  show)
    show_config
    ;;
  server-name)
    [ $# -lt 1 ] && { echo "使い方: update-config server-name <名前>"; exit 1; }
    tfvars_set "server_name" "\"$1\""
    echo "→ terraform apply で変更を反映してください"
    ;;
  max-players)
    [ $# -lt 1 ] && { echo "使い方: update-config max-players <人数>"; exit 1; }
    tfvars_set "max_players" "$1"
    echo "→ terraform apply で変更を反映してください"
    ;;
  idle-checks)
    [ $# -lt 1 ] && { echo "使い方: update-config idle-checks <回数>"; exit 1; }
    tfvars_set "idle_checks" "$1"
    echo "→ terraform apply で変更を反映してください"
    ;;
  vm-size)
    [ $# -lt 1 ] && { echo "使い方: update-config vm-size <サイズ>"; exit 1; }
    tfvars_set "vm_size" "\"$1\""
    echo "→ terraform apply で変更を反映してください (VM が再作成されます)"
    ;;
  ssh-cidr)
    SSH_CIDR="${1:-}"
    tfvars_set "allowed_ssh_cidr" "\"$SSH_CIDR\""
    echo "→ terraform apply で変更を反映してください"
    ;;
  server-password)
    PW="${1:-$(printf '%04d%04d%04d' $((RANDOM % 10000)) $((RANDOM % 10000)) $((RANDOM % 10000)))}"
    vault_set "server-password" "$PW"
    echo "  新しいパスワード: $PW"
    echo "→ サーバーを再起動すると反映されます"
    ;;
  admin-password)
    PW="${1:-$(openssl rand -base64 32 | LC_ALL=C tr -dc 'A-Za-z0-9' | cut -c1-20)}"
    vault_set "admin-password" "$PW"
    echo "→ サーバーを再起動すると反映されます"
    ;;
  discord-webhook)
    [ $# -lt 1 ] && { echo "使い方: update-config discord-webhook <URL>"; exit 1; }
    vault_set "discord-webhook-url" "$1"
    ;;
  community)
    MODE="${1:-}"
    if [ "$MODE" != "on" ] && [ "$MODE" != "off" ]; then
      echo "使い方: update-config community on|off"
      exit 1
    fi
    VALUE=$( [ "$MODE" = "on" ] && echo "true" || echo "false" )
    vault_set "community-mode" "$VALUE"
    echo "  コミュニティモード: $MODE ($VALUE)"

    RG=$(terraform -chdir=terraform output -raw resource_group_name 2>/dev/null || true)
    VM_TF=$(terraform -chdir=terraform output -raw vm_name 2>/dev/null || true)
    if [ -n "$RG" ] && [ -n "$VM_TF" ]; then
      echo "→ VM ($VM_TF) の設定を更新中..."
      if az vm run-command invoke \
          -g "$RG" -n "$VM_TF" \
          --command-id RunShellScript \
          --scripts \
            "sed -i 's|COMMUNITY:.*|COMMUNITY: \"$VALUE\"|' /opt/palworld/docker-compose.yml" \
            "cd /opt/palworld && /opt/palworld/fetch-secrets.sh && docker compose up -d palworld 2>/dev/null || true" \
          --output none 2>/dev/null; then
        echo "✓ コミュニティモードを ${MODE} にし、コンテナを再起動しました"
      else
        echo "  VM が起動していないため、次回 /palworld start 時に自動反映されます"
      fi
    fi
    ;;
  game-setting)
    [ $# -lt 2 ] && { echo "使い方: update-config game-setting <KEY> <値>"; exit 1; }
    update_game_setting "$1" "$2"
    ;;
  -h|--help|help)
    print_usage
    ;;
  *)
    echo "不明なコマンド: $COMMAND" >&2
    echo ""
    print_usage
    exit 1
    ;;
esac
