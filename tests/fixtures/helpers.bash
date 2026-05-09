#!/usr/bin/env bash
# 共用 setup/teardown 函数。详见 docs/testing.md §1.1

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

# 集成测试：完整重定向 cc 脚本的 compose 目录 + HOME（隔离 docker compose ${HOME} 卷挂载）
isolate_integration_env() {
  isolate_unit_env
  export DOCKER_CC_HOME="$BATS_TEST_TMPDIR/repo"
  mkdir -p "$DOCKER_CC_HOME"
  cp "$PROJECT_ROOT/docker-compose.yml" "$DOCKER_CC_HOME/"
  cp "$PROJECT_ROOT/Dockerfile"         "$DOCKER_CC_HOME/"
  cp "$PROJECT_ROOT/entrypoint.sh"      "$DOCKER_CC_HOME/"
  cp -r "$PROJECT_ROOT/bin"             "$DOCKER_CC_HOME/"
  touch "$DOCKER_CC_HOME/.env"

  # ⚠ 集成测试必须 export HOME 隔离，避免污染真实 ~/.docker-cc/
  export HOME="$BATS_TEST_TMPDIR"
  mkdir -p "$HOME/.docker-cc/claude" "$HOME/.docker-cc/providers" "$HOME/.docker-cc/mihomo"
}

# 启动 mock 订阅 server，返回容器内可达的 URL
# host.docker.internal 在 Docker Desktop 自带；Linux 需通过 docker-compose.test.yml
# 的 extra_hosts: "host.docker.internal:host-gateway" 注入
start_mock_subscription_server() {
  local port="${1:-8765}"
  python3 -m http.server "$port" --bind 0.0.0.0 \
    --directory "$PROJECT_ROOT/tests/fixtures" >/dev/null 2>&1 &
  echo "$!" > "$BATS_TEST_TMPDIR/mock_pid"
  echo "http://host.docker.internal:${port}/mock-clash-config.yaml"
}

stop_mock_subscription_server() {
  if [ -f "$BATS_TEST_TMPDIR/mock_pid" ]; then
    kill "$(cat "$BATS_TEST_TMPDIR/mock_pid")" 2>/dev/null || true
    rm -f "$BATS_TEST_TMPDIR/mock_pid"
  fi
}
