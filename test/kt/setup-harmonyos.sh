#!/bin/sh
# Scan Setup v0.1 | HarmonyOS PC 6.0.0.115+ (guided setup, not a system-service installer)
set -eu
ACCOUNT=scan
SHARE=scan
fail() { printf '\n错误：%s\n' "$*" >&2; exit 1; }
valid_ip() {
    printf '%s\n' "$1" | awk -F. 'NF==4 {for(i=1;i<=4;i++) if($i !~ /^[0-9]+$/ || length($i)>3 || $i>255) exit 1; if($1==0 || $1==127 || ($1==169 && $2==254) || $1>=224) exit 1; ok=1} END{if(!ok) exit 1}'
}
copy_report() {
    if command -v pbcopy >/dev/null 2>&1 && printf '%s' "$1" | pbcopy; then return 0; fi
    if [ -n "${WAYLAND_DISPLAY:-}" ] && command -v wl-copy >/dev/null 2>&1 && printf '%s' "$1" | wl-copy; then return 0; fi
    if [ -n "${DISPLAY:-}" ] && command -v xclip >/dev/null 2>&1 && printf '%s' "$1" | xclip -selection clipboard; then return 0; fi
    if [ -n "${DISPLAY:-}" ] && command -v xsel >/dev/null 2>&1 && printf '%s' "$1" | xsel --clipboard --input; then return 0; fi
    return 1
}
printf '\n=== Scan Setup v0.1 / HarmonyOS ===\n'
printf '要求：HarmonyOS 6.0.0.115 或以上；当前版本需支持本机网络共享。\n'
printf '本工具不会绕过鸿蒙权限，不会自动修改系统共享服务。\n'
for cmd in awk mkdir openssl; do command -v "$cmd" >/dev/null 2>&1 || fail "当前终端缺少 $cmd，请联系 IT。"; done
# A desktop path must be confirmed because terminal/application file views can differ by version.
desktop=${1:-}
if [ -z "$desktop" ]; then
    case "$(pwd)" in */Desktop|*/桌面) desktop=$(pwd);; esac
fi
if [ -z "$desktop" ]; then
    for d in /storage/Users/currentUser/Desktop /storage/Users/currentUser/桌面 "${HOME:-/nonexistent}/Desktop" "${HOME:-/nonexistent}/桌面"; do
        if [ -d "$d" ]; then desktop=$d; break; fi
    done
fi
if [ -n "$desktop" ] && [ -d "$desktop" ]; then
    printf '检测到候选桌面目录：%s\n' "$desktop"
    printf '请确认这是文件管理中真实桌面目录。输入 Y 确认，否则回车进入手动创建：'
    IFS= read -r answer
    case "$answer" in Y|y) ;; *) desktop='';; esac
else
    desktop=''
fi
created=no
if [ -n "$desktop" ]; then
    folder="$desktop/scan"
    if [ -L "$folder" ]; then fail 'scan 为符号链接，停止。'; fi
    if [ -e "$folder" ] && [ ! -d "$folder" ]; then fail 'scan 已存在且不是文件夹。'; fi
    if mkdir -p "$folder" 2>/dev/null; then
        # Never infer that a terminal path is the GUI desktop without visual confirmation.
        printf '目录已创建或已存在：%s\n' "$folder"
        created=yes
    else
        printf '终端不能写入候选桌面，请使用文件管理手动创建。\n'
    fi
