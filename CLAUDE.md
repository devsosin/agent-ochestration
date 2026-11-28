# mac-agent (agent-hub)

Tooling that runs one coding-agent container per project on an always-on Mac mini (M4, 16 GB, 2 TB, OrbStack). A hub Claude Code session on the Mac mini host dispatches work to those containers through `bin/proj`; the user reviews results in VS Code (Remote-SSH or vscode.dev tunnel) from any device. Project type: new tool (shell CLI + container image). Design and decisions: `docs/architecture.md`.

Git repository: `devsosin/agent-ochestration` (public — never commit tokens, hostnames, or internal IPs).

## 1. Layout

```text
mac-agent/
├── bin/proj                 # CLI: projects, accounts, tasks (bash 3.2-compatible)
├── image/                   # Agent image: Dockerfile (targets base, web, rust, rust-web) + files copied into it
│   ├── managed-settings.json  # default managed settings; bin/proj copies it per project (harness switch AGENT_HUB_HARNESS)
│   ├── settings/            # permission + hook profiles: common.json + one team file (dev, marketing), merged per project
│   ├── hooks/               # guard (.env, folder, settings, secrets, merge gate) and worklog hooks → /usr/local/lib/agent-hub/hooks
│   ├── agent-run            # loads token secrets, then execs claude with mcp.json
│   ├── mcp.json             # imagegen MCP at host.docker.internal:7801; mcp-web.json adds playwright (web, rust-web)
│   ├── install-web          # Playwright MCP + Chromium + Korean fonts (web layer)
│   ├── profile.sh           # exports tokens from /run/secrets for shells
│   └── gitconfig            # gh credential helper, ssh→https rewrite, safe.directory
├── compose/project.yml      # one compose project per registered project (proj-<name>)
├── compose/knowledge.yml    # knowledge MCP server (one container, joined to projects with knowledge on)
├── dockerproxy/           # Docker API proxy sidecar (compose service `docker`): server.py + Dockerfile, stdlib Python
├── imagegen/server.py       # image MCP on the host (Codex CLI with the host's ChatGPT login), stdlib Python
├── hub/                     # main agent: CLAUDE.md (its operating guide, linked into ~/.agent-hub/hub) + settings.json (permissions)
├── tests/proj.test.sh       # unit checks for bin/proj helpers
├── tests/imagegen.test.sh   # imagegen server against a fake codex
├── tests/hooks.test.sh      # agent hooks against fake hook input
├── tests/dockerproxy_test.py  # proxy rules against a fake daemon
└── docs/                    # Korean, compact: architecture, accounts, proj, setup-macmini
```

Runtime state lives outside the repo (never commit it):

