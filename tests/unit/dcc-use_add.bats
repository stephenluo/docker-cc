#!/usr/bin/env bats
load ../fixtures/helpers

setup() { isolate_unit_env; }

@test "add: api-key 模式生成完整 JSON" {
  run dcc-use add foo \
    --api-key=sk-test \
    --base-url=https://api.example.com \
    --model=foo-pro \
    --small-model=foo-mini
  [ "$status" -eq 0 ]
  [ -f "$PROVIDERS_DIR/foo.json" ]
  run jq -r '.ANTHROPIC_AUTH_TOKEN' "$PROVIDERS_DIR/foo.json"
  [ "$output" = "sk-test" ]
  run jq -r '.ANTHROPIC_BASE_URL' "$PROVIDERS_DIR/foo.json"
  [ "$output" = "https://api.example.com" ]
  run jq -r '.ANTHROPIC_MODEL' "$PROVIDERS_DIR/foo.json"
  [ "$output" = "foo-pro" ]
  run jq -r '.ANTHROPIC_SMALL_FAST_MODEL' "$PROVIDERS_DIR/foo.json"
  [ "$output" = "foo-mini" ]
}

@test "add: --mode=oauth 仅写 _mode 字段" {
  run dcc-use add my-account --mode=oauth
  [ "$status" -eq 0 ]
  run jq -r '._mode' "$PROVIDERS_DIR/my-account.json"
  [ "$output" = "oauth" ]
  run jq 'has("ANTHROPIC_AUTH_TOKEN")' "$PROVIDERS_DIR/my-account.json"
  [ "$output" = "false" ]
}

@test "add: --key-name=ANTHROPIC_API_KEY 写到正确字段" {
  run dcc-use add bar --api-key=K --base-url=U --key-name=ANTHROPIC_API_KEY
  [ "$status" -eq 0 ]
  run jq -r '.ANTHROPIC_API_KEY' "$PROVIDERS_DIR/bar.json"
  [ "$output" = "K" ]
  run jq 'has("ANTHROPIC_AUTH_TOKEN")' "$PROVIDERS_DIR/bar.json"
  [ "$output" = "false" ]
}

@test "add: 未知参数报错" {
  run dcc-use add foo --invalid=x --api-key=K --base-url=U
  [ "$status" -ne 0 ]
  [[ "$output" =~ "未知参数" ]]
}

@test "add: 重名报错（已存在则拒绝覆盖）" {
  dcc-use add foo --api-key=K1 --base-url=U
  run dcc-use add foo --api-key=K2 --base-url=U
  [ "$status" -ne 0 ]
  [[ "$output" =~ "已存在" ]]
  # 原值不变
  run jq -r '.ANTHROPIC_AUTH_TOKEN' "$PROVIDERS_DIR/foo.json"
  [ "$output" = "K1" ]
}
