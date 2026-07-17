const { app } = require('@azure/functions');
const { startServer, stopServer, getStatus } = require('../lib/azure');
const { editOriginalResponse } = require('../lib/discord');

// interactions から渡されたジョブを実行し、結果を Discord のフォローアップで返す。
// VM の起動/停止は数分かかるが、interaction token は 15 分有効なので間に合う。
app.storageQueue('worker', {
  queueName: 'palworld-jobs',
  connection: 'AzureWebJobsStorage',
  handler: async (message, context) => {
    const { action, token } = message;
    context.log(`processing action: ${action}`);

    let content;
    try {
      if (action === 'start') {
        content = await startServer(context);
      } else if (action === 'stop') {
        content = await stopServer(context, { graceful: true });
      } else {
        content = await getStatus(context);
      }
    } catch (err) {
      context.error(`action ${action} failed`, err);
      content = `⚠️ 操作に失敗しました: ${err.message}`;
    }

    await editOriginalResponse(token, content);
  },
});
