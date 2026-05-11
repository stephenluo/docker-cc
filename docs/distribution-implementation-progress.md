# 分发部署方案实施进度

> 跟踪 [distribution-plan.md](distribution-plan.md) §12 实施步骤的执行状态。每完成一步更新此文件。

## 状态图例

- ⬜ 待办
- 🔄 进行中
- ✅ 已完成
- 🚫 已阻塞（等外部输入）
- ⏭️ 已跳过（不适用）

## 负责人

- **U** = 用户（需账号 / 终端 / 物理机器 / commit 权限的步骤）
- **C** = Claude（写代码 / 改文档的步骤）

## 总览

| 步骤 | 标题 | 负责人 | 状态 | 产物 / 备注 |
|---|---|---|---|---|
| 1 | 阿里云 ACR 准备 | U | ⬜ | 拿到 registry / namespace / 用户名 / 固定密码 |
| 2 | GitHub Secrets 配置 | U | ⬜ | 4 个 secret：`ALIYUN_REGISTRY` / `ALIYUN_NAMESPACE` / `ALIYUN_USERNAME` / `ALIYUN_PASSWORD` |
| 3 | 写 release.yml | C | ✅ | `.github/workflows/release.yml` |
| 4 | workflow_dispatch dry-run | U | ✅ | run 25671132992 3:26 通过；GHCR + ACR 均有 `:dev` + `:dev-0.1.3`，同 digest `sha256:7b2aa376...`；multi-arch（amd64 + arm64）；无 `:latest` / 无 release / 无 tarball；本地 docker pull 两边都通 |
| 5 | 改 docker-compose.yml + install.sh + bin/dcc | C | ✅ | 三个文件变更（bash -n 语法 + compose config 通过） |
| 6 | 写 scripts/quick-install.sh | C | ✅ | 新文件 + 可执行权限 |
| 7 | 扩 bats 测试 | C | ✅ | 5 个文件 + symlink。本地用 `docker run ubuntu:24.04 bash -c '...; bats tests/unit/'` 26/26 全绿 ✓ |
| 8 | Matrix B + Matrix A mock 子集 | U | 🚫 | 等步骤 5-7 完成 + python 起 http server |
| 9 | 更新 README + CHANGELOG | C | ✅ | README.md / README.zh-CN.md / CHANGELOG.md（`[Unreleased]` 段记录本次改动） |
| 10 | 提交代码改动 + quick-install.sh 到 main | U | 🚫 | 等步骤 3, 5-7, 9 完成 |
| 11 | bump VERSION + tag v0.2.0 + push | U | 🚫 | 触发正式 release.yml |
| 12 | Matrix A 端到端验证 | U | 🚫 | release 发布后 |
| 13 | 观察 24h | U | 🚫 | 被动 |

## 详细进度

### 步骤 1：阿里云 ACR 准备
**负责人**：U
**状态**：⬜
**前置**：无

