---
title: "セットアップ手順 (Discord アプリ作成〜疎通確認)"
description: "Discord Developer Portal でのアプリ作成からデプロイ・動作確認までの手順書"
type: doc
tags: [setup, discord, azure, terraform]
path: docs/SETUP.md
---

# セットアップ手順

## 1. Discord アプリケーションを作成する

1. [Discord Developer Portal](https://discord.com/developers/applications) を開き、**New Application** をクリックして名前 (例: `Palworld Server`) を付ける
2. **General Information** ページで以下を控える
   - **Application ID** → `discord_application_id`
   - **Public Key** → `discord_public_key`
3. 左メニュー **Bot** → **Reset Token** でトークンを発行して控える
   - **Bot Token** → スラッシュコマンド登録時のみ使用 (tfvars には書かない)
4. 左メニュー **Installation** (または OAuth2 → URL Generator) で
   scope `applications.commands` を含む招待 URL を作り、Bot を自分のサーバーに追加する

   ```
   https://discord.com/oauth2/authorize?client_id=<Application ID>&scope=applications.commands
   ```

5. 通知用 Webhook を作成する: Discord の通知先チャンネル → 設定 → **連携サービス** →
   **ウェブフック** → 新規作成 → URL をコピー (手順 3 の `seed-secrets` で使用)

## 2. Azure にログインする

```bash
mise install       # terraform / node / azure-cli を導入
mise run login     # パルワールド専用アカウントでログイン
az account show    # 正しいサブスクリプションか確認
```

`mise.toml` が `AZURE_CONFIG_DIR` をプロジェクト配下 (`.azure/`) に分離しているため、
他プロジェクトで使っている Azure アカウントには影響しません。

## 3. tfvars を用意してデプロイし、シークレットを Key Vault に投入する

```bash
cp terraform/terraform.tfvars.example terraform/terraform.tfvars
$EDITOR terraform/terraform.tfvars   # サブスクリプションID・SSH公開鍵・Discord ID/Public Key を記入
                                     # (パスワード類は書かない)

terraform -chdir=terraform init
mise run apply

# Functions のコードをデプロイ (OneDeploy API 直接呼び出し)
mise run deploy-functions

# パスワードを Key Vault に投入 (未指定なら自動生成。Terraform には値が通らない)
# ※ Portal から直接シークレットを登録しても OK (名前: server-password / admin-password / discord-webhook-url)
DISCORD_WEBHOOK_URL="<手順1-5のWebhook URL>" mise run seed-secrets
```

apply 完了時に `interactions_endpoint_url` が出力されます。
サーバー参加パスワードは以下でいつでも確認できます:

```bash
az keyvault secret show --vault-name $(terraform -chdir=terraform output -raw key_vault_name) \
  --name server-password --query value -o tsv
```

## 4. Discord に Interactions Endpoint を登録する

1. Developer Portal → General Information → **INTERACTIONS ENDPOINT URL** に
   `interactions_endpoint_url` の値を貼り付けて **Save Changes**
   - この瞬間に Discord が PING を送り、署名検証込みで疎通確認される。
     保存が通れば Functions 側は正常に動いている
2. スラッシュコマンドを登録する (ギルドコマンドなので即時反映)

   ```bash
   DISCORD_APPLICATION_ID=<Application ID> \
   DISCORD_BOT_TOKEN=<Bot Token> \
   DISCORD_GUILD_ID=<サーバーID (開発者モードでサーバー右クリック→IDをコピー)> \
     mise run register-commands
   ```

## 5. 動作確認

1. Discord で `/palworld status` → 「停止中」と返る
2. `/palworld start` → 数分後に接続先 `IP:8211` とパスワードが表示される
   - **初回のみ** Docker と Palworld 本体のダウンロードが走るため、
     表示された後も接続可能になるまで 10〜15 分ほどかかる
3. Palworld クライアント → マルチプレイ → 表示された `IP:8211` を入力して接続
4. `/palworld stop` → 停止メッセージの後、Azure Portal で VM が
   **停止済み (割り当て解除)** になっていることを確認 (= 課金停止)
5. 自動停止の確認: サーバー起動後、誰も接続せず30分放置 →
   Webhook チャンネルに自動停止通知が届き、VM が割り当て解除される

## VM スクリプトの手動更新

`vm.tf` の `lifecycle { ignore_changes = [custom_data] }` により、cloud-init スクリプトの変更は **既存 VM に自動適用されません**。バグ修正やセキュリティ修正を稼働中の VM に反映するには、以下を実行してください。

```bash
bash scripts/update-vm-scripts.sh
```

**前提条件:**
- `terraform apply` 済みで `terraform output` が取得可能
- `az login` 済みで対象リソースグループへの権限がある

**更新されるスクリプト:**

| VM 上のパス | ソース |
|---|---|
| `/opt/palworld/fetch-secrets.sh` | `vm/fetch-secrets.sh.tftpl` (変数展開済み) |
| `/opt/palworld/palworld-stop.sh` | `vm/palworld-stop.sh` |
| `/opt/palworld/palworld-start-check.sh` | `vm/palworld-start-check.sh` |
| `/usr/local/bin/auto-stop.sh` | `vm/auto-stop.sh.tftpl` (変数展開済み) |

更新後、次回サーバー起動 (`/palworld start`) から新しいスクリプトが使用されます。

## GitHub Actions CI/CD の設定

`main` ブランチへの push 時に `functions/` と `vm/` の変更を自動デプロイするワークフローが `.github/workflows/deploy.yml` に定義されています。
初回利用時に以下の手順で Azure と GitHub を繋いでください。

### 1. App Registration (サービスプリンシパル) を作成する

```bash
# App Registration 作成
az ad app create --display-name "pal-server-github-actions"
APP_ID=$(az ad app list --display-name "pal-server-github-actions" --query "[0].appId" -o tsv)

# サービスプリンシパル作成
az ad sp create --id "$APP_ID"
SP_OBJECT_ID=$(az ad sp show --id "$APP_ID" --query id -o tsv)
```

### 2. OIDC フェデレーション認証を設定する

GitHub Actions が長期シークレットなしで Azure に認証できるよう、フェデレーション資格情報を登録します。

```bash
# main ブランチの push で発行されるトークンを信頼
az ad app federated-credential create --id "$APP_ID" --parameters '{
  "name": "github-main",
  "issuer": "https://token.actions.githubusercontent.com",
  "subject": "repo:azykazy/pal-server:ref:refs/heads/main",
  "audiences": ["api://AzureADTokenExchange"]
}'
```

> `azykazy/pal-server` は実際の GitHub リポジトリ名に置き換えてください。

### 3. RBAC ロールを付与する

```bash
SUB_ID=$(az account show --query id -o tsv)
RG="pal-server"         # terraform output resource_group_name の値
TF_RG="rg-tfstate"      # Terraform バックエンドのリソースグループ
TF_SA="sttfstatepal878dff"  # Terraform バックエンドのストレージアカウント

# Terraform state 読み取り (backend が Azure Storage のため)
SA_ID=$(az storage account show -g "$TF_RG" -n "$TF_SA" --query id -o tsv)
az role assignment create --assignee-object-id "$SP_OBJECT_ID" --assignee-principal-type ServicePrincipal \
  --role "Storage Blob Data Contributor" --scope "$SA_ID"

# Functions デプロイ (SCM OneDeploy API)
az role assignment create --assignee-object-id "$SP_OBJECT_ID" --assignee-principal-type ServicePrincipal \
  --role "Website Contributor" --resource-group "$RG"

# VM run-command (スクリプト転送) + 電源状態確認
az role assignment create --assignee-object-id "$SP_OBJECT_ID" --assignee-principal-type ServicePrincipal \
  --role "Virtual Machine Contributor" --resource-group "$RG"
```

### 4. GitHub Secrets を設定する

GitHub リポジトリ → **Settings → Secrets and variables → Actions** で以下を登録します。

| Secret 名 | 値 |
|---|---|
| `AZURE_CLIENT_ID` | `$APP_ID` の値 |
| `AZURE_TENANT_ID` | `az account show --query tenantId -o tsv` |
| `AZURE_SUBSCRIPTION_ID` | `az account show --query id -o tsv` |

### 5. (オプション) idle_checks を Variables に登録する

`terraform.tfvars` は CI にないため、VM スクリプト更新時の `idle_checks` 値をリポジトリ変数で管理できます。
デフォルトは `6`（30 分）です。変更したい場合は **Settings → Secrets and variables → Actions → Variables** で設定します。

| Variable 名 | 値 |
|---|---|
| `IDLE_CHECKS` | 例: `6` (5分×6 = 30分で自動停止) |

### デプロイの流れ

| push 内容 | 実行されるジョブ |
|---|---|
| `functions/` 以下を変更 | `deploy-functions` → Azure Functions に自動デプロイ |
| `vm/` 以下を変更 | `update-vm` → VM 起動中なら即時更新、停止中はジョブサマリーに手動実行コマンドを表示 |
| それ以外 | 何もしない |

## トラブルシューティング

| 症状 | 確認ポイント |
|---|---|
| Endpoint 登録が失敗する | `mise run apply` 後に zip がデプロイされているか。`az functionapp function list -g rg-palworld -n <function_app_name>` で `interactions` が見えるか |
| start しても接続できない | 初回はダウンロードに時間がかかる。SSH を開けて `journalctl -u palworld-provision -f` / `docker logs palworld-server` を確認 |
| 自動停止しない | VM 内 `/var/log/palworld-autostop.log` を確認 |
| eviction された | `/palworld start` で再開できる。IP 残骸は毎日の cleanup が削除する |
