---
title: "コミュニティサーバーブラウザ対応 - WorldOption.sav 問題の調査と修正"
description: "Palworld 専用サーバーがコミュニティブラウザで表示されない問題の原因調査と修正内容"
type: doc
tags: [server, palworld, bug-fix, deployment]
path: docs/COMMUNITY-SERVER-FIX.md
---

# コミュニティサーバーブラウザ対応 - WorldOption.sav 問題の調査と修正

## 問題の概要

Palworld 専用サーバーが Steam コミュニティサーバーブラウザで「oto world」として表示されず、代わりに「Default Palworld Server」のままになっていた問題を調査・修正しました。

### 症状

- コミュニティサーバーブラウザに「oto world」が表示されない
- REST API が全リクエストを拒否する（AdminPassword が空のため）
- ゲーム内からのマスターサーバー登録に失敗する可能性

### 影響範囲

- Palworld サーバーの接続性（コミュニティリスト表示）
- REST API の認証機構
- マスターサーバーへの公開IP登録

---

## 調査結果

### 1. WorldOption.sav がサーバー設定を上書きする

**問題の根本原因**

Palworld のセーブシステムには以下の設定ファイルが存在します：

| ファイル | 役割 | 形式 | 優先度 |
|---|---|---|---|
| `PalWorldSettings.ini` | サーバー基本設定（テンプレート） | テキスト | 低（起動時のみ参照） |
| `WorldOption.sav` | ワールド固有設定（バイナリ） | PlM1 形式 | **高（常に優先）** |

ワールドが **初回起動したタイミング**で `WorldOption.sav` が作成され、以降はゲームサーバーが **PalWorldSettings.ini よりも WorldOption.sav を優先して読み込みます**。

上書きされる設定範囲：
- ゲームプレイ設定（難易度、ドロップ率など）
- **サーバー設定（ServerName、AdminPassword、PublicIP など）** ← これが予想外

### 2. WorldOption.sav の初期値が「Default Palworld Server」だった

**なぜ間違った値で初期化されたのか**

当サーバーが最初に起動したとき：
1. Docker イメージのデフォルト値または環境変数の欠落により `SERVER_NAME` が正しく渡されなかった
2. ゲームサーバーが Palworld のデフォルト設定で `WorldOption.sav` を作成
3. 結果として以下のデフォルト値で固定化：
   - `ServerName` = "Default Palworld Server"
   - `AdminPassword` = ""（空）
   - `PublicIP` = ""（空）

**バイナリ形式による問題**

WorldOption.sav は Unreal Engine GVAS のラッパー形式（Palworld の PlM1 バイナリ）で保存されているため、テキストエディタで直接編集できません。

### 3. docker-compose.yml のテンプレートに COMMUNITY フラグがなかった

**テンプレート設定の問題**

`vm/docker-compose.yml.tftpl` で以下の状態でした：
```yaml
COMMUNITY: "false"  # ❌ コミュニティ機能が無効
SERVER_NAME: "${server_name}"
# ❌ PUBLIC_IP が設定されていない
```

VM 上では手動で `COMMUNITY: "true"` に修正されていましたが、テンプレートに反映されていませんでした。

### 4. PUBLIC_IP が設定されていなかった

**マスターサーバー登録に必須の情報**

- Docker コンテナに `PUBLIC_IP` 環境変数が渡されていなかった
- Steam マスターサーバーへの登録時に `PublicIP` フィールドが参照される
- 空の場合、正しいコミュニティリスト登録ができない

**Azure IMDS の問題**

Azure VM の Instance Metadata Service（`169.254.169.254`）で公開IPを取得しようとしましたが：
- Azure Functions が動的にアタッチする **Standard SKU 静的公開IP** が IMDS に反映されない
- `publicIpAddress` フィールドが空のままになる

---

## 実施した修正

### A. VM 上での即時対応（2026年7月21日）

#### 1. サーバーを安全に停止

```bash
# REST API 経由でセーブ + シャットダウン
/opt/palworld/palworld-stop.sh
```

セーブデータを Blob Storage にバックアップ（`20260721-130721.tar.gz`）

