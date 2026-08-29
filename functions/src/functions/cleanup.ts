import { app } from '@azure/functions';
import { ComputeManagementClient } from '@azure/arm-compute';
import { DefaultAzureCredential } from '@azure/identity';
import { getPowerState, removePublicIp } from '../lib/azure';
import { notifyWebhook } from '../lib/discord';

// 安全網: eviction 等で VM が残存していたり Public IP が残ったりしている状態を
// 毎日 09:00 UTC (18:00 JST) に掃除する。
app.timer('cleanup', {
  schedule: '0 0 9 * * *',
  handler: async (_timer, context) => {
    const state = await getPowerState();
    context.log(`cleanup check: power state = ${state}`);

    if (state === 'deleted') {
      // VM は正常に削除済み。Public IP が残っていれば削除する
      await removePublicIp(context);
      return;
    }

    if (state === 'deallocated' || state === 'stopped') {
      // eviction_policy=Delete のはずだが念のため残存 VM を削除してディスク課金を止める
      const compute = new ComputeManagementClient(
        new DefaultAzureCredential(),
        process.env.AZURE_SUBSCRIPTION_ID ?? '',
      );
      await compute.virtualMachines.beginDeleteAndWait(
        process.env.RESOURCE_GROUP ?? '',
        process.env.VM_NAME ?? '',
      );
      await removePublicIp(context);
      await notifyWebhook(
        `🧹 VM が ${state} 状態で残存していたため削除しました。Spot eviction の可能性があります。`,
      );
    }
  },
});
