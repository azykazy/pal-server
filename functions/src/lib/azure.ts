import { DefaultAzureCredential } from '@azure/identity';
import { ComputeManagementClient } from '@azure/arm-compute';
import { NetworkManagementClient } from '@azure/arm-network';
import type { InvocationContext } from '@azure/functions';
import { notifyWebhook } from './discord';

const subscriptionId = process.env.AZURE_SUBSCRIPTION_ID ?? '';
const resourceGroup = process.env.RESOURCE_GROUP ?? '';
const vmName = process.env.VM_NAME ?? '';
const nicName = process.env.NIC_NAME ?? '';
const pipName = process.env.PIP_NAME ?? '';
const location = process.env.LOCATION ?? '';
const gamePort = process.env.GAME_PORT ?? '8211';

const vmSize = process.env.VM_SIZE ?? 'Standard_D4as_v5';
const adminUsername = process.env.VM_ADMIN_USERNAME ?? 'azureuser';
const sshPublicKey = process.env.VM_SSH_PUBLIC_KEY ?? '';
const userAssignedIdentityId = process.env.VM_USER_ASSIGNED_IDENTITY_ID ?? '';
const cloudInitBase64 = process.env.CLOUD_INIT_BASE64 ?? '';

const credential = new DefaultAzureCredential();
const retryOptions = { maxRetries: 3, retryDelayInMs: 1000, maxRetryDelayInMs: 8000 };
const compute = new ComputeManagementClient(credential, subscriptionId, { retryOptions });
const network = new NetworkManagementClient(credential, subscriptionId, { retryOptions });

function isNotFound(err: unknown): boolean {
  const e = err as { statusCode?: number; code?: string };
  return e.statusCode === 404 || e.code === 'ResourceNotFound' || e.code === 'NotFound';
}

async function getPowerState(): Promise<string> {
  try {
    const view = await compute.virtualMachines.instanceView(resourceGroup, vmName);
    const status = (view.statuses ?? []).find((s) => s.code && s.code.startsWith('PowerState/'));
    return status ? status.code!.replace('PowerState/', '') : 'unknown';
  } catch (err) {
    if (isNotFound(err)) return 'deleted';
    throw err;
  }
}

// Public IP を用意して NIC に関連付け、グローバル IP アドレスを返す
async function ensurePublicIp(context: InvocationContext): Promise<string | undefined> {
  let pip: Awaited<ReturnType<typeof network.publicIPAddresses.get>> | undefined;
  try {
    pip = await network.publicIPAddresses.get(resourceGroup, pipName);
  } catch (err) {
    if (!isNotFound(err)) throw err;
  }

  if (!pip) {
    context.log(`creating public IP ${pipName}`);
    pip = await network.publicIPAddresses.beginCreateOrUpdateAndWait(resourceGroup, pipName, {
      location,
      sku: { name: 'Standard' },
      publicIPAllocationMethod: 'Static',
      publicIPAddressVersion: 'IPv4',
    });
  }

  const nic = await network.networkInterfaces.get(resourceGroup, nicName);
  const ipConfig = nic.ipConfigurations![0];
  if (!ipConfig.publicIPAddress || ipConfig.publicIPAddress.id !== pip.id) {
    context.log(`associating ${pipName} to ${nicName}`);
    ipConfig.publicIPAddress = { id: pip.id };
    await network.networkInterfaces.beginCreateOrUpdateAndWait(resourceGroup, nicName, nic);
  }

  if (!pip.ipAddress) {
    pip = await network.publicIPAddresses.get(resourceGroup, pipName);
  }
  return pip.ipAddress;
}

// NIC から Public IP を切り離してリソースごと削除する (停止中の IP 課金をゼロにする)
async function removePublicIp(context: InvocationContext): Promise<void> {
  const nic = await network.networkInterfaces.get(resourceGroup, nicName);
  if (nic.ipConfigurations![0].publicIPAddress) {
    context.log(`dissociating public IP from ${nicName}`);
    nic.ipConfigurations![0].publicIPAddress = null as never;
    await network.networkInterfaces.beginCreateOrUpdateAndWait(resourceGroup, nicName, nic);
  }
  try {
    context.log(`deleting public IP ${pipName}`);
    await network.publicIPAddresses.beginDeleteAndWait(resourceGroup, pipName);
  } catch (err) {
    if (!isNotFound(err)) {
      await notifyWebhook(`⚠️ Public IP の削除に失敗しました。手動で ${pipName} を削除してください。`);
      context.warn('PIP deletion failed', err);
    }
  }
}