#### 2. WorldOption.sav を削除

```bash
rm /opt/palworld/data/Pal/Saved/SaveGames/0/DA5201F34189679A2514BA9183E158E9/WorldOption.sav
```

**重要**: `Level.sav` やプレイヤーデータは削除しない（ワールドとプレイヤー進捗が保持される）

#### 3. .env に公開IP を明示的に設定

```bash
# ifconfig.me で IPv4 公開IPを取得
PUBLIC_IP=$(curl -4 https://ifconfig.me)
echo "PUBLIC_IP=$PUBLIC_IP" >> /opt/palworld/.env
```

取得した IP: `20.46.123.159`

#### 4. 新しい docker-compose.yml で再起動

```bash
# 変更済みテンプレートでコンテナを再起動
docker compose up -d
```

処理フロー：
1. Docker イメージが `PalWorldSettings.ini` を環境変数から再生成
2. ゲームサーバーが **新しい `WorldOption.sav` を正しい値で作成**
3. Redis キャッシュがリセットされ、REST API が認識可能に

#### 5. 結果確認

```bash
# REST API でサーバー設定を確認
curl -X GET http://localhost:8212/api/server \
  -H "Authorization: Bearer admin-secret"
```

✅ 期待通りの結果：
- `ServerName="oto world"`
- `PublicIP="20.46.123.159"`
- コミュニティブラウザで「oto world」が表示されることを確認

### B. テンプレートへの恒久修正（PR #23）

#### 修正対象ファイル

**`vm/docker-compose.yml.tftpl`**
```yaml
# Before
COMMUNITY: "false"
SERVER_NAME: "${server_name}"

# After
COMMUNITY: "true"
SERVER_NAME: "${server_name}"
PUBLIC_IP: "$${PUBLIC_IP}"  # 新規追加（$${} は Terraform テンプレートエスケープ）
```

**`vm/fetch-secrets.sh.tftpl`**

新たに公開IP取得ロジックを追加：
```bash
# 公開IPを IMDS → ifconfig.me フォールバックで取得（format=text でテキスト直接返却）
PUBLIC_IP=$(curl -fsS --max-time 10 \
  -H "Metadata: true" \
  "http://169.254.169.254/metadata/instance/network/interface/0/ipv4/ipAddress/0/publicIpAddress?api-version=2021-02-01&format=text" \
  2>/dev/null || true)

# IMDS 失敗時は ifconfig.me にフォールバック（-4 で IPv4 強制）
if [ -z "$PUBLIC_IP" ]; then
  PUBLIC_IP=$(curl -4 -fsS --max-time 10 https://ifconfig.me 2>/dev/null || true)
fi

# .env への書き出しに追加（空でも書き出す）
PUBLIC_IP=$PUBLIC_IP
```

---

## 今後の運用上の注意

### WorldOption.sav の扱い方

**基本原則**
- サーバー設定（サーバー名・管理者パスワード・ポート等）を変更した場合は、**WorldOption.sav を削除してから再起動する**
- WorldOption.sav の削除は安全（ワールドデータとプレイヤーデータには影響しない）

**セーブデータの保持**
- 削除しても以下は保持される：
  - `Level.sav` — ワールドの地形・建築・リソース状態
  - `Players/*.sav` — プレイヤーレベル、アイテム、ステータス
  - ギルド・ベースの所有権情報

**バックアップ体制**
- サーバー停止時に Blob Storage へ自動バックアップされる（`palworld-stop.sh` が実行）
- 定期的に Blob Storage から `.tar.gz` でダウンロード可能

### 公開IP の動的変化への対応

**設計思想**
- `/palworld start`（Discord コマンド）のたびに新しい公開IPが割り当てられる
- `fetch-secrets.sh` が起動時に自動取得して `.env` → Docker コンテナへ渡す

**フォールバック戦略**
- **第1優先**: Azure IMDS（`169.254.169.254`） — 高速、Azure ネイティブ
- **第2優先**: `ifconfig.me`（外部 IPv4 エコーサービス） — IMDS 失敗時
- **失敗時**: `PUBLIC_IP` が空のまま（ログに警告出力、コミュニティリストに登録されない可能性）

