#!/usr/bin/env bash
# functions/ を zip 化して dist/functions.zip を作る。
# 依存パッケージはデプロイ時のリモートビルド (SCM_DO_BUILD_DURING_DEPLOYMENT=true) で
# インストールされるため node_modules は含めない。
set -euo pipefail
cd "$(dirname "$0")/.."

mkdir -p dist
rm -f dist/functions.zip

(
  cd functions
  zip -r ../dist/functions.zip host.json package.json src \
    -x '*.DS_Store' -x '*node_modules*' -x 'local.settings.json'
)

echo "created dist/functions.zip"
