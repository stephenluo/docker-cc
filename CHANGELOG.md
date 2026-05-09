# CHANGELOG

## [Unreleased]

### Added
- 完整设计文档（[docs/implementation-plan.md](docs/implementation-plan.md)，1192 行）
- 完整测试方案（[docs/testing.md](docs/testing.md)，710 行）
- Dockerfile：node:22-slim + mihomo + yq + metacubexd + Claude Code，国内网络默认加速
- docker-compose.yml：mihomo 常驻 + cc 按需运行，端口 19090 避开 Clash Verge
- entrypoint.sh：mihomo-daemon / cc 服务双分支，HTTP_PROXY 回环防御
- bin/cc：宿主端 wrapper，10 个子命令（up / down / panel / shell / login / logout / refresh / upgrade / update / 透传 claude）
- bin/cc-use：LLM 供应商管理 + 切换，9 个子命令（list / current / show / add / edit / remove / test / switch / help），支持 API Key 与 OAuth 两种模式
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
- **`cc --version` / `cc -v`**：显示版本号并退出，不透传给 claude
- **每次 cc 启动 banner**：在 stderr 打印 `cc v<version>`，不污染 stdout 管道

### Fixed（开发期间发现）
- **macOS Bash 3.2 多字节兼容性**：`cc-use` 中 `$name(中文`...）` 在 Apple Bash 3.2.57 下变量展开为空 + 中文首字节丢失。修复：所有 `$var` 紧跟非 ASCII 字符的位置改用 `${var}` 显式分隔（cc-use 4 处）。
- **`cc panel` 默认连不上**：metacubexd 浏览器端硬编码 `127.0.0.1:9090`，但端口避让设计映射到 19090，导致首次进 panel 显示"无法连接后端"。临时修复：用户手动 `~/.docker-cc/repo/docker-compose.override.yml` 加 `9090:9090` 第二映射。永久方案待定（破坏 Verge 端口避让 vs 零配置 panel 的 trade-off）。
- **`mirror.ghproxy.com` 频繁挂掉**：build 卡在 `curl: SSL_ERROR_SYSCALL`。修复：`install.sh` 在 build 前自动 probe 5 个 GH_PROXY 备用源选第一个连通的，写入 .env。
- **新增 `cc probe`**：手动重新探测 GH_PROXY，cc upgrade 失败时救援。

### Pending
- 真实环境验证：`docker compose build`、`cc up <真实订阅>`、`claude -p` 出站
- bats 套件本地跑通（需安装 bats-core + jq）
- GitHub Actions CI 首次绿
- 兼容性矩阵首次跑（7 个组合）
- 性能基线收集
- v0.1.0 tag
