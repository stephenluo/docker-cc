#!/usr/bin/env bats
# 集成测试：端口配置（默认 19090 + UI_PORT 覆盖 + 19090 被占应失败）
load ../fixtures/helpers

setup() { isolate_integration_env; }
teardown() { stop_mock_subscription_server; cd "$DOCKER_CC_HOME" && docker compose down 2>/dev/null || true; }

@test "默认端口：19090（不与宿主 Clash Verge 的 9090 冲突）" {
  cp "$PROJECT_ROOT/tests/fixtures/docker-compose.test.yml" "$DOCKER_CC_HOME/"
  export COMPOSE_FILE="docker-compose.yml:docker-compose.test.yml"

  url=$(start_mock_subscription_server 8765)
  cc up "$url"

  # 等 mihomo 起来
  for i in 1 2 3 4 5; do
    curl -sf http://127.0.0.1:19090/ui >/dev/null 2>&1 && break
    sleep 1
  done

  run curl -sf -o /dev/null -w '%{http_code}' http://127.0.0.1:19090/ui
  [ "$output" = "200" ]
  # 7890 不应该被映射到宿主：用 bash 内置 /dev/tcp 探测，不依赖外部 nc
  ! (echo > /dev/tcp/127.0.0.1/7890) 2>/dev/null
}

@test "UI_PORT=20000 覆盖默认端口" {
  cp "$PROJECT_ROOT/tests/fixtures/docker-compose.test.yml" "$DOCKER_CC_HOME/"
  export COMPOSE_FILE="docker-compose.yml:docker-compose.test.yml"

  echo "UI_PORT=20000" > "$DOCKER_CC_HOME/.env"
  url=$(start_mock_subscription_server 8765)
  cc up "$url"

  for i in 1 2 3 4 5; do
    curl -sf http://127.0.0.1:20000/ui >/dev/null 2>&1 && break
    sleep 1
  done

  run curl -sf -o /dev/null -w '%{http_code}' http://127.0.0.1:20000/ui
  [ "$output" = "200" ]
  ! (echo > /dev/tcp/127.0.0.1/19090) 2>/dev/null   # 默认端口不再被占
}

@test "宿主已占 19090 时，cc up 应失败（端口冲突）" {
  python3 -m http.server 19090 >/dev/null 2>&1 &
  blocker=$!
  trap "kill $blocker 2>/dev/null || true" RETURN

  cp "$PROJECT_ROOT/tests/fixtures/docker-compose.test.yml" "$DOCKER_CC_HOME/"
  export COMPOSE_FILE="docker-compose.yml:docker-compose.test.yml"

  url=$(start_mock_subscription_server 8766)
  run cc up "$url"
  [ "$status" -ne 0 ]   # docker compose 应报端口冲突
}
