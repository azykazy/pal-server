// Azure Cost Management API で先月〜今月のコストを月別に取得する。
// 追加パッケージは使わず、Managed Identity のトークンで REST を直接呼ぶ。
const { DefaultAzureCredential } = require('@azure/identity');

const credential = new DefaultAzureCredential();
const subscriptionId = process.env.AZURE_SUBSCRIPTION_ID;

async function getCostSummary(context) {
  const token = await credential.getToken('https://management.azure.com/.default');
  const url = `https://management.azure.com/subscriptions/${subscriptionId}/providers/Microsoft.CostManagement/query?api-version=2023-11-01`;

  // 先月1日 00:00 〜 現在 (UTC) を月次グラニュラリティで1クエリ取得
  const now = new Date();
  const from = new Date(Date.UTC(now.getUTCFullYear(), now.getUTCMonth() - 1, 1));

  const res = await fetch(url, {
    method: 'POST',
    headers: {
      Authorization: `Bearer ${token.token}`,
      'Content-Type': 'application/json',
    },
    body: JSON.stringify({
      type: 'ActualCost',
      timeframe: 'Custom',
      timePeriod: { from: from.toISOString(), to: now.toISOString() },
      dataset: {
        granularity: 'Monthly',
        aggregation: { totalCost: { name: 'Cost', function: 'Sum' } },
        grouping: [{ type: 'Dimension', name: 'ServiceName' }],
      },
    }),
  });
  if (!res.ok) {
    throw new Error(`Cost Management API failed: ${res.status} ${await res.text()}`);
  }

  const data = await res.json();
  const columns = data.properties.columns.map((c) => c.name);
  const iCost = columns.indexOf('Cost');
  const iMonth = columns.indexOf('BillingMonth');
  const iService = columns.indexOf('ServiceName');
  const iCurrency = columns.indexOf('Currency');

  // 月 (YYYY-MM) ごとにサービス別コストを集計
  const byMonth = new Map();
  let currency = 'USD';
  for (const r of data.properties.rows || []) {
    const monthKey = String(r[iMonth]).slice(0, 7);
    currency = r[iCurrency] || currency;
    if (!byMonth.has(monthKey)) byMonth.set(monthKey, []);
    byMonth.get(monthKey).push({ cost: r[iCost], service: r[iService] });
  }

  const fmt = (n) => n.toLocaleString('ja-JP', { maximumFractionDigits: 2 });
  const thisMonth = `${now.getUTCFullYear()}-${String(now.getUTCMonth() + 1).padStart(2, '0')}`;
  const lines = ['💰 **Azure コスト (先月〜今月)**'];

  const months = [...byMonth.keys()].sort().reverse();
  for (const month of months) {
    const rows = byMonth.get(month).sort((a, b) => b.cost - a.cost);
    const total = rows.reduce((sum, r) => sum + r.cost, 0);
    const label = month === thisMonth ? `${month} (今月・途中経過)` : month;
    lines.push('', `📅 **${label}: ${fmt(total)} ${currency}**`);

    const top = rows.filter((r) => r.cost >= 0.005).slice(0, 6);
    for (const r of top) {
      lines.push(`　・${r.service}: ${fmt(r.cost)}`);
    }
    const restCount = rows.filter((r) => r.cost >= 0.005).length - top.length;
    if (restCount > 0) lines.push(`　・(ほか ${restCount} サービス)`);
  }

  if (months.length === 0) {
    lines.push('', 'まだ課金データがありません。');
  }

  context.log(`cost summary generated for ${months.length} month(s)`);
  lines.push('', '※ 課金データの反映には最大24時間ほどかかります。');
  return lines.join('\n');
}

module.exports = { getCostSummary };
