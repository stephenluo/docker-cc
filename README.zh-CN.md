# docker-cc

> 把 [Claude Code](https://claude.com/claude-code) 容器化，自带 Mihomo 代理 + Web 面板，多 LLM 供应商一键切换（Anthropic / DeepSeek / Kimi / 智谱 / MiniMax）—— 国内用户友好。

[English](README.md) | **中文**

`dcc` 命令对外行为等同原生 `claude`，但跑在容器里、自带代理、可热切多个 LLM 供应商（API Key / OAuth），通过 `dcc-use` 管理。

---

## 解决什么问题

| 痛点 | 方案 |
|---|---|
| 国内直连 `api.anthropic.com` 不稳 | 镜像内嵌 [Mihomo](https://github.com/MetaCubeX/mihomo)（Clash 内核），所有出站走代理；浏览器面板 [metacubexd](https://github.com/MetaCubeX/metacubexd) 切节点 |
| Claude Code 想用 DeepSeek / Kimi / 智谱 / MiniMax 的 Anthropic 兼容接口 | `dcc-use <name>` 一行切换；token 单独存 `~/.docker-cc/providers/*.json`（chmod 600） |
| 同时想用 Claude Pro/Max 订阅（OAuth）和 API Key 备用 | `dcc-use claude-account` 与 `dcc-use deepseek` 互切，OAuth 凭据持久化 |
| 国内 npm / GitHub 拉取慢/挂掉 | 默认清华 apt + ghproxy + npmmirror；`mirror.ghproxy.com` 抽风时 `dcc probe` 自动切到 `ghfast.top` 等备用源 |
| `~/` 配置被搞乱 | 所有运行时数据集中在 `~/.docker-cc/`，`./uninstall.sh` 干净移除 |

---

## 5 分钟上手

### 一键安装（推荐）

```bash
# 国内（默认走 ghfast 镜像加速 + 阿里云 ACR）
curl -fsSL https://ghfast.top/raw.githubusercontent.com/stephenluo/docker-cc/main/scripts/quick-install.sh | bash

# 海外（直链 GitHub + GHCR）
curl -fsSL https://raw.githubusercontent.com/stephenluo/docker-cc/main/scripts/quick-install.sh \
  | DCC_GHPROXY= bash -s -- --registry=global

# 指定版本
curl -fsSL https://ghfast.top/raw.githubusercontent.com/stephenluo/docker-cc/main/scripts/quick-install.sh \
  | DCC_VERSION=0.2.0 bash
```

完成后：

```bash
dcc up "https://your-airport.com/subscription"
dcc-use edit anthropic           # 填 sk-ant-... 用官方 API
dcc                              # 在任意项目目录用，等同 claude
```

### 安全敏感：先下载再 bash

```bash
curl -fsSL https://ghfast.top/raw.githubusercontent.com/stephenluo/docker-cc/main/scripts/quick-install.sh -o quick-install.sh
less quick-install.sh            # 审计脚本（~80 行）
bash quick-install.sh            # 跑（可附 --registry=global 等参数）
```

### 高级安装（git clone）

适用于：fork 项目、修代码、内网定制、想完整审计整套脚本。

```bash
git clone https://github.com/stephenluo/docker-cc.git docker-cc && cd docker-cc
./install.sh                     # 选项同 quick-install.sh
# 海外用户：./install.sh --registry=global
# 改了 Dockerfile：./install.sh --build-local
```

### 安装选项

| 选项 | 作用 |
|---|---|
| `--registry=auto`（默认） | 探测国内/海外网络选 ACR 或 GHCR |
| `--registry=cn` / `--registry=global` | 强制阿里云 ACR / GHCR |
| `--registry=ghcr.io/myorg` | 自定义 registry 前缀（fork / 企业内网） |
| `--build-local` | 跳过 pull，本地构建（脱机 / 改了 Dockerfile） |
| `--no-cn-mirror` | 关闭国内 apt / npm / GH 加速（fallback build 时生效） |

> **macOS 用户**：首次跑 `dcc` 撞 `cc` 缓存？跑 `hash -r` 清 zsh 命令缓存。命令故意命名为 `dcc` 来从源头避开和 C 编译器 `cc` 的冲突。
>
> **装完后**：工作目录（curl|bash 的 /tmp/ 临时目录或 git clone 出的本地副本）可以直接 `rm -rf`，`dcc` / `dcc-use` 命令通过 `~/.docker-cc/repo/bin/` 的软链继续工作。

---

## 核心命令

### `dcc`（代理 / 容器 / claude 透传）

| 命令 | 作用 |
|---|---|
| `dcc` | 等同 `claude`；自动挂载当前目录到容器 `/workspace` |
| `dcc -p "..."` | 一次性提问（透传 `claude -p`） |
| `dcc -c` | 继续上次会话 |
| `dcc --version` | 显示 dcc 版本，不透传给 claude |
| `dcc up [<url>]` | 启动 mihomo；首次需带订阅 URL，之后无参直接用 `.env` 里的 |
| `dcc down` | 停服务 |
| `dcc panel` | 浏览器打开 metacubexd 面板 |
| `dcc shell` | 进容器调试（bash） |
| `dcc login` / `dcc logout` | Claude 账号 OAuth 流程 |
| `dcc refresh` | 重拉订阅（不改 URL） |
| `dcc upgrade` | 升级到 latest release（探测 `api.github.com`，改 VERSION + `.env`，`docker compose pull` 镜像，再从 release tarball 同步宿主 `bin/` + compose 文件） |
| `dcc upgrade --keep` | 仅刷新镜像 layer，保持当前 pin 版本；宿主脚本不动 |
| `dcc upgrade --to=<x.y.z>` | 切到指定版本 |
| `dcc upgrade --build` | 本地 rebuild（修了 Dockerfile / registry 拉不动时用） |
| `dcc probe` | 重新探测 GH_PROXY 备用源（`upgrade --build` 失败时救援） |
| `dcc logs [-f]` | 看 mihomo 日志 |

### `dcc-use`（LLM 供应商管理 + 镜像源切换）

| 命令 | 作用 |
|---|---|
| `dcc-use` 或 `dcc-use list` | 列出所有供应商，★ 标记当前激活 |
| `dcc-use <name>` | 切到该供应商 |
| `dcc-use current` | 仅打印当前激活的名字 |
| `dcc-use show <name>` | 查看详情，API Key 脱敏 |
| `dcc-use add <name> --api-key=K --base-url=U [--model=M] [--small-model=M]` | 添加 API Key 模式供应商 |
| `dcc-use add <name> --mode=oauth` | 添加 OAuth 模式（Anthropic 账号） |
| `dcc-use edit <name>` | 用 `$EDITOR` 编辑 JSON |
| `dcc-use remove <name>` | 删除（带确认） |
| `dcc-use test [<name>]` | 探测 endpoint 可达性 + token 有效性 |
| `dcc-use registry` | 显示当前镜像源（GHCR / 阿里云 ACR / 自定义） |
| `dcc-use registry cn` | 把 `.env` 的 `DCC_IMAGE` 前缀改为阿里云 ACR（之后跑 `dcc upgrade --keep` 从新源拉镜像）|
| `dcc-use registry global` | 同上，改为 GHCR |
| `dcc-use registry <前缀>` | 同上，自定义 registry 前缀（fork / 内网） |

---

## 预置 LLM 供应商

`install.sh` 部署 6 个模板，`dcc-use edit <name>` 填入 token 即可：

| 名字 | 模型 | 类型 | base_url |
|---|---|---|---|
| `anthropic` | Claude Opus 4.7 / Sonnet 4.6 / Haiku 4.5 | API Key | `api.anthropic.com` |
| `claude-account` | Claude Pro / Max 订阅 | OAuth | (走 `~/.docker-cc/claude/.credentials.json`) |
| `deepseek` | deepseek-chat | API Key | `api.deepseek.com/anthropic` |
| `kimi` | kimi-k2-turbo-preview | API Key | `api.moonshot.cn/anthropic` |
| `zhipu` | glm-4.6 | API Key | `open.bigmodel.cn/api/anthropic` |
| `minimax` | minimax-m2 | API Key | (各自) |

新增任意 Anthropic 兼容供应商：
```bash
dcc-use add custom --api-key=sk-xxx --base-url=https://your.api/anthropic --model=foo-pro
```

> Claude Code 读两个槽：`ANTHROPIC_MODEL`（主对话）和 `ANTHROPIC_SMALL_FAST_MODEL`（后台小任务）；两个 model **必须同供应商**（详见 [implementation-plan §11.3](docs/implementation-plan.md)）。

---

## 架构

```
HOST（宿主机）
├─ dcc, dcc-use                 （PATH 软链）
│   ├─ dcc up      → docker compose up
│   ├─ dcc <args>  → docker compose run --rm cc claude <args>
│   └─ dcc-use     → 改 ~/.docker-cc/cc-home/.claude/settings.json
└─ ~/.docker-cc/
    ├─ mihomo/      config.yaml + cache.db
    ├─ cc-home/     容器内 $HOME（.claude.json + .claude/{settings,凭据} + .npmrc + ...）
    └─ providers/   *.json（chmod 600）
                                          │
                                          │ 卷挂载
                                          ▼
DOCKER 网络：cc-net
├─ mihomo（常驻）       :7890 混合代理  /  :9090 controller + metacubexd UI
└─ cc    （按需 --rm）
    ├─ HTTP_PROXY=http://mihomo:7890
    ├─ ANTHROPIC_* 环境变量从 settings.json 加载
    └─ /workspace = $(pwd)
                                          │
                                          ▼
宿主端口
├─ 127.0.0.1:19090  → metacubexd 面板（默认）
└─ 127.0.0.1:9090   → 仅当存在 docker-compose.override.yml 时
```

完整设计见 [docs/implementation-plan.md](docs/implementation-plan.md)（~1200 行）。

### 容器内含什么

除了 `claude` 本身，镜像预装开发常用工具，让 Claude Code 的 Bash 工具、hooks 和你的脚本"开箱即用"：

| 类别 | 工具 |
|---|---|
| Shell / 编辑器 | bash 5.2 / nano |
| 语言 | python 3.11 + pip（容器内 PEP 668 已关闭，`pip install foo` 直接可用）|
| 版本控制 | git 2.39 + openssh-client |
| 搜索 / pager | ripgrep（`rg`，Claude Code Grep tool 的高性能后端）/ less |
| 压缩 / 下载 | xz-utils / unzip / wget |
| Debug | procps（`ps`）/ iproute2（`ip`）/ file / diffutils（`diff`）/ patch |
| 其他 | curl / jq / ca-certificates / gettext-base（`envsubst`）/ tini |

镜像约 750 MB。若要在容器内 native 编译（`pip install` 含 C 扩展、npm `node-gyp`），需自己进容器装 build-essential / gcc，或 patch Dockerfile 后跑 `dcc upgrade --build` 自构建。

---

## 国内网络优化

`./install.sh` 默认开启三层加速 + 自动 probe：

| 资源 | 默认 |
|---|---|
| apt 源 | `mirrors.tuna.tsinghua.edu.cn` |
| GitHub releases (mihomo / yq / metacubexd) | 自动 probe 5 个 GH_PROXY，写入 `.env` |
| npm registry (Claude Code) | `registry.npmmirror.com` |

出国/海外构建：
```bash
./install.sh --no-cn-mirror
```

`mirror.ghproxy.com` 挂了？跑 `dcc probe` 重新探测（自动切到 `ghfast.top` / `gh-proxy.com` 等）。

---

## 故障排查

| 现象 | 解决 |
|---|---|
| `curl \| bash` 在「探测 latest 版本」处失败（API 403 / 不可达） | api.github.com 被严格防火墙拦住？显式 pin 版本跳过探测：`... \| DCC_VERSION=0.2.0 bash`。（ghfast / ghproxy 镜像普遍不代理 api.github.com，quick-install 始终走直链调用 API。） |
| `curl \| bash` 在 tarball 下载处失败 | 换 `DCC_GHPROXY`：`DCC_GHPROXY=https://gh-proxy.com/ curl ...`，或 `DCC_GHPROXY=` 走直链，或退到 `git clone + ./install.sh` |
| `dcc upgrade` 报 "pull failed" | 试 `dcc upgrade --build` 走本地构建（含 GH_PROXY 探测）。常见原因：registry 临时不可达 |
| `dcc upgrade --build` 报 SSL 错（curl mirror.ghproxy.com 失败） | `dcc probe` 切到备用 GH_PROXY 源（默认 `dcc upgrade` 走 pull，不会触发） |
| `dcc panel` 显示 "无法连接后端" | metacubexd 浏览器端硬编码默认后端是 `127.0.0.1:9090`，但宿主把 controller 映射到了 `19090`。两选一：(a) 在 setup 表单填 `http://127.0.0.1:19090`，密钥**留空**；或 (b) 加一份 `~/.docker-cc/repo/docker-compose.override.yml` 增加 `127.0.0.1:9090:9090` 映射，让默认值零配置可用 |
| `dcc` 命令变成 C 编译器（zsh 报 clang 错） | `hash -r` 清 zsh 命令缓存；新装 dcc 不会撞这坑 |
| OAuth 登录后偶尔被强制重登 | claude.ai 对 IP 风控；在 mihomo 给 `claude.ai` / `api.anthropic.com` 锁定一个稳定的美国节点 |
| 容器内 `dcc-use` 报只读错误 | providers 以 `:ro` 挂载（设计如此，避免容器破坏配置）；管理操作（`add` / `edit` / `remove`）从宿主调用 |
| 升级 Claude Code 用 `dcc update` 报错 | 应该用 `dcc upgrade`（默认 pull；改了 Dockerfile 用 `dcc upgrade --build`）；`update` 在 `--rm` 容器里改的会随容器销毁丢失 |

---

## 已知限制

- **macOS Bash 3.2 多字节兼容性**：脚本里所有 `${var}中文` 已显式分隔避坑，扩展时注意（详见 [implementation-plan §12](docs/implementation-plan.md)）
- **`dcc` 命名小众冲突**：DCC anti-spam（apt 包 `dcc-client`）/ UNSW 教学增强 gcc 等，普通用户不会撞
- **代理仅 HTTP/HTTPS 出站**：环境变量法不代理 UDP/QUIC，但 Claude Code 全是 HTTPS REST
- **容器内 `dcc-use` 只读**：providers 以 `:ro` 挂载，仅支持 `list / show / test / 切换`；`add / edit / remove` 必须宿主调用

---

## 设计与测试文档

- **[docs/implementation-plan.md](docs/implementation-plan.md)** — 项目级实施方案（架构、Dockerfile、脚本逐一拆解、风险、回退策略，~1200 行）
- **[docs/testing.md](docs/testing.md)** — 测试方案（bats 单元/集成、CI、兼容性矩阵；回归矩阵覆盖 33 条修过的 bug）
- **[CHANGELOG.md](CHANGELOG.md)** — 详细变更日志

---

## 卸载

```bash
./uninstall.sh                  # 仅移除 dcc / dcc-use 软链，保留配置 + 凭据
./uninstall.sh --purge          # 一并删除 ~/.docker-cc/（含订阅、token、OAuth 凭据，慎用）
```

---

## 贡献

bug 报告 / PR 欢迎。提交前请：

```bash
shellcheck bin/dcc bin/dcc-use entrypoint.sh install.sh uninstall.sh
docker compose config -q
bats tests/unit/                # 需先 `brew install bats-core jq`
```

---

## License

[MIT](LICENSE)
