#!/usr/bin/env bats
load ../fixtures/helpers

setup() { isolate_unit_env; }   # 仅测 cc-use 切换逻辑，不需要真实 compose

@test "切换链：API → API → API（settings env 三次正确）" {
  cc-use add a --api-key=Ka --base-url=https://a.com
  cc-use add b --api-key=Kb --base-url=https://b.com
  cc-use add c --api-key=Kc --base-url=https://c.com

  cc-use a
  run jq -r '.env.ANTHROPIC_AUTH_TOKEN' "$CLAUDE_SETTINGS"
  [ "$output" = "Ka" ]

  cc-use b
  run jq -r '.env.ANTHROPIC_AUTH_TOKEN' "$CLAUDE_SETTINGS"
  [ "$output" = "Kb" ]

  cc-use c
  run jq -r '.env.ANTHROPIC_AUTH_TOKEN' "$CLAUDE_SETTINGS"
  [ "$output" = "Kc" ]
}

@test "切换链：API → OAuth → API（env 清空再恢复）" {
  cc-use add a --api-key=Ka --base-url=https://a.com
  cc-use add oa --mode=oauth

  cc-use a
  run jq -r '.env.ANTHROPIC_AUTH_TOKEN' "$CLAUDE_SETTINGS"
  [ "$output" = "Ka" ]

  cc-use oa
  run jq -c '.env' "$CLAUDE_SETTINGS"
  [ "$output" = "{}" ]

  cc-use a
  run jq -r '.env.ANTHROPIC_AUTH_TOKEN' "$CLAUDE_SETTINGS"
  [ "$output" = "Ka" ]
}

@test "current 反查在每次切换后都正确（回归 #15）" {
  cc-use add a --api-key=K --base-url=https://a.com
  cc-use add b --api-key=K --base-url=https://b.com

  cc-use a
  [ "$(cc-use current)" = "a" ]

  cc-use b
  [ "$(cc-use current)" = "b" ]
}
