#!/usr/bin/env bats
# scripts/quick-install.sh：验证版本探测、tarball 下载、sha256 校验、参数透传、$TMP 清理。
# 用本地 python http.server 模拟 GitHub raw / release，无需真实网络。
load ../fixtures/helpers

setup() {
  isolate_unit_env
  export PATH="$PROJECT_ROOT/tests/fixtures:$PATH"
  export HOME="$BATS_TEST_TMPDIR"
  export FAKE_DOCKER_LOG="$BATS_TEST_TMPDIR/docker.log"

  # 起 mock release server：在 $MOCK_DIR 下铺出 GitHub release 的目录结构
  MOCK_DIR="$BATS_TEST_TMPDIR/mock"
  MOCK_VER="9.9.9"
  mkdir -p "$MOCK_DIR/repos/owner/docker-cc/releases"
  mkdir -p "$MOCK_DIR/owner/docker-cc/releases/download/v${MOCK_VER}"

  # latest API 响应
  printf '{"tag_name": "v%s"}\n' "$MOCK_VER" \
    > "$MOCK_DIR/repos/owner/docker-cc/releases/latest"

  # 假 tarball：里面包含一个 install.sh 用于验证 quick-install.sh 调用它
  pkg_dir="$BATS_TEST_TMPDIR/pkg/docker-cc-${MOCK_VER}"
  mkdir -p "$pkg_dir"
  cat > "$pkg_dir/install.sh" <<'EOF'
#!/usr/bin/env bash
echo "FAKE_INSTALL_CALLED args: $*"
echo "FAKE_INSTALL_CWD: $(pwd)"
exit 0
EOF
  chmod +x "$pkg_dir/install.sh"
  ( cd "$BATS_TEST_TMPDIR/pkg" && tar czf "$MOCK_DIR/owner/docker-cc/releases/download/v${MOCK_VER}/docker-cc-${MOCK_VER}.tgz" "docker-cc-${MOCK_VER}" )

  # sha256 文件
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$MOCK_DIR/owner/docker-cc/releases/download/v${MOCK_VER}/docker-cc-${MOCK_VER}.tgz" \
      | awk '{print $1}' \
      > "$MOCK_DIR/owner/docker-cc/releases/download/v${MOCK_VER}/docker-cc-${MOCK_VER}.tgz.sha256"
  else
    shasum -a 256 "$MOCK_DIR/owner/docker-cc/releases/download/v${MOCK_VER}/docker-cc-${MOCK_VER}.tgz" \
      | awk '{print $1}' \
      > "$MOCK_DIR/owner/docker-cc/releases/download/v${MOCK_VER}/docker-cc-${MOCK_VER}.tgz.sha256"
  fi

  # 同时给 raw 路径放 quick-install.sh 副本（让 quick-install.sh URL 也能拉到，但本测试是直接跑本地 sh，不走 raw）
  mkdir -p "$MOCK_DIR/owner/docker-cc/main/scripts"
  cp "$PROJECT_ROOT/scripts/quick-install.sh" "$MOCK_DIR/owner/docker-cc/main/scripts/"

  # 起 http server（端口冲突时往上挪）
  PORT=8765
  python3 -m http.server "$PORT" --bind 127.0.0.1 --directory "$MOCK_DIR" >/dev/null 2>&1 &
  echo "$!" > "$BATS_TEST_TMPDIR/http_pid"
  # 等服务起来
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    if curl -fsS --max-time 1 "http://127.0.0.1:${PORT}/" >/dev/null 2>&1; then break; fi
    sleep 0.2
  done

  export DCC_GHPROXY="http://127.0.0.1:${PORT}/"
  export DCC_REPO="owner/docker-cc"
  # quick-install.sh 会拼接 ${DCC_GHPROXY}https://...，需要 mock server 同时响应 https URL path。
  # 简化：让 mock server 直接服务 path 是 "https/..." 的请求。
  # 在 mock dir 下软链 https:/ -> .（让 path /https://github.com/... 能命中本地相对路径）
  ln -sf . "$MOCK_DIR/https:"
  # python http.server 收到 GET /https://github.com/owner/... 会解析为 /https:/github.com/owner/...
  # 加上软链 https: -> .，路径变成 ./github.com/owner/...，需把 mock 文件放在 $MOCK_DIR/github.com/owner/...
  mkdir -p "$MOCK_DIR/github.com/owner/docker-cc/releases/download/v${MOCK_VER}"
  cp "$MOCK_DIR/owner/docker-cc/releases/download/v${MOCK_VER}/docker-cc-${MOCK_VER}.tgz" \
     "$MOCK_DIR/github.com/owner/docker-cc/releases/download/v${MOCK_VER}/"
  cp "$MOCK_DIR/owner/docker-cc/releases/download/v${MOCK_VER}/docker-cc-${MOCK_VER}.tgz.sha256" \
     "$MOCK_DIR/github.com/owner/docker-cc/releases/download/v${MOCK_VER}/"
  mkdir -p "$MOCK_DIR/api.github.com/repos/owner/docker-cc/releases"
  cp "$MOCK_DIR/repos/owner/docker-cc/releases/latest" \
     "$MOCK_DIR/api.github.com/repos/owner/docker-cc/releases/latest"
}

