#!/usr/bin/env bats
# install.sh 软链方向：必须指向 $REPO_DIR/bin/（而非 $PROJECT_ROOT/bin/），
# 让用户跑完安装后可以删除工作目录。
load ../fixtures/helpers

setup() {
  isolate_unit_env
  export PATH="$PROJECT_ROOT/tests/fixtures:$PATH"
  export FAKE_DOCKER_LOG="$BATS_TEST_TMPDIR/docker.log"
  export HOME="$BATS_TEST_TMPDIR"
  # 软链放到测试临时目录，避免污染 /usr/local/bin
  export FAKE_PREFIX="$BATS_TEST_TMPDIR/fake-prefix"
}

@test "软链指向 \$REPO_DIR/bin/，而非 \$PROJECT_ROOT/bin/" {
  run "$PROJECT_ROOT/install.sh" --skip-build --no-cn-mirror --prefix="$FAKE_PREFIX"
  [ "$status" -eq 0 ]

  # 软链存在
  [ -L "$FAKE_PREFIX/bin/dcc" ]
  [ -L "$FAKE_PREFIX/bin/dcc-use" ]

  # 软链 target 应该在 ~/.docker-cc/repo/bin/ 下
  target_dcc="$(readlink "$FAKE_PREFIX/bin/dcc")"
  target_dccuse="$(readlink "$FAKE_PREFIX/bin/dcc-use")"

  [[ "$target_dcc"    == *".docker-cc/repo/bin/dcc"     ]]
  [[ "$target_dccuse" == *".docker-cc/repo/bin/dcc-use" ]]

  # 反例：必须不指向 PROJECT_ROOT（即源码目录）
  [[ "$target_dcc"    != "$PROJECT_ROOT/bin/dcc"     ]]
  [[ "$target_dccuse" != "$PROJECT_ROOT/bin/dcc-use" ]]
}

@test "软链 target 实际可执行（即 $REPO_DIR/bin/dcc 由 install.sh 同步出来了）" {
  run "$PROJECT_ROOT/install.sh" --skip-build --no-cn-mirror --prefix="$FAKE_PREFIX"
  [ "$status" -eq 0 ]

  # 通过软链调用 dcc -v 应能输出 VERSION
  run "$FAKE_PREFIX/bin/dcc" -v
  [ "$status" -eq 0 ]
  ver="$(cat "$PROJECT_ROOT/VERSION")"
  [[ "$output" == *"$ver"* ]]
}

@test "重跑 install.sh 后软链仍指向 \$REPO_DIR/bin/（ln -sf 覆盖语义）" {
  # 先建一个老式（指向 PROJECT_ROOT）的软链模拟旧版用户
  mkdir -p "$FAKE_PREFIX/bin"
  ln -sf "$PROJECT_ROOT/bin/dcc" "$FAKE_PREFIX/bin/dcc"

  # 跑新版 install.sh
  run "$PROJECT_ROOT/install.sh" --skip-build --no-cn-mirror --prefix="$FAKE_PREFIX"
  [ "$status" -eq 0 ]

  # 应已覆盖为 REPO_DIR 指向
  target="$(readlink "$FAKE_PREFIX/bin/dcc")"
  [[ "$target" == *".docker-cc/repo/bin/dcc" ]]
}
