#!/usr/bin/env bash
# install.sh：把 docker-cc 安装到当前用户。
# 详见 docs/implementation-plan.md §9 / §9.1
set -eo pipefail

# —— 参数解析 ——
NO_CN_MIRROR=0
SKIP_BUILD=0
SKIP_LINK=0
PREFIX="/usr/local"
for arg in "$@"; do
  case "$arg" in
    --no-cn-mirror)  NO_CN_MIRROR=1 ;;
    --skip-build)    SKIP_BUILD=1 ;;
    --skip-link)     SKIP_LINK=1 ;;
    --prefix=*)      PREFIX="${arg#--prefix=}" ;;
    -h|--help)
      cat <<'EOF'
用法: ./install.sh [选项]

选项：
  --no-cn-mirror      关闭国内加速（写 .env 中 APT_MIRROR/GH_PROXY/NPM_REGISTRY 空值）
  --skip-build        跳过 docker compose build（适用于镜像已存在或 CI 单独 build）
  --skip-link         跳过把 dcc/dcc-use 软链到 PREFIX/bin/（不需要 sudo）
  --prefix=<dir>      软链放到 <dir>/bin/，默认 /usr/local
  -h, --help          显示本帮助
EOF
      exit 0 ;;
    *)
      echo "未知参数: $arg"; exit 1 ;;
  esac
done

# 项目根目录（脚本所在目录）
PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DOCKER_CC_HOME="${HOME}/.docker-cc"
REPO_DIR="$DOCKER_CC_HOME/repo"

ok()    { echo "  ✓ $*"; }
fail()  { echo "  ✗ $*" >&2; exit 1; }
note()  { echo "    $*"; }

# 1. 检查依赖
echo "[1/7] 检查依赖"
command -v docker >/dev/null 2>&1 || fail "未找到 docker，请先安装 Docker Desktop / OrbStack / Colima"
docker compose version >/dev/null 2>&1 || fail "未找到 docker compose v2，请升级 Docker"
ok "docker / docker compose 可用"

# 2. 创建目录树
echo "[2/7] 创建 ~/.docker-cc/ 目录树"
mkdir -p "$DOCKER_CC_HOME"/{mihomo,claude,providers,repo}
# 含敏感数据的目录（providers 含 API key、claude 含 OAuth 凭据）权限 700
chmod 700 "$DOCKER_CC_HOME/providers" "$DOCKER_CC_HOME/claude"
ok "创建 $DOCKER_CC_HOME"

# 3. 复制仓库内容到 ~/.docker-cc/repo/（保证 dcc upgrade 时 docker compose build 有完整 context）
echo "[3/7] 复制仓库内容到 $REPO_DIR"
# 使用 rsync 排除 git/docs/tests/.docker-cc 等无关项
if command -v rsync >/dev/null 2>&1; then
  rsync -a --delete \
    --exclude='.git' --exclude='docs' --exclude='tests' --exclude='.docker-cc' \
    --exclude='.github' --exclude='node_modules' \
    "$PROJECT_ROOT/" "$REPO_DIR/"
else
  # rsync 不存在时退化用 cp
  cp -R "$PROJECT_ROOT/Dockerfile" "$PROJECT_ROOT/docker-compose.yml" \
        "$PROJECT_ROOT/entrypoint.sh" "$PROJECT_ROOT/.env.example" \
        "$PROJECT_ROOT/VERSION" \
        "$REPO_DIR/" 2>/dev/null || true
  cp -R "$PROJECT_ROOT/bin" "$REPO_DIR/" 2>/dev/null || true
  cp -R "$PROJECT_ROOT/providers" "$REPO_DIR/" 2>/dev/null || true
fi
ok "已复制必要文件"

# 4. 处理 .env：首次创建则从 .env.example 复制；--no-cn-mirror 时关闭加速源
if [ ! -f "$REPO_DIR/.env" ]; then
  cp "$REPO_DIR/.env.example" "$REPO_DIR/.env"
  ok "已创建 $REPO_DIR/.env（请编辑填入 CLASH_SUB_URL）"
