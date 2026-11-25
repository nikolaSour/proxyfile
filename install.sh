#!/usr/bin/env bash
set -euo pipefail
export LC_ALL=C

readonly SITE_PORT=8443
readonly WEB_ROOT=/var/www/proxyfile
readonly CONFIG=/etc/caddy/proxyfile.Caddyfile
readonly OVERRIDE=/etc/systemd/system/caddy.service.d/proxyfile.conf
readonly PACKAGE_MASK=/etc/systemd/system/caddy.service
readonly CADDY_REPO=https://dl.cloudsmith.io/public/caddy/stable
readonly CADDY_KEY=/usr/share/keyrings/caddy-stable-archive-keyring.gpg
readonly CADDY_LIST=/etc/apt/sources.list.d/caddy-stable.list

fail() {
    printf '错误：%s\n' "$*" >&2
    exit 1
}

usage() {
    printf '用法：bash install.sh [域名]\n将 Caddy HTTPS 网站部署到 127.0.0.1:%s。\n' "$SITE_PORT"
}

check_system() {
    [[ $(uname -s) == Linux && -d /run/systemd/system ]] || fail '需要运行 systemd 的 Linux。'
    [[ $EUID == 0 ]] || fail '请用 sudo bash install.sh 或 root 运行。'

    # shellcheck disable=SC1091
    . /etc/os-release
    case "${ID:-}:${VERSION_ID:-}" in
        debian:12|debian:13|ubuntu:24.04) ;;
        *) fail '当前支持 Debian 12、Debian 13 和 Ubuntu 24.04。' ;;
    esac
    case "$(dpkg --print-architecture)" in
        amd64|arm64) ;;
        *) fail '当前支持 amd64 和 arm64。' ;;
    esac
    command -v curl >/dev/null || fail '请先安装 curl。'
}

write_templates() {
    cat > "$workdir/Caddyfile" <<EOF
{
	auto_https disable_redirects
	default_bind 0.0.0.0
	default_sni $domain
	acme_ca https://acme-v02.api.letsencrypt.org/directory
	servers {
		protocols h1 h2
	}
	cert_issuer acme {
		disable_tlsalpn_challenge
	}
}

https://$domain:$SITE_PORT {
	bind 127.0.0.1
	root * $WEB_ROOT
	file_server
}
EOF
    cat > "$workdir/proxyfile.conf" <<EOF
[Service]
ExecStart=
ExecStart=/usr/bin/caddy run --environ --config $CONFIG --adapter caddyfile
ExecReload=
ExecReload=/usr/bin/caddy reload --config $CONFIG --adapter caddyfile
EOF
}

install_caddy() {
    # Prevent the packaged default configuration from opening port 80.
    systemctl mask caddy.service
    if [[ ! -f "$CADDY_KEY" || ! -f "$CADDY_LIST" ]]; then
        apt-get update
        apt-get install -y --no-install-recommends ca-certificates gnupg
        if [[ ! -f "$CADDY_KEY" ]]; then
            curl -fsSL "$CADDY_REPO/gpg.key" -o "$workdir/caddy.key"
            gpg --batch --dearmor -o "$workdir/caddy.gpg" "$workdir/caddy.key"
            install -m 0644 "$workdir/caddy.gpg" "$CADDY_KEY"
        fi
        if [[ ! -f "$CADDY_LIST" ]]; then
            curl -fsSL "$CADDY_REPO/debian.deb.txt" -o "$workdir/caddy.list"
            install -m 0644 "$workdir/caddy.list" "$CADDY_LIST"
        fi
    fi
    apt-get update
    apt-get install -y --no-install-recommends caddy
}

verify_site() {
    local attempt response
    printf '等待 %s 的 HTTPS 证书和网页就绪…\n' "$domain"
    for ((attempt = 1; attempt <= 25; attempt++)); do
        if response=$(curl -fsS --noproxy '*' --connect-timeout 3 --max-time 5 \
            --resolve "$domain:$SITE_PORT:127.0.0.1" -o /dev/null -w '%{http_code}' \
            "https://$domain:$SITE_PORT/" 2>/dev/null) && [[ $response == 200 ]]; then
            printf '\n本机 HTTPS 验证通过。\nSNI：%s\nTarget/Dest：127.0.0.1:%s\n网页目录：%s\n' \
                "$domain" "$SITE_PORT" "$WEB_ROOT"
            return
        fi
        sleep 3
    done
    journalctl -u caddy.service --no-pager -n 20 >&2 || true
    fail '本机 HTTPS 暂未就绪。请确认域名的 A 记录和公网 TCP 80，再用同一域名检查。'
}

