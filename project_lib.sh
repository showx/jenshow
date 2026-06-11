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

    BACKEND_DIR="${BACKEND_DIR:-${BACKEND_SCRIPTS_DIR:-${BACKEND_SRC_DIR:-${SERVER_BACKEND_SUBDIR:-backend}}}}"
    FRONTEND_DIR="${FRONTEND_DIR:-${FRONTEND_SCRIPTS_DIR:-${FRONTEND_SRC_DIR:-${SERVER_FRONTEND_SUBDIR:-frontend}}}}"
    FRONTEND_DIST="${FRONTEND_DIST:-${FRONTEND_BUILD_DIR:-${SERVER_FRONTEND_DIST:-dist}}}"
    GO_BUILD_TARGET="${GO_BUILD_TARGET:-.}"
    FRONTEND_BUILD_CMD="${FRONTEND_BUILD_CMD:-npm run build}"

    GOOS="${GOOS:-linux}"
    GOARCH="${GOARCH:-amd64}"

    APP_NAME="${PROJECT_NAME}-server"
    WEB_ROOT="/webwww/www/${PROJECT_NAME}"
    SERVER_BACKEND="${WEB_ROOT}/${BACKEND_DIR}"
    SERVER_FRONTEND="${WEB_ROOT}/${FRONTEND_DIR}"
    SERVER_FRONTEND_DIST="${SERVER_FRONTEND}/${FRONTEND_DIST}"
    REMOTE_PATH="${SERVER_BACKEND}/"
    REMOTE_BASE_PATH="${SERVER_FRONTEND}"
    REMOTE_DIST_PATH="${SERVER_FRONTEND_DIST}"
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
    BACKEND_ABS="${PROJECT_ROOT}/${BACKEND_DIR}"
    FRONTEND_ABS="${PROJECT_ROOT}/${FRONTEND_DIR}"
    FRONTEND_BUILD_ABS="${PROJECT_ROOT}/${FRONTEND_DIR}/${FRONTEND_DIST}"
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

ensure_remote_directory() {
    local remote_dir="${1%/}"
    [[ -n "${remote_dir}" ]] || return 1

    echo ">>> 检查远程目录: ${SERVER_USER}@${SERVER_HOST}:${remote_dir}"
    ssh "${SERVER_USER}@${SERVER_HOST}" \
        "if [ ! -d '${remote_dir}' ]; then mkdir -p '${remote_dir}'; fi"
}

build_backend_binary() {
    local output_name="$1"
    local output_path="${BACKEND_ABS}/${output_name}"

    [[ -d "${BACKEND_ABS}" ]] || {
        echo "❌ 后端目录不存在: ${BACKEND_ABS}"
        return 1
    }

    echo ">>> 编译: ${BACKEND_ABS} (${GO_BUILD_TARGET})"
    echo ">>> 输出: ${output_path}"

    (
        cd "${BACKEND_ABS}"
        export GOOS GOARCH
        export CGO_ENABLED=0
        go build -o "${output_path}" "${GO_BUILD_TARGET}"
    )
}

upload_backend_binary() {
    local binary_name="$1"
    local binary_path="${BACKEND_ABS}/${binary_name}"

    ensure_remote_directory "${REMOTE_PATH}"

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
    local archive_path="${FRONTEND_ABS}/${archive_name}"

    [[ -d "${FRONTEND_ABS}" ]] || {
        echo "❌ 前端目录不存在: ${FRONTEND_ABS}"
        return 1
    }

    echo ">>> 前端: ${FRONTEND_ABS}"
    echo ">>> 命令: ${FRONTEND_BUILD_CMD}"

    ( cd "${FRONTEND_ABS}" && eval "${FRONTEND_BUILD_CMD}" ) || return 1

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
command=${SERVER_BACKEND}/${APP_NAME}
directory=${SERVER_BACKEND}
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
FRONTEND_DIST="${FRONTEND_DIST}"
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

BACKEND_DIR="${BACKEND_DIR}"
FRONTEND_DIR="${FRONTEND_DIR}"
FRONTEND_DIST="${FRONTEND_DIST}"
GO_BUILD_TARGET="${GO_BUILD_TARGET}"
FRONTEND_BUILD_CMD="${FRONTEND_BUILD_CMD}"
EOF
}

export_project_env() {
    load_project_config "${1}"
    export PROJECT_NAME SERVER_USER SERVER_HOST API_DOMAIN
    export FRONTEND_ROUTE BACKEND_PORT JENSHOW_BASE_URL
    export BACKEND_DIR FRONTEND_DIR FRONTEND_DIST GO_BUILD_TARGET FRONTEND_BUILD_CMD
    export APP_NAME WEB_ROOT SERVER_BACKEND SERVER_FRONTEND SERVER_FRONTEND_DIST
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
        _wizard_input BACKEND_DIR "后端目录（脚本+源码+部署）" "backend"
        _wizard_input FRONTEND_DIR "前端目录（脚本+源码+部署）" "frontend"
        _wizard_input FRONTEND_DIST "前端构建产物子目录" "dist"
        _wizard_input GO_BUILD_TARGET "go build 目标" "."
        FRONTEND_BUILD_CMD="npm run build"
    else
        echo ">>> [3/3] 使用默认目录布局"
        BACKEND_DIR="backend"
        FRONTEND_DIR="frontend"
        FRONTEND_DIST="dist"
        GO_BUILD_TARGET="."
        FRONTEND_BUILD_CMD="npm run build"
    fi

    APP_NAME="${PROJECT_NAME}-server"
    WEB_ROOT="/webwww/www/${PROJECT_NAME}"
    SERVER_BACKEND="${WEB_ROOT}/${BACKEND_DIR}"
    SERVER_FRONTEND="${WEB_ROOT}/${FRONTEND_DIR}"
    SERVER_FRONTEND_DIST="${SERVER_FRONTEND}/${FRONTEND_DIST}"
    SUPERVISOR_PROGRAM="${APP_NAME}"

    echo ""
    echo "---------- 配置预览 ----------"
    echo "  项目名:     ${PROJECT_NAME}"
    echo "  服务名:     ${SUPERVISOR_PROGRAM}"
    echo "  域名:       ${API_DOMAIN}"
    echo "  服务器:     ${SERVER_USER}@${SERVER_HOST:-（未填）}"
    echo "  部署路径:   ${WEB_ROOT}"
    echo "  后端目录:   ${BACKEND_DIR} → ${GO_BUILD_TARGET}"
    echo "  前端目录:   ${FRONTEND_DIR}/${FRONTEND_DIST}"
    echo "------------------------------"
    echo ""

    _wizard_confirm "确认写入 project.conf" "y" || {
        echo "已取消"
        return 1
    }

    write_project_conf "${conf_path}"
    echo "✅ 已保存: ${conf_path}"
}
