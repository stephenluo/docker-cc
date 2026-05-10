#!/usr/bin/env bats
# dcc probe 子命令：探测 GH_PROXY 备用源（开发期发现 mirror.ghproxy.com 经常挂）
load ../fixtures/helpers

setup() { isolate_integration_env; }

@test "dcc probe: 探测后写入 .env 的 GH_PROXY（成功路径）" {
  # 真实跑会 curl 5 个外网源；CI 中跑此测试需要外网
  # 本地开发可 skip：bats --filter '...probe.*成功' tests/unit/dcc_probe.bats
  run dcc probe
  [ "$status" -eq 0 ]
  run grep '^GH_PROXY=' "$DOCKER_CC_HOME/.env"
  [[ "$output" =~ ^GH_PROXY= ]]
  # 写入的值要么是 https://...（某代理）要么是空（直连兜底）
  [[ "$output" =~ ^GH_PROXY=(https://.*/|)$ ]]
}

@test "dcc probe: 不重复 GH_PROXY 行（多次调用幂等）" {
  dcc probe 2>/dev/null || true
  dcc probe 2>/dev/null || true
  run grep -c '^GH_PROXY=' "$DOCKER_CC_HOME/.env"
  [ "$output" = "1" ]
}
