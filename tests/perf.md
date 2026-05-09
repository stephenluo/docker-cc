# 性能基线

> 每次 release 前重新测一遍，记录到本表追加行（保留历史）。

## 测量命令

```bash
# 镜像大小
docker images docker-cc:latest --format '{{.Size}}'

# 镜像 build 时长（国内冷构建，--no-cache）
time docker compose build --no-cache

# 首次 cc up 冷启动（mihomo 首次拉订阅 + mihomo 启动）
time cc up "<your-subscription-url>"

# 热启动 cc -p（mihomo 已 running）
time cc -p "hi"

# cc-use 切换耗时（仅文件 IO）
time cc-use kimi
```

## 基线（v0.1.0 待填）

| 指标 | 期望 | 实测 | 备注 |
|---|---|---|---|
| 镜像大小 | < 1 GB | _待测_ | base + mihomo + yq + Claude Code npm |
| build 时长（国内冷构建） | < 5 min | _待测_ | M1 Pro / 100 Mbps 国内宽带 |
| build 时长（国外冷构建） | < 8 min | _待测_ | --no-cn-mirror |
| 首次 `cc up` | < 10 s | _待测_ | 首次拉订阅 + mihomo 启动 |
| 热启动 `cc -p "hi"` | < 3 s | _待测_ | mihomo 已 running，仅 cc 容器 + claude 调用 |
| `cc-use <name>` 切换 | < 100 ms | _待测_ | 纯 jq 读写 settings.json |
| metacubexd 面板首次加载 | < 1 s | _待测_ | 静态资源在容器内，本地访问 |

## 异常基线

记录任何不符合期望的情况：

- _空_

## 历史

| 版本 | 日期 | 平台 | build (m) | up (s) | -p (s) | 备注 |
|---|---|---|---|---|---|---|
| _v0.1.0_ | _待测_ | macOS Apple Silicon | - | - | - | 首次 |
