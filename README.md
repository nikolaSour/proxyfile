# Proxyfile

在 VPS 上部署本机 HTTPS 静态站点，用作 Xray REALITY 的目标网站。Caddy 负责申请和续期证书，站点监听 `127.0.0.1:8443`。

## 一键安装

准备使用 systemd 的 Debian 12、Debian 13 或 Ubuntu 24.04 VPS（amd64 或 arm64）。安装 `curl`，把域名的 A 记录直接指向 VPS，并确保 TCP 80 能从公网访问。证书使用 IPv4 HTTP-01 验证，安装前请关闭该域名的 CDN 代理并移除 AAAA 记录。使用尚未安装 Caddy、且 TCP 80、8443 和 2019 空闲的 VPS。

在 VPS 的 root 终端执行，按提示输入域名。

```bash
curl -fsSL https://raw.githubusercontent.com/nikolaSour/proxyfile/main/install.sh -o install.sh && bash install.sh
```

如果以普通用户登录，使用 `sudo bash install.sh` 执行下载好的脚本。自动化部署可通过 `bash install.sh site.example.com` 直接传入域名。

## 接入 REALITY

本机 HTTPS 验证通过后，在 3X-UI 或 Xray 的 REALITY 入站填入脚本输出的域名和目标地址。公网 TCP 443 由 Xray 监听。

| 配置 | 值 |
| --- | --- |
| SNI | 安装时输入的域名 |
| Target / Dest | `127.0.0.1:8443` |
| Xver | `0` |

配置入站后，分别验证公网 `https://你的域名/` 和 REALITY 客户端的连接。保持公网 TCP 80 可用于证书续期。

## 网页与服务

- 首页位于 `/var/www/proxyfile/index.html`。可直接替换网页文件，用同一域名重跑安装会保留已有首页。
- 站点配置位于 `/etc/caddy/proxyfile.Caddyfile`，服务使用 `caddy.service`。
- 查看服务和证书日志可运行 `journalctl -u caddy.service -n 60 --no-pager`。
