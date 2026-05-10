#!/usr/bin/env bats
load ../fixtures/helpers

setup() { isolate_unit_env; }   # 仅测 dcc-use 切换逻辑，不需要真实 compose

@test "切换链：API → API → API（settings env 三次正确）" {
  dcc-use add a --api-key=Ka --base-url=https://a.com
  dcc-use add b --api-key=Kb --base-url=https://b.com
  dcc-use add c --api-key=Kc --base-url=https://c.com

  dcc-use a
  run jq -r '.env.ANTHROPIC_AUTH_TOKEN' "$CLAUDE_SETTINGS"
  [ "$output" = "Ka" ]

  dcc-use b
  run jq -r '.env.ANTHROPIC_AUTH_TOKEN' "$CLAUDE_SETTINGS"
  [ "$output" = "Kb" ]

  dcc-use c
  run jq -r '.env.ANTHROPIC_AUTH_TOKEN' "$CLAUDE_SETTINGS"
  [ "$output" = "Kc" ]
}

@test "切换链：API → OAuth → API（env 清空再恢复）" {
  dcc-use add a --api-key=Ka --base-url=https://a.com
  dcc-use add oa --mode=oauth

  dcc-use a
  run jq -r '.env.ANTHROPIC_AUTH_TOKEN' "$CLAUDE_SETTINGS"
  [ "$output" = "Ka" ]

  dcc-use oa
  run jq -c '.env' "$CLAUDE_SETTINGS"
  [ "$output" = "{}" ]

  dcc-use a
  run jq -r '.env.ANTHROPIC_AUTH_TOKEN' "$CLAUDE_SETTINGS"
  [ "$output" = "Ka" ]
}

@test "current 反查在每次切换后都正确（回归 #15）" {
  dcc-use add a --api-key=K --base-url=https://a.com
  dcc-use add b --api-key=K --base-url=https://b.com

  dcc-use a
  [ "$(dcc-use current)" = "a" ]

  dcc-use b
  [ "$(dcc-use current)" = "b" ]
}
