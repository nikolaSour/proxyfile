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
readonly APT_LOCK_TIMEOUT=300

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

apt_update() {
    local errors="$workdir/apt-update.stderr" waited=0 status
    while :; do
        if apt-get update 2>"$errors"; then
            cat "$errors" >&2
            return 0
        else
            status=$?
        fi
        # APT's dpkg lock timeout does not apply to the package index lock.
        if (( waited >= APT_LOCK_TIMEOUT )) || ! grep -Eq \
            '^E: Could not get lock /var/lib/apt/lists/lock(\. It is held by process | - open \(11:)' "$errors"; then
            cat "$errors" >&2
            return "$status"
        fi
        if (( waited == 0 )); then
            printf 'APT 软件包索引正在使用中，最多等待 %s 秒…\n' "$APT_LOCK_TIMEOUT" >&2
        fi
        sleep 5
        waited=$((waited + 5))
    done
}

apt_install() {
    apt-get -o "DPkg::Lock::Timeout=$APT_LOCK_TIMEOUT" install -y --no-install-recommends "$@"
}

install_caddy() {
    # Prevent the packaged default configuration from opening port 80.
    systemctl mask caddy.service
    if [[ ! -f "$CADDY_KEY" || ! -f "$CADDY_LIST" ]]; then
        apt_update
        apt_install ca-certificates gnupg
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
    apt_update
    apt_install caddy
}

install_default_page() {
    local index_file="$1" checksum
    [[ ! -L "$index_file" ]] || return 0
    if [[ -e "$index_file" ]]; then
        [[ -f "$index_file" ]] || return 0
        checksum=$(sha256sum < "$index_file")
        # Upgrade the original bundled homepage only when its contents match exactly.
        [[ ${checksum%% *} == a961cfaabdb933484344a8500e8842e099a7997cac468c43800177597f9e54ac ]] || return 0
    fi

    cat > "$workdir/index.html" <<'EOF'
<!doctype html>
<html lang="zh-CN">
<head>
    <meta charset="utf-8">
    <meta name="viewport" content="width=device-width, initial-scale=1">
    <meta name="description" content="在 Debian 或 Ubuntu 上安装 Python 3，运行 hello.py 并打印第一句 hello。">
    <title>安装 Python，打印第一句 hello · 编程笔记</title>
    <style>
        :root {
            color-scheme: light;
            --paper: #f8f6ef;
            --ink: #192720;
            --soft-ink: #4b5c51;
            --accent: #286049;
            --line: #d6dbd1;
            --terminal: #1d2c25;
            --mono: ui-monospace, "SFMono-Regular", Consolas, monospace;
        }
        * { box-sizing: border-box; }
        body {
            margin: 0;
            background: var(--paper);
            color: var(--ink);
            font: 1rem/1.8 system-ui, -apple-system, "PingFang SC", "Microsoft YaHei", sans-serif;
        }
        .wrap { width: min(100% - 3rem, 46rem); margin-inline: auto; }
        .masthead { border-bottom: 1px solid var(--line); }
        .masthead .wrap {
            display: flex;
            align-items: center;
            justify-content: space-between;
            gap: 1rem;
            min-height: 4.25rem;
        }
        .brand { color: var(--ink); font-size: 1.0625rem; font-weight: 750; text-decoration: none; }
        a { color: var(--accent); text-underline-offset: .24em; }
        nav { display: flex; flex-wrap: wrap; gap: .25rem 1.25rem; font-size: .875rem; }
        nav a { text-decoration: none; }
        nav a:hover, .brand:hover { text-decoration: underline; }
        .intro { padding: clamp(2.5rem, 7vw, 5rem) 0 2.25rem; }
        h1, h2 { line-height: 1.25; margin: 0; }
        h1 { font-size: clamp(2.1rem, 5.75vw, 4.25rem); font-weight: 780; letter-spacing: -.045em; }
        h1 span { color: var(--accent); }
        h2 { font-size: clamp(1.35rem, 3vw, 1.65rem); letter-spacing: -.025em; }
        .intro p { margin: 1.2rem 0 0; font-size: 1.0625rem; }
        p { margin: .8rem 0; color: var(--soft-ink); }
        section { padding: 1.9rem 0; border-top: 1px solid var(--line); scroll-margin-top: 1rem; }
        code { font-family: var(--mono); }
        p code { padding: .12em .35em; border-radius: .25rem; background: #e8ece2; color: var(--ink); }
        pre {
            margin: .9rem 0;
            padding: 1rem 1.2rem;
            overflow-x: auto;
            border-radius: .65rem;
            background: var(--terminal);
            color: #eff4e8;
            font: .9375rem/1.75 var(--mono);
        }
        .string { color: #c1dfaa; }
        .output { border: 1px solid var(--line); background: #edf1e8; color: var(--accent); }
        footer { padding: 1.35rem 0 2.4rem; border-top: 1px solid var(--line); font-size: .875rem; }
        @media (max-width: 32rem) {
            .wrap { width: calc(100% - 2rem); }
            .masthead .wrap { min-height: 3.5rem; }
            nav { gap: .25rem .85rem; }
            pre { padding: .85rem 1rem; font-size: .875rem; }
        }
    </style>
</head>
<body id="top">
    <header class="masthead">
        <div class="wrap">
            <a class="brand" href="#top">编程笔记</a>
            <nav aria-label="教程目录">
                <a href="#install">安装 Python</a>
                <a href="#run">运行示例</a>
            </nav>
        </div>
    </header>
    <main class="wrap">
        <article aria-labelledby="title">
            <header class="intro">
                <h1 id="title">安装 Python<br>打印第一句 <span>hello</span></h1>
                <p>这篇教程适用于 Debian 和 Ubuntu。打开终端，安装 Python 3，再写一个只有一行的程序。</p>
            </header>
            <section id="install">
                <h2>安装 Python 3</h2>
                <p>先运行 <code>python3 --version</code>。如果终端显示 Python 3 的版本号，就可以直接写代码。如果提示找不到命令，运行下面几行。用 root 登录时，去掉 <code>sudo</code>。</p>
                <pre><code>sudo apt update
sudo apt install python3
python3 --version</code></pre>
            </section>
            <section id="write">
                <h2>新建 hello.py</h2>
                <p>用文本编辑器新建一个名为 <code>hello.py</code> 的文件，写入下面这行并保存。</p>
                <pre><code>print(<span class="string">"hello"</span>)</code></pre>
            </section>
            <section id="run">
                <h2>运行程序</h2>
                <p>在终端进入 <code>hello.py</code> 所在的目录，执行下面的命令。</p>
                <pre><code>python3 hello.py</code></pre>
                <p>终端会输出这一行。</p>
                <pre class="output"><samp>hello</samp></pre>
            </section>
        </article>
        <footer><a href="https://docs.python.org/zh-cn/3/tutorial/interpreter.html">Python 官方教程 · 使用解释器</a></footer>
    </main>
</body>
</html>
EOF
    install -m 0644 "$workdir/index.html" "$index_file"
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
            apt_update
            apt_install iproute2
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
    install_default_page "$WEB_ROOT/index.html"

    if [[ -L "$PACKAGE_MASK" && $(readlink "$PACKAGE_MASK") == /dev/null ]]; then
        systemctl unmask caddy.service
    fi
    systemctl daemon-reload
    systemctl enable --now caddy.service
    verify_site
}

main "$@"