teardown() {
  if [ -f "$BATS_TEST_TMPDIR/http_pid" ]; then
    kill "$(cat "$BATS_TEST_TMPDIR/http_pid")" 2>/dev/null || true
  fi
}

@test "DCC_VERSION=<x.y.z> 跳过 latest 探测，拉对应 tarball，调 install.sh" {
  export DCC_VERSION="9.9.9"
  run bash "$PROJECT_ROOT/scripts/quick-install.sh" --foo=bar
  [ "$status" -eq 0 ]
  [[ "$output" =~ "FAKE_INSTALL_CALLED args: --foo=bar" ]]
  [[ "$output" =~ "docker-cc-9.9.9" ]]
  [[ "$output" =~ "完成。工作目录无残留" ]]
}

@test "DCC_VERSION=latest 通过 mock GitHub API 探测到 9.9.9" {
  export DCC_VERSION="latest"
  run bash "$PROJECT_ROOT/scripts/quick-install.sh"
  [ "$status" -eq 0 ]
  [[ "$output" =~ "目标版本：9.9.9" ]]
}

@test "sha256 校验通过时显式打印通过消息" {
  export DCC_VERSION="9.9.9"
  run bash "$PROJECT_ROOT/scripts/quick-install.sh"
  [ "$status" -eq 0 ]
  [[ "$output" =~ "sha256 校验通过" ]]
}

@test "sha256 mismatch 时失败退出" {
  export DCC_VERSION="9.9.9"
  # 篡改 .sha256 为错误值
  echo "deadbeef0000000000000000000000000000000000000000000000000000beef" \
    > "$BATS_TEST_TMPDIR/mock/github.com/owner/docker-cc/releases/download/v9.9.9/docker-cc-9.9.9.tgz.sha256"
  run bash "$PROJECT_ROOT/scripts/quick-install.sh"
  [ "$status" -ne 0 ]
  [[ "$output" =~ "校验失败" ]]
}

@test ".sha256 不存在时容忍（默认信任 release）" {
  export DCC_VERSION="9.9.9"
  rm "$BATS_TEST_TMPDIR/mock/github.com/owner/docker-cc/releases/download/v9.9.9/docker-cc-9.9.9.tgz.sha256"
  run bash "$PROJECT_ROOT/scripts/quick-install.sh"
  [ "$status" -eq 0 ]
  # 不应出现校验通过消息（因为没文件可校验）
  [[ ! "$output" =~ "sha256 校验通过" ]]
}

@test "tarball 不存在时给出明确报错（不卡死）" {
  export DCC_VERSION="0.0.0-nonexistent"
  run bash "$PROJECT_ROOT/scripts/quick-install.sh"
  [ "$status" -ne 0 ]
  [[ "$output" =~ "tarball 下载失败" ]]
}

@test "依赖缺失时报错（mock 掉 docker）" {
  # 把 PATH 限制到不含 docker 的目录
  export PATH="/usr/bin:/bin"
  export DCC_VERSION="9.9.9"
  run bash "$PROJECT_ROOT/scripts/quick-install.sh"
  [ "$status" -ne 0 ]
  [[ "$output" =~ "未找到 docker" ]]
}

@test "退出后 \$TMP 自动清理（trap EXIT 验证）" {
  export DCC_VERSION="9.9.9"
  # 记录跑之前的 /tmp/tmp.* 列表
  before_count=$(ls -d /tmp/tmp.* 2>/dev/null | wc -l | tr -d ' ')
  bash "$PROJECT_ROOT/scripts/quick-install.sh" >/dev/null 2>&1 || true
  after_count=$(ls -d /tmp/tmp.* 2>/dev/null | wc -l | tr -d ' ')
  # 两次计数应相等（quick-install 创建的 mktemp 目录已清理）
  [ "$before_count" = "$after_count" ]
}