fi
# .env 可能含订阅 URL 内嵌 token，权限 600
chmod 600 "$REPO_DIR/.env"
if [ "$NO_CN_MIRROR" = "1" ]; then
  {
    grep -v -E '^(APT_MIRROR|GH_PROXY|NPM_REGISTRY)=' "$REPO_DIR/.env" 2>/dev/null || true
    echo "APT_MIRROR=deb.debian.org"
    echo "GH_PROXY="
    echo "NPM_REGISTRY=https://registry.npmjs.org"
  } > "$REPO_DIR/.env.tmp"
  mv "$REPO_DIR/.env.tmp" "$REPO_DIR/.env"
  chmod 600 "$REPO_DIR/.env"
  ok "--no-cn-mirror：已关闭国内加速源"
elif [ "$SKIP_BUILD" != "1" ]; then
  # 自动 probe GH_PROXY（共享脚本 bin/_dcc-probe-ghproxy 维护探测逻辑 + 镜像源列表）
  echo "  探测可用的 GH_PROXY 镜像源..."
  "$PROJECT_ROOT/bin/_dcc-probe-ghproxy" "$REPO_DIR/.env" \
    || fail "所有 GH_PROXY 镜像源都不可达。检查网络或加 --no-cn-mirror"
fi

# 5. docker build
echo "[4/7] 构建镜像"
if [ "$SKIP_BUILD" = "1" ]; then
  note "(--skip-build) 跳过"
else
  ( cd "$REPO_DIR" && docker compose build )
  ok "镜像 docker-cc:latest 已构建"
fi

# 6. 复制 providers 模板
echo "[5/7] 部署供应商模板"
for tpl in "$PROJECT_ROOT/providers/"*.json.example; do
  [ -f "$tpl" ] || continue
  name=$(basename "$tpl" .json.example)
  target="$DOCKER_CC_HOME/providers/${name}.json"
  if [ ! -f "$target" ]; then
    cp "$tpl" "$target"
    chmod 600 "$target"     # 含明文 API key，仅当前用户可读
    ok "$(basename "$target")（首次创建）"
  else
    chmod 600 "$target" 2>/dev/null || true   # 修旧文件权限
    note "$(basename "$target") 已存在，跳过"
  fi
done

# 7. 软链 dcc / dcc-use 到 PREFIX/bin/
echo "[6/7] 安装 dcc / dcc-use 命令"
if [ "$SKIP_LINK" = "1" ]; then
  note "(--skip-link) 跳过"
else
  # /usr/local/bin 创建可能需要 sudo（父目录 /usr/local 通常 root 拥有）
  if ! mkdir -p "$PREFIX/bin" 2>/dev/null; then
    sudo mkdir -p "$PREFIX/bin" \
      || fail "无法创建 $PREFIX/bin（既无写权限，sudo 也失败）。换 --prefix=$HOME/.local 试试"
  fi
  # 用户能直接写 → ln；否则 sudo ln
  if [ -w "$PREFIX/bin" ]; then
    LN="ln"
  else
    LN="sudo ln"
    note "$PREFIX/bin 需要 sudo 权限"
  fi
  $LN -sf "$PROJECT_ROOT/bin/dcc"     "$PREFIX/bin/dcc"     || fail "软链 dcc 失败"
  $LN -sf "$PROJECT_ROOT/bin/dcc-use" "$PREFIX/bin/dcc-use" || fail "软链 dcc-use 失败"
  ok "$PREFIX/bin/dcc → $PROJECT_ROOT/bin/dcc"
  ok "$PREFIX/bin/dcc-use → $PROJECT_ROOT/bin/dcc-use"
fi

# 8. 提示
echo "[7/7] 完成！"
cat <<EOF

下一步：
  1. 启动并指定订阅 URL:
     dcc up "https://your-airport.com/subscription"

  2. 编辑 LLM 供应商的 token（任选一个）:
     dcc-use edit anthropic
     dcc-use edit deepseek

  3. 切到该供应商:
     dcc-use anthropic
     # 或 OAuth 模式（Claude Pro/Max）:
     dcc login

  4. 进入项目目录正常使用:
     cd ~/your-project && dcc

文档：
  docs/implementation-plan.md       # 完整设计
  docs/testing.md                   # 测试方案
EOF
