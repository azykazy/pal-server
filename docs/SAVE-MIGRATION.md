---
title: "ローカルセーブデータの移行手順"
description: "Steam 協力プレイ (自分がホスト) のワールドを専用サーバーへ引き継ぐ手順"
type: doc
tags: [save, migration, checklist]
path: docs/SAVE-MIGRATION.md
---

# ローカルセーブデータの移行手順

Steam の協力プレイ (自分がホスト) のワールドを Azure 上の専用サーバーへ移行する。

**重要な前提**: 協力プレイのホストはプレイヤー ID が特殊値 (`0000...0001`) で保存されるため、
そのまま移行すると**ホストのキャラクター・持ち物だけ引き継がれない**。フェーズ2の修正で
新しい ID に引き継ぐ (友人のキャラはそのまま引き継がれる)。

## フェーズ1: ワールドのアップロードと取り込み

### ゲーミング PC での作業

1. Palworld を完全に終了する
2. エクスプローラーで以下を開く (`Win+R` → 貼り付け):

   ```
   %LOCALAPPDATA%\Pal\Saved\SaveGames
   ```

3. `<数字のSteamID>` フォルダの中にある **長い16進文字列のフォルダ** (例: `1A2B3C...`) が
   ワールド。複数ある場合は更新日時で判別 (中の `LevelMeta.sav` がワールド情報)
4. そのフォルダを**右クリック → 圧縮 (zip)** して `world.zip` を作る
   (フォルダごと zip に含めること。中身だけの zip でも自動判別するが、フォルダごとが確実)
5. [Azure Portal](https://portal.azure.com) → ストレージアカウント `stpalworldikrlom` →
   **コンテナー → save-import** → **アップロード** で `world.zip` を上げる

### 取り込みの実行 (どの PC でも可 — Azure Cloud Shell 推奨)

ツールのインストール不要な **Azure Cloud Shell** で実行するのが手軽:

1. [Azure Portal](https://portal.azure.com) 右上の **Cloud Shell アイコン (>_)** をクリック → **Bash** を選択
   (初回は Cloud Shell 用ストレージの作成を促されるので同意する)
2. パルワールド用サブスクリプションになっているか確認:

   ```bash
   az account show --output table
   # 違う場合: az account set --subscription 75e0b2e4-37ae-4e2e-a6b2-410f484c7454
   ```

3. リポジトリを取得してスクリプトを実行:

   ```bash
   git clone https://github.com/azykazy/pal-server.git
   cd pal-server
   bash scripts/import-save.sh world.zip
   ```

このスクリプトが以下を自動実行する (完了まで15〜20分):
VM 起動 (IP 付与) → プロビジョニング完了待ち → サーバー初回起動でひな形生成 → 停止 →
zip を VM に取り込み → ワールド差し替え (`GameUserSettings.ini` の `DedicatedServerName` 更新) → 再起動

※ スクリプトはリソース名を既定値 (RG `pal-server` / VM `vm-palworld`) で参照するため、
terraform や事前設定は不要。

## フェーズ2: ホストキャラクターの引き継ぎ

1. ホスト (自分) が Palworld クライアントで新サーバー (`IP:8211`) に**一度ログイン**する
   (新規キャラ作成画面になるが、そのまま作成して入り、すぐ抜けてよい。これで新 ID の
   プレイヤーファイルが生成される)
2. Cloud Shell (フェーズ1と同じ) で修正スクリプトを実行:

   ```bash
   cd pal-server
   bash scripts/fix-host-save.sh
   ```

   → Players フォルダの一覧が表示されるので、`0000...0001` **以外**の新しい GUID を入力
   → サーバー停止 → PlM/PlZ 両対応の修正ツール
   ([NFZ-441/Palworld-Co-op-to-Dedicated-Server-Migration-Tool](https://github.com/NFZ-441/Palworld-Co-op-to-Dedicated-Server-Migration-Tool))
   で引き継ぎ → 再起動まで自動実行 (実行前にセーブ全体をバックアップする)
3. ホストが再ログインし、キャラクター・持ち物・拠点を確認する

> **注意: ツールについて**
> `pip install palworld-save-tools` で入る標準版は **Palworld v1.0 以降のセーブ形式 (`PlM`) に
> 非対応**のため、`Exception: not a compressed Palworld save, found b'PlM' instead of b'PlZ'`
> エラーが発生する。スクリプトは自動的に PlM 対応フォーク版を使用するため、手動変更は不要。

## 注意事項

- 移行前に必ず zip を手元にも残しておく (フェーズ2 でも VM 内にバックアップを取る)
- 修正ツールはコミュニティ製のため、Palworld 本体の大型アップデート直後は追従待ちで
  動かない場合がある。失敗した場合はバックアップから戻して続報を待つ
- ゲスト (友人) のキャラは修正不要でそのまま使える
- 移行後は自動停止 (0人30分) が通常どおり働く
