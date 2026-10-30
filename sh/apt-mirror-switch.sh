#!/usr/bin/env bash
# Debian / Ubuntu APT 国内 / 国际镜像切换工具。需要 Bash 3.2+，不适用于 sh。
set -Eeuo pipefail
export LC_ALL=C
umask 077

OS_RELEASE_FILE=/etc/os-release
APT_DIR=/etc/apt
BACKUP_DIR=/var/backups/apt-mirror-switch
KEYRING_DIR=/usr/share/keyrings
LOCK_FILE=/run/lock/apt-mirror-switch.lock
MARKER='# Managed by apt-mirror-switch v1'

MIRROR=''
REGION=auto
COUNTRY=''
PUBLIC_IP=''
FORMAT=auto
DRY_RUN=0
ASSUME_YES=0
DO_UPDATE=1
RESTORE_ID=''
LIST_BACKUPS=0
WORK_DIR=''
ACTIVE_BACKUP=''
MUTATING=0
WITH_SOURCE=0
PLAN_PATHS=()
PLAN_STATES=()
PLAN_FILES=()
PROBE_PIDS=()

say() { printf '%s\n' "$*"; }
die() { printf '错误：%s\n' "$*" >&2; exit 1; }

usage() {
    cat <<'HELP'
用法：sudo bash apt-mirror-switch.sh [选项]

不带选项时，识别系统、架构和公网出口地区，显示镜像菜单，再确认执行。

  --mirror NAME       auto / ustc / aliyun / tencent / tsinghua / huawei /
                      official / kernel / fau / xtom-us / xtom-jp
  --region REGION     auto（默认，查询公网 IP）/ cn / global
                      auto 镜像模式按地区探测候选，选择索引探测耗时最短的可用站
  --dry-run           预览将写入的源和受影响文件，不改 APT 配置，不更新索引
  --yes, -y           跳过写入前确认（仍需指定 --mirror）
  --no-update         切换后不执行 apt-get update
  --format FORMAT     auto（默认）/ sources（Deb822）/ list（传统格式）
  --restore ID        恢复指定备份，或使用 latest；恢复前也会备份当前配置
  --list-backups      列出备份编号
  --help, -h          显示帮助

示例：
  bash apt-mirror-switch.sh --mirror ustc --dry-run
  bash apt-mirror-switch.sh --mirror auto --dry-run
  sudo bash apt-mirror-switch.sh --mirror auto --yes
  sudo bash apt-mirror-switch.sh --mirror auto --region global --yes
  sudo bash apt-mirror-switch.sh --mirror aliyun --yes
  sudo bash apt-mirror-switch.sh --restore latest

仅支持 ID 为 debian / ubuntu、原生架构为 amd64 / arm64 的 Linux。
保留第三方源；只禁用已识别的发行版源。更新失败会自动恢复配置。
HELP
}

while (($#)); do
    case "$1" in
        --mirror|--format|--restore|--region)
            (($# >= 2)) || die "$1 缺少参数"
            case "$1" in
                --mirror) MIRROR=$2 ;;
                --format) FORMAT=$2 ;;
                --restore) RESTORE_ID=$2 ;;
                --region) REGION=$2 ;;
            esac
            shift 2 ;;
        --dry-run) DRY_RUN=1; shift ;;
        --yes|-y) ASSUME_YES=1; shift ;;
        --no-update) DO_UPDATE=0; shift ;;
        --list-backups) LIST_BACKUPS=1; shift ;;
        --help|-h) usage; exit 0 ;;
        *) die "未知参数：$1（使用 --help 查看用法）" ;;
    esac
done
case "$FORMAT" in auto|sources|list) ;; *) die "不支持的格式：$FORMAT" ;; esac
case "$REGION" in auto|cn|global) ;; *) die "不支持的地区：$REGION（auto / cn / global）" ;; esac
if [[ -n "$RESTORE_ID" ]]; then
    [[ -z "$MIRROR" && "$FORMAT" == auto && "$REGION" == auto && $LIST_BACKUPS == 0 ]] || die '--restore 不能与镜像、格式、地区或列出备份选项混用'
fi
if ((LIST_BACKUPS)); then
    [[ -z "$MIRROR" && -z "$RESTORE_ID" && "$REGION" == auto ]] || die '--list-backups 不能与切换、恢复或地区选项混用'
fi

valid_relative_path() {
    case "$1" in
        sources.list) return 0 ;;
        sources.list.d/*.list|sources.list.d/*.sources)
            local leaf=${1#sources.list.d/}
            [[ "$leaf" != */* && "$leaf" != *$'\n'* && "$leaf" != *$'\t'* ]] ;;
        *) return 1 ;;
    esac
}

check_target() {
    valid_relative_path "$1" || die "不安全的配置文件名：$1"
    [[ ! -L "$APT_DIR" && ! -L "$APT_DIR/sources.list.d" ]] || die 'APT 配置目录是符号链接，请先人工检查'
    [[ ! -L "$APT_DIR/$1" ]] || die "需要修改的文件是符号链接，请先人工检查：$APT_DIR/$1"
    [[ ! -e "$APT_DIR/$1" || -f "$APT_DIR/$1" ]] || die "目标不是普通文件：$APT_DIR/$1"
}

