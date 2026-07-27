'use strict';

// モジュールロード前に環境変数をセット
process.env.AZURE_SUBSCRIPTION_ID = 'sub-test';
process.env.RESOURCE_GROUP = 'rg-test';
process.env.VM_NAME = 'vm-test';
process.env.NIC_NAME = 'nic-test';
process.env.PIP_NAME = 'pip-test';
process.env.LOCATION = 'japaneast';
process.env.GAME_PORT = '8211';

// Azure SDK をモック
const mockBeginStartAndWait = jest.fn().mockResolvedValue({});
const mockBeginDeallocateAndWait = jest.fn().mockResolvedValue({});
const mockBeginRunCommandAndWait = jest.fn().mockResolvedValue({});
const mockInstanceView = jest.fn();
const mockBeginCreateOrUpdateAndWait = jest.fn();
const mockNicBeginCreateOrUpdateAndWait = jest.fn();
const mockGetNic = jest.fn();
const mockGetPip = jest.fn();
const mockBeginDeleteAndWait = jest.fn();

jest.mock('@azure/identity', () => ({
  DefaultAzureCredential: jest.fn().mockImplementation(() => ({
    getToken: jest.fn().mockResolvedValue({ token: 'dummy-token' }),
  })),
}));

jest.mock('@azure/arm-compute', () => ({
  ComputeManagementClient: jest.fn().mockImplementation(() => ({
    virtualMachines: {
      instanceView: mockInstanceView,
      beginStartAndWait: mockBeginStartAndWait,
      beginDeallocateAndWait: mockBeginDeallocateAndWait,
      beginRunCommandAndWait: mockBeginRunCommandAndWait,
    },
  })),
}));

jest.mock('@azure/arm-network', () => ({
  NetworkManagementClient: jest.fn().mockImplementation(() => ({
    publicIPAddresses: {
      get: mockGetPip,
      beginCreateOrUpdateAndWait: mockBeginCreateOrUpdateAndWait,
      beginDeleteAndWait: mockBeginDeleteAndWait,
    },
    networkInterfaces: {
      get: mockGetNic,
      beginCreateOrUpdateAndWait: mockNicBeginCreateOrUpdateAndWait,
    },
  })),
}));

const { startServer, stopServer, getStatus, getPowerState, removePublicIp } = require('../src/lib/azure');

const mockContext = { log: jest.fn() };

function makeNic(pipId = null) {
  return {
    ipConfigurations: [{ publicIPAddress: pipId ? { id: pipId } : null }],
  };
}

function makePip(ipAddress = '1.2.3.4', id = '/pip/pip-test') {
  return { id, ipAddress };
}

beforeEach(() => {
  jest.clearAllMocks();
});

// ─── getPowerState ────────────────────────────────────────────────────────────

describe('getPowerState', () => {
  test('PowerState/running を返す', async () => {
    mockInstanceView.mockResolvedValue({
      statuses: [{ code: 'ProvisioningState/succeeded' }, { code: 'PowerState/running' }],
    });
    await expect(getPowerState()).resolves.toBe('running');
  });

  test('PowerState が見つからない場合は unknown を返す', async () => {
    mockInstanceView.mockResolvedValue({ statuses: [] });
    await expect(getPowerState()).resolves.toBe('unknown');
  });
});

// ─── removePublicIp ───────────────────────────────────────────────────────────

describe('removePublicIp', () => {
  test('PIP が NIC に紐付いている場合は切り離して削除する', async () => {
    const nic = makeNic('/pip/pip-test');
    mockGetNic.mockResolvedValue(nic);
    mockNicBeginCreateOrUpdateAndWait.mockResolvedValue({});
    mockBeginDeleteAndWait.mockResolvedValue({});

    await removePublicIp(mockContext);

    expect(mockNicBeginCreateOrUpdateAndWait).toHaveBeenCalledTimes(1);
    expect(nic.ipConfigurations[0].publicIPAddress).toBeNull();
    expect(mockBeginDeleteAndWait).toHaveBeenCalledTimes(1);
  });

  test('PIP が既になければ NIC 更新をスキップする', async () => {
    mockGetNic.mockResolvedValue(makeNic(null));
    mockBeginDeleteAndWait.mockResolvedValue({});

    await removePublicIp(mockContext);

    expect(mockNicBeginCreateOrUpdateAndWait).not.toHaveBeenCalled();
    expect(mockBeginDeleteAndWait).toHaveBeenCalledTimes(1);
  });

  test('PIP が 404 の場合はエラーを握り潰す', async () => {
    mockGetNic.mockResolvedValue(makeNic(null));
    const notFound = Object.assign(new Error('not found'), { statusCode: 404 });
    mockBeginDeleteAndWait.mockRejectedValue(notFound);

    await expect(removePublicIp(mockContext)).resolves.toBeUndefined();
  });

  test('PIP 削除で 404 以外のエラーは再スローする', async () => {
    mockGetNic.mockResolvedValue(makeNic(null));
    mockBeginDeleteAndWait.mockRejectedValue(new Error('server error'));

    await expect(removePublicIp(mockContext)).rejects.toThrow('server error');
  });
});

// ─── startServer ─────────────────────────────────────────────────────────────