main() {
    if [[ ${1:-} == --help || ${1:-} == -h ]]; then
        usage
        return
    fi
    (( $# <= 1 )) || fail '请运行 bash install.sh --help 查看用法。'
    check_system

    domain=${1:-}
    if [[ -z "$domain" ]]; then
        [[ -t 0 ]] || fail '请将域名作为安装参数传入。'
        read -r -p '站点域名：' domain || fail '没有收到域名。'
    fi
    domain=${domain,,}
    local domain_pattern='^([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z]([a-z0-9-]{0,61}[a-z0-9])?$'
    [[ ${#domain} -le 253 && $domain =~ $domain_pattern ]] || fail '请输入完整域名，例如 site.example.com。'

    exec 9>/run/proxyfile.lock
    flock -n 9 || fail '另一份安装正在运行。'
    workdir=$(mktemp -d)
    trap 'rm -rf -- "$workdir"' EXIT
    write_templates

    if [[ -e "$CONFIG" || -L "$CONFIG" ]]; then
        [[ ! -L "$CONFIG" ]] && cmp -s "$workdir/Caddyfile" "$CONFIG" \
            || fail "已有安装使用其他域名或配置已被修改，请检查 $CONFIG。"
    else
        if command -v caddy >/dev/null || systemctl cat caddy.service >/dev/null 2>&1 \
            || [[ -e /etc/caddy/Caddyfile || -e "$PACKAGE_MASK" || -L "$PACKAGE_MASK" \
                || -d "${OVERRIDE%/*}" || -d /run/systemd/system/caddy.service.d ]]; then
            fail '检测到已有 Caddy 安装或服务配置。请在独立的 VPS 上运行。'
        fi
    fi

    if [[ -e "$OVERRIDE" || -L "$OVERRIDE" ]]; then
        [[ ! -L "$OVERRIDE" ]] && cmp -s "$workdir/proxyfile.conf" "$OVERRIDE" \
            || fail "已有服务配置与安装脚本不一致，请检查 $OVERRIDE。"
    fi

    if ! systemctl is-active --quiet caddy.service; then
        if ! command -v ss >/dev/null; then
            apt-get update
            apt-get install -y --no-install-recommends iproute2
        fi
        local listeners
        listeners=$(ss -Hltn "sport = :80 or sport = :$SITE_PORT or sport = :2019")
        [[ -z "$listeners" ]] || fail "TCP 80、$SITE_PORT 或 2019 已被占用。"
    fi

    if [[ ! -e "$CONFIG" ]]; then
        install -d -m 0755 "${CONFIG%/*}"
        install -m 0644 "$workdir/Caddyfile" "$CONFIG"
    fi
    if [[ $(dpkg-query -W -f='${db:Status-Status}' caddy 2>/dev/null || true) != installed ]]; then
        install_caddy
    fi
    /usr/bin/caddy validate --config "$CONFIG" --adapter caddyfile

    if [[ ! -e "$OVERRIDE" ]]; then
        install -d -m 0755 "${OVERRIDE%/*}"
        install -m 0644 "$workdir/proxyfile.conf" "$OVERRIDE"
    fi

    install -d -m 0755 "$WEB_ROOT"
    if [[ ! -e "$WEB_ROOT/index.html" && ! -L "$WEB_ROOT/index.html" ]]; then
        cat > "$workdir/index.html" <<'EOF'
<!doctype html>
<html lang="zh-CN">
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>站点首页</title>
<body>
    <main>
        <h1>站点首页</h1>
        <p>这个网站已启用 HTTPS。</p>
    </main>
</body>
</html>
EOF
        install -m 0644 "$workdir/index.html" "$WEB_ROOT/index.html"
    fi

    if [[ -L "$PACKAGE_MASK" && $(readlink "$PACKAGE_MASK") == /dev/null ]]; then
        systemctl unmask caddy.service
    fi
    systemctl daemon-reload
    systemctl enable --now caddy.service
    verify_site
}

main "$@"
