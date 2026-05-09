#!/usr/bin/env bats
# 回归：macOS Bash 3.2 在 UTF-8 locale 下，$var 紧跟非 ASCII 字符时会"吃"首字节
# 修复：所有此类位置改用 ${var} 显式分隔
load ../fixtures/helpers

setup() { isolate_unit_env; }

@test "cc-use switch: 输出含完整变量值 + 完整中文括号（不漏字节）" {
  echo '{"_mode":"oauth"}' > "$PROVIDERS_DIR/oa.json"
  run cc-use oa
  [ "$status" -eq 0 ]
  # 必须包含完整供应商名 'oa'
  [[ "$output" =~ "oa" ]]
  # 必须包含完整中文左括号"（"
  [[ "$output" =~ "（" ]]
  # 必须包含完整中文右括号"）"
  [[ "$output" =~ "）" ]]
}

@test "cc-use add OAuth: 输出含完整变量值 + 完整中文括号" {
  run cc-use add my-oauth --mode=oauth
  [ "$status" -eq 0 ]
  [[ "$output" =~ "my-oauth" ]]
  [[ "$output" =~ "（" ]]
  [[ "$output" =~ "）" ]]
}

@test "cc-use add 重名: 报错信息含完整供应商名" {
  echo '{"ANTHROPIC_AUTH_TOKEN":"K","ANTHROPIC_BASE_URL":"U"}' > "$PROVIDERS_DIR/foo.json"
  run cc-use add foo --api-key=K --base-url=U
  [ "$status" -ne 0 ]
  [[ "$output" =~ "foo" ]]   # 不被 macOS bash 3.2 吃掉
  [[ "$output" =~ "（" ]]
}
