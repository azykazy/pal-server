const { app } = require('@azure/functions');
const { stopServer } = require('../lib/azure');
const { notifyWebhook } = require('../lib/discord');

// VM 上の auto-stop.sh から呼ばれる内部エンドポイント (function key で保護)。
// VM は自分の Public IP を切り離すと外に出られなくなるため、
// deallocate と IP 削除は接続性が保証されたこちら側で実行する。
app.http('internalStop', {
  methods: ['POST'],
  authLevel: 'function',
  route: 'internal-stop',
  handler: async (request, context) => {
    context.log('internal stop requested (auto-stop from VM)');
    // palworld 自体は VM 側で graceful 停止済みなので Run Command は不要
    const result = await stopServer(context, { graceful: false });
    await notifyWebhook(`✅ 自動停止が完了しました。\n${result}`);
    return { status: 200, jsonBody: { ok: true } };
  },
});
