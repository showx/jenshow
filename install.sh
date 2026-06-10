#!/bin/bash
#
# jenshow 一键安装入口
# 仓库: https://github.com/showx/jenshow
#
# 交互式（推荐）:
#   curl -fsSL https://raw.githubusercontent.com/showx/jenshow/master/install.sh | bash -s -- init
#   curl -fsSL https://raw.githubusercontent.com/showx/jenshow/master/install.sh | sudo bash -s -- setup-init
#
# 非交互:
#   curl -fsSL .../install.sh | sudo bash -s -- setup
#   curl -fsSL .../install.sh | bash -s -- deploy-scripts

set -euo pipefail

JENSHOW_BASE_URL="${JENSHOW_BASE_URL:-https://raw.githubusercontent.com/showx/jenshow/master}"
JENSHOW_INSTALL_URL="${JENSHOW_BASE_URL}/install.sh"

usage() {
    cat <<EOF
用法: install.sh <命令> [目录]

命令:
  configure          交互式生成 project.conf（分 3 步）
  init [目录]        交互式配置 + 下载发布脚本（本机推荐）
  setup-init [目录]  交互式配置 + 服务器环境搭建（需 root）
  setup              服务器完整搭建（需已有配置或环境变量）
  setup-common       仅安装基础软件
  deploy-scripts     下载发布脚本（无交互，用模板）
  help               显示帮助

示例:
  curl -fsSL ${JENSHOW_INSTALL_URL} | bash -s -- init ./myproject
  curl -fsSL ${JENSHOW_INSTALL_URL} | sudo bash -s -- setup-init
  curl -fsSL ${JENSHOW_INSTALL_URL} | bash -s -- configure
EOF
}

fetch() {
    curl -fsSL "${JENSHOW_BASE_URL}/$1"
}

load_fetched_project_lib() {
    local dir="$1"
    mkdir -p "${dir}"
    fetch "project_lib.sh" > "${dir}/.project_lib.sh"
    # shellcheck source=/dev/null
    source "${dir}/.project_lib.sh"
}

run_configure() {
    local target_dir="${1:-.}"
    load_fetched_project_lib "${target_dir}"
    interactive_project_config "${target_dir}"
}

run_setup() {
    [[ "${EUID:-$(id -u)}" -eq 0 ]] || {
        echo "错误: setup 需要 root"
        exit 1
    }
    echo ">>> 拉取 setup_server.sh ..."
    JENSHOW_BASE_URL="${JENSHOW_BASE_URL}" fetch "setup_server.sh" | JENSHOW_BASE_URL="${JENSHOW_BASE_URL}" bash
}

run_setup_common() {
    [[ "${EUID:-$(id -u)}" -eq 0 ]] || {
        echo "错误: setup-common 需要 root"
        exit 1
    }
    JENSHOW_BASE_URL="${JENSHOW_BASE_URL}" fetch "setup_server_common.sh" | JENSHOW_BASE_URL="${JENSHOW_BASE_URL}" bash
}

run_setup_init() {
    local target_dir="${1:-.}"
    [[ "${EUID:-$(id -u)}" -eq 0 ]] || {
        echo "错误: setup-init 需要 root"
        exit 1
    }
    run_configure "${target_dir}"
    target_dir="$(cd "${target_dir}" 2>/dev/null && pwd || pwd)"
    load_fetched_project_lib "${target_dir}"
    export_project_env "${target_dir}"
    echo ""
    echo ">>> 开始搭建服务器环境 ..."
    run_setup
}

run_init() {
    local target_dir="${1:-.}"
    run_configure "${target_dir}"
    echo ""
    run_deploy_scripts "${target_dir}"
}

run_deploy_scripts() {
    local target_dir="${1:-.}"
    local backend_dir frontend_dir

    target_dir="$(cd "${target_dir}" 2>/dev/null && pwd || { mkdir -p "${target_dir}" && cd "${target_dir}" && pwd; })"

    echo ">>> 下载到: ${target_dir}"
    echo ">>> 源: ${JENSHOW_BASE_URL}"

    if [[ ! -f "${target_dir}/project.conf" ]]; then
        fetch "project.conf.example" > "${target_dir}/project.conf"
        echo ">>> 已从模板生成 project.conf（建议运行 configure 交互配置）"
    else
        echo "⏭  保留已有 project.conf"
    fi

    fetch "project_lib.sh" > "${target_dir}/project_lib.sh"
    # shellcheck source=/dev/null
    source "${target_dir}/project_lib.sh"
    load_project_config "${target_dir}"

    backend_dir="${target_dir}/${BACKEND_SCRIPTS_DIR}"
    frontend_dir="${target_dir}/${FRONTEND_SCRIPTS_DIR}"
    mkdir -p "${backend_dir}" "${frontend_dir}"

    fetch "setup_lib.sh"           > "${target_dir}/setup_lib.sh"
    fetch "setup_server.sh"        > "${target_dir}/setup_server.sh"
    fetch "setup_server_common.sh" > "${target_dir}/setup_server_common.sh"
    fetch "install.sh"             > "${target_dir}/install.sh"
    fetch "backend/publish.sh"             > "${backend_dir}/publish.sh"
    fetch "backend/build_and_upload.sh"    > "${backend_dir}/build_and_upload.sh"
    fetch "backend/build_upload_deploy.sh" > "${backend_dir}/build_upload_deploy.sh"
    fetch "backend/deploy.sh"              > "${backend_dir}/deploy.sh"
    fetch "frontend/build_and_upload.sh"   > "${frontend_dir}/build_and_upload.sh"
    fetch "project.conf.example"           > "${target_dir}/project.conf.example"

    chmod +x \
        "${target_dir}/install.sh" \
        "${target_dir}/setup_server.sh" \
        "${target_dir}/setup_server_common.sh" \
        "${backend_dir}/publish.sh" \
        "${backend_dir}/build_and_upload.sh" \
        "${backend_dir}/build_upload_deploy.sh" \
        "${backend_dir}/deploy.sh" \
        "${frontend_dir}/build_and_upload.sh"

    cat <<EOF

✅ 已就绪
   ${target_dir}/project.conf
   ${backend_dir}/publish.sh
   ${frontend_dir}/build_and_upload.sh
EOF
}

CMD="${1:-help}"
shift || true

case "${CMD}" in
    configure) run_configure "${1:-.}" ;;
    init) run_init "${1:-.}" ;;
    setup-init) run_setup_init "${1:-.}" ;;
    setup) run_setup ;;
    setup-common) run_setup_common ;;
    deploy-scripts) run_deploy_scripts "${1:-.}" ;;
    help|-h|--help) usage ;;
    *) echo "未知命令: ${CMD}"; usage; exit 1 ;;
esac
