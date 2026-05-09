#!/usr/bin/env bash
# install.sh：把 docker-cc 安装到当前用户。
# 详见 docs/implementation-plan.md §9 / §9.1
set -e

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
  --skip-link         跳过把 cc/cc-use 软链到 PREFIX/bin/（不需要 sudo）
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

# 探测 GH_PROXY 备用源，stdout 输出第一个连通的 prefix（可能为空=直连 GitHub）
# 探测过程输出到 stderr 不污染 stdout
probe_ghproxy() {
  local target="github.com/mikefarah/yq/releases/download/v4.45.1/yq_linux_amd64"
  local prefixes=(
    "https://mirror.ghproxy.com/"
    "https://ghfast.top/"
    "https://gh-proxy.com/"
    "https://ghps.cc/"
    ""
  )
  local p
  for p in "${prefixes[@]}"; do
    if [ -n "$p" ]; then
      printf "    探测 %-32s ... " "$p" >&2
    else
      printf "    %-39s ... " "探测 直连 GitHub（无加速）" >&2
    fi
    # -r 0-1024 仅下载头 1KB，快速验证连通性
    if curl -sfL --max-time 5 -r 0-1024 -o /dev/null "${p}https://${target}" 2>/dev/null; then
      echo "✓" >&2
      echo "$p"
      return 0
    fi
    echo "✗" >&2
  done
  return 1
}

# 1. 检查依赖
echo "[1/7] 检查依赖"
command -v docker >/dev/null 2>&1 || fail "未找到 docker，请先安装 Docker Desktop / OrbStack / Colima"
docker compose version >/dev/null 2>&1 || fail "未找到 docker compose v2，请升级 Docker"
ok "docker / docker compose 可用"

# 2. 创建目录树
echo "[2/7] 创建 ~/.docker-cc/ 目录树"
mkdir -p "$DOCKER_CC_HOME"/{mihomo,claude,providers,repo}
ok "创建 $DOCKER_CC_HOME"

# 3. 复制仓库内容到 ~/.docker-cc/repo/（保证 cc upgrade 时 docker compose build 有完整 context）
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
if [ "$NO_CN_MIRROR" = "1" ]; then
  {
    grep -v -E '^(APT_MIRROR|GH_PROXY|NPM_REGISTRY)=' "$REPO_DIR/.env" 2>/dev/null || true
    echo "APT_MIRROR=deb.debian.org"
    echo "GH_PROXY="
    echo "NPM_REGISTRY=https://registry.npmjs.org"
  } > "$REPO_DIR/.env.tmp"
  mv "$REPO_DIR/.env.tmp" "$REPO_DIR/.env"
  ok "--no-cn-mirror：已关闭国内加速源"
elif [ "$SKIP_BUILD" != "1" ]; then
  # 自动 probe GH_PROXY：避免遇到某个镜像源临时挂掉（如 mirror.ghproxy.com）
  echo "  探测可用的 GH_PROXY 镜像源..."
  if SELECTED_GH_PROXY=$(probe_ghproxy); then
    {
      grep -v '^GH_PROXY=' "$REPO_DIR/.env" 2>/dev/null || true
      echo "GH_PROXY=${SELECTED_GH_PROXY}"
    } > "$REPO_DIR/.env.tmp"
    mv "$REPO_DIR/.env.tmp" "$REPO_DIR/.env"
    if [ -n "$SELECTED_GH_PROXY" ]; then
      ok "选用 GH_PROXY=${SELECTED_GH_PROXY}"
    else
      ok "选用 直连 GitHub（无加速）"
    fi
  else
    fail "所有 GH_PROXY 镜像源都不可达。检查网络或加 --no-cn-mirror"
  fi
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
    ok "$(basename "$target")（首次创建）"
  else
    note "$(basename "$target") 已存在，跳过"
  fi
done

# 7. 软链 cc / cc-use 到 PREFIX/bin/
echo "[6/7] 安装 cc / cc-use 命令"
if [ "$SKIP_LINK" = "1" ]; then
  note "(--skip-link) 跳过"
else
  mkdir -p "$PREFIX/bin"
  # /usr/local/bin 通常需要 sudo；其他 prefix 默认用户可写
  if [ -w "$PREFIX/bin" ]; then
    LN="ln"
  else
    LN="sudo ln"
    note "$PREFIX/bin 需要 sudo 权限"
  fi
  $LN -sf "$PROJECT_ROOT/bin/cc"     "$PREFIX/bin/cc"
  $LN -sf "$PROJECT_ROOT/bin/cc-use" "$PREFIX/bin/cc-use"
  ok "$PREFIX/bin/cc → $PROJECT_ROOT/bin/cc"
  ok "$PREFIX/bin/cc-use → $PROJECT_ROOT/bin/cc-use"
fi

# 8. 提示
echo "[7/7] 完成！"
cat <<EOF

下一步：
  1. 启动并指定订阅 URL:
     cc up "https://your-airport.com/subscription"

  2. 编辑 LLM 供应商的 token（任选一个）:
     cc-use edit anthropic
     cc-use edit deepseek

  3. 切到该供应商:
     cc-use anthropic
     # 或 OAuth 模式（Claude Pro/Max）:
     cc login

  4. 进入项目目录正常使用:
     cd ~/your-project && cc

文档：
  docs/implementation-plan.md       # 完整设计
  docs/testing.md                   # 测试方案
EOF
