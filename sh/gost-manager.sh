#!/usr/bin/env bash
# GOST v3 one-click installer and TCP/UDP forwarding manager (Debian/Ubuntu + systemd).
# Repository: https://github.com/ggfvictor/static-files/tree/main/sh
# Usage: bash <(curl -fsSL https://raw.githubusercontent.com/ggfvictor/static-files/main/sh/gost-manager.sh)
# Run as root. Existing manually written YAML services are not removed by this tool.
set -Eeuo pipefail
umask 077

# Version of this management script (independent from the installed GOST binary version).
SCRIPT_VERSION="1.4.2"

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
    printf 'GOST 管理器 v%s\n' "$SCRIPT_VERSION"
    cat <<'HELP'
GOST v3 安装及 TCP/UDP 转发管理（Debian/Ubuntu + systemd）
用法：sudo bash gost-manager.sh [--install|--list|--status|--reload|--version|--help]
不带参数：显示本机服务状态，按规则管理、服务管理和维护诊断分组。

规则管理：查看、新增、修改、删除 TCP/UDP 转发；动态读取本机监听地址、校验本机 IP 和端口冲突。
通用部署：不预设服务器地区、运营商或 VPN 网段；所有目标由用户自行填写。
安全设计：下载官方最新稳定版本，校验 SHA256；修改前备份配置；
          通过 SIGHUP 热加载；不覆盖现有 systemd 服务文件或手工规则。
配置位置：/etc/gost/gost.yml
规则记录：/etc/gost/gost-manager.rules
备份目录：/var/backups/gost-manager
HELP
}

[[ ${1:-} == --help || ${1:-} == -h ]] && { usage; exit 0; }
[[ ${1:-} == --version || ${1:-} == -v ]] && { printf 'gost-manager v%s\n' "$SCRIPT_VERSION"; exit 0; }
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

# 官方 v3.3.3 的 `-V` 输出是 `gost 3.3.3 (go... linux/amd64)`，没有 v 前缀。
# 单独解析版本，供安装校验、版本检查和状态展示共用。
get_gost_version() {
    local output
    output=$("$1" -V 2>&1) || return 1
    if [[ $output =~ ^gost[[:space:]]+v?([0-9]+\.[0-9]+\.[0-9]+)([+.-][^[:space:]]+)?([[:space:]]|$) ]]; then
        printf '%s\n' "${BASH_REMATCH[1]}"
    else
        return 1
    fi
}

require_gost() {
    local installed_version
    GOST_BIN=$(find_gost)
    [[ -n $GOST_BIN && -x $GOST_BIN ]] || die '尚未安装 GOST，请在「服务管理」中选择安装 GOST。'
    installed_version=$(get_gost_version "$GOST_BIN") || die "无法识别 GOST 版本：$GOST_BIN，请检查 gost -V。"
    [[ $installed_version == 3.* ]] || die "当前 GOST 版本为 $installed_version，不是 v3，请先升级。"
}

# 仅查询状态，不修改系统配置；每次重新显示菜单时刷新。
# 仅在交互式终端显示 ANSI 颜色；管道/重定向或 NO_COLOR 时输出纯文本。
status_value() {
    local color=$1 value=$2 prefix='' suffix=''
    if [[ -t 1 && -z ${NO_COLOR:-} && ${TERM:-dumb} != dumb ]]; then
        case $color in
            green)  prefix=$'\033[32m' ;;
            red)    prefix=$'\033[31m' ;;
            yellow) prefix=$'\033[33m' ;;
            cyan)   prefix=$'\033[36m' ;;
        esac
        [[ -z $prefix ]] || suffix=$'\033[0m'
    fi
    printf '%s%s%s' "$prefix" "$value" "$suffix"
}

status_field() {
    printf '%s：' "$1"
    status_value "$2" "$3"
    printf '\n'
}

