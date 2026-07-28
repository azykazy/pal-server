---
title: "スクリプト使い方リファレンス"
description: "scripts/ 配下の全スクリプトの目的・前提条件・使い方一覧"
type: doc
tags: [scripts, operations, save-migration, azure, discord]
path: docs/SCRIPTS.md
---

# スクリプト使い方リファレンス

`scripts/` 配下のスクリプト一覧と使い方です。  
特に記載のないものは `mise run apply` 済み・`az login` 済みを前提とします。

---

## クイックリファレンス

```bash
# セーブデータを手動バックアップする（サーバー停止不要）
bash scripts/backup-save.sh

# プレイヤーデータを確認する
bash scripts/check-players.sh

# ホストのセーブデータを実 ID に変換する（要: 一度ログイン済み）
bash scripts/fix-host-save.sh

# セーブデータを Blob から VM に取り込む
bash scripts/import-save.sh world.zip

# サーバー設定を表示する
bash scripts/update-config.sh

# サーバー設定を変更する（例）
bash scripts/update-config.sh server-name "My Server"
bash scripts/update-config.sh max-players 16
bash scripts/update-config.sh game-setting EXP_RATE 5

# Functions をビルド＆デプロイする
bash scripts/deploy-functions.sh

# VM 上のスクリプトを最新版に更新する
bash scripts/update-vm-scripts.sh

# Key Vault にシークレットを投入する（初回セットアップ時）
DISCORD_WEBHOOK_URL="https://..." mise run seed-secrets

# Discord スラッシュコマンドを登録する
DISCORD_APPLICATION_ID=... DISCORD_BOT_TOKEN=... DISCORD_GUILD_ID=... mise run register-commands

# Discord に操作パネルを投稿する（初回のみ）
DISCORD_BOT_TOKEN=... DISCORD_CHANNEL_ID=... node scripts/post-panel.mjs
```

---

## 目次

