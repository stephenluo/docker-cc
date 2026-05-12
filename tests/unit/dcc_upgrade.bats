#!/usr/bin/env bats
load ../fixtures/helpers

setup() {
  isolate_integration_env
  # 用 fake-docker 接管 docker compose pull/build，避免测试真跑容器
  export PATH="$PROJECT_ROOT/tests/fixtures:$PATH"
  export FAKE_DOCKER_LOG="$BATS_TEST_TMPDIR/docker.log"
}

# 仅测脚本路由逻辑，不真实跑 docker compose build（成本太高）
# 真实升级走 integration/07_upgrade_persistence.bats

@test "dcc upgrade mihomo: 提示编辑 Dockerfile" {
  run dcc upgrade mihomo
  [ "$status" -eq 0 ]
  [[ "$output" =~ "MIHOMO_VERSION" ]]
}

@test "dcc upgrade <unknown>: 报错并打印用法（提示含 --build）" {
  run dcc upgrade weird
  [ "$status" -ne 0 ]
  [[ "$output" =~ "用法" ]]
  [[ "$output" =~ "--build" ]]
}

@test "dcc update: 拒绝并提示用 dcc upgrade" {
  run dcc update
  [ "$status" -ne 0 ]
  [[ "$output" =~ "dcc upgrade" ]]
  [[ "$output" =~ "不会持久化" ]]
}

@test "dcc upgrade --keep 走 pull，不走 build（不调 API，纯路由）" {
  export FAKE_DOCKER_PULL_EXIT=0
  run dcc upgrade --keep
  [ "$status" -eq 0 ]
  run grep -F "compose pull" "$FAKE_DOCKER_LOG"
  [ "$status" -eq 0 ]
  run grep -F "compose build" "$FAKE_DOCKER_LOG"
  [ "$status" -ne 0 ]
}

@test "dcc upgrade --build 走 build，不走 pull" {
  export FAKE_DOCKER_BUILD_EXIT=0
  run dcc upgrade --build
  [ "$status" -eq 0 ]
  run grep -F "compose build" "$FAKE_DOCKER_LOG"
  [ "$status" -eq 0 ]
  run grep -F "compose pull" "$FAKE_DOCKER_LOG"
  [ "$status" -ne 0 ]
}

@test "dcc upgrade --keep pull 失败时给出 --build 提示" {
  export FAKE_DOCKER_PULL_EXIT=1
  run dcc upgrade --keep
  [ "$status" -ne 0 ]
  [[ "$output" =~ "dcc upgrade --build" ]]
}

@test "dcc upgrade --build claude 与 dcc upgrade --build all 都进 build 分支" {
  export FAKE_DOCKER_BUILD_EXIT=0
  run dcc upgrade --build claude
  [ "$status" -eq 0 ]
  run dcc upgrade --build all
  [ "$status" -eq 0 ]
}

# —— 新增 v0.2.8 flag 覆盖：--to / --keep / 默认探测 latest（mock API）——

@test "dcc upgrade --to=<v> 改 VERSION + .env DCC_IMAGE tag" {
  export FAKE_DOCKER_PULL_EXIT=0
  echo "0.1.0" > "$DOCKER_CC_HOME/VERSION"
  echo 'DCC_IMAGE=ghcr.io/foo/docker-cc:0.1.0' > "$DOCKER_CC_HOME/.env"
  run dcc upgrade --to=9.9.9
  [ "$status" -eq 0 ]
  [ "$(cat "$DOCKER_CC_HOME/VERSION")" = "9.9.9" ]
  run grep '^DCC_IMAGE=' "$DOCKER_CC_HOME/.env"
  [[ "$output" == *":9.9.9"* ]]
}

@test "dcc upgrade --to （后无参数）报错并退出" {
  run dcc upgrade --to
  [ "$status" -ne 0 ]
  [[ "$output" =~ "--to 后需要版本号" ]]
}

@test "dcc upgrade --keep 不改 VERSION" {
  export FAKE_DOCKER_PULL_EXIT=0
  echo "0.1.0" > "$DOCKER_CC_HOME/VERSION"
  run dcc upgrade --keep
  [ "$status" -eq 0 ]
  [ "$(cat "$DOCKER_CC_HOME/VERSION")" = "0.1.0" ]
}

@test "dcc upgrade 默认通过 DCC_API_BASE mock 探测 latest 写入 VERSION" {
  export FAKE_DOCKER_PULL_EXIT=0
  # 起 mock API server
  MOCK_DIR=$(mktemp -d)
  mkdir -p "$MOCK_DIR/repos/owner/docker-cc/releases"
  echo '{"tag_name": "v9.9.9"}' > "$MOCK_DIR/repos/owner/docker-cc/releases/latest"
  PORT=$((10000 + RANDOM % 50000))
  python3 -m http.server "$PORT" --bind 127.0.0.1 --directory "$MOCK_DIR" >/dev/null 2>&1 &
  PID=$!
  for _ in 1 2 3 4 5; do
    curl -fsS --max-time 1 "http://127.0.0.1:${PORT}/" >/dev/null 2>&1 && break
    sleep 0.2
  done

  echo "0.1.0" > "$DOCKER_CC_HOME/VERSION"
  echo 'DCC_IMAGE=ghcr.io/owner/docker-cc:0.1.0' > "$DOCKER_CC_HOME/.env"
  export DCC_API_BASE="http://127.0.0.1:${PORT}"
  export DCC_REPO="owner/docker-cc"
  run dcc upgrade
  status_saved=$status
  result_ver=$(cat "$DOCKER_CC_HOME/VERSION")

  # 立刻 kill mock server（不用 trap，因为 bats 子 shell EXIT trap 退出晚，
  # 让 docker container 主进程 hang 等子进程回收）
  kill -9 "$PID" 2>/dev/null || true
  wait "$PID" 2>/dev/null || true
  rm -rf "$MOCK_DIR"

  [ "$status_saved" -eq 0 ]
  [ "$result_ver" = "9.9.9" ]
}

@test "dcc upgrade 默认 API 不可达时友好提示 --to / --keep" {
  export FAKE_DOCKER_PULL_EXIT=0
  # 指向不存在的 API base，curl 必失败
  export DCC_API_BASE="http://127.0.0.1:1"
  run dcc upgrade
  [ "$status" -ne 0 ]
  [[ "$output" =~ "无法探测 latest 版本" ]]
  [[ "$output" =~ "--to=" ]]
  [[ "$output" =~ "--keep" ]]
}