# Both manual and manager-created services contribute to the total service count.
# Parsing via GOST ensures that multiline YAML and hand-written rules are counted correctly.
get_service_count() {
    local bin=$1 count
    if [[ ! -f $CONFIG_FILE || -z $bin ]]; then
        printf '%s' '--'
        return 0
    fi
    if count=$("$bin" -C "$CONFIG_FILE" -O json 2>/dev/null | python3 -c '
import json, sys
try:
    data = json.load(sys.stdin)
    print(len(data.get("services") or []))
except Exception:
    sys.exit(1)
' 2>/dev/null); then
        printf '%s' "$count"
    else
        printf '%s' '?'
    fi
}

show_brief_status() {
    local bin ver gtext gcolor unit_state service_text service_color
    local enabled active pid auto_text auto_color conf_text conf_color
    local managed_count total_count host_label
    bin=$(find_gost)
    if [[ -n $bin && -x $bin ]]; then
        if ver=$(get_gost_version "$bin"); then
            gtext="已安装 v$ver"; gcolor=green
        else
            gtext='版本无法识别'; gcolor=yellow
        fi
    else
        gtext='未安装'; gcolor=red
    fi

    unit_state=$(systemctl show gost.service -p LoadState --value 2>/dev/null || true)
    if [[ -z $unit_state || $unit_state == not-found ]]; then
        service_text='未安装'; service_color=red
        auto_text='未启用'; auto_color=red
    else
        active=$(systemctl is-active gost.service 2>/dev/null || true)
        case $active in
            active)
                pid=$(systemctl show gost.service -p MainPID --value 2>/dev/null || true)
                service_text='运行中'
                [[ $pid =~ ^[1-9][0-9]*$ ]] && service_text="运行中 (PID $pid)"
                service_color=green ;;
            failed|inactive)
                service_text="未运行 ($active)"; service_color=red ;;
            *) service_text="待就绪 (${active:-unknown})"; service_color=yellow ;;
        esac
        [[ $unit_state == loaded ]] || { service_text="systemd ${unit_state}"; service_color=yellow; }
        enabled=$(systemctl is-enabled gost.service 2>/dev/null || true)
        case $enabled in
            enabled) auto_text='已启用'; auto_color=green ;;
            disabled|masked) auto_text="未启用 ($enabled)"; auto_color=red ;;
            *) auto_text="其他状态 (${enabled:-unknown})"; auto_color=yellow ;;
        esac
    fi
    if [[ -f $CONFIG_FILE ]]; then
        conf_text='已存在'; conf_color=green
    else
        conf_text='未创建'; conf_color=yellow
    fi
    managed_count=0
    if [[ -f $RULES_FILE ]]; then
        managed_count=$(awk -F '\t' 'NF == 6 && $1 !~ /^#/ {n++} END {print n+0}' "$RULES_FILE" 2>/dev/null) || managed_count='?'
    fi
    total_count=$(get_service_count "$bin")
    host_label=$(hostname -s 2>/dev/null || true)
    # 同宽标签：GOST（4 列）与两字中文标签（4 列）天然对齐，无需计算字符宽度。
    printf '\n  GOST Manager  v%s\n' "$SCRIPT_VERSION"
    printf '  ------------------------------------------\n'
    [[ -z $host_label ]] || printf '  主机  %s\n' "$host_label"
    printf '  GOST  '; status_value "$gcolor" "$gtext"; printf '\n'
    printf '  服务  '; status_value "$service_color" "$service_text"; printf '\n'
    printf '  自启  '; status_value "$auto_color" "$auto_text"; printf '\n'
    printf '  配置  '; status_value "$conf_color" "$conf_text"; printf '\n'
    printf '  规则  '; status_value cyan "${total_count} 个服务 / ${managed_count} 组管理器规则"; printf '\n'
    printf '  ------------------------------------------\n'
}

