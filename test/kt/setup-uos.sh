#!/usr/bin/env bash
# Scan Setup v0.3-uos | UOS Desktop (Debian-compatible Samba/systemd edition)
set -Eeuo pipefail
umask 077
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
ACCOUNT=scanuser
SHARE=scan
CONF=/etc/samba/smb.conf
TAG='ScanSetup v0.1'
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
ask() { ui '1;33' '%s' "$1" >&2; read -r "$2"; }
die() { ui '1;31' '\n[错误] %s\n' "$*" >&2; exit 1; }
valid_ip() { local a b c d extra x; IFS=. read -r a b c d extra <<< "$1"; [[ -z ${extra:-} && $1 =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]] || return 1; for x in "$a" "$b" "$c" "$d"; do ((10#$x <= 255)) || return 1; done; }
# Convert an IPv4/prefix to canonical network/netmask, accepted by Samba and UFW.
network_of() {
    local addr=${1%/*} prefix=${1#*/} a b c d n mask net
    valid_ip "$addr" && [[ $prefix =~ ^[0-9]{1,2}$ ]] && ((prefix>=1 && prefix<=32)) || return 1
    IFS=. read -r a b c d <<< "$addr"
    n=$(( (10#$a<<24) | (10#$b<<16) | (10#$c<<8) | 10#$d ))
    mask=$(( (0xffffffff << (32-prefix)) & 0xffffffff )); net=$((n & mask))
    printf '%d.%d.%d.%d/%d\n' "$((net>>24&255))" "$((net>>16&255))" "$((net>>8&255))" "$((net&255))" "$prefix"
}
copy_report() {
    if [[ -n ${WAYLAND_DISPLAY:-} ]] && command -v wl-copy >/dev/null && printf '%s' "$1" | wl-copy; then return 0; fi
    if [[ -n ${DISPLAY:-} ]] && command -v xclip >/dev/null && printf '%s' "$1" | xclip -selection clipboard; then return 0; fi
    if [[ -n ${DISPLAY:-} ]] && command -v xsel >/dev/null && printf '%s' "$1" | xsel --clipboard --input; then return 0; fi
    return 1
}
configure_root() {
    [[ $EUID == 0 && $# == 4 ]] || die '内部配置参数错误。'
    local owner=$1 folder=$2 ip=$3 sources=$4 password role backup temp effective uspath prefix existing
    IFS= read -r password || die '未读取到专用密码。'
    [[ $password =~ ^Sc9![a-f0-9]{16}$ ]] || die '密码格式错误。'
    [[ $owner =~ ^[a-zA-Z0-9_.-]+\$?$ && $owner != root && $owner != "$ACCOUNT" && $owner != "$SHARE" ]] || die '当前用户名称不受支持。'
    [[ -d $folder && ! -L $folder && $folder == /*/scan && $folder != *$'\n'* && $folder != *$'\r'* && $folder != *%* && $folder != *'"'* && $folder != *'\'* ]] || die '共享路径不安全或不受支持。'
    [[ $(stat -c %U -- "$folder") == "$owner" ]] || die 'scan 目录不属于当前员工。'
    [[ -z $(find "$folder" -mindepth 1 -maxdepth 1 -print -quit) ]] || die 'scan 中有旧资料，停止共享。'
    valid_ip "$ip" || die '本机 IPv4 无效。'
    local source
    for source in $sources; do
        if [[ $source == */* ]]; then [[ $(network_of "$source") == "$source" ]] || die '来源网段无效。'; else valid_ip "$source" || die '来源 IPv4 无效。'; fi
    done
    [[ -n $sources ]] || die '缺少来源限制。'
    [[ -f $CONF && ! -L $CONF ]] || die '找不到普通 Samba 配置文件。'
    for cmd in testparm smbpasswd pdbedit smbclient systemctl useradd userdel; do command -v "$cmd" >/dev/null || die "缺少 $cmd"; done
    role=$(testparm -s --parameter-name='server role' "$CONF" 2>/dev/null) || die '现有 Samba 配置无效。'
    [[ $role == 'standalone server' ]] || die "本版仅支持独立 Samba 服务，当前角色：$role"
    # Global host rules can override share-level restrictions. Do not rewrite existing policy.
    local global_allow global_deny
    global_allow=$(testparm -s --parameter-name='hosts allow' "$CONF" 2>/dev/null || true)
    global_deny=$(testparm -s --parameter-name='hosts deny' "$CONF" 2>/dev/null || true)
    [[ -z ${global_allow//[[:space:]]/} && -z ${global_deny//[[:space:]]/} ]] || die '已有 Samba 全局来源限制，请 IT 审核，避免覆盖现有安全策略。'
    effective=$(testparm -s "$CONF" 2>/dev/null) || die '无法读取当前 Samba 配置。'
    if grep -Eiq '^\[scan\][[:space:]]*$' <<< "$effective"; then die '已有 scan 共享，本版不会覆盖。'; fi
    uspath=$(testparm -s --parameter-name='usershare path' "$CONF" 2>/dev/null || true)
    if [[ -n $uspath && -e $uspath/scan ]]; then die '已有文件管理器创建的 scan 共享，请联系 IT。'; fi
    # A legacy scan account, or any local account named like the share, may
    # trigger the UOS file-manager name check. Never delete or rename it.
    if getent passwd "$SHARE" >/dev/null; then die '系统已有与共享名 scan 重名的账户（可能是旧版创建）。请 IT 检查 --diagnose；本版不会删除、迁移或重置旧账户。'; fi
    if getent passwd "$ACCOUNT" >/dev/null; then die "已有 $ACCOUNT 系统用户，本版不会重置密码。"; fi
    existing=$(pdbedit -L 2>/dev/null) || die '无法读取 Samba 用户数据库。'
    if grep -q "^$ACCOUNT:" <<< "$existing"; then die "已有 $ACCOUNT Samba 用户，本版不会覆盖。"; fi
    if grep -q "^$SHARE:" <<< "$existing"; then die '已有旧版 scan Samba 用户，需 IT 核查；本版不会自动迁移。'; fi
    # The account is not a desktop login account; file operations are performed as the employee.
    local nologin=/usr/sbin/nologin
    [[ -x $nologin ]] || nologin=/sbin/nologin
    [[ -x $nologin ]] || die '未发现 nologin。'
    backup=$(mktemp /etc/samba/smb.conf.scan-setup-backup.XXXXXX)
    cp -p -- "$CONF" "$backup"
    temp=$(mktemp /etc/samba/.scan-setup.XXXXXX)
    cp -p -- "$CONF" "$temp"
    cat >> "$temp" <<CFG

# BEGIN ScanSetup v0.1
[scan]
    comment = ScanSetup v0.1
    path = $folder
    browseable = no
    read only = no
    guest ok = no
    valid users = $ACCOUNT
    force user = $owner
    create mask = 0600
    directory mask = 0700
    follow symlinks = no
    wide links = no
    hosts allow = 127.0.0.1 $sources
    hosts deny = ALL
# END ScanSetup v0.1
CFG
    if ! testparm -s "$temp" >/dev/null 2>&1; then rm -f -- "$temp"; die '新增配置未通过 testparm，原配置未改动。'; fi
    # Roll back the new share/account on a configuration error; never delete employee files.
    local changed=0 madeuser=0 added_smb=0 authdir=''
    rollback() {
        local rc=$?
        trap - EXIT
        [[ -z $authdir ]] || rm -rf -- "$authdir"
        [[ ! -e $temp ]] || rm -f -- "$temp"
        if ((rc!=0)); then
            set +e
            if ((changed)); then cp -p -- "$backup" "$CONF"; systemctl reload smbd >/dev/null 2>&1 || smbcontrol smbd reload-config >/dev/null 2>&1; fi
            if ((added_smb)); then smbpasswd -x "$ACCOUNT" >/dev/null 2>&1 || ui '1;31' '[错误] Samba 用户清理失败，请 IT 处理。\n' >&2; fi
            if ((madeuser)); then userdel "$ACCOUNT" >/dev/null 2>&1 || ui '1;31' '[错误] 系统用户清理失败，请 IT 处理。\n' >&2; fi
            ui '1;31' '[错误] 配置失败。原配置备份：%s；已安装的软件/启动的服务可能保留。\n' "$backup" >&2
        fi
        exit "$rc"
    }
    trap rollback EXIT
    useradd --system --no-create-home --home-dir /nonexistent --shell "$nologin" --comment "$TAG" "$ACCOUNT"
    madeuser=1
    ui '1;32' '[完成] 专用扫描账号已创建。\n' >&2
    printf '%s\n%s\n' "$password" "$password" | smbpasswd -s -a "$ACCOUNT" >/dev/null
    added_smb=1
    mv -f -- "$temp" "$CONF"; changed=1
    systemctl enable --now smbd >/dev/null
    systemctl reload smbd >/dev/null 2>&1 || smbcontrol smbd reload-config >/dev/null
    systemctl is-active --quiet smbd || die 'smbd 未启动。'
    ui '1;32' '[完成] Samba 静态共享配置已加载。\n' >&2
    ui '1;36' '[说明] 文件管理器的 Usershare 开关可能不显示；以实际 SMB 认证和读写测试为准。\n' >&2
    # Local authentication plus write/delete test. The secret is in a root-only temp file, not command arguments.
    authdir=$(mktemp -d)
    printf 'username = %s\npassword = %s\n' "$ACCOUNT" "$password" > "$authdir/auth"
    printf 'ScanSetup local test\n' > "$authdir/test"
    local probe="scan_setup_test_$(openssl rand -hex 6).tmp"
    if smbclient //127.0.0.1/scan -p 445 -A "$authdir/auth" --option='client min protocol=SMB2' -c "put $authdir/test $probe" >/dev/null 2>&1 && smbclient //127.0.0.1/scan -p 445 -A "$authdir/auth" --option='client min protocol=SMB2' -c "del $probe" >/dev/null 2>&1; then
        ui '1;32' '[完成] 本机 SMB2/3 认证、写入和删除测试通过。\n' >&2
        printf 'LOCAL_TEST=PASS\n'
    else
        ui '1;33' '[注意] 本机 SMB2/3 测试失败；共享已配置，需 IT 检查接口、策略、权限。\n' >&2
        printf 'LOCAL_TEST=FAIL\n'
    fi
    # Restrict any NEW UFW allowance to the selected sources. Never disable a firewall.
    if command -v ufw >/dev/null && LC_ALL=C ufw status 2>/dev/null | grep -q '^Status: active'; then
        for source in $sources; do
            if ! ufw allow proto tcp from "$source" to any port 445 >/dev/null 2>&1; then ui '1;33' '[注意] UFW 规则添加失败，请 IT 处理。\n' >&2; printf 'FIREWALL=CHECK\n'; break; fi
        done
    else
        ui '1;33' '[注意] 未检测到启用的 UFW；如有其他防火墙/终端安全软件，请 IT 核查 TCP 445。\n' >&2
    fi
    prefix=$(testparm -s --parameter-name='server min protocol' "$CONF" 2>/dev/null || true)
    case "$prefix" in NT1|LANMAN*|CORE*) ui '1;33' '[注意] 现有 Samba 全局协议允许 SMB1，工具未修改该策略。\n' >&2;; esac
    ui '1;36' '原 Samba 配置备份：%s\n' "$backup" >&2
    exit 0
}
# Read-only diagnostic mode; no passwords, password hashes or config changes.
diagnose() {
    ui '1;36' '\n========== UOS SMB 共享诊断 ==========\n'
    printf '当前终端用户名：%s\n' "$(id -un)"
    printf '预期共享名：%s；新版专用账号：%s\n' "$SHARE" "$ACCOUNT"
    printf '\n[1] 本地账户（只显示是否存在）\n'
    local name
    for name in "$SHARE" "$ACCOUNT"; do
        if getent passwd "$name" >/dev/null; then printf '%s: EXISTS\n' "$name"; else printf '%s: NOT_FOUND\n' "$name"; fi
    done
    printf '\n[2] Samba 服务与监听端口\n'
    if command -v systemctl >/dev/null; then systemctl is-active smbd || true; fi
    if command -v ss >/dev/null; then ss -lnt | grep -E ':(445|139)[[:space:]]' || printf '未发现监听端口，或无法读取。\n'; fi
    local -a admin=()
    if ((EUID != 0)); then
        if command -v sudo >/dev/null && sudo -v; then admin=(sudo -n); else ui '1;33' '[注意] 未取得管理员权限，部分检查可能不完整。\n'; fi
    fi
    printf '\n[3] 静态 scan 共享\n'
    if command -v testparm >/dev/null; then
        local static
        if static=$("${admin[@]}" testparm -s --section-name="$SHARE" "$CONF" 2>&1); then
            printf '%s\n' "$static"
        else
            printf '静态共享查询失败或不存在：\n%s\n' "$static"
        fi
        printf '\n[4] Usershare 参数\n'
        local key
        for key in 'usershare path' 'usershare max shares' 'usershare owner only'; do
            printf '%s = ' "$key"
            "${admin[@]}" testparm -s --parameter-name="$key" "$CONF" 2>/dev/null || printf '[读取失败]\n'
        done
    else
        printf 'testparm 不可用。\n'
    fi
    printf '\n[5] 文件管理器 Usershare 中的 scan\n'
    if command -v net >/dev/null; then "${admin[@]}" net usershare info --long "$SHARE" 2>&1 || true; else printf 'net 不可用。\n'; fi
    printf '\n[6] Samba 账户（不输出密码、哈希）\n'
    if command -v pdbedit >/dev/null; then
        for name in "$SHARE" "$ACCOUNT"; do
            if "${admin[@]}" pdbedit -L -u "$name" 2>/dev/null | grep -q "^$name:"; then printf '%s: EXISTS\n' "$name"; else printf '%s: 未查到，或权限/数据库异常。\n' "$name"; fi
        done
    else
        printf 'pdbedit 不可用。\n'
    fi
    ui '1;36' '\n[说明] 静态 SMB 共享不等同于文件管理器的 Usershare 开关。\n'
    printf '如已有旧版配置，请用原用户名 scan 和原密码测试；新版首次配置使用 scanuser。\n'
    printf '诊断未改动共享、账户、服务或防火墙配置。不要向他人发送实际 SMB 密码。\n'
}
if [[ ${1:-} == --diagnose ]]; then diagnose; exit 0; fi
if [[ ${1:-} == --help ]]; then printf '用法：bash setup-uos.sh [--diagnose | --help]\n'; exit 0; fi
if [[ ${1:-} == --configure-root ]]; then shift; configure_root "$@"; exit 0; fi
[[ $EUID != 0 ]] || die '请在员工自己的桌面终端运行，不要 sudo 整个脚本。'
for cmd in sudo ip openssl getent stat find awk; do command -v "$cmd" >/dev/null || die "缺少 $cmd，请联系 IT。"; done
ui '1;36' '\n========== Scan Setup v0.3-uos / UOS ==========\n'
owner=$(id -un)
if [[ $owner == "$SHARE" ]]; then die '当前登录用户名为 scan，与共享名称冲突。请 IT 决定使用其他共享名；不要改动员工登录账户。'; fi
if [[ $owner == "$ACCOUNT" ]]; then die '不能使用专用 SMB 账户运行此脚本。'; fi
if getent passwd "$SHARE" >/dev/null; then die '检测到与共享同名的 scan 系统账户（可能来自旧版）。请运行 bash setup-uos.sh --diagnose；不会自动修改旧配置。'; fi
if getent passwd "$ACCOUNT" >/dev/null; then die '检测到已有 scanuser 账户。请运行 bash setup-uos.sh --diagnose；不会重置密码。'; fi
desktop=''
if command -v xdg-user-dir >/dev/null; then desktop=$(xdg-user-dir DESKTOP 2>/dev/null || true); fi
if [[ -z $desktop || $desktop == "$HOME" || ! -d $desktop ]]; then
    for candidate in "$HOME/Desktop" "$HOME/桌面"; do if [[ -d $candidate ]]; then desktop=$candidate; break; fi; done
fi
[[ -d $desktop && $desktop != "$HOME" ]] || die '找不到桌面路径，请由 IT 检查 XDG 桌面目录。'
folder="$desktop/scan"
[[ ! -L $folder ]] || die 'scan 为符号链接，停止。'
if [[ -e $folder ]]; then [[ -d $folder && -z $(find "$folder" -mindepth 1 -maxdepth 1 -print -quit) ]] || die 'scan 不是空文件夹，请 IT 检查。'; fi
mapfile -t choices < <(ip -o -4 addr show up scope global | awk '{print $2 " " $4}' | awk '$2 !~ /^169\.254\./')
((${#choices[@]})) || die '没有有效 IPv4，请先连接办公网络。'
ui '1;36' '请选择办公网 IPv4（不要选择 VPN 或虚拟网卡）：\n'
for i in "${!choices[@]}"; do printf '  %d. %s\n' "$((i+1))" "${choices[i]}"; done
while :; do
    ask '输入序号（仅一项可回车）：' n
    [[ -n $n || ${#choices[@]} != 1 ]] || n=1
    if [[ $n =~ ^[0-9]{1,4}$ ]] && ((10#$n>=1 && 10#$n<=${#choices[@]})); then break; fi
done
cidr=${choices[10#$n-1]##* }; ip=${cidr%/*}; net=$(network_of "$cidr") || die '无法识别办公网网段。'
ask "打印机 IPv4（多个英文逗号分隔；回车=仅所选网段 $net）：" raw
sources=$net
if [[ -n $raw ]]; then
    sources=''; IFS=, read -r -a printers <<< "$raw"
    for addr in "${printers[@]}"; do addr=${addr//[[:space:]]/}; valid_ip "$addr" || die "无效的打印机 IP：$addr"; sources+=" $addr"; done
    sources=${sources# }
fi
ask "打印机通讯录显示名（员工姓名，回车=$owner）：" employee
employee=${employee:-$owner}
ui '1;36' '将创建 %s、共享名 %s、专用 SMB 账号 %s，并限制来源为 %s。\n' "$folder" "$SHARE" "$ACCOUNT" "$sources"
ask '确认配置？输入 Y 继续：' answer; [[ $answer == [Yy] ]] || die '用户取消。'
sudo -v || die '需要 sudo 权限；请由 IT 授权或在员工会话协助执行。'
packages=()
if ! command -v smbd >/dev/null || ! command -v testparm >/dev/null || ! command -v smbpasswd >/dev/null; then packages+=(samba); fi
if ! command -v smbclient >/dev/null; then packages+=(smbclient); fi
if [[ -n ${DISPLAY:-} ]] && ! command -v xclip >/dev/null && ! command -v xsel >/dev/null && ! command -v wl-copy >/dev/null; then
    ask '安装 xclip 以支持自动复制？(Y/n)：' clip_answer; [[ $clip_answer == [Nn] ]] || packages+=(xclip)
fi
if [[ -n ${WAYLAND_DISPLAY:-} && -z ${DISPLAY:-} ]] && ! command -v wl-copy >/dev/null; then
    ask '安装 wl-clipboard 以支持自动复制？(Y/n)：' clip_answer; [[ $clip_answer == [Nn] ]] || packages+=(wl-clipboard)
fi
if ((${#packages[@]})); then
    ui '1;33' '[注意] 需要安装：%s。安装 Samba 可能启用其默认服务，请遵循企业软件策略。\n' "${packages[*]}"
    ask '允许通过已配置的 APT 源安装？(Y/n)：' install_answer
    [[ $install_answer != [Nn] ]] || die '依赖安装取消。'
    sudo apt-get install -y "${packages[@]}" || die '软件安装失败，请检查 UOS 软件源/权限。'
fi
mkdir -p -- "$folder"
ui '1;32' '[完成] 桌面 scan 文件夹已准备。\n'
password="Sc9!$(openssl rand -hex 8)"
[[ $password =~ ^Sc9![a-f0-9]{16}$ ]] || die '随机密码生成失败。'
script=$(readlink -f -- "$0")
sudo -v || die '管理员授权失败。'
# The password crosses stdin, never the process command line.
if ! result=$(printf '%s\n' "$password" | sudo -n bash "$script" --configure-root "$owner" "$folder" "$ip" "$sources"); then die '配置未完成。请 IT 查看错误，不要盲目重复执行。'; fi
status='共享已配置；等待打印机实测'
if grep -q 'LOCAL_TEST=PASS' <<< "$result"; then status='本机 SMB2/3 认证和读写测试通过；等待打印机实测'; else status='共享已配置，本机 SMB 测试失败；请 IT 检查'; fi
if grep -q 'FIREWALL=CHECK' <<< "$result"; then status+='；防火墙待检查'; fi
if ! grep -q 'LOCAL_TEST=PASS' <<< "$result"; then
    ui '1;33' '[注意] 本机 SMB 测试未通过，请运行 bash setup-uos.sh --diagnose；勿直接重复创建。\n'
fi
report=$(printf '【扫描到个人电脑 - 配置信息】\n员工姓名：%s\n操作系统：UOS\n计算机名：%s\n服务器 IP：%s\n端口：445 (TCP)\n共享名称：scan\n子目录：无（共享根目录）\nUNC 路径：\\\\%s\\scan\nSMB 用户名：%s\nSMB 密码：%s\n状态：%s' "$employee" "$(hostname)" "$ip" "$ip" "$ACCOUNT" "$password" "$status")
show_report "$report"
if copy_report "$report"; then
    ui '1;32' '[完成] 已自动复制到剪贴板，无需手动复制。\n'
else
    ui '1;33' '[注意] 自动复制不可用，请手动复制上方两条分隔线之间的完整内容。\n'
fi
ui '1;36' '[操作] 请通过单位批准的安全渠道发送给 IT，发送后清除剪贴板。\n'
