#!/usr/bin/env bats
load ../fixtures/helpers

setup() {
  # 隔离 HOME，避免污染真实 ~/.docker-cc/
  export HOME="$BATS_TEST_TMPDIR"
}

@test "install.sh --skip-build --skip-link --prefix 创建期望产物" {
  cd "$PROJECT_ROOT"
  run ./install.sh --skip-build --skip-link --prefix="$BATS_TEST_TMPDIR/local"
  [ "$status" -eq 0 ]
  [ -d "$HOME/.docker-cc/repo" ]
  [ -f "$HOME/.docker-cc/repo/Dockerfile" ]
  [ -f "$HOME/.docker-cc/repo/docker-compose.yml" ]
  [ -d "$HOME/.docker-cc/providers" ]
  [ -f "$HOME/.docker-cc/providers/anthropic.json" ]
  # --skip-link 时不应建 symlink
  [ ! -L "$BATS_TEST_TMPDIR/local/bin/cc" ]
}

@test "install.sh --prefix 模式建 symlink 到指定目录" {
  cd "$PROJECT_ROOT"
  run ./install.sh --skip-build --prefix="$BATS_TEST_TMPDIR/local"
  [ "$status" -eq 0 ]
  [ -L "$BATS_TEST_TMPDIR/local/bin/cc" ]
  [ -L "$BATS_TEST_TMPDIR/local/bin/cc-use" ]
}

@test "install.sh --no-cn-mirror 在 .env 写入空加速变量" {
  cd "$PROJECT_ROOT"
  ./install.sh --skip-build --skip-link --prefix="$BATS_TEST_TMPDIR/local" --no-cn-mirror
  run grep '^GH_PROXY=' "$HOME/.docker-cc/repo/.env"
  [ "$output" = "GH_PROXY=" ]
  run grep '^APT_MIRROR=' "$HOME/.docker-cc/repo/.env"
  [ "$output" = "APT_MIRROR=deb.debian.org" ]
}