| Path (host) | Contents |
|---|---|
| `~/.agent-hub/config` | optional overrides: `WORKSPACE_ROOT`, `HARNESS_DIR`, `DEFAULT_ACCOUNT`, `MAX_TASKS` |
| `~/.agent-hub/accounts/<alias>/` | `claude.token`, `gh.token`, `git.env` — secrets, mode 700/600 |
| `~/.agent-hub/projects/<name>.env` | compose variables for one project |
| `~/.agent-hub/projects/<name>.managed-settings.json` | that project's plugins + `env` (`proj plugin`) + profile rules (`proj profile`), mounted read-only at `/etc/claude-code/managed-settings.json` |
| `~/.agent-hub/plugins/<marketplace>/` | plugin marketplace clones (`proj plugin source add`), mounted read-only at `/opt/plugins` |
| `~/.agent-hub/tasks/<name>/<id>/` | `prompt.txt`, `log.jsonl`, `meta`, `pid`, `exit` (mounted at `/var/agent-hub/tasks` in that project's container), `transcript.md` (built on the host, `proj transcript`) |
| `~/.agent-hub/sessions/<name>/` | Claude Code session files of that project's container (bind mount of `/home/node/.claude/projects`), source of `transcript.md` |
| `~/.agent-hub/usage/<alias>.jsonl` | latest rate-limit probe result per account (`proj usage --refresh`) |
| `~/.agent-hub/imagegen/`, `imagegen.log` | generated images (24 h) and log of `proj imagegen run` (launchd `com.agent-hub.imagegen`) |
| `~/.agent-hub/idle.log` | `proj idle` runs from launchd (`com.agent-hub.idle`) |
| `~/.agent-hub/hub-settings.json` | `hub/settings.json` with paths rewritten for `WORKSPACE_ROOT`/`AGENT_HUB_HOME` (`proj hub run`) |
| `~/.agent-hub/hub/` | hub working dir (`CLAUDE.md` symlink, `hub.log`); launchd: `~/Library/LaunchAgents/com.agent-hub.hub.plist` |
| `~/.claude-<alias>/` | host Claude config per account (full login, used by the hub) |
| `~/workspace/<name>/` (`WORKSPACE_ROOT`) | project checkout (tasks run here on `agent/<id>`); `--worktree` tasks in `.worktrees/<id>/` |
| `~/workspace/refs/<repo>/` | reference repo clones (`proj ref`), pulled on the host before each task run; mounted read-only at `/refs/<repo>` only in projects listing them (`REFS` in `<name>.env`, compose override `<name>.refs.yml`) |
| `~/.agent-hub/knowledge/` | knowledge MCP server config `mcp.config.json` (written by `proj`, token hashes only), `github.token` (server's propose token), `db/` (ETL output, index) |
| `~/.agent-hub/projects/<name>.knowledge.token` | that project's knowledge token (compose secret; empty while off) |
| `~/workspace/harness/` (`HARNESS_DIR`) | harness plugin source (`devsosin/harness`), mounted read-only, pulled before each task, loaded with `agent-run --plugin-dir` (no plugin cache) |

## 2. Sources of truth

1. User decisions in `docs/architecture.md` §결정 기록.
2. `docs/*.md`.
3. Code — what actually runs. If code and docs differ, ask which is right and fix the other in the same change.

## 3. Rules

- GitHub: repo creation and other admin actions use the host `gh` login (`proj new --create`); containers only get the account's fine-grained token without Administration.
- `hub/settings.json` is the hub's permission boundary: widen it only with the user's agreement, and keep the deny on `~/.agent-hub/accounts/**`.
- Project containers never get the Docker socket, host `~/.ssh`, or the hub's Claude login — whoever holds the socket controls every bind-mountable path under `/Users`. They use host Docker only through their own `docker` proxy service (`dockerproxy/server.py`), which limits them to objects labelled `agent-hub.project=<name>` and bind mounts inside the project dir. Widen its rules only with the user's agreement; never label the `agent` or `docker` services, and never let a project write `agent-hub:*` images.
- Mount the project dir at the same absolute path in the container — git worktrees store absolute paths, and the host (VS Code, hub) must open worktrees the container created.
- `bin/proj` must run on macOS `/bin/bash` 3.2: no `${x,,}`, associative arrays, `mapfile`.
- `proj rm` removes the project's containers, its Claude config volume, and the containers/networks/volumes labelled `agent-hub.project=<name>` (user decision: projects keep their compose/seed so these can be re-created). Never delete a project directory (except `--purge` checks), unlabelled volumes, or the shared `cargo-*` volumes from code.
- No unscoped `docker system prune` / `volume prune` — it deletes other projects' data. Clean up per compose project (`harness:cleanup`).
- Secrets: never print token values or write them to logs, commits, or chat. Read them only from `/run/secrets` inside containers.

## 4. Build & test

```bash
bash tests/proj.test.sh                 # helper unit checks
bash tests/imagegen.test.sh             # imagegen MCP server (fake codex)
bash tests/hooks.test.sh                # agent hooks (guard, worklog)
python3 tests/dockerproxy_test.py       # Docker proxy rules (fake daemon)
bin/proj build                          # builds agent-hub:base, web, rust, rust-web, dockerproxy
```

Smoke test without touching real state (scratch dirs, fake token; task fails on auth but exercises the pipeline):

```bash
export AGENT_HUB_HOME=$(mktemp -d) WORKSPACE_ROOT=$(mktemp -d)
bin/proj new smoke --account test --image agent-hub:base   # after `proj account add test`
bin/proj task smoke "say hi" && bin/proj status
bin/proj rm smoke
```

`shellcheck` is not installed on the dev MacBook (not verified).

## 5. Workflow

- harness skills (`github-issue`, `implement`, `github-pr`) once the repo has a remote. Commit only when the user asks.
- Changes to `bin/proj` commands update `docs/proj.md` in the same change.

## 6. Documentation

- `docs/` prose in Korean, compact (tables and short lists). Identifiers, paths, commands stay as they are.
- This file stays in English and points to docs instead of copying them.
