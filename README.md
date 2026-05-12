# docker-cc

> Dockerized [Claude Code](https://claude.com/claude-code) CLI with built-in Mihomo proxy and one-command switching between Anthropic / DeepSeek / Kimi / Zhipu / MiniMax — designed for users behind restrictive networks (especially GFW).

**English** | [中文](README.zh-CN.md)

The `dcc` command behaves identically to native `claude` — but runs in a container with bundled Mihomo proxy + a web dashboard, and hot-switches between LLM providers (API key or OAuth) via `dcc-use`.

---

## Why

| Pain point | Solution |
|---|---|
| Can't reach `api.anthropic.com` reliably from China | Image bundles [Mihomo](https://github.com/MetaCubeX/mihomo) (the Clash core); all egress is proxied. Browser dashboard ([metacubexd](https://github.com/MetaCubeX/metacubexd)) for picking nodes |
| Want to use Claude Code with DeepSeek / Kimi / Zhipu / MiniMax via their Anthropic-compatible endpoints | `dcc-use <name>` switches in one command. Tokens live in `~/.docker-cc/providers/*.json` (chmod 600) |
| Want both Claude Pro/Max (OAuth) and an API key as fallback | `dcc-use claude-account` ↔ `dcc-use deepseek`. OAuth credentials persist across container restarts |
| GitHub / npm pulls slow or down inside China | Defaults to Tsinghua apt + ghproxy + npmmirror. When `mirror.ghproxy.com` is flaky, `dcc probe` auto-fails over to `ghfast.top` etc. |
| Don't want to pollute `~/` | All state lives in `~/.docker-cc/`. `./uninstall.sh` removes cleanly |

---

## Quick Start (5 minutes)

### One-line install (recommended)

```bash
# Outside China (direct GitHub + GHCR)
curl -fsSL https://raw.githubusercontent.com/stephenluo/docker-cc/main/scripts/quick-install.sh \
  | DCC_GHPROXY= bash -s -- --registry=global

# In China (default: ghfast mirror + Alibaba ACR)
curl -fsSL https://ghfast.top/raw.githubusercontent.com/stephenluo/docker-cc/main/scripts/quick-install.sh | bash

# Pin a specific version
curl -fsSL https://raw.githubusercontent.com/stephenluo/docker-cc/main/scripts/quick-install.sh \
  | DCC_VERSION=0.2.0 DCC_GHPROXY= bash
```

Then:

```bash
dcc up "https://your-airport.com/subscription"
dcc-use edit anthropic           # paste your sk-ant-... API key
dcc                              # use in any project dir, equivalent to `claude`
```

### Safety-conscious: download first, then bash

```bash
curl -fsSL https://raw.githubusercontent.com/stephenluo/docker-cc/main/scripts/quick-install.sh -o quick-install.sh
less quick-install.sh            # audit the script (~80 lines)
bash quick-install.sh            # then run (any --flag passes through)
```

### Advanced install (git clone)

For: forks, code edits, intranet customization, full audit of the install chain.

```bash
git clone https://github.com/stephenluo/docker-cc.git docker-cc && cd docker-cc
./install.sh                     # same options as quick-install.sh
# Outside China: ./install.sh --registry=global
# Modified Dockerfile / offline: ./install.sh --build-local
```

### Install options

| Option | Effect |
|---|---|
| `--registry=auto` (default) | Probe; if `aliyun.com` reachable use ACR, else GHCR |
| `--registry=cn` / `--registry=global` | Force Aliyun ACR / GHCR |
| `--registry=ghcr.io/myorg` | Custom registry prefix (fork / private) |
| `--build-local` | Skip pull, build locally (offline / patched Dockerfile) |
| `--no-cn-mirror` | Disable China apt/npm/GH acceleration (affects fallback build) |

> **macOS users**: if `dcc` resolves to the C compiler the first time, run `hash -r` (zsh has cached the path to `/usr/bin/cc`). The command was named `dcc` from the start specifically to avoid this conflict.
>
> **After installation**: the working directory (curl|bash's `/tmp/` temp dir or the local git clone) can be safely `rm -rf`'d. `dcc` / `dcc-use` keep working via symlinks under `~/.docker-cc/repo/bin/`.

---

## Commands

### `dcc` (proxy / container / claude pass-through)

| Command | Effect |
|---|---|
| `dcc` | Equivalent to `claude`; auto-mounts current directory to `/workspace` |
| `dcc -p "..."` | One-shot prompt (passes through to `claude -p`) |
| `dcc -c` | Resume last session |
| `dcc --version` | Show dcc version (does not pass to claude) |
| `dcc up [<url>]` | Start mihomo; first run needs subscription URL, later calls reuse `.env` |
| `dcc down` | Stop services |
| `dcc panel` | Open metacubexd dashboard in browser |
| `dcc shell` | Drop into the container (bash) for debugging |
| `dcc login` / `dcc logout` | Claude account OAuth flow |
| `dcc refresh` | Re-fetch subscription (URL unchanged) |
| `dcc upgrade` | Upgrade to latest release (probes `api.github.com`, rewrites VERSION + `.env`, `docker compose pull` image, then sync host `bin/` + compose from release tarball) |
| `dcc upgrade --keep` | Refresh image layers but keep current version pin; host scripts unchanged |
| `dcc upgrade --to=<x.y.z>` | Switch to a specific version |
| `dcc upgrade --build` | Build locally (Dockerfile patched / registry unreachable) |
| `dcc probe` | Re-probe GH_PROXY mirrors (use when `dcc upgrade --build` fails) |
| `dcc logs [-f]` | Tail mihomo logs |

### `dcc-use` (LLM provider management + registry switch)

| Command | Effect |
|---|---|
| `dcc-use` or `dcc-use list` | List all providers; ★ marks the active one |
| `dcc-use <name>` | Switch to that provider |
| `dcc-use current` | Print only the active provider name |
| `dcc-use show <name>` | Show details (API key masked) |
| `dcc-use add <name> --api-key=K --base-url=U [--model=M] [--small-model=M]` | Add an API-key provider |
| `dcc-use add <name> --mode=oauth` | Add an OAuth provider (Anthropic account) |
| `dcc-use edit <name>` | Edit JSON with `$EDITOR` |
| `dcc-use remove <name>` | Delete (with confirmation) |
| `dcc-use test [<name>]` | Probe endpoint reachability + token validity |
| `dcc-use registry` | Show current image registry (GHCR / Aliyun ACR / custom) |
| `dcc-use registry cn` | Rewrite `.env`'s `DCC_IMAGE` prefix to Aliyun ACR (then run `dcc upgrade --keep` to pull from new source) |
| `dcc-use registry global` | Same, but to GHCR |
| `dcc-use registry <prefix>` | Same, custom registry prefix (fork / private) |

---

## Bundled LLM Providers

`install.sh` lays down 6 templates. Just `dcc-use edit <name>` to fill in the token:

| Name | Model | Type | base_url |
|---|---|---|---|
| `anthropic` | Claude Opus 4.7 / Sonnet 4.6 / Haiku 4.5 | API key | `api.anthropic.com` |
| `claude-account` | Claude Pro / Max subscription | OAuth | (uses `~/.docker-cc/claude/.credentials.json`) |
| `deepseek` | deepseek-chat | API key | `api.deepseek.com/anthropic` |
| `kimi` | kimi-k2-turbo-preview | API key | `api.moonshot.cn/anthropic` |
| `zhipu` | glm-4.6 | API key | `open.bigmodel.cn/api/anthropic` |
| `minimax` | minimax-m2 | API key | (their endpoint) |

Add any other Anthropic-compatible provider:
```bash
dcc-use add custom --api-key=sk-xxx --base-url=https://your.api/anthropic --model=foo-pro
```

> Claude Code reads two model slots: `ANTHROPIC_MODEL` (main) and `ANTHROPIC_SMALL_FAST_MODEL` (background tasks). Both **must come from the same provider** (see [implementation-plan §11.3](docs/implementation-plan.md)).

---

## Architecture

```
HOST
├─ dcc, dcc-use                  (in PATH via symlink)
│   ├─ dcc up      → docker compose up
│   ├─ dcc <args>  → docker compose run --rm cc claude <args>
│   └─ dcc-use     → edits ~/.docker-cc/cc-home/.claude/settings.json
└─ ~/.docker-cc/
    ├─ mihomo/      config.yaml + cache.db
    ├─ cc-home/     container $HOME (.claude.json + .claude/{settings,creds} + .npmrc + ...)
    └─ providers/   *.json (chmod 600)
                                          │
                                          │ volume mounts
                                          ▼
DOCKER NETWORK: cc-net
├─ mihomo (always-on)   :7890 mixed proxy  /  :9090 ctrl + metacubexd UI
└─ cc     (on-demand --rm)
    ├─ HTTP_PROXY=http://mihomo:7890
    ├─ ANTHROPIC_* env loaded from settings.json
    └─ /workspace = $(pwd)
                                          │
                                          ▼
HOST PORTS
├─ 127.0.0.1:19090  → metacubexd panel (default)
└─ 127.0.0.1:9090   → only if docker-compose.override.yml is added
```

Full design: [docs/implementation-plan.md](docs/implementation-plan.md) (~1200 lines).

### What's inside the container

Beyond `claude` itself, the image ships with developer essentials so Claude Code's Bash tool, hooks, and your scripts can run out of the box:

| Category | Tools |
|---|---|
| Shell / editor | bash 5.2 / nano |
| Language | python 3.11 + pip (PEP 668 disabled inside the container — `pip install foo` just works) |
| VCS | git 2.39 + openssh-client |
| Search / pager | ripgrep (`rg`, the high-performance backend for Claude Code's Grep tool) / less |
| Compress / fetch | xz-utils / unzip / wget |
| Debug | procps (`ps`) / iproute2 (`ip`) / file / diffutils (`diff`) / patch |
| Misc | curl / jq / ca-certificates / gettext-base (`envsubst`) / tini |

Image size ≈ 750 MB. For native compilation inside the container (`pip install` with C extensions, npm `node-gyp`), install build-essential / gcc yourself or patch the Dockerfile and run `dcc upgrade --build`.

---

## China Network Optimization

`./install.sh` enables three layers of acceleration by default + auto probing:

| Resource | Default mirror |
|---|---|
| apt source | `mirrors.tuna.tsinghua.edu.cn` |
| GitHub releases (mihomo / yq / metacubexd) | Auto-probes 5 GH_PROXY mirrors, writes the working one to `.env` |
| npm registry (Claude Code) | `registry.npmmirror.com` |

Build outside China:
```bash
./install.sh --no-cn-mirror
```

When `mirror.ghproxy.com` is down, run `dcc probe` to switch (auto-failover to `ghfast.top` / `gh-proxy.com` / `ghps.cc`).

---

## Troubleshooting

| Symptom | Fix |
|---|---|
| `curl \| bash` fails at "探测 latest 版本" (API 403 / unreachable) | api.github.com behind a strict firewall? Pin a version to skip probing: `... \| DCC_VERSION=0.2.0 bash`. (ghfast / ghproxy mirrors don't proxy api.github.com — quick-install always calls the API directly.) |
| `curl \| bash` fails at tarball download | Switch `DCC_GHPROXY`: `DCC_GHPROXY=https://gh-proxy.com/ curl ...`, or `DCC_GHPROXY=` for direct link, or fall back to `git clone + ./install.sh` |
| `dcc upgrade` fails with "pull failed" | Try `dcc upgrade --build` to rebuild locally (uses GH_PROXY probing). Common cause: registry temporarily unreachable |
| `dcc upgrade --build` fails with SSL error (curl mirror.ghproxy.com) | `dcc probe` switches to another GH_PROXY mirror (default `dcc upgrade` uses pull and isn't affected) |
| `dcc panel` shows "Cannot connect to backend" | metacubexd's hard-coded default backend is `127.0.0.1:9090`, but the host maps the controller to `19090`. Either (a) fill `http://127.0.0.1:19090` into the setup form with secret **left blank**, or (b) add a `127.0.0.1:9090:9090` mapping via `~/.docker-cc/repo/docker-compose.override.yml` so the default works zero-config |
| `dcc` resolves to clang/C compiler | `hash -r` clears zsh's command cache. Newly-installed `dcc` should not collide |
| OAuth occasionally forces re-login | claude.ai does IP-based account binding. Pin `claude.ai` / `api.anthropic.com` to a stable US node in mihomo rules |
| Container `dcc-use` complains about read-only providers | By design (`:ro` mount). Use `add` / `edit` / `remove` from the **host** side |
| `dcc update` errors out | Use `dcc upgrade` instead. `update` would run inside the `--rm` container and lose the change on exit |

---

## Known Limitations

- **macOS Bash 3.2 multibyte compatibility**: scripts use `${var}` explicit braces around any var followed by CJK chars to dodge a 2007 bash regression. Worth knowing if you extend the scripts. ([implementation-plan §12](docs/implementation-plan.md))
- **`dcc` name collisions** (rare): DCC anti-spam (`dcc-client` apt package), UNSW teaching gcc wrapper. Default-installed systems have no conflict.
- **HTTP/HTTPS proxy only**: env-var based proxy doesn't cover UDP/QUIC. Claude Code is pure HTTPS REST so this is fine.
- **`dcc-use` is read-only inside container**: providers volume is mounted `:ro`. Run `add` / `edit` / `remove` on the host side.

---

## Documentation & Tests

- **[docs/implementation-plan.md](docs/implementation-plan.md)** — full design (architecture, Dockerfile, scripts, risks, milestones; ~1200 lines)
- **[docs/testing.md](docs/testing.md)** — test plan (bats unit/integration, CI, compat matrix; regression matrix tracks 33 fixed bugs)
- **[CHANGELOG.md](CHANGELOG.md)** — detailed changelog

---

## Uninstall

```bash
./uninstall.sh                  # Removes only dcc / dcc-use symlinks; keeps configs + credentials
./uninstall.sh --purge          # Also deletes ~/.docker-cc/ (subscription, tokens, OAuth creds — destructive)
```

---

## Contributing

Bug reports / PRs welcome. Before submitting:

```bash
shellcheck bin/dcc bin/dcc-use entrypoint.sh install.sh uninstall.sh
docker compose config -q
bats tests/unit/                # requires `brew install bats-core jq` first
```

---

## License

[MIT](LICENSE)
