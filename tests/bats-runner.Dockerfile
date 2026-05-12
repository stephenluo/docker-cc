# 本地 bats 测试运行环境 —— 预装 bats + 测试用依赖，避免每次 docker run 重拉 apk 包。
#
# 用法：
#   一次性 build:
#     docker build -t bats-runner:local -f tests/bats-runner.Dockerfile tests/
#   跑全套 unit tests:
#     docker run --rm -v "$PWD:/code" -w /code bats-runner:local tests/unit/
#   跑单个文件:
#     docker run --rm -v "$PWD:/code" -w /code bats-runner:local tests/unit/dcc_upgrade.bats
#   并行（端口冲突时 quick_install.bats 串行，其他并行）:
#     docker run --rm -v "$PWD:/code" -w /code bats-runner:local --jobs 4 tests/unit/

FROM bats/bats:1.10.0

# tests 依赖：
#   jq         —— dcc-use 测试断言 JSON 字段
#   curl       —— quick_install.bats 调 mock release server
#   python3    —— quick_install.bats 起 mock HTTP server (python3 -m http.server)
# 镜像内已有 bash / tar / coreutils（alpine + bats/bats 基础）
RUN apk add --no-cache jq curl python3
