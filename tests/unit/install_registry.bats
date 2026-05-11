#!/usr/bin/env bats
# install.sh --registry / --build-local 参数解析与 .env 写入
load ../fixtures/helpers

setup() {
  isolate_unit_env
  # 用 fake-docker 接管 docker compose pull/build，避免测试真跑容器
  export PATH="$PROJECT_ROOT/tests/fixtures:$PATH"
  export FAKE_DOCKER_LOG="$BATS_TEST_TMPDIR/docker.log"
  export FAKE_DOCKER_PULL_EXIT=0
  export FAKE_DOCKER_BUILD_EXIT=0
  # 用 BATS_TEST_TMPDIR 当 fake HOME，避免污染真实 ~/.docker-cc/
  export HOME="$BATS_TEST_TMPDIR"
  # 把 install.sh 需要的环境变量预设（避免 auto 探测真实网络）
  export GHCR_OWNER="testowner"
  export ALIYUN_PREFIX="registry.fake.aliyuncs.com/testns"
}

run_install() {
  # --skip-link 避免 ln 进真实 /usr/local/bin；--no-cn-mirror 跳过 probe
  run "$PROJECT_ROOT/install.sh" --skip-link --no-cn-mirror "$@"
}

@test "--registry=global 写入 GHCR 前缀的 DCC_IMAGE" {
  run_install --registry=global
  [ "$status" -eq 0 ]
  ver="$(cat "$PROJECT_ROOT/VERSION")"
  run grep '^DCC_IMAGE=' "$HOME/.docker-cc/repo/.env"
  [[ "$output" == *"ghcr.io/testowner/docker-cc:${ver}"* ]]
}

@test "--registry=cn 写入阿里云前缀的 DCC_IMAGE" {
  run_install --registry=cn
  [ "$status" -eq 0 ]
  ver="$(cat "$PROJECT_ROOT/VERSION")"
  run grep '^DCC_IMAGE=' "$HOME/.docker-cc/repo/.env"
  [[ "$output" == *"registry.fake.aliyuncs.com/testns/docker-cc:${ver}"* ]]
}

@test "--registry=<自定义前缀> 直接用" {
  run_install --registry=my.private.io/team
  [ "$status" -eq 0 ]
  run grep '^DCC_IMAGE=' "$HOME/.docker-cc/repo/.env"
  [[ "$output" == *"my.private.io/team/docker-cc:"* ]]
}

@test "--build-local 跳过 pull，直接 build" {
  # 让 pull 一定失败，验证 --build-local 根本不调用 pull
  export FAKE_DOCKER_PULL_EXIT=1
  run_install --build-local
  [ "$status" -eq 0 ]
  # log 中不应出现 "compose pull"
  run grep -F "compose pull" "$FAKE_DOCKER_LOG"
  [ "$status" -ne 0 ]
  # log 中应有 "compose build"
  run grep -F "compose build" "$FAKE_DOCKER_LOG"
  [ "$status" -eq 0 ]
}

@test "pull 失败 fallback 到本地 build，.env 的 DCC_IMAGE 改回 docker-cc:latest" {
  export FAKE_DOCKER_PULL_EXIT=1
  export FAKE_DOCKER_BUILD_EXIT=0
  run_install --registry=global
  [ "$status" -eq 0 ]
  run grep '^DCC_IMAGE=' "$HOME/.docker-cc/repo/.env"
  [[ "$output" == "DCC_IMAGE=docker-cc:latest" ]]
}

@test "--skip-build 完全跳过 [4/7]" {
  run "$PROJECT_ROOT/install.sh" --skip-link --skip-build
  [ "$status" -eq 0 ]
  # 既不 pull 也不 build
  [ ! -s "$FAKE_DOCKER_LOG" ] || {
    run grep -E "compose (pull|build)" "$FAKE_DOCKER_LOG"
    [ "$status" -ne 0 ]
  }
}

@test "未知参数报错并退出非 0" {
  run "$PROJECT_ROOT/install.sh" --weird-flag
  [ "$status" -ne 0 ]
  [[ "$output" =~ "未知参数" ]]
}

@test "--help 退出 0 并列出 --registry / --build-local" {
  run "$PROJECT_ROOT/install.sh" --help
  [ "$status" -eq 0 ]
  [[ "$output" =~ "--registry=" ]]
  [[ "$output" =~ "--build-local" ]]
}
