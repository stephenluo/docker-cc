# docker-cc

将 Claude Code CLI 容器化，自带代理（Mihomo + Web 面板）和多 LLM 供应商切换。
对外暴露一个 `cc` 命令，使用体验等同原生 `claude`。

## 5 分钟上手

```bash
# 1. 克隆 + 安装（默认走国内加速）
git clone <this-repo>.git docker-cc && cd docker-cc
./install.sh

# 2. 启动代理 + 指定 Clash/Mihomo 订阅
cc up "https://your-airport.com/subscription"

# 3. 配置一个 LLM 供应商
cc-use edit anthropic                # 填入 sk-ant-...
cc-use anthropic                     # 切到该供应商

# 4. 在任意项目目录正常用
cd ~/your-project
cc                                   # 等同于敲 claude，进入交互
cc -p "explain this repo"            # 一次性
```

## 核心命令

| 命令 | 作用 |
|---|---|
| `cc` | 等同于 `claude`，自动挂载当前目录到容器 |
| `cc --version` | 显示 cc 版本号（不透传给 claude） |
| `cc up [<url>]` | 启动 mihomo 代理；首次需带订阅 URL |
| `cc panel` | 浏览器打开 metacubexd 面板（默认 `localhost:19090`），切节点 |
| `cc upgrade` | 升级镜像内 Claude Code（rebuild 镜像；配置不丢） |
| `cc login` / `cc logout` | Claude 账号 OAuth 流程（Pro/Max 订阅） |
| `cc-use [list]` | 列出所有 LLM 供应商，★ 标记当前激活 |
| `cc-use <name>` | 切到该供应商 |
| `cc-use add <name> --api-key=K --base-url=U [--model=M]` | 添加新供应商 |
| `cc-use edit <name>` | 编辑供应商 JSON |
| `cc-use show <name>` | 查看详情（API Key 脱敏） |

完整命令清单：`cc-use --help` 或 `cat docs/implementation-plan.md` §7.1 / §7.2。

## 已支持的 LLM 供应商

`./install.sh` 会预置以下供应商模板，编辑填入 token 即可使用：

| 名字 | 模型 | 类型 |
|---|---|---|
| `anthropic` | Claude Opus / Sonnet / Haiku | API Key |
| `claude-account` | Claude Pro / Max 订阅 | OAuth |
| `deepseek` | deepseek-chat | API Key |
| `kimi` | kimi-k2-turbo-preview | API Key |
| `zhipu` | glm-4.6 | API Key |
| `minimax` | minimax-m2 | API Key |

新增其他供应商：`cc-use add <name> --api-key=... --base-url=...`

## 国内网络优化

镜像构建默认走国内加速：清华 apt + ghproxy + npmmirror。出国/海外用户：

```bash
./install.sh --no-cn-mirror
```

或手动 `--build-arg APT_MIRROR=deb.debian.org GH_PROXY= NPM_REGISTRY=https://registry.npmjs.org`。

## 设计文档

- [docs/implementation-plan.md](docs/implementation-plan.md) — 完整设计（架构、Dockerfile、脚本、风险、实施计划）
- [docs/testing.md](docs/testing.md) — 测试方案（bats 单元/集成、CI、兼容性矩阵）

## 卸载

```bash
./uninstall.sh                  # 移除 cc/cc-use 软链，保留配置
./uninstall.sh --purge          # 一并删除 ~/.docker-cc/（慎用）
```

## 许可

MIT