ensure_files() {
    mkdir -p "$CONFIG_DIR"
    if [[ ! -f $CONFIG_FILE ]]; then
        printf 'services: []\n' >"$CONFIG_FILE"
        chmod 600 "$CONFIG_FILE"
        info "已创建空配置文件 $CONFIG_FILE"
    fi
    if [[ ! -e $RULES_FILE ]]; then
        # Never regenerate an empty rule database over a YAML file that already
        # contains managed services (e.g. when migrating only gost.yml).
        if [[ -f $CONFIG_FILE ]] && grep -Fq -- "$MARK_START" "$CONFIG_FILE"; then
            die "检测到已有管理器生成的规则，但缺少 $RULES_FILE。请从原服务器或备份恢复规则索引，已拒绝操作以免丢失规则。"
        fi
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
    local detected_version
    detected_version=$(get_gost_version "$bin_dir") || die '下载程序无法执行或版本输出无法识别。'
    [[ $detected_version == "$version" ]] || die "下载程序版本不符：预期 $version，实际 $detected_version。"
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
    python3 - "$CONFIG_FILE" "$rules" "$output" "$RULES_FILE" <<'PY'
import json, pathlib, re, sys
src, rules_file, dest, original_db = map(pathlib.Path, sys.argv[1:])
start = '  # >>> GOST-MANAGER managed services >>>'
end = '  # <<< GOST-MANAGER managed services <<<'
lines = src.read_text(encoding='utf-8').splitlines(keepends=True)
begins = [i for i, x in enumerate(lines) if x.rstrip('\r\n') == start]
ends = [i for i, x in enumerate(lines) if x.rstrip('\r\n') == end]
if len(begins) != len(ends) or len(begins) > 1 or (begins and begins[0] >= ends[0]):
    sys.exit('错误：YAML 内的 GOST-MANAGER 标记异常，拒绝自动编辑。')
if begins:
    # The managed block must agree with the rule index BEFORE rewriting it.
    # In particular, a missing/empty/partial index after migrating servers
    # must never silently erase an existing managed forward.
    def recorded_services(path):
        names = []
        for row in path.read_text(encoding='utf-8').splitlines():
            if not row or row.startswith('#'):
                continue
            parts = row.split(chr(9))
            if len(parts) != 6 or parts[1] not in ('tcp', 'udp', 'both'):
                sys.exit('错误：管理器规则索引损坏，请先恢复备份。')
            name, proto = parts[0], parts[1]
            if not re.fullmatch(r'[a-zA-Z0-9_-]{1,48}', name):
                sys.exit('错误：规则索引包含非法名称。')
            for p in ('tcp', 'udp') if proto == 'both' else (proto,):
                names.append(f'gm-{name}-{p}')
        return sorted(names)

    old_block = lines[begins[0]+1:ends[0]]
    old_names = []
    for entry in old_block:
        match = re.match(r"""^  - name:\s*['"]?([A-Za-z0-9_-]+)['"]?\s*(?:#.*)?$""", entry.rstrip())
        if match:
            old_names.append(match.group(1))
    if sorted(old_names) != recorded_services(original_db):
        sys.exit('错误：当前 YAML 中的管理器服务与规则索引不一致。'
                 '请从同一次备份恢复 gost.yml 与 gost-manager.rules；本次不会覆盖旧规则。')
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

# A running systemd unit must actually read the YAML that we edit.
# This prevents successful-looking reloads that affect a different GOST instance.
check_service_config_path() {
    local execstart
    if systemctl is-active --quiet gost.service; then
        execstart=$(systemctl show gost.service -p ExecStart --value 2>/dev/null || true)
        if [[ $execstart != *"$CONFIG_FILE"* ]]; then
            die "运行中的 gost.service 未明确使用 $CONFIG_FILE；为避免修改错误实例，已停止操作。请检查 systemctl cat gost。"
        fi
    fi
}

reload_service() {
    check_service_config_path
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
    check_service_config_path
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
    local host=$1 port=$2 proto=$3 exclude_rule=${4:-} bin
    bin=$(find_gost)
    "$bin" -C "$CONFIG_FILE" -O json 2>/dev/null | python3 -c '
import sys, json
host, port, proto, exclude_rule = sys.argv[1:]
ignored = {"gm-" + exclude_rule + "-tcp", "gm-" + exclude_rule + "-udp"} if exclude_rule else set()
services=(json.load(sys.stdin).get("services") or [])
def split_addr(s):
    h, sep, p = str(s).rpartition(":")
    return (h.strip("[]"),p) if sep else ("","")
def clashing(h1,h2):
    wild={"", "0.0.0.0", "::", "[::]"}
    return h1==h2 or h1 in wild or h2 in wild
for s in services:
    if s.get("name") in ignored:
        continue
    listening=(s.get("listener") or {}).get("type") or "tcp"
    if listening != proto and proto != "both":
        continue
    h,p=split_addr(s.get("addr",""))
    if p==port and clashing(h,host):
        print("与现有服务端口冲突："+str(s.get("name")),file=sys.stderr)
        sys.exit(3)
' "$host" "$port" "$proto" "$exclude_rule"
}

# List real interface addresses on the host currently running the script.
# Neither a cloud provider nor a VPN subnet is assumed. Default binding is
# localhost so pressing Enter never accidentally exposes a service publicly.
select_listen_address() {
    local choice interface address index
    local -a addresses=() interfaces=()
    if command -v ip >/dev/null 2>&1; then
        while IFS=$'\t' read -r interface address; do
            [[ -n ${address:-} ]] || continue
            interfaces+=("$interface")
            addresses+=("$address")
        done < <(
            {
                ip -o -4 addr show scope global 2>/dev/null |
                    awk '{split($4, a, "/"); print $2 "\t" a[1]}'
                ip -o -6 addr show scope global 2>/dev/null |
                    awk '{split($4, a, "/"); print $2 "\t[" a[1] "]"}'
            } | sort -u
        )
    fi
    printf '\n当前服务器的可用监听地址：\n'
    for ((index = 0; index < ${#addresses[@]}; index++)); do
        printf '  %2d) %-42s  (%s)\n' "$((index+1))" "${addresses[index]}" "${interfaces[index]}"
    done
    printf '   0) 127.0.0.1  (仅当前服务器访问)\n'
    if (( ${#addresses[@]} == 0 )); then
        warn '未自动检测到网卡地址，可直接手动输入本机监听 IP。'
    fi
    printf '提示：可以选择编号，也可以直接输入任意本机 IP；公网及全接口监听会二次确认。\n'
    read -r -p '选择编号或输入监听 IP（回车默认 127.0.0.1）：' choice || return 1
    if [[ -z $choice || $choice == 0 ]]; then
        LISTEN_ADDRESS=127.0.0.1
    elif [[ $choice =~ ^[0-9]+$ ]]; then
        index=$((10#$choice))
        if ((index < 1 || index > ${#addresses[@]})); then
            die "监听地址编号无效：$choice"
        fi
        LISTEN_ADDRESS="${addresses[index-1]}"
    else
        LISTEN_ADDRESS=$choice
    fi
    return 0
}

# Validate manually chosen literal bind addresses against the current host.
# This prevents copying a private IP from a different machine and getting a bind failure.
# Wildcard/loopback addresses are allowed; non-IP hostnames retain GOST's own resolution rules.
validate_local_listener() {
    local host=$1 result=0
    if ! command -v ip >/dev/null 2>&1; then
        warn '系统没有 ip 命令，无法核对监听地址是否属于本机。'
        return 0
    fi
    python3 - "$host" <<'PY' || result=$?
import ipaddress, re, subprocess, sys
host = sys.argv[1].strip("[]")
try:
    selected = ipaddress.ip_address(host)
except ValueError:
    # A hostname may resolve locally and is checked by GOST when binding.
    sys.exit(0)
if selected.is_unspecified or selected.is_loopback:
    sys.exit(0)
try:
    result = subprocess.run(["ip", "-o", "addr", "show"], text=True,
                            capture_output=True, check=True)
except (OSError, subprocess.CalledProcessError):
    sys.exit(3)
for match in re.finditer(r"\binet6?\s+([0-9a-fA-F:.]+)/[0-9]+", result.stdout):
    try:
        if ipaddress.ip_address(match.group(1)) == selected:
            sys.exit(0)
    except ValueError:
        pass
sys.exit(2)
PY
    case $result in
        0) return 0 ;;
        2) die "监听地址 $host 不属于当前服务器。请从本机地址列表选择，或使用 127.0.0.1 / 0.0.0.0。";;
        3) warn '无法获取本机 IP 地址，跳过监听地址归属检查。' ;;
        *) die "监听地址检查发生异常（退出码 $result）。" ;;
    esac
}

# Manual edits must not silently mutate the section controlled by the rule index.
# That section can only be changed through add/edit/remove manager operations.
managed_block_unchanged() {
    local before=$1 after=$2
    python3 - "$before" "$after" <<'PY'
from pathlib import Path
import sys
start = "  # >>> GOST-MANAGER managed services >>>"
end = "  # <<< GOST-MANAGER managed services <<<"
def block(path):
    lines = Path(path).read_text(encoding="utf-8").splitlines()
    a = [i for i, line in enumerate(lines) if line == start]
    b = [i for i, line in enumerate(lines) if line == end]
    if not a and not b:
        return None
    if len(a) != 1 or len(b) != 1 or a[0] >= b[0]:
        raise ValueError("invalid managed section boundaries")
    return lines[a[0]:b[0]+1]
try:
    sys.exit(0 if block(sys.argv[1]) == block(sys.argv[2]) else 1)
except (ValueError, UnicodeError, OSError):
    sys.exit(1)
PY
}

# Warn before binding to all interfaces or a globally routable address.
# RFC1918, CGNAT, loopback, and ULA addresses are not treated as globally routable.
confirm_listener_exposure() {
    local host=$1 classification
    classification=$(python3 - "$host" <<'PY'
import ipaddress, sys
try:
    address = ipaddress.ip_address(sys.argv[1].strip('[]'))
except ValueError:
    print("hostname")
else:
    if address.is_unspecified:
        print("all")
    elif address.is_global:
        print("public")
    else:
        print("restricted")
PY
) || return 1
    case $classification in
        all) ask_yes "监听 $host 将开放所有网卡，可能暴露公网，确认继续？" ;;
        public) ask_yes "监听 $host 是公网地址，请确认防火墙访问控制，继续？" ;;
        hostname) warn "监听地址 $host 不是 IP 字面量；请确认该名称解析为本机地址。" ;;
    esac
}

add_rule() {
    local name listen port target target_port proto choice staged
    require_gost
    ensure_files
    printf '\n新增端口转发：当前服务器监听指定端口，并把流量转发到你填写的目标主机。\n'
    read -r -p '规则名称（字母、数字、_、-；例如 web-forward）：' name
    [[ $name =~ ^[a-zA-Z0-9_-]{1,48}$ ]] || die '规则名不合法。'
    if grep -Eq "^${name}"$'\t' "$RULES_FILE"; then
        die "规则 $name 已经存在，请换一个名称。"
    fi
    select_listen_address || return 0
    listen=$LISTEN_ADDRESS
    valid_host "$listen" || die '监听 IP 格式不合法；IPv6 请使用 [地址] 格式。'
    validate_local_listener "$listen"
    confirm_listener_exposure "$listen" || { info '已取消。'; return; }
    read -r -p '监听端口（1-65535）：' port
    valid_port "$port" || die '监听端口无效。'
    read -r -p '转发目标 IP 或域名（IPv6 请用 [地址] 格式）：' target
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

# Manual YAML editor for existing services not created by this manager.
# Back up before editing, validate before reloading, and restore on errors.
edit_manual_yaml() {
    local editor backup bin
    require_gost
    ensure_files
    if command -v nano >/dev/null 2>&1; then
        editor=$(command -v nano)
    elif command -v vi >/dev/null 2>&1; then
        editor=$(command -v vi)
    else
        die '找不到 nano 或 vi；请先安装文本编辑器。'
    fi
    warn '手工编辑模式将打开整个 gost.yml。'
    warn '不要修改 # >>> GOST-MANAGER ... # <<< GOST-MANAGER 管理区；该区会在下一次管理器操作时重新生成。'
    ask_yes '已了解，继续编辑？' || { info '已取消。'; return; }
    backup=$(snapshot)
    info "修改前备份：$backup"
    if ! "$editor" "$CONFIG_FILE"; then
        cp -p "$backup/gost.yml" "$CONFIG_FILE"
        die '编辑器异常退出，已恢复修改前配置。'
    fi
    if cmp -s "$backup/gost.yml" "$CONFIG_FILE"; then
        info '配置没有变化，无需热加载。'
        return 0
    fi
    if ! managed_block_unchanged "$backup/gost.yml" "$CONFIG_FILE"; then
        cp -p "$backup/gost.yml" "$CONFIG_FILE"
        die '管理器自动生成的规则区发生变化，已恢复原文件。请通过规则管理菜单修改该区域。'
    fi
    bin=$(find_gost)
    if ! "$bin" -C "$CONFIG_FILE" -O yaml >"$WORK_DIR/manual-check.out" 2>"$WORK_DIR/manual-check.err"; then
        cat "$WORK_DIR/manual-check.err" >&2
        cp -p "$backup/gost.yml" "$CONFIG_FILE"
        die 'YAML 配置校验失败，已恢复原配置。'
    fi
    if ! reload_service; then
        cp -p "$backup/gost.yml" "$CONFIG_FILE"
        systemctl reload gost || true
        die '热加载失败，已恢复原配置；请检查日志。'
    fi
    ok '手工配置已保存。'
}

edit_rule() {
    local mode choice old_name old_row old_proto old_listen old_port old_target old_target_port
    local name proto listen port target target_port input staged
    require_gost
    ensure_files
    printf '\n修改现有转发规则\n  1) 修改脚本创建的规则（逐项修改，回车保留原值）\n  2) 修改手工规则（编辑 YAML，自动备份与校验）\n  0) 返回\n'
    read -r -p '请选择 [1/2/0]：' mode || return 0
    case $mode in
        1) ;;
        2) edit_manual_yaml; return ;;
        0|'') info '已取消。'; return ;;
        *) die '无效选项。' ;;
    esac
    if [[ ! -s $RULES_FILE ]]; then
        warn '暂无脚本创建的规则；如果是原来手工写入的服务，请选择手工 YAML 编辑模式。'
        return 0
    fi
    printf '\n当前可修改规则：\n'
    awk -F '\t' 'NF == 6 && $1 !~ /^#/ {i++; printf " %2d) %-20s %-5s %s:%s -> %s:%s\n", i, $1, $2, $3, $4, $5, $6}' "$RULES_FILE"
    read -r -p '输入规则编号或规则名（0 返回）：' choice || return 0
    [[ $choice != 0 && -n $choice ]] || return 0
    if [[ $choice =~ ^[0-9]+$ ]]; then
        old_name=$(awk -F '\t' -v n="$choice" 'NF == 6 && $1 !~ /^#/ {i++; if (i == n) {print $1; exit}}' "$RULES_FILE")
    else
        old_name=$choice
    fi
    [[ $old_name =~ ^[a-zA-Z0-9_-]{1,48}$ ]] || die '找不到有效的规则名。'
    old_row=$(awk -F '\t' -v n="$old_name" '$1 == n {print; exit}' "$RULES_FILE")
    [[ -n $old_row ]] || die "规则不存在：$old_name。手工规则请使用菜单 2。"
    IFS=$'\t' read -r _ old_proto old_listen old_port old_target old_target_port <<< "$old_row"
    printf '\n当前配置：%s [%s] %s:%s -> %s:%s\n' "$old_name" "$old_proto" "$old_listen" "$old_port" "$old_target" "$old_target_port"
    printf '直接回车保留原值。\n'

    read -r -p "规则名称 [$old_name]：" input || return 0
    name=${input:-$old_name}
    [[ $name =~ ^[a-zA-Z0-9_-]{1,48}$ ]] || die '规则名无效。'
    if [[ $name != "$old_name" ]] && cut -f1 "$RULES_FILE" | grep -Fxq -- "$name"; then
        die "规则名 $name 已存在。"
    fi

    printf '可用网卡监听地址（修改时可手动输入）：\n'
    if command -v ip >/dev/null 2>&1; then
        ip -o -4 addr show scope global 2>/dev/null | awk '{split($4,a,"/"); print "  " $2 "  " a[1]}' || true
        ip -o -6 addr show scope global 2>/dev/null | awk '{split($4,a,"/"); print "  " $2 "  [" a[1] "]"}' || true
    fi
    read -r -p "监听 IP [$old_listen]：" input || return 0
    listen=${input:-$old_listen}
    valid_host "$listen" || die '监听地址格式不合法；IPv6 请使用 [地址] 格式。'
    if [[ $listen != "$old_listen" ]]; then
        validate_local_listener "$listen"
        confirm_listener_exposure "$listen" || { info '已取消。'; return; }
    fi

    read -r -p "监听端口 [$old_port]：" input || return 0
    port=${input:-$old_port}
    valid_port "$port" || die '监听端口无效。'

    read -r -p "转发目标 IP 或域名 [$old_target]：" input || return 0
    target=${input:-$old_target}
    valid_host "$target" || die '目标地址格式不合法。'

    read -r -p "目标端口 [$old_target_port]：" input || return 0
    target_port=${input:-$old_target_port}
    valid_port "$target_port" || die '目标端口无效。'

    read -r -p "协议 [tcp/udp/both] (当前 $old_proto，回车保留)：" input || return 0
    case ${input:-$old_proto} in
        1|tcp|TCP) proto=tcp ;;
        2|udp|UDP) proto=udp ;;
        3|both|BOTH) proto=both ;;
        *) die '协议无效，只能是 tcp、udp 或 both。' ;;
    esac

    # Ignore the old manager-owned service(s) while checking the candidate ports.
    if [[ $proto == both ]]; then
        check_conflicts "$listen" "$port" tcp "$old_name" || die '新 TCP 监听与现有规则冲突。'
        check_conflicts "$listen" "$port" udp "$old_name" || die '新 UDP 监听与现有规则冲突。'
    else
        check_conflicts "$listen" "$port" "$proto" "$old_name" || die '新监听与现有规则冲突。'
    fi

    if [[ $name == "$old_name" && $proto == "$old_proto" && $listen == "$old_listen" && $port == "$old_port" && $target == "$old_target" && $target_port == "$old_target_port" ]]; then
        info '规则未发生变化，无需热加载。'
        return 0
    fi
    printf '\n变更前：%s [%s] %s:%s -> %s:%s\n' "$old_name" "$old_proto" "$old_listen" "$old_port" "$old_target" "$old_target_port"
    printf '变更后：%s [%s] %s:%s -> %s:%s\n' "$name" "$proto" "$listen" "$port" "$target" "$target_port"
    ask_yes '确定保存并热加载吗？' || { info '已取消。'; return; }

    staged="$WORK_DIR/rules-edit.tsv"
    awk -F '\t' -v OFS='\t' -v old="$old_name" -v new="$name" -v p="$proto" -v a="$listen" -v lp="$port" -v dest="$target" -v rp="$target_port" '
        $1 == old { $1 = new; $2 = p; $3 = a; $4 = lp; $5 = dest; $6 = rp }
        { print }
    ' "$RULES_FILE" >"$staged"
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
    show_brief_status
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

