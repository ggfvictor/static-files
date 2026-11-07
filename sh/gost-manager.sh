#!/usr/bin/env bash
# GOST v3 one-click installer and TCP/UDP forwarding manager (Debian/Ubuntu + systemd).
# Repository: https://github.com/ggfvictor/static-files/tree/main/sh
# Usage: bash <(curl -fsSL https://raw.githubusercontent.com/ggfvictor/static-files/main/sh/gost-manager.sh)
# Run as root. Existing manually written YAML services are not removed by this tool.
set -Eeuo pipefail
umask 077

CONFIG_DIR=/etc/gost
CONFIG_FILE=$CONFIG_DIR/gost.yml
RULES_FILE=$CONFIG_DIR/gost-manager.rules
SERVICE_FILE=/etc/systemd/system/gost.service
BACKUP_DIR=/var/backups/gost-manager
BIN_TARGET=/usr/local/bin/gost
REPO_API=https://api.github.com/repos/go-gost/gost/releases/latest
MARK_START='  # >>> GOST-MANAGER managed services >>>'
MARK_END='  # <<< GOST-MANAGER managed services <<<'

info() { printf '\033[1;34m[INFO]\033[0m %s\n' "$*"; }
ok()   { printf '\033[1;32m[ OK ]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[WARN]\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[ERROR]\033[0m %s\n' "$*" >&2; exit 1; }
ask_yes() { local ans; [[ -t 0 ]] || { warn "非交互模式：跳过需要确认的操作：$1"; return 1; }; read -r -p "$1 [y/N]: " ans || return 1; [[ $ans == [yY] || $ans == [yY][eE][sS] ]]; }

usage() {
    cat <<'HELP'
GOST v3 安装及 TCP/UDP 转发管理（Debian/Ubuntu + systemd）
用法：sudo bash gost-manager.sh [--install|--list|--status|--reload|--help]
不带参数：显示交互式菜单。

规则管理：添加 TCP、UDP 或两者同时转发；只删除本脚本创建的规则。
安全设计：下载官方最新稳定版本，校验 SHA256；修改前备份配置；
          通过 SIGHUP 热加载；不覆盖现有 systemd 服务文件或手工规则。
配置位置：/etc/gost/gost.yml
规则记录：/etc/gost/gost-manager.rules
备份目录：/var/backups/gost-manager
HELP
}

[[ ${1:-} == --help || ${1:-} == -h ]] && { usage; exit 0; }
(( EUID == 0 )) || die '请使用 root 运行。'
[[ $(uname -s) == Linux ]] || die '仅支持 Linux。'
[[ -d /run/systemd/system ]] || warn '没有检测到正在运行的 systemd；安装服务和热加载可能不可用。'
command -v python3 >/dev/null || die '缺少 python3，请先执行 apt-get install -y python3。'
command -v flock >/dev/null || die '缺少 flock（util-linux）。'
command -v systemctl >/dev/null || die '缺少 systemctl，暂不支持此系统。'
mkdir -p /run/lock "$CONFIG_DIR"
exec 9>/run/lock/gost-manager.lock
flock -n 9 || die '另一个 GOST 管理脚本正在运行。'

WORK_DIR=$(mktemp -d /tmp/gost-manager.XXXXXXXX)
trap 'rm -rf -- "$WORK_DIR"' EXIT

find_gost() {
    if [[ -x $BIN_TARGET ]]; then
        printf '%s\n' "$BIN_TARGET"
    else
        command -v gost || true
    fi
}

require_gost() {
    GOST_BIN=$(find_gost)
    [[ -n $GOST_BIN && -x $GOST_BIN ]] || die '尚未安装 GOST，请先选择菜单 1。'
    "$GOST_BIN" -V 2>&1 | grep -q 'v3\.' || die '当前 GOST 不是 v3，请先升级。'
}

ensure_files() {
    mkdir -p "$CONFIG_DIR"
    if [[ ! -f $CONFIG_FILE ]]; then
        printf 'services: []\n' >"$CONFIG_FILE"
        chmod 600 "$CONFIG_FILE"
        info "已创建空配置文件 $CONFIG_FILE"
    fi
    if [[ ! -e $RULES_FILE ]]; then
        : >"$RULES_FILE"
        chmod 600 "$RULES_FILE"
    fi
}