atomic_write() {
    local input=$1 rel=$2 restore_metadata=${3:-0} target tmp
    check_target "$rel"
    target=$APT_DIR/$rel
    mkdir -p -- "${target%/*}"
    tmp=$(mktemp "${target%/*}/.apt-mirror-switch.XXXXXXXX")
    if ((restore_metadata)); then
        cp -p -- "$input" "$tmp" || { rm -f -- "$tmp"; return 1; }
    elif [[ -f "$target" ]]; then
        cp -p -- "$target" "$tmp" || { rm -f -- "$tmp"; return 1; }
    else
        chmod 0644 "$tmp" || { rm -f -- "$tmp"; return 1; }
    fi
    if ! cat -- "$input" > "$tmp"; then rm -f -- "$tmp"; return 1; fi
    mv -f -- "$tmp" "$target" || { rm -f -- "$tmp"; return 1; }
}

# 不执行备份中的任何代码；manifest 只包含 P(原来存在)/A(原来不存在) 和相对路径。
validate_snapshot() {
    local snapshot=$1 state rel extra count=0
    [[ -f "$snapshot/complete" && -f "$snapshot/manifest" && -f "$snapshot/format" ]] || return 1
    [[ $(cat "$snapshot/format") == apt-mirror-switch-v1 ]] || return 1
    while IFS=$'\t' read -r state rel extra; do
        [[ -z "$extra" ]] && valid_relative_path "$rel" || return 1
        case "$state" in
            P) [[ -f "$snapshot/files/$rel" && ! -L "$snapshot/files/$rel" ]] || return 1 ;;
            A) ;;
            *) return 1 ;;
        esac
        count=$((count + 1))
    done < "$snapshot/manifest"
    ((count > 0))
}

rollback_snapshot() {
    local snapshot=$1 state rel
    validate_snapshot "$snapshot" || return 1
    while IFS=$'\t' read -r state rel; do
        if [[ "$state" == P ]]; then
            atomic_write "$snapshot/files/$rel" "$rel" 1 || return 1
        else
            check_target "$rel"
            rm -f -- "$APT_DIR/$rel" || return 1
        fi
    done < "$snapshot/manifest"
}

