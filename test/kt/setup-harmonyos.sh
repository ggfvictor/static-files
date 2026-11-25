#!/bin/sh
# Scan Setup v0.3-harmony (preview) | HarmonyOS PC 6.0.0.115+ (guided setup, not a system-service installer)
set -eu
ACCOUNT=scan
SHARE=scan
# ANSI decoration is for interactive display only. Never decorate machine-readable
# results, passwords passed to system commands, or text sent to the clipboard.
ui() {
    if [ -t 1 ] && [ "${TERM:-dumb}" != dumb ] && [ "${NO_COLOR+x}" != x ]; then
        printf '\033[%sm' "$1"
        shift
        printf "$@"
        printf '\033[0m'
    else
        shift
        printf "$@"
    fi
}
show_report() {
    ui '1;35' '\n========== 复制开始 | 请发送给 IT ==========\n'
    ui '1;35' '%s\n' "$1"
    ui '1;35' '========== 复制结束 | 仅复制两线之间 ==========\n\n'
}
fail() { ui '1;31' '\n[错误] %s\n' "$*" >&2; exit 1; }
# Validate without relying on awk, which may be absent in the native terminal.
valid_ip() (
    rest=$1
    i=1
    first=0
    while [ "$i" -le 4 ]; do
        if [ "$i" -lt 4 ]; then
            case "$rest" in *.*) octet=${rest%%.*}; rest=${rest#*.};; *) return 1;; esac
        else
            octet=$rest
        fi
        case "$octet" in 0|[1-9]|[1-9][0-9]|[1-9][0-9][0-9]) ;; *) return 1;; esac
        [ "$octet" -le 255 ] || return 1
        case "$i" in
            1) first=$octet; [ "$first" -gt 0 ] && [ "$first" -ne 127 ] && [ "$first" -lt 224 ] || return 1;;
            2) if [ "$first" -eq 169 ] && [ "$octet" -eq 254 ]; then return 1; fi;;
        esac
        i=$((i + 1))
    done
    return 0
)
valid_hex() {
    [ "${#1}" -eq 16 ] || return 1
    case "$1" in *[!0123456789abcdefABCDEF]*) return 1;; esac
}
new_password() {
    hex=''
    if command -v openssl >/dev/null 2>&1; then
        hex=$(openssl rand -hex 8 2>/dev/null) || hex=''
    fi
    if ! valid_hex "$hex" && command -v od >/dev/null 2>&1 && command -v tr >/dev/null 2>&1 && [ -r /dev/urandom ]; then
        hex=$(od -An -N8 -tx1 /dev/urandom 2>/dev/null | tr -d '[:space:]') || hex=''
    fi
    valid_hex "$hex" || return 1
    printf 'Sc9!%s' "$hex"
}
# Read-only diagnostics: show directory metadata, not directory contents,
# and command availability. Do not include passwords or IP addresses.
diagnose() {
    printf '\n=== HarmonyOS Scan Setup | 诊断（不修改系统） ===\n'
    printf 'SHELL=%s\nHOME=%s\nPWD=%s\n' "${SHELL:-unknown}" "${HOME:-unknown}" "$(pwd)"
    printf '\n目录检查（存在 / 可写）：\n'
    for d in "$(pwd)" /storage/Users/currentUser /storage/Users/currentUser/Desktop /storage/Users/currentUser/desktop /storage/Users/currentUser/桌面 "${HOME:-/nonexistent}/Desktop" "${HOME:-/nonexistent}/desktop" "${HOME:-/nonexistent}/桌面"; do
        if [ -d "$d" ]; then
            writable=no
            if [ -w "$d" ]; then writable=yes; fi
            printf '  FOUND writable=%s %s\n' "$writable" "$d"
        else
            printf '  NOT_FOUND %s\n' "$d"
        fi
    done
    printf '\n命令检查（仅检查是否存在，不执行）：\n'
    for cmd in sh zsh mkdir awk openssl od tr ifconfig ip hostname smbpasswd smbd net pbcopy wl-copy xclip xsel; do
        if command -v "$cmd" >/dev/null 2>&1; then printf '  FOUND %s\n' "$cmd"; else printf '  NOT_FOUND %s\n' "$cmd"; fi
    done
    printf '\n以上信息不包含脚本生成的 SMB 密码。发送给 IT 前可遮盖个人用户名。\n'
}
copy_report() {
    if command -v pbcopy >/dev/null 2>&1 && printf '%s' "$1" | pbcopy; then return 0; fi
    if [ -n "${WAYLAND_DISPLAY:-}" ] && command -v wl-copy >/dev/null 2>&1 && printf '%s' "$1" | wl-copy; then return 0; fi
    if [ -n "${DISPLAY:-}" ] && command -v xclip >/dev/null 2>&1 && printf '%s' "$1" | xclip -selection clipboard; then return 0; fi
    if [ -n "${DISPLAY:-}" ] && command -v xsel >/dev/null 2>&1 && printf '%s' "$1" | xsel --clipboard --input; then return 0; fi
    return 1
}
ui '1;36' '\n========== Scan Setup v0.3-harmony / HarmonyOS ==========\n'
printf '要求：HarmonyOS 6.0.0.115 或以上；当前版本需支持本机网络共享。\n'
printf '本工具不会绕过鸿蒙权限，不会自动修改系统共享服务。\n'
if [ "${1:-}" = "--diagnose" ]; then diagnose; exit 0; fi
if [ "${1:-}" = "--help" ]; then
    printf '用法：sh setup-harmonyos.sh [真实桌面目录]\n      sh setup-harmonyos.sh --diagnose\n'
    exit 0