fi
if [ "$created" = no ]; then printf '请先打开文件管理 > 桌面，新建空文件夹 scan。\n'; fi
printf '请在图形桌面确认 scan 文件夹确实存在且只包含允许扫描共享的内容（首次建议为空）。\n'
printf '确认后输入 Y：'; IFS= read -r answer
case "$answer" in Y|y) ;; *) fail '未确认桌面目录，未继续。';; esac
# Both common Linux/Toybox ifconfig address formats are accepted. VPN/virtual interfaces may appear.
ips=''
if command -v ifconfig >/dev/null 2>&1; then
    ips=$(ifconfig 2>/dev/null | awk '
        /^[^ \t]/ {iface=$1; sub(/:$/, "", iface)}
        {for(i=1;i<=NF;i++) if($i=="inet") {v=$(i+1); sub(/^addr:/,"",v); split(v,a,"/"); v=a[1]; n=split(v,b,"."); if(n==4 && b[1]!=0 && b[1]!=127 && b[1]<224 && !(b[1]==169 && b[2]==254) && !seen[v]++) print iface, v}}
    ' || true)
fi
if [ -n "$ips" ]; then
    printf '\n检测到的 IPv4：\n%s\n' "$ips"
    count=$(printf '%s\n' "$ips" | awk 'END{print NR}')
    if [ "$count" = 1 ]; then default_ip=$(printf '%s\n' "$ips" | awk 'NR==1{print $NF}'); else default_ip=''; fi
else
    printf '\n未能自动解析 IP，请到设置 > 网络查看办公网 IPv4。\n'
    default_ip=''
fi
while :; do
    printf '输入打印机可访问的办公网 IPv4（避免 VPN/虚拟网卡%s）：' "${default_ip:+，回车=$default_ip}"
    IFS= read -r ip
    ip=${ip:-$default_ip}
    if valid_ip "$ip"; then break; fi
    printf '无效的办公网 IPv4。\n'
done
printf '输入打印机通讯录显示名（员工姓名）：'; IFS= read -r employee
[ -n "$employee" ] || fail '员工姓名不能为空。'
password="Sc9!$(openssl rand -hex 8)"
case "$password" in Sc9!*) ;; *) fail '随机密码生成失败。';; esac
[ "${#password}" -eq 20 ] || fail '随机密码生成失败。'
printf '\n========= 请按以下步骤配置鸿蒙 SMB =========\n'
printf '1. 文件管理 > 更多 > 设置 > 开启网络共享。首次需安装网络邻居服务，最后点击保存并关闭。\n'
printf '2. 文件管理 > 更多 > 设置 > 网络用户管理 > 添加用户。\n'
printf '   用户名：%s\n   专用随机密码：%s\n' "$ACCOUNT" "$password"
printf '   如果 scan 用户已存在，不要直接重置；请先由 IT 确认旧打印机地址簿是否在使用。\n'
printf '3. 右键桌面 scan > 授予访问权限 > 特定用户（或属性/详情 > 共享）。\n'
printf '   仅添加 scan 网络用户，权限选择读取/写入；不要开启匿名或所有人共享。\n'
printf '4. 确认共享名称为 scan，保存。\n'
printf '5. 优先让 IT 验证 SMB2/3、TCP 445。华为官方打印机回传指南要求 SMB1/CIFS；若确需使用，由 IT 安全评估后手动开启，本工具不自动开启。\n'
printf '\n完成上述配置且确认密码与上面完全一致后，输入 DONE（其他输入取消）：'
IFS= read -r answer
[ "$answer" = DONE ] || fail '共享未确认，不生成已配置报告。'
computer='待 IT 核实'
if command -v hostname >/dev/null 2>&1; then computer=$(hostname 2>/dev/null || printf '待 IT 核实'); fi
report=$(printf '【扫描到个人电脑 - 配置信息】\n员工姓名：%s\n操作系统：HarmonyOS\n计算机名：%s\n服务器 IP：%s\n端口：445 (TCP，待验证)\n共享名称：scan\n子目录：无（共享根目录）\nUNC 路径：\\\\%s\\scan\nSMB 用户名：scan\nSMB 密码：%s\n状态：用户已手动确认共享配置，尚未验证 SMB 连通及写入；请 IT 实测' "$employee" "$computer" "$ip" "$ip" "$password")
printf '\n%s\n\n' "$report"
if copy_report "$report"; then printf '已调用可用的剪贴板工具。请确认粘贴内容，并通过单位批准的安全渠道发送给 IT。\n'; else printf '当前终端没有可验证的剪贴板工具。请选择上方完整信息，使用终端复制功能，然后发送给 IT。\n'; fi
printf '发送后清除剪贴板，勿上传到公开渠道或使用个人系统登录密码。\n'