cleanup() {
    local rc=$? probe_pid
    trap - EXIT INT TERM
    set +e
    if ((${#PROBE_PIDS[@]})); then
        for probe_pid in "${PROBE_PIDS[@]}"; do kill "$probe_pid" 2>/dev/null; done
    fi
    if ((MUTATING)); then
        say '操作未完成，正在恢复切换前的源配置……' >&2
        if rollback_snapshot "$ACTIVE_BACKUP"; then
            say "已恢复源配置。备份：$ACTIVE_BACKUP" >&2
        else
            say "自动恢复失败，请使用备份人工恢复：$ACTIVE_BACKUP" >&2
        fi
        ((rc != 0)) || rc=1
    fi
    [[ -z "$WORK_DIR" ]] || rm -rf -- "$WORK_DIR"
    exit "$rc"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

need_root() { [[ $(id -u) == 0 ]] || die '写入配置/读取备份需要 root，请用 sudo bash 运行'; }

lock_config() {
    command -v flock >/dev/null 2>&1 || die '缺少 flock，请先安装 util-linux'
    [[ ! -L "$LOCK_FILE" ]] || die '锁文件不能是符号链接'
    mkdir -p -- "${LOCK_FILE%/*}"
    exec 9> "$LOCK_FILE"
    flock -n 9 || die '另一个镜像切换进程正在运行，请稍后重试'
}

confirm() {
    local answer
    ((ASSUME_YES)) && return 0
    [[ -t 0 ]] || die '非交互运行请指定 --yes；可先使用 --dry-run 检查'
    printf '确认执行上述操作？[y/N] '
    IFS= read -r answer || return 1
    case "$answer" in y|Y|yes|YES) return 0 ;; *) say '已取消。'; return 1 ;; esac
}

backup_ids() {
    local entry
    [[ -d "$BACKUP_DIR" ]] || return 0
    for entry in "$BACKUP_DIR"/*; do
        [[ -d "$entry" && ! -L "$entry" && -f "$entry/complete" ]] || continue
        printf '%s\n' "${entry##*/}"
    done | sort -r
}

add_plan() {
    local rel=$1 state=$2 staged=${3:-}
    check_target "$rel"
    PLAN_PATHS+=("$rel")
    PLAN_STATES+=("$state")
    PLAN_FILES+=("$staged")
}

create_backup() {
    local rel snapshot
    [[ ! -L "$BACKUP_DIR" ]] || die '备份目录不能是符号链接'
    mkdir -p -- "$BACKUP_DIR"
    chmod 0700 "$BACKUP_DIR"
    snapshot=$BACKUP_DIR/$(date -u +%Y%m%dT%H%M%SZ)-$$
    mkdir -m 0700 -- "$snapshot"
    mkdir -- "$snapshot/files"
    printf '%s\n' apt-mirror-switch-v1 > "$snapshot/format"
    : > "$snapshot/manifest"
    for rel in "${PLAN_PATHS[@]}"; do
        check_target "$rel"
        if [[ -f "$APT_DIR/$rel" ]]; then
            if [[ "$rel" == */* ]]; then mkdir -p -- "$snapshot/files/${rel%/*}"; fi
            cp -p -- "$APT_DIR/$rel" "$snapshot/files/$rel"
            printf 'P\t%s\n' "$rel" >> "$snapshot/manifest"
        else
            printf 'A\t%s\n' "$rel" >> "$snapshot/manifest"
        fi
    done
    : > "$snapshot/complete"
    ACTIVE_BACKUP=$snapshot
    say "已备份：$ACTIVE_BACKUP"
}

apply_plan() {
    local i
    create_backup
    MUTATING=1
    for ((i=0; i<${#PLAN_PATHS[@]}; i++)); do
        if [[ ${PLAN_STATES[$i]} == P ]]; then
            atomic_write "${PLAN_FILES[$i]}" "${PLAN_PATHS[$i]}" "${RESTORE_ID:+1}"
        else
            check_target "${PLAN_PATHS[$i]}"
            rm -f -- "$APT_DIR/${PLAN_PATHS[$i]}"
        fi
    done
}

update_indexes() {
    local result=0
    say '正在更新软件包索引（不会安装或升级软件包）……'
    # 新 APT 使用 Error-Mode=any；兼容旧 APT，将抓取失败警告也视为失败。
    apt-get -o APT::Update::Error-Mode=any update > "$WORK_DIR/apt-update.log" 2>&1 || result=$?
    cat "$WORK_DIR/apt-update.log"
    if ((result != 0)) || grep -Eq '^(W: Failed to fetch |E:)' "$WORK_DIR/apt-update.log"; then
        die 'apt-get update 失败；若刚修改了配置，将自动恢复。请检查网络、发行版是否停止支持，以及第三方源的错误'
    fi
}

[[ $(uname -s) == Linux ]] || die '本脚本只能在目标 Debian/Ubuntu Linux 上运行'
for utility in awk cmp cp date grep mktemp sort; do
    command -v "$utility" >/dev/null 2>&1 || die "缺少命令：$utility"
done
if ((LIST_BACKUPS)); then
    need_root
    say "备份目录：$BACKUP_DIR（编号按新到旧排列）"
    backup_ids
    exit 0
fi
if ((DRY_RUN == 0)); then need_root; lock_config; fi
WORK_DIR=$(mktemp -d "${TMPDIR:-/tmp}/apt-mirror-switch.XXXXXXXX")

if [[ -n "$RESTORE_ID" ]]; then
    ((DRY_RUN)) || need_root
    if [[ "$RESTORE_ID" == latest ]]; then
        RESTORE_ID=$(backup_ids | awk 'NR == 1 { print; exit }')
        [[ -n "$RESTORE_ID" ]] || die '没有可恢复的备份'
    fi
    [[ "$RESTORE_ID" =~ ^[0-9]{8}T[0-9]{6}Z-[0-9]+$ ]] || die '备份编号格式不正确，请用 --list-backups 查看'
    SNAPSHOT=$BACKUP_DIR/$RESTORE_ID
    [[ ! -L "$SNAPSHOT" ]] && validate_snapshot "$SNAPSHOT" || die "备份不完整或无效：$SNAPSHOT"
    while IFS=$'\t' read -r state rel; do
        add_plan "$rel" "$state" "$SNAPSHOT/files/$rel"
    done < "$SNAPSHOT/manifest"
    say "将恢复：$SNAPSHOT"
    printf '  %s\n' "${PLAN_PATHS[@]}"
    if ((DRY_RUN)); then say '预览结束，未修改配置。'; exit 0; fi
    confirm || exit 0
    apply_plan
    # 明确恢复以源配置落盘为准，不因原始源的网络问题撤销恢复。
    MUTATING=0
    say '原配置已恢复。'
    if ((DO_UPDATE)); then update_indexes; fi
    exit 0
fi

[[ -r "$OS_RELEASE_FILE" ]] || die "无法读取 $OS_RELEASE_FILE"
command -v dpkg >/dev/null 2>&1 || die '缺少 dpkg，无法识别 APT 架构'
os_value() {
    awk -v key="$1" '
        index($0, key "=") == 1 {
            v = substr($0, length(key) + 2)
            q = substr(v, 1, 1)
            if ((q == "\"" || q == sprintf("%c", 39)) && substr(v, length(v), 1) == q)
                v = substr(v, 2, length(v) - 2)
            print v; exit
        }' "$OS_RELEASE_FILE"
}
DISTRO=$(os_value ID)
CODENAME=$(os_value VERSION_CODENAME)
VERSION_ID=$(os_value VERSION_ID)
PRETTY_NAME=$(os_value PRETTY_NAME)
case "$DISTRO" in
    debian|ubuntu) ;;
    *) die "暂不支持系统 ID=$DISTRO；不会把衍生发行版强行切换成 Debian/Ubuntu 源" ;;
esac
if [[ "$DISTRO" == ubuntu && -z "$CODENAME" ]]; then CODENAME=$(os_value UBUNTU_CODENAME); fi
[[ "$CODENAME" =~ ^[a-z][a-z0-9-]*$ ]] || die '无法可靠识别发行版代号，停止操作'
if [[ "$DISTRO" == debian ]]; then
    [[ "$VERSION_ID" =~ ^[0-9]+([.][0-9]+)*$ ]] || die '仅支持有明确版本号的 Debian 正式发行版'
    MAJOR=${VERSION_ID%%.*}
    ((MAJOR >= 11)) || die 'Debian 10 及更旧版本需要归档源，本脚本不自动处理'
fi
ARCH=$(dpkg --print-architecture)
case "$ARCH" in amd64|arm64) ;; *) die "当前原生架构 $ARCH 暂不支持；本版面向 amd64/arm64" ;; esac
FOREIGN_ARCHES=$(dpkg --print-foreign-architectures)
ARCHES=$ARCH
PC_ARCHES=''
PORTS_ARCHES=''
for apt_arch in $ARCH $FOREIGN_ARCHES; do
    [[ "$apt_arch" =~ ^[a-z0-9][a-z0-9-]*$ ]] || die "无法识别附加架构：$apt_arch"
    if [[ "$apt_arch" != "$ARCH" ]]; then ARCHES="$ARCHES $apt_arch"; fi
    if [[ "$DISTRO" == ubuntu ]]; then
        case "$apt_arch" in
            amd64|i386) PC_ARCHES="${PC_ARCHES:+$PC_ARCHES }$apt_arch" ;;
            arm64|armhf|ppc64el|riscv64|s390x) PORTS_ARCHES="${PORTS_ARCHES:+$PORTS_ARCHES }$apt_arch" ;;
            *) die "Ubuntu 附加架构 $apt_arch 暂不支持" ;;
        esac
    fi
done

json_value() {
    # 仅从小型定位响应取字符串，不 eval、不 source 远程内容。
    awk -v key="$1" '
        match($0, "\"" key "\"[ \t]*:[ \t]*\"[^\"]*\"") {
            v = substr($0, RSTART, RLENGTH)
            sub(/^[^:]*:[ \t]*"/, "", v); sub(/"$/, "", v)
            print v; exit
        }'
}

valid_country() {
    [[ "$COUNTRY" =~ ^[A-Z]{2}$ && "$COUNTRY" != XX && "$COUNTRY" != ZZ ]]
}

resolve_region() {
    local response=''
    if [[ "$REGION" != auto ]]; then
        say "镜像地区：$REGION（手动指定，不查询公网 IP）"
        return 0
    fi
    if ! command -v curl >/dev/null 2>&1; then
        say '未安装 curl，无法查询公网出口地区；可手动选择镜像。' >&2
        return 1
    fi
    say '正在查询公网出口地区（Cloudflare，失败时使用 country.is）……'
    if response=$(curl -fLsS --proto '=https' --proto-redir '=https' \
        --connect-timeout 2 --max-time 4 --max-filesize 65536 \
        https://www.cloudflare.com/cdn-cgi/trace 2>/dev/null); then
        COUNTRY=$(printf '%s\n' "$response" | awk -F= '$1 == "loc" { print $2; exit }')
        PUBLIC_IP=$(printf '%s\n' "$response" | awk -F= '$1 == "ip" { print $2; exit }')
    fi
    if ! valid_country; then
        COUNTRY=''; PUBLIC_IP=''
        if response=$(curl -fLsS --proto '=https' --proto-redir '=https' \
            --connect-timeout 2 --max-time 4 --max-filesize 65536 \
            https://api.country.is/ 2>/dev/null); then
            COUNTRY=$(printf '%s\n' "$response" | json_value country)
            PUBLIC_IP=$(printf '%s\n' "$response" | json_value ip)
        fi
    fi
    if ! valid_country; then
        COUNTRY=''; PUBLIC_IP=''
        say '公网 IP 地区查询失败，未假定服务器位于国内或国际地区。' >&2
        return 1
    fi
    [[ "$PUBLIC_IP" =~ ^[0-9A-Fa-f:.]+$ ]] || PUBLIC_IP=''
    if [[ "$COUNTRY" == CN ]]; then REGION=cn; else REGION=global; fi
    say "公网出口：${PUBLIC_IP:-未获取 IP}；国家/地区代码：$COUNTRY；候选地区：$REGION"
    say '定位反映当前请求的公网出口；代理、VPN 和 IP 数据库误差可能影响结果。'
}

mirror_supported() {
    # 这些站点缺少 ubuntu-ports；不能把 Ubuntu ARM64 指向 ubuntu。
    if [[ "$DISTRO" == ubuntu && -n "$PORTS_ARCHES" ]]; then
        case "$1" in kernel|xtom-us|xtom-jp) return 1 ;; esac
    fi
    return 0
}

configure_mirror() {
    local base=''
    DEBIAN_URL=https://deb.debian.org/debian
    DEBIAN_SECURITY_URL=https://security.debian.org/debian-security
    UBUNTU_URL=https://archive.ubuntu.com/ubuntu
    UBUNTU_SECURITY_URL=https://security.ubuntu.com/ubuntu
    UBUNTU_PORTS_URL=https://ports.ubuntu.com/ubuntu-ports
    case "$1" in
        ustc) base=https://mirrors.ustc.edu.cn ;;
        aliyun) base=https://mirrors.aliyun.com ;;
        tencent) base=https://mirrors.cloud.tencent.com ;;
        tsinghua) base=https://mirrors.tuna.tsinghua.edu.cn ;;
        huawei) base=https://mirrors.huaweicloud.com ;;
        official) ;;
        kernel)
            DEBIAN_URL=https://mirrors.edge.kernel.org/debian
            UBUNTU_URL=https://mirrors.edge.kernel.org/ubuntu
            UBUNTU_PORTS_URL='' ;;
        fau)
            DEBIAN_URL=https://ftp.fau.de/debian
            UBUNTU_URL=https://ftp.fau.de/ubuntu
            UBUNTU_PORTS_URL=https://ftp.fau.de/ubuntu-ports ;;
        xtom-us) base=https://mirrors.xtom.com ;;
        xtom-jp) base=https://mirrors.xtom.jp ;;
        *) return 1 ;;
    esac
    if [[ -n "$base" ]]; then
        DEBIAN_URL=$base/debian
        DEBIAN_SECURITY_URL=$base/debian-security
        UBUNTU_URL=$base/ubuntu
        UBUNTU_SECURITY_URL=$base/ubuntu
        UBUNTU_PORTS_URL=$base/ubuntu-ports
        case "$1" in xtom-*) UBUNTU_PORTS_URL='' ;; esac
    fi
}

probe_mirror() {
    local candidate=$1 order=$2 i elapsed body available apt_arch expected_codename
    local total_ms=0
    local urls=() suites=() arches=()
    configure_mirror "$candidate" || return 1
    if [[ "$DISTRO" == debian ]]; then
        urls=("$DEBIAN_URL" "$DEBIAN_SECURITY_URL")
        suites=("$CODENAME" "$CODENAME-security")
        arches=("$ARCHES" "$ARCHES")
    else
        if [[ -n "$PC_ARCHES" ]]; then
            urls+=("$UBUNTU_URL" "$UBUNTU_SECURITY_URL")
            suites+=("$CODENAME" "$CODENAME-security")
            arches+=("$PC_ARCHES" "$PC_ARCHES")
        fi
        if [[ -n "$PORTS_ARCHES" ]]; then
            urls+=("$UBUNTU_PORTS_URL" "$UBUNTU_PORTS_URL")
            suites+=("$CODENAME" "$CODENAME-security")
            arches+=("$PORTS_ARCHES" "$PORTS_ARCHES")
        fi
    fi
    for ((i=0; i<${#urls[@]}; i++)); do
        body=$WORK_DIR/probe-$order-$i
        elapsed=$(curl -fLsS --proto '=https' --proto-redir '=https' \
            --connect-timeout 2 --max-time 6 --max-filesize 2097152 \
            --output "$body" --write-out '%{time_total}' \
            "${urls[$i]}/dists/${suites[$i]}/InRelease" 2>/dev/null) || return 1
        [[ "$elapsed" =~ ^[0-9]+([.][0-9]+)?$ ]] || return 1
        grep -Fqx -- '-----BEGIN PGP SIGNED MESSAGE-----' "$body" || return 1
        if [[ "$DISTRO" == ubuntu ]]; then
            # Ubuntu 的 noble-security 仍写 Codename: noble，以 Suite 区分更新渠道。
            expected_codename=$CODENAME
            grep -Fqx -- "Suite: ${suites[$i]}" "$body" || return 1
        else
            expected_codename=${suites[$i]}
        fi
        grep -Fqx -- "Codename: $expected_codename" "$body" || return 1
        available=$(awk '/^Architectures:/ { sub(/^Architectures:[ \t]*/, ""); print; exit }' "$body")
        for apt_arch in ${arches[$i]}; do
            case " $available " in *" $apt_arch "*) ;; *) return 1 ;; esac
        done
        total_ms=$(awk -v current="$total_ms" -v seconds="$elapsed" 'BEGIN { printf "%.0f", current + seconds * 1000 }')
    done
    printf '%s\t%s\t%s\n' "$total_ms" "$order" "$candidate" > "$WORK_DIR/probe-result-$order"
}

