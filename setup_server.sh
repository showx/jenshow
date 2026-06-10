#!/bin/bash

# 服务器一键环境搭建（配置来自 project.conf）

if [[ $EUID -ne 0 ]]; then
   echo "错误：此脚本必须以 root 权限运行！"
   exit 1
fi

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
JENSHOW_BASE_URL="${JENSHOW_BASE_URL:-https://raw.githubusercontent.com/showx/jenshow/master}"

if [[ -f "${SCRIPT_DIR}/setup_lib.sh" ]]; then
    # shellcheck source=setup_lib.sh
    source "${SCRIPT_DIR}/setup_lib.sh"
else
    # shellcheck disable=SC1090
    source <(curl -fsSL "${JENSHOW_BASE_URL}/setup_lib.sh")
fi

load_setup_libs "${SCRIPT_DIR}"
load_setup_project_config "${SCRIPT_DIR}"

echo ">>> 项目: ${PROJECT_NAME} | 服务: ${SUPERVISOR_PROGRAM} | 目录: ${WEB_ROOT}"

echo ">>> [1/9] 更新系统软件包..."
run_apt_update
run_apt_upgrade_if_needed

echo ">>> [2/9] Nginx..."
ensure_package nginx
ensure_systemd_service nginx

echo ">>> [3/9] Supervisor..."
ensure_package supervisor
ensure_systemd_service supervisor

echo ">>> [4/9] SSH (SFTP)..."
configure_ssh_for_sftp

echo ">>> [5/9] 项目目录..."
ensure_directory "${SERVER_BACKEND}"
ensure_directory "${SERVER_FRONTEND_DIST}"
ensure_directory "${SERVER_FRONTEND}" "www-data:www-data"

echo ">>> [6/9] Redis..."
ensure_package redis-server
ensure_systemd_service redis-server

echo ">>> [7/9] Nginx 站点 (${NGINX_CONF})..."
ensure_nginx_site "${NGINX_CONF}" <<EOF
server {
    listen 80;
    server_name ${API_DOMAIN};

    root ${SERVER_FRONTEND_DIST};
    index index.html;

    location ${FRONTEND_ROUTE} {
        try_files \$uri \$uri/ /index.html;
    }

    location / {
        proxy_pass http://127.0.0.1:${BACKEND_PORT};
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }
}
EOF

echo ">>> [8/9] Supervisor (${SUPERVISOR_PROGRAM})..."
ensure_supervisor_program "${SUPERVISOR_CONF}" "${SUPERVISOR_PROGRAM}" <<EOF
$(render_supervisor_conf)
EOF

echo ">>> [9/9] 同步 deploy 配置..."
render_server_project_conf | write_file_if_changed "${SERVER_BACKEND}/project.conf" || true
ensure_remote_script "${JENSHOW_BASE_URL}/backend/deploy.sh" "${SERVER_BACKEND}/deploy.sh"

echo "================================================================="
echo "  搭建完成 | 项目: ${PROJECT_NAME} | 服务: ${SUPERVISOR_PROGRAM}"
echo "  后端: ${SERVER_BACKEND} | 前端: ${SERVER_FRONTEND_DIST}"
echo "  仓库: https://github.com/showx/jenshow"
echo "================================================================="
