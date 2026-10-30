#!/usr/bin/env bash
# Debian 11+ / Ubuntu 22.04+ 系统维护脚本（APT 2.1.10+）。
# 用法：sudo bash debian-maintenance.sh
# 配置文件冲突：优先采用 dpkg 默认处理方式，无默认选择时保留本地配置。
# 升级可能重启服务，请在合适的维护窗口执行；日志轮转需另行配置。
set -euo pipefail
umask 027

if (( EUID != 0 )); then
    echo '请使用 sudo bash debian-maintenance.sh 或以 root 用户运行。' >&2
    exit 1
fi

LOG=/var/log/debian-maintenance.log

exec 9>/run/lock/debian-maintenance.lock
flock -n 9 || {
    echo '已有维护任务运行，退出。' >&2
    exit 1
}

{
    trap 'rc=$?; printf "维护失败：退出码 %s，命令：%s\n" "$rc" "$BASH_COMMAND" >&2; exit "$rc"' ERR

    echo "========== $(date '+%F %T') =========="

    echo '[1/6] 升级前检查'
    df -h / /var

    audit=$(dpkg --audit)
    if [[ -n "$audit" ]]; then
        printf '%s\n' "$audit"
        echo '软件包状态异常，请先处理。' >&2
        exit 1
    fi

    echo '[2/6] 更新软件源'
    apt-get -o APT::Update::Error-Mode=any update

    echo '[3/6] 升级系统软件包'
    DEBIAN_FRONTEND=noninteractive apt-get \
        -o Dpkg::Options::=--force-confdef \
        -o Dpkg::Options::=--force-confold \
        upgrade -y

    echo '[4/6] 清理软件包缓存'
    apt-get autoclean

    echo '[5/6] 升级后检查'
    audit=$(dpkg --audit)
    if [[ -n "$audit" ]]; then
        printf '%s\n' "$audit"
        echo '升级后软件包状态异常，请检查。' >&2
        exit 1
    fi

    echo '[6/6] 检查重启需求'
    if [[ -f /run/reboot-required ]]; then
        echo '系统有重启提示，请安排重启。'
    else
        echo '未发现 reboot-required 标记；仍需结合内核和服务更新判断。'
    fi

    echo "维护完成：$(date '+%F %T')"
} 2>&1 | tee -a "$LOG"
