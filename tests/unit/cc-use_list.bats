#!/usr/bin/env bats
load ../fixtures/helpers

setup() { isolate_unit_env; }

@test "list: 显示已添加供应商" {
  cc-use add foo --api-key=K --base-url=https://foo.com
  cc-use add bar --api-key=K --base-url=https://bar.com
  run cc-use list
  [ "$status" -eq 0 ]
  [[ "$output" =~ "foo" ]]
  [[ "$output" =~ "bar" ]]
  [[ "$output" =~ "https://foo.com" ]]
}

@test "list: 当前激活的有 ★ 标记" {
  cc-use add foo --api-key=K --base-url=https://foo.com
  cc-use foo
  run cc-use list
  [ "$status" -eq 0 ]
  [[ "$output" =~ "★" ]]
  [[ "$output" =~ "foo" ]]
}

@test "list: oauth 模式标识 type=oauth" {
  cc-use add my-account --mode=oauth
  run cc-use list
  [ "$status" -eq 0 ]
  [[ "$output" =~ "oauth" ]]
}

@test "list: 无参数等同 list" {
  cc-use add foo --api-key=K --base-url=https://foo.com
  run cc-use
  [ "$status" -eq 0 ]
  [[ "$output" =~ "foo" ]]
}
