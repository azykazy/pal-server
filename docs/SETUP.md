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
   **ウェブフック** → 新規作成 → URL をコピー → `discord_webhook_url`

## 2. Azure にログインする

```bash
mise install       # terraform / node / azure-cli を導入
mise run login     # パルワールド専用アカウントでログイン
az account show    # 正しいサブスクリプションか確認
```

`mise.toml` が `AZURE_CONFIG_DIR` をプロジェクト配下 (`.azure/`) に分離しているため、
他プロジェクトで使っている Azure アカウントには影響しません。

## 3. tfvars を用意してデプロイする

```bash
cp terraform/terraform.tfvars.example terraform/terraform.tfvars
$EDITOR terraform/terraform.tfvars   # サブスクリプションID・SSH公開鍵・パスワード・Discordキーを記入

terraform -chdir=terraform init
mise run apply
```

apply 完了時に `interactions_endpoint_url` が出力されます。

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

## トラブルシューティング

| 症状 | 確認ポイント |
|---|---|
| Endpoint 登録が失敗する | `mise run apply` 後に zip がデプロイされているか。`az functionapp function list -g rg-palworld -n <function_app_name>` で `interactions` が見えるか |
| start しても接続できない | 初回はダウンロードに時間がかかる。SSH を開けて `journalctl -u palworld-provision -f` / `docker logs palworld-server` を確認 |
| 自動停止しない | VM 内 `/var/log/palworld-autostop.log` を確認 |
| eviction された | `/palworld start` で再開できる。IP 残骸は毎日の cleanup が削除する |
