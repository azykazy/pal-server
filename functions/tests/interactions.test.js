'use strict';

process.env.DISCORD_PUBLIC_KEY = 'test-public-key';

let capturedHandler;

jest.mock('@azure/functions', () => ({
  app: {
    http: jest.fn((_name, config) => {
      capturedHandler = config.handler;
    }),
  },
  output: {
    storageQueue: jest.fn(() => 'mock-queue'),
  },
}));

const mockVerifyKey = jest.fn();

jest.mock('discord-interactions', () => ({
  verifyKey: mockVerifyKey,
  InteractionType: {
    PING: 1,
    APPLICATION_COMMAND: 2,
    MESSAGE_COMPONENT: 3,
  },
  InteractionResponseType: {
    PONG: 1,
    CHANNEL_MESSAGE_WITH_SOURCE: 4,
    DEFERRED_CHANNEL_MESSAGE_WITH_SOURCE: 5,
  },
}));

require('../src/functions/interactions');

function makeRequest(body) {
  return {
    headers: {
      get: (name) => {
        if (name === 'x-signature-ed25519') return 'test-sig';
        if (name === 'x-signature-timestamp') return 'test-ts';
        return null;
      },
    },
    text: jest.fn().mockResolvedValue(JSON.stringify(body)),
  };
}

function makeContext() {
  const queueSet = jest.fn();
  return {
    log: jest.fn(),
    warn: jest.fn(),
    error: jest.fn(),
    extraOutputs: { set: queueSet },
    _queueSet: queueSet,
  };
}

beforeEach(() => {
  jest.clearAllMocks();
  mockVerifyKey.mockResolvedValue(true);
});

// ─── 署名検証 ─────────────────────────────────────────────────────────────────

describe('署名検証', () => {
  test('#1 署名が正しい /palworld start → deferred ephemeral を返す', async () => {
    const ctx = makeContext();
    const req = makeRequest({
      type: 2,
      token: 'tok',
      data: { name: 'palworld', options: [{ name: 'start' }] },
    });

    const result = await capturedHandler(req, ctx);

    expect(result.status).toBeUndefined();
    expect(result.jsonBody.type).toBe(5);
    expect(result.jsonBody.data?.flags).toBe(64);
  });

  test('#2 署名が不正 → 401 を返す', async () => {
    mockVerifyKey.mockResolvedValue(false);
    const ctx = makeContext();
    const req = makeRequest({ type: 1, token: 'tok' });

    const result = await capturedHandler(req, ctx);

    expect(result.status).toBe(401);
    expect(ctx.warn).toHaveBeenCalledWith('invalid request signature');
  });
});

// ─── PING ─────────────────────────────────────────────────────────────────────

describe('PING', () => {
  test('#3 PING に対して PONG を返す', async () => {
    const ctx = makeContext();
    const req = makeRequest({ type: 1, token: 'tok' });

    const result = await capturedHandler(req, ctx);

    expect(result.jsonBody.type).toBe(1);
  });
});

// ─── スラッシュコマンド ───────────────────────────────────────────────────────

describe('スラッシュコマンド', () => {
  test('#4 start コマンド → キューに {action:start, token} が積まれる', async () => {
    const ctx = makeContext();
    const req = makeRequest({
      type: 2,
      token: 'tok-start',
      data: { name: 'palworld', options: [{ name: 'start' }] },
    });

    await capturedHandler(req, ctx);

    expect(ctx._queueSet).toHaveBeenCalledWith('mock-queue', { action: 'start', token: 'tok-start' });
  });

  test('#6 不明なサブコマンド → エラーメッセージを返す（キューに積まない）', async () => {
    const ctx = makeContext();
    const req = makeRequest({
      type: 2,
      token: 'tok',
      data: { name: 'palworld', options: [{ name: 'unknown' }] },
    });

    const result = await capturedHandler(req, ctx);

    expect(result.jsonBody.data.content).toContain('不明なサブコマンド');
    expect(ctx._queueSet).not.toHaveBeenCalled();
  });

  test.each(['start', 'status'])('#7 %s コマンドは flags:64 の deferred 応答を返す', async (action) => {
    const ctx = makeContext();
    const req = makeRequest({
      type: 2,
      token: 'tok',
      data: { name: 'palworld', options: [{ name: action }] },
    });

    const result = await capturedHandler(req, ctx);

    expect(result.jsonBody.type).toBe(5);
    expect(result.jsonBody.data?.flags).toBe(64);
  });

  test.each(['stop', 'cost'])('#8 %s コマンドは flags なしの deferred 応答を返す', async (action) => {
    const ctx = makeContext();
    const req = makeRequest({
      type: 2,
      token: 'tok',
      data: { name: 'palworld', options: [{ name: action }] },
    });

    const result = await capturedHandler(req, ctx);

    expect(result.jsonBody.type).toBe(5);
    expect(result.jsonBody.data?.flags).toBeUndefined();
  });
});

// ─── ボタン操作 ───────────────────────────────────────────────────────────────

describe('ボタン操作', () => {
  test('#5 ボタン palworld_start → キューに積まれる', async () => {
    const ctx = makeContext();
    const req = makeRequest({
      type: 3,
      token: 'btn-tok',
      data: { custom_id: 'palworld_start' },
    });

    await capturedHandler(req, ctx);

    expect(ctx._queueSet).toHaveBeenCalledWith('mock-queue', { action: 'start', token: 'btn-tok' });
  });

  test('不明な custom_id のボタン → エラーメッセージを返す（キューに積まない）', async () => {
    const ctx = makeContext();
    const req = makeRequest({
      type: 3,
      token: 'tok',
      data: { custom_id: 'palworld_unknown' },
    });

    const result = await capturedHandler(req, ctx);

    expect(result.jsonBody.data.content).toContain('不明な操作');
    expect(ctx._queueSet).not.toHaveBeenCalled();
  });
});