async function getServerPassword(): Promise<string | null> {
  const vaultUri = process.env.KEY_VAULT_URI;
  if (!vaultUri) return null;
  const token = await credential.getToken('https://vault.azure.net/.default');
  const res = await fetch(`${vaultUri}secrets/server-password?api-version=7.4`, {
    headers: { Authorization: `Bearer ${token!.token}` },
  });
  if (!res.ok) return null;
  return ((await res.json()) as { value: string }).value;
}

async function connectionInfo(ip: string): Promise<string> {
  const lines = [`接続先: \`${ip}:${gamePort}\``];
  const password = await getServerPassword();
  if (password) lines.push(`パスワード: \`${password}\``);
  return lines.join('\n');
}

export async function startServer(context: InvocationContext): Promise<string> {
  const state = await getPowerState();
  context.log(`current power state: ${state}`);

  if (state === 'running') {
    const ip = await ensurePublicIp(context);
    return ['🟢 **Palworld サーバーはすでに起動しています。**', '', await connectionInfo(ip ?? '')].join('\n');
  }

  // Azure eviction 等で deallocated のまま残っている場合は先に削除してからクリーン再作成する
  if (state !== 'deleted') {
    context.log(`deleting existing VM ${vmName} (state: ${state}) before recreation`);
    await compute.virtualMachines.beginDeleteAndWait(resourceGroup, vmName);
  }

  const ip = await ensurePublicIp(context);
  const nic = await network.networkInterfaces.get(resourceGroup, nicName);

  context.log(`creating VM ${vmName}`);
  await compute.virtualMachines.beginCreateOrUpdateAndWait(resourceGroup, vmName, {
    location,
    hardwareProfile: { vmSize },
    priority: 'Spot',
    evictionPolicy: 'Delete',
    billingProfile: { maxPrice: -1 },
    osProfile: {
      computerName: vmName,
      adminUsername,
      linuxConfiguration: {
        disablePasswordAuthentication: true,
        ssh: {
          publicKeys: [{ path: `/home/${adminUsername}/.ssh/authorized_keys`, keyData: sshPublicKey }],
        },
      },
      customData: cloudInitBase64,
    },
    storageProfile: {
      imageReference: {
        publisher: 'Canonical',
        offer: 'ubuntu-24_04-lts',
        sku: 'server',
        version: 'latest',
      },
      osDisk: {
        createOption: 'FromImage',
        managedDisk: { storageAccountType: 'StandardSSD_LRS' },
        diskSizeGB: 32,
        deleteOption: 'Delete',
      },
    },
    networkProfile: {
      networkInterfaces: [{ id: nic.id, primary: true }],
    },
    identity: {
      type: 'UserAssigned',
      userAssignedIdentities: { [userAssignedIdentityId]: {} },
    },
  });

  return [
    '🟢 **Palworld サーバーを起動しました！**',
    '',
    await connectionInfo(ip ?? ''),
    '',
    '※ ワールドの読み込みに数分かかります。接続できない場合は少し待ってから再試行してください。',
  ].join('\n');
}

export async function stopServer(
  context: InvocationContext,
  { graceful = true } = {},
): Promise<string> {
  const state = await getPowerState();
  context.log(`current power state: ${state}`);

  if (state === 'deleted') {
    await removePublicIp(context);
    return '⚪ サーバーはすでに削除済みです (課金なし)。';
  }

  if (graceful && state === 'running') {
    context.log('graceful shutdown via Run Command');
    try {
      await compute.virtualMachines.beginRunCommandAndWait(resourceGroup, vmName, {
        commandId: 'RunShellScript',
        script: ['systemctl stop palworld.service || true'],
      });
    } catch (err) {
      context.log(`run command failed, continuing to delete: ${(err as Error).message}`);
    }
  }

  context.log(`deleting VM ${vmName}`);
  await compute.virtualMachines.beginDeleteAndWait(resourceGroup, vmName);
  await removePublicIp(context);

  return '🔴 **Palworld サーバーを停止しました。** VM と OS ディスクを削除しました。';
}

export async function getStatus(context: InvocationContext): Promise<string> {
  const state = await getPowerState();
  context.log(`current power state: ${state}`);

  if (state === 'running') {
    let ip: string | null = null;
    try {
      ip = (await network.publicIPAddresses.get(resourceGroup, pipName)).ipAddress ?? null;
    } catch (err) {
      if (!isNotFound(err)) throw err;
    }
    return [
      '🟢 **サーバーは稼働中です。**',
      '',
      ip ? await connectionInfo(ip) : '(Public IP なし — /palworld start を実行してください)',
    ].join('\n');
  }

  if (state === 'deleted') {
    return '⚪ サーバーは削除済みです。`/palworld start` で起動できます。';
  }

  return `⚪ サーバーは停止中です (${state})。\`/palworld start\` で起動できます。`;
}

export { getPowerState, removePublicIp };
