# CHANGELOG

## [Unreleased]

## [0.2.9] - 2026-05-12

### ⚠ 升级注意（一次性过渡期）

本版本起 `dcc upgrade` 会自动同步宿主 dcc / dcc-use 脚本——但这个能力本身在新版 `dcc` 里。**0.2.8 及以下版本的用户首次升级必须用 quick-install.sh**（一次过渡，之后所有版本 `dcc upgrade` 都能自更新）：

```bash
# 国内
curl -fsSL https://ghfast.top/raw.githubusercontent.com/stephenluo/docker-cc/main/scripts/quick-install.sh \
  | bash -s -- --skip-link

# 海外
curl -fsSL https://raw.githubusercontent.com/stephenluo/docker-cc/main/scripts/quick-install.sh \
  | DCC_GHPROXY= bash -s -- --skip-link --registry=global
```

之后日常升级：`dcc upgrade` 一行搞定（image + host scripts 都升）。

### Added — `dcc upgrade` 同步宿主脚本 + `dcc-use registry` 切换镜像源

**`dcc upgrade` 顺手更新宿主 dcc / dcc-use / compose**（pull image 后自动）
- 之前 `dcc upgrade` 只 `docker compose pull`，不动 `~/.docker-cc/repo/bin/dcc` 等宿主脚本，导致镜像新了但 host 端 `dcc-use` 等还是旧版（缺新命令）
- 现在 pull image 成功后，自动从 release tarball 拉对应版本的 `bin/` + `docker-compose.yml` + `Dockerfile` + `entrypoint.sh` + `.env.example` + `scripts/`，覆盖 `~/.docker-cc/repo/`
- 保护用户数据：不动 `.env` / `providers/` / `VERSION`（VERSION 已由 upgrade 自身改）
- tarball 失败时 print warning + 提示用 quick-install.sh 兜底
- `--keep` / `--build` 跳过此同步（无版本切换时无需拉）

**`dcc-use registry` 一键切换镜像源**
- `dcc-use registry` 显示当前 docker image registry（识别 GHCR / 阿里云 ACR / 自定义）
- `dcc-use registry cn` / `global` / `<前缀>` 改 `~/.docker-cc/repo/.env` 的 `DCC_IMAGE` 前缀（tag 保持不变）。改完跑 `dcc upgrade --keep` 即可从新 registry 拉镜像
- `DCC_ALIYUN_PREFIX` / `DCC_GHCR_OWNER` 环境变量覆盖默认 prefix（fork / 内网用户）
- 11 个新 bats 测试覆盖 show / cn / global / 自定义 / 重复切 / 环境变量覆盖 / 边界

### Fixed
- bin/dcc-use cmd_registry 管道末尾加 `|| true` 兜底 `set -e + pipefail`，否则 grep 找不到 DCC_IMAGE 时让 `cur_img=$(...)` 退出码非 0，整个脚本静默退出，跳过"没找到 DCC_IMAGE"友好提示（同 quick-install.sh / dcc upgrade 已修过的 pattern）

## [0.2.8] - 2026-05-12

### Added — `dcc upgrade` 智能化（自动到 latest + flag 套件）
- **`dcc upgrade`（默认）** 改为探测 `api.github.com/repos/.../releases/latest`，对比当前 VERSION，自动改 VERSION + `.env` 的 `DCC_IMAGE` tag，然后 `docker compose pull`
- **`dcc upgrade --to=<x.y.z>`** 切到指定版本
- **`dcc upgrade --keep`** 保持当前 pin（v0.2.0-v0.2.7 旧默认行为，仅刷新镜像 layer）
- **`dcc upgrade --build`** 本地构建（不变）
- pull 失败自动回退 VERSION + `.env`，给清晰提示
- `DCC_API_BASE` 环境变量：API 基址覆盖，供 bats 注入 mock / GitHub Enterprise 用户改 API 基址
- `DCC_REPO` 环境变量：fork 用户可在 `.env` 加 `DCC_REPO=myfork/docker-cc` 覆盖
- `tests/bats-runner.Dockerfile`：本地 dev 加速镜像（apk add jq curl python3 预装），本地 bats 跑时间 3:52 → 4s
- 5 个新 bats test 覆盖 `--to=` / `--keep` / DCC_API_BASE mock 探测 / API 不可达友好提示 / `--to` 空参报错

### Changed — CI 流程
- **`test.yml` build / integration job 加 `if: github.event_name == 'pull_request'`**，main push 只跑 static + unit（轻量 2-3 min）
- **`test.yml` `concurrency.cancel-in-progress: true`**，同 ref 新 push 自动取消旧 in-progress run
- 4 个原 dcc_upgrade.bats "默认" test 改用 `--keep`，避开 API 依赖

