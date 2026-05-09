#!/usr/bin/env bats
# 集成测试：cc upgrade 不丢配置（settings.json + providers + cache.db）
# 真实跑 docker compose build，耗时较长，CI 中标 slow 标签
load ../fixtures/helpers

setup() { isolate_integration_env; }
teardown() { cd "$DOCKER_CC_HOME" && docker compose down 2>/dev/null || true; }

@test "cc upgrade 后 settings.json 保留 (不污染真实环境)" {
  cc-use add foo --api-key=K-persist --base-url=https://test.com
  cc-use foo
  before=$(jq -r '.env.ANTHROPIC_AUTH_TOKEN' "$CLAUDE_SETTINGS")
  [ "$before" = "K-persist" ]

  # docker compose build 真实跑，但走 docker layer cache 应秒过
  run cc upgrade claude
  [ "$status" -eq 0 ]

  after=$(jq -r '.env.ANTHROPIC_AUTH_TOKEN' "$CLAUDE_SETTINGS")
  [ "$after" = "K-persist" ]
}

@test "cc upgrade 后 providers/*.json 仍存在" {
  cc-use add foo --api-key=K --base-url=https://test.com
  cc-use add bar --mode=oauth
  cc upgrade claude
  [ -f "$PROVIDERS_DIR/foo.json" ]
  [ -f "$PROVIDERS_DIR/bar.json" ]
}
