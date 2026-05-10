#!/usr/bin/env bats
# 集成测试：PWD 隔离（回归 #2 PWD 污染）
# 需要 docker-cc:latest 镜像已 build
load ../fixtures/helpers

setup() { isolate_integration_env; }

@test "PWD 隔离：当前目录被挂载到 /workspace（不通过 claude LLM）" {
  d="$BATS_TEST_TMPDIR/some-project"
  mkdir -p "$d"
  echo "marker-content" > "$d/MARKER"
  cd "$d"

  # 不通过 claude LLM（输出不可预测），直接用 cat 验证挂载
  # --entrypoint cat 跳过 entrypoint 健康检查；不依赖 mihomo
  run docker run --rm \
    -v "$d:/workspace" \
    --entrypoint cat \
    docker-cc:latest \
    /workspace/MARKER
  [ "$status" -eq 0 ]
  [ "$output" = "marker-content" ]
}

@test "dcc 脚本 cd 后仍能挂载用户原始 PWD（HOST_PWD 机制，回归 #2）" {
  d="$BATS_TEST_TMPDIR/some-project"
  mkdir -p "$d"
  echo "ok-from-host-pwd" > "$d/MARKER"
  cd "$d"

  # 模拟 dcc 脚本：保存 HOST_PWD 然后 cd，期望 ${HOST_PWD} 被解析成 $d
  run env HOST_PWD="$d" docker compose -f "$DOCKER_CC_HOME/docker-compose.yml" \
    run --rm --no-deps --entrypoint cat cc /workspace/MARKER
  [ "$status" -eq 0 ]
  [ "$output" = "ok-from-host-pwd" ]
}
