#!/usr/bin/env bats
load ../fixtures/helpers

setup() { isolate_unit_env; }

@test "current: settings env 匹配则返回正确名字" {
  echo '{"ANTHROPIC_AUTH_TOKEN":"K","ANTHROPIC_BASE_URL":"U1"}' > "$PROVIDERS_DIR/foo.json"
  echo '{"ANTHROPIC_AUTH_TOKEN":"K","ANTHROPIC_BASE_URL":"U2"}' > "$PROVIDERS_DIR/bar.json"
  echo '{"env":{"ANTHROPIC_AUTH_TOKEN":"K","ANTHROPIC_BASE_URL":"U2"}}' > "$CLAUDE_SETTINGS"
  run cc-use current
  [ "$output" = "bar" ]
}

@test "current: env 为空 + 有 oauth 模式供应商 → 返回 oauth 供应商名" {
  echo '{"_mode":"oauth"}' > "$PROVIDERS_DIR/oa.json"
  echo '{"env":{}}' > "$CLAUDE_SETTINGS"
  run cc-use current
  [ "$output" = "oa" ]
}

@test "current: settings 完全空 + 无供应商 → (none)" {
  run cc-use current
  [ "$output" = "(none)" ]
}

@test "current: switch 后 current 反查正确" {
  echo '{"ANTHROPIC_AUTH_TOKEN":"K","ANTHROPIC_BASE_URL":"U-special"}' > "$PROVIDERS_DIR/special.json"
  cc-use special
  run cc-use current
  [ "$output" = "special" ]
}
