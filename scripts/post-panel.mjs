#!/usr/bin/env node
// 操作パネル (ボタン付きメッセージ) をチャンネルに投稿する。一度だけ実行すればよい。
// 前提: Bot が `bot` スコープ + メッセージ送信権限付きでサーバーに追加されていること。
//
// 使い方:
//   DISCORD_BOT_TOKEN=... DISCORD_CHANNEL_ID=... node scripts/post-panel.mjs

const botToken = process.env.DISCORD_BOT_TOKEN;
const channelId = process.env.DISCORD_CHANNEL_ID;

if (!botToken || !channelId) {
  console.error('環境変数 DISCORD_BOT_TOKEN / DISCORD_CHANNEL_ID を設定してください。');
  process.exit(1);
}

const message = {
  content: [
    '🎮 **Palworld サーバー操作パネル**',
    'ボタンで操作できます (結果はこのチャンネルに返信されます)。',
  ].join('\n'),
  components: [
    {
      type: 1, // Action Row
      components: [
        { type: 2, style: 3, label: '起動', emoji: { name: '▶️' }, custom_id: 'palworld_start' },
        { type: 2, style: 4, label: '停止', emoji: { name: '⏹️' }, custom_id: 'palworld_stop' },
        { type: 2, style: 2, label: '状態', emoji: { name: 'ℹ️' }, custom_id: 'palworld_status' },
        { type: 2, style: 2, label: 'コスト', emoji: { name: '💰' }, custom_id: 'palworld_cost' },
      ],
    },
  ],
};

const res = await fetch(`https://discord.com/api/v10/channels/${channelId}/messages`, {
  method: 'POST',
  headers: {
    Authorization: `Bot ${botToken}`,
    'Content-Type': 'application/json',
  },
  body: JSON.stringify(message),
});

if (!res.ok) {
  console.error(`投稿に失敗しました: ${res.status}`);
  console.error(await res.text());
  process.exit(1);
}

console.log('操作パネルを投稿しました。ピン留めしておくと便利です。');