snapshot() {
    local stamp dest
    stamp=$(date -u +'%Y%m%dT%H%M%S.%N')
    dest="$BACKUP_DIR/$stamp"
    mkdir -p "$dest"
    [[ ! -f $CONFIG_FILE ]] || cp -p "$CONFIG_FILE" "$dest/gost.yml"
    [[ ! -f $RULES_FILE ]] || cp -p "$RULES_FILE" "$dest/gost-manager.rules"
    printf '%s\n' "$dest"
}

install_binary() {
    local arch asset release tag version url checksum_url checksum expected actual bin_dir
    local -a required=(curl jq tar gzip sha256sum)
    local cmd
    for cmd in "${required[@]}"; do
        if ! command -v "$cmd" >/dev/null 2>&1; then
            info "安装依赖：$cmd"
            apt-get update && apt-get install -y curl jq tar gzip coreutils ca-certificates
            break
        fi
    done
    case $(uname -m) in
        x86_64) arch=amd64 ;;
        aarch64|arm64) arch=arm64 ;;
        armv7l) arch=armv7 ;;
        armv6l) arch=armv6 ;;
        i686|i386) arch=386 ;;
        *) die "不支持的 CPU 架构：$(uname -m)" ;;
    esac
    info '查询 GOST 官方最新稳定版本（不会选择 nightly）...'
    release=$(curl -fsSL --retry 3 --connect-timeout 10 --max-time 40 "$REPO_API") || die '无法查询 GitHub Releases，请稍后重试。'
    tag=$(printf '%s' "$release" | jq -r '.tag_name // empty')
    [[ $tag =~ ^v3\.[0-9]+\.[0-9]+$ ]] || die "获取的版本不是正式稳定版：$tag"
    version=${tag#v}
    asset="gost_${version}_linux_${arch}.tar.gz"
    url=$(printf '%s' "$release" | jq -r --arg n "$asset" '.assets[]? | select(.name == $n) | .browser_download_url' | head -n 1)
    checksum_url=$(printf '%s' "$release" | jq -r '.assets[]? | select(.name == "checksums.txt") | .browser_download_url' | head -n 1)
    [[ $url == https://github.com/go-gost/gost/releases/download/* ]] || die "版本 $tag 没有适用安装包 $asset"
    [[ $checksum_url == https://github.com/go-gost/gost/releases/download/* ]] || die '该版本没有 checksums.txt，已停止安装。'
    info "下载 $tag / $asset ..."
    curl -fL --retry 3 --connect-timeout 15 --max-time 300 -o "$WORK_DIR/$asset" "$url" || die 'GOST 下载失败。'
    curl -fL --retry 3 --connect-timeout 15 --max-time 60 -o "$WORK_DIR/checksums.txt" "$checksum_url" || die 'SHA256 校验文件下载失败。'
    expected=$(awk -v n="$asset" '$2 == n || $2 == "*" n {print $1; exit}' "$WORK_DIR/checksums.txt")
    [[ $expected =~ ^[[:xdigit:]]{64}$ ]] || die "找不到 $asset 的 SHA256，拒绝安装。"
    actual=$(sha256sum "$WORK_DIR/$asset" | awk '{print $1}')
    [[ ${expected,,} == "${actual,,}" ]] || die 'SHA256 校验失败，已拒绝安装。'
    tar -tzf "$WORK_DIR/$asset" | grep -Eq '^\./?gost$|^gost$' || die '压缩包内没有 gost 程序。'
    mkdir -p "$WORK_DIR/extracted"
    tar -xzf "$WORK_DIR/$asset" -C "$WORK_DIR/extracted" --no-same-owner
    if [[ -f $WORK_DIR/extracted/gost ]]; then
        bin_dir="$WORK_DIR/extracted/gost"
    elif [[ -f $WORK_DIR/extracted/./gost ]]; then
        bin_dir="$WORK_DIR/extracted/./gost"
    else
        die '解压后找不到 gost 可执行文件。'
    fi
    chmod 755 "$bin_dir"
    "$bin_dir" -V 2>&1 | grep -q "v${version}" || die '下载程序版本与 Release 不符。'
    if [[ -e $BIN_TARGET ]]; then
        mkdir -p "$BACKUP_DIR/binaries"
        cp -p "$BIN_TARGET" "$BACKUP_DIR/binaries/gost.$(date -u +%Y%m%dT%H%M%S).bak"
    fi
    install -m 0755 "$bin_dir" "$BIN_TARGET.tmp.$$"
    mv -f "$BIN_TARGET.tmp.$$" "$BIN_TARGET"
    ok "GOST $tag 已安装：$BIN_TARGET（SHA256 校验通过）"
    if systemctl is-active --quiet gost; then
        warn '当前 GOST 服务仍在运行原来的进程；升级生效需要重启服务，现有连接将中断。'
        if systemctl cat gost 2>/dev/null | grep -Eq '^ExecStart=/usr/bin/gost([[:space:]]|$)'; then
            warn '现有服务使用 /usr/bin/gost 而非 /usr/local/bin/gost；本次安装的新版本不会被该服务使用，请核对 ExecStart。'
        fi
        if ask_yes '现在重启 gost 服务吗？'; then
            systemctl restart gost && ok '服务已重启。' || warn '重启失败，请检查 journalctl -u gost -n 50。'
        fi
    fi
}

ensure_reload_support() {
    if [[ $(systemctl show gost -p CanReload --value 2>/dev/null || true) != yes ]]; then
        mkdir -p /etc/systemd/system/gost.service.d
        cat >/etc/systemd/system/gost.service.d/10-gost-manager-reload.conf <<'UNIT'
[Service]
ExecReload=/bin/kill -HUP $MAINPID
UNIT
        systemctl daemon-reload
        info '已为现有 GOST 服务添加 systemd 热加载支持。'
    fi
}

install_service() {
    local bin
    require_gost
    ensure_files
    bin=$(find_gost)
    if systemctl cat gost >/dev/null 2>&1; then
        info '检测到现有 gost.service，将保留其 ExecStart 和其他配置。'
    else
        cat >"$SERVICE_FILE" <<UNIT
[Unit]
Description=GOST v3 TCP/UDP Forwarding
Documentation=https://gost.run/
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=$bin -C $CONFIG_FILE
ExecReload=/bin/kill -HUP \$MAINPID
Restart=always
RestartSec=5
LimitNOFILE=65535

[Install]
WantedBy=multi-user.target
UNIT
        chmod 644 "$SERVICE_FILE"
        systemctl daemon-reload
        ok "已创建 $SERVICE_FILE"
    fi
    ensure_reload_support
    if ! systemctl cat gost | grep -Fq "$CONFIG_FILE"; then
        warn "现有 systemd 服务没有明确引用 $CONFIG_FILE；请核对 systemctl cat gost 的 ExecStart。"
        warn '为避免误操作，本次不会自动覆盖已有服务定义。'
    fi
    systemctl enable --now gost
    systemctl is-active --quiet gost || die 'GOST 服务启动失败，使用 journalctl -u gost -n 50 检查。'
    ok 'GOST 系统服务已启动并设置开机自启。'
}

validate_config() {
    local file=$1 bin
    require_gost
    bin=$(find_gost)
    if ! "$bin" -C "$file" -O yaml >"$WORK_DIR/config-check.out" 2>"$WORK_DIR/config-check.err"; then
        cat "$WORK_DIR/config-check.err" >&2
        die "GOST 配置检查失败：$file"
    fi
}

render_config() {
    local rules=$1 output=$2
    python3 - "$CONFIG_FILE" "$rules" "$output" <<'PY'
import json, pathlib, re, sys
src, rules_file, dest = map(pathlib.Path, sys.argv[1:])
start = '  # >>> GOST-MANAGER managed services >>>'
end = '  # <<< GOST-MANAGER managed services <<<'
lines = src.read_text(encoding='utf-8').splitlines(keepends=True)
begins = [i for i, x in enumerate(lines) if x.rstrip('\r\n') == start]
ends = [i for i, x in enumerate(lines) if x.rstrip('\r\n') == end]
if len(begins) != len(ends) or len(begins) > 1 or (begins and begins[0] >= ends[0]):
    sys.exit('错误：YAML 内的 GOST-MANAGER 标记异常，拒绝自动编辑。')
if begins:
    lines = lines[:begins[0]] + lines[ends[0]+1:]
records = []
for row in rules_file.read_text(encoding='utf-8').splitlines():
    if not row.strip() or row.startswith('#'):
        continue
    fields = row.split('\t')
    if len(fields) != 6:
        sys.exit('错误：规则数据库格式不正确。')
    name, proto, listen, listen_port, target, target_port = fields
    if not re.fullmatch(r'[a-zA-Z0-9_-]{1,48}', name) or proto not in ('tcp', 'udp', 'both'):
        sys.exit('错误：规则名或协议无效。')
    if not all(re.fullmatch(r'[a-zA-Z0-9.\[\]:_-]+', s) for s in (listen, target)):
        sys.exit('错误：地址无效。')
    if not all(s.isdecimal() and 1 <= int(s) <= 65535 for s in (listen_port, target_port)):
        sys.exit('错误：端口无效。')
    records.append(fields)

managed = [start + '\n']
for name, proto, listen, lport, target, tport in records:
    for p in ('tcp', 'udp') if proto == 'both' else (proto,):
        sname = 'gm-' + name + '-' + p
        if any(re.search(r'^\s*-\s*name:\s*["\']?' + re.escape(sname) + r'["\']?\s*$', l) for l in lines):
            sys.exit('错误：服务名 ' + sname + ' 已存在于手写规则中。')
        managed += [
            '  - name: ' + sname + '\n',
            '    addr: ' + json.dumps(f'{listen}:{lport}') + '\n',
            '    handler:\n',
            '      type: ' + p + '\n',
            '    listener:\n',
            '      type: ' + p + '\n',
        ]
        if p == 'udp':
            managed += [
                '      metadata:\n',
                '        keepAlive: true\n',
                '        ttl: 30s\n',
                '        readBufferSize: 65535\n',
            ]
        managed += [
            '    forwarder:\n',
            '      nodes:\n',
            '        - name: ' + sname + '-target\n',
            '          addr: ' + json.dumps(f'{target}:{tport}') + '\n',
        ]
managed.append(end + '\n')

service_positions = [i for i, line in enumerate(lines) if re.match(r'^services\s*:', line)]
if len(service_positions) > 1:
    sys.exit('错误：存在多个顶层 services 字段。')
if service_positions:
    i = service_positions[0]
    if re.fullmatch(r'services\s*:\s*\[\s*\]\s*(?:#.*)?\n?', lines[i]):
        lines[i] = 'services:\n'
    elif not re.fullmatch(r'services\s*:\s*(?:#.*)?\n?', lines[i]):
        sys.exit('错误：services 不是普通 YAML 列表，无法安全插入，请手动配置。')
    insert_at = len(lines)
    for j in range(i+1, len(lines)):
        if re.match(r'^[a-zA-Z_][a-zA-Z_0-9-]*\s*:', lines[j]) or lines[j].strip() in ('---', '...'):
            insert_at = j
            break
    lines[insert_at:insert_at] = managed
else:
    if lines and not lines[-1].endswith('\n'):
        lines[-1] += '\n'
    lines += ['\nservices:\n'] + managed

dest.write_text(''.join(lines), encoding='utf-8')
PY
}

reload_service() {
    validate_config "$CONFIG_FILE"
    if systemctl is-active --quiet gost; then
        ensure_reload_support
        if ! systemctl reload gost; then
            warn '热加载失败；当前服务可能仍使用旧配置。'
            return 1
        fi
        ok '已发送 SIGHUP 热加载请求。'
        info '请核对新端口监听及 journalctl -u gost -n 30。'
    else
        warn 'GOST 当前未运行，配置已保存但尚未生效。请先启动服务。'
    fi
}

apply_staged_rules() {
    local staged_rules=$1 staged_config backup
    staged_config="$WORK_DIR/gost-staged.yml"
    render_config "$staged_rules" "$staged_config"
    validate_config "$staged_config"
    backup=$(snapshot)
    install -m 600 "$staged_config" "$CONFIG_FILE.tmp.$$"
    mv -f "$CONFIG_FILE.tmp.$$" "$CONFIG_FILE"
    install -m 600 "$staged_rules" "$RULES_FILE.tmp.$$"
    mv -f "$RULES_FILE.tmp.$$" "$RULES_FILE"
    info "修改前备份：$backup"
    if ! reload_service; then
        warn '热加载失败，正在恢复旧配置与规则。'
        cp -p "$backup/gost.yml" "$CONFIG_FILE"
        cp -p "$backup/gost-manager.rules" "$RULES_FILE"
        systemctl reload gost || true
        die '已回滚文件；请检查 GOST 日志后重试。'
    fi
    ok '规则文件已更新。'
}

valid_host() {
    [[ $1 =~ ^[a-zA-Z0-9._-]+$ || $1 =~ ^\[[0-9a-fA-F:.]+\]$ ]]
}
valid_port() {
    [[ $1 =~ ^[0-9]{1,5}$ ]] && (( 10#$1 >= 1 && 10#$1 <= 65535 ))
}

list_rules() {
    ensure_files
    printf '\n==== 管理器创建的转发规则 ====\n'
    if [[ ! -s $RULES_FILE ]]; then
        printf '（无；已有的手工规则不会被此工具删除）\n'
    else
        printf '%-18s %-6s %-25s %-25s\n' '名称' '协议' '监听' '目标'
        while IFS=$'\t' read -r name proto listen lport target tport; do
            [[ -n $name && $name != \#* ]] || continue
            printf '%-18s %-6s %-25s %-25s\n' "$name" "$proto" "$listen:$lport" "$target:$tport"
        done < "$RULES_FILE"
    fi
    printf '\n==== 当前 GOST 全部服务（含手工规则）====\n'
    if [[ -f $CONFIG_FILE ]]; then
        if command -v gost >/dev/null || [[ -x $BIN_TARGET ]]; then
            local bin
            bin=$(find_gost)
            if "$bin" -C "$CONFIG_FILE" -O json 2>/dev/null | python3 -c '
import sys, json
cfg=json.load(sys.stdin)
for s in cfg.get("services",[]) or []:
    typ=((s.get("listener") or {}).get("type") or "?").upper()
    targets=", ".join(str(n.get("addr", "?")) for n in ((s.get("forwarder") or {}).get("nodes") or []))
    print("- {}  {}  {} -> {}".format(s.get("name", "?"), typ, s.get("addr", "?"), targets or "(非端口转发服务)"))
' ; then
                return
            fi
        fi
        grep -E '^[[:space:]]*(- name:|addr:)' "$CONFIG_FILE" || true
    fi
}

check_conflicts() {
    local host=$1 port=$2 proto=$3 bin
    bin=$(find_gost)
    "$bin" -C "$CONFIG_FILE" -O json 2>/dev/null | python3 -c '
import sys, json
host, port, proto = sys.argv[1:]
services=(json.load(sys.stdin).get("services") or [])
def split_addr(s):
    h, sep, p = str(s).rpartition(":")
    return (h.strip("[]"),p) if sep else ("","")
def clashing(h1,h2):
    wild={"", "0.0.0.0", "::", "[::]"}
    return h1==h2 or h1 in wild or h2 in wild
for s in services:
    listening=(s.get("listener") or {}).get("type") or "tcp"
    if listening != proto and proto != "both":
        continue
    h,p=split_addr(s.get("addr",""))
    if p==port and clashing(h,host):
        print("与现有服务端口冲突："+str(s.get("name")),file=sys.stderr)
        sys.exit(3)
' "$host" "$port" "$proto"
}

add_rule() {
    local name listen port target target_port proto choice default_ip staged
    require_gost
    ensure_files
    printf '\n新增本地端口转发（TCP/UDP 由洛杉矶服务器重新向目标建立连接）\n'
    read -r -p '规则名（英文字母、数字、_、-；例 hawaii-web）：' name
    [[ $name =~ ^[a-zA-Z0-9_-]{1,48}$ ]] || die '规则名不合法。'
    if grep -Eq "^${name}"$'\t' "$RULES_FILE"; then
        die "规则 $name 已经存在，请换一个名称。"
    fi
    default_ip=$(ip -o -4 address show 2>/dev/null | awk '{split($4,a,"/"); if (a[1] ~ /^100\.66\./) {print a[1];exit}}' || true)
    default_ip=${default_ip:-127.0.0.1}
    read -r -p "监听 IP（默认 $default_ip；可填 100.66.0.60，不建议公网 0.0.0.0）：" listen
    listen=${listen:-$default_ip}
    valid_host "$listen" || die '监听 IP/地址格式不合法。'
    if [[ $listen == 0.0.0.0 || $listen == '::' || $listen == '[::]' ]]; then
        ask_yes '将监听所有网络接口，可能暴露公网端口，确定吗？' || { info '已取消。'; return; }
    fi
    read -r -p '监听端口（1-65535）：' port
    valid_port "$port" || die '监听端口无效。'
    read -r -p '目标 IP 或域名（例 100.66.0.62）：' target
    valid_host "$target" || die '目标地址格式不合法。'
    read -r -p "目标端口（默认 $port）：" target_port
    target_port=${target_port:-$port}
    valid_port "$target_port" || die '目标端口无效。'
    printf '协议：1) TCP  2) UDP  3) TCP+UDP\n'
    read -r -p '请选择 [1/2/3]：' choice
    case $choice in
        1) proto=tcp ;;
        2) proto=udp ;;
        3) proto=both ;;
        *) die '协议选择无效。' ;;
    esac
    # A paired protocol can share a port, but within each protocol the address must be free.
    if [[ $proto == both ]]; then
        check_conflicts "$listen" "$port" tcp || die 'TCP 监听冲突。'
        check_conflicts "$listen" "$port" udp || die 'UDP 监听冲突。'
    else
        check_conflicts "$listen" "$port" "$proto" || die '监听冲突或无法读取原有配置。'
    fi
    printf '\n确认新增：%s [%s] %s:%s -> %s:%s\n' "$name" "$proto" "$listen" "$port" "$target" "$target_port"
    ask_yes '确认保存并热加载？' || { info '已取消。'; return; }
    staged="$WORK_DIR/rules-new.tsv"
    cp "$RULES_FILE" "$staged"
    printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$name" "$proto" "$listen" "$port" "$target" "$target_port" >>"$staged"
    apply_staged_rules "$staged"
}

remove_rule() {
    local name staged
    ensure_files
    list_rules
    [[ -s $RULES_FILE ]] || return 0
    read -r -p '输入要删除的管理器规则名（手写规则不会删除）：' name
    [[ $name =~ ^[a-zA-Z0-9_-]{1,48}$ ]] || die '规则名无效。'
    grep -Eq "^${name}"$'\t' "$RULES_FILE" || die "找不到管理器规则：$name"
    ask_yes "确认删除 $name？" || { info '已取消。'; return; }
    staged="$WORK_DIR/rules-after-delete.tsv"
    awk -F '\t' -v target="$name" '$1 != target' "$RULES_FILE" >"$staged"
    apply_staged_rules "$staged"
}

status() {
    local bin
    bin=$(find_gost)
    if [[ -n $bin ]]; then
        "$bin" -V || true
    else
        warn 'GOST 尚未安装。'
    fi
    systemctl --no-pager --full status gost || true
    printf '\nTCP / UDP 监听：\n'
    ss -lntup 2>/dev/null | grep -E 'gost|State' || true
}

show_backups() {
    if [[ -d $BACKUP_DIR ]]; then
        find "$BACKUP_DIR" -mindepth 1 -maxdepth 1 -type d ! -name binaries -printf '%f\n' | sort -r | head -n 15
    else
        printf '暂无备份。\n'
    fi
}

restore_backup() {
    local stamp src now
    show_backups
    read -r -p '输入要恢复的备份编号：' stamp
    [[ $stamp =~ ^[0-9]{8}T[0-9]{6}\.[0-9]{9}$ ]] || die '备份编号格式错误。'
    src="$BACKUP_DIR/$stamp"
    [[ -f $src/gost.yml && -f $src/gost-manager.rules ]] || die '备份文件不完整。'
    validate_config "$src/gost.yml"
    ask_yes "确认恢复 $stamp 并热加载？" || return 0
    now=$(snapshot)
    cp -p "$src/gost.yml" "$CONFIG_FILE"
    cp -p "$src/gost-manager.rules" "$RULES_FILE"
    if ! reload_service; then
        cp -p "$now/gost.yml" "$CONFIG_FILE"
        cp -p "$now/gost-manager.rules" "$RULES_FILE"
        systemctl reload gost || true
        die '恢复操作失败，已尝试回滚。'
    fi
    ok "已恢复备份：$stamp"
}

menu() {
    local choice
    while true; do
        cat <<'MENU'

========== GOST v3 管理 ==========
  1) 安装/更新 GOST 官方稳定版
  2) 安装/启用 systemd 服务（保留原配置）
  3) 新增 TCP / UDP / 双协议转发
  4) 删除本脚本创建的转发规则
  5) 查看全部转发规则
  6) 校验配置并热加载
  7) 查看 GOST 状态和监听端口
  8) 实时查看日志
  9) 重启 GOST 服务（将中断连接）
 10) 查看配置备份 / 恢复备份
  0) 退出
=================================
MENU
        read -r -p '选择操作：' choice || break
        case $choice in
            1) install_binary ;;
            2) install_service ;;
            3) add_rule ;;
            4) remove_rule ;;
            5) list_rules ;;
            6) reload_service ;;
            7) status ;;
            8) journalctl -u gost -f -n 30 || true ;;
            9) if ask_yes '确定重启？现有连接将被断开。'; then systemctl restart gost; fi ;;
            10) restore_backup ;;
            0) break ;;
            *) warn '无效选项。' ;;
        esac
    done
}

case ${1:-} in
    --install) install_binary; install_service ;;
    --list) list_rules ;;
    --status) status ;;
    --reload) reload_service ;;
    '') menu ;;
    *) usage; exit 2 ;;
esac