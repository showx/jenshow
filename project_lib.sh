#!/bin/bash
# 配置加载、路径推导、构建与模板生成

JENSHOW_BASE_URL="${JENSHOW_BASE_URL:-https://raw.githubusercontent.com/showx/jenshow/master}"

find_project_root() {
    local dir="$1"
    while [[ "${dir}" != "/" ]]; do
        [[ -f "${dir}/project.conf" ]] && { echo "${dir}"; return 0; }
        dir="$(dirname "${dir}")"
    done
    return 1
}

load_project_config() {
    local search_dir="${1:-.}"

    if [[ -f "${search_dir}/project.conf" ]]; then
        # shellcheck source=/dev/null
        source "${search_dir}/project.conf"
    else
        echo "错误: 找不到 ${search_dir}/project.conf"
        exit 1
    fi

    PROJECT_NAME="${PROJECT_NAME:?请在 project.conf 中设置 PROJECT_NAME}"
    JENSHOW_BASE_URL="${JENSHOW_BASE_URL:-https://raw.githubusercontent.com/showx/jenshow/master}"
    SERVER_USER="${SERVER_USER:-root}"
    SERVER_HOST="${SERVER_HOST:-}"
    API_DOMAIN="${API_DOMAIN:-your-api.example.com}"
    FRONTEND_ROUTE="${FRONTEND_ROUTE:-/adminxend}"
    BACKEND_PORT="${BACKEND_PORT:-8080}"

    BACKEND_SCRIPTS_DIR="${BACKEND_SCRIPTS_DIR:-backend}"
    FRONTEND_SCRIPTS_DIR="${FRONTEND_SCRIPTS_DIR:-frontend}"
    BACKEND_SRC_DIR="${BACKEND_SRC_DIR:-backend}"
    GO_BUILD_TARGET="${GO_BUILD_TARGET:-.}"
    FRONTEND_SRC_DIR="${FRONTEND_SRC_DIR:-frontend}"
    FRONTEND_BUILD_DIR="${FRONTEND_BUILD_DIR:-dist}"
    FRONTEND_BUILD_CMD="${FRONTEND_BUILD_CMD:-npm run build}"

    SERVER_BACKEND_SUBDIR="${SERVER_BACKEND_SUBDIR:-backend}"
    SERVER_FRONTEND_SUBDIR="${SERVER_FRONTEND_SUBDIR:-frontend}"
    SERVER_FRONTEND_DIST="${SERVER_FRONTEND_DIST:-dist}"

    GOOS="${GOOS:-linux}"
    GOARCH="${GOARCH:-amd64}"

    APP_NAME="${PROJECT_NAME}-server"
    WEB_ROOT="/webwww/www/${PROJECT_NAME}"
    BACKEND_DIR="${WEB_ROOT}/${SERVER_BACKEND_SUBDIR}"
    FRONTEND_DIR="${WEB_ROOT}/${SERVER_FRONTEND_SUBDIR}"
    FRONTEND_DIST="${FRONTEND_DIR}/${SERVER_FRONTEND_DIST}"
    REMOTE_PATH="${BACKEND_DIR}/"
    REMOTE_BASE_PATH="${FRONTEND_DIR}"
    REMOTE_DIST_PATH="${FRONTEND_DIST}"
    SUPERVISOR_PROGRAM="${APP_NAME}"
    SUPERVISOR_CONF="/etc/supervisor/conf.d/${APP_NAME}.conf"
    NGINX_CONF="/etc/nginx/sites-enabled/${PROJECT_NAME}.conf"
}

setup_deploy_context() {
    local script_dir="$1"

    PROJECT_ROOT="$(find_project_root "${script_dir}")" || {
        echo "错误: 从 ${script_dir} 向上找不到 project.conf"
        exit 1
    }

    load_project_config "${PROJECT_ROOT}"

    DEPLOY_SCRIPT_DIR="${script_dir}"
    BACKEND_SCRIPTS_ABS="${PROJECT_ROOT}/${BACKEND_SCRIPTS_DIR}"
    FRONTEND_SCRIPTS_ABS="${PROJECT_ROOT}/${FRONTEND_SCRIPTS_DIR}"
    BACKEND_SRC_ABS="${PROJECT_ROOT}/${BACKEND_SRC_DIR}"
    FRONTEND_SRC_ABS="${PROJECT_ROOT}/${FRONTEND_SRC_DIR}"
    FRONTEND_BUILD_ABS="${PROJECT_ROOT}/${FRONTEND_SRC_DIR}/${FRONTEND_BUILD_DIR}"
}

