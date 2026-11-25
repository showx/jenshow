#!/bin/bash
# 回滚已发布版本。
# 本机执行：同步到服务器后远程回滚。
# 服务器执行：直接切换版本（setup 会把本脚本放到后端目录）。
#
#   ./rollback.sh                         后端回到上一版
#   ./rollback.sh 20260109_1200           后端切到指定版本
#   ./rollback.sh frontend                前端回到上一版
#   ./rollback.sh frontend 20260109_1200  前端解压指定归档
#   ./rollback.sh all                     后端、前端都回到上一版
#   ./rollback.sh --list                  查看可回滚版本

set -euo pipefail

_script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

usage() {
    cat <<'EOF'
用法: ./rollback.sh [backend|frontend|all] [版本号]
      ./rollback.sh --list [backend|frontend|all]

回滚已经发布的版本。不删除现有二进制和前端归档，可以再切回去。

  （无参数）                 后端回到上一版
  backend [版本号]           回滚后端；省略版本号则回到上一版
  frontend [版本号]          回滚前端；省略版本号则回到上一版
  all [版本号]               后端和前端一起回滚
  --list                     查看当前版本和可回滚版本

示例:
  ./rollback.sh
  ./rollback.sh 20260109_1200
  ./rollback.sh frontend
  ./rollback.sh all
  ./rollback.sh --list

后端：按二进制修改时间，切换到比当前更旧的最近一版，然后重启 Supervisor。
前端：按 dist_<版本号>.tar.gz 的修改时间回退；没有归档时与 dist_old 对调。
EOF
}

TARGET="backend"
ACTION="rollback"
VERSION=""
TARGET_EXPLICIT=0

