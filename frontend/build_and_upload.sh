#!/bin/bash

set -euo pipefail

bootstrap_deploy "$(cd "$(dirname "$0")" && pwd)"
require_server_host

VERSION=${1:-$(date +%Y%m%d_%H%M)}

build_frontend_package "${VERSION}" || {
    echo "❌ 构建失败，请检查 FRONTEND_SRC_DIR / FRONTEND_BUILD_CMD"
    exit 1
}

echo ">>> 上传: ${SERVER_USER}@${SERVER_HOST}:${REMOTE_BASE_PATH}/"
scp "${FRONTEND_ARCHIVE_PATH}" "${SERVER_USER}@${SERVER_HOST}:${REMOTE_BASE_PATH}/"

echo ">>> 远程解压..."
ssh "${SERVER_USER}@${SERVER_HOST}" "cd ${REMOTE_BASE_PATH} && \
    if [ -d '${SERVER_FRONTEND_DIST}' ]; then rm -rf ${SERVER_FRONTEND_DIST}_old && mv ${SERVER_FRONTEND_DIST} ${SERVER_FRONTEND_DIST}_old; fi && \
    mkdir -p ${SERVER_FRONTEND_DIST} && \
    tar -xzf ${FRONTEND_ARCHIVE_NAME} -C ${SERVER_FRONTEND_DIST} && \
    echo \"部署时间: \$(date)\" > ${SERVER_FRONTEND_DIST}/version.txt && \
    echo \"项目: ${PROJECT_NAME}\" >> ${SERVER_FRONTEND_DIST}/version.txt && \
    echo \"版本号: ${VERSION}\" >> ${SERVER_FRONTEND_DIST}/version.txt"

echo "🎉 前端部署完成 → ${REMOTE_DIST_PATH}"