choose_auto_mirror() {
    local candidates candidate order=0 probe_pid score measured_order measured_name
    command -v curl >/dev/null 2>&1 || die '自动探测需要 curl；可改用 --mirror 指定镜像，或先安装 curl'
    case "$REGION" in
        cn) candidates='ustc aliyun tencent tsinghua huawei' ;;
        global) candidates='official fau kernel xtom-us xtom-jp' ;;
        *) die '尚未确定地区，请使用 --region cn 或 --region global，或手动指定 --mirror' ;;
    esac
    say "正在并行探测 $REGION 镜像（主仓库和安全仓库；单次请求最多 6 秒）……"
    for candidate in $candidates; do
        if mirror_supported "$candidate"; then
            probe_mirror "$candidate" "$order" &
            PROBE_PIDS+=("$!")
        fi
        order=$((order + 1))
    done
    for probe_pid in "${PROBE_PIDS[@]}"; do wait "$probe_pid" || :; done
    PROBE_PIDS=()
    : > "$WORK_DIR/ranking"
    order=0
    for candidate in $candidates; do
        if ! mirror_supported "$candidate"; then
            say "  $candidate：跳过（没有所需的 Ubuntu ports 仓库）"
        elif [[ -s "$WORK_DIR/probe-result-$order" ]]; then
            IFS=$'\t' read -r score measured_order measured_name < "$WORK_DIR/probe-result-$order"
            say "  $measured_name：${score} ms（所需索引下载合计）"
            cat "$WORK_DIR/probe-result-$order" >> "$WORK_DIR/ranking"
        else
            say "  $candidate：探测失败或缺少所需版本/架构"
        fi
        order=$((order + 1))
    done
    [[ -s "$WORK_DIR/ranking" ]] || die '候选镜像全部探测失败，未修改配置；请检查网络或使用 --mirror 手动指定镜像'
    MIRROR=$(sort -n -k1,1 -k2,2 "$WORK_DIR/ranking" | awk 'NR == 1 { print $3 }')
    say "自动选择：$MIRROR（以本次小索引探测耗时排序，不代表安装软件包的持续下载速度）"
}