bootstrap_deploy() {
    local script_dir="$1"
    local root="${script_dir}"

    while [[ "${root}" != "/" ]]; do
        if [[ -f "${root}/project_lib.sh" ]]; then
            # shellcheck source=/dev/null
            source "${root}/project_lib.sh"
            setup_deploy_context "${script_dir}"
            return 0
        fi
        root="$(dirname "${root}")"
    done

    echo "❌ 找不到 project.conf / project_lib.sh"
    exit 1
}

require_server_host() {
    if [[ -z "${SERVER_HOST}" ]]; then
        echo "❌ 请在 project.conf 中设置 SERVER_HOST"
        exit 1
    fi
}

build_backend_binary() {
    local output_name="$1"
    local output_path="${BACKEND_SCRIPTS_ABS}/${output_name}"

    [[ -d "${BACKEND_SRC_ABS}" ]] || {
        echo "❌ Go 源码目录不存在: ${BACKEND_SRC_ABS}"
        return 1
    }

    echo ">>> 编译: ${BACKEND_SRC_ABS} (${GO_BUILD_TARGET})"
    echo ">>> 输出: ${output_path}"

    (
        cd "${BACKEND_SRC_ABS}"
        export GOOS GOARCH
        export CGO_ENABLED=0
        go build -o "${output_path}" "${GO_BUILD_TARGET}"
    )
}

upload_backend_binary() {
    local binary_name="$1"
    local binary_path="${BACKEND_SCRIPTS_ABS}/${binary_name}"

    echo ">>> 上传: ${SERVER_USER}@${SERVER_HOST}:${REMOTE_PATH}"
    scp "${binary_path}" "${SERVER_USER}@${SERVER_HOST}:${REMOTE_PATH}"
    ssh "${SERVER_USER}@${SERVER_HOST}" "chmod +x ${REMOTE_PATH}${binary_name}"
}

deploy_backend_remote() {
    local version="$1"
    ssh "${SERVER_USER}@${SERVER_HOST}" "cd ${REMOTE_PATH} && ./deploy.sh ${version}"
}

build_frontend_package() {
    local version="$1"
    local archive_name="dist_${version}.tar.gz"
    local archive_path="${FRONTEND_SCRIPTS_ABS}/${archive_name}"

    [[ -d "${FRONTEND_SRC_ABS}" ]] || {
        echo "❌ 前端工程目录不存在: ${FRONTEND_SRC_ABS}"
        return 1
    }

    echo ">>> 前端: ${FRONTEND_SRC_ABS}"
    echo ">>> 命令: ${FRONTEND_BUILD_CMD}"

    ( cd "${FRONTEND_SRC_ABS}" && eval "${FRONTEND_BUILD_CMD}" ) || return 1

    [[ -d "${FRONTEND_BUILD_ABS}" ]] || {
        echo "❌ 构建产物不存在: ${FRONTEND_BUILD_ABS}"
        return 1
    }

    tar -czf "${archive_path}" -C "${FRONTEND_BUILD_ABS}" .
    FRONTEND_ARCHIVE_PATH="${archive_path}"
    FRONTEND_ARCHIVE_NAME="${archive_name}"
}

render_supervisor_conf() {
    cat <<EOF
[program:${SUPERVISOR_PROGRAM}]
command=${BACKEND_DIR}/${APP_NAME}
directory=${BACKEND_DIR}
user=root
autostart=true
autorestart=true
startretries=3
stdout_logfile=/var/log/${APP_NAME}.out.log
stdout_logfile_maxbytes=50MB
stdout_logfile_backups=10
stderr_logfile=/var/log/${APP_NAME}.err.log
stderr_logfile_maxbytes=50MB
stderr_logfile_backups=10
stopsignal=TERM
stopasgroup=true
killasgroup=true
EOF
}

