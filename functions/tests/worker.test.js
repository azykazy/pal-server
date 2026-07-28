'use strict';

let capturedHandler;

jest.mock('@azure/functions', () => ({
  app: {
    storageQueue: jest.fn((_name, config) => {
      capturedHandler = config.handler;
    }),
  },
}));

const mockStartServer = jest.fn();
const mockStopServer = jest.fn();
const mockGetStatus = jest.fn();
const mockGetCostSummary = jest.fn();
const mockEditOriginalResponse = jest.fn().mockResolvedValue(undefined);

jest.mock('../src/lib/azure', () => ({
  startServer: mockStartServer,
  stopServer: mockStopServer,
  getStatus: mockGetStatus,
}));

jest.mock('../src/lib/cost', () => ({
  getCostSummary: mockGetCostSummary,
}));

jest.mock('../src/lib/discord', () => ({
  editOriginalResponse: mockEditOriginalResponse,
}));

require('../src/functions/worker');

function makeContext() {
  return {
    log: jest.fn(),
    warn: jest.fn(),
    error: jest.fn(),
  };
}

beforeEach(() => {
  jest.clearAllMocks();
  mockStartServer.mockResolvedValue('🟢 起動しました');
  mockStopServer.mockResolvedValue('🔴 停止しました');
  mockGetStatus.mockResolvedValue('🟢 稼働中');
  mockGetCostSummary.mockResolvedValue('💰 コスト: ¥1,234');
  mockEditOriginalResponse.mockResolvedValue(undefined);
});

// ─── 正常系 ───────────────────────────────────────────────────────────────────

describe('worker handler 正常系', () => {
  test('#9 start ジョブ → startServer() を呼び Discord に結果を送る', async () => {
    const ctx = makeContext();

    await capturedHandler({ action: 'start', token: 'tok-start' }, ctx);

    expect(mockStartServer).toHaveBeenCalledWith(ctx);
    expect(mockEditOriginalResponse).toHaveBeenCalledWith('tok-start', '🟢 起動しました');
  });

  test('#10 stop ジョブ → stopServer() を呼び Discord に結果を送る', async () => {
    const ctx = makeContext();

    await capturedHandler({ action: 'stop', token: 'tok-stop' }, ctx);

    expect(mockStopServer).toHaveBeenCalledWith(ctx, { graceful: true });
    expect(mockEditOriginalResponse).toHaveBeenCalledWith('tok-stop', '🔴 停止しました');
  });

  test('#11 status ジョブ → getStatus() を呼ぶ', async () => {
    const ctx = makeContext();

    await capturedHandler({ action: 'status', token: 'tok-status' }, ctx);

    expect(mockGetStatus).toHaveBeenCalledWith(ctx);
    expect(mockEditOriginalResponse).toHaveBeenCalledWith('tok-status', '🟢 稼働中');
  });

  test('#12 cost ジョブ → getCostSummary() を呼ぶ', async () => {
    const ctx = makeContext();

    await capturedHandler({ action: 'cost', token: 'tok-cost' }, ctx);

    expect(mockGetCostSummary).toHaveBeenCalledWith(ctx);
    expect(mockEditOriginalResponse).toHaveBeenCalledWith('tok-cost', '💰 コスト: ¥1,234');
  });
});

// ─── エラー系 ─────────────────────────────────────────────────────────────────

describe('worker handler エラー系', () => {
  test('#13 startServer が例外 → エラーメッセージを Discord に送りクラッシュしない', async () => {
    mockStartServer.mockRejectedValue(new Error('VM start failed'));
    const ctx = makeContext();

    await expect(capturedHandler({ action: 'start', token: 'tok' }, ctx)).resolves.toBeUndefined();

    expect(ctx.error).toHaveBeenCalledWith('action start failed', expect.any(Error));
    expect(mockEditOriginalResponse).toHaveBeenCalledWith(
      'tok',
      expect.stringContaining('VM start failed'),
    );
  });

  test('#14 stopServer が例外 → エラーメッセージを Discord に送りクラッシュしない', async () => {
    mockStopServer.mockRejectedValue(new Error('Deallocate failed'));
    const ctx = makeContext();

    await expect(capturedHandler({ action: 'stop', token: 'tok' }, ctx)).resolves.toBeUndefined();

    expect(ctx.error).toHaveBeenCalledWith('action stop failed', expect.any(Error));
    expect(mockEditOriginalResponse).toHaveBeenCalledWith(
      'tok',
      expect.stringContaining('Deallocate failed'),
    );
  });
});
