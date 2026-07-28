'use strict';

process.env.DISCORD_APPLICATION_ID = 'app-123';
process.env.DISCORD_WEBHOOK_URL = 'https://discord.com/api/webhooks/test/token';

global.fetch = jest.fn();

const { editOriginalResponse, notifyWebhook } = require('../src/lib/discord');

beforeEach(() => {
  jest.clearAllMocks();
});

describe('editOriginalResponse', () => {
  test('正常に PATCH リクエストを送信する', async () => {
    fetch.mockResolvedValue({ ok: true });

    await editOriginalResponse('interaction-token', 'テストメッセージ');

    expect(fetch).toHaveBeenCalledTimes(1);
    const [url, options] = fetch.mock.calls[0];
    expect(url).toContain('app-123');
    expect(url).toContain('interaction-token');
    expect(url).toContain('@original');
    expect(options.method).toBe('PATCH');
    expect(JSON.parse(options.body).content).toBe('テストメッセージ');
  });

  test('API がエラーを返した場合は例外をスローする', async () => {
    fetch.mockResolvedValue({
      ok: false,
      status: 401,
      text: jest.fn().mockResolvedValue('Unauthorized'),
    });

    await expect(editOriginalResponse('bad-token', 'msg')).rejects.toThrow(
      'Discord followup failed: 401'
    );
  });
});

describe('notifyWebhook', () => {
  test('WEBHOOK_URL が設定されている場合は POST を送信する', async () => {
    fetch.mockResolvedValue({ ok: true });

    await notifyWebhook('通知テスト');

    expect(fetch).toHaveBeenCalledTimes(1);
    const [url, options] = fetch.mock.calls[0];
    expect(url).toBe('https://discord.com/api/webhooks/test/token');
    expect(options.method).toBe('POST');
    expect(JSON.parse(options.body).content).toBe('通知テスト');
  });

  test('WEBHOOK_URL が未設定の場合は何もしない', async () => {
    const original = process.env.DISCORD_WEBHOOK_URL;
    delete process.env.DISCORD_WEBHOOK_URL;

    await notifyWebhook('スキップ');

    expect(fetch).not.toHaveBeenCalled();
    process.env.DISCORD_WEBHOOK_URL = original;
  });

  test('Webhook が HTTP エラーを返してもスローしない', async () => {
    fetch.mockResolvedValue({ ok: false, status: 500 });

    await expect(notifyWebhook('エラー時')).resolves.toBeUndefined();
  });

  test('fetch 自体が失敗してもスローしない', async () => {
    fetch.mockRejectedValue(new Error('network error'));

    await expect(notifyWebhook('ネットワークエラー時')).resolves.toBeUndefined();
  });
});
