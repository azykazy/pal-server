const { app } = require('@azure/functions');
const { getPowerState, removePublicIp } = require('../lib/azure');
const { notifyWebhook } = require('../lib/discord');

// 安全網: Spot eviction などで「VM は deallocated だが Public IP が残っている」状態を
// 放置すると IP 課金 (約$3.65/月) が続くため、毎日 09:00 UTC (18:00 JST) に掃除する。
app.timer('cleanup', {
  schedule: '0 0 9 * * *',
  handler: async (_timer, context) => {
    const state = await getPowerState();
    context.log(`cleanup check: power state = ${state}`);

    if (state === 'deallocated' || state === 'stopped') {
      await removePublicIp(context);
      if (state === 'stopped') {
        // "stopped" (OS 停止のみ) はコンピューティング課金が続くため deallocate に落とす
        const { ComputeManagementClient } = require('@azure/arm-compute');
        const { DefaultAzureCredential } = require('@azure/identity');
        const compute = new ComputeManagementClient(
          new DefaultAzureCredential(),
          process.env.AZURE_SUBSCRIPTION_ID,
        );
        await compute.virtualMachines.beginDeallocateAndWait(
          process.env.RESOURCE_GROUP,
          process.env.VM_NAME,
        );
        await notifyWebhook(
          '🧹 VM が stopped (課金継続) 状態だったため deallocate しました。Spot eviction の可能性があります。',
        );
      }
    }
  },
});
