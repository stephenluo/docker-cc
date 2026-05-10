#!/usr/bin/env bats
load ../fixtures/helpers

setup() { isolate_integration_env; }

@test "dcc up <url>: URL 含 & 不会破坏 .env（回归 #19 #20 三轮审核 URL 特殊字符）" {
  dcc up "https://test.com/sub?token=x&format=clash" 2>/dev/null || true
  run grep '^CLASH_SUB_URL=' "$DOCKER_CC_HOME/.env"
  [[ "$output" == *'?token=x&format=clash'* ]]
}

@test "dcc up <url>: URL 在 .env 中带双引号（回归 #20 防御 shell 元字符）" {
  dcc up "https://test.com/sub?a=1&b=2" 2>/dev/null || true
  run grep '^CLASH_SUB_URL=' "$DOCKER_CC_HOME/.env"
  [[ "$output" == *'CLASH_SUB_URL="'* ]]
}

@test "dcc up <url>: 二次调用换 URL 会覆盖（不重复）" {
  dcc up "https://a.com/sub" 2>/dev/null || true
  dcc up "https://b.com/sub" 2>/dev/null || true
  run grep -c '^CLASH_SUB_URL=' "$DOCKER_CC_HOME/.env"
  [ "$output" = "1" ]
  run grep '^CLASH_SUB_URL=' "$DOCKER_CC_HOME/.env"
  [[ "$output" == *"b.com"* ]]
}

@test "dcc up（无参）: .env 无 CLASH_SUB_URL 时报错引导" {
  run dcc up
  [ "$status" -ne 0 ]
  [[ "$output" =~ "首次使用请指定订阅" ]]
}

@test "dcc 默认分支: 拒绝 dcc update（回归 dcc upgrade 陷阱）" {
  run dcc update
  [ "$status" -ne 0 ]
  [[ "$output" =~ "dcc upgrade" ]]
}