say "系统：${PRETTY_NAME:-$DISTRO}"
say "代号：$CODENAME；APT 架构：$ARCHES；内核架构：$(uname -m)"
if [[ -z "$MIRROR" ]]; then
    ((ASSUME_YES == 0)) || die '--yes 需要同时指定 --mirror（自动模式使用 --mirror auto）'
    [[ -t 0 ]] || die '请使用 --mirror 指定镜像站；自动模式使用 --mirror auto'
fi
if [[ -z "$MIRROR" || "$MIRROR" == auto ]]; then
    if ! resolve_region; then
        if [[ ! -t 0 || $ASSUME_YES == 1 ]]; then
            die '无法自动定位；请指定 --region cn / global，或使用 --mirror 手动选择'
        fi
        MIRROR=''
    fi
fi
if [[ -z "$MIRROR" ]]; then
    cat <<'MENU'

  a) 根据公网出口地区探测并自动选择（地区已确定时默认）
  1) 中国科学技术大学 USTC
  2) 阿里云
  3) 腾讯云（公网镜像）
  4) 清华大学 TUNA
  5) 华为云
  6) Debian / Ubuntu 官方源（Debian 使用全球 CDN）
  7) Kernel.org（国际；不提供 Ubuntu ports）
  8) FAU 德国（国际；提供 Ubuntu ports）
  9) xTom 美国（国际；不提供 Ubuntu ports）
 10) xTom 日本（国际；不提供 Ubuntu ports）
  0) 退出