parse_rollback_args() {
    local positional=()
    local arg
    TARGET="backend"
    ACTION="rollback"
    VERSION=""
    TARGET_EXPLICIT=0

    while [[ $# -gt 0 ]]; do
        arg="$1"
        case "${arg}" in
            -l|--list|list)
                ACTION="list"
                shift
                ;;
            backend|frontend|all)
                TARGET="${arg}"
                TARGET_EXPLICIT=1
                shift
                ;;
            --)
                shift
                positional+=("$@")
                break
                ;;
            -*)
                echo "未知参数: ${arg}"
                usage
                exit 1
                ;;
            *)
                positional+=("${arg}")
                shift
                ;;
        esac
    done

    if [[ ${#positional[@]} -gt 1 ]]; then
        echo "错误: 只能指定一个版本号"
        usage
        exit 1
    fi
    if [[ ${#positional[@]} -eq 1 ]]; then
        VERSION="${positional[0]}"
    fi
}

load_server_config() {
    local cli_project="${PROJECT_NAME:-}"
    local cli_app="${APP_NAME:-}"
    local cli_supervisor="${SUPERVISOR_PROGRAM:-}"
    local cli_frontend_dir="${FRONTEND_DIR:-}"
    local cli_frontend_dist="${FRONTEND_DIST:-}"
    local cli_server_frontend="${SERVER_FRONTEND:-}"
    local conf=""
    local root="${_script_dir}"

    if [[ -f "${_script_dir}/project.conf" ]]; then
        conf="${_script_dir}/project.conf"
    else
        while [[ "${root}" != "/" ]]; do
            if [[ -f "${root}/project.conf" ]]; then
                conf="${root}/project.conf"
                break
            fi
            root="$(dirname "${root}")"
        done
    fi

    if [[ -n "${conf}" ]]; then
        # shellcheck source=/dev/null
        source "${conf}"
    fi

    PROJECT_NAME="${cli_project:-${PROJECT_NAME:-}}"
    APP_NAME="${cli_app:-${APP_NAME:-}}"
    SUPERVISOR_PROGRAM="${cli_supervisor:-${SUPERVISOR_PROGRAM:-}}"
    FRONTEND_DIR="${cli_frontend_dir:-${FRONTEND_DIR:-frontend}}"
    FRONTEND_DIST="${cli_frontend_dist:-${FRONTEND_DIST:-dist}}"
    SERVER_FRONTEND="${cli_server_frontend:-${SERVER_FRONTEND:-}}"

    [[ -n "${PROJECT_NAME}" ]] || {
        echo "错误: 未设置 PROJECT_NAME（服务器 backend/project.conf 缺失）"
        exit 1
    }
    [[ -n "${APP_NAME}" ]] || APP_NAME="${PROJECT_NAME}-server"
    [[ -n "${SUPERVISOR_PROGRAM}" ]] || SUPERVISOR_PROGRAM="${APP_NAME}"
    if [[ -z "${SERVER_FRONTEND}" ]]; then
        SERVER_FRONTEND="$(cd "${_script_dir}/.." && pwd)/${FRONTEND_DIR}"
    fi
}

read_frontend_version() {
    local dir="$1"
    local file="${dir}/version.txt"
    local line
    [[ -f "${file}" ]] || return 1
    line="$(sed -n 's/^版本号:[[:space:]]*//p' "${file}")"
    [[ -n "${line}" ]] || return 1
    printf '%s\n' "${line%%$'\n'*}"
}

backend_file_path() {
    printf '%s\n' "${_script_dir}/${APP_NAME}${1}"
}

# 普通文件且非空才算“文件在”。空文件和断掉的软链都不能用来切换。
ensure_backend_file() {
    local ver="$1"
    local path
    path="$(backend_file_path "${ver}")"
    if [[ -f "${path}" && -s "${path}" ]]; then
        return 0
    fi
    if [[ -f "${path}" ]]; then
        echo "错误: 文件是空的，已取消切换: ${path}"
        exit 1
    fi
    echo "错误: 文件不存在，已取消切换: ${path}"
    exit 1
}

dir_has_entries() {
    local dir="$1" found
    [[ -d "${dir}" ]] || return 1
    found="$(find "${dir}" -mindepth 1 -print -quit 2>/dev/null || true)"
    [[ -n "${found}" ]]
}

ensure_frontend_archive() {
    local ver="$1"
    local archive="${SERVER_FRONTEND}/dist_${ver}.tar.gz"
    if [[ ! -e "${archive}" ]]; then
        echo "错误: 前端归档不存在，已取消切换: ${archive}"
        exit 1
    fi
    if [[ ! -f "${archive}" || ! -s "${archive}" ]]; then
        echo "错误: 前端归档是空文件，已取消切换: ${archive}"
        exit 1
    fi
}

ensure_frontend_old_dir() {
    local old="${SERVER_FRONTEND}/${FRONTEND_DIST}_old"
    if [[ ! -d "${old}" ]] || ! dir_has_entries "${old}"; then
        echo "错误: 上一版前端目录不存在或没有文件，已取消切换: ${old}"
        exit 1
    fi
}

collect_backend_versions() {
    BACKEND_VERSIONS=()
    CURRENT_BACKEND_VER=""
    CURRENT_BACKEND_LINK_VER=""
    local line file ver link target_path

    link="${_script_dir}/${APP_NAME}"
    if [[ -L "${link}" ]]; then
        file="$(readlink "${link}")"
        file="${file##*/}"
        ver="${file#"${APP_NAME}"}"
        if [[ -n "${ver}" && "${ver}" != "${file}" ]]; then
            target_path="${_script_dir}/${file}"
            if [[ -f "${target_path}" && -s "${target_path}" ]]; then
                CURRENT_BACKEND_VER="${ver}"
            else
                CURRENT_BACKEND_LINK_VER="${ver}"
            fi
        fi
    fi

    while IFS= read -r line; do
        [[ -n "${line}" ]] || continue
        file="${line#*$'\t'}"
        ver="${file#"${APP_NAME}"}"
        [[ -n "${ver}" && "${ver}" != "${file}" ]] || continue
        [[ -f "${_script_dir}/${file}" && -s "${_script_dir}/${file}" ]] || continue
        BACKEND_VERSIONS+=("${ver}")
    done < <(find "${_script_dir}" -maxdepth 1 -type f -name "${APP_NAME}*" -printf '%T@\t%f\n' | sort -nr)
}

collect_frontend_versions() {
    FRONTEND_ARCHIVES=()
    CURRENT_FRONTEND_VER=""
    FRONTEND_OLD_VER=""
    local dist old line file ver

    dist="${SERVER_FRONTEND}/${FRONTEND_DIST}"
    old="${dist}_old"
    CURRENT_FRONTEND_VER="$(read_frontend_version "${dist}" || true)"
    if [[ -d "${old}" ]]; then
        FRONTEND_OLD_VER="$(read_frontend_version "${old}" || true)"
    fi

    [[ -d "${SERVER_FRONTEND}" ]] || return 0

    while IFS= read -r line; do
        [[ -n "${line}" ]] || continue
        file="${line#*$'\t'}"
        ver="${file#dist_}"
        ver="${ver%.tar.gz}"
        [[ -n "${ver}" && "${ver}" != "${file}" ]] || continue
        [[ -f "${SERVER_FRONTEND}/${file}" && -s "${SERVER_FRONTEND}/${file}" ]] || continue
        FRONTEND_ARCHIVES+=("${ver}")
    done < <(find "${SERVER_FRONTEND}" -maxdepth 1 -type f -name 'dist_*.tar.gz' -printf '%T@\t%f\n' | sort -nr)
}

# 比当前更旧的最近一版。成功时向 stdout 打印版本号。
previous_backend_version() {
    local i
    if [[ ${#BACKEND_VERSIONS[@]} -eq 0 ]]; then
        echo "错误: 服务器上没有后端二进制，无法回滚" >&2
        return 1
    fi
    if [[ -z "${CURRENT_BACKEND_VER}" ]]; then
        echo "${BACKEND_VERSIONS[0]}"
        return 0
    fi
    for i in "${!BACKEND_VERSIONS[@]}"; do
        if [[ "${BACKEND_VERSIONS[$i]}" == "${CURRENT_BACKEND_VER}" ]]; then
            if [[ $((i + 1)) -lt ${#BACKEND_VERSIONS[@]} ]]; then
                echo "${BACKEND_VERSIONS[$((i + 1))]}"
                return 0
            fi
            echo "错误: 后端当前已是最旧版本 ${CURRENT_BACKEND_VER}，没有更早的二进制" >&2
            return 1
        fi
    done
    echo "${BACKEND_VERSIONS[0]}"
}

# 打印 swap，或 archive <版本号>
previous_frontend_action() {
    local dist="${SERVER_FRONTEND}/${FRONTEND_DIST}"
    local old="${dist}_old"
    local i

    if [[ -n "${CURRENT_FRONTEND_VER}" && ${#FRONTEND_ARCHIVES[@]} -gt 0 ]]; then
        for i in "${!FRONTEND_ARCHIVES[@]}"; do
            if [[ "${FRONTEND_ARCHIVES[$i]}" == "${CURRENT_FRONTEND_VER}" ]]; then
                if [[ $((i + 1)) -lt ${#FRONTEND_ARCHIVES[@]} ]]; then
                    echo "archive ${FRONTEND_ARCHIVES[$((i + 1))]}"
                    return 0
                fi
                echo "错误: 前端当前已是最旧归档 ${CURRENT_FRONTEND_VER}" >&2
                return 1
            fi
        done
    fi

    if dir_has_entries "${old}"; then
        echo "swap"
        return 0
    fi

    if [[ -d "${old}" ]]; then
        echo "错误: 上一版前端目录没有文件，已取消切换: ${old}" >&2
        return 1
    fi

    if [[ ! -d "${SERVER_FRONTEND}" ]]; then
        echo "错误: 前端目录不存在: ${SERVER_FRONTEND}" >&2
        return 1
    fi
    echo "错误: 没有可回滚的前端（缺少更旧的 dist_*.tar.gz，也没有 ${FRONTEND_DIST}_old）" >&2
    return 1
}

print_backend_status() {
    local ver mark
    echo "========== 后端 ${APP_NAME} =========="
    if [[ -n "${CURRENT_BACKEND_VER}" ]]; then
        echo "当前版本: ${CURRENT_BACKEND_VER}"
    elif [[ -n "${CURRENT_BACKEND_LINK_VER:-}" ]]; then
        echo "当前软链: ${CURRENT_BACKEND_LINK_VER}（文件不存在，不能切换到该版本）"
    else
        echo "当前版本: （软链 ${APP_NAME} 不存在或无效）"
    fi
    if [[ ${#BACKEND_VERSIONS[@]} -eq 0 ]]; then
        echo "可用二进制: （无）"
        return 0
    fi
    echo "可用版本（新 → 旧）:"
    for ver in "${BACKEND_VERSIONS[@]}"; do
        mark=""
        [[ "${ver}" == "${CURRENT_BACKEND_VER}" ]] && mark="  ← 当前"
        echo "  ${ver}${mark}"
    done
}

print_frontend_status() {
    local dist="${SERVER_FRONTEND}/${FRONTEND_DIST}"
    local ver mark
    echo "========== 前端 ${dist} =========="
    if [[ -n "${CURRENT_FRONTEND_VER}" ]]; then
        echo "当前版本: ${CURRENT_FRONTEND_VER}"
    elif [[ -d "${dist}" ]]; then
        echo "当前版本: （目录在，但没有 version.txt）"
    else
        echo "当前版本: （目录不存在）"
    fi
    if [[ -d "${dist}_old" ]]; then
        if [[ -n "${FRONTEND_OLD_VER}" ]]; then
            echo "上一份目录: ${FRONTEND_DIST}_old（${FRONTEND_OLD_VER}）"
        else
            echo "上一份目录: ${FRONTEND_DIST}_old"
        fi
    else
        echo "上一份目录: （无 ${FRONTEND_DIST}_old）"
    fi
    if [[ ${#FRONTEND_ARCHIVES[@]} -eq 0 ]]; then
        echo "归档: （无 dist_*.tar.gz）"
        return 0
    fi
    echo "归档（新 → 旧）:"
    for ver in "${FRONTEND_ARCHIVES[@]}"; do
        mark=""
        [[ "${ver}" == "${CURRENT_FRONTEND_VER}" ]] && mark="  ← 当前"
        echo "  ${ver}${mark}"
    done
}

print_status() {
    local show_backend=0 show_frontend=0
    if [[ "${ACTION}" == "list" && "${TARGET_EXPLICIT}" -eq 0 ]]; then
        show_backend=1
        show_frontend=1
    elif [[ "${TARGET}" == "all" ]]; then
        show_backend=1
        show_frontend=1
    elif [[ "${TARGET}" == "frontend" ]]; then
        show_frontend=1
    else
        show_backend=1
    fi

    if [[ "${show_backend}" -eq 1 ]]; then
        print_backend_status
    fi
    if [[ "${show_frontend}" -eq 1 ]]; then
        [[ "${show_backend}" -eq 1 ]] && echo ""
        print_frontend_status
    fi
}

rollback_frontend_swap() {
    local dist="${SERVER_FRONTEND}/${FRONTEND_DIST}"
    local old="${dist}_old"
    local tmp="${dist}_rollback_tmp"
    local ver

    ensure_frontend_old_dir

    rm -rf "${tmp}"
    if [[ -d "${dist}" ]]; then
        mv "${dist}" "${tmp}"
    fi
    mv "${old}" "${dist}"
    if [[ -d "${tmp}" ]]; then
        mv "${tmp}" "${old}"
    fi

    ver="$(read_frontend_version "${dist}" || true)"
    if [[ -n "${ver}" ]]; then
        echo "✅ 前端已与 ${FRONTEND_DIST}_old 对调，当前版本 ${ver}"
    else
        echo "✅ 前端已与 ${FRONTEND_DIST}_old 对调"
    fi
}

rollback_frontend_archive() {
    local ver="$1"
    local archive="${SERVER_FRONTEND}/dist_${ver}.tar.gz"
    local dist="${SERVER_FRONTEND}/${FRONTEND_DIST}"
    local old="${dist}_old"
    local tmp

    ensure_frontend_archive "${ver}"

    tmp="$(mktemp -d "${SERVER_FRONTEND}/.rollback_XXXXXX")"
    if ! tar -xzf "${archive}" -C "${tmp}"; then
        rm -rf "${tmp}"
        echo "错误: 解压失败，已取消切换: ${archive}"
        exit 1
    fi
    if ! dir_has_entries "${tmp}"; then
        rm -rf "${tmp}"
        echo "错误: 归档内没有文件，已取消切换: ${archive}"
        exit 1
    fi

    {
        echo "部署时间: $(date)"
        echo "项目: ${PROJECT_NAME}"
        echo "版本号: ${ver}"
        echo "说明: rollback"
    } > "${tmp}/version.txt"

    rm -rf "${old}"
    if [[ -d "${dist}" ]]; then
        mv "${dist}" "${old}"
    fi
    if ! mv "${tmp}" "${dist}"; then
        if [[ -d "${old}" ]]; then
            mv "${old}" "${dist}"
        fi
        rm -rf "${tmp}"
        echo "错误: 无法把解压结果移动到 ${dist}"
        exit 1
    fi
    echo "✅ 前端已回滚到 ${ver}"
}

run_server() {
    local need_backend=0 need_frontend=0
    local backend_to="" frontend_kind="" frontend_to=""
    local resolved

    parse_rollback_args "$@"
    load_server_config
    collect_backend_versions
    collect_frontend_versions

    if [[ "${ACTION}" == "list" ]]; then
        print_status
        exit 0
    fi

    if [[ "${TARGET}" == "backend" || "${TARGET}" == "all" ]]; then
        need_backend=1
    fi
    if [[ "${TARGET}" == "frontend" || "${TARGET}" == "all" ]]; then
        need_frontend=1
    fi

    if [[ "${need_backend}" -eq 1 ]]; then
        if [[ -n "${VERSION}" ]]; then
            ensure_backend_file "${VERSION}"
            if [[ "${VERSION}" == "${CURRENT_BACKEND_VER}" ]]; then
                echo "后端已是 ${VERSION}，跳过"
            else
                backend_to="${VERSION}"
            fi
        else
            if ! backend_to="$(previous_backend_version)"; then
                exit 1
            fi
        fi
    fi

    if [[ "${need_frontend}" -eq 1 ]]; then
        if [[ -n "${VERSION}" ]]; then
            ensure_frontend_archive "${VERSION}"
            if [[ "${VERSION}" == "${CURRENT_FRONTEND_VER}" ]] && dir_has_entries "${SERVER_FRONTEND}/${FRONTEND_DIST}"; then
                echo "前端已是 ${VERSION}，跳过"
            else
                frontend_kind="archive"
                frontend_to="${VERSION}"
            fi
        else
            if ! resolved="$(previous_frontend_action)"; then
                exit 1
            fi
            frontend_kind="${resolved%% *}"
            frontend_to="${resolved#"${frontend_kind}"}"
            frontend_to="${frontend_to# }"
        fi
    fi

    if [[ -z "${backend_to}" && -z "${frontend_kind}" ]]; then
        echo "无需回滚"
        exit 0
    fi

    # 真正切换前再查一次。文件在收集版本之后被删掉时，也不能改软链或前端目录。
    if [[ -n "${backend_to}" ]]; then
        ensure_backend_file "${backend_to}"
    fi
    if [[ "${frontend_kind}" == "swap" ]]; then
        ensure_frontend_old_dir
    elif [[ "${frontend_kind}" == "archive" ]]; then
        ensure_frontend_archive "${frontend_to}"
    fi

    echo ">>> 将回滚 ${PROJECT_NAME}:"
    if [[ -n "${backend_to}" ]]; then
        echo "    后端 ${CURRENT_BACKEND_VER:-（无）} → ${backend_to}"
    fi
    if [[ "${frontend_kind}" == "swap" ]]; then
        echo "    前端 与 ${FRONTEND_DIST}_old 对调"
    elif [[ "${frontend_kind}" == "archive" ]]; then
        echo "    前端 ${CURRENT_FRONTEND_VER:-（无）} → ${frontend_to}"
    fi

    if [[ -n "${backend_to}" ]]; then
        if [[ ! -f "${_script_dir}/deploy.sh" ]]; then
            echo "错误: 找不到 ${_script_dir}/deploy.sh"
            exit 1
        fi
        if [[ -x "${_script_dir}/deploy.sh" ]]; then
            "${_script_dir}/deploy.sh" "${backend_to}"
        else
            bash "${_script_dir}/deploy.sh" "${backend_to}"
        fi
        echo "✅ 后端已回滚到 ${backend_to}"
    fi

    if [[ "${frontend_kind}" == "swap" ]]; then
        rollback_frontend_swap
    elif [[ "${frontend_kind}" == "archive" ]]; then
        rollback_frontend_archive "${frontend_to}"
    fi
}

run_local() {
    local root="${_script_dir}"
    local remote_dir qargs="" arg

    while [[ "${root}" != "/" ]]; do
        if [[ -f "${root}/project_lib.sh" ]]; then
            # shellcheck source=/dev/null
            source "${root}/project_lib.sh"
            break
        fi
        root="$(dirname "${root}")"
    done

    bootstrap_deploy "${_script_dir}"
    require_server_host

    remote_dir="${REMOTE_PATH%/}"
    echo ">>> 同步 rollback.sh → ${SERVER_USER}@${SERVER_HOST}:${remote_dir}/rollback.sh"
    scp "${_script_dir}/rollback.sh" "${SERVER_USER}@${SERVER_HOST}:${remote_dir}/rollback.sh"
    ssh "${SERVER_USER}@${SERVER_HOST}" "chmod +x $(printf '%q' "${remote_dir}/rollback.sh")"

    for arg in "$@"; do
        qargs+=" $(printf '%q' "${arg}")"
    done

    # 远程固定走服务器逻辑，避免服务器上如果也有 project_lib.sh 时再 SSH 一次
    ssh "${SERVER_USER}@${SERVER_HOST}" \
        "cd $(printf '%q' "${remote_dir}") && \
         SERVER_FRONTEND=$(printf '%q' "${SERVER_FRONTEND}") \
         FRONTEND_DIR=$(printf '%q' "${FRONTEND_DIR}") \
         FRONTEND_DIST=$(printf '%q' "${FRONTEND_DIST}") \
         APP_NAME=$(printf '%q' "${APP_NAME}") \
         PROJECT_NAME=$(printf '%q' "${PROJECT_NAME}") \
         SUPERVISOR_PROGRAM=$(printf '%q' "${SUPERVISOR_PROGRAM}") \
         JENSHOW_ROLLBACK_MODE=server \
         ./rollback.sh${qargs}"
}

rollback_main() {
    local _arg _lib_root _found_lib

    for _arg in "$@"; do
        case "${_arg}" in
            -h|--help|help)
                usage
                exit 0
                ;;
        esac
    done

    _lib_root="${_script_dir}"
    _found_lib=0
    if [[ "${JENSHOW_ROLLBACK_MODE:-}" != "server" ]]; then
        while [[ "${_lib_root}" != "/" ]]; do
            if [[ -f "${_lib_root}/project_lib.sh" ]]; then
                _found_lib=1
                break
            fi
            _lib_root="$(dirname "${_lib_root}")"
        done
    fi

    if [[ "${_found_lib}" -eq 1 ]]; then
        run_local "$@"
    else
        run_server "$@"
    fi
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    rollback_main "$@"
fi
