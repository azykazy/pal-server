const { app, output } = require('@azure/functions');
const { verifyKey, InteractionType, InteractionResponseType } = require('discord-interactions');

// Discord の 3 秒制限内に deferred 応答を返し、実処理はキュー経由で worker に渡す
const jobQueue = output.storageQueue({
  queueName: 'palworld-jobs',
  connection: 'AzureWebJobsStorage',
});

app.http('interactions', {
  methods: ['POST'],
  authLevel: 'anonymous',
  route: 'interactions',
  extraOutputs: [jobQueue],
  handler: async (request, context) => {
    const signature = request.headers.get('x-signature-ed25519');
    const timestamp = request.headers.get('x-signature-timestamp');
    const rawBody = await request.text();

    const isValid =
      signature &&
      timestamp &&
      (await verifyKey(rawBody, signature, timestamp, process.env.DISCORD_PUBLIC_KEY));
    if (!isValid) {
      context.warn('invalid request signature');
      return { status: 401, body: 'invalid request signature' };
    }

    const interaction = JSON.parse(rawBody);

    if (interaction.type === InteractionType.PING) {
      return { jsonBody: { type: InteractionResponseType.PONG } };
    }

    const VALID_ACTIONS = ['start', 'stop', 'status', 'cost'];

    // スラッシュコマンド (/palworld <action>)
    if (
      interaction.type === InteractionType.APPLICATION_COMMAND &&
      interaction.data?.name === 'palworld'
    ) {
      const action = interaction.data.options?.[0]?.name;
      if (!VALID_ACTIONS.includes(action)) {
        return {
          jsonBody: {
            type: InteractionResponseType.CHANNEL_MESSAGE_WITH_SOURCE,
            data: { content: '不明なサブコマンドです。' },
          },
        };
      }

      context.extraOutputs.set(jobQueue, { action, token: interaction.token });
      context.log(`queued action (slash): ${action}`);
      return {
        jsonBody: { type: InteractionResponseType.DEFERRED_CHANNEL_MESSAGE_WITH_SOURCE },
      };
    }

    // 操作パネルのボタン (custom_id: palworld_<action>)
    if (interaction.type === InteractionType.MESSAGE_COMPONENT) {
      const action = (interaction.data?.custom_id || '').replace(/^palworld_/, '');
      if (!VALID_ACTIONS.includes(action)) {
        return { status: 400, body: 'unknown component' };
      }

      context.extraOutputs.set(jobQueue, { action, token: interaction.token });
      context.log(`queued action (button): ${action}`);
      return {
        jsonBody: { type: InteractionResponseType.DEFERRED_CHANNEL_MESSAGE_WITH_SOURCE },
      };
    }

    return { status: 400, body: 'unsupported interaction' };
  },
});
