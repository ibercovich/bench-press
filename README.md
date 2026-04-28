# bench-press

A sandboxed Docker environment for running [Claude Code](https://docs.anthropic.com/en/docs/claude-code) against [terminal-bench](https://github.com/harbor-framework/terminal-bench-3) task analyses — no permissions prompts, no host filesystem risk.

Claude runs inside a locked-down container with read-only access to your workspace and a per-run writable task directory. Credentials are extracted from your macOS Keychain at launch so there's nothing to configure.

## Prerequisites

- macOS
- [Docker Desktop](https://www.docker.com/products/docker-desktop/)
- [Claude Code](https://docs.anthropic.com/en/docs/claude-code) logged in (`claude` CLI authenticated)
- [GitHub CLI](https://cli.github.com/) logged in (`gh auth login`)
- Python 3

## Quick start

```bash
git clone <this-repo> && cd bench-press

# Full GUIDE.md task review of a PR — the only command you typically need
./run.sh --pr https://github.com/harbor-framework/terminal-bench-3/pull/166
```

That's it. `--pr` triggers a complete review: rubric alignment, instruction-bloat check, per-trial failure taxonomy reconstructed from primary artifacts, and a `review-summary.md` written to the task directory.

Concurrent runs against different PRs work in parallel — each PR has its own namespaced directory (see [File layout](#file-layout)).

## How it works

1. **`run.sh`** builds the Docker image (if needed), extracts your Claude and GitHub tokens from macOS Keychain, and launches a container.
2. With `--pr <url>`, the script pre-fetches the `/run` and `/cheat` result comments, the PR description and diff, all PR comments, and the five sticky CI bot comments into a per-PR directory at `tasks/<owner>/<repo>/pr-<N>/`.
3. Claude Code runs in `--dangerously-skip-permissions` mode inside the container — safe because the container is the sandbox.
4. The PR directory is bind-mounted at `/tasks` inside the container (writable; outputs survive container exit). The project root is mounted read-only at `/workspace` so the agent can read `GUIDE.md`; the host's `tasks/` history is hidden behind a tmpfs so the agent can't read prior runs by accident.
5. Output streams through **`format-stream.py`** so you see thinking, tool calls, and responses in real time instead of raw JSON.

## Usage

### From a PR (the common case)

```bash
./run.sh --pr https://github.com/harbor-framework/terminal-bench-3/pull/330
```

The built-in prompt drives the full GUIDE.md review end-to-end. No customization needed.

### Submit a review automatically

Add `--review` to post a `REQUEST_CHANGES` review to the PR after the analysis finishes. The review body uses `issues-found.md` (extracted from `## Issues Found`) and inlines the full `review-summary.md` in a collapsed `<details>` block.

```bash
./run.sh --review --pr https://github.com/harbor-framework/terminal-bench-3/pull/330
```

The review is prefixed with: *"This is an automatic review. The author might disagree with some of the feedback."* If `issues-found.md` is empty or missing, no review is submitted (no findings = nothing to request changes on). Posts under the GitHub identity associated with your local `gh auth`.

### Custom prompt (advanced)

If you want a narrower or different focus, pass a prompt before `--pr`:

```bash
./run.sh "Focus only on cheat-trial robustness. Skip the bloat review." \
  --pr https://github.com/harbor-framework/terminal-bench-3/pull/330
```

### With local task files (no PR)

Place task `.md` files in the repo root and pass a prompt referencing them:

```bash
gh api repos/harbor-framework/terminal-bench-3/contents/tasks/my-task/instruction.md \
  --jq '.content' | base64 -d > my-task.md

./run.sh "use GUIDE.md to analyze the task described in my-task.md"
```

This mode falls back to a timestamped `tasks/run-<timestamp>-<pid>/` directory.

## What's in the container

| Tool | Purpose |
|------|---------|
| `claude` | Claude Code CLI (`--dangerously-skip-permissions`) |
| `gh` | GitHub CLI (authenticated via `GH_TOKEN`) |
| `git` | Version control |
| `curl` | HTTP requests |
| Node.js 22 | Claude Code runtime |

## Container resources

- **CPU**: all host cores
- **RAM**: 8 GB
- **Disk**: dynamically allocated by Docker Desktop (check Docker Desktop > Settings > Resources > Disk to increase)

## File layout

```
bench-press/
├── Dockerfile          # Container image definition
├── run.sh              # Build + run script (extracts credentials, launches container)
├── format-stream.py    # Filters stream-json output into readable terminal output
├── GUIDE.md            # Analysis methodology and replay guide
├── README.md           # This file
└── tasks/              # Created at runtime, gitignored
    ├── <owner>/<repo>/pr-<N>/    # PR mode: namespaced per PR, persists across runs
    │   ├── trajectory_analysis.md, cheat_results.md, ci/*.md, ...
    │   └── review-summary.md     # Written by the agent
    └── run-YYYYMMDD-HHMMSS-PID/  # Custom-prompt mode (no --pr): timestamped
```

Re-running the same PR refreshes the pre-fetched snapshot in place. Outputs from earlier runs (e.g. `review-summary.md`) survive unless the agent overwrites them.

## Output format

The stream filter shows:

```
[init] model=claude-sonnet-4-6 mode=bypassPermissions
💭 Let me start by reading the guide and task file...

[tool] Read: /workspace/GUIDE.md
[tool] Read: /workspace/my-task.md
Here's my analysis of the task...
[tool] Bash: gh run download 12345 --repo harbor-framework/terminal-bench-3 ...
[tool] WebFetch: https://...

[done] 12 turns, 45.3s, $0.0521
```

## Security notes

- The workspace is **read-only** — Claude cannot modify your files
- Claude writes only to `/tasks` (mapped to `tasks/<run-id>/`)
- Credentials are passed as environment variables, never baked into the image
- No `--privileged`, no Docker socket mount, no host network
- The `node` user (non-root) runs inside the container
