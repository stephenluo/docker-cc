# docker-cc 分发部署方案：双推 GHCR + 阿里云 ACR + 一键安装

> 目标：让用户在另一台机器上首装 docker-cc 时，**一行 `curl | bash` 命令完成**——跳过 git clone、跳过 350MB / 2-5 分钟的本地 build；国内、海外用户都得到原生速度。
>
> 三件事一起做：
> 1. **镜像分发**：CI 双推 GHCR + 阿里云 ACR，`install.sh` 默认走 pull。
> 2. **代码分发**：release 顺手发 tarball，新增 `scripts/quick-install.sh` 做 `curl | bash` 一键入口（国内走 ghproxy 镜像）。
> 3. **目录解耦**：`install.sh` 把所有运行依赖整理到 `~/.docker-cc/repo/`，软链改为指向那里，工作目录装完即可删。

---

## 1. 目标与范围

### 必须满足

**镜像分发**
- 每次发布 release tag（`v*`）后，CI 自动构建 multi-arch 镜像（amd64 + arm64）并同时推送到：
  - **GHCR**（海外主源，`ghcr.io/<owner>/docker-cc`）
  - **阿里云 ACR 个人版**（国内主源，`registry.cn-hangzhou.aliyuncs.com/<namespace>/docker-cc`）
- `install.sh` 默认走 pull 流程（自动选 registry），失败兜底到本地 build。
- `dcc upgrade` 改为 `docker compose pull` + recreate，不再本地 rebuild。
- 用户无感知 registry 选择；高级用户可手动指定（`--registry=cn|global`）。
- 镜像 tag 与 [VERSION](../VERSION) 文件单一来源对齐，升级语义清晰。

**代码分发与一键安装**
- 每次 release 上传 source tarball（`docker-cc-<version>.tgz`）到 GitHub Release 资产。
- 新增 `scripts/quick-install.sh`：用户一行 `curl | bash` 即可完成全部安装。
- 国内用户走 ghproxy（默认 `https://ghfast.top/`）拉 raw 脚本 + release tarball；海外用户走 GitHub 直链。
- 保留 git clone + `./install.sh` 路径作为备选（fork / hack 用户场景）。

**目录解耦**
- `/usr/local/bin/dcc` / `dcc-use` 软链指向 `~/.docker-cc/repo/bin/`（而非 clone 目录）。
- 用户在 `curl | bash` 完成后，工作目录里**任何痕迹都没有**（quick-install.sh 自动清理）。
- 用 git clone 路径安装的用户，clone 目录也可以删（兼容 fork 场景）。

### 不在范围
- **不**做镜像签名（cosign / docker scout） —— 增加用户验证负担，暂不必要。
- **不**推 Docker Hub —— 拉取限流问题大于收益，等真有用户卡 GHCR 再加。
- **不**改 docker daemon 的 `registry-mirrors`（路线 B）—— 把问题甩给用户，与项目"零配置"理念冲突。
- **不**做镜像同步类商业方案（如阿里云 ACR 企业版的镜像同步）—— 需付费。
- **不**改 [Dockerfile](../Dockerfile) 本身 —— 现有 `ARG TARGETARCH` 已支持 multi-arch，buildx 自动注入。
- **不**做 Homebrew tap —— Mac/Linux 双覆盖但 brew 自身对国内不友好，且 `curl | bash` 已经够简单。
- **不**做 Gitee 镜像 —— `curl | bash` 走 ghproxy 已经覆盖国内访问场景，再加 Gitee 是重复工。

---

## 2. 架构总览

```
┌────────────────────────────────────────────────────────────────────────────┐
│ 开发者侧                                                                    │
│                                                                             │
│   git tag v0.2.0 && git push --tags                                         │
│        │                                                                    │
│        ▼                                                                    │
│   ┌─────────────────────────────────────────────────────────────────────┐ │
│   │ GitHub Actions (.github/workflows/release.yml)                       │ │
│   │  ① 镜像 job (multi-arch buildx)                                       │ │
│   │     - docker login → GHCR / 阿里云 ACR                                │ │
│   │     - buildx --platform linux/amd64,linux/arm64 --push                │ │
│   │       tags: 双 registry × 2 tag（latest + vX.Y.Z）                     │ │
│   │  ② 源码 tarball job                                                   │ │
│   │     - git archive → docker-cc-X.Y.Z.tgz                              │ │
│   │     - softprops/action-gh-release 上传到 Release 资产                  │ │
│   └─────────────────────────────────────────────────────────────────────┘ │
│             │                          │                                    │
│             ▼                          ▼                                    │
│      镜像 → GHCR + ACR             tarball → GitHub Release                  │
└─────────────────────────────────────────────────────────────────────────────┘
                                              │
                                              ▼
┌────────────────────────────────────────────────────────────────────────────┐
│ 用户侧（一行命令）                                                          │
│                                                                             │
│   $ curl -fsSL https://ghfast.top/raw.githubusercontent.com/<owner>/        │
│            docker-cc/main/scripts/quick-install.sh | bash                   │
│                  │                                                          │
│                  ▼                                                          │
│   ┌──────────────────────────────────────────────────────────────────┐    │
│   │ scripts/quick-install.sh （仅 raw 几 KB）                          │    │
│   │  - 通过 GitHub API 探测 latest version（走 ghproxy）               │    │
│   │  - curl 拉 tarball → 解到 $TMP                                     │    │
│   │  - cd $TMP && exec ./install.sh "$@"                              │    │
│   └──────────────────────────────────────────────────────────────────┘    │
│                  │                                                          │
│                  ▼                                                          │
│   ┌──────────────────────────────────────────────────────────────────┐    │
│   │ install.sh                                                        │    │
│   │  - rsync 整个仓库 → ~/.docker-cc/repo/                             │    │
│   │  - auto 探测 registry（aliyun.com 通 → CN，否则 global）           │    │
│   │  - 写 .env: DCC_IMAGE=<前缀>/docker-cc:<version>                   │    │
│   │  - docker compose pull（成功）/ fallback build（失败）              │    │
│   │  - ln -s ~/.docker-cc/repo/bin/dcc → /usr/local/bin/dcc            │    │
│   │  - ln -s ~/.docker-cc/repo/bin/dcc-use → /usr/local/bin/dcc-use    │    │
│   └──────────────────────────────────────────────────────────────────┘    │
│                  │                                                          │
│                  ▼                                                          │
│   quick-install.sh 末尾：rm -rf $TMP（工作目录无任何残留）                   │
│                  │                                                          │
│                  ▼                                                          │
│           dcc up "<订阅URL>"  →  dcc-use edit anthropic  →  dcc             │
└────────────────────────────────────────────────────────────────────────────┘
```

**两条路径的关系**：
- `curl | bash` 是**默认主路径**（README 5min 上手用这个）。
- `git clone + ./install.sh` 是**fork / hack 子路径**（修代码、贡献 PR、内网定制）。两条路径下 install.sh 走完全相同的逻辑。

**核心五件事**：
1. CI 把同一个 buildx 产物同时推到两个 registry（GHCR + ACR）。
2. CI 同步发布 source tarball 到 GitHub Release 资产。
3. `scripts/quick-install.sh` 做 `curl | bash` 一键入口，国内走 ghproxy 镜像 raw.githubusercontent.com + release.github.com。
4. `install.sh` 在用户侧选 registry 写入 `.env`，由 `docker-compose.yml` 通过环境变量引用；软链指向 `~/.docker-cc/repo/bin/` 而非工作目录。
5. `dcc upgrade` 从 build 改 pull，并提供 `--build` 退回老语义。

---

## 3. 前置准备

### 3.1 阿里云容器镜像服务（ACR）个人版

阿里云 ACR 个人版**完全免费**，限 3 命名空间 / 300 仓库，对开源项目余量大。

**开通步骤**（一次性）：

