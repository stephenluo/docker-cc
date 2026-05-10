#!/usr/bin/env bats
# 集成测试：dcc upgrade 不丢配置（settings.json + providers + cache.db）
# 真实跑 docker compose build，耗时较长，CI 中标 slow 标签
load ../fixtures/helpers

setup() { isolate_integration_env; }
teardown() { cd "$DOCKER_CC_HOME" && docker compose down 2>/dev/null || true; }

@test "dcc upgrade 后 settings.json 保留 (不污染真实环境)" {
  dcc-use add foo --api-key=K-persist --base-url=https://test.com
  dcc-use foo
  before=$(jq -r '.env.ANTHROPIC_AUTH_TOKEN' "$CLAUDE_SETTINGS")
  [ "$before" = "K-persist" ]

  # docker compose build 真实跑，但走 docker layer cache 应秒过
  run dcc upgrade claude
  [ "$status" -eq 0 ]

  after=$(jq -r '.env.ANTHROPIC_AUTH_TOKEN' "$CLAUDE_SETTINGS")
  [ "$after" = "K-persist" ]
}

@test "dcc upgrade 后 providers/*.json 仍存在" {
  dcc-use add foo --api-key=K --base-url=https://test.com
  dcc-use add bar --mode=oauth
  dcc upgrade claude
  [ -f "$PROVIDERS_DIR/foo.json" ]
  [ -f "$PROVIDERS_DIR/bar.json" ]
}
