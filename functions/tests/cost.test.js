'use strict';

process.env.AZURE_SUBSCRIPTION_ID = 'sub-test';

jest.mock('@azure/identity', () => ({
  DefaultAzureCredential: jest.fn().mockImplementation(() => ({
    getToken: jest.fn().mockResolvedValue({ token: 'dummy-token' }),
  })),
}));

// fetch をグローバルにモック
global.fetch = jest.fn();

const { getCostSummary } = require('../src/lib/cost');

const mockContext = { log: jest.fn() };

function buildApiResponse(rows, columns) {
  return {
    properties: {
      columns: columns.map((name) => ({ name })),
      rows,
    },
  };
}

beforeEach(() => {
  jest.clearAllMocks();
});

describe('getCostSummary', () => {
  const COLUMNS = ['Cost', 'BillingMonth', 'ServiceName', 'Currency'];

  test('正常なレスポンスからコストサマリーを生成する', async () => {
    const now = new Date();
    const thisMonth = `${now.getUTCFullYear()}-${String(now.getUTCMonth() + 1).padStart(2, '0')}`;
    const billingMonth = `${now.getUTCFullYear()}-${String(now.getUTCMonth() + 1).padStart(2, '0')}-01T00:00:00Z`;

    const rows = [
      [10.5, billingMonth, 'Virtual Machines', 'JPY'],
      [3.2, billingMonth, 'Storage', 'JPY'],
    ];

    fetch.mockResolvedValue({
      ok: true,
      json: jest.fn().mockResolvedValue(buildApiResponse(rows, COLUMNS)),
    });

    const result = await getCostSummary(mockContext);

    expect(result).toContain('Azure コスト');
    expect(result).toContain(thisMonth);
    expect(result).toContain('今月・途中経過');
    expect(result).toContain('Virtual Machines');
    expect(result).toContain('Storage');
  });

  test('データが 0 件の場合は「まだ課金データがありません」を表示する', async () => {
    fetch.mockResolvedValue({
      ok: true,
      json: jest.fn().mockResolvedValue(buildApiResponse([], COLUMNS)),
    });

    const result = await getCostSummary(mockContext);

    expect(result).toContain('まだ課金データがありません');
  });

  test('先月と今月の 2 ヶ月分のデータを月別に集計する', async () => {
    const now = new Date();
    const thisMonthStr = `${now.getUTCFullYear()}-${String(now.getUTCMonth() + 1).padStart(2, '0')}-01T00:00:00Z`;
    const lastMonthDate = new Date(Date.UTC(now.getUTCFullYear(), now.getUTCMonth() - 1, 1));
    const lastMonthStr = `${lastMonthDate.getUTCFullYear()}-${String(lastMonthDate.getUTCMonth() + 1).padStart(2, '0')}-01T00:00:00Z`;

    const rows = [
      [20.0, lastMonthStr, 'Virtual Machines', 'JPY'],
      [5.0, thisMonthStr, 'Storage', 'JPY'],
    ];

    fetch.mockResolvedValue({
      ok: true,
      json: jest.fn().mockResolvedValue(buildApiResponse(rows, COLUMNS)),
    });

    const result = await getCostSummary(mockContext);

    const thisMonthKey = `${now.getUTCFullYear()}-${String(now.getUTCMonth() + 1).padStart(2, '0')}`;
    const lastMonthKey = `${lastMonthDate.getUTCFullYear()}-${String(lastMonthDate.getUTCMonth() + 1).padStart(2, '0')}`;

    expect(result).toContain(thisMonthKey);
    expect(result).toContain(lastMonthKey);
  });

  test('cost が 0.005 未満のサービスは表示しない', async () => {
    const now = new Date();
    const billingMonth = `${now.getUTCFullYear()}-${String(now.getUTCMonth() + 1).padStart(2, '0')}-01T00:00:00Z`;

    const rows = [
      [10.0, billingMonth, 'Virtual Machines', 'JPY'],
      [0.001, billingMonth, 'TinyService', 'JPY'],
    ];

    fetch.mockResolvedValue({
      ok: true,
      json: jest.fn().mockResolvedValue(buildApiResponse(rows, COLUMNS)),
    });

    const result = await getCostSummary(mockContext);

    expect(result).toContain('Virtual Machines');
    expect(result).not.toContain('TinyService');
  });

  test('API がエラーを返した場合は例外をスローする', async () => {
    fetch.mockResolvedValue({
      ok: false,
      status: 403,
      text: jest.fn().mockResolvedValue('Forbidden'),
    });

    await expect(getCostSummary(mockContext)).rejects.toThrow('Cost Management API failed: 403');
  });

  test('注釈テキストが含まれる', async () => {
    fetch.mockResolvedValue({
      ok: true,
      json: jest.fn().mockResolvedValue(buildApiResponse([], COLUMNS)),
    });

    const result = await getCostSummary(mockContext);

    expect(result).toContain('24時間');
  });
});
