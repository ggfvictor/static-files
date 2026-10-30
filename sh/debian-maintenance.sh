#!/usr/bin/env bash
# Debian 11+ / Ubuntu 22.04+ 系统维护脚本（APT 2.1.10+）。
# 用法：sudo bash debian-maintenance.sh
# 配置文件冲突：优先采用 dpkg 默认处理方式，无默认选择时保留本地配置。
# 升级可能重启服务，请在合适的维护窗口执行。
# 终端仅显示单行进度和结果，完整输出写入日志。
# 每次运行轮换日志，保留当前日志及 .1 到 .4，共最近 5 份。
# 运行前显示脚本提交版本，并通过 SHA-256 核对内容；单文件联网查询需 curl。
set -euo pipefail
umask 027

if (( EUID != 0 )); then
    echo '❌ 请使用 sudo bash debian-maintenance.sh 或以 root 用户运行。' >&2
    exit 1
fi

LOG=/var/log/debian-maintenance.log
STEP='初始化'

exec 9>/run/lock/debian-maintenance.lock
flock -n 9 || {
    echo '⚠️ 已有维护任务运行，退出。' >&2
    exit 1
}

# 获取锁后轮换，.1 为上次日志，.4 为最早保留的日志。
rm -f -- "$LOG.4"
for ((log_index = 3; log_index >= 1; log_index--)); do
    if [[ -f "$LOG.$log_index" ]]; then
        mv -- "$LOG.$log_index" "$LOG.$((log_index + 1))"
    fi
done
if [[ -f "$LOG" ]]; then
    mv -- "$LOG" "$LOG.1"
fi

# 保存终端输出，维护命令的 stdout / stderr 统一写入本次日志。
exec 3>&1 4>&2

describe_version() {
    local script_path=$1 script_dir script_name
    local local_digest reference_digest commit_id api_response

    if [[ ! -f "$script_path" || ! -r "$script_path" ]]; then
        printf '⚠️ 版本：未确认（请下载脚本后运行以校验）\n'
        return
    fi
    if ! local_digest=$(sha256sum <"$script_path" 2>/dev/null); then
        printf '⚠️ 版本：未确认（无法计算文件校验值）\n'
        return
    fi
    local_digest=${local_digest%% *}
    script_name=${script_path##*/}
    script_dir=$(cd -- "$(dirname -- "$script_path")" && pwd -P)

    # 使用最后一次修改本文件的提交，避免把仓库其他文件的更新当作脚本版本。
    if command -v git >/dev/null 2>&1 &&
        commit_id=$(git -C "$script_dir" log -1 --format=%H -- "./$script_name" 2>/dev/null) &&
        [[ $commit_id =~ ^[0-9a-f]{40,64}$ ]] &&
        reference_digest=$(git -C "$script_dir" show "$commit_id:./$script_name" 2>/dev/null | sha256sum); then
        reference_digest=${reference_digest%% *}
        if [[ "$local_digest" == "$reference_digest" ]]; then
            printf '✅ 版本：%.12s（内容一致）\n' "$commit_id"
        else
            printf '⚠️ 版本：%.12s（本地有改动）\n' "$commit_id"
        fi
        return
    fi

    # 单文件没有 Git 元数据：先查询提交，再按该提交下载原文计算摘要。
    # 摘要不一致时只能确认与仓库版本不同，不能推断本地文件来自哪个提交。
    if command -v curl >/dev/null 2>&1 &&
        api_response=$(curl -fsSL --connect-timeout 2 --max-time 4 \
            'https://api.github.com/repos/ggfvictor/static-files/commits?path=sh/debian-maintenance.sh&per_page=1' 2>/dev/null) &&
        [[ $api_response =~ \"sha\"[[:space:]]*:[[:space:]]*\"([0-9a-f]{40})\" ]]; then
        commit_id=${BASH_REMATCH[1]}
        if reference_digest=$(curl -fsSL --connect-timeout 2 --max-time 4 \
            "https://raw.githubusercontent.com/ggfvictor/static-files/$commit_id/sh/debian-maintenance.sh" \
            2>/dev/null | sha256sum); then
            reference_digest=${reference_digest%% *}
            if [[ "$local_digest" == "$reference_digest" ]]; then
                printf '✅ 版本：%.12s（内容一致）\n' "$commit_id"
            else
                printf '⚠️ 版本：未确认（与仓库 %.12s 不同）\n' "$commit_id"
            fi
            return
        fi
    fi

    printf '⚠️ 版本：未确认（无法核对仓库）｜SHA256：%.12s\n' "$local_digest"
}

show_step() {
    STEP=$1
    printf '%s\n' "$STEP"
    if [[ -t 3 ]]; then
        printf '\r\033[K⏳ %s…' "$STEP" >&3
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
    printf '❌ 维护失败：%s（退出码 %s）\n日志：%s\n' "$STEP" "$exit_code" "$LOG" >&4
    exit "$exit_code"
}

{
    trap 'on_failure "$?" "$BASH_COMMAND"' ERR

    echo "========== $(date '+%F %T') =========="
    version_status=$(describe_version "${BASH_SOURCE[0]:-}")
    printf '%s\n' "$version_status"
    printf '%s\n' "$version_status" >&3
    if [[ ! -t 3 ]]; then
        printf '⏳ 开始维护…\n' >&3
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
        status_icon='🔴'
        reboot_status='需要择机重启'
    else
        echo '未发现 reboot-required 标记；仍需结合内核和服务更新判断。'
        status_icon='🟢'
        reboot_status='未发现重启提示'
    fi

    echo "维护完成：$(date '+%F %T')"
    clear_progress
    printf '%s 维护完成（%s）\n日志：%s\n' "$status_icon" "$reboot_status" "$LOG" >&3
} >"$LOG" 2>&1
