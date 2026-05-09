#!/usr/bin/env bats
load ../fixtures/helpers

setup() { isolate_integration_env; }

# 仅测脚本路由逻辑，不真实跑 docker compose build（成本太高）
# 真实升级走 integration/07_upgrade_persistence.bats

@test "cc upgrade mihomo: 提示编辑 Dockerfile" {
  run cc upgrade mihomo
  [ "$status" -eq 0 ]
  [[ "$output" =~ "MIHOMO_VERSION" ]]
}

@test "cc upgrade <unknown>: 报错并打印用法" {
  run cc upgrade weird
  [ "$status" -ne 0 ]
  [[ "$output" =~ "用法" ]]
}

@test "cc update: 拒绝并提示用 cc upgrade" {
  run cc update
  [ "$status" -ne 0 ]
  [[ "$output" =~ "cc upgrade" ]]
  [[ "$output" =~ "不会持久化" ]]
}
