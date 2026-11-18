# mac-agent (agent-hub)

Tooling that runs one coding-agent container per project on an always-on Mac mini (M4, 16 GB, 2 TB, OrbStack). A hub Claude Code session on the Mac mini host dispatches work to those containers through `bin/proj`; the user reviews results in VS Code (Remote-SSH or vscode.dev tunnel) from any device. Project type: new tool (shell CLI + container image). Design and decisions: `docs/architecture.md`.

Git repository: `devsosin/agent-ochestration` (public — never commit tokens, hostnames, or internal IPs).

## 1. Layout

```text
mac-agent/
├── bin/proj                 # CLI: projects, accounts, tasks (bash 3.2-compatible)
├── image/                   # Agent image: Dockerfile (targets base, rust) + files copied into it
│   ├── managed-settings.json  # registers harness marketplace (/opt/harness) and enables the plugin
│   ├── agent-run            # loads token secrets, then execs claude
│   ├── profile.sh           # exports tokens from /run/secrets for shells
│   └── gitconfig            # gh credential helper, ssh→https rewrite, safe.directory
├── compose/project.yml      # one compose project per registered project (proj-<name>)
├── tests/proj.test.sh       # unit checks for bin/proj helpers
└── docs/                    # Korean, compact: architecture, accounts, proj, setup-macmini
```

Runtime state lives outside the repo (never commit it):

| Path (host) | Contents |
|---|---|
| `~/.agent-hub/config` | optional overrides: `WORKSPACE_ROOT`, `HARNESS_DIR`, `DEFAULT_ACCOUNT`, `MAX_TASKS` |
| `~/.agent-hub/accounts/<alias>/` | `claude.token`, `gh.token`, `git.env` — secrets, mode 700/600 |
| `~/.agent-hub/projects/<name>.env` | compose variables for one project |
| `~/.agent-hub/tasks/<name>/<id>/` | `prompt.txt`, `log.jsonl`, `meta`, `pid`, `exit` (mounted at `/var/agent-hub/tasks` in that project's container) |
| `~/workspace/<name>/` | project checkout; task worktrees in `.worktrees/<id>/` |
| `~/workspace/harness/` | harness plugin source (`devsosin/harness`), mounted read-only |

## 2. Sources of truth

1. User decisions in `docs/architecture.md` §결정 기록.
2. `docs/*.md`.
3. Code — what actually runs. If code and docs differ, ask which is right and fix the other in the same change.

## 3. Rules

- Project containers never get the Docker socket, host `~/.ssh`, or the hub's Claude login — whoever holds the socket controls every bind-mountable path under `/Users`.
- Mount the project dir at the same absolute path in the container — git worktrees store absolute paths, and the host (VS Code, hub) must open worktrees the container created.
- `bin/proj` must run on macOS `/bin/bash` 3.2: no `${x,,}`, associative arrays, `mapfile`.
- `proj rm` removes containers and the project's Claude config volume only; never delete a project directory, a DB volume, or the shared `cargo-*` volumes from code.
- No unscoped `docker system prune` / `volume prune` — it deletes other projects' data. Clean up per compose project (`harness:cleanup`).
- Secrets: never print token values or write them to logs, commits, or chat. Read them only from `/run/secrets` inside containers.

## 4. Build & test

```bash
bash tests/proj.test.sh                 # helper unit checks
bin/proj build                          # builds agent-hub:base and agent-hub:rust
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
