#!/usr/bin/env bats
load ../fixtures/helpers

setup() {
  isolate_integration_env
  # 用 fake-docker 接管 docker compose pull/build，避免测试真跑容器
  export PATH="$PROJECT_ROOT/tests/fixtures:$PATH"
  export FAKE_DOCKER_LOG="$BATS_TEST_TMPDIR/docker.log"
}

# 仅测脚本路由逻辑，不真实跑 docker compose build（成本太高）
# 真实升级走 integration/07_upgrade_persistence.bats

@test "dcc upgrade mihomo: 提示编辑 Dockerfile" {
  run dcc upgrade mihomo
  [ "$status" -eq 0 ]
  [[ "$output" =~ "MIHOMO_VERSION" ]]
}

@test "dcc upgrade <unknown>: 报错并打印用法（提示含 --build）" {
  run dcc upgrade weird
  [ "$status" -ne 0 ]
  [[ "$output" =~ "用法" ]]
  [[ "$output" =~ "--build" ]]
}

@test "dcc update: 拒绝并提示用 dcc upgrade" {
  run dcc update
  [ "$status" -ne 0 ]
  [[ "$output" =~ "dcc upgrade" ]]
  [[ "$output" =~ "不会持久化" ]]
}

@test "dcc upgrade（默认）走 pull，不走 build" {
  export FAKE_DOCKER_PULL_EXIT=0
  run dcc upgrade
  [ "$status" -eq 0 ]
  run grep -F "compose pull" "$FAKE_DOCKER_LOG"
  [ "$status" -eq 0 ]
  run grep -F "compose build" "$FAKE_DOCKER_LOG"
  [ "$status" -ne 0 ]
}

@test "dcc upgrade --build 走 build，不走 pull" {
  export FAKE_DOCKER_BUILD_EXIT=0
  run dcc upgrade --build
  [ "$status" -eq 0 ]
  run grep -F "compose build" "$FAKE_DOCKER_LOG"
  [ "$status" -eq 0 ]
  run grep -F "compose pull" "$FAKE_DOCKER_LOG"
  [ "$status" -ne 0 ]
}

@test "dcc upgrade（默认）pull 失败时给出 --build 提示" {
  export FAKE_DOCKER_PULL_EXIT=1
  run dcc upgrade
  [ "$status" -ne 0 ]
  [[ "$output" =~ "dcc upgrade --build" ]]
}

@test "dcc upgrade --build claude 与 dcc upgrade --build all 都进 build 分支" {
  export FAKE_DOCKER_BUILD_EXIT=0
  run dcc upgrade --build claude
  [ "$status" -eq 0 ]
  run dcc upgrade --build all
  [ "$status" -eq 0 ]
}