render_server_project_conf() {
    cat <<EOF
# 由 setup 同步到服务器，供 deploy.sh 使用
PROJECT_NAME="${PROJECT_NAME}"
APP_NAME="${APP_NAME}"
SUPERVISOR_PROGRAM="${SUPERVISOR_PROGRAM}"
SERVER_FRONTEND_DIST="${SERVER_FRONTEND_DIST}"
EOF
}

# ---------- 交互式配置（curl 管道时从 /dev/tty 读取） ----------

_wizard_input() {
    local __var="$1" __prompt="$2" __default="${3:-}"
    local __val="" __tty="/dev/tty"

    if [[ ! -r "${__tty}" ]]; then
        echo "错误: 需要交互终端。请改用: curl -fsSL ... -o install.sh && bash install.sh configure"
        exit 1
    fi

    if [[ -n "${__default}" ]]; then
        read -r -p "${__prompt} [${__default}]: " __val < "${__tty}"
        __val="${__val:-${__default}}"
    else
        while [[ -z "${__val}" ]]; do
            read -r -p "${__prompt}: " __val < "${__tty}"
            [[ -n "${__val}" ]] || echo "  此项不能为空"
        done
    fi
    printf -v "${__var}" '%s' "${__val}"
}

_wizard_confirm() {
    local __prompt="$1" __default="${2:-y}"
    local __val="" __tty="/dev/tty"
    read -r -p "${__prompt} [${__default}]: " __val < "${__tty}"
    __val="${__val:-${__default}}"
    [[ "${__val}" =~ ^[Yy] ]]
}

write_project_conf() {
    local dest="$1"
    cat > "${dest}" <<EOF
# 由 jenshow configure 生成 — $(date '+%Y-%m-%d %H:%M')
PROJECT_NAME="${PROJECT_NAME}"
SERVER_USER="${SERVER_USER}"
SERVER_HOST="${SERVER_HOST}"
API_DOMAIN="${API_DOMAIN}"
FRONTEND_ROUTE="${FRONTEND_ROUTE}"
BACKEND_PORT="${BACKEND_PORT}"

JENSHOW_BASE_URL="${JENSHOW_BASE_URL}"

BACKEND_SCRIPTS_DIR="${BACKEND_SCRIPTS_DIR}"
FRONTEND_SCRIPTS_DIR="${FRONTEND_SCRIPTS_DIR}"
BACKEND_SRC_DIR="${BACKEND_SRC_DIR}"
GO_BUILD_TARGET="${GO_BUILD_TARGET}"
FRONTEND_SRC_DIR="${FRONTEND_SRC_DIR}"
FRONTEND_BUILD_DIR="${FRONTEND_BUILD_DIR}"
FRONTEND_BUILD_CMD="${FRONTEND_BUILD_CMD}"

SERVER_BACKEND_SUBDIR="${SERVER_BACKEND_SUBDIR}"
SERVER_FRONTEND_SUBDIR="${SERVER_FRONTEND_SUBDIR}"
SERVER_FRONTEND_DIST="${SERVER_FRONTEND_DIST}"
EOF
}

export_project_env() {
    load_project_config "${1}"
    export PROJECT_NAME SERVER_USER SERVER_HOST API_DOMAIN
    export FRONTEND_ROUTE BACKEND_PORT JENSHOW_BASE_URL
    export BACKEND_SCRIPTS_DIR FRONTEND_SCRIPTS_DIR BACKEND_SRC_DIR GO_BUILD_TARGET
    export FRONTEND_SRC_DIR FRONTEND_BUILD_DIR FRONTEND_BUILD_CMD
    export SERVER_BACKEND_SUBDIR SERVER_FRONTEND_SUBDIR SERVER_FRONTEND_DIST
    export APP_NAME WEB_ROOT BACKEND_DIR FRONTEND_DIR FRONTEND_DIST
    export SUPERVISOR_PROGRAM SUPERVISOR_CONF NGINX_CONF REMOTE_PATH REMOTE_BASE_PATH
}

