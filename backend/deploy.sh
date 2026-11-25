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

# ln -snf 不检查目标是否存在。文件不在或是空文件时不能切换，也不重启服务。
if [[ ! -f "${TARGET_BIN}" ]]; then
    echo "错误: 文件不存在，已取消切换: ${TARGET_BIN}"
    exit 1
fi
if [[ ! -s "${TARGET_BIN}" ]]; then
    echo "错误: 文件是空的，已取消切换: ${TARGET_BIN}"
    exit 1
fi

previous_link=""
had_link=0
if [[ -L "${LINK_NAME}" ]]; then
    had_link=1
    previous_link="$(readlink "${LINK_NAME}")"
fi

chmod 744 "${TARGET_BIN}"
if [[ ! -f "${TARGET_BIN}" || ! -s "${TARGET_BIN}" ]]; then
    echo "错误: 文件不存在或为空，已取消切换: ${TARGET_BIN}"
    exit 1
fi

ln -snf "${TARGET_BIN}" "${LINK_NAME}"
if [[ ! -f "${LINK_NAME}" || ! -s "${LINK_NAME}" ]]; then
    echo "错误: 切换后 ${LINK_NAME} 不可用，已恢复原版本"
    if [[ "${had_link}" -eq 1 ]]; then
        ln -snf "${previous_link}" "${LINK_NAME}"
    else
        rm -f "${LINK_NAME}"
    fi
    exit 1
fi

sudo supervisorctl restart "${SUPERVISOR_PROGRAM}"

echo ">>> ${PROJECT_NAME} 版本 ${VERSION} 已上线"
