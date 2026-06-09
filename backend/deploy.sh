#!/bin/bash

set -euo pipefail

[[ -n "${1:-}" ]] || {
    echo "用法: ./deploy.sh <版本号>"
    exit 1
}

_deploy_script_dir="$(cd "$(dirname "$0")" && pwd)"

if [[ -f "${_deploy_script_dir}/project.conf" ]]; then
    # shellcheck source=project.conf
    source "${_deploy_script_dir}/project.conf"
else
    _root="${_deploy_script_dir}"
    while [[ "${_root}" != "/" ]]; do
        if [[ -f "${_root}/project.conf" ]]; then
            # shellcheck source=/dev/null
            source "${_root}/project.conf"
            break
        fi
        _root="$(dirname "${_root}")"
    done
fi

[[ -n "${APP_NAME:-}" ]] || APP_NAME="${PROJECT_NAME}-server"
[[ -n "${SUPERVISOR_PROGRAM:-}" ]] || SUPERVISOR_PROGRAM="${APP_NAME}"

VERSION=$1
TARGET_BIN="${APP_NAME}${VERSION}"
LINK_NAME="${APP_NAME}"

cd "${_deploy_script_dir}"

[[ -f "${TARGET_BIN}" ]] || {
    echo "错误: 找不到 ${TARGET_BIN}"
    exit 1
}

chmod 744 "${TARGET_BIN}"
ln -snf "${TARGET_BIN}" "${LINK_NAME}"
sudo supervisorctl restart "${SUPERVISOR_PROGRAM}"

echo ">>> ${PROJECT_NAME} 版本 ${VERSION} 已上线"
