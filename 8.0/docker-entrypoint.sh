#!/bin/bash

# 容器入口脚本：填充配置与规则，再以 suricata 用户启动引擎。
set -euo pipefail

readonly CONFIG_DIR=/etc/suricata
readonly CONFIG_DIST_DIR=/etc/suricata.dist
readonly RULES_DIR=/usr/share/suricata/rules
readonly RULES_DIST_DIR=/usr/share/suricata/rules.dist
readonly STATE_DIR=/var/lib/suricata
readonly LOG_DIR=/var/log/suricata
readonly RUN_DIR=/var/run/suricata
readonly SURICATA_USER=suricata
readonly SURICATA_BIN=/usr/bin/suricata
readonly SURICATA_LOAD_RULES="${SURICATA_LOAD_RULES:-no}"
readonly SURICATA_NO_RULES_CONFIG="${CONFIG_DIST_DIR}/suricata-no-rules.yaml"

SURICATA_ARGS=()

log() {
    echo "$*"
}

warn() {
    echo "Warning: $*" >&2
}

# force=yes 时覆盖 dst；否则仅在 dst 不存在时复制。
copy_dist_file() {
    local src="$1"
    local dst="$2"
    local force="${3:-no}"
    local reason="${4:-}"

    mkdir -p "$(dirname "${dst}")"

    if [[ "${force}" = "yes" ]]; then
        if [[ -n "${reason}" ]]; then
            log "Refreshing ${dst} from image default (${reason})."
        else
            log "Refreshing ${dst} from image default."
        fi
        cp -af "${src}" "${dst}"
        return 0
    fi

    if [[ ! -e "${dst}" ]]; then
        log "Creating ${dst} from image default."
        cp -a "${src}" "${dst}"
    fi
}

# 按 PUID/PGID 调整 suricata 用户，并修正配置与数据目录属主。
fix_perms() {
    if [[ -n "${PGID:-}" ]]; then
        groupmod -o -g "${PGID}" "${SURICATA_USER}"
    fi

    if [[ -n "${PUID:-}" ]]; then
        usermod -o -u "${PUID}" "${SURICATA_USER}"
    fi

    chown -R "${SURICATA_USER}:${SURICATA_USER}" "${CONFIG_DIR}"
    chown -R "${SURICATA_USER}:${SURICATA_USER}" "${STATE_DIR}"
    chown -R "${SURICATA_USER}:${SURICATA_USER}" "${LOG_DIR}"
    chown -R "${SURICATA_USER}:${SURICATA_USER}" "${RUN_DIR}"
    chown -R "${SURICATA_USER}:${SURICATA_USER}" "${RULES_DIR}"
}

# 检查当前进程是否具备指定 Linux capability。
check_for_cap() {
    local cap="$1"

    printf "Checking for capability %s: " "${cap}"
    if getpcaps 0 2>&1 | grep -q "${cap}"; then
        echo "yes"
        return 0
    fi

    echo "no"
    return 1
}

# 默认不覆盖已有配置；SURICATA_USE_IMAGE_YAML=yes 时只覆盖 suricata.yaml。
copy_config_from_dist() {
    local dist_dir="${1:-${CONFIG_DIST_DIR}}"
    local config_dir="${2:-${CONFIG_DIR}}"
    local src filename dst force

    for src in "${dist_dir}"/*; do
        [[ -e "${src}" ]] || continue
        filename=$(basename "${src}")
        dst="${config_dir}/${filename}"
        force=no
        if [[ "${filename}" = "suricata.yaml" && "${SURICATA_USE_IMAGE_YAML:-no}" = "yes" ]]; then
            force=yes
        fi
        copy_dist_file "${src}" "${dst}" "${force}" "SURICATA_USE_IMAGE_YAML=yes"
    done
}

# 仅补缺失的规则文件，已有文件不覆盖。
copy_rules_from_dist() {
    local dist_dir="${1:-${RULES_DIST_DIR}}"
    local rules_dir="${2:-${RULES_DIR}}"
    local src filename dst

    [[ -d "${dist_dir}" ]] || return 0
    mkdir -p "${rules_dir}"

    for src in "${dist_dir}"/*; do
        [[ -e "${src}" ]] || continue
        filename=$(basename "${src}")
        dst="${rules_dir}/${filename}"
        copy_dist_file "${src}" "${dst}" "no"
    done
}

# SSH 白名单仅在缺失时从镜像复制，已有文件永不覆盖。
copy_ssh_allowlist_from_dist() {
    local dist_dir="${1:-${CONFIG_DIST_DIR}}"
    local config_dir="${2:-${CONFIG_DIR}}"
    local src="${dist_dir}/iprep/ssh-allow.list"
    local dst="${config_dir}/iprep/ssh-allow.list"

    [[ -f "${src}" ]] || return 0
    copy_dist_file "${src}" "${dst}" "no"
}

replace_config_arg() {
    local config_path="$1"
    shift
    local out=()
    local seen=no
    while (($#)); do
        if [[ "$1" = "-c" && $# -gt 1 ]]; then
            out+=(-c "${config_path}")
            shift 2
            seen=yes
            continue
        fi
        out+=("$1")
        shift
    done
    [[ "${seen}" = "yes" ]] || out+=(-c "${config_path}")
    printf '%s\0' "${out[@]}"
}

# 缺 sys_nice/net_admin 时以 root 运行；否则修正权限并以 suricata 用户启动。
prepare_run_user() {
    local run_as_user=yes

    SURICATA_ARGS=()

    if ! check_for_cap sys_nice; then
        warn "no sys_nice capability, use --cap-add sys_nice"
        run_as_user=no
    fi
    if ! check_for_cap net_admin; then
        warn "no net_admin capability, use --cap-add net_admin"
        run_as_user=no
    fi

    if [[ "${run_as_user}" != "yes" ]]; then
        warn "running as root due to missing capabilities"
        return 0
    fi

    fix_perms
    SURICATA_ARGS=(--user "${SURICATA_USER}" --group "${SURICATA_USER}")
}

main() {
    local suricata_config="${CONFIG_DIR}/suricata.yaml"
    local suricata_cmd=()

    copy_config_from_dist
    copy_ssh_allowlist_from_dist

    if [[ "${SURICATA_LOAD_RULES}" = "yes" ]]; then
        copy_rules_from_dist
    else
        suricata_config="${SURICATA_NO_RULES_CONFIG}"
    fi

    # Docker 惯例：首参不是 Suricata 选项时，执行该命令而不启动引擎。
    if [[ $# -gt 0 && "${1:0:1}" != "-" ]]; then
        exec "$@"
    fi

    prepare_run_user

    mapfile -d '' -t suricata_cmd < <(replace_config_arg "${suricata_config}" "$@")
    set -- "${suricata_cmd[@]}"

    if [[ "${ENABLE_CRON:-}" = "yes" ]]; then
        crond
    fi

    exec "${SURICATA_BIN}" "${SURICATA_ARGS[@]}" "$@"
}

main "$@"
