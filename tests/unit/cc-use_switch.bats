#!/usr/bin/env bats
load ../fixtures/helpers

setup() { isolate_unit_env; }

@test "switch: api-key 模式把字段写入 settings.env" {
  echo '{"ANTHROPIC_AUTH_TOKEN":"K","ANTHROPIC_BASE_URL":"U"}' > "$PROVIDERS_DIR/foo.json"
  run cc-use foo
  [ "$status" -eq 0 ]
  run jq -r '.env.ANTHROPIC_AUTH_TOKEN' "$CLAUDE_SETTINGS"
  [ "$output" = "K" ]
  run jq -r '.env.ANTHROPIC_BASE_URL' "$CLAUDE_SETTINGS"
  [ "$output" = "U" ]
}

@test "switch: oauth 模式清空 env（回归 #22 OAuth/API key 互斥）" {
  echo '{"ANTHROPIC_AUTH_TOKEN":"K","ANTHROPIC_BASE_URL":"U"}' > "$PROVIDERS_DIR/foo.json"
  cc-use foo
  echo '{"_mode":"oauth"}' > "$PROVIDERS_DIR/oa.json"
  run cc-use oa
  [ "$status" -eq 0 ]
  run jq -c '.env' "$CLAUDE_SETTINGS"
  [ "$output" = "{}" ]
}

@test "switch: 不存在的供应商报错并列出可用项" {
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
  run jq 'has("_comment")' <(jq '.env' "$CLAUDE_SETTINGS")
  [ "$output" = "false" ]
}

@test "switch: 切换后再切回保留原 token" {
  echo '{"ANTHROPIC_AUTH_TOKEN":"K1","ANTHROPIC_BASE_URL":"U1"}' > "$PROVIDERS_DIR/foo.json"
  echo '{"ANTHROPIC_AUTH_TOKEN":"K2","ANTHROPIC_BASE_URL":"U2"}' > "$PROVIDERS_DIR/bar.json"
  cc-use foo
  cc-use bar
  cc-use foo
  run jq -r '.env.ANTHROPIC_AUTH_TOKEN' "$CLAUDE_SETTINGS"
  [ "$output" = "K1" ]
}
