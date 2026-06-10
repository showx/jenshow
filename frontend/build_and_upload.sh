#!/bin/bash

set -euo pipefail

_script_dir="$(cd "$(dirname "$0")" && pwd)"
_root="${_script_dir}"
while [[ "${_root}" != "/" ]]; do
    if [[ -f "${_root}/project_lib.sh" ]]; then
        # shellcheck source=/dev/null
        source "${_root}/project_lib.sh"
        break
    fi
    _root="$(dirname "${_root}")"
done

bootstrap_deploy "${_script_dir}"
require_server_host

VERSION=${1:-$(date +%Y%m%d_%H%M)}

build_frontend_package "${VERSION}" || {
    echo "❌ 构建失败，请检查 FRONTEND_DIR / FRONTEND_BUILD_CMD"
    exit 1
}

echo ">>> 上传: ${SERVER_USER}@${SERVER_HOST}:${REMOTE_BASE_PATH}/"
scp "${FRONTEND_ARCHIVE_PATH}" "${SERVER_USER}@${SERVER_HOST}:${REMOTE_BASE_PATH}/"

echo ">>> 远程解压..."
ssh "${SERVER_USER}@${SERVER_HOST}" "cd ${REMOTE_BASE_PATH} && \
    if [ -d '${FRONTEND_DIST}' ]; then rm -rf ${FRONTEND_DIST}_old && mv ${FRONTEND_DIST} ${FRONTEND_DIST}_old; fi && \
    mkdir -p ${FRONTEND_DIST} && \
    tar -xzf ${FRONTEND_ARCHIVE_NAME} -C ${FRONTEND_DIST} && \
    echo \"部署时间: \$(date)\" > ${FRONTEND_DIST}/version.txt && \
    echo \"项目: ${PROJECT_NAME}\" >> ${FRONTEND_DIST}/version.txt && \
    echo \"版本号: ${VERSION}\" >> ${FRONTEND_DIST}/version.txt"

echo "🎉 前端部署完成 → ${REMOTE_DIST_PATH}"