fi
# Do not require IP/password utilities before creating the desktop directory.
ui '1;36' '\n[步骤 1/5] 定位真实桌面并创建 scan\n'
# A desktop path must be confirmed because terminal/application file views can differ by version.
desktop=${1:-}
if [ -z "$desktop" ]; then
    case "$(pwd)" in */Desktop|*/desktop|*/桌面) desktop=$(pwd);; esac
fi
if [ -z "$desktop" ]; then
    for d in /storage/Users/currentUser/Desktop /storage/Users/currentUser/desktop /storage/Users/currentUser/桌面 "${HOME:-/nonexistent}/Desktop" "${HOME:-/nonexistent}/desktop" "${HOME:-/nonexistent}/桌面"; do
        if [ -d "$d" ]; then desktop=$d; break; fi
    done
fi
while :; do
    if [ -n "$desktop" ] && [ -d "$desktop" ]; then
        ui '1;36' '候选桌面目录：%s\n' "$desktop"
        ui '1;33' '确认是真实桌面？输入 Y；其他输入重新选择路径：'
        IFS= read -r answer || fail '输入结束，取消。'
        case "$answer" in Y|y) break;; esac
    else
        ui '1;33' '[注意] 未找到可确认的桌面路径。\n'
    fi
    ui '1;36' '可在文件管理中打开桌面，右键启动终端，再运行 pwd 获取真实路径。\n'
    ui '1;33' '输入真实桌面绝对路径（直接回车改为手动创建）：'
    IFS= read -r desktop || fail '输入结束，取消。'
    [ -n "$desktop" ] || break
    case "$desktop" in /*) ;; *) desktop=''; ui '1;31' '[错误] 请使用绝对路径。\n';; esac
done
created=no
if [ -n "$desktop" ]; then
    folder="$desktop/scan"
    if [ -L "$folder" ]; then fail 'scan 为符号链接，停止。'; fi
    if [ -e "$folder" ] && [ ! -d "$folder" ]; then fail 'scan 已存在且不是文件夹。'; fi
    if command -v mkdir >/dev/null 2>&1 && mkdir -p "$folder" && [ -d "$folder" ] && [ ! -L "$folder" ]; then
        # Verify the shell-visible directory; the user still verifies the GUI view.
        ui '1;32' '[完成] 终端目录创建/存在检查通过：%s\n' "$folder"
        created=yes
    else
        ui '1;31' '[错误] 未能创建 %s（请查看上面的实际报错）。\n' "$folder"
        ui '1;33' '[注意] 检查设置 > 隐私和安全 > 文件和文件夹中终端的桌面访问权限（若有该项）；也可在文件管理手动创建。\n'
    fi
fi
if [ "$created" = no ]; then ui '1;33' '[操作] 请先打开文件管理 > 桌面，新建空文件夹 scan。\n'; fi
ui '1;33' '[操作] 请在图形桌面确认 scan 文件夹确实存在且只包含允许扫描共享的内容（首次建议为空）。\n'
ui '1;33' '确认后输入 Y：'; IFS= read -r answer
case "$answer" in Y|y) ;; *) fail '未确认桌面目录，未继续。';; esac
ui '1;32' '[完成] 用户已确认图形桌面存在 scan。\n'
ui '1;36' '\n[步骤 2/5] 确定办公网 IPv4 和员工姓名\n'
# Both common Linux/Toybox ifconfig address formats are accepted. VPN/virtual interfaces may appear.
ips=''
if command -v ifconfig >/dev/null 2>&1 && command -v awk >/dev/null 2>&1; then
    ips=$(ifconfig 2>/dev/null | awk '
        /^[^ \t]/ {iface=$1; sub(/:$/, "", iface)}
        {for(i=1;i<=NF;i++) if($i=="inet") {v=$(i+1); sub(/^addr:/,"",v); split(v,a,"/"); v=a[1]; n=split(v,b,"."); if(n==4 && b[1]!=0 && b[1]!=127 && b[1]<224 && !(b[1]==169 && b[2]==254) && !seen[v]++) print iface, v}}
    ' || true)
fi
if [ -z "$ips" ] && command -v ip >/dev/null 2>&1 && command -v awk >/dev/null 2>&1; then
    ips=$(ip -o -4 addr show up scope global 2>/dev/null | awk '{split($4,a,"/"); if(a[1] !~ /^169\.254\./) print $2, a[1]}' || true)
fi
if [ -n "$ips" ]; then
    ui '1;36' '\n检测到的 IPv4：\n%s\n' "$ips"
    count=$(printf '%s\n' "$ips" | awk 'END{print NR}')
    if [ "$count" = 1 ]; then default_ip=$(printf '%s\n' "$ips" | awk 'NR==1{print $NF}'); else default_ip=''; fi
else
    ui '1;33' '\n[注意] 未能自动解析 IP，请到设置 > 网络查看办公网 IPv4。\n'
    default_ip=''
fi
while :; do
    ui '1;33' '输入打印机可访问的办公网 IPv4（避免 VPN/虚拟网卡%s）：' "${default_ip:+，回车=$default_ip}"
    IFS= read -r ip
    ip=${ip:-$default_ip}
    if valid_ip "$ip"; then break; fi
    ui '1;31' '[错误] 无效的办公网 IPv4。\n'
done
ui '1;33' '输入打印机通讯录显示名（员工姓名）：'; IFS= read -r employee
[ -n "$employee" ] || fail '员工姓名不能为空。'
ui '1;36' '\n[步骤 3/5] 生成独立的扫描账号凭据\n'
if ! password=$(new_password); then
    fail '当前终端没有可用的安全随机数命令（openssl 或 od + tr）。scan 目录已准备；请 IT 运行 --diagnose 核查。'
fi
ui '1;32' '[完成] 已生成专用随机密码（尚未创建网络用户）。\n'
ui '1;33' '\n[步骤 4/5] 需要手动操作 | 鸿蒙 SMB\n'
ui '1;33' '[注意] 目前未确认鸿蒙有公开的 SMB 用户及共享管理命令，本脚本不会自动创建或授权账号。\n'
printf '1. 文件管理 > 更多 > 设置 > 开启网络共享。首次需安装网络邻居服务，最后点击保存并关闭。\n'
ui '1;33' '完成开启网络共享后输入 Y：'
IFS= read -r answer || fail '输入结束，取消。'
case "$answer" in Y|y) ;; *) fail '网络共享未确认。';; esac
printf '2. 文件管理 > 更多 > 设置 > 网络用户管理 > 添加用户。\n'
ui '1;33' '   用户名：%s\n   专用随机密码：%s\n' "$ACCOUNT" "$password"
ui '1;33' '   [注意] 如果 scan 用户已存在，不要直接重置；请先由 IT 确认旧打印机地址簿是否在使用。\n'
ui '1;33' '确认已创建 scan 网络用户且密码与上方一致后输入 Y：'
IFS= read -r answer || fail '输入结束，取消。'
case "$answer" in Y|y) ;; *) fail '网络用户未确认。';; esac
printf '3. 右键桌面 scan > 授予访问权限 > 特定用户（或属性/详情 > 共享）。\n'
printf '   仅添加 scan 网络用户，权限选择读取/写入；不要开启匿名或所有人共享。\n'
printf '4. 确认共享名称为 scan，保存。\n'
printf '5. 优先让 IT 验证 SMB2/3、TCP 445。华为官方打印机回传指南要求 SMB1/CIFS；若确需使用，由 IT 安全评估后手动开启，本工具不自动开启。\n'
ui '1;33' '\n完成上述配置且确认密码与上面完全一致后，输入 DONE（其他输入取消）：'
IFS= read -r answer
[ "$answer" = DONE ] || fail '共享未确认，不生成已配置报告。'
computer='待 IT 核实'
if command -v hostname >/dev/null 2>&1; then computer=$(hostname 2>/dev/null || printf '待 IT 核实'); fi
report=$(printf '【扫描到个人电脑 - 配置信息】\n员工姓名：%s\n操作系统：HarmonyOS\n计算机名：%s\n服务器 IP：%s\n端口：445 (TCP，待验证)\n共享名称：scan\n子目录：无（共享根目录）\nUNC 路径：\\\\%s\\scan\nSMB 用户名：scan\nSMB 密码：%s\n状态：用户已手动确认共享配置，尚未验证 SMB 连通及写入；请 IT 实测' "$employee" "$computer" "$ip" "$ip" "$password")
ui '1;36' '\n[步骤 5/5] 整理提交给 IT 的配置\n'
ui '1;33' '[注意] 用户已确认手动配置；SMB 连通性和写入尚待 IT 验证。\n'
show_report "$report"
if copy_report "$report"; then
    ui '1;32' '[完成] 已调用剪贴板工具，请确认粘贴内容。\n'
else
    ui '1;33' '[注意] 自动复制不可用，请手动复制上方两条分隔线之间的完整内容。\n'
fi
ui '1;36' '[操作] 请通过单位批准的安全渠道发送给 IT，发送后清除剪贴板。\n'
ui '1;33' '[注意] 勿上传到公开渠道或使用个人系统登录密码。\n'
