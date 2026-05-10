# 兼容性矩阵

> 每次 release 前手动跑一遍，更新状态。

## 跑全套验证的步骤（每个组合）

1. `docker --version` / `docker compose version` 满足最低
2. `bats tests/unit/`：全绿
3. `bats tests/integration/`：全绿
4. 手动一次 `dcc up <url> && dcc panel && dcc -p "hi"` 跑完整链路

## 平台 × Docker 实现 × Compose 版本

| 平台 | Docker | Compose | bats unit | bats integration | 手动跑通 | 备注 |
|---|---|---|---|---|---|---|
| macOS 14 (Apple Silicon) + Docker Desktop | 25.x | v2.30 | ⬜ | ⬜ | ⬜ | 主开发平台 |
| macOS 14 (Apple Silicon) + OrbStack | 25.x | v2.30 | ⬜ | ⬜ | ⬜ | 性能优 |
| macOS 14 (Apple Silicon) + Colima | 25.x | v2.30 | ⬜ | ⬜ | ⬜ | 开源备选 |
| Ubuntu 22.04 (x86_64) | 24.x | v2.20 | ⬜ | ⬜ | ⬜ | 主流 Linux |
| Ubuntu 22.04 (arm64) | 24.x | v2.20 | ⬜ | ⬜ | ⬜ | ARM 服务器 |
| Debian 12 (x86_64) | 24.x | v2.6 | ⬜ | ⬜ | ⬜ | 最低 compose 版本 |
| WSL2 Ubuntu | 24.x | v2.20 | ⬜ | ⬜ | ⬜ | Windows 用户 |

图例：✅ pass / ⚠ partial / ❌ fail / ⬜ 未测

## 已知不兼容

记录测试中发现的边界情况（v0.1.0 待跑）：

- _空_

## 历史

| 版本 | 日期 | 通过率 | 备注 |
|---|---|---|---|
| v0.1.0 | _待跑_ | _待填_ | 首次发布 |