1. 注册/登录 [阿里云](https://www.aliyun.com)。
2. 进入「容器镜像服务 ACR」控制台，选「个人实例」（不要选企业版）。
3. 「实例列表」→ 选地域（推荐 **华东 1 / 杭州** `cn-hangzhou`，国内 BGP 最稳）。
4. 「命名空间」→ 新建命名空间，**类型选公开**（不然用户 pull 要登录）。
   - 命名空间名称将出现在镜像地址里，例如 `<namespace>/docker-cc`。
   - 建议用 GitHub handle 同名，便于辨识。
5. 「访问凭证」→ 设置「固定密码」（这不是阿里云登录密码，是 registry 专用的）。
6. 记下三项信息：
   - **registry 域名**：**个人版 ≠ 企业版！**
     - 个人版（你这种）：`crpi-<实例ID>.cn-<region>.personal.cr.aliyuncs.com`，每个实例独立 endpoint，从「实例详情 → 访问凭证」抄
     - 企业版（付费）：`registry.cn-<region>.aliyuncs.com`，公共 endpoint
   - **用户名**：阿里云账号全名（形如 `username@xxxx.onaliyun.com` 或主账号名）
   - **固定密码**：刚才设置的那个

> ⚠ ACR 「个人版」也叫「云效 Artifact」入口下的免费版本，控制台路径偶尔被阿里改版。如找不到「命名空间」入口，搜「容器镜像服务 个人版」即可。
> ⚠ 个人版的 registry endpoint **不是** `registry.cn-<region>.aliyuncs.com`，而是带实例 ID 前缀的 `crpi-<id>.cn-<region>.personal.cr.aliyuncs.com`。docker pull / push 必须用这个独立 endpoint。

### 3.2 GitHub Secrets

在 GitHub 仓库 → Settings → Secrets and variables → Actions → New repository secret：

| Secret 名 | 值 | 用途 |
|---|---|---|
| `ALIYUN_REGISTRY` | 个人版：`crpi-<id>.cn-<region>.personal.cr.aliyuncs.com`；企业版：`registry.cn-<region>.aliyuncs.com` | 阿里云 ACR 域名（个人版 / 企业版格式不同！） |
| `ALIYUN_NAMESPACE` | `<your-namespace>` | 阿里云命名空间名 |
| `ALIYUN_USERNAME` | `<阿里云账号名>` | 登录用户名 |
| `ALIYUN_PASSWORD` | `<固定密码>` | 登录密码 |

`GHCR_TOKEN` 不用配置 —— Actions 内置的 `GITHUB_TOKEN` 默认对当前仓库的 GHCR 有 push 权限（需在 Settings → Actions → General → Workflow permissions 选「Read and write permissions」，或在 workflow 里显式声明 `permissions: packages: write`）。

### 3.3 GHCR 包可见性

首次 push 后，GHCR 包默认 private。需在 GitHub → 个人头像 → Your packages → `docker-cc` → Package settings → Change visibility → Public。否则用户 pull 要登录。

---

## 4. 变更清单

按文件列出所有改动。下面用 `+` 表示新增，`-` 表示删除，`~` 表示修改。

### 4.1 新增 `.github/workflows/release.yml`（+）

完整内容：

```yaml
name: release

on:
  push:
    tags:
      - 'v*'
  workflow_dispatch:        # 也允许手动触发，方便首次调试

permissions:
  contents: write           # softprops/action-gh-release 创建 release 需要
  packages: write           # 写 GHCR

jobs:
  build-and-push:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4

      - name: 读取 VERSION
        id: ver
        run: echo "version=$(cat VERSION)" >> "$GITHUB_OUTPUT"

      - name: 校验 tag 与 VERSION 一致
        if: startsWith(github.ref, 'refs/tags/v')
        run: |
          tag="${GITHUB_REF#refs/tags/v}"
          ver="${{ steps.ver.outputs.version }}"
          if [ "$tag" != "$ver" ]; then
            echo "::error::tag v$tag 与 VERSION ($ver) 不一致"
            exit 1
          fi

      - uses: docker/setup-qemu-action@v3
      - uses: docker/setup-buildx-action@v3

      - name: 登录 GHCR
        uses: docker/login-action@v3
        with:
          registry: ghcr.io
          username: ${{ github.actor }}
          password: ${{ secrets.GITHUB_TOKEN }}

      - name: 登录阿里云 ACR
        uses: docker/login-action@v3
        with:
          registry: ${{ secrets.ALIYUN_REGISTRY }}
          username: ${{ secrets.ALIYUN_USERNAME }}
          password: ${{ secrets.ALIYUN_PASSWORD }}

      # —— 生成 image tag：正式 release 用 :latest + :VERSION，dry-run 用 :dev + :dev-VERSION
      # 这样 workflow_dispatch 不会污染正式 tag
      - name: 计算 image tag
        id: imgtag
        run: |
          if [[ "${GITHUB_REF}" == refs/tags/v* ]]; then
            echo "tag_main=latest"                                          >> "$GITHUB_OUTPUT"
            echo "tag_ver=${{ steps.ver.outputs.version }}"                 >> "$GITHUB_OUTPUT"
          else
            echo "tag_main=dev"                                             >> "$GITHUB_OUTPUT"
            echo "tag_ver=dev-${{ steps.ver.outputs.version }}"             >> "$GITHUB_OUTPUT"
          fi

      - name: 构建并推送（multi-arch）
        uses: docker/build-push-action@v5
        with:
          context: .
          platforms: linux/amd64,linux/arm64
          push: true
          tags: |
            ghcr.io/${{ github.repository_owner }}/docker-cc:${{ steps.imgtag.outputs.tag_main }}
            ghcr.io/${{ github.repository_owner }}/docker-cc:${{ steps.imgtag.outputs.tag_ver }}
            ${{ secrets.ALIYUN_REGISTRY }}/${{ secrets.ALIYUN_NAMESPACE }}/docker-cc:${{ steps.imgtag.outputs.tag_main }}
            ${{ secrets.ALIYUN_REGISTRY }}/${{ secrets.ALIYUN_NAMESPACE }}/docker-cc:${{ steps.imgtag.outputs.tag_ver }}
          build-args: |
            APT_MIRROR=deb.debian.org
            GH_PROXY=
            NPM_REGISTRY=https://registry.npmjs.org
          # scope 显式固定，让 dry-run（main ref）与正式 release（tag ref）共享 buildx cache。
          # 默认 scope = git ref，dry-run 跑过后正式 release 仍冷启动，浪费 5-10 min arm64 仿真。
          cache-from: type=gha,scope=buildx-shared
          cache-to: type=gha,scope=buildx-shared,mode=max

      # —— 源码 tarball（供 quick-install.sh / 离线安装用）——
      - name: 打包 source tarball
        if: startsWith(github.ref, 'refs/tags/v')
        run: |
          VERSION="${{ steps.ver.outputs.version }}"
          # git archive 自动排除 .gitignore 项；--prefix 让解压后是 docker-cc-X.Y.Z/
          git archive --format=tar.gz \
            --prefix="docker-cc-${VERSION}/" \
            -o "docker-cc-${VERSION}.tgz" HEAD
          # 同时算 sha256 给用户校验
          sha256sum "docker-cc-${VERSION}.tgz" > "docker-cc-${VERSION}.tgz.sha256"

      # 抽取本次 release 的 CHANGELOG 段（避免把整个 CHANGELOG 当 release body）
      - name: 抽取本次 release 的 CHANGELOG 段
        if: startsWith(github.ref, 'refs/tags/v')
        run: |
          VERSION="${{ steps.ver.outputs.version }}"
          # 匹配 "## [0.2.0]" 或 "## 0.2.0" 开头，取到下一个 "## " 为止
          awk -v ver="$VERSION" '
            $0 ~ "^## \\[?" ver "\\]?" { flag=1; next }
            flag && /^## / { exit }
            flag { print }
          ' CHANGELOG.md > release-body.md
          # 如果抽不到（CHANGELOG 还没记录此版本），给个 fallback
          [ -s release-body.md ] || echo "See [CHANGELOG.md](CHANGELOG.md)." > release-body.md

      - name: 创建/更新 GitHub Release
        if: startsWith(github.ref, 'refs/tags/v')
        uses: softprops/action-gh-release@v2
        with:
          tag_name: ${{ github.ref_name }}
          name: docker-cc ${{ steps.ver.outputs.version }}
          body_path: release-body.md
          files: |
            docker-cc-${{ steps.ver.outputs.version }}.tgz
            docker-cc-${{ steps.ver.outputs.version }}.tgz.sha256
```

**说明**：
- `permissions.contents: write` 是 `softprops/action-gh-release` 创建 release 的必需权限（**易漏**：默认 read 时会 403）。
- `build-args` 关掉国内加速 —— CI 跑在 GitHub Actions，走清华源 / ghproxy 反而慢且不稳。
- `cache-from/to: type=gha,scope=buildx-shared` 用 GitHub Actions Cache 缓存 buildx 层。**显式固定 scope** 让 dry-run（main ref）和正式 release（tag ref）共用一份缓存，否则默认按 git ref 分 scope，dry-run 跑过后正式 release 仍要重新 build arm64（白白多耗 5-10 分钟仿真）。
- `校验 tag 与 VERSION 一致` 防止 push 错 tag 导致镜像 vs 仓库代码错位。
- **Dry-run 隔离**：workflow_dispatch（无 v* tag）触发时，镜像 tag 自动变成 `:dev` + `:dev-<VERSION>`，**不会污染** `:latest` 或 `:<VERSION>`。tarball 步骤和 release 步骤也都被 `if: startsWith(github.ref, 'refs/tags/v')` 跳过，dry-run 只验证 build + push 通路。
- `git archive` 而非 `tar` —— `.gitignore`（含 `.env`、`node_modules` 等）自动排除，不会泄漏开发机的 `.env`；且产物对每个 commit 字节级稳定，便于 sha256 校验。
- tarball 与镜像在**同一 job** 内顺序执行，保证版本一致（不会出现 image push 成功但 tarball 没传的偏态）。
- CHANGELOG 段抽取用 awk，匹配 `## [VERSION]` 或 `## VERSION` 两种 keep-a-changelog 风格；抽不到时 release body 留个 fallback 链接，避免空 body。
- `softprops/action-gh-release@v2` **幂等**：相同 tag 第二次跑会更新已有 release 的 body 和资产（而非报错），适合迭代式发版。若想强制覆盖 tag 上的资产，加 `with: { fail_on_unmatched_files: true, generate_release_notes: false }` 也可。

### 4.2 `docker-compose.yml`（~）

第 3、25 行的 `image:` 字段改成变量引用：

```yaml
services:
  mihomo:
    image: ${DCC_IMAGE:-docker-cc:latest}     # 默认本地 build 产物，install.sh 写入完整 registry 路径
    build:                                     # 保留 build 段：本地 build 兜底
      context: .
      args:
        APT_MIRROR: ${APT_MIRROR-mirrors.tuna.tsinghua.edu.cn}
        GH_PROXY: ${GH_PROXY-https://mirror.ghproxy.com/}
        NPM_REGISTRY: ${NPM_REGISTRY-https://registry.npmmirror.com}
    ...

  cc:
    image: ${DCC_IMAGE:-docker-cc:latest}     # 与 mihomo 服务复用同一个镜像
    ...
```

**变更说明**：
- `${DCC_IMAGE:-docker-cc:latest}` 让 `.env` 通过 `DCC_IMAGE=...` 覆盖。未设置时退回原有的 `docker-cc:latest`（本地 build 后的 image tag），保持向后兼容。
- `build:` 段不动，`docker compose build` 仍可用。

### 4.3 `install.sh`（~）

主要变更三处：
1. 参数解析加 `--registry` / `--build-local`；
2. `[4/7]` 步骤改为 pull-first（失败兜底 build）；
3. 软链改为指向 `~/.docker-cc/repo/bin/`（让工作目录可删，**B+C 方案核心改动**）。

**4.3.1 参数解析（约 11 行处）**

```bash
# —— 参数解析 ——
NO_CN_MIRROR=0
SKIP_BUILD=0
SKIP_LINK=0
BUILD_LOCAL=0                                  # 新增
REGISTRY="auto"                                # 新增：auto | cn | global | <自定义前缀>
PREFIX="/usr/local"
for arg in "$@"; do
  case "$arg" in
    --no-cn-mirror)  NO_CN_MIRROR=1 ;;
    --skip-build)    SKIP_BUILD=1 ;;
    --skip-link)     SKIP_LINK=1 ;;
    --build-local)   BUILD_LOCAL=1 ;;          # 新增：强制本地 build
    --registry=*)    REGISTRY="${arg#--registry=}" ;;   # 新增
    --prefix=*)      PREFIX="${arg#--prefix=}" ;;
    -h|--help) ... ;;
    *) echo "未知参数: $arg"; exit 1 ;;
  esac
done
```

`--help` 输出同步追加：

```
  --registry=auto|cn|global|<前缀>   选择镜像源
                                     auto: 探测 aliyun.com 通则 cn，否则 global
                                     cn:   阿里云 ACR
                                     global: GHCR
                                     <前缀>: 自定义，如 ghcr.io/myorg
  --build-local       跳过 pull，直接本地 build（兜底）
```

**4.3.2 替换原 `[4/7] 构建镜像` 段（约 99-106 行）**

```bash
# 5. 镜像获取：pull 优先，失败回退本地 build
echo "[4/7] 获取镜像"
if [ "$SKIP_BUILD" = "1" ]; then
  note "(--skip-build) 跳过"
elif [ "$BUILD_LOCAL" = "1" ]; then
  ( cd "$REPO_DIR" && docker compose build )
  ok "镜像 docker-cc:latest 已本地构建"
else
  # 选 registry
  GHCR_OWNER="${GHCR_OWNER:-<your-github-handle>}"        # ← 发布时改为真实 owner
  ALIYUN_PREFIX="${ALIYUN_PREFIX:-registry.cn-hangzhou.aliyuncs.com/<your-namespace>}"

  case "$REGISTRY" in
    auto)
      if curl -fsS --max-time 3 https://www.aliyun.com >/dev/null 2>&1; then
        DCC_IMAGE_PREFIX="$ALIYUN_PREFIX"
        ok "检测到国内网络，使用阿里云 ACR"
      else
        DCC_IMAGE_PREFIX="ghcr.io/$GHCR_OWNER"
        ok "使用 GHCR"
      fi ;;
    cn)     DCC_IMAGE_PREFIX="$ALIYUN_PREFIX" ;;
    global) DCC_IMAGE_PREFIX="ghcr.io/$GHCR_OWNER" ;;
    *)      DCC_IMAGE_PREFIX="$REGISTRY" ;;      # 自定义前缀
  esac

  DCC_TAG="$(cat "$REPO_DIR/VERSION")"
  DCC_IMAGE="$DCC_IMAGE_PREFIX/docker-cc:$DCC_TAG"

  # 把选中的 image 写入 .env，供 docker-compose.yml 读取
  {
    grep -v -E '^DCC_IMAGE=' "$REPO_DIR/.env" 2>/dev/null || true
    echo "DCC_IMAGE=$DCC_IMAGE"
  } > "$REPO_DIR/.env.tmp"
  mv "$REPO_DIR/.env.tmp" "$REPO_DIR/.env"
  chmod 600 "$REPO_DIR/.env"

  # pull
  if ( cd "$REPO_DIR" && docker compose pull ); then
    ok "已拉取镜像 $DCC_IMAGE"
  else
    note "pull 失败，回退到本地 build（走 GH_PROXY 探测）"
    # 把 DCC_IMAGE 改回本地 tag，避免 compose 后续操作还指向远端
    sed -i.bak 's|^DCC_IMAGE=.*|DCC_IMAGE=docker-cc:latest|' "$REPO_DIR/.env"
    rm -f "$REPO_DIR/.env.bak"
    ( cd "$REPO_DIR" && docker compose build ) \
      || fail "pull 失败且本地 build 也失败。检查网络或运行 dcc probe"
    ok "镜像 docker-cc:latest 已本地构建"
  fi
fi
```

**注意点**：
- `GHCR_OWNER` 和 `ALIYUN_PREFIX` 在 install.sh 里**硬编码默认值**（发布前替换为真实值），同时允许通过同名环境变量覆盖，方便 fork 用户。
- pull 失败时把 `.env` 里的 `DCC_IMAGE` 改回本地 tag，否则后续 `docker compose up` 还会去拉远端。

**4.3.3 软链指向改动（约 141-142 行）**

[install.sh:141-142](../install.sh#L141-L142) 原本是软链到 `$PROJECT_ROOT/bin/`（也就是用户执行 install.sh 时所在的 clone/tarball 解压目录），改为指向 `$REPO_DIR/bin/`：

```bash
# 改前
$LN -sf "$PROJECT_ROOT/bin/dcc"     "$PREFIX/bin/dcc"     || fail "软链 dcc 失败"
$LN -sf "$PROJECT_ROOT/bin/dcc-use" "$PREFIX/bin/dcc-use" || fail "软链 dcc-use 失败"

# 改后
$LN -sf "$REPO_DIR/bin/dcc"     "$PREFIX/bin/dcc"     || fail "软链 dcc 失败"
$LN -sf "$REPO_DIR/bin/dcc-use" "$PREFIX/bin/dcc-use" || fail "软链 dcc-use 失败"
```

**前置条件**：步骤 3（[install.sh:60-72](../install.sh#L60-L72) 的 rsync / cp）已经把 `bin/` 目录整体复制到 `$REPO_DIR/bin/`，所以 `$REPO_DIR/bin/dcc` 一定存在。

**收益**：
- 用户在工作目录跑完 install.sh 后，工作目录（含 git clone 或 tarball 解压出来的副本）可以**直接 `rm -rf`**，`dcc` / `dcc-use` 命令仍然可用。
- `curl | bash` 路径下，`scripts/quick-install.sh` 末尾 `rm -rf $TMP` 是安全的——不影响 `dcc` 运行。
- `dcc upgrade --build` 仍然能用（因为 Dockerfile / docker-compose.yml 也在 `$REPO_DIR/` 下）。
- 后续 `install.sh` 重跑时，rsync 会把工作目录的 bin/ 更新到 `$REPO_DIR/bin/`，软链自动跟着新版本走。

**不动旧行为的兼容**：之前已经用旧版 install.sh 装过的用户重跑新版 install.sh 时，`ln -sf` 会无差别覆盖旧软链，平滑升级；旧的 clone 目录此后即可删除。

### 4.4 `bin/dcc`（~）

[bin/dcc:81-101](../bin/dcc#L81-L101) 的 `upgrade` 分支重写：

```bash
upgrade)
        # 升级：从 registry pull 新版镜像并重建容器。
        # 不再本地 rebuild（除非加 --build）。
        shift
        FORCE_BUILD=0
        case "${1:-}" in
          --build) FORCE_BUILD=1; shift ;;
        esac
        case "${1:-claude}" in
          claude|all)
            if [ "$FORCE_BUILD" = "1" ]; then
              if ! docker compose build --no-cache --pull; then
                echo "build 失败。请运行: dcc probe（重新探测 GH_PROXY）"
                exit 1
              fi
            else
              if ! docker compose pull; then
                echo "pull 失败。常见原因："
                echo "  - registry 不可达（试 dcc upgrade --build 走本地构建）"
                echo "  - DCC_IMAGE 配置错（检查 ~/.docker-cc/repo/.env）"
                exit 1
              fi
            fi
            docker compose up -d --force-recreate mihomo
            docker compose run --rm cc claude --version
            echo "升级完成。配置和凭据未受影响（都在卷挂载目录）。" ;;
          mihomo)
            echo "升级 mihomo 内核：修改 Dockerfile 的 ARG MIHOMO_VERSION，然后 dcc upgrade claude --build" ;;
          *)
            echo "用法: dcc upgrade [--build] [claude|mihomo|all]"; exit 1 ;;
        esac ;;
```

**变更说明**：
- 默认 `dcc upgrade` → `docker compose pull` + recreate（快、不依赖国内构建链）。
- `dcc upgrade --build` 退回旧行为（本地 rebuild），用于：
  - 修了 Dockerfile / entrypoint.sh / bin/* 想验证未发布版本
  - 升级 mihomo 内核（改 Dockerfile 里的 `ARG MIHOMO_VERSION`）
  - registry 拉不动时的兜底

### 4.5 `.env.example`（~）

末尾追加：

```bash
# 可选：镜像地址。install.sh 会按 --registry 自动写入完整路径。
# 手动覆盖示例：
# DCC_IMAGE=ghcr.io/<owner>/docker-cc:0.2.0
# DCC_IMAGE=registry.cn-hangzhou.aliyuncs.com/<namespace>/docker-cc:0.2.0
# DCC_IMAGE=docker-cc:latest         # 本地 build 后的默认 tag
```

### 4.6 `uninstall.sh`（无变更）

清理逻辑不变，仍删 `~/.docker-cc/` 和 `/usr/local/bin/dcc{,-use}` 软链。镜像不主动删（用户可能在用），文末打印 `docker rmi` 提示。

### 4.7 `README.md` / `README.zh-CN.md`（~）

「5 分钟上手」段重写为「一键安装 + 高级安装」两个子段：

````markdown
## 5 分钟上手

### 一键安装（推荐）

```bash
# 国内（默认走 ghfast 镜像 + 阿里云 ACR）
curl -fsSL https://ghfast.top/raw.githubusercontent.com/<owner>/docker-cc/main/scripts/quick-install.sh | bash

# 海外（直链 GitHub + GHCR）
curl -fsSL https://raw.githubusercontent.com/<owner>/docker-cc/main/scripts/quick-install.sh \
  | DCC_GHPROXY= bash -s -- --registry=global

# 指定版本
curl -fsSL .../quick-install.sh | DCC_VERSION=0.2.0 bash
```

完成后：

```bash
dcc up "https://your-airport.com/subscription"
dcc-use edit anthropic
dcc                                 # 在任意项目目录用，等同 claude
```

### 安全敏感：先下载再 bash（不走管道）

`curl | bash` 是业界惯例，但管道执行存在"看不到脚本内容就执行"的顾虑。若你想审计后再跑：

```bash
# 1. 下载脚本到本地
curl -fsSL https://ghfast.top/raw.githubusercontent.com/<owner>/docker-cc/main/scripts/quick-install.sh -o quick-install.sh

# 2. 审计（脚本仅 ~50 行）
less quick-install.sh

# 3. 跑
bash quick-install.sh
# 或加参数
bash quick-install.sh --registry=global
```

quick-install.sh 自身也会下载 tarball 并校验 sha256（如果 release 资产含 .sha256），等同二次校验。

### 高级安装（git clone）

适用于：fork 项目、修代码、内网定制、想完整审计整套脚本。

```bash
git clone https://github.com/<owner>/docker-cc.git docker-cc && cd docker-cc
./install.sh                        # 选项同 quick-install.sh
```

### 安装选项

| 选项 | 作用 |
|---|---|
| `--registry=auto`（默认） | 探测国内/海外网络选 ACR 或 GHCR |
| `--registry=cn` | 强制阿里云 ACR |
| `--registry=global` | 强制 GHCR |
| `--registry=ghcr.io/myorg` | 自定义 registry 前缀（fork / 企业内网） |
| `--build-local` | 跳过 pull，本地构建（脱机 / 改了 Dockerfile） |
| `--no-cn-mirror` | 关闭国内 apt / npm / GH 加速（fallback build 时生效） |
````

「故障排查」段加一条「镜像拉不动怎么办」+「`curl | bash` 失败怎么办」：参考 §10。

### 4.8 新增 `scripts/quick-install.sh`（+）

完整内容：

```bash
#!/usr/bin/env bash
# docker-cc 一键安装入口。
# 用法：
#   curl -fsSL https://ghfast.top/raw.githubusercontent.com/<owner>/docker-cc/main/scripts/quick-install.sh | bash
# 环境变量：
#   DCC_VERSION    指定版本（默认 latest）
#   DCC_GHPROXY    GitHub 加速前缀（默认 https://ghfast.top/；置空走直链）
#   DCC_REPO       仓库 owner/name（默认 <owner>/docker-cc，便于 fork）
# 透传给 install.sh：剩余位置参数（如 --registry=global、--build-local 等）

set -euo pipefail

DCC_VERSION="${DCC_VERSION:-latest}"
DCC_GHPROXY="${DCC_GHPROXY-https://ghfast.top/}"     # 注意：置空字符串走直链
DCC_REPO="${DCC_REPO:-<owner>/docker-cc}"

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
trap 'rm -rf "$TMP"' EXIT          # 退出/出错时清理临时目录

TARBALL_URL="${DCC_GHPROXY}https://github.com/${DCC_REPO}/releases/download/v${DCC_VERSION}/docker-cc-${DCC_VERSION}.tgz"
info "下载 tarball: $TARBALL_URL"
curl -fsSL --max-time 120 "$TARBALL_URL" -o "$TMP/docker-cc.tgz" \
  || fail "tarball 下载失败。试试换 DCC_GHPROXY（如 https://gh-proxy.com/）或置空走直链"

# 校验 sha256（如果资产包含 .sha256 文件）
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
tar xz -C "$TMP" -f "$TMP/docker-cc.tgz"
SRC_DIR="$TMP/docker-cc-${DCC_VERSION}"
[ -d "$SRC_DIR" ] || fail "解压结果异常：$SRC_DIR 不存在"
ok "已解压到 $SRC_DIR"

# —— 5. 跑 install.sh（透传所有位置参数）——
info "运行 install.sh $*"
cd "$SRC_DIR"
./install.sh "$@"

# —— 6. EXIT trap 自动清理 $TMP ——
info "完成。工作目录无残留。"
```

**设计说明**：

| 决策 | 理由 |
|---|---|
| 不依赖 jq | quick-install 是 zero-dep 入口；grep + sed 抓 `tag_name` 够用 |
| `DCC_GHPROXY` 默认 `https://ghfast.top/` | ghfast 是 ghproxy 当前最稳的实现；置空（`DCC_GHPROXY=`）走直链给海外用户 |
| `trap 'rm -rf "$TMP"' EXIT` | 正常退出 / Ctrl-C / 出错都自动清理 |
| 校验 sha256 但容忍缺失 | 提高安全性，但 release.yml 还没传 `.sha256` 时不强卡 |
| `set -euo pipefail` | 与 install.sh 一致；管道里 curl 失败立即终止 |
| 透传 `"$@"` | 用户可以 `bash -s -- --registry=global` 之类透传任意 install.sh 参数 |
| 文件托管在 `main` 分支 raw（不是 release 资产） | 用户拿到的总是最新版 quick-install.sh；版本固定在 `DCC_VERSION` 上 |

**部署位置**：仓库 `scripts/quick-install.sh`（新增目录），main 分支 raw URL 即对外入口。

**用户能否 fork 后改用自己的 quick-install.sh？** 可以：

```bash
DCC_REPO=myfork/docker-cc curl -fsSL \
  https://ghfast.top/raw.githubusercontent.com/myfork/docker-cc/main/scripts/quick-install.sh | bash
```

需配套：fork 仓库的 release 流程 / 镜像 registry 设置都准备好（见 §3 / §7）。

---

## 5. Registry 选择策略

### 5.1 默认 auto 探测逻辑

```
curl -fsS --max-time 3 https://www.aliyun.com >/dev/null
  ├─ 成功 → CN（阿里云 ACR）
  └─ 失败/超时 → global（GHCR）
```

**为什么用 `aliyun.com` 而不是 `google.com`？**
- 国内网络拨 `aliyun.com` 必通；拨 `google.com` 必不通 → 用通的那个做正信号，比用不通的那个做反信号更可靠。
- 国外网络拨 `aliyun.com` 也通（阿里有海外节点），但稍慢，3s 超时大多数情况下能区分。

**为什么不用 `ip-api.com` 之类地理位置 API？**
- 多一个依赖，且 GFW 抽风时 ip-api 可能也不通。
- 用「能不能拉镜像」做信号更直接，但 docker pull HEAD 请求成本太高，不适合做探测。

### 5.2 手动覆盖优先级

`install.sh --registry=<value>` > 环境变量 `GHCR_OWNER` / `ALIYUN_PREFIX` > 默认硬编码。

后续可通过 `dcc-use registry <value>` 之类的命令再切（本期不做，留到 §11）。

---

## 6. 版本与 Tag 策略

### 6.1 三层 tag

每次 release 推送 4 个 tag（每个 registry 各 2 个）：

```
<prefix>/docker-cc:latest        # 始终指向最新 stable release
<prefix>/docker-cc:0.2.0         # 精确版本（与 git tag v0.2.0 / VERSION 对齐）
```

**不推 `0.2` / `0` 这种浮动 tag** —— 维护成本大于收益，用户想固定中位版本可以自己写 `.env`。

### 6.2 VERSION 文件单一来源

- 开发者改 [VERSION](../VERSION) → bump → `git tag v$(cat VERSION)` → push tag → CI 跑。
- CI 通过 `校验 tag 与 VERSION 一致` 防止错位。
- 用户侧 install.sh `DCC_TAG="$(cat $REPO_DIR/VERSION)"`，VERSION 文件就是真理。
- `dcc upgrade` 时若需要切到特定版本：
  ```bash
  echo "0.1.9" > ~/.docker-cc/repo/VERSION
  dcc upgrade
  ```

### 6.3 `latest` 的语义

`latest` = 最近一次发布的 release tag（不含 prerelease / draft）。本期不做 prerelease 区分，所有 push v* 都更新 latest。后续要做 beta 通道再加 `--prerelease` 判断。

### 6.4 `:dev` tag（仅 dry-run）

workflow_dispatch（手动触发）时镜像 tag 自动变成 `:dev` + `:dev-<VERSION>`，**永远不会污染 `:latest` 或 `:<VERSION>`**。CI 通路验证完后，可在 ACR / GHCR 控制台手动删除累积的 `:dev*` tag。用户侧 install.sh 默认 pin 到 `:<VERSION>`，不会拉到 `:dev`。

---

## 7. 首次发布流程

按以下顺序操作。前置：§3 已完成。

### 7.1 改 install.sh 默认值

```bash
# install.sh 内（示例：个人版 endpoint）
GHCR_OWNER="${GHCR_OWNER:-stephenluo}"
ALIYUN_PREFIX="${ALIYUN_PREFIX:-crpi-<your-instance-id>.cn-<region>.personal.cr.aliyuncs.com/stephenluo}"
```

⚠ **个人版用户**：endpoint 必须从「访问凭证」页拷贝完整的 `crpi-xxx.cn-xxx.personal.cr.aliyuncs.com`，不能用 `registry.cn-<region>.aliyuncs.com`（那是企业版地址，个人版用了 push 会失败）。

### 7.2 dry-run（workflow_dispatch）

不打 tag，先手动触发一次 release.yml 验证 CI 通路：

```bash
# 提交 .github/workflows/release.yml 等改动到 main
git push

# GitHub → Actions → release → Run workflow → 选 main 分支
```

预期：CI 跑 15-25 分钟（首次没缓存，arm64 仿真慢），结束后 GHCR + 阿里云 ACR 都能看到 image。

⚠ **Dry-run 产物（与正式 release 隔离）**：

| 步骤 | 正式 release（push v* tag） | dry-run（workflow_dispatch） |
|---|---|---|
| `校验 tag 与 VERSION 一致` | 跑 | **跳过** |
| 镜像 tag | `:latest` + `:<VERSION>` | `:dev` + `:dev-<VERSION>` |
| 源码 tarball | 生成并附加到 release | **跳过** |
| GitHub Release 创建 | 创建（含 CHANGELOG 抽取段） | **跳过** |

所以 dry-run 跑完看到的是 `:dev` 和 `:dev-<VERSION>` 两个 tag。**不会污染 `:latest` 或 `:<VERSION>`**，因此可以随便重跑。正式发版前在 ACR / GHCR 控制台手动删 `:dev*` tag 也行。

### 7.3 把 GHCR 包改成 public

GitHub → 个人头像 → Packages → docker-cc → Package settings → Change visibility → Public。

### 7.4 用另一台机器验证

```bash
# A. 一键安装路径（用户主路径）
#    使用 main 分支 raw 上的 quick-install.sh（即使 release 未含 quick-install.sh 也能跑）
curl -fsSL https://ghfast.top/raw.githubusercontent.com/<owner>/docker-cc/main/scripts/quick-install.sh \
  | DCC_VERSION=0.2.0 bash
dcc up "<订阅 URL>"
dcc-use edit anthropic
dcc -p "hello"
# 验证：解压临时目录已自动清理
ls -la /tmp/tmp.*    # 应找不到与 quick-install 相关的残留

# B. git clone 路径（备选 / 开发者）
git clone <repo> docker-cc && cd docker-cc
./install.sh
cd .. && rm -rf docker-cc          # 关键验证点：删了 clone 目录后 dcc 仍能用
dcc -p "hello"
```

各 registry 选项各跑一次：
- 国内：默认 `auto`（应选 cn），再显式 `--registry=cn`、`--registry=global`
- 海外：默认 `auto`（应选 global），再显式 `--registry=cn`、`--registry=global`

**容易漏的验证点**：
- `rm -rf docker-cc` 之后 `which dcc` 还是软链到 `~/.docker-cc/repo/bin/dcc` 且 `dcc -v` 正常输出。
- `curl | bash` 中途 Ctrl-C 后没有残留临时目录（`trap EXIT` 验证）。
- pull 失败时 fallback 到 build：手动模拟（断开 ACR 网络，或 `--registry=ghcr.io/nonexistent`）。

### 7.5 正式发版

```bash
# 1. bump VERSION
echo "0.2.0" > VERSION

# 2. 写 CHANGELOG
$EDITOR CHANGELOG.md

# 3. commit
git commit -am "v0.2.0: 镜像双推（GHCR + 阿里云 ACR）"

# 4. tag + push
git tag v0.2.0
git push && git push --tags

# 5. CI 自动跑 release.yml
```

---

## 8. 用户侧使用变化

### 8.1 首次安装（最大变化：从多步变一行）

**旧（v0.1.x）：**

```bash
# 用户要懂 git，要能访问 github.com，clone 目录还得长期保留
git clone https://github.com/<owner>/docker-cc.git docker-cc
cd docker-cc
./install.sh
# [4/7] 构建镜像  → docker compose build （2-5 分钟，含 GH_PROXY 探测）
```

**新（B+C 后）：**

```bash
# 国内一行（默认 ghfast + 阿里云 ACR）
curl -fsSL https://ghfast.top/raw.githubusercontent.com/<owner>/docker-cc/main/scripts/quick-install.sh | bash
# 全过程：探测 latest → 拉 ~300KB tarball → 解压 → install.sh → docker pull ~350MB
# 总耗时：1-3 分钟（视带宽）
# 工作目录：装完干净，无任何残留
```

`install.sh` 内部输出对比：

```diff
- [4/7] 构建镜像
- → docker compose build （2-5 分钟）
+ [4/7] 获取镜像
+ → 检测到国内网络，使用阿里云 ACR
+ → docker compose pull docker-cc-cn:0.2.0 （20s-2min）

- [6/7] 安装 dcc / dcc-use 命令
- → ln -sf /path/to/clone/bin/dcc /usr/local/bin/dcc
+ [6/7] 安装 dcc / dcc-use 命令
+ → ln -sf ~/.docker-cc/repo/bin/dcc /usr/local/bin/dcc
```

### 8.2 升级

```diff
$ dcc upgrade
- → docker compose build --no-cache --pull
- → 2-5 分钟
+ → docker compose pull
+ → 20s-2min
+ → docker compose up -d --force-recreate mihomo
```

修过 Dockerfile / 想 build 本地版本时：
```bash
dcc upgrade --build              # 等同 v0.1.x 的 dcc upgrade
```

**升级到新版本号**：

```bash
# 方法 A：重跑 quick-install（推荐，自动拿 latest）
curl -fsSL https://ghfast.top/.../quick-install.sh | bash

# 方法 B：手动改 VERSION 后 upgrade（脚本化版本，不依赖具体版本号）
NEW_VER="0.2.1"
echo "$NEW_VER" > ~/.docker-cc/repo/VERSION
# 把 .env 里 DCC_IMAGE 的 tag 部分（最后一个 :之后的内容）替换为 NEW_VER
sed -i.bak -E "s|(/docker-cc:)[^\"[:space:]]+|\\1${NEW_VER}|" ~/.docker-cc/repo/.env
rm -f ~/.docker-cc/repo/.env.bak
dcc upgrade
```

后续可加 `dcc upgrade --to <version>` 命令直接简化方法 B，本期不做（§13）。

### 8.3 离线 / 内网环境

```bash
# 走 git clone + 强制本地 build
git clone https://github.com/<owner>/docker-cc.git docker-cc && cd docker-cc
./install.sh --build-local

# 或 curl|bash 路径透传 --build-local
curl -fsSL .../quick-install.sh | bash -s -- --build-local
```

### 8.4 自定义 registry / fork

```bash
# fork 用户用自己的 GHCR
./install.sh --registry=ghcr.io/myfork

# 企业内网 registry
./install.sh --registry=my.private.registry/team

# fork 用户用自己的 quick-install.sh
DCC_REPO=myfork/docker-cc curl -fsSL \
  https://ghfast.top/raw.githubusercontent.com/myfork/docker-cc/main/scripts/quick-install.sh | bash
```

### 8.5 卸载 / 清理工作目录

新的目录解耦语义下，用户不再需要保留任何工作目录：

```bash
# 一键安装路径：完全无残留（quick-install.sh 自动清理 /tmp/tmp.*）
# 不需要任何额外清理

# git clone 路径：装完即可删 clone 目录
rm -rf ~/your-clones/docker-cc       # dcc 命令仍可用

# 卸载（不变，但提醒用户：原 clone 目录无需还原即可重装）
~/.docker-cc/repo/uninstall.sh       # 软链通过 ~/.docker-cc/repo/ 找到 uninstall.sh
~/.docker-cc/repo/uninstall.sh --purge   # 并删 ~/.docker-cc/
```

### 8.6 安装路径决策树

```
我是谁？
├─ 普通用户（只想用 docker-cc）
│   └─ curl | bash 一键安装
│       └─ 国内：默认（ghfast + ACR）
│       └─ 海外：DCC_GHPROXY= ... --registry=global
├─ Fork / 修代码 / 贡献 PR
│   └─ git clone + ./install.sh
└─ 内网 / 离线 / 自改 Dockerfile
    └─ git clone + ./install.sh --build-local
```

---

## 9. 测试方案

### 9.1 CI（release.yml）单元测试

不增加单独 job，依赖既有 [.github/workflows/test.yml](../.github/workflows/test.yml) 的 bats 套件。但需要扩展 bats 单元覆盖：

| 文件 | 新增用例 |
|---|---|
| `tests/unit/install_registry.bats`（+） | `install.sh --registry=auto/cn/global/自定义` 写入 `.env` 的 `DCC_IMAGE` 正确 |
| `tests/unit/install_registry.bats` | `--build-local` 跳过 pull，强制 build |
| `tests/unit/install_symlink.bats`（+） | install.sh 后 `/usr/local/bin/dcc` 软链应指向 `$REPO_DIR/bin/dcc` 而非 `$PROJECT_ROOT/bin/dcc` |
| `tests/unit/install_symlink.bats` | 删除 `$PROJECT_ROOT` 后 `dcc --version` 仍能跑 |
| `tests/unit/dcc_upgrade.bats`（~） | `dcc upgrade` 默认走 pull；`dcc upgrade --build` 走 build |
| `tests/unit/quick_install.bats`（+） | 用 mock HTTP 服务模拟 GitHub API + release：tarball 下载 → 解压 → 调用 mock install.sh，验证位置参数透传与 `$TMP` 自动清理 |
| `tests/unit/quick_install.bats` | `DCC_GHPROXY=` 走直链 vs 默认走 ghfast，URL 拼接正确 |
| `tests/unit/quick_install.bats` | sha256 校验：缺失 → 容忍；mismatch → 退出 |

### 9.2 集成测试（手动 + matrix）

参照 [docs/testing.md](testing.md) 的 compat matrix 风格，加两张表。

**Matrix A：`curl | bash` 主路径**

| 平台 | DCC_GHPROXY | --registry | 网络 | 预期 |
|---|---|---|---|---|
| macOS arm64 | 默认（ghfast.top） | auto | CN | 走 ghfast 拉 tarball 1-3s，选 cn pull，无残留 |
| macOS arm64 | 置空 | global | 海外 VPN | 直链 raw.github 拉 tarball，pull GHCR arm64 |
| Linux amd64 | 默认 | auto | CN | 走 ghfast，选 cn pull |
| Linux amd64 | 默认 | global | CN | 走 ghfast 拉 tarball OK，但 docker pull GHCR 失败 → 回退本地 build |
| macOS arm64 | 故意写错 url | auto | CN | tarball 下载失败，给出明确报错（不卡死） |
| macOS arm64 | 默认 | auto | CN，下载中 Ctrl-C | `$TMP` 已清理（验 `ls /tmp/tmp.*`） |

**Matrix B：git clone 路径**

| 平台 | 选项 | 网络 | 预期 |
|---|---|---|---|
| macOS arm64 | 默认（auto） | CN | clone 完跑 `./install.sh`，选 cn pull 20-40s，装完正常用 |
| Linux amd64 | --build-local | CN/海外 | 跳过 pull，本地 build（走 GH_PROXY 探测） |
| macOS arm64 | `--registry=cn`，断网阿里云 | CN | pull 失败 → 回退本地 build → 成功 |
| 任一平台 | 装完后 `rm -rf <clone>` | 任一 | `which dcc` 指向 `~/.docker-cc/repo/bin/dcc`；`dcc -v` 正常 |

### 9.3 release.yml dry-run 检查清单

首次跑 workflow_dispatch 后人工 verify：

- [ ] GHCR 出现 `docker-cc:latest` 和 `docker-cc:<VERSION>`
- [ ] 阿里云 ACR 同样出现两个 tag
- [ ] 每个 tag 都是 multi-arch（`docker buildx imagetools inspect` 看 manifest list 含 amd64 + arm64）
- [ ] 镜像 size 与本地 build 相近（350MB ± 20MB，差太多说明哪一层没复用）
- [ ] `docker pull <tag> && docker run --rm <tag> claude --version` 在 amd64 与 arm64 都通
- [ ] **（tarball job）** GitHub Release 页面有 `docker-cc-<VERSION>.tgz` 和 `.tgz.sha256` 两个资产
- [ ] **（tarball job）** 下载 tarball 解压后包含 `install.sh`、`Dockerfile`、`bin/`、`scripts/`、不含 `.env` 等 `.gitignore` 内容
- [ ] **（dry-run 隔离）** workflow_dispatch 触发时：镜像 tag 为 `:dev` + `:dev-<VERSION>`（**不是** `:latest` / `:<VERSION>`），不创建 GitHub Release，不生成 tarball

---

## 10. 回退与故障处理

### 10.1 用户侧：pull 不动

**症状**：`./install.sh` 在 `[4/7] 获取镜像` 卡很久或报错。

**自动行为**：install.sh 内置 fallback，pull 失败时自动回退本地 build。用户通常无需介入。

**手动处理**：
```bash
./install.sh --build-local                    # 强制本地 build
# 或换 registry
./install.sh --registry=global                # 国内但阿里云抽风时试 GHCR
```

### 10.1b 用户侧：`curl | bash` 拉不动 tarball

**症状**：`quick-install.sh` 在「下载 tarball」步报 `curl: (xx)` 或卡住。

**原因 1**：ghfast.top（默认 ghproxy）抽风。换一个：

```bash
DCC_GHPROXY=https://gh-proxy.com/ curl -fsSL .../quick-install.sh | bash
DCC_GHPROXY=https://ghps.cc/      curl -fsSL .../quick-install.sh | bash
DCC_GHPROXY=                       curl -fsSL .../quick-install.sh | bash    # 直链
```

**原因 2**：raw.githubusercontent.com 也被代理挂了（quick-install.sh 自身都拉不到）。退到 git clone：

```bash
# 用任意可访问 GitHub 的方式（VPN / Gitee 镜像 / 内部镜像源）拿到代码
git clone https://github.com/<owner>/docker-cc.git docker-cc && cd docker-cc
./install.sh
```

**原因 3**：sha256 校验失败。可能 release 资产被替换或下载中断：

```bash
# 大概率是网络中断造成的不完整下载，重跑一次就好
curl -fsSL .../quick-install.sh | bash

# 如确认 release 没被篡改且仍想跳过校验（不推荐），手动下载 + 跳过 sha256:
curl -fsSL https://github.com/<owner>/docker-cc/releases/download/v0.2.0/docker-cc-0.2.0.tgz \
  -o /tmp/docker-cc.tgz
mkdir -p /tmp/dcc-src && tar xz -C /tmp/dcc-src -f /tmp/docker-cc.tgz --strip-components=1
cd /tmp/dcc-src && ./install.sh
```

> 校验失败但 sha256 文件本身可访问时，**默认不跳过**——可能意味着真的有人替换了资产。先核对 GitHub Release 页面上显示的 sha256 与 `expected` 报错值是否一致，再决定是否信任。

### 10.2 用户侧：pull 成功但 image 跑不起来

**症状**：`docker compose up` 报 `exec format error` 或 `no matching manifest`。

**原因**：multi-arch manifest 缺当前架构（多见于自建 amd64 only 镜像）。

**处理**：
```bash
docker manifest inspect $DCC_IMAGE | grep architecture        # 看支持哪些
# 缺架构时回退本地 build
./install.sh --build-local
```

### 10.3 开发者侧：CI release 失败

| 错误 | 原因 | 处理 |
|---|---|---|
| `tag v0.2.0 与 VERSION (0.1.9) 不一致` | git tag 和 VERSION 文件不同步 | 改 VERSION 或重打 tag |
| `denied: permission_denied` (GHCR) | Workflow permissions 没给 packages: write | Repo Settings → Actions → General → Workflow permissions |
| `unauthorized` (阿里云) | ACR 固定密码错或过期 | 阿里云控制台 → 访问凭证 → 重置 → 更新 GH Secret |
| arm64 仿真超时（> 6h） | npm install claude-code 仿真 + 缓存未命中 | 重跑（GHA cache 第二次会快很多） |

### 10.4 紧急回退到全本地 build

如果 registry 大面积故障，临时回退到 v0.1.x 的全本地 build 行为：

```bash
# 用户侧
DCC_IMAGE=docker-cc:latest dcc upgrade --build

# install.sh 默认改回本地 build（临时分支）
sed -i.bak 's/BUILD_LOCAL=0/BUILD_LOCAL=1/' install.sh
```

---

## 11. 风险与权衡

### 11.1 风险点

| 风险 | 等级 | 缓解 |
|---|---|---|
| 阿里云 ACR 政策变动（个人版收费 / 限流） | 中 | 双推保证 GHCR 兜底；用户能自助 `--build-local` |
| GHCR 国内访问彻底不可达 | 低 | install.sh auto 探测优先 CN；个别用户用代理走 GHCR |
| Multi-arch buildx CI 时长（arm64 仿真） | 中 | cache-from/to gha 缓存；只在 `push v*` tag 与 `workflow_dispatch` 时触发，普通 feature/main push 不触发 |
| `latest` tag 漂移引起用户跑到非预期版本 | 低 | `.env` 默认 pin `DCC_IMAGE=<prefix>/docker-cc:<VERSION>`，不用 latest |
| 镜像里 npm `claude-code` 升级与镜像 release 节奏脱钩 | 中 | 后续考虑加 weekly release.yml 自动 rebuild 拉最新 claude-code |
| ghfast.top / ghproxy 镜像服务不稳 | 中 | quick-install.sh 提供 `DCC_GHPROXY` 覆盖；故障文档列 3 个备选源；最终退到 git clone |
| `curl \| bash` 安全顾虑（脚本被中间人篡改） | 低 | quick-install.sh 短小可审计；tarball 自带 sha256 校验；README 提供"先下载脚本再 bash 跑"的替代姿势 |
| Release tarball 与镜像版本错位 | 低 | 同一 CI job 内顺序执行；tag/VERSION 一致性校验前置 |
| 软链改向 `~/.docker-cc/repo/bin/` 后老用户重装的兼容性 | 低 | `ln -sf` 会无差别覆盖旧软链；记得在 CHANGELOG 提醒可以安全删 clone 目录 |

### 11.2 取舍记录

- **不做镜像签名**：cosign 对用户增加 `cosign verify` 步骤，目前用户群体不大，收益不抵成本。
- **不做 Docker Hub**：Hub 拉取限流 + 国内访问没比 GHCR 强多少，等明确用户诉求再加。
- **不做"国内 daemon mirror"路线**：要求用户改 `/etc/docker/daemon.json`，破坏"零配置"原则。
- **不做 ACR 镜像同步**：要钱，且增加阿里云企业版依赖。
- **不做 Gitee 镜像**：`curl | bash` 走 ghproxy 已经覆盖国内场景；Gitee 同步 + 用户路径切换是重复劳动。
- **不做 Homebrew tap**：Mac/Linux 双覆盖但 brew 自身对国内不友好，且 `curl | bash` 已经够简单。
- **`curl | bash` vs `先下载再 bash` 默认推前者**：业界惯例，习惯成本最低；安全敏感用户走 README 列的替代姿势（下载 → 审计 → 跑）。
- **quick-install.sh 不发布到 release 资产，挂 main 分支 raw**：用户拿到的总是最新的入口逻辑；版本变化只在 `DCC_VERSION` 这一个变量上。
- **保留本地 build 兜底**：CI 哪天挂了用户仍能装上 docker-cc。
- **保留 git clone 路径**：fork / 内网 / 安全敏感用户必需的退路；维护成本几乎为零（install.sh 是同一份）。

---

## 12. 实施步骤建议

按依赖关系排序，每步独立可验证。

### 步骤 1：阿里云 ACR 准备（30min，外部账号）
完成 §3.1 全部步骤；得到 registry / namespace / 用户名 / 密码 4 项。

### 步骤 2：GitHub Secrets 配置（10min）
完成 §3.2，4 个 secret 全部加上。

### 步骤 3：写 release.yml（45min）
按 §4.1 拷入完整内容（含 tarball + GitHub Release 段）；GHCR_OWNER / ALIYUN_NAMESPACE 留占位。

### 步骤 4：workflow_dispatch dry-run（20min + CI 时长）
不改其他代码，先把 release.yml 单独 push 到 main，手动触发跑通。
验收：GHCR + 阿里云 ACR 各有镜像，arm64 + amd64 manifest 都在。**tarball job 在 workflow_dispatch 触发时跳过（被 `if` 条件保护），属预期。**

### 步骤 5：改 docker-compose.yml + install.sh（含软链改动）+ bin/dcc（1.5-2h）
按 §4.2 / §4.3（含 §4.3.3）/ §4.4 改完。**重点验证**：
- `./install.sh --registry=global` 走 pull
- 装完后 `rm -rf $(pwd)/../docker-cc` 不影响 `dcc -v`（软链已脱离工作目录）

### 步骤 6：写 `scripts/quick-install.sh`（1h）
按 §4.8 拷入；本地 mock 测试：
```bash
# 起 python -m http.server 8000 在临时仓库根，模拟 raw 服务
# DCC_GHPROXY=http://localhost:8000/ DCC_REPO=local/docker-cc bash scripts/quick-install.sh
```
确认参数透传、`$TMP` 清理、sha256 校验各分支都走通。

### 步骤 7：扩 bats 测试（1.5h）
§9.1 列的 4 个 bats 文件补上，本地 `bats tests/unit/` 全绿。

### 步骤 8：跑 §9.2 Matrix B 与 Matrix A 的 mock 子集（1.5h）
**注意**：此时还没正式 release，release tarball 在线下不存在 —— Matrix A 的端到端不能跑，移到步骤 12。本步只覆盖：
- **Matrix B 全表**（git clone 路径四行：默认 auto / --build-local / 断 ACR fallback / `rm -rf` 后 dcc 仍可用）
- **Matrix A 的 mock 子集**：本地用 `python -m http.server` 模拟 ghproxy，验证 quick-install.sh 自身正确（参数透传、$TMP 清理、错误处理）

### 步骤 9：更新 README + CHANGELOG（45min）
- README/README.zh-CN 的「5 分钟上手」按 §4.7 改写
- 加「故障排查 / 镜像或 tarball 拉不动」段
- CHANGELOG 记一笔 v0.2.0，特别提示老用户：原 clone 目录可删

### 步骤 10：先提交代码改动 + quick-install.sh 到 main（5min）
**注意顺序**：先让 `scripts/quick-install.sh` 在 main 分支可访问，否则 release 后用户跑 curl|bash 会 404。

### 步骤 11：bump VERSION → 0.2.0 → commit → tag → push（5min）
触发正式 release.yml。等待 CI 完成（15-25 min 首次，含 arm64 仿真）。

### 步骤 12：跑 §9.2 Matrix A 端到端验证（1h）
release 完成后才能跑真正的 `curl | bash`：
- macOS arm64：默认（ghfast + auto）
- macOS arm64：`DCC_GHPROXY= ... --registry=global`
- Linux amd64：默认（ghfast + auto）
- 边界：故意写错 DCC_GHPROXY、下载中 Ctrl-C

确认：tarball 拉得到、sha256 校验通过、$TMP 清理干净、`dcc -v` 输出 v0.2.0。

### 步骤 13：观察 24h，收集首批用户反馈（被动）
若发现 fallback 触发频繁，调 §5 的探测逻辑或 §10 的提示。

**总工作量**：开发者侧约 6-8h（不含 CI 等待）。比纯镜像方案多 2h，主要是 quick-install.sh + bats 用例 + Matrix A 端到端验证。

### 顺序依赖图

```
  1 (ACR)  ─┐
  2 (GHs)  ─┼─► 3 (release.yml) ─► 4 (dry-run, 推 :dev tag)
            │
            ▼
            5 (compose / install.sh / bin/dcc 改动)
            │
            ▼
            6 (写 scripts/quick-install.sh + 本地 mock 验证)
            │
            ▼
            7 (扩 bats 用例) ─► 8 (Matrix B + Matrix A mock 子集)
                                                  │
                                                  ▼
                                                  9 (docs README/CHANGELOG)
                                                  │
                                                  ▼
                                                  10 (push 到 main：scripts/ 等)
                                                  │
                                                  ▼
                                                  11 (bump VERSION + tag v0.2.0 → 触发正式 release)
                                                  │
                                                  ▼
                                                  12 (Matrix A 端到端真实 curl|bash)
                                                  │
                                                  ▼
                                                  13 (观察 24h)
```

**关键 sequencing 约束**：
- **步骤 10 必须先于步骤 11**：raw URL 上的 `scripts/quick-install.sh` 在 main 分支可访问，是 curl|bash 入口的前置条件。
- **Matrix A 必须在步骤 11 之后**：tarball/release 资产不存在时无法做端到端，只能 mock。
- **Matrix B 在步骤 5 之后即可**：git clone 路径不依赖 release。

---

## 13. 后续可扩展

本期之外的想法，按优先级：

1. **`dcc upgrade --to <version>` / `dcc-use registry <auto|cn|global>`**：用户安装后想换版本 / registry 不用重跑 install.sh，由 dcc 自身改 `.env` + `docker compose pull`。
2. **weekly auto rebuild**：定时 cron 触发 release.yml，自动跟进 `@anthropic-ai/claude-code` 新版本（不变 docker-cc VERSION，只更新 `:latest`）。
3. **添加 Docker Hub 作为第三个 registry**：等到 GHCR + 阿里云双源都有用户卡过，再加 Hub 作 mirror。
4. **release notes 自动生成**：CHANGELOG.md 段落自动同步到 GitHub Release 描述。
5. **`dcc self-update`**：自检 latest release 版本号，引导用户重跑 quick-install.sh 或自动完成 in-place 升级（涉及 `~/.docker-cc/repo/` 同步 + image pull + 软链刷新）。
6. **镜像 SBOM / 签名**：等项目用户量上来再做。
7. **缩减镜像 size**：当前 350MB，大头是 node + claude-code。可探索 alpine 基底 / 移除不必要的工具（nano 等）。
8. **Homebrew tap（如果有 Mac 用户呼声）**：把 quick-install.sh 包成 brew formula，享受 `brew upgrade`。
9. **Gitee 镜像（如果 ghproxy 系列全挂掉）**：用 hub-mirror-action 把 main + tags 推到 Gitee 做退路。