### コミュニティサーバーブラウザについて

**既知の制限**
- Palworld のコミュニティブラウザは更新が遅く、起動直後は表示されないことがある（通常 1〜5 分待つ）
- キャッシュが古い場合、サーバーが実際に起動していても表示されないことがある

**確実に接続するための代替手段**
- Discord の `/palworld status` コマンドで現在の公開IP と接続ポートを確認
- ゲーム内で「サーバーに接続」→「IP アドレスで検索」で直接入力

---

## 関連ファイル構造

```
pal-server/
├── vm/
│   ├── docker-compose.yml.tftpl    # ← 修正：COMMUNITY, PUBLIC_IP 追加
│   ├── fetch-secrets.sh.tftpl      # ← 修正：IP 取得ロジック追加
│   └── palworld-stop.sh            # 停止スクリプト（セーブ + バックアップ）
│
├── Pal/Saved/
│   ├── Config/LinuxServer/
│   │   └── PalWorldSettings.ini    # サーバー設定テンプレート（起動時に環境変数から生成）
│   └── SaveGames/0/
│       └── <WORLD_ID>/
│           ├── Level.sav           # ワールドデータ（削除厳禁）
│           ├── WorldOption.sav     # ← ワールド設定（削除可、再生成される）
│           └── Players/            # プレイヤーデータ（削除厳禁）
│
└── docs/
    └── COMMUNITY-SERVER-FIX.md     # このファイル
```

### Docker イメージのビルドフロー

```
docker compose up -d
  ↓
fetch-secrets.sh が実行される
  ├─ PUBLIC_IP を Azure IMDS または ifconfig.me から取得
  └─ PUBLIC_IP=<IP> を .env に書き込み
  ↓
Docker イメージが起動
  ├─ env ファイルが読み込まれる
  ├─ PalWorldSettings.ini が環境変数から再生成される
  └─ ゲームサーバーが起動
  ↓
WorldOption.sav が存在しない場合は新規作成（正しい値で初期化）
```

---

## トラブルシューティング

### コミュニティブラウザに表示されない場合

1. **サーバーが起動しているか確認**
   ```bash
   curl -X GET http://localhost:8212/api/server \
     -H "Authorization: Bearer admin-secret"
   ```

2. **Public IP が正しく設定されているか確認**
   ```bash
   cat /opt/palworld/.env | grep PUBLIC_IP
   ```

3. **WorldOption.sav の値を確認**
   - REST API でサーバー名とパスワードを確認
   ```bash
   curl -X GET http://localhost:8212/api/server \
     -H "Authorization: Bearer admin-secret" | jq '.serverName, .adminPassword'
   ```

4. **キャッシュをリセット**
   - Redis をリセット：`redis-cli FLUSHALL`
   - WorldOption.sav を削除：`rm Pal/Saved/SaveGames/0/*/WorldOption.sav`
   - サーバーを再起動

### REST API が認証を拒否する場合

**原因**: AdminPassword が空

```bash
# 現在の AdminPassword を確認
curl -X GET http://localhost:8212/api/server \
  -H "Authorization: Bearer admin-secret" | jq '.adminPassword'

# 空の場合は WorldOption.sav を削除して再起動
rm /opt/palworld/data/Pal/Saved/SaveGames/0/*/WorldOption.sav
docker compose restart
```

---

## 参考

### 関連 PR・コミット

- **PR #23**: docker-compose.yml テンプレートの修正（COMMUNITY フラグ、PUBLIC_IP 追加）
- **Deploy**: 2026-07-21 13:07 UTC に VM 上で手動修正実施

### 関連ドキュメント

- 「pal-server」: Palworld 専用サーバーの構築・管理ドキュメント
- 「Azure VM デプロイメント」: Terraform による VM 起動フロー
- 「REST API 仕様」: `/api/server` エンドポイントの詳細

### 参考資料

- Palworld wiki — Server Configuration
- Unreal Engine GVAS Format
- Azure Instance Metadata Service（IMDS）ドキュメント
