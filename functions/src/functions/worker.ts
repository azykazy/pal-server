import { app } from '@azure/functions';
import { startServer, stopServer, getStatus } from '../lib/azure';
import { getCostSummary } from '../lib/cost';
import { editOriginalResponse } from '../lib/discord';

// interactions から渡されたジョブを実行し、結果を Discord のフォローアップで返す。
// VM の起動/停止は数分かかるが、interaction token は 15 分有効なので間に合う。
app.storageQueue('worker', {
  queueName: 'palworld-jobs',
  connection: 'AzureWebJobsStorage',
  handler: async (message: unknown, context) => {
    const { action, token } = message as { action: string; token: string };
    context.log(`processing action: ${action}`);

    let content: string;
    try {
      if (action === 'start') {
        content = await startServer(context);
      } else if (action === 'stop') {
        content = await stopServer(context, { graceful: true });
      } else if (action === 'cost') {
        content = await getCostSummary(context);
      } else {
        content = await getStatus(context);
      }
    } catch (err) {
      context.error(`action ${action} failed`, err);
      content = `⚠️ 操作に失敗しました: ${(err as Error).message}`;
    }

    await editOriginalResponse(token, content);
  },
});
