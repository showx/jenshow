#!/bin/bash
# setup 脚本公共工具：已安装/已配置则跳过，避免重复处理

setup_log_skip() {
    echo "⏭  跳过: $1"
}

setup_log_do() {
    echo ">>> $1"
}

is_package_installed() {
    local pkg="$1"
    dpkg-query -W -f='${Status}' "$pkg" 2>/dev/null | grep -q "install ok installed"
}

ensure_package() {
    local pkg="$1"
    if is_package_installed "${pkg}"; then
        setup_log_skip "软件包 ${pkg} 已安装"
        return 0
    fi
    setup_log_do "安装 ${pkg} ..."
    apt-get install -y "${pkg}"
}

ensure_systemd_service() {
    local svc="$1"
    if ! systemctl is-enabled --quiet "${svc}" 2>/dev/null; then
        setup_log_do "设置 ${svc} 开机自启 ..."
        systemctl enable "${svc}"
    fi
    if systemctl is-active --quiet "${svc}"; then
        setup_log_skip "服务 ${svc} 已在运行"
    else
        setup_log_do "启动 ${svc} ..."
        systemctl start "${svc}"
    fi
}

run_apt_update() {
    setup_log_do "更新 apt 软件源索引 ..."
    apt-get update -y
}

run_apt_upgrade_if_needed() {
    if [[ "${FORCE_UPGRADE:-0}" == "1" ]]; then
        setup_log_do "执行系统升级 (FORCE_UPGRADE=1) ..."
        apt-get upgrade -y
        return 0
    fi
    if is_package_installed nginx && is_package_installed supervisor && is_package_installed redis-server; then
        setup_log_skip "核心软件已安装，跳过 apt upgrade（如需强制升级请设置 FORCE_UPGRADE=1）"
        return 0
    fi
    setup_log_do "执行系统升级 ..."
    apt-get upgrade -y
}

ensure_directory() {
    local dir="$1"
    local owner="${2:-}"
    if [[ -d "${dir}" ]]; then
        setup_log_skip "目录已存在: ${dir}"
    else
        setup_log_do "创建目录: ${dir} ..."
        mkdir -pv "${dir}"
    fi
    if [[ -n "${owner}" ]]; then
        local current_owner
        current_owner="$(stat -c '%U:%G' "${dir}" 2>/dev/null || echo "")"
        if [[ "${current_owner}" == "${owner}" ]]; then
            setup_log_skip "目录权限已是 ${owner}: ${dir}"
        else
            setup_log_do "设置目录权限 ${owner}: ${dir} ..."
            chown -R "${owner}" "${dir}"
        fi
    fi
}

configure_ssh_for_sftp() {
    local ssh_config="/etc/ssh/sshd_config"
    local changed=0

    if [[ ! -f "${ssh_config}.bak" ]]; then
        setup_log_do "备份 SSH 配置 ..."
        cp "${ssh_config}" "${ssh_config}.bak"
    else
        setup_log_skip "SSH 配置备份已存在: ${ssh_config}.bak"
    fi

    if grep -q "^PasswordAuthentication[[:space:]]*no" "${ssh_config}"; then
        setup_log_skip "SSH PasswordAuthentication 已是 no"
    else
        setup_log_do "设置 SSH PasswordAuthentication no ..."
        if grep -q "^PasswordAuthentication" "${ssh_config}"; then
            sed -i 's/^PasswordAuthentication.*/PasswordAuthentication no/' "${ssh_config}"
        else
            echo "PasswordAuthentication no" >> "${ssh_config}"
        fi
        changed=1
    fi

    if grep -q "PubkeyAcceptedAlgorithms +ssh-rsa" "${ssh_config}"; then
        setup_log_skip "SSH PubkeyAcceptedAlgorithms 已配置"
    else
        setup_log_do "添加 SSH PubkeyAcceptedAlgorithms +ssh-rsa ..."
        echo "PubkeyAcceptedAlgorithms +ssh-rsa" >> "${ssh_config}"
        changed=1
    fi

    if [[ "${changed}" -eq 1 ]]; then
        setup_log_do "重启 SSH 服务 ..."
        if systemctl list-units --type=service --all 2>/dev/null | grep -q '\bssh\.service\b'; then
            systemctl restart ssh
        else
            systemctl restart sshd
        fi
        echo "SSH 配置已更新并重启。"
    else
        setup_log_skip "SSH 配置无需变更，跳过重启"
    fi
}

# 从 stdin 读取内容，仅在与目标文件不同时写入；返回 0=有变更，1=无变更
write_file_if_changed() {
    local dest="$1"
    local tmp
    tmp="$(mktemp)"
    cat > "${tmp}"
    if [[ -f "${dest}" ]] && cmp -s "${tmp}" "${dest}"; then
        setup_log_skip "配置文件未变化: ${dest}"
        rm -f "${tmp}"
        return 1
    fi
    setup_log_do "写入配置文件: ${dest} ..."
    mv "${tmp}" "${dest}"
    return 0
}

