#!/usr/bin/env bash
# uninstall.sh：卸载 cc / cc-use 命令软链。
# 默认不删除 ~/.docker-cc/ 配置目录（含 OAuth 凭据等用户数据），需用户手动清理。
set -eo pipefail

PREFIX="/usr/local"
PURGE=0
for arg in "$@"; do
  case "$arg" in
    --prefix=*) PREFIX="${arg#--prefix=}" ;;
    --purge)    PURGE=1 ;;
    -h|--help)
      cat <<'EOF'
用法: ./uninstall.sh [选项]

选项：
  --prefix=<dir>   软链所在目录，默认 /usr/local
  --purge          一并删除 ~/.docker-cc/ 配置目录（含订阅、凭据，慎用！）
  -h, --help       显示本帮助
EOF
      exit 0 ;;
    *) echo "未知参数: $arg"; exit 1 ;;
  esac
done

echo "[1/3] 移除命令软链"
for cmd in cc cc-use; do
  link="$PREFIX/bin/$cmd"
  if [ -L "$link" ]; then
    if [ -w "$PREFIX/bin" ]; then rm -f "$link"; else sudo rm -f "$link"; fi
    echo "  ✓ 已移除 $link"
  else
    echo "    $link 不存在，跳过"
  fi
done

echo "[2/3] 停止 docker 服务"
if [ -d "$HOME/.docker-cc/repo" ]; then
  ( cd "$HOME/.docker-cc/repo" && docker compose down 2>/dev/null ) || true
  echo "  ✓ docker compose down"
fi

echo "[3/3] 配置目录"
if [ "$PURGE" = "1" ]; then
  rm -rf "$HOME/.docker-cc"
  echo "  ✓ 已删除 ~/.docker-cc/（含所有用户数据）"
else
  echo "  保留 ~/.docker-cc/（含订阅、token、OAuth 凭据等）"
  echo "  如需彻底清理：./uninstall.sh --purge  或  rm -rf ~/.docker-cc"
fi

echo "完成。"