MENU
    if [[ "$REGION" == auto ]]; then
        printf '定位失败，请手动输入镜像编号 [1-10]：'
    else
        printf '请选择 [a / 1-10，默认 a；当前地区 %s]：' "$REGION"
    fi
    IFS= read -r choice || exit 1
    if [[ -z "$choice" && "$REGION" != auto ]]; then choice=a; fi
    case "$choice" in
        a|A) MIRROR=auto ;;
        1) MIRROR=ustc ;; 2) MIRROR=aliyun ;; 3) MIRROR=tencent ;;
        4) MIRROR=tsinghua ;; 5) MIRROR=huawei ;; 6) MIRROR=official ;;
        7) MIRROR=kernel ;; 8) MIRROR=fau ;; 9) MIRROR=xtom-us ;; 10) MIRROR=xtom-jp ;;
        0) exit 0 ;; *) die '无效选择，请手动选择菜单中的镜像编号' ;;
    esac
fi
if [[ "$MIRROR" == auto ]]; then choose_auto_mirror; fi
mirror_supported "$MIRROR" || die "$MIRROR 不提供 Ubuntu ports，当前架构请使用 official / fau 或国内镜像"
configure_mirror "$MIRROR" || die "未知镜像：$MIRROR"

if [[ "$DISTRO" == debian ]]; then
    KEYRING=$KEYRING_DIR/debian-archive-keyring.gpg
    COMPONENTS='main contrib non-free'
    if ((MAJOR >= 12)); then COMPONENTS="$COMPONENTS non-free-firmware"; fi
else
    KEYRING=$KEYRING_DIR/ubuntu-archive-keyring.gpg
    COMPONENTS='main restricted universe multiverse'
fi
[[ -r "$KEYRING" ]] || die "发行版签名密钥文件不存在：$KEYRING；请先修复官方 archive-keyring 软件包"