ensure_nginx_site() {
    local conf_path="$1"
    local nginx_changed=0

    if write_file_if_changed "${conf_path}"; then
        nginx_changed=1
    fi

    if [[ -L /etc/nginx/sites-enabled/default || -f /etc/nginx/sites-enabled/default ]]; then
        setup_log_do "移除 Nginx 默认站点 ..."
        rm -f /etc/nginx/sites-enabled/default
        nginx_changed=1
    else
        setup_log_skip "Nginx 默认站点已移除"
    fi

    if [[ "${nginx_changed}" -eq 1 ]]; then
        nginx -t
        setup_log_do "重载 Nginx ..."
        systemctl reload nginx
    else
        setup_log_skip "Nginx 站点配置无需重载"
    fi
}

ensure_supervisor_program() {
    local conf_path="$1"
    local program_name="$2"
    local supervisor_changed=0

    if write_file_if_changed "${conf_path}"; then
        supervisor_changed=1
    fi

    if [[ "${supervisor_changed}" -eq 1 ]]; then
        supervisorctl reread
        supervisorctl update
    else
        setup_log_skip "Supervisor 配置无需更新"
    fi

    if supervisorctl status "${program_name}" >/dev/null 2>&1; then
        setup_log_skip "Supervisor 程序 ${program_name} 已注册"
    else
        supervisorctl status "${program_name}" || true
    fi
}

ensure_remote_script() {
    local url="$1"
    local dest="$2"
    local force="${FORCE:-0}"

    if [[ -f "${dest}" && "${force}" != "1" ]]; then
        setup_log_skip "脚本已存在: ${dest}（如需覆盖请设置 FORCE=1）"
        chmod +x "${dest}" 2>/dev/null || true
        return 0
    fi

    if ! command -v curl >/dev/null 2>&1; then
        echo "警告: 未找到 curl，请手动上传脚本到 ${dest}"
        return 1
    fi

    setup_log_do "下载脚本: ${dest} ..."
    curl -fsSL "${url}" -o "${dest}"
    chmod +x "${dest}"
}

load_setup_libs() {
    local script_dir="$1"

    JENSHOW_BASE_URL="${JENSHOW_BASE_URL:-https://raw.githubusercontent.com/showx/jenshow/master}"

    if [[ -f "${script_dir}/project_lib.sh" ]]; then
        # shellcheck source=project_lib.sh
        source "${script_dir}/project_lib.sh"
    else
        # shellcheck disable=SC1090
        source <(curl -fsSL "${JENSHOW_BASE_URL}/project_lib.sh")
    fi
}

load_setup_project_config() {
    local script_dir="$1"

    if [[ -f "${script_dir}/project.conf" ]]; then
        load_project_config "${script_dir}"
        return 0
    fi

    if [[ -n "${PROJECT_NAME:-}" && -n "${BACKEND_DIR:-}" && -n "${API_DOMAIN:-}" ]]; then
        return 0
    fi

    if [[ -n "${PROJECT_NAME:-}" ]]; then
        load_project_config_from_env
        return 0
    fi

    echo "错误: setup 需要项目配置"
    echo "  方式1: curl ... | sudo bash -s -- setup-init"
    echo "  方式2: 传环境变量 PROJECT_NAME=xxx API_DOMAIN=xxx ..."
    echo "  方式3: 在脚本目录放置 project.conf"
    exit 1
}

load_project_config_from_env() {
    JENSHOW_BASE_URL="${JENSHOW_BASE_URL:-https://raw.githubusercontent.com/showx/jenshow/master}"
    SERVER_USER="${SERVER_USER:-root}"
    API_DOMAIN="${API_DOMAIN:-your-api.example.com}"
    FRONTEND_ROUTE="${FRONTEND_ROUTE:-/adminxend}"
    BACKEND_PORT="${BACKEND_PORT:-8080}"
    BACKEND_DIR="${BACKEND_DIR:-${SERVER_BACKEND_SUBDIR:-backend}}"
    FRONTEND_DIR="${FRONTEND_DIR:-${SERVER_FRONTEND_SUBDIR:-frontend}}"
    FRONTEND_DIST="${FRONTEND_DIST:-dist}"
    APP_NAME="${PROJECT_NAME}-server"
    WEB_ROOT="/webwww/www/${PROJECT_NAME}"
    SERVER_BACKEND="${WEB_ROOT}/${BACKEND_DIR}"
    SERVER_FRONTEND="${WEB_ROOT}/${FRONTEND_DIR}"
    SERVER_FRONTEND_DIST="${SERVER_FRONTEND}/${FRONTEND_DIST}"
    SUPERVISOR_PROGRAM="${APP_NAME}"
    SUPERVISOR_CONF="/etc/supervisor/conf.d/${APP_NAME}.conf"
    NGINX_CONF="/etc/nginx/sites-enabled/${PROJECT_NAME}.conf"
}