### Fixed — shellcheck 0.9 + hadolint + bats 兼容
- **shellcheck 0.9.0 兼容**（ubuntu 24.04 runner 升级触发，旧 0.8 不报）：
  - `bin/dcc:54` SC2015 `[ -f .env ] && grep -q ... || { ...; exit 1; }` → if/then/else 形式
  - `entrypoint.sh:24` SC2034 `for i in $(seq 1 15)` → `for _`（unused loop var 约定）
  - `entrypoint.sh:29` SC2015 `[ -n "$DCC_PROVIDER" ] && dcc-use ... || true` → if/then/else
- **hadolint DL4006**：`Dockerfile` 顶部加 `SHELL ["/bin/bash", "-o", "pipefail", "-c"]`，让 `curl | gzip` 这类 pipe 任一环节失败即 fail（之前 curl 失败时 gzip 静默读 0 字节让 RUN 假成功，镜像里塞空文件）
- **新增 `.hadolint.yaml`** 忽略 DL3008 / DL3016（apt / npm 不 pin 是设计选择，避免镜像过时）
- **bats unit 6 个 fail 修复**：
  - `bin/dcc-use cmd_add` `read -rp` 在非交互（bats / CI / piped stdin）下立即 EOF，`set -e` 让 jq 写文件那步永远跑不到 → read 后加 `|| true` + if 形式（影响 dcc-use_add.bats #3 #5 + dcc-use_list.bats #10 #11 #13 测试，setup 调 dcc-use add 也挂）
  - `quick_install.bats` test 16 `export PATH=` 污染下个 test setup → 改 `PATH=... run` 局部传递 + 把 bash 也软链进 no-docker-path（alpine PATH 限制后 bash 自身找不到）

## [0.2.2] - 2026-05-12

### Added — 镜像内开发工具全家桶
- **Dockerfile +14 工具**：python 3.11 + pip / git + openssh-client / ripgrep（`rg`，Claude Code Grep tool 后端）/ less / xz-utils / unzip / wget / procps（`ps`）/ iproute2（`ip`）/ file / diffutils（`diff`）/ patch。
- **`python` / `pip` 命令别名**：软链到 python3 / pip3，便于 hooks 与用户脚本调用。
- **`/etc/pip.conf` 关闭 PEP 668**：容器内是隔离环境，`pip install foo` 直接可用（不需要 `--break-system-packages` 或 venv）。
- 镜像 size 从 ~590MB → ~750MB（+160MB），为换"开箱即用"的开发体验。

### Fixed — quick-install.sh API 调用 + 错误处理（v0.2.1 已 main raw 生效，本 release 一并归档）
- **API URL 改走直链**：ghfast.top 实测对 `api.github.com` 返回 403（多数 ghproxy 镜像只代理 raw / release / archive，不代理 REST API）。`quick-install.sh` 的 latest 探测改用 `https://api.github.com` 直链。
- **`set -e + pipefail` 吃掉友好提示修复**：管道末尾加 `|| true`，让 `tag=$(curl|grep|sed)` 失败时不立即退出，走到 `[ -n "$tag" ] || fail "..."` 显示"DCC_VERSION=<x.y.z> 跳过探测"的友好引导。
- **DCC_API_BASE 环境变量**：API 基址覆盖，bats 注入 mock server / GitHub Enterprise 用户改 API 基址。
- **README 故障排查段补 3 条**：`curl | bash` API 探测失败、tarball 下载失败、`dcc upgrade` pull 失败的应对。

### Added — 分发部署方案（B+C 路线）
- **`.github/workflows/release.yml`**：CI 双推 GHCR + 阿里云 ACR，multi-arch（amd64 + arm64）；`workflow_dispatch` dry-run 用 `:dev` tag 隔离，不污染正式 `:latest` / `:VERSION`。
- **`scripts/quick-install.sh`**：一键 `curl | bash` 入口，默认走 ghfast 镜像 raw + release；GitHub API 探测 latest 版本；自动 sha256 校验；trap EXIT 清理 `$TMP`。
- **GitHub Release source tarball**：`git archive` 生成 `docker-cc-<version>.tgz` 自动附加，含 `.sha256` 校验文件；CHANGELOG 段抽取作为 release body。
- **`install.sh --registry=<auto|cn|global|<前缀>>`**：选择镜像源（默认 auto 探测 aliyun.com 决定 cn / global）。
- **`install.sh --build-local`**：跳过 pull 直接本地构建（脱机 / 改 Dockerfile）。
- **`dcc upgrade --build`**：保留旧版本地 rebuild 行为（registry 拉不动时的兜底）。
- **`docs/distribution-plan.md`** + **`docs/distribution-implementation-progress.md`**：完整方案文档 + 实施进度追踪。
- **`tests/unit/install_registry.bats` / `install_symlink.bats` / `quick_install.bats`**：覆盖 registry 选择 / 软链方向 / quick-install 端到端 mock。
- **`tests/fixtures/fake-docker`**：mock docker 二进制，用于单元测试中拦截 `docker compose pull/build`。