# Redraw inside the same terminal viewport. No escape sequences when output is redirected.
refresh_screen() {
    if [[ -t 1 && ${TERM:-dumb} != dumb && -z ${NO_CLEAR:-} ]]; then
        printf '\033[H\033[2J'
    fi
}

# A command gets its own screen. After it finishes, retain its output until Enter.
# Run the action in a subshell so die/exit does not close the interactive manager.
run_menu_action() {
    local title=$1 result=0
    shift
    refresh_screen
    printf '========== %s | gost-manager v%s ==========\n\n' "$title" "$SCRIPT_VERSION"
    # Invoke the subshell as a simple command, not an if test:
    # this preserves errexit inside install/configuration functions.
    set +e
    ( set -Eeuo pipefail; "$@" )
    result=$?
    set -e
    if (( result != 0 )); then
        warn "操作未完成（退出码 $result），请查看上方提示。"
    fi
    if [[ -t 0 ]]; then
        printf '\n'
        read -r -p '按 Enter 返回主菜单...' _ || true
    fi
}

restart_service_interactive() {
    if ask_yes '确定重启 GOST？现有连接将被断开。'; then
        systemctl restart gost
        ok 'GOST 已重启。'
    else
        info '已取消重启。'
    fi
}

show_live_logs() {
    printf '实时日志（按 Ctrl+C 停止查看并返回菜单）\n\n'
    # Trap SIGINT in this subshell so Ctrl+C stops journalctl, not the menu.
    trap ':' INT
    journalctl -u gost -f -n 30 || true
    trap - INT
}

