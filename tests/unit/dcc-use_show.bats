#!/usr/bin/env bats
load ../fixtures/helpers

setup() { isolate_unit_env; }

@test "show: API Key 脱敏（不含完整值）" {
  echo '{"ANTHROPIC_AUTH_TOKEN":"sk-ant-secret-12345","ANTHROPIC_BASE_URL":"U"}' \
    > "$PROVIDERS_DIR/foo.json"
  run dcc-use show foo
  [ "$status" -eq 0 ]
  [[ ! "$output" =~ "sk-ant-secret-12345" ]]
  # 仍展示前 7 + 后 4 字符
  [[ "$output" =~ "sk-ant-" ]]
}

@test "show: ANTHROPIC_API_KEY 也脱敏" {
  echo '{"ANTHROPIC_API_KEY":"abc-very-secret-xyz-987","ANTHROPIC_BASE_URL":"U"}' \
    > "$PROVIDERS_DIR/foo.json"
  run dcc-use show foo
  [ "$status" -eq 0 ]
  [[ ! "$output" =~ "abc-very-secret-xyz-987" ]]
}

@test "show: 不存在的供应商报错" {
  run dcc-use show ghost
  [ "$status" -ne 0 ]
  [[ "$output" =~ "找不到" ]]
}

@test "show: oauth 模式（无 token 字段）正常输出" {
  echo '{"_mode":"oauth","_comment":"hi"}' > "$PROVIDERS_DIR/oa.json"
  run dcc-use show oa
  [ "$status" -eq 0 ]
  [[ "$output" =~ "oauth" ]]
}
