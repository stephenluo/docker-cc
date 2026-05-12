#!/usr/bin/env bats
# dcc-use registry: 显示 / 切换 docker image registry（改 .env DCC_IMAGE 前缀）
load ../fixtures/helpers

setup() {
  isolate_unit_env
  # 模拟 ~/.docker-cc/repo/.env
  export DOCKER_CC_HOME="$BATS_TEST_TMPDIR/.docker-cc"
  mkdir -p "$DOCKER_CC_HOME/repo"
  REPO_ENV="$DOCKER_CC_HOME/repo/.env"
}

@test "registry show: 当前是 GHCR 时正确识别 + 提示" {
  echo 'DCC_IMAGE=ghcr.io/stephenluo/docker-cc:0.2.8' > "$REPO_ENV"
  run dcc-use registry
  [ "$status" -eq 0 ]
  [[ "$output" =~ "global (GHCR)" ]]
  [[ "$output" =~ "ghcr.io/stephenluo/docker-cc:0.2.8" ]]
}

@test "registry show: 当前是阿里云 ACR 时正确识别" {
  echo 'DCC_IMAGE=crpi-rskelsy8ldqvpz46.cn-shanghai.personal.cr.aliyuncs.com/stephenluo/docker-cc:0.2.8' > "$REPO_ENV"
  run dcc-use registry
  [ "$status" -eq 0 ]
  [[ "$output" =~ "cn (阿里云 ACR)" ]]
}

@test "registry cn: 切到阿里云" {
  echo 'DCC_IMAGE=ghcr.io/stephenluo/docker-cc:0.2.8' > "$REPO_ENV"
  run dcc-use registry cn
  [ "$status" -eq 0 ]
  run grep '^DCC_IMAGE=' "$REPO_ENV"
  [[ "$output" == *"crpi-rskelsy8ldqvpz46.cn-shanghai.personal.cr.aliyuncs.com/stephenluo/docker-cc:0.2.8"* ]]
}

@test "registry global: 切到 GHCR" {
  echo 'DCC_IMAGE=crpi-rskelsy8ldqvpz46.cn-shanghai.personal.cr.aliyuncs.com/stephenluo/docker-cc:0.2.8' > "$REPO_ENV"
  run dcc-use registry global
  [ "$status" -eq 0 ]
  run grep '^DCC_IMAGE=' "$REPO_ENV"
  [[ "$output" == *"ghcr.io/stephenluo/docker-cc:0.2.8"* ]]
}

@test "registry <自定义前缀>: 任意 prefix 都接受" {
  echo 'DCC_IMAGE=ghcr.io/stephenluo/docker-cc:0.2.8' > "$REPO_ENV"
  run dcc-use registry my.private.io/team
  [ "$status" -eq 0 ]
  run grep '^DCC_IMAGE=' "$REPO_ENV"
  [[ "$output" == *"my.private.io/team/docker-cc:0.2.8"* ]]
}

@test "registry: 切到当前已用的 registry 提示无需切换" {
  echo 'DCC_IMAGE=ghcr.io/stephenluo/docker-cc:0.2.8' > "$REPO_ENV"
  run dcc-use registry global
  [ "$status" -eq 0 ]
  [[ "$output" =~ "无需切换" ]]
}

@test "registry: 保留原 tag（切前后 tag 一致）" {
  echo 'DCC_IMAGE=ghcr.io/stephenluo/docker-cc:0.1.5' > "$REPO_ENV"
  run dcc-use registry cn
  [ "$status" -eq 0 ]
  run grep '^DCC_IMAGE=' "$REPO_ENV"
  [[ "$output" == *":0.1.5"* ]]
}

@test "registry: .env 不存在时报错" {
  run dcc-use registry show
  [ "$status" -ne 0 ]
  [[ "$output" =~ "未找到" ]]
}

@test "registry: .env 里无 DCC_IMAGE 时报错" {
  echo 'CLASH_SUB_URL=https://example.com/sub' > "$REPO_ENV"
  run dcc-use registry
  [ "$status" -ne 0 ]
  [[ "$output" =~ "没找到 DCC_IMAGE" ]]
}

@test "registry -h / --help: 显示用法" {
  echo 'DCC_IMAGE=ghcr.io/stephenluo/docker-cc:0.2.8' > "$REPO_ENV"
  run dcc-use registry --help
  [ "$status" -eq 0 ]
  [[ "$output" =~ "用法" ]]
}

@test "registry: DCC_GHCR_OWNER 环境变量覆盖默认 owner" {
  echo 'DCC_IMAGE=ghcr.io/myfork/docker-cc:0.2.8' > "$REPO_ENV"
  export DCC_GHCR_OWNER="myfork"
  run dcc-use registry
  [ "$status" -eq 0 ]
  [[ "$output" =~ "global (GHCR)" ]]
}
