---
title: "残作業チェックリスト (Discord 連携の仕上げ)"
description: "別 PC で実施する Discord 登録・シークレット投入・動作確認の手順 (このファイルだけで完結)"
type: doc
tags: [setup, discord, checklist]
path: docs/DISCORD-REMAINING-STEPS.md
---

# 残作業チェックリスト (Discord 連携の仕上げ)

インフラ構築・コードデプロイは完了済み。残りは以下の3つ＋動作確認のみ。
**このファイルの手順はブラウザと curl (または node) だけで完結**し、リポジトリの clone は不須。

## 確定済みの値

| 項目 | 値 |
|---|---|
| Application ID | `1527503571770146926` |
| サーバー (ギルド) ID | `1527498915535126558` |
| Interactions Endpoint URL | `https://func-palworld-ikrlom.azurewebsites.net/api/interactions` |
| Key Vault 名 | `kv-palworld-ikrlom` |
| リソースグループ | `pal-server` |
| VM 名 | `vm-palworld` |

## ☐ 1. Key Vault にパスワードを登録

[Azure Portal](https://portal.azure.com) → リソースグループ `pal-server` → `kv-palworld-ikrlom`
→ **オブジェクト → シークレット → ＋生成/インポート**

| シークレット名 (完全一致) | 値 | 必須 |
|---|---|---|
| `server-password` | ゲーム参加パスワード (友人に共有する、英数字推奨) | ✅ |
| `admin-password` | 管理用パスワード (長めの英数字) | ✅ |
| `discord-webhook-url` | 通知チャンネルの Webhook URL | 任意 |

- Webhook の作り方: 通知チャンネルの⚙️ → 連携サービス → ウェブフック (PC 版 Discord のみ)
- ⚠️ 「権限がありません」と出る場合はロール反映待ち。数分後に再読み込み

## ☐ 2. Interactions Endpoint URL を登録

1. [Discord Developer Portal](https://discord.com/developers/applications) → 対象アプリ → **General Information**
2. **INTERACTIONS ENDPOINT URL** に以下を貼って **Save Changes**:

   ```
   https://func-palworld-ikrlom.azurewebsites.net/api/interactions
   ```

3. 保存時に Discord が疎通確認 (PING) を送る。**コールドスタートで初回は失敗することがある
   → 10秒待ってもう一度 Save** すれば通る

## ☐ 3. スラッシュコマンドを登録

Bot Token (Developer Portal → Bot → Reset Token で取得) を使って1回だけ実行する。

**curl 版 (どの PC でも可):** `<BOT_TOKEN>` を差し替えて実行

```bash
curl -X PUT "https://discord.com/api/v10/applications/1527503571770146926/guilds/1527498915535126558/commands" \
  -H "Authorization: Bot <BOT_TOKEN>" \
  -H "Content-Type: application/json" \
  -d '[{"name":"palworld","description":"Palworld サーバーを操作します","options":[
    {"type":1,"name":"start","description":"サーバーを起動して接続情報を表示します"},
    {"type":1,"name":"stop","description":"サーバーを停止します (課金停止)"},
    {"type":1,"name":"status","description":"サーバーの状態と接続情報を表示します"},
    {"type":1,"name":"cost","description":"今月の Azure コストを表示します"}]}]'
```

成功すると JSON が返り、Discord のサーバーで `/palworld` が即座に使えるようになる
(ギルドコマンドなので反映は即時)。

**リポジトリがある場合の代替:**

```bash
DISCORD_BOT_TOKEN=<BOT_TOKEN> \
DISCORD_APPLICATION_ID=1527503571770146926 \
DISCORD_GUILD_ID=1527498915535126558 \
node scripts/register-commands.mjs
```

## ☐ 4. (推奨) ボタン操作パネルを設置

チャンネルにボタン付きメッセージを1つ置くと、スラッシュコマンドなしでワンタップ操作できる。

1. Bot を `bot` スコープ付きで**再招待**する (メッセージ送信権限が必要):

   ```
   https://discord.com/oauth2/authorize?client_id=1527503571770146926&scope=bot+applications.commands&permissions=2048
   ```

2. 設置先チャンネルの ID を取得 (開発者モード ON → チャンネルを長押し/右クリック → IDをコピー)
3. `<BOT_TOKEN>` と `<CHANNEL_ID>` を差し替えて実行:

   ```bash
   curl -X POST "https://discord.com/api/v10/channels/<CHANNEL_ID>/messages" \
     -H "Authorization: Bot <BOT_TOKEN>" \
     -H "Content-Type: application/json" \
     -d '{"content":"🎮 **Palworld サーバー操作パネル**\nボタンで操作できます (結果はこのチャンネルに返信されます)。","components":[{"type":1,"components":[{"type":2,"style":3,"label":"▶️ 起動","custom_id":"palworld_start"},{"type":2,"style":4,"label":"⏹️ 停止","custom_id":"palworld_stop"},{"type":2,"style":2,"label":"ℹ️ 状態","custom_id":"palworld_status"},{"type":2,"style":2,"label":"💰 コスト","custom_id":"palworld_cost"}]}]}'
   ```

4. 投稿されたパネルを**ピン留め**しておく (ボタンは無期限で有効)

リポジトリがある場合の代替: `DISCORD_BOT_TOKEN=... DISCORD_CHANNEL_ID=... node scripts/post-panel.mjs`

## ☐ 5. 動作確認

1. `/palworld status` → 「⚪ サーバーは停止中です」と返れば連携成功
2. `/palworld start` → 数分後に接続先 `IP:8211` とパスワードが表示される
   - **初回のみ Docker + Palworld 本体のダウンロードが走るため、表示後さらに10〜15分**
     かかってから接続可能になる (2回目以降は数分)
3. Palworld クライアント → マルチプレイ → 表示された `IP:8211` で接続
4. `/palworld stop` → 停止メッセージを確認。[Portal](https://portal.azure.com) で
   `vm-palworld` が「停止済み (割り当て解除)」になっていれば課金も止まっている
5. (自動停止の確認) 起動したまま誰も接続せず30分放置 → 自動停止 + Webhook 通知

## トラブルシューティング

| 症状 | 対処 |
|---|---|
| Endpoint 保存が何度も失敗 | 1分待って再試行。それでもダメなら Portal で Function App `func-palworld-ikrlom` が Running か確認 |
| `/palworld` が候補に出ない | 手順3の curl のレスポンスにエラーがないか確認。Bot がサーバーに追加済みか確認 (`https://discord.com/oauth2/authorize?client_id=1527503571770146926&scope=applications.commands`) |
| start 後に「操作に失敗しました」 | Key Vault のシークレット未登録の可能性 → 手順1を確認 |
| 接続できない | 初回は15分待つ。Palworld の検索バーには `IP:8211` を正確に入力 |
