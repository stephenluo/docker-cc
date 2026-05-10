#!/usr/bin/env bats
# 集成测试：mihomo 启动不卡死在 HTTP_PROXY 回环（回归 #14）
# 需要 docker-cc:latest 镜像已 build，且能用 docker-compose.test.yml 注入 host-gateway
load ../fixtures/helpers

setup() { isolate_integration_env; }
teardown() { stop_mock_subscription_server; cd "$DOCKER_CC_HOME" && docker compose down 2>/dev/null || true; }

@test "首次 dcc up <mock-url> 不会卡死在 HTTP_PROXY 回环（30s 超时守门）" {
  # 复制 test override 让 mihomo 容器能解析 host.docker.internal
  cp "$PROJECT_ROOT/tests/fixtures/docker-compose.test.yml" "$DOCKER_CC_HOME/"
  export COMPOSE_FILE="docker-compose.yml:docker-compose.test.yml"

  url=$(start_mock_subscription_server 8765)

  # 30s 超时：HTTP_PROXY 回环 bug 复现时会无限等待
  run timeout 30 dcc up "$url"
  [ "$status" -eq 0 ]

  # mihomo 容器应在跑
  run docker compose ps -q mihomo
  [ -n "$output" ]
}

@test "mihomo logs 应含'拉取订阅'（验证 entrypoint 走了 curl 分支）" {
  cp "$PROJECT_ROOT/tests/fixtures/docker-compose.test.yml" "$DOCKER_CC_HOME/"
  export COMPOSE_FILE="docker-compose.yml:docker-compose.test.yml"
  url=$(start_mock_subscription_server 8765)
  dcc up "$url"
  sleep 2
  run docker compose logs mihomo
  [[ "$output" =~ "拉取订阅" ]]
}