# Match the two-space left edge of the dashboard and separator.
# Menu descriptions use fixed-width numeric prefixes to align after both 1- and 2-digit choices.
print_menu_heading() {
    printf '\n  '
    status_value cyan "$1"
    printf '\n'
}

menu() {
    local choice
    while true; do
        refresh_screen
        show_brief_status
        print_menu_heading '[ 转发规则 ]'
        cat <<'MENU'
  1)  查看全部转发规则
  2)  新增 TCP/UDP 规则
  3)  修改现有转发规则
  4)  删除管理器规则
  5)  校验配置并热加载
MENU
        print_menu_heading '[ 服务管理 ]'
        cat <<'MENU'
  6)  安装/更新 GOST
  7)  安装/启用 systemd
  8)  重启 GOST 服务
MENU
        print_menu_heading '[ 诊断与维护 ]'
        cat <<'MENU'
  9)  查看详细状态与端口
  10) 实时查看日志
  11) 查看备份/恢复配置
MENU
        printf '  ------------------------------------------\n'
        printf '  0)  退出\n\n'
        read -r -p '  请选择编号 [0-11]：' choice || break
        case $choice in
            1) run_menu_action '查看全部转发规则' list_rules ;;
            2) run_menu_action '新增 TCP/UDP 转发' add_rule ;;
            3) run_menu_action '修改现有转发规则' edit_rule ;;
            4) run_menu_action '删除转发规则' remove_rule ;;
            5) run_menu_action '校验配置并热加载' reload_service ;;
            6) run_menu_action '安装/更新 GOST' install_binary ;;
            7) run_menu_action '安装/启用 systemd' install_service ;;
            8) run_menu_action '重启 GOST 服务' restart_service_interactive ;;
            9) run_menu_action '查看详细状态' status ;;
            10) run_menu_action '实时查看日志' show_live_logs ;;
            11) run_menu_action '查看备份/恢复配置' restore_backup ;;
            0) refresh_screen; info '已退出 GOST 管理器。'; break ;;
            *) run_menu_action '无效选项' warn '请输入 0-11 之间的菜单编号。' ;;
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