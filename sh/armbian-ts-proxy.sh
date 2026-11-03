#!/usr/bin/env bash
set -Eeuo pipefail

# Tailscale proxy used by the Armbian devices.
# Override during install/on, for example:
#   sudo PROXY_SCHEME=socks5h PROXY_HOST=100.66.66.88 PROXY_PORT=8899 \
#     ./armbian-ts-proxy.sh on
ENV_PROXY_SCHEME="${PROXY_SCHEME-}"
ENV_PROXY_HOST="${PROXY_HOST-}"
ENV_PROXY_PORT="${PROXY_PORT-}"
PROXY_SCHEME="${PROXY_SCHEME:-http}"
PROXY_HOST="${PROXY_HOST:-100.66.66.88}"
PROXY_PORT="${PROXY_PORT:-8899}"

SELF_PATH="/usr/local/sbin/armbian-ts-proxy"
CONFIG_FILE="/etc/armbian-ts-proxy.conf"
APT_FILE="/etc/apt/apt.conf.d/99-armbian-ts-proxy"
PROFILE_FILE="/etc/profile.d/99-armbian-ts-proxy.sh"
CURL_FILE="/etc/curlrc"
WGET_FILE="/etc/wgetrc"
GIT_FILE="/etc/gitconfig"
BEGIN_MARK="# BEGIN armbian-ts-proxy (managed)"
END_MARK="# END armbian-ts-proxy (managed)"
NO_PROXY_VALUE="localhost,127.0.0.1,::1,.local,100.64.0.0/10"

usage() {
    cat <<'EOF'
Usage:
  bash <(curl -LfsS https://raw.githubusercontent.com/ggfvictor/static-files/main/sh/armbian-ts-proxy.sh)
  sudo ./armbian-ts-proxy.sh install [http|socks5h]
  sudo armbian-ts-proxy on [http|socks5h]
  sudo armbian-ts-proxy off
  armbian-ts-proxy status
  sudo armbian-ts-proxy test
  armbian-ts-proxy env
  sudo armbian-ts-proxy run <command> [args...]

Defaults: http://100.66.66.88:8899

Examples:
  bash <(curl -LfsS https://raw.githubusercontent.com/ggfvictor/static-files/main/sh/armbian-ts-proxy.sh)
  sudo ./armbian-ts-proxy.sh install
  sudo armbian-ts-proxy on http
  sudo armbian-ts-proxy test
  sudo armbian-ts-proxy run armbian-update
  sudo armbian-ts-proxy off

With no arguments the script performs "on". "on" configures APT, curl,
wget (HTTP only), Git and login-shell
environment variables. "off" removes only blocks/files managed by this tool.
EOF
}

die() {
    printf 'ERROR: %s\n' "$*" >&2
    exit 1
}

need_root() {
    [[ ${EUID:-$(id -u)} -eq 0 ]] || die "This action must be run with sudo/root."
}

load_config() {
    if [[ -r "$CONFIG_FILE" ]]; then
        # This file is created by this script and contains only validated values.
        # shellcheck disable=SC1090
        source "$CONFIG_FILE"
    fi
    # Explicit environment values take precedence over the saved config.
    [[ -z "$ENV_PROXY_SCHEME" ]] || PROXY_SCHEME="$ENV_PROXY_SCHEME"
    [[ -z "$ENV_PROXY_HOST" ]] || PROXY_HOST="$ENV_PROXY_HOST"
    [[ -z "$ENV_PROXY_PORT" ]] || PROXY_PORT="$ENV_PROXY_PORT"
}

validate_config() {
    case "$PROXY_SCHEME" in
        http|socks5h) ;;
        socks5) PROXY_SCHEME="socks5h" ;;
        *) die "PROXY_SCHEME must be 'http' or 'socks5h' (got: $PROXY_SCHEME)." ;;
    esac
    [[ "$PROXY_HOST" =~ ^[A-Za-z0-9._:-]+$ ]] || die "Invalid PROXY_HOST."
    [[ "$PROXY_PORT" =~ ^[0-9]+$ ]] || die "Invalid PROXY_PORT."
    (( PROXY_PORT >= 1 && PROXY_PORT <= 65535 )) || die "PROXY_PORT is out of range."
}

