#!/bin/bash

if [[ $EUID -ne 0 ]]; then
   echo "错误：此脚本必须以 root 权限运行！"
   exit 1
fi

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
JENSHOW_BASE_URL="${JENSHOW_BASE_URL:-https://raw.githubusercontent.com/showx/jenshow/main}"

if [[ -f "${SCRIPT_DIR}/setup_lib.sh" ]]; then
    # shellcheck source=setup_lib.sh
    source "${SCRIPT_DIR}/setup_lib.sh"
else
    # shellcheck disable=SC1090
    source <(curl -fsSL "${JENSHOW_BASE_URL}/setup_lib.sh")
fi

echo ">>> [1/5] 更新系统软件包..."
run_apt_update
run_apt_upgrade_if_needed

echo ">>> [2/5] Nginx..."
ensure_package nginx
ensure_systemd_service nginx

echo ">>> [3/5] Supervisor..."
ensure_package supervisor
ensure_systemd_service supervisor

echo ">>> [4/5] SSH (SFTP)..."
configure_ssh_for_sftp

echo ">>> [5/5] Redis..."
ensure_package redis-server
ensure_systemd_service redis-server

echo "================================================================="
echo "  基础环境搭建完成"
echo "  仓库: https://github.com/showx/jenshow"
echo "================================================================="
