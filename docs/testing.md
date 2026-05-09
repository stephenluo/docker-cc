# docker-cc 测试方案

> 配套 [implementation-plan.md](implementation-plan.md)。本文档定义测试矩阵、工具链和具体用例。每个用例都对应一个或多个已识别风险。

---

## 0. 测试栈

| 类型 | 工具 | 用途 |
|---|---|---|
| 静态检查 | `shellcheck` | shell 脚本 lint |
| 静态检查 | `docker compose config` | compose YAML 语法验证 |
| 静态检查 | `yamllint`（可选） | YAML 格式 |
| 静态检查 | `hadolint` | Dockerfile 最佳实践 |
| 单元测试 | [bats-core](https://github.com/bats-core/bats-core) | shell 脚本测试 |
| Mock | 自写 fake HTTP server（python `-m http.server` / `nc`） | mock 订阅 URL、mock provider API |
| 集成测试 | bats + docker compose | 端到端 |
| CI | GitHub Actions | 每 PR 自动跑 |

安装：
```bash
# macOS
brew install shellcheck bats-core hadolint

# Debian/Ubuntu
sudo apt install shellcheck bats jq
# hadolint 在 apt 里没有官方包，改用 docker 或 GitHub release 二进制：
docker pull hadolint/hadolint                              # 推荐
# 或：
curl -fsSL "https://github.com/hadolint/hadolint/releases/latest/download/hadolint-Linux-x86_64" \
  -o /usr/local/bin/hadolint && chmod +x /usr/local/bin/hadolint
```

---

## 1. 测试目录结构

```
docker-cc/
├── tests/
│   ├── unit/
│   │   ├── cc-use_add.bats
│   │   ├── cc-use_switch.bats
│   │   ├── cc-use_show.bats
│   │   ├── cc-use_current.bats
│   │   ├── cc-use_remove.bats
│   │   ├── cc-use_list.bats
│   │   ├── cc_up.bats
│   │   └── cc_upgrade.bats
│   ├── integration/
│   │   ├── 01_install.bats
│   │   ├── 02_first_run.bats
│   │   ├── 03_provider_switch.bats
│   │   ├── 04_oauth_flow.bats
│   │   ├── 05_pwd_isolation.bats
│   │   ├── 06_url_special_chars.bats
│   │   ├── 07_upgrade_persistence.bats
│   │   └── 08_port_conflict.bats
│   ├── fixtures/
│   │   ├── mock-clash-config.yaml      # 假订阅，含一个 DIRECT 节点
│   │   ├── mock-providers/             # 测试用 provider JSON
│   │   └── helpers.bash                # 共用 setup/teardown
│   └── README.md
└── .github/
    └── workflows/
        └── test.yml
```

---

## 1.1 测试隔离策略

bats 测试**不能污染用户真实的 `~/.docker-cc/`**。每个测试用 BATS_TEST_TMPDIR 作为隔离 home，并通过环境变量重定向所有产物路径：

| 隔离项 | 单元测试 | 集成测试 |
|---|---|---|
| 供应商目录 | `PROVIDERS_DIR=$BATS_TEST_TMPDIR/providers` | 同左 |
| settings.json | `CLAUDE_SETTINGS=$BATS_TEST_TMPDIR/settings.json` | 同左 |
| compose 工作目录（cc 脚本） | `DOCKER_CC_HOME=$BATS_TEST_TMPDIR/repo` | 同左 + 复制真实 docker-compose.yml 进去 |
| PATH | `PATH=$PROJECT_ROOT/bin:$PATH`（让测试调用项目内 cc / cc-use） | 同左 |
| HOME | 单元测试不需要改 HOME | 集成测试**必须** `export HOME=$BATS_TEST_TMPDIR`：docker compose 读 `${HOME}/.docker-cc/...` 做卷挂载，不隔离会污染真实环境 |

`BATS_TEST_TMPDIR` 由 bats 自动创建并在测试结束时清理，无需 teardown。

### `tests/fixtures/helpers.bash` 内容

```bash
#!/usr/bin/env bash
# 由所有 bats 文件 load ../../fixtures/helpers 引入

PROJECT_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
export PROJECT_ROOT

# 让测试中调用 cc / cc-use 时找到项目内的脚本而不是已安装的版本
export PATH="$PROJECT_ROOT/bin:$PATH"

# 单元测试：每个 test 独立 PROVIDERS_DIR / SETTINGS
isolate_unit_env() {
  export PROVIDERS_DIR="$BATS_TEST_TMPDIR/providers"
  export CLAUDE_SETTINGS="$BATS_TEST_TMPDIR/settings.json"
  mkdir -p "$PROVIDERS_DIR"
  echo '{}' > "$CLAUDE_SETTINGS"
}

# 集成测试：完整重定向 cc 脚本的 compose 目录
isolate_integration_env() {
  isolate_unit_env
  export DOCKER_CC_HOME="$BATS_TEST_TMPDIR/repo"
  mkdir -p "$DOCKER_CC_HOME"
  cp "$PROJECT_ROOT/docker-compose.yml" "$DOCKER_CC_HOME/"
  cp "$PROJECT_ROOT/Dockerfile" "$DOCKER_CC_HOME/"
  cp "$PROJECT_ROOT/entrypoint.sh" "$DOCKER_CC_HOME/"
  cp -r "$PROJECT_ROOT/bin" "$DOCKER_CC_HOME/"
  touch "$DOCKER_CC_HOME/.env"
}

# 启动 mock 订阅 server，返回容器内可达的 URL
# host.docker.internal 在 Docker Desktop 自带；Linux 需通过 docker-compose.test.yml 的
# extra_hosts: "host.docker.internal:host-gateway" 注入，详见 §4.4
start_mock_subscription_server() {
  local port="${1:-8765}"
  python3 -m http.server "$port" --bind 0.0.0.0 \
    --directory "$PROJECT_ROOT/tests/fixtures" >/dev/null 2>&1 &
  echo "$!" > "$BATS_TEST_TMPDIR/mock_pid"
  echo "http://host.docker.internal:${port}/mock-clash-config.yaml"
}

stop_mock_subscription_server() {
  [ -f "$BATS_TEST_TMPDIR/mock_pid" ] && kill "$(cat "$BATS_TEST_TMPDIR/mock_pid")" 2>/dev/null || true
}
```

---

## 2. 静态检查（CI 第一关）

每次 PR 必跑，~10 秒：

```bash
# shell 脚本
shellcheck bin/cc bin/cc-use entrypoint.sh install.sh uninstall.sh

# Dockerfile
hadolint Dockerfile

# compose
docker compose -f docker-compose.yml config -q

# yaml（可选）
yamllint -d relaxed docker-compose.yml
```

**通过标准**：所有命令退出码 0。shellcheck 允许 SC2155 等少量风格警告（用 `# shellcheck disable=...` 标注），不允许 error 级别。

---

## 3. 单元测试（bats）

### 3.1 cc-use add

`tests/unit/cc-use_add.bats`：

```bash
#!/usr/bin/env bats
load ../fixtures/helpers

setup() { isolate_unit_env; }

@test "add: api-key 模式生成完整 JSON" {
  run cc-use add foo \
    --api-key=sk-test \
    --base-url=https://api.example.com \
    --model=foo-pro \
    --small-model=foo-mini
  [ "$status" -eq 0 ]
  [ -f "$PROVIDERS_DIR/foo.json" ]
  run jq -r '.ANTHROPIC_AUTH_TOKEN' "$PROVIDERS_DIR/foo.json"
  [ "$output" = "sk-test" ]
  run jq -r '.ANTHROPIC_BASE_URL' "$PROVIDERS_DIR/foo.json"
  [ "$output" = "https://api.example.com" ]
  run jq -r '.ANTHROPIC_MODEL' "$PROVIDERS_DIR/foo.json"
  [ "$output" = "foo-pro" ]
  run jq -r '.ANTHROPIC_SMALL_FAST_MODEL' "$PROVIDERS_DIR/foo.json"
  [ "$output" = "foo-mini" ]
}

@test "add: --mode=oauth 仅写 _mode 字段" {
  run cc-use add my-account --mode=oauth
  [ "$status" -eq 0 ]
  run jq -r '._mode' "$PROVIDERS_DIR/my-account.json"
  [ "$output" = "oauth" ]
  run jq 'has("ANTHROPIC_AUTH_TOKEN")' "$PROVIDERS_DIR/my-account.json"
  [ "$output" = "false" ]
}

@test "add: --key-name=ANTHROPIC_API_KEY 写到正确字段" {
  run cc-use add bar --api-key=K --base-url=U --key-name=ANTHROPIC_API_KEY
  [ "$status" -eq 0 ]
  run jq -r '.ANTHROPIC_API_KEY' "$PROVIDERS_DIR/bar.json"
  [ "$output" = "K" ]
  run jq 'has("ANTHROPIC_AUTH_TOKEN")' "$PROVIDERS_DIR/bar.json"
  [ "$output" = "false" ]
}

@test "add: 未知参数报错" {
  run cc-use add foo --invalid=x
  [ "$status" -ne 0 ]
  [[ "$output" =~ "未知参数" ]]
}
```

### 3.2 cc-use switch

```bash
@test "switch: api-key 模式把字段写入 settings.env" {
  echo '{"ANTHROPIC_AUTH_TOKEN":"K","ANTHROPIC_BASE_URL":"U"}' > "$PROVIDERS_DIR/foo.json"
  run cc-use foo
  [ "$status" -eq 0 ]
  run jq -r '.env.ANTHROPIC_AUTH_TOKEN' "$CLAUDE_SETTINGS"
  [ "$output" = "K" ]
}

@test "switch: oauth 模式清空 env" {
  echo '{"ANTHROPIC_AUTH_TOKEN":"K"}' > "$PROVIDERS_DIR/foo.json"
  cc-use foo
  echo '{"_mode":"oauth"}' > "$PROVIDERS_DIR/oa.json"
  run cc-use oa
  [ "$status" -eq 0 ]
  run jq '.env' "$CLAUDE_SETTINGS"
  [ "$output" = "{}" ]
}

@test "switch: 不存在的供应商报错" {
  run cc-use ghost
  [ "$status" -ne 0 ]
  [[ "$output" =~ "找不到供应商" ]]
}

@test "switch: 下划线开头字段不写入 env" {
  echo '{"_mode":"api-key","_comment":"x","ANTHROPIC_AUTH_TOKEN":"K","ANTHROPIC_BASE_URL":"U"}' \
    > "$PROVIDERS_DIR/foo.json"
  cc-use foo
  run jq 'has("_mode")' <(jq '.env' "$CLAUDE_SETTINGS")
  [ "$output" = "false" ]
}
```

### 3.3 cc-use show 脱敏

```bash
@test "show: API Key 脱敏（不含完整值）" {
  echo '{"ANTHROPIC_AUTH_TOKEN":"sk-ant-secret-12345","ANTHROPIC_BASE_URL":"U"}' \
    > "$PROVIDERS_DIR/foo.json"
  run cc-use show foo
  [ "$status" -eq 0 ]
  ! [[ "$output" =~ "sk-ant-secret-12345" ]]      # 完整 token 不应出现
}
```

### 3.4 current_provider 反查

```bash
@test "current: settings env 匹配则返回正确名字" {
  echo '{"ANTHROPIC_AUTH_TOKEN":"K","ANTHROPIC_BASE_URL":"U1"}' > "$PROVIDERS_DIR/foo.json"
  echo '{"ANTHROPIC_AUTH_TOKEN":"K","ANTHROPIC_BASE_URL":"U2"}' > "$PROVIDERS_DIR/bar.json"
  echo '{"env":{"ANTHROPIC_AUTH_TOKEN":"K","ANTHROPIC_BASE_URL":"U2"}}' > "$CLAUDE_SETTINGS"
  run cc-use current
  [ "$output" = "bar" ]
}

@test "current: env 为空 + 有 oauth 模式供应商 → 返回 oauth 供应商名" {
  echo '{"_mode":"oauth"}' > "$PROVIDERS_DIR/oa.json"
  echo '{"env":{}}' > "$CLAUDE_SETTINGS"
  run cc-use current
  [ "$output" = "oa" ]
}
```

### 3.5 cc up（含 URL 特殊字符回归）

```bash
setup() { isolate_integration_env; }   # 注意：需要 DOCKER_CC_HOME 隔离，不是 unit

@test "cc up: URL 含 & 不会破坏 .env（回归 #19 #20 URL 特殊字符）" {
  # cc 脚本会调 docker compose up；mock 不到真镜像就 exit 非零，但 .env 已写入
  cc up "https://test.com/sub?token=x&format=clash" 2>/dev/null || true
  run grep '^CLASH_SUB_URL=' "$DOCKER_CC_HOME/.env"
  [[ "$output" == *'?token=x&format=clash'* ]]
}

@test "cc up: URL 在 .env 中带双引号（防御 shell 元字符）" {
  cc up "https://test.com/sub?a=1&b=2" 2>/dev/null || true
  run grep '^CLASH_SUB_URL=' "$DOCKER_CC_HOME/.env"
  # 形如 CLASH_SUB_URL="https://..."
  [[ "$output" == *'CLASH_SUB_URL="'* ]]
}

@test "cc up: 二次调用换 URL 会覆盖（不重复）" {
  cc up "https://a.com/sub" 2>/dev/null || true
  cc up "https://b.com/sub" 2>/dev/null || true
  run grep -c '^CLASH_SUB_URL=' "$DOCKER_CC_HOME/.env"
  [ "$output" = "1" ]
  run grep '^CLASH_SUB_URL=' "$DOCKER_CC_HOME/.env"
  [[ "$output" == *"b.com"* ]]
}
```

---

## 4. 集成测试（bats + docker compose）

### 4.1 Mock 订阅

`tests/fixtures/mock-clash-config.yaml`：
```yaml
mixed-port: 7890
external-controller: 0.0.0.0:9090
mode: rule
proxies:
  - { name: direct, type: direct }
proxy-groups:
  - { name: PROXY, type: select, proxies: [direct] }
rules:
  - MATCH,PROXY
```

集成测试用 `python3 -m http.server` 起一个本地 HTTP server 提供这个文件，模拟订阅 URL。

### 4.2 端到端：首次安装

`tests/integration/01_install.bats`：
```bash
load ../fixtures/helpers
setup() {
  # 隔离 HOME，避免污染真实 ~/.docker-cc/
  export HOME="$BATS_TEST_TMPDIR"
  export PROJECT_ROOT  # 来自 helpers
}

@test "install.sh 创建所有期望产物（隔离安装）" {
  cd "$PROJECT_ROOT"
  # --skip-build：CI 中已单独 build；--skip-link / --prefix：装到隔离目录避免 sudo
  run ./install.sh --skip-build --skip-link --prefix="$BATS_TEST_TMPDIR/local"
  [ "$status" -eq 0 ]
  [ -d "$HOME/.docker-cc/repo" ]
  [ -f "$HOME/.docker-cc/repo/Dockerfile" ]
  [ -d "$HOME/.docker-cc/providers" ]
  # --skip-link 时不应建 symlink
  [ ! -L "$BATS_TEST_TMPDIR/local/bin/cc" ]
}

@test "install.sh --prefix 模式建 symlink 到指定目录" {
  cd "$PROJECT_ROOT"
  run ./install.sh --skip-build --prefix="$BATS_TEST_TMPDIR/local"
  [ "$status" -eq 0 ]
  [ -L "$BATS_TEST_TMPDIR/local/bin/cc" ]
  [ -L "$BATS_TEST_TMPDIR/local/bin/cc-use" ]
}
```

### 4.3 端到端：PWD 隔离（回归 #2 PWD 污染）

`tests/integration/05_pwd_isolation.bats`：
```bash
load ../fixtures/helpers
setup() { isolate_integration_env; }

@test "在 /tmp/X 目录敲 cc，容器内 /workspace 是 /tmp/X" {
  d="$BATS_TEST_TMPDIR/some-project"
  mkdir -p "$d"
  echo "marker-content" > "$d/MARKER"
  cd "$d"
  # 不通过 claude LLM（输出不可预测），直接用 cat 验证挂载
  # 跳过 entrypoint（用 --entrypoint cat），跳过 mihomo 依赖（无 depends_on 因为没走 compose）
  run docker run --rm \
    -v "$d:/workspace" \
    --entrypoint cat \
    docker-cc:latest \
    /workspace/MARKER
  [ "$status" -eq 0 ]
  [ "$output" = "marker-content" ]
}

@test "cc 脚本 cd 后仍能挂载用户原始 PWD（HOST_PWD 机制）" {
  d="$BATS_TEST_TMPDIR/some-project"
  mkdir -p "$d"
  echo "ok-from-host-pwd" > "$d/MARKER"
  cd "$d"
  # 模拟 cc 脚本行为：保存 HOST_PWD 然后 cd 到 compose 目录
  HOST_PWD="$d" docker compose -f "$DOCKER_CC_HOME/docker-compose.yml" \
    run --rm --no-deps --entrypoint cat cc /workspace/MARKER
  # 期望输出内容来自 $d/MARKER，证明 HOST_PWD 机制有效
}
```

### 4.4 端到端：mihomo 启动不回环（回归 #14 HTTP_PROXY 回环）

`host.docker.internal` 在 Docker Desktop 自带，但 Linux 默认无该 hostname。集成测试通过临时 compose override 文件加 `extra_hosts: host-gateway` 兼容 Linux：

`tests/fixtures/docker-compose.test.yml`：
```yaml
services:
  mihomo:
    extra_hosts:
      - "host.docker.internal:host-gateway"   # docker 20.10+ 内置，跨平台
```

```bash
@test "首次 cc up <url> 不会卡死在 HTTP_PROXY 回环" {
  isolate_integration_env
  cp "$PROJECT_ROOT/tests/fixtures/docker-compose.test.yml" "$DOCKER_CC_HOME/"
  # 让 cc 脚本同时加载 base + override
  export COMPOSE_FILE="docker-compose.yml:docker-compose.test.yml"

  url=$(start_mock_subscription_server 8765)
  trap stop_mock_subscription_server EXIT

  # 30s 超时：HTTP_PROXY 回环 bug 复现时会无限等待
  timeout 30 cc up "$url"
  [ "$?" -eq 0 ]

  run docker compose -f "$DOCKER_CC_HOME/docker-compose.yml" \
                     -f "$DOCKER_CC_HOME/docker-compose.test.yml" \
                     ps -q mihomo
  [ -n "$output" ]
}
```

### 4.5 端到端：升级不丢配置（回归 cc upgrade）

```bash
load ../fixtures/helpers
setup() {
  isolate_integration_env
  # 关键：override HOME 让 docker compose 卷挂载也走 BATS_TEST_TMPDIR/.docker-cc/
  export HOME="$BATS_TEST_TMPDIR"
  mkdir -p "$HOME/.docker-cc/claude" "$HOME/.docker-cc/providers"
}

@test "cc upgrade 后 settings.json 和 providers 仍存在（不污染真实环境）" {
  cc-use add foo --api-key=K --base-url=U
  cc-use foo
  before=$(jq -r '.env.ANTHROPIC_AUTH_TOKEN' "$CLAUDE_SETTINGS")
  [ "$before" = "K" ]
  cc upgrade
  after=$(jq -r '.env.ANTHROPIC_AUTH_TOKEN' "$CLAUDE_SETTINGS")
  [ "$after" = "K" ]
  [ -f "$PROVIDERS_DIR/foo.json" ]
}
```

> **⚠ 集成测试警告**：本节所有用例都通过 `export HOME=$BATS_TEST_TMPDIR` 隔离用户真实环境。**严禁在测试中直接写 `~/.docker-cc/...`**（除非用 `$HOME` 引用）。CI runner 是临时 VM，污染无所谓；本地开发跑 integration 测试一定要先确认 setup 了 HOME 隔离。

### 4.6 端到端：端口配置（回归端口冲突避让设计）

```bash
load ../fixtures/helpers
setup() { isolate_integration_env; }
teardown() { stop_mock_subscription_server; cc down 2>/dev/null || true; }

@test "默认端口：19090（不与宿主 Clash Verge 的 9090 冲突）" {
  url=$(start_mock_subscription_server)
  cc up "$url"
  # 等 mihomo 起来
  for i in 1 2 3 4 5; do curl -sf http://127.0.0.1:19090/ui && break; sleep 1; done
  run curl -sf -o /dev/null -w '%{http_code}' http://127.0.0.1:19090/ui
  [ "$output" = "200" ]
  # 7890 不应该被映射到宿主：用 bash 内置 /dev/tcp 探测，不依赖外部 nc
  ! (echo > /dev/tcp/127.0.0.1/7890) 2>/dev/null
}

@test "UI_PORT=20000 覆盖生效" {
  echo "UI_PORT=20000" > "$DOCKER_CC_HOME/.env"
  url=$(start_mock_subscription_server)
  cc up "$url"
  for i in 1 2 3 4 5; do curl -sf http://127.0.0.1:20000/ui && break; sleep 1; done
  run curl -sf -o /dev/null -w '%{http_code}' http://127.0.0.1:20000/ui
  [ "$output" = "200" ]
  ! (echo > /dev/tcp/127.0.0.1/19090) 2>/dev/null   # 默认端口不再被占
}

@test "宿主已占 19090 时，cc up 应失败并提示用户改 UI_PORT" {
  python3 -m http.server 19090 >/dev/null 2>&1 &
  blocker=$!
  trap "kill $blocker" RETURN
  url=$(start_mock_subscription_server 8766)
  run cc up "$url"
  [ "$status" -ne 0 ]   # docker compose 应报端口冲突
}
```

---

## 5. 回归测试清单

每个修过的 bug 对应至少一个测试。优先级 P1 必须有 bats 用例（"#" 列对应 implementation-plan §14 之前审核出的 22 个 bug 编号）：

| # | 修复点 | 测试位置 | 优先级 |
|---|---|---|---|
| 1 | 容器/宿主路径不一致 | `unit/cc-use_*.bats`（用 PROVIDERS_DIR override 验证） | P1 |
| 2 | PWD 污染 | `integration/05_pwd_isolation.bats` | P1 |
| 3 | CC_PROVIDER / HOST_PWD 透传 | `integration/05_pwd_isolation.bats` 副产物 | P2 |
| 4 | yq 缺失 | docker build 即验证（步骤 1） | P1 |
| 5 | anthropic.json 字段不全 | `unit/cc-use_add.bats`（add 后 jq 字段） | P2 |
| 6 | 国内网络优化 | CI 中 build 默认值通过即可；切 `--no-cn-mirror` 单独 build 一次 | P3 |
| 7 | providers 容器内只读 | 跑 `docker compose run cc cc-use add foo` 应失败 | P3 |
| 8 | docker compose ps 兼容 | 改用 up -d 后无需测 | P3 |
| 9 | sed URL 转义 | 与 #19、#20 同测，`unit/cc_up.bats` | P1 |
| 10 | list 表头对齐 | 视觉，不测 | - |
| 11 | cc 命令冲突 | 文档说明，不测 | - |
| 12 | 订阅格式约束 | 文档说明，不测 | - |
| 13 | .gitignore 包含 | 静态：grep 检查 .gitignore 含 .env | P3 |
| 14 | HTTP_PROXY 回环 | `integration/04_first_run.bats` 不超时 | P1 |
| 15 | REFRESH_SUB 透传 | `cc up <new-url>` 后 mihomo logs 含"拉订阅" | P2 |
| 16 | compose build context | `docker compose build` 不报错 | P1 |
| 17 | cc panel Linux | 在 Linux runner 上 cc panel 不报错 | P3 |
| 18 | 健康检查改 mihomo | `cc -p` 不卡 15 秒 | P2 |
| 19 | source .env 安全提取（URL 含 `&`）| `unit/cc_up.bats` URL 特殊字符用例 | P1 |
| 20 | URL 加引号写入 .env | `unit/cc_up.bats` 验证带双引号 | P1 |
| 21 | /login 是会话内命令 | `cc login` 进入交互不直接执行（手动验证） | P2 |
| 22 | OAuth 与 API key 互斥 | `unit/cc-use_switch.bats` oauth 用例 | P2 |
| 23 | macOS Bash 3.2 多字节 `$var中文` 兼容 | `unit/cc-use_macos_bash32.bats`（断言变量值 + 中文括号完整） | P1 |
| 24 | GH_PROXY 镜像源 probe | `unit/cc_probe.bats`（验证 .env 写入 + 幂等）；CI 中需外网 | P2 |
| 25 | metacubexd 默认连 9090 / 端口避让冲突 | 手动验证（panel 浏览器侧），文档 + override 临时方案 | P3 |

---

## 6. 兼容性矩阵

每个 release 前手动跑一次，结果记入 `tests/compat-matrix.md`：

| 平台 | docker | compose | 状态 |
|---|---|---|---|
| macOS 14 (Apple Silicon) + Docker Desktop | 25.x | v2.30 | ⬜ |
| macOS 14 (Apple Silicon) + OrbStack | 25.x | v2.30 | ⬜ |
| macOS 14 (Apple Silicon) + Colima | 25.x | v2.30 | ⬜ |
| Ubuntu 22.04 (x86_64) | 24.x | v2.20 | ⬜ |
| Ubuntu 22.04 (arm64) | 24.x | v2.20 | ⬜ |
| Debian 12 (x86_64) | 24.x | v2.6（最低版） | ⬜ |
| WSL2 Ubuntu | 24.x | v2.20 | ⬜ |

每个组合至少跑：
1. 步骤 1-5 的所有验证命令
2. `bats tests/integration/*.bats`
3. 一次完整 cc → claude 交互（手动验证 token 流）

---

## 7. 性能基线

记入 `tests/perf.md`：

| 指标 | 期望 | 实测命令 |
|---|---|---|
| 镜像大小 | < 1 GB | `docker images docker-cc:latest --format '{{.Size}}'` |
| 镜像 build 时长（国内冷构建） | < 5 min | `time docker compose build --no-cache` |
| 首次 `cc up` 冷启动 | < 10 s | `time cc up <url>` |
| 热启动 `cc -p "hi"`（mihomo 已 running） | < 3 s | `time cc -p "hi"` |
| `cc-use <name>` 切换耗时 | < 100 ms | `time cc-use kimi` |

---

## 8. CI 配置

`.github/workflows/test.yml` 关键阶段：

```yaml
name: test
on: [push, pull_request]
jobs:
  static:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - run: sudo apt-get install -y shellcheck
      - run: shellcheck bin/cc bin/cc-use entrypoint.sh install.sh
      - uses: hadolint/hadolint-action@v3.1.0   # 不依赖 runner 是否装了 hadolint
        with:
          dockerfile: Dockerfile
      - run: docker compose config -q

  build:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      # GitHub runner 在美国，关闭所有国内加速源以避免反向慢
      - run: |
          docker compose build \
            --build-arg APT_MIRROR=deb.debian.org \
            --build-arg GH_PROXY= \
            --build-arg NPM_REGISTRY=https://registry.npmjs.org
      - run: docker images docker-cc:latest --format '{{.Size}}'

  unit:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - run: sudo apt-get install -y bats jq shellcheck
      - run: bats tests/unit/

  integration:
    runs-on: ubuntu-latest
    needs: [build]
    steps:
      - uses: actions/checkout@v4
      - run: sudo apt-get install -y bats jq
      - run: bats tests/integration/
```

---

## 9. 哪些不测

明确划界，避免无限扩张：

- **真实订阅链接的可用性**：用 mock，不依赖外部机场
- **Anthropic API 真实计费**：单元测试不发真实请求；集成测试只发健康检查类（HEAD / OPTIONS）
- **OAuth 完整流程**：自动化拿不到浏览器授权，仅测"切到 oauth 模式后 settings.env 为 {}"
- **跨地区代理节点选择**：mihomo 自身的逻辑，不重复测
- **浏览器中的 metacubexd 行为**：纯前端，原项目已测

---

## 10. 实施顺序建议（旧版，保留作为参考）

> 本节已被 §15 的"按里程碑"实施计划取代。保留是为了说明"按周递进"和"按里程碑"两种思路的差异。新项目从 §15 走。

旧版 4 周递进（粗粒度）：
1. **第一周**：步骤 1-5 的验证命令变成 bats 集成测试 + CI
2. **第二周**：cc-use 单元测试全覆盖
3. **第三周**：兼容性矩阵首次跑全
4. **持续**：每发现一个新 bug，先写回归测试再 fix（TDD 习惯）

---

## 15. 测试侧实施计划（与 implementation-plan §15 里程碑对齐）

每个里程碑的开发任务都伴随对应测试任务。这里只列**测试侧**的清单，按 M0-M4 排，方便测试工程师对账。开发任务详见 [implementation-plan §15.2](implementation-plan.md#152-任务分解)。

### 15.1 与 implementation-plan §15 里程碑映射

| 里程碑 | 测试任务 | 测试类型 | 工作量（含写 + 调） |
|---|---|---|---|
| **M0** 镜像骨架 | TT0.1 静态检查、TT0.2 build 国内/国外、TT0.3 mihomo 启动 + 面板 200 | 静态 + 集成 | 0.5 d |
| **M1** 核心通路 | TT1.1 `04_first_run.bats`（HTTP_PROXY 不回环）、TT1.2 anthropic.com 联通、TT1.3 手动 claude -p | 集成 + 手动 | 0.5 d |
| **M2** 脚本层 | TT2.1 `helpers.bash`、TT2.2 cc-use_*.bats（6 个）、TT2.3 cc_up.bats、TT2.4 `05_pwd_isolation.bats`、TT2.5 `03_provider_switch` + `06_url_special_chars` | 单元 + 集成 | 1.5 d |
| **M3** 工程化 | TT3.1 `01_install.bats`、TT3.2 `07_upgrade_persistence`、TT3.3 `08_port_conflict` | 集成 | 0.75 d |
| **M4** CI + 发布 | TT4.1 `.github/workflows/test.yml`、TT4.2 兼容性矩阵首次跑、TT4.3 性能基线 | CI + 跨平台 | 1 d |

合计：**~4.25 测试人天**，与开发任务 TDD 并行（不额外占工期），但应预留独立调试时间。

### 15.2 优先级与守门

不同测试在 CI 中扮演的角色：

| 类型 | 阻断 PR 合并 | 阻断 release | 频率 |
|---|---|---|---|
| 静态检查（shellcheck / hadolint） | ✅ | ✅ | 每次 push |
| 单元测试（bats unit/） | ✅ | ✅ | 每次 push |
| 集成测试（bats integration/） | ✅ | ✅ | 每次 push |
| 兼容性矩阵 | ❌ | ✅ | release 前 + 每月 |
| 性能基线 | ❌ | 仅 record，不阻断 | release 前 |

### 15.3 测试覆盖目标（按里程碑累计）

到 M4 结束时，覆盖率应达：

| 维度 | 目标 |
|---|---|
| cc-use 子命令测试覆盖 | 8/8 子命令至少 1 个 bats 用例（list / current / show / add / edit / remove / test / switch） |
| cc 子命令测试覆盖 | 6/10 自动化 + 4/10 手动验证（login/logout/panel/shell 含 GUI/交互成分） |
| §5 回归测试矩阵 | P1 全部有 bats 自动化（9 项）；P2 至少有手动复现脚本（6 项） |
| 平台覆盖 | macOS Apple Silicon + Linux x86_64 必过；arm64 / WSL2 best-effort |

### 15.4 交付物清单（v0.1.0 测试侧）

```
tests/
├── unit/
│   ├── cc-use_add.bats
│   ├── cc-use_switch.bats
│   ├── cc-use_show.bats
│   ├── cc-use_current.bats
│   ├── cc-use_remove.bats
│   ├── cc-use_list.bats
│   ├── cc_up.bats
│   └── cc_upgrade.bats
├── integration/
│   ├── 01_install.bats
│   ├── 03_provider_switch.bats
│   ├── 04_first_run.bats
│   ├── 05_pwd_isolation.bats
│   ├── 06_url_special_chars.bats
│   ├── 07_upgrade_persistence.bats
│   └── 08_port_conflict.bats
├── fixtures/
│   ├── helpers.bash
│   ├── mock-clash-config.yaml
│   └── docker-compose.test.yml
├── perf.md
└── compat-matrix.md
```

`.github/workflows/test.yml` 见 §8。

### 15.5 持续维护

v0.1.0 之后的测试维护原则：

- **每发现一个 prod bug，先写测试再 fix**：把它加到 `tests/` 对应的 bats 文件，并在 §5 回归矩阵新增一行。
- **每加一个 cc / cc-use 子命令**：必须先写 bats 用例（TDD），然后实现，最后通过 PR。
- **每发一个 release**：跑全 §6 兼容性矩阵 + 收集 §7 性能基线，结果记入 `tests/compat-matrix.md` 和 `tests/perf.md`。
- **每季度**：review CI 配置（GitHub Actions runner 镜像可能升级）、依赖版本（mihomo / yq / hadolint）。
