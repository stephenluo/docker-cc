#!/usr/bin/env bash
# docker-cc 一键安装入口。
#
# 用法：
#   curl -fsSL https://ghfast.top/raw.githubusercontent.com/stephenluo/docker-cc/main/scripts/quick-install.sh | bash
#
# 环境变量：
#   DCC_VERSION    指定版本（默认 latest，从 GitHub API 探测）
#   DCC_GHPROXY    GitHub 加速前缀（默认 https://ghfast.top/；置空走直链）
#   DCC_REPO       仓库 owner/name（默认 stephenluo/docker-cc，便于 fork）
#
# 透传给 install.sh：剩余位置参数（如 --registry=global、--build-local 等）
# 例：curl ... | bash -s -- --registry=global

set -euo pipefail

DCC_VERSION="${DCC_VERSION:-latest}"
DCC_GHPROXY="${DCC_GHPROXY-https://ghfast.top/}"     # 用 - 不用 :- ，允许置空走直链
DCC_REPO="${DCC_REPO:-stephenluo/docker-cc}"

# —— 工具函数 ——
ok()   { echo "  ✓ $*"; }
fail() { echo "  ✗ $*" >&2; exit 1; }
info() { echo "[quick-install] $*"; }

# —— 1. 依赖检查 ——
for c in curl tar; do
  command -v "$c" >/dev/null 2>&1 || fail "未找到 $c，请先安装"
done
command -v docker >/dev/null 2>&1 \
  || fail "未找到 docker（需先装 Docker Desktop / OrbStack / Colima）"

# —— 2. 探测 latest 版本 ——
if [ "$DCC_VERSION" = "latest" ]; then
  info "探测 latest 版本..."
  # ghfast/ghproxy 通常也代理 api.github.com；如不代理则 DCC_GHPROXY= 走直链
  API_URL="${DCC_GHPROXY}https://api.github.com/repos/${DCC_REPO}/releases/latest"
  # 不用 jq（quick-install 必须无依赖）：grep + sed 精确匹配 "tag_name": "..."
  # 关键：sed 正则必须锁 "tag_name"，否则贪婪匹配会错抓为 "tag_name" 字符串本身
  tag=$(curl -fsSL --max-time 10 "$API_URL" \
          | grep -E '"tag_name"[[:space:]]*:' | head -1 \
          | sed -E 's/.*"tag_name"[[:space:]]*:[[:space:]]*"v?([^"]+)".*/\1/')
  [ -n "$tag" ] || fail "无法探测 latest 版本（API 不可达或 release 不存在；可用 DCC_VERSION=<x.y.z> 跳过探测）"
  DCC_VERSION="$tag"
fi
ok "目标版本：$DCC_VERSION"

# —— 3. 下 tarball ——
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT          # 正常退出 / Ctrl-C / 出错都自动清理

TARBALL_URL="${DCC_GHPROXY}https://github.com/${DCC_REPO}/releases/download/v${DCC_VERSION}/docker-cc-${DCC_VERSION}.tgz"
info "下载 tarball: $TARBALL_URL"
curl -fsSL --max-time 120 "$TARBALL_URL" -o "$TMP/docker-cc.tgz" \
  || fail "tarball 下载失败。试试换 DCC_GHPROXY（如 https://gh-proxy.com/）或置空走直链"

# 校验 sha256（如果 release 资产包含 .sha256 文件；缺失则容忍，mismatch 则退出）
SHA_URL="${TARBALL_URL}.sha256"
if curl -fsSL --max-time 10 "$SHA_URL" -o "$TMP/docker-cc.tgz.sha256" 2>/dev/null; then
  expected="$(awk '{print $1}' "$TMP/docker-cc.tgz.sha256")"
  if command -v sha256sum >/dev/null 2>&1; then
    actual="$(sha256sum "$TMP/docker-cc.tgz" | awk '{print $1}')"
  else
    actual="$(shasum -a 256 "$TMP/docker-cc.tgz" | awk '{print $1}')"
  fi
  [ "$expected" = "$actual" ] || fail "tarball 校验失败：$expected vs $actual"
  ok "sha256 校验通过"
fi

# —— 4. 解压 ——
tar -xzf "$TMP/docker-cc.tgz" -C "$TMP"
SRC_DIR="$TMP/docker-cc-${DCC_VERSION}"
[ -d "$SRC_DIR" ] || fail "解压结果异常：$SRC_DIR 不存在"
ok "已解压到 $SRC_DIR"

# —— 5. 跑 install.sh（透传所有位置参数）——
info "运行 install.sh ${*:-(无额外参数)}"
cd "$SRC_DIR"
./install.sh "$@"

# —— 6. EXIT trap 自动清理 $TMP ——
info "完成。工作目录无残留。"
