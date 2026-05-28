#! /bin/bash

# 容器入口脚本，初始化配置和目录权限，再以suricat用户启动
set -e

fix_perms() {
    if [[ "${PGID}" ]]; then
        groupmod -o -g "${PGID}" suricata
    fi

    if [[ "${PUID}" ]]; then
        usermod -o -u "${PUID}" suricata
    fi

    chown -R suricata:suricata /etc/suricata
    chown -R suricata:suricata /var/lib/suricata
    chown -R suricata:suricata /var/log/suricata
    chown -R suricata:suricata /var/run/suricata
}

# 配置目录策略（与 run-suricata-docker.sh 挂载 /etc/suricata-docker 配合）：
# - SURICATA_USE_IMAGE_YAML=no（默认）：保留宿主机已有文件；仅缺失时从 /etc/suricata.dist 复制。
#   在宿主机改 /etc/suricata-docker/suricata.yaml 后 docker restart 即可加载新配置。
# - SURICATA_USE_IMAGE_YAML=yes：每次启动用镜像内 suricata.dist 覆盖 suricata.yaml（宿主机手改会被冲掉）。
seed_config_from_dist() {
    local src dst filename

    for src in /etc/suricata.dist/*; do
        [[ -e "${src}" ]] || continue
        filename=$(basename "${src}")
        dst="/etc/suricata/${filename}"

        if [[ "${filename}" = "suricata.yaml" && "${SURICATA_USE_IMAGE_YAML:-no}" = "yes" ]]; then
            echo "Refreshing ${dst} from image default (SURICATA_USE_IMAGE_YAML=yes)."
            cp -af "${src}" "${dst}"
            continue
        fi

        if ! test -e "${dst}"; then
            echo "Creating ${dst} from image default."
            cp -a "${src}" "${dst}"
        fi
    done
}

seed_config_from_dist

# If the first command does not look like argument, assume its a
# command the user wants to run. Normally I wouldn't do this.
if [[ $# -gt 0 && "${1:0:1}" != "-" ]]; then
    exec "$@"
fi

run_as_user="yes"

check_for_cap() {
    echo -n "Checking for capability $1: "
    if getpcaps 0 2>&1 | grep -q "$1"; then
        echo "yes"
        return 0
    else
        echo "no"
        return 1
    fi
}

if ! check_for_cap sys_nice; then
    echo "Warning: no sys_nice capability, use --cap-add sys_nice"
    run_as_user="no"
fi
if ! check_for_cap net_admin; then
    echo "Warning: no net_admin capability, use --cap-add net_admin"
    run_as_user="no"
fi

ARGS=()

if [[ "${run_as_user}" != "yes" ]]; then
    echo "Warning: running as root due to missing capabilities" > /dev/stderr
else
    fix_perms
    ARGS=(--user suricata --group suricata)
fi

# run helper processes
if [[ "$ENABLE_CRON" == "yes" ]]; then
    crond
fi

# run primary process
exec /usr/bin/suricata "${ARGS[@]}" "$@"
