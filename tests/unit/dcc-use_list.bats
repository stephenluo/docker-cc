#!/usr/bin/env bats
load ../fixtures/helpers

setup() { isolate_unit_env; }

@test "list: 显示已添加供应商" {
  dcc-use add foo --api-key=K --base-url=https://foo.com
  dcc-use add bar --api-key=K --base-url=https://bar.com
  run dcc-use list
  [ "$status" -eq 0 ]
  [[ "$output" =~ "foo" ]]
  [[ "$output" =~ "bar" ]]
  [[ "$output" =~ "https://foo.com" ]]
}

@test "list: 当前激活的有 ★ 标记" {
  dcc-use add foo --api-key=K --base-url=https://foo.com
  dcc-use foo
  run dcc-use list
  [ "$status" -eq 0 ]
  [[ "$output" =~ "★" ]]
  [[ "$output" =~ "foo" ]]
}

@test "list: oauth 模式标识 type=oauth" {
  dcc-use add my-account --mode=oauth
  run dcc-use list
  [ "$status" -eq 0 ]
  [[ "$output" =~ "oauth" ]]
}

@test "list: 无参数等同 list" {
  dcc-use add foo --api-key=K --base-url=https://foo.com
  run dcc-use
  [ "$status" -eq 0 ]
  [[ "$output" =~ "foo" ]]
}
