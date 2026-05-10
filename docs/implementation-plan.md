# docker-cc 实现方案

> 目标：将 Claude Code CLI 容器化，自带代理（Mihomo + metacubexd Web 面板）和多 LLM 供应商切换能力，对外暴露一个 `cc` 命令，使用体验等同原生 `claude`。

---

## 1. 目标与范围

### 必须满足
- 在容器内运行 Claude Code CLI，并能操作宿主机任意工作目录（`$(pwd)` 自动挂载）。
- 容器内自带代理服务，Claude Code 出站走代理（解决国内访问 Anthropic API 的问题）。
- 提供 Web 形式的代理节点管理面板。
- 支持在 Anthropic / DeepSeek / Kimi / 智谱 / MiniMax 等多个 LLM 供应商间灵活切换。
- 同时支持 **API Key** 与 **Anthropic 账号 OAuth 登录** 两种认证方式，可互切。
- 宿主机敲 `cc` 命令，体感和敲 `claude` 完全一致。

### 不在范围
- 不容器化原版 Clash Verge GUI（用 Mihomo CLI + Web 面板替代，详见 §3）。
- 不容器化原版 cc-switch GUI（用 `cc-use` CLI 脚本替代）。
- 不使用 TUN 模式做透明代理（用 HTTP_PROXY 环境变量足够）。

---

## 2. 架构总览

采用 **docker compose 双服务** 架构：

```
┌─────────────────────────────────────────────────────────┐
│ 宿主机                                                   │
│                                                          │
│   cc / cc-use 命令 (shell wrapper)                       │
│        │                                                 │
│        ├─ cc up      → docker compose up -d mihomo      │
│        ├─ cc <args>  → docker compose run --rm cc claude│
│        └─ cc-use X   → 直接改 ~/.docker-cc/claude/...   │
│                                                          │
│   ~/.docker-cc/                  ← 持久化目录            │
│     ├─ mihomo/  (config.yaml)                            │
│     ├─ claude/  (settings.json, 凭据)                    │
│     └─ providers/ (供应商模板)                            │
└─────────────────────────────────────────────────────────┘
                       │ 卷挂载
                       ▼
┌─────────────────────────────────────────────────────────┐
│ Docker network: cc-net                                   │
│                                                          │
│  ┌──────────────────────┐    ┌────────────────────────┐ │
│  │ mihomo (常驻)         │    │ cc (按需 run --rm)      │ │
│  │  - mihomo daemon     │◄───┤  - claude code CLI     │ │
│  │  - 监听 7890 (mixed) │HTTP│  - HTTP_PROXY=mihomo:7890│
│  │  - 监听 9090 (UI)    │PROXY  - 工作目录 /workspace │ │
│  │  - metacubexd 面板   │    │    挂载 host $(pwd)    │ │
│  └──────────────────────┘    └────────────────────────┘ │
│        │仅 9090 端口转发                                  │
│        ▼                                                 │
│  宿主 19090 (Web 面板，避开 Verge 默认 9090)              │
│  （7890 不暴露，cc 容器走 docker 内网访问）                │
└─────────────────────────────────────────────────────────┘
```

**两个服务一个镜像**：mihomo 服务和 cc 服务用同一个镜像，通过 entrypoint 不同的子命令分别启动 mihomo daemon 和 claude CLI。

---

## 3. 组件清单与选型

