#!/usr/bin/env node
// Discord のギルドコマンドとして /palworld (start|stop|status) を登録する。
// ギルドコマンドは即時反映される (グローバルコマンドは反映に時間がかかる)。
//
// 使い方:
//   DISCORD_APPLICATION_ID=... DISCORD_BOT_TOKEN=... DISCORD_GUILD_ID=... \
//     node scripts/register-commands.mjs

const applicationId = process.env.DISCORD_APPLICATION_ID;
const botToken = process.env.DISCORD_BOT_TOKEN;
const guildId = process.env.DISCORD_GUILD_ID;

if (!applicationId || !botToken || !guildId) {
  console.error(
    '環境変数 DISCORD_APPLICATION_ID / DISCORD_BOT_TOKEN / DISCORD_GUILD_ID を設定してください。',
  );
  process.exit(1);
}

const commands = [
  {
    name: 'palworld',
    description: 'Palworld サーバーを操作します',
    options: [
      { type: 1, name: 'start', description: 'サーバーを起動して接続情報を表示します' },
      { type: 1, name: 'stop', description: 'サーバーを停止します (課金停止)' },
      { type: 1, name: 'status', description: 'サーバーの状態と接続情報を表示します' },
    ],
  },
];

const res = await fetch(
  `https://discord.com/api/v10/applications/${applicationId}/guilds/${guildId}/commands`,
  {
    method: 'PUT',
    headers: {
      Authorization: `Bot ${botToken}`,
      'Content-Type': 'application/json',
    },
    body: JSON.stringify(commands),
  },
);

if (!res.ok) {
  console.error(`登録に失敗しました: ${res.status}`);
  console.error(await res.text());
  process.exit(1);
}

console.log('スラッシュコマンド /palworld を登録しました。');
