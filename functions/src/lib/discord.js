// Discord へのフォローアップ・通知 (Bot トークン不要、interaction token / webhook URL で認可される)

async function editOriginalResponse(interactionToken, content) {
  const applicationId = process.env.DISCORD_APPLICATION_ID;
  const url = `https://discord.com/api/v10/webhooks/${applicationId}/${interactionToken}/messages/@original`;
  const res = await fetch(url, {
    method: 'PATCH',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ content }),
  });
  if (!res.ok) {
    throw new Error(`Discord followup failed: ${res.status} ${await res.text()}`);
  }
}

async function notifyWebhook(content) {
  const url = process.env.DISCORD_WEBHOOK_URL;
  if (!url) return;
  try {
    const res = await fetch(url, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ content }),
    });
    if (!res.ok) {
      console.warn(`Discord webhook returned ${res.status}`);
    }
  } catch (err) {
    console.warn('Discord webhook failed:', err.message);
  }
}

module.exports = { editOriginalResponse, notifyWebhook };
