const { DefaultAzureCredential } = require('@azure/identity');
const { ComputeManagementClient } = require('@azure/arm-compute');
const { NetworkManagementClient } = require('@azure/arm-network');

const subscriptionId = process.env.AZURE_SUBSCRIPTION_ID;
const resourceGroup = process.env.RESOURCE_GROUP;
const vmName = process.env.VM_NAME;
const nicName = process.env.NIC_NAME;
const pipName = process.env.PIP_NAME;
const location = process.env.LOCATION;
const gamePort = process.env.GAME_PORT || '8211';

const credential = new DefaultAzureCredential();
const compute = new ComputeManagementClient(credential, subscriptionId);
const network = new NetworkManagementClient(credential, subscriptionId);

function isNotFound(err) {
  return err.statusCode === 404 || err.code === 'ResourceNotFound' || err.code === 'NotFound';
}

async function getPowerState() {
  const view = await compute.virtualMachines.instanceView(resourceGroup, vmName);
  const status = (view.statuses || []).find((s) => s.code && s.code.startsWith('PowerState/'));
  return status ? status.code.replace('PowerState/', '') : 'unknown';
}

// Public IP を用意して NIC に関連付け、グローバル IP アドレスを返す
async function ensurePublicIp(context) {
  let pip;
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
  const ipConfig = nic.ipConfigurations[0];
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
async function removePublicIp(context) {
  const nic = await network.networkInterfaces.get(resourceGroup, nicName);
  if (nic.ipConfigurations[0].publicIPAddress) {
    context.log(`dissociating public IP from ${nicName}`);
    nic.ipConfigurations[0].publicIPAddress = null;
    await network.networkInterfaces.beginCreateOrUpdateAndWait(resourceGroup, nicName, nic);
  }
  try {
    context.log(`deleting public IP ${pipName}`);
    await network.publicIPAddresses.beginDeleteAndWait(resourceGroup, pipName);
  } catch (err) {
    if (!isNotFound(err)) throw err;
  }
}

async function getServerPassword() {
  const vaultUri = process.env.KEY_VAULT_URI;
  if (!vaultUri) return null;
  const token = await credential.getToken('https://vault.azure.net/.default');
  const res = await fetch(`${vaultUri}secrets/server-password?api-version=7.4`, {
    headers: { Authorization: `Bearer ${token.token}` },
  });
  if (!res.ok) return null;
  return (await res.json()).value;
}

async function connectionInfo(ip) {
  const lines = [`接続先: \`${ip}:${gamePort}\``];
  const password = await getServerPassword();
  if (password) lines.push(`パスワード: \`${password}\``);
  return lines.join('\n');
}

async function startServer(context) {
  const state = await getPowerState();
  context.log(`current power state: ${state}`);

  const ip = await ensurePublicIp(context);
  if (state !== 'running') {
    context.log(`starting VM ${vmName}`);
    await compute.virtualMachines.beginStartAndWait(resourceGroup, vmName);
  }

  return [
    '🟢 **Palworld サーバーを起動しました！**',
    '',
    await connectionInfo(ip),
    '',
    '※ ワールドの読み込みに数分かかります。接続できない場合は少し待ってから再試行してください。',
  ].join('\n');
}

async function stopServer(context, { graceful = true } = {}) {
  const state = await getPowerState();
  context.log(`current power state: ${state}`);

  if (state === 'deallocated' || state === 'deallocating') {
    await removePublicIp(context);
    return '⚪ サーバーはすでに停止しています (コンピューティング課金なし)。';
  }

  if (graceful && state === 'running') {
    context.log('graceful shutdown via Run Command');
    try {
      await compute.virtualMachines.beginRunCommandAndWait(resourceGroup, vmName, {
        commandId: 'RunShellScript',
        script: ['systemctl stop palworld.service || true'],
      });
    } catch (err) {
      context.log(`run command failed, continuing to deallocate: ${err.message}`);
    }
  }

  context.log(`deallocating VM ${vmName}`);
  await compute.virtualMachines.beginDeallocateAndWait(resourceGroup, vmName);
  await removePublicIp(context);

  return '🔴 **Palworld サーバーを停止しました。** コンピューティングと IP の課金は止まりました。';
}

async function getStatus(context) {
  const state = await getPowerState();
  context.log(`current power state: ${state}`);

  if (state === 'running') {
    let ip = null;
    try {
      ip = (await network.publicIPAddresses.get(resourceGroup, pipName)).ipAddress;
    } catch (err) {
      if (!isNotFound(err)) throw err;
    }
    return ['🟢 **サーバーは稼働中です。**', '', ip ? await connectionInfo(ip) : '(Public IP なし — /palworld start を実行してください)'].join('\n');
  }
  return `⚪ サーバーは停止中です (${state})。\`/palworld start\` で起動できます。`;
}

module.exports = { startServer, stopServer, getStatus, getPowerState, removePublicIp };
