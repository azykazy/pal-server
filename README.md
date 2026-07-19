---
title: "Palworld プライベートサーバー on Azure Spot"
description: "Azure Spot VM + Discord スラッシュコマンドで運用する低コスト Palworld サーバーの IaC"
type: readme
tags: [palworld, azure, terraform, spot-vm, discord, azure-functions]
path: README.md
---

# Palworld プライベートサーバー on Azure Spot

Azure Spot VM 上に Palworld 専用サーバーを構築し、Discord のスラッシュコマンドで
起動・停止・接続情報の確認ができる構成の Terraform 一式です。
**使っている間だけ課金**され、月30時間プレイで **約 $3.8/月 (≒600円)** に収まります。

## アーキテクチャ

```
Discord (/palworld start|stop|status)
   │ Interactions Endpoint (Ed25519 署名検証, 3秒以内に deferred 応答)
   ▼
Azure Functions (Flex Consumption, Node.js 20, Managed Identity)
   ├─ start:  Public IP 作成 → NIC に関連付け → VM 起動 → 接続情報を返信
   ├─ stop:   Run Command で graceful 停止 → deallocate → Public IP 削除
   ├─ status: 電源状態と接続情報を返信
   ├─ internal-stop: VM の自動停止スクリプトから呼ばれる内部 API
   └─ cleanup: 毎日1回、eviction 後の残存 IP / stopped 状態を掃除
   ▼
Spot VM (Standard_D4as_v5, Ubuntu 24.04, eviction=Deallocate)
   ├─ palworld-server-docker (compose, systemd 管理)
   ├─ REST API は localhost のみ (NSG 非公開)
   └─ auto-stop cron: プレイヤー0人×30分 → セーブ → 停止 → internal-stop 呼び出し
```

- **停止中の課金はディスク (Standard SSD 32GB, 約$2.4/月) のみ**。
  Public IP は起動時に作成・停止時に削除するため停止中は課金されない
- IP・パスワードは起動のたびに変わるが、`/palworld start` / `/palworld status` が
  Discord 上に接続先 (`IP:8211`) と最新のパスワード (4桁数字) を毎回表示する
- プレイヤー0人が30分続くと自動でセーブして停止する (切り忘れ防止)
- **シークレットは Key Vault 管理** (操作課金 $0.03/1万回 ≒ この用途では実質$0)。
  パスワード類はローカルファイル・tfvars・tfstate に残らず、
  Functions は Key Vault 参照、VM は Managed Identity で起動時に取得する

## 料金見込み (2026-07 時点, japaneast)

| 項目 | 単価 | 月30時間プレイ時 |
|---|---|---|
| VM (D4as_v5 Spot) | $0.0414/h (稼働時のみ) | 約 $1.24 |
| ディスク (Standard SSD 32GB) | $2.40/月 (常時) | $2.40 |
| Public IP | $0.005/h (稼働時のみ) | 約 $0.15 |
| Functions / Storage | 無料枠内 | ~$0 |
| **合計** | | **約 $3.8/月** |

## セットアップ

前提: [mise](https://mise.jdx.dev/) がインストール済みであること。

```bash
mise install                 # terraform / node を導入 (az はシステム版を使用)
mise run login               # パルワールド専用 Azure アカウントにログイン
                             # (AZURE_CONFIG_DIR がプロジェクト配下に分離される)

# 1. Discord アプリを作成して各キーを取得 (docs/SETUP.md 参照)
# 2. tfvars を用意 (シークレットは書かない)
cp terraform/terraform.tfvars.example terraform/terraform.tfvars
$EDITOR terraform/terraform.tfvars

# 3. デプロイ + コード配置 + シークレット投入
terraform -chdir=terraform init
mise run apply               # インフラ作成
mise run deploy-functions    # Functions コードのデプロイ
DISCORD_WEBHOOK_URL=... mise run seed-secrets

# 4. 出力された interactions_endpoint_url を Discord Developer Portal に登録し、
#    スラッシュコマンドを登録 (docs/SETUP.md 参照)
DISCORD_APPLICATION_ID=... DISCORD_BOT_TOKEN=... DISCORD_GUILD_ID=... \
  mise run register-commands
```

## 使い方 (Discord)

| コマンド | 動作 |
|---|---|
| `/palworld start` | サーバー起動。完了すると接続先 `IP:8211` とパスワードを表示 |
| `/palworld stop` | セーブしてサーバー停止 (課金停止) |
| `/palworld status` | 稼働状態と接続情報を表示 |
| `/palworld cost` | 先月〜今月の Azure コスト (サービス別内訳つき) を表示 |

スラッシュコマンドの代わりに、チャンネルに常設する**ボタン操作パネル**も使える
(`scripts/post-panel.mjs` で一度投稿してピン留めする。詳細は docs/DISCORD-REMAINING-STEPS.md)。

初回の `/palworld start` はプロビジョニング (Docker とサーバー本体のダウンロード) が
走るため、接続できるまで 10〜15 分程度かかります。2回目以降は数分です。

## 注意事項

- Spot VM のため、Azure 側の容量逼迫で稀に強制停止 (eviction) されることがあります。
  データはディスクに保持されるので `/palworld start` で再開できます
- 32GB ディスクは Palworld 本体で 15〜20GB 使うためやや余裕が少なめです。
  不足したら Azure のオンラインディスク拡張で 64GB (+$2.4/月) に上げられます
- Discord キー等は `terraform.tfvars` (gitignore 済み) にのみ書きます。
  サーバーパスワードは VM 起動時に自動生成されるため `tfvars` への記載は不要です

## ディレクトリ構成

| パス | 内容 |
|---|---|
| `terraform/` | インフラ定義 (VM, ネットワーク, Functions, IAM) |
| `functions/` | Discord Bot (Azure Functions, Node.js) |
| `vm/` | VM 上に配置される compose / スクリプトのテンプレート |
| `scripts/` | ビルド・コマンド登録スクリプト |
| `docs/SETUP.md` | Discord アプリ作成〜疎通確認の手順 |