interactive_project_config() {
    local target_dir="${1:-.}"
    target_dir="$(mkdir -p "${target_dir}" && cd "${target_dir}" && pwd)"
    local conf_path="${target_dir}/project.conf"

    echo ""
    echo "=========================================="
    echo "  jenshow 交互式配置（共 3 步，回车使用默认值）"
    echo "  保存到: ${conf_path}"
    echo "=========================================="
    echo ""

    if [[ -f "${conf_path}" ]] && ! _wizard_confirm "已存在 project.conf，是否覆盖"; then
        echo "已取消，保留原配置"
        return 0
    fi

    echo ">>> [1/3] 项目标识"
    _wizard_input PROJECT_NAME "项目名 PROJECT_NAME（目录/服务名）" "myapp"
    _wizard_input API_DOMAIN "API 域名 server_name" "${PROJECT_NAME}.example.com"
    _wizard_input SERVER_HOST "发布用服务器 IP/域名（本机 setup 可留空）" ""
    _wizard_input SERVER_USER "SSH 用户" "root"

    echo ""
    echo ">>> [2/3] 运行参数"
    _wizard_input FRONTEND_ROUTE "前端 SPA 路由前缀" "/adminxend"
    _wizard_input BACKEND_PORT "后端端口" "8080"
    JENSHOW_BASE_URL="${JENSHOW_BASE_URL:-https://raw.githubusercontent.com/showx/jenshow/master}"

    echo ""
    if _wizard_confirm "是否配置目录布局（高级）" "n"; then
        echo ">>> [3/3] 目录布局"
        _wizard_input BACKEND_SCRIPTS_DIR "后端脚本目录" "backend"
        _wizard_input FRONTEND_SCRIPTS_DIR "前端脚本目录" "frontend"
        _wizard_input BACKEND_SRC_DIR "Go 源码目录" "backend"
        _wizard_input GO_BUILD_TARGET "go build 目标" "."
        _wizard_input FRONTEND_SRC_DIR "前端源码目录" "frontend"
        _wizard_input FRONTEND_BUILD_DIR "前端构建产物子目录" "dist"
        FRONTEND_BUILD_CMD="npm run build"
        _wizard_input SERVER_BACKEND_SUBDIR "服务器后端子目录" "backend"
        _wizard_input SERVER_FRONTEND_SUBDIR "服务器前端子目录" "frontend"
        _wizard_input SERVER_FRONTEND_DIST "服务器静态目录名" "dist"
    else
        echo ">>> [3/3] 使用默认目录布局"
        BACKEND_SCRIPTS_DIR="backend"
        FRONTEND_SCRIPTS_DIR="frontend"
        BACKEND_SRC_DIR="backend"
        GO_BUILD_TARGET="."
        FRONTEND_SRC_DIR="frontend"
        FRONTEND_BUILD_DIR="dist"
        FRONTEND_BUILD_CMD="npm run build"
        SERVER_BACKEND_SUBDIR="backend"
        SERVER_FRONTEND_SUBDIR="frontend"
        SERVER_FRONTEND_DIST="dist"
    fi

    APP_NAME="${PROJECT_NAME}-server"
    WEB_ROOT="/webwww/www/${PROJECT_NAME}"
    BACKEND_DIR="${WEB_ROOT}/${SERVER_BACKEND_SUBDIR}"
    FRONTEND_DIR="${WEB_ROOT}/${SERVER_FRONTEND_SUBDIR}"
    FRONTEND_DIST="${FRONTEND_DIR}/${SERVER_FRONTEND_DIST}"
    SUPERVISOR_PROGRAM="${APP_NAME}"

    echo ""
    echo "---------- 配置预览 ----------"
    echo "  项目名:     ${PROJECT_NAME}"
    echo "  服务名:     ${SUPERVISOR_PROGRAM}"
    echo "  域名:       ${API_DOMAIN}"
    echo "  服务器:     ${SERVER_USER}@${SERVER_HOST:-（未填）}"
    echo "  部署路径:   ${WEB_ROOT}"
    echo "  后端源码:   ${BACKEND_SRC_DIR} → ${GO_BUILD_TARGET}"
    echo "  前端源码:   ${FRONTEND_SRC_DIR}/${FRONTEND_BUILD_DIR}"
    echo "------------------------------"
    echo ""

    _wizard_confirm "确认写入 project.conf" "y" || {
        echo "已取消"
        return 1
    }

    write_project_conf "${conf_path}"
    echo "✅ 已保存: ${conf_path}"
}