| 组件 | 选型 | 说明 |
|---|---|---|
| 基础镜像 | `node:22-slim` | Claude Code 是 npm 包，自带 Node 运行时 |
| 代理内核 | [Mihomo](https://github.com/MetaCubeX/mihomo) v1.18+ | Clash Verge 的底层内核，纯 CLI |
| 订阅获取 | entrypoint 内 `curl -fsSL "$CLASH_SUB_URL"` 直接拉 | 订阅 URL 必须返回 **Clash/Mihomo 兼容的 yaml**；V2Ray/Trojan 等其他格式需用户先用 [subconverter](https://github.com/tindy2013/subconverter) 或 [sub.dler.io](https://sub.dler.io) 转成 Clash 格式后再传给 `cc up <url>` |
| Web 面板 | [metacubexd](https://github.com/MetaCubeX/metacubexd) | 静态资源直接放进镜像 `/etc/mihomo/ui` |
| LLM CLI | `@anthropic-ai/claude-code` | npm 全局安装 |
| 供应商切换 | 自写 `cc-use` shell 脚本 | 修改 `~/.claude/settings.json` 的 env 段；支持 API key 与 Anthropic OAuth 两种模式 |
| OAuth 登录 | Claude Code 内置 `/login`（device code flow） | 凭据落 `~/.claude/.credentials.json`，由卷挂载持久化 |
| 主入口 | 自写 `cc` shell 脚本（宿主侧）| docker compose 的薄封装 |

---

## 4. 镜像设计（Dockerfile 骨架）

```dockerfile
FROM node:22-slim

ARG MIHOMO_VERSION=v1.18.10
ARG YQ_VERSION=v4.45.1
ARG TARGETARCH

# —— 国内网络加速（默认开启，覆盖见 §4.1）——
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

# Mihomo 二进制 + yq 二进制（entrypoint.sh 用 yq 改写 config.yaml 注入 external-controller / external-ui）
RUN case "$TARGETARCH" in \
      amd64) ARCH=amd64 ;; \
      arm64) ARCH=arm64 ;; \
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
COPY bin/cc-use /usr/local/bin/cc-use
RUN chmod +x /usr/local/bin/entrypoint.sh /usr/local/bin/cc-use

WORKDIR /workspace
ENV HTTP_PROXY=http://mihomo:7890 \
    HTTPS_PROXY=http://mihomo:7890 \
    NO_PROXY=localhost,127.0.0.1,mihomo \
    EDITOR=nano

ENTRYPOINT ["tini","--","/usr/local/bin/entrypoint.sh"]
CMD ["claude"]
```

> `tini` 用来正确转发信号（Ctrl+C 等），避免 Claude Code 退不掉。

### 4.1 国内网络环境优化

镜像构建涉及四类国外资源拉取，国内直连普遍卡顿/失败。Dockerfile 已通过 ARG 默认走国内加速：

| 资源 | 默认加速源 | 影响层 |
|---|---|---|
| **base image** `node:22-slim` | （需在宿主 docker daemon 配置 registry-mirror，见下文） | docker pull |
| **apt 包**（curl / jq / nano 等） | `mirrors.tuna.tsinghua.edu.cn` | 由 `APT_MIRROR` ARG 控制 |
| **GitHub releases**（mihomo / yq / metacubexd） | `https://mirror.ghproxy.com/` 反代 | 由 `GH_PROXY` ARG 控制（前缀拼接） |
| **npm package**（@anthropic-ai/claude-code） | `https://registry.npmmirror.com` | 由 `NPM_REGISTRY` ARG 控制 |

#### 默认构建（国内）
```bash
docker build -t docker-cc:latest .
```

#### 国外/全局构建（关闭加速）
```bash
docker build -t docker-cc:latest \
  --build-arg APT_MIRROR=deb.debian.org \
  --build-arg GH_PROXY= \
  --build-arg NPM_REGISTRY=https://registry.npmjs.org \
  .
```

#### base image 镜像加速

`FROM node:22-slim` 由 docker pull 处理，**不能在 Dockerfile 里通过 ARG 改 registry**（需要 BuildKit 高级特性，跨平台兼容差）。建议在宿主 `/etc/docker/daemon.json`（macOS Docker Desktop 在 Settings → Docker Engine）配置：

```json
{
  "registry-mirrors": [
    "https://docker.m.daocloud.io",
    "https://dockerproxy.com",
    "https://mirror.ccs.tencentyun.com"
  ]
}
```

配完 `sudo systemctl restart docker`（macOS 重启 Docker Desktop）。后续所有 `docker pull` 都自动走镜像源，对所有项目通用。

#### GH_PROXY 自动探测

`install.sh` 在 build 之前会**自动探测**多个 GH_PROXY 备用源（curl HEAD 1KB），选第一个连通的写入 `.env`：

```
1. https://mirror.ghproxy.com/   (默认首选)
2. https://ghfast.top/
3. https://gh-proxy.com/
4. https://ghps.cc/
5. （直连 GitHub）                  最后兜底
```

任何一个能通就直接用，避免某源临时挂掉时整体卡死。`--no-cn-mirror` 跳过探测，强制 GH_PROXY 为空。

#### 手动重新探测

`mirror.ghproxy.com` 经常抽风。如果某天 `cc upgrade` 失败：

```bash
cc probe                  # 重新探测，写入 .env
cc upgrade                # 再试
```

`cc probe` 与 `install.sh` 用的是同一组备用源 + 同一探测逻辑。

#### 自定义 GH_PROXY

如果想锁定特定源（避免每次探测）：
```bash
# 直接编辑 ~/.docker-cc/repo/.env
GH_PROXY=https://your-preferred-proxy/

# 或一次性 build：
docker compose build --build-arg GH_PROXY=https://your-preferred-proxy/
```

---

## 5. docker-compose.yml 骨架

```yaml
services:
  mihomo:
    image: docker-cc:latest
    build:                                  # cc upgrade 走 docker compose build
      context: .
      args:
        APT_MIRROR: ${APT_MIRROR-mirrors.tuna.tsinghua.edu.cn}
        GH_PROXY: ${GH_PROXY-https://mirror.ghproxy.com/}
        NPM_REGISTRY: ${NPM_REGISTRY-https://registry.npmmirror.com}
    container_name: cc-mihomo
    command: ["mihomo-daemon"]              # entrypoint 识别此子命令
    restart: unless-stopped
    volumes:
      - ${HOME}/.docker-cc/mihomo:/etc/mihomo
    environment:
      - CLASH_SUB_URL=${CLASH_SUB_URL}      # 订阅 URL，从 .env 读
      - REFRESH_SUB=${REFRESH_SUB:-0}       # cc up <url> / cc refresh 时透传 1，强制重拉
    ports:
      # 7890 默认不暴露：cc 容器走 docker 内网（mihomo:7890）访问，无需经过宿主端口。
      # 若想让宿主其他程序也用这个代理，在 .env 设 EXPOSE_PROXY_PORT=7890 后启用 override。
      - "127.0.0.1:${UI_PORT:-19090}:9090"   # Web 面板，默认 19090 避开 Clash Verge 的 9090
    networks: [cc-net]

  cc:
    image: docker-cc:latest                 # 与 mihomo 服务复用同一个镜像（不再单独 build）
    profiles: ["cli"]                       # 默认不启动，仅 run 时使用
    depends_on: [mihomo]
    volumes:
      - ${HOST_PWD:-${PWD}}:/workspace       # cc 脚本设置 HOST_PWD=用户原始工作目录
      - ${HOME}/.docker-cc/claude:/root/.claude
      - ${HOME}/.docker-cc/providers:/root/.cc-providers:ro
    environment:
      - CC_PROVIDER=${CC_PROVIDER:-}        # 可选：entrypoint 启动时 cc-use 切到该供应商
    networks: [cc-net]
    stdin_open: true
    tty: true

networks:
  cc-net:
    driver: bridge
```

关键点：
- `profiles: ["cli"]` 让 `cc` 服务默认不被 `compose up` 启动，只能通过 `compose run --rm cc` 调用。
- `${HOST_PWD}` 由 `cc` 包装脚本在 `cd` 之前 export，保留用户调用时的原始工作目录。如果直接用 `docker compose run`（不通过 cc 脚本），fallback 到 `${PWD}`（compose 命令的 pwd）。
- 端口仅绑 `127.0.0.1`，避免代理被局域网误用。
- **7890 不暴露宿主**：cc → mihomo 通过 `cc-net` 内网通信，与宿主完全隔离；与宿主已运行的 Clash Verge 互不干扰。
- **9090 → 19090**：metacubexd 面板端口默认改为 19090，避开 Verge 的 9090 占用。可通过 `.env` 的 `UI_PORT` 自定义。

可选：若想把代理也开放给宿主其他程序，新建 `docker-compose.override.yml`（不入 git）：
```yaml
services:
  mihomo:
    ports:
      - "127.0.0.1:17890:7890"   # 自定义宿主端口避开 Verge
```

---

## 6. entrypoint.sh 逻辑

```bash
#!/usr/bin/env bash
set -e

case "${1:-}" in
  mihomo-daemon)
    # —— mihomo 服务模式 ——
    # ⚠ 关键：mihomo 自己就是代理，启动前拉订阅必须直连，否则会形成 HTTP_PROXY=mihomo:7890
    # 的回环（mihomo 还没起就走它代理）。unset 仅影响本进程，不影响 mihomo 守护进程。
    unset HTTP_PROXY HTTPS_PROXY http_proxy https_proxy
    if [ ! -f /etc/mihomo/config.yaml ] || [ "${REFRESH_SUB:-0}" = "1" ]; then
      [ -n "$CLASH_SUB_URL" ] || { echo "需要 CLASH_SUB_URL"; exit 1; }
      curl -fsSL "$CLASH_SUB_URL" -o /etc/mihomo/config.yaml
      # 注入 external-controller 与 ui 路径
      yq -i '.external-controller="0.0.0.0:9090" | .external-ui="/etc/mihomo/ui"' \
        /etc/mihomo/config.yaml
    fi
    exec mihomo -d /etc/mihomo
    ;;
  *)
    # —— cc 服务模式 ——
    # 等 mihomo controller 起来即可（轻量、无外网依赖）
    # 不依赖外网联通性测试，避免代理节点慢/坏时无谓卡 15 秒
    for i in $(seq 1 15); do
      curl -s -o /dev/null -m 1 --noproxy '*' http://mihomo:9090 && break
      sleep 1
    done
    # 应用 cc-use 默认供应商（如果设置了 CC_PROVIDER）
    [ -n "$CC_PROVIDER" ] && cc-use "$CC_PROVIDER" || true
    exec "$@"
    ;;
esac
```

---

## 7. 关键脚本

### 7.1 `bin/cc`（宿主端 wrapper）

放到 `~/bin/cc`，软链 `/usr/local/bin/cc`。

```bash
#!/usr/bin/env bash
set -e

# 关键：先保存用户调用 cc 时的工作目录，再 cd 到 compose 目录
# 否则 docker-compose.yml 里的 ${PWD} 会被解析成 compose 目录，工作目录就挂错了
export HOST_PWD="$PWD"
COMPOSE_DIR="${DOCKER_CC_HOME:-$HOME/.docker-cc/repo}"
cd "$COMPOSE_DIR"

# 仅提取 cc 脚本需要的变量（不能 source 整个 .env：CLASH_SUB_URL 含 & ? 等
# shell 元字符时 source 会语法错；docker compose 读 .env 不走 shell 语法所以无碍）
if [ -f .env ]; then
  while IFS='=' read -r k v; do
    case "$k" in
      UI_PORT) v="${v%\"}"; UI_PORT="${v#\"}" ;;
    esac
  done < .env
fi

# 读版本号（VERSION 文件由 install.sh 复制到 COMPOSE_DIR）
CC_VERSION="$(cat VERSION 2>/dev/null || echo dev)"

# --version / -v：单独显示版本，不透传给 claude，不打 banner
if [ "${1:-}" = "--version" ] || [ "${1:-}" = "-v" ]; then
  echo "cc v${CC_VERSION}"
  exit 0
fi

# 其他所有调用：开始时打一行 banner（输出到 stderr 不污染 stdout 管道）
echo "cc v${CC_VERSION}" >&2

case "${1:-}" in
  up)
    shift
    if [ -n "${1:-}" ]; then
      # 首次或想换订阅时：cc up <url> 直接传订阅链接，自动写入 .env 并强制重拉
      # 用 grep -v + 追加替代 sed，避免 URL 含 | / & / \ 等特殊字符破坏 sed 模式
      # URL 加双引号写入：docker compose 解析 .env 时会去引号；防御 URL 含 & 等元字符
      url="$1"
      { grep -v '^CLASH_SUB_URL=' .env 2>/dev/null || true; echo "CLASH_SUB_URL=\"${url}\""; } > .env.tmp
      mv .env.tmp .env
      REFRESH_SUB=1 exec docker compose up -d mihomo
    else
      # 之后：cc up 直接复用 .env 里的 URL
      [ -f .env ] && grep -q '^CLASH_SUB_URL=.' .env \
        || { echo "首次使用请指定订阅: cc up <subscription-url>"; exit 1; }
      exec docker compose up -d mihomo
    fi
    ;;
  down)   exec docker compose down ;;
  logs)   shift; exec docker compose logs "$@" mihomo ;;
  panel)
    url="http://127.0.0.1:${UI_PORT:-19090}/ui"
    if   command -v open      >/dev/null 2>&1; then exec open      "$url"
    elif command -v xdg-open  >/dev/null 2>&1; then exec xdg-open  "$url"
    else echo "请在浏览器打开：$url"; fi ;;
  shell)  exec docker compose run --rm cc bash ;;
  login)
          # 切到 OAuth 模式（清空 settings.json 的 env，避免 API key 抢占）
          cc-use claude-account
          echo "进入 claude 交互界面后，输入 /login 完成 OAuth 流程（终端会显示 URL，"
          echo "用宿主浏览器打开授权，再把 token 复制粘贴回容器终端）。完成后 Ctrl+D 退出。"
          exec docker compose run --rm cc claude ;;
  logout)
          echo "进入 claude 交互界面后，输入 /logout 退出账号。"
          exec docker compose run --rm cc claude ;;
  refresh)
          REFRESH_SUB=1 docker compose up -d --force-recreate mihomo ;;
  probe)
          # 重新探测 GH_PROXY 备用源，写入 .env（与 install.sh 同一组源 + 同一逻辑）
          # 用途：cc upgrade 失败时手动救援，或主动切到更快的镜像源
          target="github.com/mikefarah/yq/releases/download/v4.45.1/yq_linux_amd64"
          for p in "https://mirror.ghproxy.com/" "https://ghfast.top/" "https://gh-proxy.com/" "https://ghps.cc/" ""; do
            if [ -n "$p" ]; then printf "  探测 %-32s ... " "$p"
            else                  printf "  %-39s ... " "探测 直连 GitHub（无加速）"; fi
            if curl -sfL --max-time 5 -r 0-1024 -o /dev/null "${p}https://${target}" 2>/dev/null; then
              echo "✓"
              { grep -v '^GH_PROXY=' .env 2>/dev/null || true; echo "GH_PROXY=${p}"; } > .env.tmp
              mv .env.tmp .env
              echo "已写入 .env：GH_PROXY=${p:-（直连）}"
              exit 0
            fi
            echo "✗"
          done
          echo "所有 GH_PROXY 源都不可达"; exit 1 ;;
  upgrade)
          # ⚠ 不要用 cc update —— claude code 装在镜像层，--rm 容器内 npm 更新会被丢弃。
          # 升级正确做法是 rebuild 镜像。
          shift
          case "${1:-claude}" in
            claude|all)
              if ! docker compose build --no-cache --pull; then
                echo ""
                echo "build 失败。常见原因：GH_PROXY 镜像源临时挂掉。"
                echo "请运行: cc probe   # 重新探测可用源"
                echo "然后再 cc upgrade。"
                exit 1
              fi
              docker compose up -d --force-recreate mihomo
              docker compose run --rm cc claude --version
              echo "升级完成。配置和凭据未受影响（都在卷挂载目录）。" ;;
            mihomo)
              echo "升级 mihomo 内核：修改 Dockerfile 的 ARG MIHOMO_VERSION，然后 cc upgrade claude" ;;
            *)
              echo "用法: cc upgrade [claude|mihomo|all]"; exit 1 ;;
          esac ;;
  update)
          echo "提示：cc update 不会持久化。请使用 cc upgrade（rebuild 镜像）。"
          exit 1 ;;
  *)
    # 默认：透传给 claude
    # docker compose up -d 是幂等操作：已运行则 no-op，未运行则启动
    # 不用 ps --status 判断，避免 compose < 2.6 不支持 --status 标志
    docker compose up -d mihomo >/dev/null
    exec docker compose run --rm cc claude "$@"
    ;;
esac
```

- 首次调用 `cc <args>` 时，若 mihomo 未起，会自动 `up`。
- `cc` 不带参数 → 交互 claude；`cc -p "..."` → 一次性，与原生体验一致。

### 7.2 `bin/cc-use`（LLM 供应商管理 + 切换）

对标原版 cc-switch GUI 的功能，提供完整的"管理 + 切换"能力，子命令模式：

```bash
# —— 查看 ——
cc-use                              # 列出所有供应商，★ 标记当前激活（list 别名）
cc-use list                         # 同上
cc-use current                      # 仅打印当前激活的供应商名
cc-use show <name>                  # 显示某供应商详情，API Key 脱敏

# —— 增删改 ——
cc-use add <name> --api-key=KEY --base-url=URL [--model=NAME] [--small-model=NAME] [--key-name=VAR]
cc-use add <name> --mode=oauth      # 创建 OAuth 模式供应商（仅写入 _mode=oauth，无其他字段）
cc-use add <name>                   # 缺参数则交互式补齐（API Key 用 -s 隐式输入）
cc-use edit <name>                  # 用 $EDITOR 打开 ~/.docker-cc/providers/<name>.json
cc-use remove <name>                # 删除（带确认）

# —— 切换（保留原有行为）——
cc-use <name>                       # 切到该供应商；OAuth 模式自动清空 env

# —— 调试 ——
cc-use test [<name>]                # 用 curl 探测 base_url 是否可达；不传 name 则测当前激活的
```

参数说明：
- `--mode`：默认 `api-key`；设为 `oauth` 时仅写入 `{"_mode":"oauth"}`，其他参数全部忽略，用于创建走 Anthropic 账号订阅的供应商（如 `claude-account`，可建多个不同账号）。
- `--api-key`：供应商后台拿到的密钥串，本质就是 API key，写入 settings.json 的 env 字段。
- `--key-name`：默认 `ANTHROPIC_AUTH_TOKEN`（多数 Anthropic 兼容供应商用这个）；少数供应商要求 `ANTHROPIC_API_KEY`，用此 flag 覆盖。
- `--model`：可选，写入 `ANTHROPIC_MODEL`，主对话模型。
- `--small-model`：可选，写入 `ANTHROPIC_SMALL_FAST_MODEL`，用于后台轻量任务（会话摘要、文件名建议、补全等），通常选同供应商的便宜小模型，可显著降本。

`cc-use list` 输出示例：
```
   NAME             BASE_URL                                       TYPE
   anthropic        https://api.anthropic.com                      api-key
★  kimi             https://api.moonshot.cn/anthropic              api-key
   deepseek         https://api.deepseek.com/anthropic             api-key
   claude-account   -                                              oauth
```

#### 实现骨架

```bash
#!/usr/bin/env bash
set -e

# 同一份脚本同时部署在宿主和容器，根据运行环境选默认路径
if [ -f /.dockerenv ]; then
  # 容器内：路径与 docker-compose.yml 挂载点对齐
  PROVIDERS_DIR="${PROVIDERS_DIR:-/root/.cc-providers}"
  SETTINGS="${CLAUDE_SETTINGS:-/root/.claude/settings.json}"
else
  # 宿主：~/.docker-cc/ 下
  PROVIDERS_DIR="${PROVIDERS_DIR:-$HOME/.docker-cc/providers}"
  SETTINGS="${CLAUDE_SETTINGS:-$HOME/.docker-cc/claude/settings.json}"
fi
mkdir -p "$PROVIDERS_DIR" "$(dirname "$SETTINGS")" 2>/dev/null || true
[ -f "$SETTINGS" ] || echo '{}' > "$SETTINGS"

# 当前激活：用 settings.json 的 env.ANTHROPIC_BASE_URL 反查 providers/*.json
current_provider() {
  local cur_url cur_token
  cur_url=$(jq -r '.env.ANTHROPIC_BASE_URL // empty' "$SETTINGS")
  cur_token=$(jq -r '.env.ANTHROPIC_AUTH_TOKEN // .env.ANTHROPIC_API_KEY // empty' "$SETTINGS")
  if [ -z "$cur_token" ] && [ -z "$cur_url" ]; then
    # env 空 → OAuth 模式
    for f in "$PROVIDERS_DIR"/*.json; do
      [ "$(jq -r '._mode // empty' "$f" 2>/dev/null)" = "oauth" ] \
        && basename "$f" .json && return
    done; return
  fi
  for f in "$PROVIDERS_DIR"/*.json; do
    [ "$(jq -r '.ANTHROPIC_BASE_URL // empty' "$f" 2>/dev/null)" = "$cur_url" ] \
      && basename "$f" .json && return
  done
}

cmd_add() {
  local name="$1"; shift
  local mode="api-key" api_key="" base_url="" model="" small_model="" key_name="ANTHROPIC_AUTH_TOKEN"
  while [ $# -gt 0 ]; do
    case "$1" in
      --mode=*)        mode="${1#--mode=}" ;;
      --api-key=*)     api_key="${1#--api-key=}" ;;
      --base-url=*)    base_url="${1#--base-url=}" ;;
      --model=*)       model="${1#--model=}" ;;
      --small-model=*) small_model="${1#--small-model=}" ;;
      --key-name=*)    key_name="${1#--key-name=}" ;;
      *) echo "未知参数: $1"; exit 1 ;;
    esac; shift
  done

  if [ "$mode" = "oauth" ]; then
    jq -n '{ _mode: "oauth", _comment: "OAuth 模式：切到此供应商后运行 cc login" }' \
      > "$PROVIDERS_DIR/${name}.json"
    # 注意：${name} 显式分隔，避免 macOS 自带 Bash 3.2 在 UTF-8 locale 下把
    # $name 后紧跟的中文首字节"吃"进变量解析（详见 §12 已知限制）
    echo "已创建 OAuth 供应商: ${name}（运行 cc-use ${name} && cc login 完成登录）"
    return
  fi

  [ -z "$api_key" ]     && { read -rsp "API Key: " api_key; echo; }
  [ -z "$base_url" ]    && read -rp  "Base URL: " base_url
  [ -z "$model" ]       && read -rp  "Model (可选，主对话): " model
  [ -z "$small_model" ] && read -rp  "Small/Fast Model (可选，后台小任务): " small_model
  jq -n --arg k "$key_name" --arg t "$api_key" --arg u "$base_url" \
        --arg m "$model"   --arg sm "$small_model" \
    '{ ($k): $t, ANTHROPIC_BASE_URL: $u } +
     (if $m  == "" then {} else {ANTHROPIC_MODEL: $m} end) +
     (if $sm == "" then {} else {ANTHROPIC_SMALL_FAST_MODEL: $sm} end)' \
    > "$PROVIDERS_DIR/${name}.json"
}

cmd_switch() {
  local name="$1" f="$PROVIDERS_DIR/${1}.json"
  [ -f "$f" ] || { echo "找不到供应商: ${name}"; cmd_list; exit 1; }
  if [ "$(jq -r '._mode // empty' "$f")" = "oauth" ]; then
    jq '.env = {}' "$SETTINGS" > "$SETTINGS.tmp"
    # ${name} 显式分隔，防 macOS Bash 3.2 在 UTF-8 下"吃"中文首字节（详见 §12）
    echo "已切换到 OAuth 模式: ${name}（如未登录请运行 cc login）"
  else
    jq --slurpfile p "$f" \
       '.env = ($p[0] | with_entries(select(.key | startswith("_") | not)))' \
       "$SETTINGS" > "$SETTINGS.tmp"
    echo "已切换到 API Key 供应商: ${name}"
  fi
  mv "$SETTINGS.tmp" "$SETTINGS"
}

# 其余 cmd_list / cmd_current / cmd_show / cmd_edit / cmd_remove / cmd_test 略，详见 bin/cc-use 源码

case "${1:-list}" in
  ""|list)    cmd_list ;;
  current)    cmd_current ;;
  show)       shift; cmd_show "$@" ;;
  add)        shift; cmd_add "$@" ;;
  edit)       shift; cmd_edit "$@" ;;
  remove|rm)  shift; cmd_remove "$@" ;;
  test)       shift; cmd_test "$@" ;;
  -h|--help)  echo "用法: cc-use [list|current|show|add|edit|remove|test|<name>]" ;;
  *)          cmd_switch "$1" ;;
esac
```

> **关于 `--api-key` 命名**：Claude Code 实际读的环境变量是 `ANTHROPIC_AUTH_TOKEN`（或 `ANTHROPIC_API_KEY`），但用户视角"API Key"更直白。`--api-key` 默认写到 `ANTHROPIC_AUTH_TOKEN`，如供应商要求别的变量名，用 `--key-name` 覆盖。

修改的是宿主侧 `~/.docker-cc/claude/settings.json`（被卷挂载到容器内 `/root/.claude/settings.json`），下次 `cc` 启动 claude 时自动生效，无需重启容器。

### 7.3 供应商模板示例

`~/.docker-cc/providers/anthropic.json`:
```json
{
  "ANTHROPIC_AUTH_TOKEN": "sk-ant-xxx",
  "ANTHROPIC_BASE_URL": "https://api.anthropic.com",
  "ANTHROPIC_MODEL": "claude-sonnet-4-6",
  "ANTHROPIC_SMALL_FAST_MODEL": "claude-haiku-4-5"
}
```

`~/.docker-cc/providers/deepseek.json`:
```json
{
  "ANTHROPIC_AUTH_TOKEN": "sk-xxx",
  "ANTHROPIC_BASE_URL": "https://api.deepseek.com/anthropic",
  "ANTHROPIC_MODEL": "deepseek-chat"
}
```

`~/.docker-cc/providers/kimi.json`、`zhipu.json`、`minimax.json` 同理。

`~/.docker-cc/providers/claude-account.json`（**OAuth 模式**，使用 Claude Pro/Max 订阅）:
```json
{
  "_mode": "oauth",
  "_comment": "使用 Anthropic 账号订阅；切到此模式后请执行 cc login"
}
```

> **API Key 与 OAuth 互斥**：Claude Code 一旦读到 `ANTHROPIC_AUTH_TOKEN` 就会绕过 OAuth。`cc-use` 切到 OAuth 模式时会清空 `env`；切回任意 API key 模式则 OAuth 自动失活（凭据文件保留，不被使用）。

---

## 8. 项目文件结构

```
docker-cc/
├── Dockerfile
├── docker-compose.yml
├── entrypoint.sh
├── VERSION                         # 单行版本号，cc / cc --version 启动时显示
├── .env.example                    # CLASH_SUB_URL=... + 可选 UI_PORT / GH_PROXY 等
├── .gitignore                      # 包含 .env、~/.docker-cc/ 等敏感路径
├── bin/
│   ├── cc                          # 宿主 wrapper
│   ├── cc-use                      # 切供应商（宿主 + 容器复用同一份）
│   └── _cc-probe-ghproxy           # 探测可用 GH_PROXY 镜像源（install.sh + cc probe 共享）
├── providers/                      # 模板，install.sh 复制到 ~/.docker-cc/providers
│   ├── anthropic.json.example      # API Key 模式
│   ├── claude-account.json.example # OAuth 模式（Claude Pro/Max 订阅）
│   ├── deepseek.json.example
│   ├── kimi.json.example
│   ├── zhipu.json.example
│   └── minimax.json.example
├── install.sh                      # 一键安装
├── uninstall.sh
├── docs/
│   └── implementation-plan.md      # 本文件
└── README.md
```

---

## 9. 安装流程（install.sh 做的事）

1. 检查依赖：`docker`、`docker compose` 可用，否则报错。
2. 创建 `~/.docker-cc/` 目录树（mihomo / claude / providers / repo）。
3. 把整个仓库内容复制到 `~/.docker-cc/repo/`（包含 `Dockerfile`、`entrypoint.sh`、`bin/`、`docker-compose.yml`、`.env.example`、`providers/`），保证 `cc upgrade` 时 `docker compose build` 有完整的 build context。
4. **GH_PROXY 自动探测**：build 之前 install.sh 会探测 5 个 GH_PROXY 备用源，选第一个连通的写入 `.env`（详见 §4.1）。`--no-cn-mirror` 时跳过探测、强制空 GH_PROXY。
5. 在 `~/.docker-cc/repo/` 执行 `docker compose build`（compose.yml 的 `build.args` 自动读 `.env` 里的 `APT_MIRROR / GH_PROXY / NPM_REGISTRY`）。
6. 把 `providers/*.example` 复制到 `~/.docker-cc/providers/`，去掉 `.example` 后缀（独立于 repo 目录，方便用户管理 token 而不污染 git）。
7. 把 `bin/cc` 和 `bin/cc-use` 软链到 `/usr/local/bin/`。
8. 提示用户：用 `cc up <subscription-url>` 启动，并 `cc-use edit <name>` 填 token。

### 9.1 install.sh 支持的参数

| 参数 | 作用 | 用途 |
|---|---|---|
| `--no-cn-mirror` | 关闭国内加速：写入 `.env` 中 `APT_MIRROR=deb.debian.org GH_PROXY= NPM_REGISTRY=https://registry.npmjs.org` 后再 build | 出国/海外用户、CI 在境外 runner |
| `--skip-build` | 跳过 `docker compose build` 步骤 | 测试场景：镜像已存在；CI 中 build 阶段独立跑 |
| `--skip-link` | 跳过把 `cc` / `cc-use` 软链到 `/usr/local/bin/`（不需要 sudo） | 隔离测试；不污染系统 PATH |
| `--prefix=<dir>` | 软链放到 `<dir>/bin/` 而不是 `/usr/local/bin/` | 用户级安装（如 `--prefix=$HOME/.local`），不需要 sudo |

无参数 = 默认全套（国内加速 + build + 软链到 /usr/local/bin/）。

---

## 10. 使用流程

### 首次配置
```bash
git clone <repo> && cd docker-cc
./install.sh
cc up "https://your-airport.com/subscription"    # 直接传订阅 URL，自动写入 .env 并启动
$EDITOR ~/.docker-cc/providers/deepseek.json     # 填 LLM 供应商 token
cc panel                                         # 浏览器打开面板，选个节点
```

> 也可以先 `$EDITOR ~/.docker-cc/repo/.env` 手动填 `CLASH_SUB_URL`，然后 `cc up`（不带参数）。两种等价。

### 日常使用

```bash
# —— 启停与订阅管理 ——
cc up                                # URL 已在 .env，直接启动 mihomo
cc up "https://new-airport.com/sub"  # 换机场：传新 URL，自动覆盖 .env 并重拉
cc refresh                           # URL 不变，仅重拉一次订阅（节点更新）
cc down                              # 停服务
cc logs -f                           # 看 mihomo 日志
cc panel                             # 浏览器打开 metacubexd 面板（19090）
cc probe                             # 重新探测 GH_PROXY 镜像源（cc upgrade 失败时救援）
cc upgrade                           # 升级镜像内的 claude code 到最新版（rebuild）

# —— 在项目里跑 claude（核心体验，与原生 claude 一致）——
cd ~/some-project
cc                                   # 进入交互
cc -p "explain this repo"            # 一次性
cc -c                                # 继续上次会话

# —— 管理 LLM 供应商 ——
cc-use                               # 列出所有，★ 标记当前
cc-use edit anthropic                # 编辑 install.sh 预置的模板（填入 token）
cc-use add my-account \              # 新增一个非预置供应商
    --api-key=sk-xxx --base-url=https://api.example.com/anthropic \
    --model=foo-pro --small-model=foo-mini
cc-use show kimi                     # 查看详情（API Key 脱敏）
cc-use test                          # curl 测试当前供应商连通性
cc-use remove my-account             # 删除（带确认）

# —— 切换 LLM 供应商 ——
cc-use kimi                          # 切到 Kimi（API Key 模式）
cc                                   # 用 Kimi 跑

# —— 用 Claude 账号订阅（OAuth 模式）——
cc login                             # 切到 claude-account，然后进入 claude 交互界面
                                     # 在会话内手动敲 /login → 终端显示 URL → 宿主浏览器
                                     # 授权 → 拷贝 token 回粘 → Ctrl+D 退出（凭据已落盘）
cc                                   # 之后正常使用，走 Claude Pro/Max 配额
cc logout                            # 同样进交互界面，敲 /logout
cc-use deepseek                      # 切回 API Key 供应商，OAuth 自动失活
```

---

## 11. 配置数据流

```
宿主 ~/.docker-cc/mihomo/config.yaml
   │  (卷挂载)
   ▼
容器 /etc/mihomo/config.yaml ──► mihomo daemon ──► 7890 端口
                                                       ▲
                                                       │ HTTP_PROXY
宿主 ~/.docker-cc/claude/settings.json                  │
   │  (卷挂载)                                          │
   ▼                                                    │
容器 /root/.claude/settings.json ──► claude 启动时读 env ┘
                                       │
                                       ▼
                                   调用 LLM API

# 当切到 OAuth 模式时（settings.json 的 env 为空）：
宿主 ~/.docker-cc/claude/.credentials.json
   │  (卷挂载，cc login 后由 claude 写入)
   ▼
容器 /root/.claude/.credentials.json ──► claude 走 OAuth 鉴权
```

`cc-use` 在宿主直接改 `~/.docker-cc/claude/settings.json`，下次 `cc` 启动新容器即生效。OAuth 凭据文件落在同一目录，自动持久化跨容器复用。

### 11.1 metacubexd 面板能做什么、不能做什么

面板是**运行时控制台**，不是配置编辑器。理解这一点很重要：

| 操作 | 面板里能做？ | 实际配置位置 / 说明 |
|---|---|---|
| 输入订阅 URL 加载机场 | ❌ | 由 `.env` 的 `CLASH_SUB_URL` 决定，`cc up <url>` / `cc refresh` 触发拉取 |
| 切换当前节点（核心功能） | ✅ | mihomo 内存状态，写入 `cache.db` 持久化 |
| 切换代理模式（rule/global/direct） | ✅ | 同上 |
| 节点延迟测试 | ✅ | 实时，不写盘 |
| 编辑分流规则（哪些域名走哪组） | ❌ | 规则随订阅源生成在 `config.yaml` 里，订阅自带 |
| 查看实时连接、日志、流量 | ✅ | 只读 |
| 重载配置文件 | ✅ | 等价于 `cc refresh` 后端的"reload"信号 |

简单记忆：**"哪里来的节点"靠 `.env` 决定（部署期），"用哪个节点"靠面板决定（运行期）。**

### 11.2 状态持久化机制

所有状态都通过卷挂载落到宿主，重启容器/电脑/`docker compose down` 都不会丢：

```
~/.docker-cc/repo/.env               ← 订阅 URL
~/.docker-cc/mihomo/config.yaml      ← 上次拉到的订阅内容（节点列表、规则）
~/.docker-cc/mihomo/cache.db         ← ★ 上次选的节点 + 模式 + 节点延迟测速结果
~/.docker-cc/claude/settings.json    ← 当前 LLM 供应商配置（cc-use 写入）
~/.docker-cc/claude/.credentials.json← OAuth 凭据（cc login 写入）
~/.docker-cc/claude/<其他>           ← Claude Code 会话历史、todo 状态等
~/.docker-cc/providers/*.json        ← 各 LLM 供应商模板（含 token）
```

`cache.db` 是 mihomo 自己维护的状态文件，**下次 `cc up` 后面板里看到的节点选择和你上次离开时完全一样**，无需重新选。

### 11.3 模型配置（主模型 vs 小快模型）

#### 两个配置槽

Claude Code 在**单一供应商**内可同时配置两个角色的模型：

| 字段 | 角色 | 典型场景 |
|---|---|---|
| `ANTHROPIC_MODEL` | 主对话模型 | 处理你的实际编码任务，能力优先 |
| `ANTHROPIC_SMALL_FAST_MODEL` | 小快模型 | 会话摘要、文件名建议、tab 补全等后台轻量任务，便宜+快 |

混用搭配的目的是**降本**：主模型用强模型保证质量，小快模型用便宜模型处理高频小请求，整体成本能降到原本一半以下。

#### Anthropic 三档模型

Anthropic 自家供应商提供三档模型，能力 / 速度 / 价格三角递减：

| 档位 | 当前最新版本 | 定位 |
|---|---|---|
| **Opus** | `claude-opus-4-7` | 旗舰，能力最强、最贵、最慢 |
| **Sonnet** | `claude-sonnet-4-6` | 平衡档，性价比高，**Claude Code 默认主模型** |
| **Haiku** | `claude-haiku-4-5` | 轻量档，最快最便宜 |

#### 三档怎么塞进两槽？

```
        三档模型可选                    配置只有两个槽
┌──────────────────────────┐         ┌──────────────────────┐
│  Opus    (强但贵慢)        │  ──┐    │ ANTHROPIC_MODEL      │ ← 主对话用
│  Sonnet  (平衡，日常主力)  │  ──┼──► │                      │
│  Haiku   (便宜超快)        │  ──┘    │ ANTHROPIC_SMALL_FAST │ ← 后台小任务
└──────────────────────────┘         └──────────────────────┘
                                       /model <name>          ← 会话内逃生口
                                       (临时切到第三档)
```

**两槽 + 一个逃生口**，覆盖三档全部用法。

#### 三种典型组合

| 策略 | `ANTHROPIC_MODEL`（主）| `ANTHROPIC_SMALL_FAST_MODEL`（小快）| 何时用 |
|---|---|---|---|
| **默认**（推荐）| Sonnet | Haiku | 日常编码主力，95% 场景 |
| **重活专用** | Opus | Haiku | 复杂重构、跨多文件设计；账单贵约 5 倍 |
| **极致省钱** | Haiku | Haiku | 批量简单任务、对能力要求低 |

不推荐 Opus + Sonnet 组合：小快任务用 Sonnet 浪费钱，Sonnet 不便宜也不算超快。

#### 逃生口模式（最常用工作流）

```bash
# 配置：anthropic 供应商已由 install.sh 从模板预置，编辑填入 token 即可
cc-use edit anthropic
# 默认模板已含 model=claude-sonnet-4-6 + small-model=claude-haiku-4-5，
# 仅需把 ANTHROPIC_AUTH_TOKEN 替换为真实 sk-ant-... 值

cc-use anthropic                # 切到该供应商

# 日常：直接 cc，主对话用 Sonnet，小快自动用 Haiku
cc

# 遇到硬骨头：会话内临时切 Opus
> /model claude-opus-4-7
> 重构这个登录流程，需要兼顾 SSO/MFA/会话过期...
> /model default                 # 搞完切回配置默认（Sonnet）
```

**常驻 = 性价比组合，Opus 按需召唤**，账单最优。Opus 不写进配置，作为 `/model` 临时召唤的"备胎"使用。

#### ⚠ 三档命名只对 Anthropic 官方有效

第三方供应商虽然提供 Anthropic 兼容协议，但**不接受 opus/sonnet/haiku 这些字符串**，只接受自己的 model 名：

| 供应商 | 主模型名示例 | 小快模型名示例 |
|---|---|---|
| Anthropic | `claude-sonnet-4-6` | `claude-haiku-4-5` |
| Kimi | `kimi-k2-turbo-preview` | `moonshot-v1-8k` |
| DeepSeek | `deepseek-chat` | `deepseek-chat`（无单独小快档）|
| 智谱 | `glm-4.6` | `glm-4-flash` |

切到非 Anthropic 供应商后用 `/model claude-opus-4-7` 会报错"未知模型"。**只有 Anthropic 自家供应商**下三档名字才有意义。

#### 单供应商限制

两个 model 必须来自同一个供应商，因为只有一套 `ANTHROPIC_AUTH_TOKEN` + `ANTHROPIC_BASE_URL`：

- ✅ 主 `claude-sonnet-4-6` + 小快 `claude-haiku-4-5`（同走 anthropic.com）
- ✅ 主 `kimi-k2-turbo-preview` + 小快 `moonshot-v1-8k`（同走 moonshot endpoint）
- ❌ 主 Kimi、小快 DeepSeek（两套 API key 没法同时给）

**跨供应商混用模型的进阶玩法**（不在当前方案范围）：在容器与 mihomo 之间再插一层路由网关（如 [LiteLLM proxy](https://github.com/BerriAI/litellm) 或 [claude-code-router](https://github.com/musistudio/claude-code-router)），按模型名分发到不同上游。属于后续可扩展项。

### 11.4 订阅与节点状态触发关系

什么情况下需要重新拉订阅 / 重选节点：

| 触发动作 | 影响 |
|---|---|
| `cc up`（无参，默认） | 复用现有 config.yaml 和 cache.db，秒起 |
| `cc up <new-url>` | 覆盖 .env，强制重拉订阅；节点选择会重置（新订阅节点 ID 变了） |
| `cc refresh` | URL 不变，仅重拉订阅；若新订阅保留了同名节点，cache.db 仍能命中你之前的选择 |
| 手动删 `~/.docker-cc/mihomo/cache.db` | 节点选择回到订阅默认，配置不变 |
| 手动删 `~/.docker-cc/mihomo/config.yaml` | 下次 `cc up` 自动重拉订阅 |

---

## 12. 已知限制与边界

- **正在运行的 `claude` 进程不会感知 `cc-use` 切换**：必须退出当前会话重新 `cc` 才生效（与 cc-switch GUI 行为一致）。
- **OAuth 与 API Key 互斥**：`ANTHROPIC_AUTH_TOKEN` 一旦在 env 中存在，Claude Code 会优先使用，OAuth 凭据被忽略。`cc-use claude-account` / `cc login` 会清空 env；切回其他供应商即恢复 API Key 模式。
- **OAuth 登录建议固定代理节点**：claude.ai 对账号 IP 有风控，频繁切节点（尤其香港/日本之间跳变）可能触发账号锁定。建议在 mihomo 配置里给 `api.anthropic.com`、`claude.ai`、`console.anthropic.com` 锁定一个稳定的美国节点（独立 proxy-group）。
- **代理仅 HTTP/HTTPS 出站**：环境变量法不能代理 UDP/QUIC，但 Claude Code 全是 HTTPS REST，不影响。
- **订阅 URL 包含敏感信息**：仅落到 `~/.docker-cc/repo/.env`，不进镜像层、不进 git。`.env` 应加入 `.gitignore`。
- **多并发会话**：可以多个 terminal 同时 `cc`，每个新建独立 cc 容器，共享同一个 mihomo。
- **容器内 cc-use 只读**：providers 目录在 cc 容器内以 `:ro` 挂载，容器内只能 `list` / `show` / `test` / `<name>` 切换；`add` / `edit` / `remove` 必须从宿主调用（用宿主的 `cc-use` 软链）。这是安全设计：避免容器内程序意外破坏供应商配置。
- **跨平台**：开发在 macOS（Apple Silicon）；Linux x86_64 同样支持（Dockerfile 已用 `TARGETARCH` 多架构）；Windows 仅 WSL2 内可用。
- **端口冲突**：宿主已运行 Clash Verge 时无需特殊处理 —— 7890 不暴露、9090 已改名 19090。若 19090 也被占用，在 `.env` 改 `UI_PORT=别的端口` 即可。
- **首次冷启动**：mihomo 拉订阅 + 启动 ~3-5 秒；之后 `cc` 启动 ~1 秒（仅创建 cc 容器）。
- **不能用 `claude update` 自更新**：Claude Code 装在镜像层，`--rm` 临时容器内的 npm 更新会随容器一起销毁。必须用 `cc upgrade` 在宿主侧 rebuild 镜像。`cc update` 已被脚本拦截并给出提示。配置 / 凭据 / 节点状态在卷挂载目录里，与镜像无关，升级不会丢。
- **`cc` 命令名与系统 C 编译器冲突**：macOS/Linux 的 `cc` 默认是 C 编译器（链接到 clang/gcc）。本方案的 `cc` 软链放在 `/usr/local/bin/`，**会遮蔽**部分构建脚本中的 `cc` 调用（如某些 Makefile）。如有冲突，可通过 `DOCKER_CC_CMD=xc ./install.sh` 重命名（或手动建别名）。绝大多数现代项目用 `gcc`/`clang` 显式指定编译器，不受影响。
- **macOS 自带 Bash 3.2 多字节兼容性**：macOS 因 GPLv3 协议拒绝升级，`/bin/bash` 至今是 2007 年的 3.2.57 版本，在 UTF-8 locale 下处理 `$var紧跟中文字符` 的边界识别有 bug —— 会把中文字符的 UTF-8 首字节"吃"进变量名解析，导致变量展开为空且字符破损。**所有 shell 脚本里 `$var` 后紧跟非 ASCII 字符时必须用 `${var}` 显式分隔**。本方案脚本已统一处理。如自行扩展 `cc-use` / `cc` / `entrypoint.sh`，注意遵守此规则。
- **`cc shell` 等命令需 zsh `hash -r` 后生效**：首次安装后 zsh 可能 cache 了系统 `/usr/bin/cc`（C 编译器）的路径，导致 `cc <子命令>` 被解析为 clang。修复：在终端跑 `hash -r`，或新开终端窗口（zsh 重新扫描 PATH）。

---

## 13. 后续可扩展

- 加 shell prompt 集成（如 starship 模块）实时显示当前供应商。
- 加 `cc doctor` 诊断命令：检查代理通断、API key 有效性、镜像版本。
- 若将来想加 Web 切换面板，按 §11 数据流增加一个监听 7000 端口的 FastAPI 即可，不影响现有 CLI。
- 多账号隔离：通过 `DOCKER_CC_HOME` 环境变量切换不同的 `~/.docker-cc/<profile>` 目录。
- 跨供应商混用模型：在容器与 mihomo 之间加一层路由网关（LiteLLM proxy / claude-code-router），按 model 名分发到不同上游 API key，突破"主+小快必须同供应商"的限制。

---

## 14. 实施步骤建议

每步对应一次提交，附**可执行的验证命令**和**期望输出**。详细测试矩阵见 [docs/testing.md](testing.md)。

### 步骤 1：镜像骨架
**做**：Dockerfile + entrypoint.sh + docker-compose.yml
**验证**：
```bash
docker compose build                                                # 期望：build 成功，无 ERROR
docker compose config -q                                            # 期望：无输出（语法 OK）
shellcheck entrypoint.sh                                            # 期望：无 error 级别问题
echo 'CLASH_SUB_URL="https://your-url"' > .env
docker compose up -d mihomo                                         # 期望：状态 running
docker compose logs mihomo | grep -i "started"                      # 期望：mihomo 启动日志
curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:19090/ui    # 期望：200
```

### 步骤 2：代理出站验证
**做**：确认容器内 HTTP_PROXY 能联通外网
**验证**：
```bash
docker compose run --rm cc curl -sI https://api.anthropic.com       # 期望：HTTP/2 状态行
docker compose run --rm cc curl -sI https://www.gstatic.com/generate_204
                                                                    # 期望：HTTP/2 204
docker compose run --rm cc sh -c 'env | grep -i proxy'              # 期望：HTTP_PROXY=http://mihomo:7890
```

### 步骤 3：Claude Code 接通
**做**：手动写一个 provider，跑 claude
**验证**：
```bash
mkdir -p ~/.docker-cc/providers ~/.docker-cc/claude
cat > ~/.docker-cc/providers/test.json <<EOF
{
  "ANTHROPIC_AUTH_TOKEN": "sk-ant-...",
  "ANTHROPIC_BASE_URL": "https://api.anthropic.com",
  "ANTHROPIC_MODEL": "claude-haiku-4-5"
}
EOF
echo '{"env":'"$(cat ~/.docker-cc/providers/test.json)"'}' > ~/.docker-cc/claude/settings.json
docker compose run --rm cc claude --version                         # 期望：输出版本号
docker compose run --rm cc claude -p "say hi in one word"           # 期望：模型回复
```

### 步骤 4：cc / cc-use 脚本
**做**：实现 `bin/cc` 和 `bin/cc-use`
**验证**：
```bash
shellcheck bin/cc bin/cc-use                                        # 期望：无 error
ln -sf "$PWD/bin/cc" /usr/local/bin/cc
ln -sf "$PWD/bin/cc-use" /usr/local/bin/cc-use

# cc-use 子命令
cc-use list                                                         # 期望：列出已知供应商
cc-use add foo --api-key=K --base-url=https://x.com --model=m
test -f ~/.docker-cc/providers/foo.json && echo OK                  # 期望：OK
cc-use show foo | grep -v 'K' && echo "脱敏 OK"                      # 期望：脱敏 OK
cc-use foo                                                          # 期望：已切换到 ...
cc-use current                                                      # 期望：foo
cc-use remove foo <<< 'y'

# cc 透传 + PWD 正确性
cd /tmp && mkdir -p test-cc-pwd && cd test-cc-pwd && touch marker
cc -p "list files in current dir" | grep marker && echo "PWD OK"    # 期望：PWD OK

# cc up <url> .env 写入正确（含特殊字符的 URL）
cc up "https://test.com/sub?token=x&format=clash"
grep '^CLASH_SUB_URL=' ~/.docker-cc/repo/.env                       # 期望：双引号包裹完整 URL

# cc upgrade 不丢配置
cc-use foo  # 切到 foo
cc upgrade
cc-use current                                                      # 期望：foo（升级未影响配置）
```

### 步骤 5：install.sh + 自动化
**做**：install.sh / uninstall.sh / README.md
**验证**：
```bash
# 干净环境（建议先 docker volume rm + rm -rf ~/.docker-cc）
./install.sh                                                        # 期望：所有步骤打 ✓
which cc cc-use                                                     # 期望：/usr/local/bin/cc{,−use}
test -d ~/.docker-cc/{repo,mihomo,claude,providers} && echo OK      # 期望：OK
test -x ~/.docker-cc/repo/Dockerfile -o -f ~/.docker-cc/repo/Dockerfile && echo OK
docker images docker-cc:latest --format '{{.Size}}'                 # 期望：<1GB

# 国内/国外切换
./install.sh --no-cn-mirror                                         # 期望：build 命令带空 GH_PROXY 等

# 卸载干净
./uninstall.sh
test ! -L /usr/local/bin/cc && echo "卸载 OK"
```

### 步骤 6：bats 单元 + 集成测试套件
**做**：`tests/` 目录（详见 [docs/testing.md](testing.md)）
**验证**：
```bash
bats tests/unit/        # 期望：全绿（cc-use 各子命令 ~20+ 用例）
bats tests/integration/ # 期望：全绿（端到端 ~10+ 场景）
```

### 步骤 7：文档与发布
- 写 README.md（用户视角，链接到本 implementation-plan.md）
- CHANGELOG.md
- LICENSE
- GitHub Actions：每次 PR 跑 shellcheck + bats + docker build

---

## 15. 实施计划（项目级）

§14 是"按步骤照着做"的开发者视角；本节是项目级里程碑、工作量、依赖、风险。

### 15.0 实施进度（v0.1.0 开发追踪）

> ✅ = 代码已落仓库；🟡 = 进行中；⬜ = 待办；🟦 = 写完未跑（需真实 docker / bats 环境验证）

| 里程碑 | 状态 | 备注 |
|---|---|---|
| **M0** 镜像骨架 | ✅ | Dockerfile / docker-compose.yml / entrypoint.sh / .env.example / .gitignore 全部落仓 |
| **M1** 核心通路 | 🟦 | 代码已写（entrypoint.sh 双分支），需真实 build + mihomo 启动验证 |
| **M2** 脚本层 | ✅ | bin/cc + bin/cc-use 完整实现，所有子命令到位 |
| **M3** 工程化 | ✅ | install.sh / uninstall.sh / providers 6 个 / README / LICENSE / CHANGELOG |
| **M4** CI + 发布 | 🟦 | .github/workflows/test.yml 已写、bats 套件已写；需 push GitHub 验证 + 兼容性矩阵跑 |
| **测试套件** | ✅ | 7 个 unit + 6 个 integration .bats 文件 + helpers.bash + fixtures + perf.md + compat-matrix.md |

#### 用户首次实跑发现并修复的 bug

| # | bug | 修复 | 状态 |
|---|---|---|---|
| 23 | `mirror.ghproxy.com` SSL_ERROR_SYSCALL，build 中断 | `install.sh` 加 GH_PROXY 自动 probe（5 源轮询） + `cc probe` 子命令 | ✅ 已修 |
| 24 | macOS Bash 3.2.57 在 UTF-8 locale 下 `$var(中文`...）` 变量展开为空 + 中文首字节丢失 | cc-use 4 处 `$name` → `${name}`；§12 加兼容性说明 | ✅ 已修 |
| 25 | zsh 缓存 `cc` 路径为 `/usr/bin/cc`（C 编译器），新装的 `/usr/local/bin/cc` 不被识别 | §12 补操作说明：`hash -r` 或新开终端 | ✅ 文档化 |
| 26 | `cc panel` 进入后 metacubexd 报 ERR_CONNECTION_REFUSED：浏览器端硬编码 `127.0.0.1:9090`，但端口避让设计映射到 19090 | `~/.docker-cc/repo/docker-compose.override.yml` 临时加 9090:9090 双映射 | 🟡 临时 |
| 27 | 镜像 `/etc/mihomo/ui` 被卷挂载遮蔽，mihomo 启动时自己又下载一份 UI（绕路） | UI 应解压到非挂载路径如 `/usr/share/metacubexd/`，entrypoint 改 `external-ui` 指向那里 | ⬜ 待修 |
| 28 | providers/*.json 文件权限默认 644（API key 明文，多用户机器风险）| install.sh + cc-use add 写入时 `chmod 600`；providers 目录 `chmod 700` | ✅ 已修 |
| 29 | .env 文件权限默认 644（CLASH_SUB_URL 可能内嵌订阅 token）| 所有写入位置 `chmod 600` | ✅ 已修 |
| 30 | install.sh 与 bin/cc probe 探测逻辑代码重复 | 抽到共享脚本 `bin/_cc-probe-ghproxy`，两处统一调用 | ✅ 已修 |
| 31 | install.sh `mkdir -p $PREFIX/bin` 失败未检查（`/usr/local` 无写权限+无 sudo 时静默） | 加 sudo fallback + 失败 fail 提示 `--prefix` 替代 | ✅ 已修 |
| 32 | 所有脚本仅 `set -e`，管道中非末尾命令错误被忽略 | 改为 `set -eo pipefail` | ✅ 已修 |
| 33 | `cc-use test` 探 `/v1/models`，DeepSeek 等兼容供应商不实现，永远返回 404 | 改成 POST `/v1/messages` 占位 model + 状态码语义化解读；附带 `Authorization: Bearer` 头 | ✅ 已修 |

#### 已知待真实环境验证项

| 项 | 阻塞原因 | 状态 |
|---|---|---|
| `docker compose build` 镜像构建成功 | 网络拉 mihomo / yq / metacubexd / npm | ✅ 用户已 build 过 |
| `cc up <真实订阅>` 拉订阅 + mihomo 启动 | 需要订阅 URL | ✅ 用户已跑通 |
| `cc panel` 看到节点列表 + 切节点 | 需面板可访问 | ✅ 用户跑通（用 override） |
| 容器内 `curl -x http://127.0.0.1:7890 anthropic.com` 通 | 节点真实可用 | ✅ 用户跑通 |
| `cc login` OAuth 登录流程 | 需 Claude 账号 + 浏览器 | ✅ 用户跑通（凭据自动复用） |
| `claude -p "hi"` 真实回答 | 需登录 + 节点稳定 | ⬜ 待用户验证 |
| `bats tests/unit/` 全绿 | 需安装 `bats-core` + `jq` 跑一次 | ⬜ 待跑 |
| `bats tests/integration/*` 全绿 | 需镜像 + bats + python（mock server） | ⬜ 待跑 |
| GitHub Actions CI 跑通 | 需 push 到 GitHub repo | ⬜ 待 push |
| 兼容性矩阵 7 项 | 需多平台手动跑 | ⬜ 待跑 |
| 性能基线（perf.md） | 需真实跑测量 | ⬜ 待跑 |

#### 已落仓库的文件清单

```
docker-cc/
├── Dockerfile                          ✅
├── docker-compose.yml                  ✅
├── entrypoint.sh                       ✅
├── .env.example                        ✅
├── .gitignore                          ✅
├── install.sh                          ✅
├── uninstall.sh                        ✅
├── README.md                           ✅
├── CHANGELOG.md                        ✅
├── LICENSE                             ✅
├── bin/{cc,cc-use}                     ✅
├── providers/{anthropic,claude-account,deepseek,kimi,zhipu,minimax}.json.example  ✅
├── tests/
│   ├── unit/{cc-use_add,cc-use_switch,cc-use_show,cc-use_current,cc-use_remove,cc-use_list,cc_up,cc_upgrade}.bats  ✅
│   ├── integration/{01_install,03_provider_switch,04_first_run,05_pwd_isolation,06_url_special_chars,07_upgrade_persistence,08_port_conflict}.bats  ✅
│   ├── fixtures/{helpers.bash,mock-clash-config.yaml,docker-compose.test.yml}    ✅
│   ├── perf.md                         ✅
│   └── compat-matrix.md                ✅
├── .github/workflows/test.yml          ✅
└── docs/{implementation-plan,testing}.md  ✅
```

### 15.1 里程碑总览

| ID | 里程碑 | 工作量 | 关键产出 | 关键路径 |
|----|--------|--------|---------|---------|
| **M0** | 镜像骨架 | 1.5 d | 可 build 的镜像、可启动的 mihomo、面板 200 | ⭐ |
| **M1** | 核心通路 | 2 d | claude 在容器内能调通 anthropic API（手动 provider）| ⭐ |
| **M2** | 脚本层 | 3 d | `cc` / `cc-use` 全套子命令 work | |
| **M3** | 工程化 | 2 d | `install.sh`、`uninstall.sh`、providers 模板、README | |
| **M4** | CI + 发布 | 1 d | GitHub Actions 全绿、兼容性矩阵首次跑、v0.1.0 tag | |

合计 **~10 人天**（单人，不含调试与 review buffer）。串行为主，里程碑内部开发与测试 TDD 并行。

### 15.2 任务分解

#### M0 镜像骨架

**开发任务**：
- T0.1 写 `Dockerfile`（§4 + §4.1 国内加速 ARG）
- T0.2 写 `docker-compose.yml`（§5）
- T0.3 写 `entrypoint.sh` 骨架（§6 case 框架，分支留空）
- T0.4 写 `.env.example` / `.gitignore`

**测试任务**（参 [testing.md](testing.md) §15）：
- TT0.1 静态：`hadolint Dockerfile` / `shellcheck entrypoint.sh` / `docker compose config -q`
- TT0.2 build：国内默认 + `--no-cn-mirror` 各 build 一次成功
- TT0.3 启动：`docker compose up -d mihomo` + `curl :19090/ui` 200

**风险**：
- 🔴 国内拉 GitHub releases 失败（mihomo / yq / metacubexd 三个二进制）→ 多 GH_PROXY 备用 + 文档说明 fallback
- 🟡 `mihomo` / `yq` 版本号过期 → 锁版本，CHANGELOG 跟踪
- 🟡 `node:22-slim` 拉取慢 → docker daemon 配 registry-mirror

**交付物**：可 build 镜像、可启动 mihomo 服务、面板可见。

---

#### M1 核心通路

**开发任务**：
- T1.1 完成 `entrypoint.sh` 的 `mihomo-daemon` 分支（unset HTTP_PROXY、curl 订阅、yq 注入、exec mihomo）
- T1.2 完成 `entrypoint.sh` 的 `cc 服务分支`（健康检查 mihomo:9090、CC_PROVIDER 切换、exec）
- T1.3 手动放 `~/.docker-cc/providers/test.json` 验证 claude 调用

**测试任务**：
- TT1.1 `tests/integration/04_first_run.bats`：`cc up <mock-url>` 30s 内不卡死（HTTP_PROXY 回环回归）
- TT1.2 `docker compose run --rm cc curl -sI https://api.anthropic.com` 状态码合理
- TT1.3 手动：`docker compose run --rm cc claude -p "hi"` 有响应

**风险**：
- 🔴 订阅格式不兼容 V2Ray 等 → 文档明确仅 Clash/Mihomo yaml
- 🟡 entrypoint 健康检查超时不当 → 已设 15s，参数化可调
- 🟡 yq 命令在某些 mihomo config 上失败（多文档 YAML？）→ 单元测试守门

**依赖**：M0 done。

**交付物**：claude 在容器里能正确出站调 anthropic API。

---

#### M2 脚本层

**开发任务**（cc 与 cc-use 可两人并行）：
- T2.1 `bin/cc-use`：cmd_list / current / show / add / edit / remove / test / switch（§7.2）
- T2.2 `bin/cc`：up / down / panel / shell / login / logout / refresh / upgrade / update / 默认（§7.1）
- T2.3 容器/宿主路径自动适配（cc-use 头部 `/.dockerenv` 探测）
- T2.4 防御逻辑：HOST_PWD 保留、source .env 安全提取、拒绝 `claude update`

**测试任务**（TDD 与开发并行）：
- TT2.1 `tests/fixtures/helpers.bash`（[testing.md](testing.md) §1.1）
- TT2.2 全部 `tests/unit/cc-use_*.bats`（add / switch / show / current / remove / list）
- TT2.3 `tests/unit/cc_up.bats`（含特殊字符 URL 回归 #19 #20）
- TT2.4 `tests/integration/05_pwd_isolation.bats`（PWD 污染回归 #2）
- TT2.5 `tests/integration/03_provider_switch.bats`、`06_url_special_chars.bats`

**风险**：
- 🔴 cc 脚本 PWD 处理 bug（已修过一次）→ bats 守门
- 🔴 cc-use 脱敏漏 token → bats 断言无完整 token
- 🟡 jq 跨平台行为差异 → 用纯 jq 表达式，不依赖外部管道

**依赖**：M1 done（cc 脚本调 docker compose 要真能起容器）。

**并行**：T2.1 / T2.2 接口约定一致后两人并行；测试 TDD 与开发并行。

**交付物**：`cc -p "hi"`、`cc-use kimi`、`cc-use add foo --api-key=...` 全部 work。

---

#### M3 工程化

**开发任务**：
- T3.1 `install.sh`：参数解析 + 7 个步骤 + 4 个 flag（§9 + §9.1）
- T3.2 `uninstall.sh`：移除软链 + **不强删** ~/.docker-cc/（怕丢凭据）
- T3.3 `providers/*.example` 6 个模板
- T3.4 `README.md`（用户视角 5 分钟入门 + 链接 docs）
- T3.5 `LICENSE`（建议 MIT）

**测试任务**：
- TT3.1 `tests/integration/01_install.bats`（含 --skip-build / --skip-link / --prefix）
- TT3.2 `tests/integration/07_upgrade_persistence.bats`（cc upgrade 不丢配置）
- TT3.3 `tests/integration/08_port_conflict.bats`（默认 19090 + UI_PORT 覆盖 + 19090 被占失败）

**风险**：
- 🟡 install.sh sudo 处理 → `--prefix` 给非 root 选项
- 🟡 uninstall 误删用户 token → 默认仅删软链，配置目录提示手动删

**依赖**：M2 done。

**交付物**：新机器 `git clone && ./install.sh && cc up <url> && cc -p "hi"` 一气呵成。

---

#### M4 CI + 发布

**开发任务**：
- T4.1 `.github/workflows/test.yml`（4 jobs：static / build / unit / integration）
- T4.2 第一次跑兼容性矩阵（[testing.md](testing.md) §6）：macOS Apple Silicon / Linux x86_64 / arm64 / WSL2
- T4.3 收集性能基线，写到 `tests/perf.md`
- T4.4 v0.1.0 release（git tag + GitHub Release）

**测试任务**：本身就是测试。

**风险**：
- 🟡 GitHub Actions runner 慢，build 时间长 → 用 Docker Buildx cache
- 🟡 兼容性矩阵 7 项跑全成本高 → 仅 release 前跑，平时只 ubuntu-latest

**依赖**：M3 done。

**交付物**：CI 全绿、兼容性矩阵 ≥5/7 pass、v0.1.0 tag。

### 15.3 依赖与并行图

```
M0 ──► M1 ──► M2 ──► M3 ──► M4
            │     ┌────┘ │
            │     │      │
            │   T2.1 ⇄ T2.2 (两人并行)
            │
            └─ TT 测试任务每里程碑都与开发任务 TDD 并行

关键路径：M0 → M1 → M2.{T2.1+T2.2 较长} → M3 → M4
最长串行链 ≈ 1.5+2+3+2+1 = 9.5 d，约 10 人天
```

### 15.4 关键路径与项目级风险

| ID | 风险 | 触发条件 | 缓解 |
|---|---|---|---|
| R1 | 国内 build 完全失败 | mihomo / yq / metacubexd / npm 镜像源全挂 | 多 GH_PROXY 备用源 + npm 国内镜像备用 + 文档 fallback |
| R2 | Claude Code 大版本不兼容 | npm 包重命名环境变量 | 锁 npm 版本 + cc-use 加版本探测 warn |
| R3 | mihomo 配置 schema break | 上游改 external-controller 字段 | yq 注入用幂等表达式 + bats 守门 |
| R4 | docker compose 老版本不识别新语法 | 用户 v2.6 以下 | 已修：用 up -d 幂等替代 ps --status |
| R5 | OAuth 流程改名 | claude /login slash 命令路径变 | 已修：进交互让用户手动敲，不依赖 CLI flag |

### 15.5 回退策略

每个里程碑"前进 / 维持 / 回退"三态：

| 里程碑 | 维持条件失败 | 回退动作 |
|---|---|---|
| M0 | hadolint error 或 build 三次失败 | revert PR；缩范围（先不做国内加速） |
| M1 | curl anthropic.com 长期不通 | 检 mihomo 健康 + entrypoint unset；评估 TUN 模式作为 fallback |
| M2 | bats unit 任一不通 | revert 该子命令实现；最小可用（仅 add/switch） |
| M3 | install.sh 在某平台失败 | 该平台标 unsupported；v0.1.0 仅发主平台 |
| M4 | CI 跑不通 | 标记 alpha 版本，CI 修好再 GA |

### 15.6 交付物清单（v0.1.0）

```
docker-cc/
├── Dockerfile
├── docker-compose.yml
├── entrypoint.sh
├── VERSION
├── .env.example
├── .gitignore
├── bin/
│   ├── cc
│   ├── cc-use
│   └── _cc-probe-ghproxy           # 共享探测脚本，install.sh 和 cc probe 调用
├── providers/
│   ├── anthropic.json.example
│   ├── claude-account.json.example
│   ├── deepseek.json.example
│   ├── kimi.json.example
│   ├── zhipu.json.example
│   └── minimax.json.example
├── install.sh
├── uninstall.sh
├── README.md
├── CHANGELOG.md
├── LICENSE
├── docs/
│   ├── implementation-plan.md
│   └── testing.md
├── tests/
│   ├── unit/*.bats
│   ├── integration/*.bats
│   ├── fixtures/{helpers.bash,mock-clash-config.yaml,docker-compose.test.yml}
│   ├── perf.md
│   └── compat-matrix.md
└── .github/workflows/test.yml
```

### 15.7 v0.1.0 后路线图

§13 后续可扩展项 → 时间表：

| 版本 | 预计 | 内容 |
|---|---|---|
| **v0.2.0** | +2 周 | `cc doctor` 诊断命令、starship prompt 集成、cc-use TUI 选择器 |
| **v0.3.0** | +1 月 | Web 切换面板（FastAPI）、多账号隔离 `DOCKER_CC_HOME` |
| **v0.4.0** | +2 月 | 跨供应商模型路由（LiteLLM / claude-code-router）|