proxy_url() {
    printf '%s://%s:%s' "$PROXY_SCHEME" "$PROXY_HOST" "$PROXY_PORT"
}

write_atomic() {
    local target="$1" mode="$2" temp
    temp=$(mktemp "${target}.tmp.XXXXXX")
    cat >"$temp"
    chmod "$mode" "$temp"
    chown root:root "$temp"
    mv -f "$temp" "$target"
}

remove_managed_block() {
    local file="$1" temp
    [[ -e "$file" ]] || return 0
    temp=$(mktemp "${file}.tmp.XXXXXX")
    awk -v begin="$BEGIN_MARK" -v end="$END_MARK" '
        $0 == begin { managed=1; next }
        $0 == end   { managed=0; next }
        !managed    { print }
    ' "$file" >"$temp"
    chmod --reference="$file" "$temp" 2>/dev/null || chmod 644 "$temp"
    chown --reference="$file" "$temp" 2>/dev/null || chown root:root "$temp"
    if [[ -s "$temp" ]]; then
        mv -f "$temp" "$file"
    else
        rm -f "$temp" "$file"
    fi
}

append_managed_block() {
    local file="$1" content="$2"
    touch "$file"
    chmod 644 "$file"
    chown root:root "$file"
    remove_managed_block "$file"
    {
        [[ ! -s "$file" ]] || printf '\n'
        printf '%s\n' "$BEGIN_MARK"
        printf '%s\n' "$content"
        printf '%s\n' "$END_MARK"
    } >>"$file"
}

write_config() {
    write_atomic "$CONFIG_FILE" 644 <<EOF
PROXY_SCHEME='$PROXY_SCHEME'
PROXY_HOST='$PROXY_HOST'
PROXY_PORT='$PROXY_PORT'
EOF
}

enable_proxy() {
    need_root
    load_config
    if [[ ${1:-} != "" ]]; then
        PROXY_SCHEME="$1"
    fi
    validate_config
    local url curl_block git_block wget_block
    url=$(proxy_url)
    write_config

    install -d -m 755 /etc/apt/apt.conf.d /etc/profile.d

    write_atomic "$APT_FILE" 644 <<EOF
// Managed by armbian-ts-proxy. Remove with: armbian-ts-proxy off
Acquire::http::Proxy "$url/";
Acquire::https::Proxy "$url/";
Acquire::http::Proxy::localhost "DIRECT";
Acquire::https::Proxy::localhost "DIRECT";
Acquire::http::Proxy::127.0.0.1 "DIRECT";
Acquire::https::Proxy::127.0.0.1 "DIRECT";
EOF

    write_atomic "$PROFILE_FILE" 644 <<EOF
# Managed by armbian-ts-proxy. Applies to newly opened login shells.
export http_proxy='$url'
export https_proxy='$url'
export all_proxy='$url'
export HTTP_PROXY='$url'
export HTTPS_PROXY='$url'
export ALL_PROXY='$url'
export no_proxy='$NO_PROXY_VALUE'
export NO_PROXY='$NO_PROXY_VALUE'
EOF

    curl_block=$(cat <<EOF
proxy = "$url"
noproxy = "$NO_PROXY_VALUE"
EOF
)
    append_managed_block "$CURL_FILE" "$curl_block"

    git_block=$(cat <<EOF
[http]
    proxy = $url
EOF
)
    append_managed_block "$GIT_FILE" "$git_block"

    if [[ "$PROXY_SCHEME" == "http" ]]; then
        wget_block=$(cat <<EOF
use_proxy = on
http_proxy = $url
https_proxy = $url
no_proxy = $NO_PROXY_VALUE
EOF
)
        append_managed_block "$WGET_FILE" "$wget_block"
    else
        # GNU wget has no native SOCKS5 support. Do not leave a stale HTTP block.
        remove_managed_block "$WGET_FILE"
    fi

    printf 'Proxy enabled: %s\n' "$url"
    printf 'Covered: APT/armbian-config, curl/armbian-update, Git, login shells'
    if [[ "$PROXY_SCHEME" == "http" ]]; then
        printf ', wget\n'
    else
        printf '\nNote: GNU wget is not covered because it has no native SOCKS5 support.\n'
    fi
}

