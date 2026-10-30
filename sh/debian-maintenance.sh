#!/usr/bin/env bash
# Debian 11+ / Ubuntu 22.04+ 系统维护脚本（APT 2.1.10+）。
# 用法：sudo bash debian-maintenance.sh
# 配置文件冲突：优先采用 dpkg 默认处理方式，无默认选择时保留本地配置。
# 升级可能重启服务，请在合适的维护窗口执行；日志轮转需另行配置。
# 终端仅显示单行进度和结果，完整输出写入日志。
set -euo pipefail
umask 027

if (( EUID != 0 )); then
    echo '请使用 sudo bash debian-maintenance.sh 或以 root 用户运行。' >&2
    exit 1
fi

LOG=/var/log/debian-maintenance.log
STEP='初始化'

exec 9>/run/lock/debian-maintenance.lock
flock -n 9 || {
    echo '已有维护任务运行，退出。' >&2
    exit 1
}

# 保存终端输出，维护命令的 stdout / stderr 统一追加到日志。
exec 3>&1 4>&2

show_step() {
    STEP=$1
    printf '%s\n' "$STEP"
    if [[ -t 3 ]]; then
        printf '\r\033[K%s…' "$STEP" >&3
    fi
}

clear_progress() {
    if [[ -t 3 ]]; then
        printf '\r\033[K' >&3
    fi
}

on_failure() {
    local exit_code=$1 failed_command=$2
    printf '维护失败：退出码 %s，命令：%s\n' "$exit_code" "$failed_command" >&2 || :
    clear_progress
    printf '维护失败：%s（退出码 %s）\n日志：%s\n' "$STEP" "$exit_code" "$LOG" >&4
    exit "$exit_code"
}

{
    trap 'on_failure "$?" "$BASH_COMMAND"' ERR

    echo "========== $(date '+%F %T') =========="
    if [[ ! -t 3 ]]; then
        printf '开始维护…\n' >&3
    fi

    show_step '[1/6] 升级前检查'
    df -h / /var

    audit=$(dpkg --audit)
    if [[ -n "$audit" ]]; then
        printf '%s\n' "$audit"
        echo '软件包状态异常，请先处理。' >&2
        on_failure 1 'dpkg --audit 发现异常'
    fi

    show_step '[2/6] 更新软件源'
    apt-get -o APT::Update::Error-Mode=any update

    show_step '[3/6] 升级系统软件包'
    DEBIAN_FRONTEND=noninteractive apt-get \
        -o Dpkg::Options::=--force-confdef \
        -o Dpkg::Options::=--force-confold \
        upgrade -y

    show_step '[4/6] 清理软件包缓存'
    apt-get autoclean

    show_step '[5/6] 升级后检查'
    audit=$(dpkg --audit)
    if [[ -n "$audit" ]]; then
        printf '%s\n' "$audit"
        echo '升级后软件包状态异常，请检查。' >&2
        on_failure 1 'dpkg --audit 发现异常'
    fi

    show_step '[6/6] 检查重启需求'
    if [[ -f /run/reboot-required ]]; then
        echo '系统有重启提示，请安排重启。'
        reboot_status='需要择机重启'
    else
        echo '未发现 reboot-required 标记；仍需结合内核和服务更新判断。'
        reboot_status='未发现重启提示'
    fi

    echo "维护完成：$(date '+%F %T')"
    clear_progress
    printf '维护完成（%s）\n日志：%s\n' "$reboot_status" "$LOG" >&3
} >>"$LOG" 2>&1
