#!/bin/bash
# 后端发布：默认编译+上传+远程切换；--upload-only 仅上传

set -euo pipefail

UPLOAD_ONLY=0
if [[ "${1:-}" == "--upload-only" ]]; then
    UPLOAD_ONLY=1
    shift
fi

bootstrap_deploy "$(cd "$(dirname "$0")" && pwd)"
require_server_host

VERSION=${1:-$(date +%Y%m%d_%H%M)}
BINARY_NAME="${APP_NAME}${VERSION}"

echo "=========================================="
echo "🚀 ${PROJECT_NAME} / ${BINARY_NAME}"
echo "=========================================="

build_backend_binary "${BINARY_NAME}" || {
    echo "❌ 编译失败，请检查 BACKEND_SRC_DIR / GO_BUILD_TARGET"
    exit 1
}
echo "✅ 编译成功"

upload_backend_binary "${BINARY_NAME}" || {
    echo "❌ 上传失败"
    exit 1
}
echo "✅ 上传成功"

if [[ "${UPLOAD_ONLY}" -eq 1 ]]; then
    echo "登录服务器: cd ${REMOTE_PATH} && ./deploy.sh ${VERSION}"
    exit 0
fi

deploy_backend_remote "${VERSION}" || {
    echo "❌ 远程部署失败"
    exit 1
}

echo "🎉 ${SUPERVISOR_PROGRAM} 版本 ${VERSION} 已上线"
