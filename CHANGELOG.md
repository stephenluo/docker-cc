# CHANGELOG

## [Unreleased]

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