if [[ "$FORMAT" == auto ]]; then
    FORMAT=list
    for source_file in "$APT_DIR/sources.list.d/"*.sources; do
        if [[ -f "$source_file" ]]; then FORMAT=sources; break; fi
    done
    if [[ "$DISTRO" == ubuntu && "${VERSION_ID%%.*}" =~ ^[0-9]+$ ]]; then
        if ((${VERSION_ID%%.*} >= 24)); then FORMAT=sources; fi
    elif [[ "$DISTRO" == debian ]] && ((MAJOR >= 13)); then
        FORMAT=sources
    fi
fi
MANAGED_REL=sources.list.d/cn-mirror-switch.$FORMAT
for ext in list sources; do
    managed_file=$APT_DIR/sources.list.d/cn-mirror-switch.$ext
    if [[ -e "$managed_file" || -L "$managed_file" ]]; then
        check_target "sources.list.d/cn-mirror-switch.$ext"
        [[ $(head -n 1 "$managed_file") == "$MARKER" ]] || die "保留文件名被其他配置占用：$managed_file"
    fi
done

# 对传统 list 逐行解析，对 Deb822 按空行分段；不执行配置文件内容。
# 只识别官方域名和常用公共镜像的标准发行版路径，未知地址原样保留。
filter_sources() {
    local input=$1 kind=$2 output=$3
    awk -v kind="$kind" -v distro="$DISTRO" -v src_flag="$WORK_DIR/with-source" '
    function vendor(uri, host, repo) {
        if (uri ~ /^cdrom:/) return 1
        if (uri !~ /^https?:\/\//) return 0
        host = uri; sub(/^https?:\/\//, "", host); sub(/\/.*/, "", host)
        host = tolower(host)
        repo = uri; sub(/^https?:\/\/[^\/]+/, "", repo); sub(/\/+$/, "", repo)
        # Debian 安全仓库也可能直接使用域名根路径；只接受这一确切官方域名。
        if (distro == "debian" && host == "security.debian.org" && repo == "") return 1
        if (distro == "debian" && repo !~ /^\/debian(-security)?$/) return 0
        if (distro == "ubuntu" && repo !~ /^\/ubuntu(-ports)?$/) return 0
        if (distro == "debian" && host ~ /^(deb|security|ftp|archive)\.debian\.org$/) return 1
        if (distro == "debian" && host ~ /^ftp\.[a-z][a-z]\.debian\.org$/) return 1
        if (distro == "ubuntu" && (host ~ /^(archive|security|ports|old-releases)\.ubuntu\.com$/ || host ~ /^[a-z][a-z]\.archive\.ubuntu\.com$/)) return 1
        if (host ~ /^(mirrors\.edge\.kernel\.org|mirrors\.kernel\.org|ftp\.fau\.de|mirrors?\.xtom\.(com|jp|de))$/) return 1
        return host ~ /^(mirrors\.ustc\.edu\.cn|mirrors\.tuna\.tsinghua\.edu\.cn|mirrors\.aliyun\.com|mirrors\.cloud\.aliyuncs\.com|mirrors\.cloud\.tencent\.com|mirrors\.tencentyun\.com|mirrors\.tencent\.com|mirrors\.huaweicloud\.com|repo\.huaweicloud\.com|mirrors\.163\.com|mirrors\.sohu\.com|mirrors\.bfsu\.edu\.cn|mirrors\.nju\.edu\.cn|mirror\.nju\.edu\.cn|mirrors\.sjtug\.sjtu\.edu\.cn|mirror\.sjtu\.edu\.cn|mirrors\.cernet\.edu\.cn|mirrors\.hit\.edu\.cn|mirrors\.hust\.edu\.cn)$/
    }
    function flush(   i,line,pos,key,value,field,uris,enabled,types,n,parts,hits,total,disable) {
        if (!nlines) return
        uris = ""; enabled = "yes"; types = ""; field = ""
        for (i = 1; i <= nlines; i++) {
            line = lines[i]
            if (line ~ /^[ \t]*#/) continue
            if (line ~ /^[ \t]+/) {
                value = line; sub(/^[ \t]+/, "", value)
                if (field == "uris") uris = uris " " value
                if (field == "types") types = types " " value
                continue
            }
            pos = index(line, ":")
            if (!pos) { field = ""; continue }
            key = tolower(substr(line, 1, pos - 1)); field = key
            value = substr(line, pos + 1); sub(/^[ \t]+/, "", value); sub(/[ \t]+$/, "", value)
            if (key == "uris") uris = uris " " value
            if (key == "enabled") enabled = tolower(value)
            if (key == "types") types = types " " value
        }
        hits = 0; total = 0
        if (enabled != "no" && types ~ /(^|[ \t])deb(-src)?([ \t]|$)/) {
            n = split(uris, parts, /[ \t]+/)
            for (i = 1; i <= n; i++) if (parts[i] != "") { total++; hits += vendor(parts[i]) }
        }
        if (hits && hits != total) {
            print "同一 Deb822 段混合了系统源与未知 URI，请先拆成独立段：" FILENAME > "/dev/stderr"
            bad = 1; exit 2
        }
        disable = (hits > 0)
        if (disable && types ~ /(^|[ \t])deb-src([ \t]|$)/) print "yes" > src_flag
        for (i = 1; i <= nlines; i++) print (disable ? "# cn-mirror-switch: " : "") lines[i]
        nlines = 0
    }
    kind == "list" {
        line = $0
        if (line ~ /^[ \t]*deb(-src)?[ \t]+/) {
            rest = line; sub(/^[ \t]*deb(-src)?[ \t]+/, "", rest)
            sub(/^\[[^]]*\][ \t]*/, "", rest)
            split(rest, words, /[ \t]+/)
            if (vendor(words[1])) {
                if (line ~ /^[ \t]*deb-src[ \t]+/) print "yes" > src_flag
                line = "# cn-mirror-switch: " line
            }
        }
        print line; next
    }
    /^[ \t]*$/ { flush(); print; next }
    { lines[++nlines] = $0 }
    END { if (!bad) flush() }
    ' "$input" > "$output"
}

index=0
for source_file in "$APT_DIR/sources.list" "$APT_DIR/sources.list.d/"*.list "$APT_DIR/sources.list.d/"*.sources; do
    [[ -f "$source_file" ]] || continue
    rel=${source_file#"$APT_DIR/"}
    case "$rel" in
        sources.list.d/cn-mirror-switch.*)
            if [[ "$rel" != "$MANAGED_REL" ]]; then add_plan "$rel" A; fi
            # 保持之前已经启用的 deb-src。
            if grep -Eq '^(deb-src[[:space:]]|Types:.*deb-src)' "$source_file"; then WITH_SOURCE=1; fi
            continue ;;
    esac
    kind=list
    [[ "$source_file" != *.sources ]] || kind=sources
    staged=$WORK_DIR/source-$index
    filter_sources "$source_file" "$kind" "$staged" || die "解析失败，未修改任何配置：$source_file"
    if ! cmp -s -- "$source_file" "$staged"; then add_plan "$rel" P "$staged"; fi
    index=$((index + 1))
done
if [[ -f "$WORK_DIR/with-source" ]]; then WITH_SOURCE=1; fi

emit_stanza() {
    local uri=$1 suites=$2 arches=$3 apt_type arch_csv
    if [[ "$FORMAT" == sources ]]; then
        printf 'Types: deb%s\nURIs: %s\nSuites: %s\nComponents: %s\nArchitectures: %s\nSigned-By: %s\n\n' \
            "$([[ $WITH_SOURCE == 0 ]] || printf ' deb-src')" "$uri" "$suites" "$COMPONENTS" "$arches" "$KEYRING"
    else
        arch_csv=${arches// /,}
        for suite in $suites; do
            for apt_type in deb $([[ $WITH_SOURCE == 0 ]] || printf 'deb-src'); do
                printf '%s [arch=%s signed-by=%s] %s %s %s\n' "$apt_type" "$arch_csv" "$KEYRING" "$uri" "$suite" "$COMPONENTS"
            done
        done
    fi
}

generate_sources() {
    printf '%s\n# System: %s %s | mirror: %s\n\n' "$MARKER" "$DISTRO" "$CODENAME" "$MIRROR"
    if [[ "$DISTRO" == debian ]]; then
        emit_stanza "$DEBIAN_URL" "$CODENAME $CODENAME-updates" "$ARCHES"
        emit_stanza "$DEBIAN_SECURITY_URL" "$CODENAME-security" "$ARCHES"
    else
        if [[ -n "$PC_ARCHES" ]]; then
            emit_stanza "$UBUNTU_URL" "$CODENAME $CODENAME-updates $CODENAME-backports" "$PC_ARCHES"
            emit_stanza "$UBUNTU_SECURITY_URL" "$CODENAME-security" "$PC_ARCHES"
        fi
        if [[ -n "$PORTS_ARCHES" ]]; then
            emit_stanza "$UBUNTU_PORTS_URL" "$CODENAME $CODENAME-updates $CODENAME-backports $CODENAME-security" "$PORTS_ARCHES"
        fi
    fi
}
generate_sources > "$WORK_DIR/generated"
if ! cmp -s -- "$WORK_DIR/generated" "$APT_DIR/$MANAGED_REL"; then
    add_plan "$MANAGED_REL" P "$WORK_DIR/generated"
fi

say "镜像：$MIRROR；格式：$FORMAT"
say "将写入：$APT_DIR/$MANAGED_REL"
cat "$WORK_DIR/generated"
say '需要修改的文件（第三方源、未知源地址保持原样；请留意是否有自定义系统源）：'
if ((${#PLAN_PATHS[@]})); then printf '  %s\n' "${PLAN_PATHS[@]}"; else say '  无，当前配置已经一致。'; fi
if ((DRY_RUN)); then say '预览结束，未修改配置。'; exit 0; fi
need_root
command -v apt-get >/dev/null 2>&1 || die '缺少 apt-get'
confirm || exit 0
if ((${#PLAN_PATHS[@]})); then apply_plan; fi
if ((DO_UPDATE)); then update_indexes; fi
MUTATING=0
say '镜像配置已生效。'
if [[ -n "$ACTIVE_BACKUP" ]]; then say "恢复命令：sudo bash $0 --restore ${ACTIVE_BACKUP##*/}"; fi
