# syntax=docker/dockerfile:1.6
FROM node:22-slim

ARG MIHOMO_VERSION=v1.18.10
ARG YQ_VERSION=v4.45.1
ARG TARGETARCH

# —— 国内网络加速（默认开启，覆盖见 docs/implementation-plan.md §4.1）——
ARG APT_MIRROR=mirrors.tuna.tsinghua.edu.cn
ARG GH_PROXY=https://mirror.ghproxy.com/
ARG NPM_REGISTRY=https://registry.npmmirror.com

# 切 apt 源（同时兼容 sources.list 旧格式与 sources.list.d/*.sources 新格式）
RUN if [ "$APT_MIRROR" != "deb.debian.org" ] && [ -n "$APT_MIRROR" ]; then \
      sed -i "s|deb.debian.org|$APT_MIRROR|g" /etc/apt/sources.list 2>/dev/null || true; \
      sed -i "s|deb.debian.org|$APT_MIRROR|g" /etc/apt/sources.list.d/*.sources 2>/dev/null || true; \
    fi

RUN apt-get update && apt-get install -y --no-install-recommends \
      curl ca-certificates jq tini gettext-base \
      nano \
    && rm -rf /var/lib/apt/lists/*

# Mihomo + yq 二进制
RUN case "$TARGETARCH" in \
      amd64) ARCH=amd64 ;; \
      arm64) ARCH=arm64 ;; \
      *) echo "unsupported arch: $TARGETARCH"; exit 1 ;; \
    esac && \
    curl -fsSL "${GH_PROXY}https://github.com/MetaCubeX/mihomo/releases/download/${MIHOMO_VERSION}/mihomo-linux-${ARCH}-${MIHOMO_VERSION}.gz" \
      | gzip -d > /usr/local/bin/mihomo && \
    chmod +x /usr/local/bin/mihomo && \
    curl -fsSL "${GH_PROXY}https://github.com/mikefarah/yq/releases/download/${YQ_VERSION}/yq_linux_${ARCH}" \
      -o /usr/local/bin/yq && \
    chmod +x /usr/local/bin/yq

# metacubexd 面板（静态资源）
RUN mkdir -p /etc/mihomo/ui && \
    curl -fsSL "${GH_PROXY}https://github.com/MetaCubeX/metacubexd/releases/latest/download/compressed-dist.tgz" \
      | tar xz -C /etc/mihomo/ui

# Claude Code（npm 源）
RUN if [ -n "$NPM_REGISTRY" ]; then npm config set registry "$NPM_REGISTRY"; fi && \
    npm install -g @anthropic-ai/claude-code

# 入口脚本与工具
COPY entrypoint.sh /usr/local/bin/entrypoint.sh
COPY bin/dcc-use /usr/local/bin/dcc-use
RUN chmod +x /usr/local/bin/entrypoint.sh /usr/local/bin/dcc-use

WORKDIR /workspace
ENV HTTP_PROXY=http://mihomo:7890 \
    HTTPS_PROXY=http://mihomo:7890 \
    NO_PROXY=localhost,127.0.0.1,mihomo \
    EDITOR=nano

ENTRYPOINT ["tini","--","/usr/local/bin/entrypoint.sh"]
CMD ["claude"]
