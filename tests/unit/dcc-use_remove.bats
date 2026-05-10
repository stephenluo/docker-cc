#!/usr/bin/env bats
load ../fixtures/helpers

setup() { isolate_unit_env; }

@test "remove: 确认 y 后文件被删" {
  echo '{"ANTHROPIC_AUTH_TOKEN":"K","ANTHROPIC_BASE_URL":"U"}' > "$PROVIDERS_DIR/foo.json"
  run bash -c "echo 'y' | dcc-use remove foo"
  [ "$status" -eq 0 ]
  [ ! -f "$PROVIDERS_DIR/foo.json" ]
}

@test "remove: 拒绝时文件保留" {
  echo '{"ANTHROPIC_AUTH_TOKEN":"K","ANTHROPIC_BASE_URL":"U"}' > "$PROVIDERS_DIR/foo.json"
  run bash -c "echo 'n' | dcc-use remove foo"
  [ "$status" -eq 0 ]
  [ -f "$PROVIDERS_DIR/foo.json" ]
}

@test "remove: 不存在的供应商报错" {
  run dcc-use remove ghost
  [ "$status" -ne 0 ]
  [[ "$output" =~ "找不到" ]]
}

@test "remove: rm 是 remove 的别名" {
  echo '{"ANTHROPIC_AUTH_TOKEN":"K","ANTHROPIC_BASE_URL":"U"}' > "$PROVIDERS_DIR/foo.json"
  run bash -c "echo 'y' | dcc-use rm foo"
  [ "$status" -eq 0 ]
  [ ! -f "$PROVIDERS_DIR/foo.json" ]
}
