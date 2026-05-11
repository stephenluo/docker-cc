# syntax=docker/dockerfile:1.6
FROM node:22-slim

# 切到 bash + pipefail：让后续 RUN 里的 pipe（curl | gzip 等）任一环节失败都 exit 非 0，
# 避免 curl 静默失败时 gzip / tar 读 0 字节"成功"导致镜像里塞了空文件
SHELL ["/bin/bash", "-o", "pipefail", "-c"]

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

# —— 系统工具 ——
# 分组：
#   基础      curl ca-certificates jq tini gettext-base nano
#   Python    python3 python3-pip python3-venv（debian bookworm 默认 3.11.2）
#   开发核心  git openssh-client ripgrep less（git over ssh / Claude Code Grep tool 后端 / pager）
#   压缩网络  xz-utils unzip wget
#   debug     procps iproute2 file diffutils patch
RUN apt-get update && apt-get install -y --no-install-recommends \
      curl ca-certificates jq tini gettext-base nano \
      python3 python3-pip python3-venv \
      git openssh-client ripgrep less \
      xz-utils unzip wget \
      procps iproute2 file diffutils patch \
    && rm -rf /var/lib/apt/lists/*

# python / pip 命令别名，便于 Claude Code hooks / 用户脚本调用 `python` / `pip`
RUN ln -sf /usr/bin/python3 /usr/local/bin/python && \
    ln -sf /usr/bin/pip3    /usr/local/bin/pip

# debian 12 默认 PEP 668 阻止 pip 全局装包；容器内是隔离环境无需此保护，
# 写一份 /etc/pip.conf 让 `pip install foo` 直接可用（用户依然可以选 venv）
RUN printf '[global]\nbreak-system-packages = true\n' > /etc/pip.conf

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