### Changed — 分发流程
- **`docker-compose.yml`**：`image` 字段改为 `${DCC_IMAGE:-docker-cc:latest}`，支持 install.sh 写入完整 registry 路径；本地 build 兜底未变。
- **`install.sh` 软链方向（破坏性兼容变更）**：`/usr/local/bin/dcc` 从指向 `$PROJECT_ROOT/bin/dcc` 改为指向 `$REPO_DIR/bin/dcc`（即 `~/.docker-cc/repo/bin/dcc`）。**老用户重跑 install.sh 后即可安全删除 git clone 目录**——`ln -sf` 无差别覆盖旧软链。
- **`dcc upgrade`（默认行为）**：从本地 rebuild 改为 `docker compose pull`，速度从 2-5min 降至 20s-2min；想本地 build 改用 `dcc upgrade --build`。
- **`install.sh [4/7]`**：从 "构建镜像" 改为 "获取镜像"——默认 pull，失败自动 fallback 到本地 build（fallback 前自动 probe GH_PROXY）。
- **README / README.zh-CN**：「5 分钟上手」段重写为「一键安装 / 安全敏感先下载再 bash / 高级安装 / 安装选项」四块；首推 `curl | bash`。

### Fixed
- **`install.sh` 重跑会擦掉 `.env`**：之前 `rsync --delete` 没排除 `.env`，导致重跑时用户的 `CLASH_SUB_URL`、`GH_PROXY` 探测结果都被 `.env.example` 覆盖。已在 rsync 命令加 `--exclude='.env'`。

## [0.1.2-pre-dist]（v0.1.0 ~ v0.1.2 累积，未单独发版本段）

