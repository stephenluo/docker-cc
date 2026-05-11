#!/usr/bin/env bash
set -eo pipefail

case "${1:-}" in
  mihomo-daemon)
    # —— mihomo 服务模式 ——
    # ⚠ 关键：mihomo 自己就是代理，启动前拉订阅必须直连，否则会形成 HTTP_PROXY=mihomo:7890
    # 的回环（mihomo 还没起就走它代理）。unset 仅影响本进程，不影响 mihomo 守护进程。
    unset HTTP_PROXY HTTPS_PROXY http_proxy https_proxy
    if [ ! -f /etc/mihomo/config.yaml ] || [ "${REFRESH_SUB:-0}" = "1" ]; then
      [ -n "$CLASH_SUB_URL" ] || { echo "需要 CLASH_SUB_URL"; exit 1; }
      echo "拉取订阅: $CLASH_SUB_URL"
      curl -fsSL "$CLASH_SUB_URL" -o /etc/mihomo/config.yaml
      # 注入 external-controller 与 ui 路径（让 metacubexd 面板可访问）
      yq -i '.external-controller="0.0.0.0:9090" | .external-ui="/etc/mihomo/ui"' \
        /etc/mihomo/config.yaml
    fi
    exec mihomo -d /etc/mihomo
    ;;
  *)
    # —— dcc 服务模式 ——
    # 等 mihomo controller 起来即可（轻量、无外网依赖）
    # 不依赖外网联通性测试，避免代理节点慢/坏时无谓卡 15 秒
    for _ in $(seq 1 15); do
      curl -s -o /dev/null -m 1 --noproxy '*' http://mihomo:9090 && break
      sleep 1
    done
    # 应用 dcc-use 默认供应商（如果设置了 DCC_PROVIDER）；
    # dcc-use 失败也不打断 entrypoint（用户可能配错供应商名）
    if [ -n "${DCC_PROVIDER:-}" ]; then
      dcc-use "$DCC_PROVIDER" || true
    fi
    exec "$@"
    ;;
esac