describe('startServer', () => {
  beforeEach(() => {
    delete process.env.KEY_VAULT_URI;
  });

  test('VM が停止中の場合は起動して接続先を返す', async () => {
    mockInstanceView.mockResolvedValue({ statuses: [{ code: 'PowerState/deallocated' }] });
    mockGetPip.mockResolvedValue(makePip('1.2.3.4'));
    mockGetNic.mockResolvedValue(makeNic('/pip/pip-test'));

    const result = await startServer(mockContext);

    expect(mockBeginStartAndWait).toHaveBeenCalledTimes(1);
    expect(result).toContain('起動しました');
    expect(result).toContain('1.2.3.4:8211');
  });

  test('VM が既に running の場合は start を呼ばない', async () => {
    mockInstanceView.mockResolvedValue({ statuses: [{ code: 'PowerState/running' }] });
    mockGetPip.mockResolvedValue(makePip('1.2.3.4'));
    mockGetNic.mockResolvedValue(makeNic('/pip/pip-test'));

    const result = await startServer(mockContext);

    expect(mockBeginStartAndWait).not.toHaveBeenCalled();
    expect(result).toContain('起動しました');
  });

  test('PIP が存在しない場合は新規作成して NIC に紐付ける', async () => {
    mockInstanceView.mockResolvedValue({ statuses: [{ code: 'PowerState/deallocated' }] });
    const notFound = Object.assign(new Error('not found'), { statusCode: 404 });
    mockGetPip
      .mockRejectedValueOnce(notFound)
      .mockResolvedValueOnce(makePip('5.6.7.8'));
    mockBeginCreateOrUpdateAndWait.mockResolvedValue({ id: '/pip/pip-test', ipAddress: null });
    const nic = makeNic(null);
    mockGetNic.mockResolvedValue(nic);
    mockNicBeginCreateOrUpdateAndWait.mockResolvedValue({});

    const result = await startServer(mockContext);

    expect(mockBeginCreateOrUpdateAndWait).toHaveBeenCalledTimes(1);
    expect(mockNicBeginCreateOrUpdateAndWait).toHaveBeenCalledTimes(1);
    expect(result).toContain('5.6.7.8:8211');
  });
});

// ─── stopServer ───────────────────────────────────────────────────────────────

describe('stopServer', () => {
  test('running の場合はグレースフルシャットダウン後に deallocate する', async () => {
    mockInstanceView.mockResolvedValue({ statuses: [{ code: 'PowerState/running' }] });
    mockGetNic.mockResolvedValue(makeNic(null));
    mockBeginDeleteAndWait.mockResolvedValue({});

    const result = await stopServer(mockContext, { graceful: true });

    expect(mockBeginRunCommandAndWait).toHaveBeenCalledTimes(1);
    expect(mockBeginDeallocateAndWait).toHaveBeenCalledTimes(1);
    expect(result).toContain('停止しました');
  });

  test('graceful=false の場合は Run Command をスキップする', async () => {
    mockInstanceView.mockResolvedValue({ statuses: [{ code: 'PowerState/running' }] });
    mockGetNic.mockResolvedValue(makeNic(null));
    mockBeginDeleteAndWait.mockResolvedValue({});

    await stopServer(mockContext, { graceful: false });

    expect(mockBeginRunCommandAndWait).not.toHaveBeenCalled();
    expect(mockBeginDeallocateAndWait).toHaveBeenCalledTimes(1);
  });

  test('Run Command が失敗しても deallocate は続行する', async () => {
    mockInstanceView.mockResolvedValue({ statuses: [{ code: 'PowerState/running' }] });
    mockBeginRunCommandAndWait.mockRejectedValue(new Error('run command error'));
    mockGetNic.mockResolvedValue(makeNic(null));
    mockBeginDeleteAndWait.mockResolvedValue({});

    const result = await stopServer(mockContext, { graceful: true });

    expect(mockBeginDeallocateAndWait).toHaveBeenCalledTimes(1);
    expect(result).toContain('停止しました');
  });

  test('deallocated の場合はすでに停止中のメッセージを返す', async () => {
    mockInstanceView.mockResolvedValue({ statuses: [{ code: 'PowerState/deallocated' }] });
    mockGetNic.mockResolvedValue(makeNic(null));
    mockBeginDeleteAndWait.mockResolvedValue({});

    const result = await stopServer(mockContext);

    expect(mockBeginDeallocateAndWait).not.toHaveBeenCalled();
    expect(result).toContain('すでに停止しています');
  });
});

// ─── getStatus ────────────────────────────────────────────────────────────────

describe('getStatus', () => {
  test('running かつ PIP あり → IP アドレス付きメッセージ', async () => {
    mockInstanceView.mockResolvedValue({ statuses: [{ code: 'PowerState/running' }] });
    mockGetPip.mockResolvedValue(makePip('9.10.11.12'));
    delete process.env.KEY_VAULT_URI;

    const result = await getStatus(mockContext);

    expect(result).toContain('稼働中');
    expect(result).toContain('9.10.11.12:8211');
  });

  test('running かつ PIP なし → start 案内メッセージ', async () => {
    mockInstanceView.mockResolvedValue({ statuses: [{ code: 'PowerState/running' }] });
    const notFound = Object.assign(new Error('not found'), { code: 'ResourceNotFound' });
    mockGetPip.mockRejectedValue(notFound);

    const result = await getStatus(mockContext);

    expect(result).toContain('稼働中');
    expect(result).toContain('start');
  });

  test('deallocated → 停止中メッセージ', async () => {
    mockInstanceView.mockResolvedValue({ statuses: [{ code: 'PowerState/deallocated' }] });

    const result = await getStatus(mockContext);

    expect(result).toContain('停止中');
    expect(result).toContain('start');
  });
});
