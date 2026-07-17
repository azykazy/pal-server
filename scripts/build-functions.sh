#!/usr/bin/env bash
# functions/ を zip 化して dist/functions.zip を作る。
# Flex Consumption はリモートビルド用の app setting (SCM_DO_BUILD_DURING_DEPLOYMENT) を
# サポートしないため、本番依存の node_modules を zip に同梱する。
set -euo pipefail
cd "$(dirname "$0")/.."

mkdir -p dist
rm -f dist/functions.zip

(
  cd functions
  npm ci --omit=dev --no-audit --no-fund
  zip -qr ../dist/functions.zip host.json package.json src node_modules \
    -x '*.DS_Store' -x 'local.settings.json'
)

echo "created dist/functions.zip ($(du -h dist/functions.zip | cut -f1))"