按 [distribution-plan.md §3.1](distribution-plan.md#L120) 完成。需手动操作：
- [ ] 阿里云容器镜像服务个人版开通
- [ ] 实例地域选择（推荐 `cn-hangzhou`）
- [ ] 命名空间创建（**类型选公开**）
- [ ] 固定密码设置
- [ ] 记下 4 项凭证

完成后请告知：`ALIYUN_REGISTRY=...` / `ALIYUN_NAMESPACE=...`（后两项请通过 GitHub Secrets 而非聊天传入）。

---

### 步骤 2：GitHub Secrets 配置
**负责人**：U
**状态**：⬜
**前置**：步骤 1

按 [distribution-plan.md §3.2](distribution-plan.md#L140) 配置。secrets 列表见同文档。

完成标志：仓库 Settings → Secrets 页可见 4 个 secret。

---

### 步骤 3：写 release.yml
**负责人**：C
**状态**：⬜
**前置**：无（可与步骤 1-2 并行）

按 [distribution-plan.md §4.1](distribution-plan.md#L163) 写入 `.github/workflows/release.yml`。

---

### 步骤 4：workflow_dispatch dry-run
**负责人**：U
**状态**：🚫
**前置**：步骤 1, 2, 3

操作：
- [ ] 把步骤 3 的 release.yml push 到 main
- [ ] GitHub → Actions → release → Run workflow → main 分支
- [ ] 等待 CI 完成（首次 15-25 min，arm64 仿真慢）

验收（[distribution-plan.md §9.3](distribution-plan.md)）：
- [ ] GHCR / ACR 都出现 `:dev` + `:dev-<VERSION>` 两个 tag（**不是** `:latest` / `:VERSION`）
- [ ] 各 tag 是 multi-arch（含 amd64 + arm64）
- [ ] 不创建 GitHub Release
- [ ] 不生成 tarball

---

### 步骤 5：改 docker-compose.yml + install.sh + bin/dcc
**负责人**：C
**状态**：⬜
**前置**：无

按 [distribution-plan.md §4.2 / §4.3 / §4.4](distribution-plan.md) 改动。

涉及文件：
- `docker-compose.yml`：image 字段变量化
- `install.sh`：参数解析（+`--registry` / `--build-local`）+ pull-first 流程 + 软链改向 `$REPO_DIR/bin/`
- `bin/dcc`：upgrade 子命令重写

**注意**：`install.sh` 里的 `GHCR_OWNER` / `ALIYUN_PREFIX` 默认值留占位（`<your-github-handle>` / `<your-namespace>`），步骤 11 之前由 U 替换为真实值。

---

### 步骤 6：写 scripts/quick-install.sh
**负责人**：C
**状态**：⬜
**前置**：无

按 [distribution-plan.md §4.8](distribution-plan.md) 写入 `scripts/quick-install.sh`（新目录）。

**注意**：DCC_REPO 默认值用占位，步骤 11 之前由 U 替换。

---

### 步骤 7：扩 bats 测试
**负责人**：C
**状态**：⬜
**前置**：步骤 5, 6

按 [distribution-plan.md §9.1](distribution-plan.md) 新增/修改 4 个 bats 文件：
- `tests/unit/install_registry.bats`（+）
- `tests/unit/install_symlink.bats`（+）
- `tests/unit/dcc_upgrade.bats`（~：扩 --build 用例）
- `tests/unit/quick_install.bats`（+）

---

### 步骤 8：跑 §9.2 Matrix B + Matrix A mock 子集
**负责人**：U
**状态**：🚫
**前置**：步骤 5-7

按 [distribution-plan.md §9.2](distribution-plan.md) 跑：
- [ ] Matrix B 全表（git clone 路径 4 行）
- [ ] Matrix A mock 子集：本地起 `python -m http.server`，DCC_GHPROXY 指向 localhost，验证 quick-install.sh 自身

---

### 步骤 9：更新 README + CHANGELOG
**负责人**：C
**状态**：⬜
**前置**：步骤 3, 5, 6 完成（避免反复改）

按 [distribution-plan.md §4.7](distribution-plan.md) 改写「5 分钟上手」段。

CHANGELOG 更新 `[Unreleased]` 段：
- 新增：双推 GHCR + ACR / 一键安装 / 软链改向
- 提示老用户：clone 目录可删

---

### 步骤 10：提交代码改动 + quick-install.sh 到 main
**负责人**：U
**状态**：🚫
**前置**：步骤 3, 5-7, 9

⚠ **顺序关键**：必须先于步骤 11——quick-install.sh 必须在 main 分支 raw 可访问，否则 curl|bash 入口 404。

```bash
git add .github/workflows/release.yml docker-compose.yml install.sh bin/dcc \
        scripts/quick-install.sh tests/unit/install_*.bats tests/unit/quick_install.bats \
        tests/unit/dcc_upgrade.bats README.md README.zh-CN.md CHANGELOG.md \
        docs/distribution-plan.md docs/distribution-implementation-progress.md
# 注意：按 user 记忆规则，commit 由 U 主动发起，且先 bump VERSION
```

---

### 步骤 11：bump VERSION + tag v0.2.0 + push
**负责人**：U
**状态**：🚫
**前置**：步骤 10

按 [distribution-plan.md §7.5](distribution-plan.md) 操作：
- [ ] `echo "0.2.0" > VERSION`
- [ ] 写 CHANGELOG 当次 release 段
- [ ] commit
- [ ] `git tag v0.2.0`
- [ ] `git push && git push --tags`
- [ ] 触发正式 release.yml

---

### 步骤 12：Matrix A 端到端验证
**负责人**：U
**状态**：🚫
**前置**：步骤 11 + CI 完成

按 [distribution-plan.md §9.2 Matrix A](distribution-plan.md) 跑，至少覆盖：
- [ ] macOS arm64：默认（ghfast + auto）
- [ ] macOS arm64：DCC_GHPROXY= + --registry=global
- [ ] Linux amd64：默认
- [ ] 边界：故意写错 DCC_GHPROXY、下载中 Ctrl-C

---

### 步骤 13：观察 24h
**负责人**：U
**状态**：🚫
**前置**：步骤 12 通过

被动观察用户反馈、fallback 触发频率。

---

## 变更日志（本进度文件自身）

| 时间 | 步骤 | 操作 |
|---|---|---|
| 2026-05-11 | 初始化 | 创建本文件，13 步全部 ⬜/🚫 |
| 2026-05-11 | 3 ✅ | 写入 `.github/workflows/release.yml`（multi-arch + dual-push + tarball + release，dry-run 隔离） |
| 2026-05-11 | 5 ✅ | `docker-compose.yml` image 变量化；`install.sh` 加 --registry / --build-local，pull-first，软链改向 `$REPO_DIR/bin/`；`bin/dcc upgrade` 默认 pull、支持 --build；`bash -n` 三个脚本均通过，`docker compose config` 通过 |
| 2026-05-11 | 6 ✅ | 新建 `scripts/quick-install.sh`（+x），含 latest 探测 / sha256 校验 / EXIT trap 清理；`bash -n` 通过 |
| 2026-05-11 | 7 ✅ | 新增 `install_registry.bats`（8 用例）、`install_symlink.bats`（3 用例）、`quick_install.bats`（8 用例）；扩 `dcc_upgrade.bats`（+4 用例）；新增 `tests/fixtures/fake-docker`（+x）。**注**：本机未装 bats，待 U 跑 `bats tests/unit/` 验证 |
| 2026-05-11 | 9 ✅ | README.md / README.zh-CN.md「5 分钟上手」重写；CHANGELOG.md `[Unreleased]` 段写入 Added / Changed / Fixed 三类 |
| 2026-05-11 | 占位替换 ✅ | install.sh / scripts/quick-install.sh / README × 2 全部替换为真实值（stephenluo + 个人版 ACR endpoint） |
| 2026-05-11 | distribution-plan.md 修订 | 标注个人版 endpoint 格式（与企业版区分），§3.1 / §3.2 / §7.1 加警告 |
| 2026-05-11 | 步骤 4 ✅ | dry-run（commit 244f36c → workflow_dispatch run 25671132992）3:26 通过；GHCR + ACR 双 push 验证一致（同 digest `sha256:7b2aa376...`）；multi-arch + dry-run 隔离全部正确 |
| 2026-05-11 | 步骤 7 验证 ✅ | macOS brew bats 1.12 对中文 test name 有 bug（升级后引入），改用 `docker run ubuntu:24.04` 跑 bats 1.10：26/26 全绿。修了一个 fake-docker 部署 bug（加 symlink `docker → fake-docker`） |

## C 已完成、U 待操作的衔接清单

按 §12 顺序，U 接下来要做的：

1. **步骤 1**（阿里云 ACR 准备）：注册 / 开通个人版 / 拿凭证
2. **步骤 2**（GitHub Secrets）：把 4 个 secret 写入仓库
3. **步骤 4**（dry-run）：先 push 步骤 5/6 的代码到 main，再手动 workflow_dispatch
4. **步骤 8**（Matrix B + Matrix A mock）：本地跑 `bats tests/unit/`；起 `python3 -m http.server` 验证 quick-install.sh
5. **步骤 10/11/12/13**：commit / tag / 端到端验证 / 观察

### ⚠ 关键替换点（✅ 已于 2026-05-11 完成）

代码占位已全部替换为真实值（U 提供）：

| 文件 | 字段 | 替换后值 |
|---|---|---|
| `install.sh:45` | `GHCR_OWNER` | `stephenluo` |
| `install.sh:46` | `ALIYUN_PREFIX` | `crpi-rskelsy8ldqvpz46.cn-shanghai.personal.cr.aliyuncs.com/stephenluo` |
| `scripts/quick-install.sh:19` | `DCC_REPO` | `stephenluo/docker-cc` |
| `README.md` / `README.zh-CN.md` | 多处 `<owner>` | `stephenluo` |

**Fork 用户怎么改成自己的**：所有上述值都可通过环境变量在 install.sh / quick-install.sh 调用时覆盖（`GHCR_OWNER=` / `ALIYUN_PREFIX=` / `DCC_REPO=`），无需改源码。

**ACR endpoint 注意**：你用的是 **个人版**，endpoint 是 `crpi-<id>.cn-<region>.personal.cr.aliyuncs.com`（独立实例 URL），不是企业版的 `registry.cn-<region>.aliyuncs.com`。已在 [distribution-plan.md §3.1 / §3.2 / §7.1](distribution-plan.md) 加注释。

### GitHub Secrets 配置参考（U 做步骤 2 时用）

| Secret 名 | 值 |
|---|---|
| `ALIYUN_REGISTRY` | `crpi-rskelsy8ldqvpz46.cn-shanghai.personal.cr.aliyuncs.com` |
| `ALIYUN_NAMESPACE` | `stephenluo` |
| `ALIYUN_USERNAME` | （阿里云 ACR 个人版「访问凭证」页显示的用户名）|
| `ALIYUN_PASSWORD` | （步骤 1 设置的固定密码）|

### ⚠ Sequencing 提醒

- **步骤 10 必须先于步骤 11**：scripts/quick-install.sh 需要 main 分支可访问，否则用户 curl|bash 404
- **Matrix A 端到端**只能在步骤 12（release 发出后）跑；步骤 8 期间用本地 mock 代替