| スクリプト | 用途 |
|---|---|
| [backup-save.sh](#backup-savesh) | セーブデータを手動バックアップする（停止不要） |
| [check-players.sh](#check-playerssh) | プレイヤーデータを確認する |
| [fix-host-save.sh](#fix-host-savesh) | ホストの引き継ぎ — `00000...0001` を実 ID に変換する |
| [import-save.sh](#import-savesh) | Blob から セーブデータを VM に取り込む |
| [update-config.sh](#update-configsh) | サーバー設定を表示・変更する |
| [seed-secrets.sh](#seed-secretssh) | Key Vault にシークレットを投入する |
| [update-vm-scripts.sh](#update-vm-scriptssh) | VM 上のシェルスクリプトを最新版に差し替える |
| [build-functions.sh](#build-functionssh) | Azure Functions を zip にビルドする |
| [deploy-functions.sh](#deploy-functionssh) | Azure Functions をデプロイする |
| [register-commands.mjs](#register-commandsmjs) | Discord スラッシュコマンドを登録する |
| [post-panel.mjs](#post-panelmjs) | Discord に操作パネルを投稿する |

---

## backup-save.sh

サーバーを停止せずにセーブデータを手動バックアップする。起動中のサーバーには REST API で `save` を要求してからアップロードする。

```bash
bash scripts/backup-save.sh
```

**処理の流れ**

1. サーバー起動中なら REST API (`POST /v1/api/save`) でセーブを要求
2. セーブデータを `/tmp/manual-YYYYMMDD-HHMMSS.tar.gz` に圧縮
3. IMDS Managed Identity でトークン取得 → Blob Storage の `save-backup` コンテナにアップロード

**保存先**

| コンテナ | Blob 名 | 備考 |
|---|---|---|
| `save-backup` | `manual-YYYYMMDD-HHMMSS.tar.gz` | 自動停止バックアップと同じ場所に保存 |

`latest.json` は更新しない（自動停止バックアップと区別するため）。

---

## check-players.sh

アクティブなワールドのプレイヤーファイル一覧とオンライン状況を表示する。

```bash
bash scripts/check-players.sh
```

**表示内容**

| セクション | 内容 |
|---|---|
| Players ディレクトリ | `.sav` ファイルのサイズ・更新日時一覧 |
| REST API | 現在オンラインのプレイヤー名・レベル・ping |
| ファイルサイズまとめ | 各プレイヤーの KB 表示と合計 |

**よくある GUID の意味**

| GUID | 意味 |
|---|---|
| `00000000000000000000000000000001` | 協力プレイのホスト (未変換) |
| その他 32 桁 | 専用サーバーで発番された個人 ID |

---

## fix-host-save.sh

協力プレイのホストだったプレイヤーのセーブデータ (`00000000000000000000000000000001.sav`) を、専用サーバーで発番された新しい GUID に引き継ぐ。

**前提条件**

1. `import-save.sh` でセーブデータを VM に取り込み済み
2. ホストが専用サーバーに **一度ログイン済み** (新しい GUID の `.sav` が生成されていること)

新しい `.sav` が生成されているかは `check-players.sh` で確認できる。

```bash
bash scripts/fix-host-save.sh
```

実行すると Players ディレクトリの一覧が表示され、新しい GUID の入力を求められる。

```
ホストの新しい GUID (00000... 以外の新しい .sav のファイル名、拡張子なし): <ここに入力>
```

**処理の流れ**

1. `systemctl stop palworld.service` でサーバーを停止
2. セーブデータを `/opt/palworld/save-backup-<timestamp>/` にバックアップ
3. `fix_host_save.py` で `00000...0001` → 新 GUID に変換
4. `systemctl start palworld.service` でサーバーを再起動

**完了後**

ホストのキャラクターで再ログインして持ち物・拠点を確認する。  
問題があれば `/opt/palworld/save-backup-*` にバックアップが残っているので、`docs/SAVE-MIGRATION.md` のトラブルシュートを参照。

---

## import-save.sh

Blob Storage (`save-import` コンテナ) にアップロードされたセーブ zip を VM に取り込み、ワールドを差し替える。VM が停止していれば自動起動する。

```bash
bash scripts/import-save.sh <blob名>

# 例
bash scripts/import-save.sh world.zip
```

**処理の流れ**

1. VM を起動 (停止中の場合はパブリック IP を付与してから起動)
2. プロビジョニング完了を待機
3. サーバーを一度起動してひな形ファイルを生成 → 停止
4. Blob から SAS URL を発行して zip を VM にダウンロード・展開
5. ワールドを差し替えてサーバーを再起動

**完了後**

```
接続先: <IP>:8211 (ワールド読み込みに数分かかります)
次はフェーズ2: ホストが一度ログインしてから scripts/fix-host-save.sh を実行してください
```

---

## update-config.sh

サーバー設定を表示・変更する。`mise run update-config` 経由でも実行可。

```bash
# 現在の設定を表示
bash scripts/update-config.sh
mise run update-config

# 設定を変更する
bash scripts/update-config.sh <コマンド> [引数]
mise run update-config -- <コマンド> [引数]
```

**コマンド一覧**

| コマンド | 引数 | 反映タイミング |
|---|---|---|
| `show` | — | 即時表示のみ |
| `server-name` | `<名前>` | `terraform apply` 後 |
| `max-players` | `<人数>` | `terraform apply` 後 |
| `idle-checks` | `<回数>` | `terraform apply` 後 |
| `vm-size` | `<サイズ>` | `terraform apply` 後 (VM 再作成) |
| `ssh-cidr` | `[CIDR]` | `terraform apply` 後 |
| `server-password` | `[値]` (省略でランダム6桁) | サーバー再起動後 |
| `admin-password` | `[値]` (省略でランダム生成) | サーバー再起動後 |
| `discord-webhook` | `<URL>` | 即時 (Key Vault 更新) |
| `community` | `on\|off` | 即時 (VM が起動中の場合) |
| `game-setting` | `<KEY> <値>` | サーバー再起動後 |

**`game-setting` の KEY 例**

```bash
bash scripts/update-config.sh game-setting EXP_RATE 5
bash scripts/update-config.sh game-setting PAL_CAPTURE_RATE 3
bash scripts/update-config.sh game-setting COLLECTION_DROP_RATE 2
```

使えるキーの全量は `vm/game-settings.env` を参照。

---

## seed-secrets.sh

`terraform apply` 直後に一度だけ実行し、Key Vault にシークレットを投入する。

```bash
# DISCORD_WEBHOOK_URL を同時に設定する場合
DISCORD_WEBHOOK_URL="https://discord.com/api/webhooks/..." mise run seed-secrets

# Webhook なしで実行
mise run seed-secrets
```

**投入されるシークレット**

| Key Vault 名 | 内容 |
|---|---|
| `admin-password` | 管理者パスワード (未指定なら自動生成) |
| `internal-stop-url` | Function App の内部停止 URL |
| `discord-webhook-url` | 通知先 Webhook URL (指定した場合のみ) |

サーバー参加パスワード (`server-password`) は VM 起動時に自動生成されるため、ここでは設定しない。

---

## update-vm-scripts.sh

`cloud-init` は既存 VM に再適用されないため、VM 上のシェルスクリプトをリポジトリの最新版で上書きする。バグ修正・設定変更を稼働中の VM に反映したいときに使う。

```bash
bash scripts/update-vm-scripts.sh
```

**更新されるファイル**

| VM 上のパス | リポジトリのソース |
|---|---|
| `/opt/palworld/fetch-secrets.sh` | `vm/fetch-secrets.sh.tftpl` |
| `/opt/palworld/palworld-stop.sh` | `vm/palworld-stop.sh` |
| `/opt/palworld/palworld-start-check.sh` | `vm/palworld-start-check.sh` |
| `/usr/local/bin/auto-stop.sh` | `vm/auto-stop.sh.tftpl` |

更新後、次回 `/palworld start` から新しいスクリプトが使用される。

---

## build-functions.sh

`functions/` を本番依存込みで zip にビルドし `dist/functions.zip` を生成する。

```bash
bash scripts/build-functions.sh
mise run build-functions
```

`deploy-functions.sh` が内部でこのスクリプトを呼ぶため、通常は直接実行不要。

---

## deploy-functions.sh

Functions をビルドして Azure にデプロイする。Flex Consumption 向けに OneDeploy API を直接呼び出す。

```bash
bash scripts/deploy-functions.sh
mise run deploy-functions
```

デプロイ完了まで最大 7 分半待機し、成功すると関数一覧を表示する。

---

## register-commands.mjs

Discord のスラッシュコマンド (`/palworld`) をギルドに登録する。コマンド定義を変更したときに再実行する。

```bash
DISCORD_APPLICATION_ID=<Application ID> \
DISCORD_BOT_TOKEN=<Bot Token> \
DISCORD_GUILD_ID=<Guild ID> \
  node scripts/register-commands.mjs

# mise 経由
DISCORD_APPLICATION_ID=... DISCORD_BOT_TOKEN=... DISCORD_GUILD_ID=... mise run register-commands
```

ギルドコマンドのため登録は即時反映される。

---

## post-panel.mjs

Discord チャンネルにボタン付きの操作パネルメッセージを投稿する。**初回セットアップ時に一度だけ実行**すればよい。

```bash
DISCORD_BOT_TOKEN=<Bot Token> \
DISCORD_CHANNEL_ID=<Channel ID> \
  node scripts/post-panel.mjs
```

投稿されるパネルには「起動 / 停止 / 状態 / コスト」の 4 ボタンが付く。ピン留めしておくと便利。

> **前提**: Bot が `bot` スコープ + メッセージ送信権限付きでサーバーに追加されていること。

---

## このサーバーのプレイヤー ID メモ

| 役割 | GUID |
|---|---|
| 元ホスト（旧 GUID・移行前） | `00000000000000000000000000000001` |
| 元ホスト（新 GUID・移行後） | `615FE6FB000000000000000000000000` |
| その他プレイヤー | `9AF8D604000000000000000000000000` |
| その他プレイヤー | `EA235BA7000000000000000000000000` |

- アクティブワールド ID: `DA5201F34189679A2514BA9183E158E9`
- 次回 `fix-host-save.sh` を実行する際は新 GUID `615FE6FB000000000000000000000000` を入力する

---

## セーブ移行の全体フロー

協力プレイから専用サーバーへの移行は以下の順で実行する。

```
1. セーブデータを zip にまとめて Blob (save-import コンテナ) にアップロード
   └─ az storage blob upload ...

2. import-save.sh でワールドを VM に取り込む
   └─ bash scripts/import-save.sh world.zip

3. ホストが専用サーバーに一度ログインする (新 GUID の .sav が生成される)

4. check-players.sh で新 GUID を確認する
   └─ bash scripts/check-players.sh

5. fix-host-save.sh でホストデータを新 GUID に変換する
   └─ bash scripts/fix-host-save.sh

6. ホストのキャラクターで再ログインして持ち物・拠点を確認する
```