### Added
- 完整设计文档（[docs/implementation-plan.md](docs/implementation-plan.md)，1192 行）
- 完整测试方案（[docs/testing.md](docs/testing.md)，710 行）
- Dockerfile：node:22-slim + mihomo + yq + metacubexd + Claude Code，国内网络默认加速
- docker-compose.yml：mihomo 常驻 + cc 按需运行，端口 19090 避开 Clash Verge
- entrypoint.sh：mihomo-daemon / cc 服务双分支，HTTP_PROXY 回环防御
- bin/dcc：宿主端 wrapper，10 个子命令（up / down / panel / shell / login / logout / refresh / upgrade / update / 透传 claude）
- bin/dcc-use：LLM 供应商管理 + 切换，9 个子命令（list / current / show / add / edit / remove / test / switch / help），支持 API Key 与 OAuth 两种模式
- providers/*.json.example：6 个供应商模板（anthropic / claude-account / deepseek / kimi / zhipu / minimax）
- install.sh：4 个 flag（--no-cn-mirror / --skip-build / --skip-link / --prefix）
- uninstall.sh：默认仅移除软链，--purge 选项彻底清理

### Done（追加）
- M4 CI 配置（.github/workflows/test.yml，static / build / unit / integration 4 jobs）
- tests/ 完整套件：
  - 7 个单元测试（cc-use_add, cc-use_switch, cc-use_show, cc-use_current, cc-use_remove, cc-use_list, cc_up, cc_upgrade）
  - 6 个集成测试（install, provider_switch, first_run, pwd_isolation, url_special_chars, upgrade_persistence, port_conflict）
  - helpers.bash + mock-clash-config.yaml + docker-compose.test.yml fixtures
  - perf.md + compat-matrix.md 模板

### Added（v0.1.0 开发期补充）
- **VERSION 文件**：项目根目录单行版本号（当前 `0.1.0`），`install.sh` 复制到 `~/.docker-cc/repo/VERSION`
- **`dcc --version` / `dcc -v`**：显示版本号并退出，不透传给 claude
- **每次 cc 启动 banner**：在 stderr 打印 `dcc v<version>`，不污染 stdout 管道

### Changed（破坏性变更）
- **命令重命名**：`cc` / `cc-use` → `dcc` / `dcc-use`；`_cc-probe-ghproxy` → `_dcc-probe-ghproxy`。
  - **理由**：`cc` 与系统 C 编译器（链接到 clang/gcc）冲突，多次让用户撞 zsh hash 缓存问题；`dcc` 在主流系统默认空闲（仅极小众 anti-spam 工具同名）。
  - **环境变量**：`CC_PROVIDER` → `DCC_PROVIDER`；脚本内部 `CC_VERSION` → `DCC_VERSION`。
  - **保留**（不改）：项目名 `docker-cc`、目录 `~/.docker-cc/`、环境变量 `DOCKER_CC_HOME`、docker compose service 名 `cc:`、network `cc-net`、container `cc-mihomo`、容器内挂载点 `/root/.cc-providers`。这些是命名空间独立的标识符，与 PATH 命令解耦。
  - **迁移**：用户需 `sudo rm /usr/local/bin/{cc,cc-use}`（清旧 dangling 软链）+ 重跑 `./install.sh` 建立 `dcc` / `dcc-use` 新软链。配置 / 凭据 / 镜像 全部保留。

### Security（代码审核发现）
- **#28 providers/*.json 文件权限**：含明文 API key，原默认 644 同组/其他用户可读。`install.sh` 复制 + `dcc-use add` 写入时显式 `chmod 600`；`~/.docker-cc/providers` 目录 `chmod 700`。
- **#29 .env 文件权限**：`CLASH_SUB_URL` 可能内嵌订阅 token。`install.sh` 创建/更新 + `dcc up <url>` 写入 + `bin/_dcc-probe-ghproxy` 写入时全部 `chmod 600`。

### Fixed（开发期间发现）
- **`dcc-use test` 探测错误的 endpoint**：原来探 `/v1/models`，DeepSeek 等兼容供应商一般没实现，永远返回 404 无法判断真实可用性。改成 POST `/v1/messages` 占位 model，通过 HTTP 状态码语义化判断（400 = endpoint+auth OK / 401 = token 错 / 000 = 网络不通 等），同时附带 `Authorization: Bearer` 头适配更多供应商。
- **#30 GH_PROXY probe 代码重复**：`install.sh` 和 `bin/dcc probe` 之前各内联一份探测逻辑（5 镜像源列表 + curl 探测 + 写 .env），独立维护易脱节。抽到共享脚本 `bin/_dcc-probe-ghproxy`，两处统一调用。
- **#31 install.sh `mkdir -p $PREFIX/bin` 未检查失败**：`/usr/local` 只读且无 sudo 时静默失败。改为先尝试 `mkdir -p`，失败时 fallback `sudo mkdir -p`，仍失败则 fail 并建议 `--prefix=$HOME/.local`。
- **#32 全局 `set -eo pipefail`**：原来仅 `set -e`，管道中错误（如 `curl ... | jq ...`）的非末尾命令失败会被忽略。所有 5 个脚本（dcc / dcc-use / entrypoint / install / uninstall + 新增 _dcc-probe-ghproxy）改为 `set -eo pipefail`。

- **macOS Bash 3.2 多字节兼容性**：`dcc-use` 中 `$name(中文`...）` 在 Apple Bash 3.2.57 下变量展开为空 + 中文首字节丢失。修复：所有 `$var` 紧跟非 ASCII 字符的位置改用 `${var}` 显式分隔（dcc-use 4 处）。
- **`dcc panel` 默认连不上**：metacubexd 浏览器端硬编码 `127.0.0.1:9090`，但端口避让设计映射到 19090，导致首次进 panel 显示"无法连接后端"。临时修复：用户手动 `~/.docker-cc/repo/docker-compose.override.yml` 加 `9090:9090` 第二映射。永久方案待定（破坏 Verge 端口避让 vs 零配置 panel 的 trade-off）。
- **`mirror.ghproxy.com` 频繁挂掉**：build 卡在 `curl: SSL_ERROR_SYSCALL`。修复：`install.sh` 在 build 前自动 probe 5 个 GH_PROXY 备用源选第一个连通的，写入 .env。
- **新增 `dcc probe`**：手动重新探测 GH_PROXY，dcc upgrade 失败时救援。

### Pending
- 真实环境验证：`docker compose build`、`dcc up <真实订阅>`、`claude -p` 出站
- bats 套件本地跑通（需安装 bats-core + jq）
- GitHub Actions CI 首次绿
- 兼容性矩阵首次跑（7 个组合）
- 性能基线收集
- v0.1.0 tag