disable_proxy() {
    need_root
    rm -f "$APT_FILE" "$PROFILE_FILE" "$CONFIG_FILE"
    remove_managed_block "$CURL_FILE"
    remove_managed_block "$WGET_FILE"
    remove_managed_block "$GIT_FILE"
    printf 'Proxy disabled. Managed proxy settings were removed.\n'
}

show_status() {
    load_config
    validate_config
    local url state="disabled"
    url=$(proxy_url)
    [[ -f "$APT_FILE" && -f "$PROFILE_FILE" ]] && state="enabled"
    printf 'State:  %s\nProxy:  %s\n' "$state" "$url"
    printf 'APT:    %s\n' "$([[ -f "$APT_FILE" ]] && echo configured || echo direct)"
    printf 'curl:   %s\n' "$(grep -qF "$BEGIN_MARK" "$CURL_FILE" 2>/dev/null && echo configured || echo direct)"
    printf 'wget:   %s\n' "$(grep -qF "$BEGIN_MARK" "$WGET_FILE" 2>/dev/null && echo configured || echo direct/not-supported)"
    printf 'Git:    %s\n' "$(grep -qF "$BEGIN_MARK" "$GIT_FILE" 2>/dev/null && echo configured || echo direct)"
}

show_env() {
    load_config
    validate_config
    local url
    url=$(proxy_url)
    cat <<EOF
export http_proxy='$url'
export https_proxy='$url'
export all_proxy='$url'
export HTTP_PROXY='$url'
export HTTPS_PROXY='$url'
export ALL_PROXY='$url'
export no_proxy='$NO_PROXY_VALUE'
export NO_PROXY='$NO_PROXY_VALUE'
EOF
}

test_proxy() {
    load_config
    validate_config
    local url code
    url=$(proxy_url)
    printf 'Testing proxy %s ...\n' "$url"

    if command -v tailscale >/dev/null 2>&1; then
        if tailscale ping -c 1 --timeout 5s "$PROXY_HOST" >/dev/null 2>&1; then
            printf '[OK] Tailscale can reach %s\n' "$PROXY_HOST"
        else
            printf '[WARN] tailscale ping failed; continuing with the proxy test.\n'
        fi
    fi

    command -v curl >/dev/null 2>&1 || die "curl is required for the test."
    if code=$(curl -q --proxy "$url" --connect-timeout 10 --max-time 25 \
        --silent --show-error --output /dev/null --write-out '%{http_code}' \
        https://github.com/); then
        case "$code" in
            2*|3*) printf '[OK] HTTPS through proxy works (github.com HTTP %s).\n' "$code" ;;
            *) die "Proxy connected, but github.com returned HTTP $code." ;;
        esac
    else
        die "Could not reach github.com through $url. Check the proxy protocol, listener and Tailscale ACL/firewall."
    fi
}

run_with_proxy() {
    [[ $# -gt 0 ]] || die "run requires a command."
    load_config
    validate_config
    local url
    url=$(proxy_url)
    export http_proxy="$url" https_proxy="$url" all_proxy="$url"
    export HTTP_PROXY="$url" HTTPS_PROXY="$url" ALL_PROXY="$url"
    export no_proxy="$NO_PROXY_VALUE" NO_PROXY="$NO_PROXY_VALUE"
    exec "$@"
}

install_self() {
    need_root
    local requested_scheme="${1:-$PROXY_SCHEME}"
    if [[ -e "$SELF_PATH" && "$0" -ef "$SELF_PATH" ]]; then
        printf 'Already installed: %s\n' "$SELF_PATH"
    else
        install -m 755 "$0" "$SELF_PATH"
        printf 'Installed: %s\n' "$SELF_PATH"
    fi
    enable_proxy "$requested_scheme"
}

main() {
    case "${1:-}" in
        install) shift; install_self "${1:-}" ;;
        on)      shift; enable_proxy "${1:-}" ;;
        off)     disable_proxy ;;
        status)  show_status ;;
        test)    test_proxy ;;
        env)     show_env ;;
        run)     shift; run_with_proxy "$@" ;;
        -h|--help|help) usage ;;
        "") enable_proxy ;;
        *) die "Unknown command: $1 (use --help)" ;;
    esac
}

main "$@"
