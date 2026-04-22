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

# Analyze a PR with the built-in trajectory-review prompt (most common)
./run.sh --pr https://github.com/harbor-framework/terminal-bench-3/pull/166

# Or pass a custom prompt (overrides the built-in)
./run.sh "use GUIDE.md to review this, focus on cheat resistance" \
  --pr https://github.com/harbor-framework/terminal-bench-3/pull/166

# Or run with a local task file
./run.sh "use GUIDE.md to analyze the task described in my-task.md"
```

## How it works

1. **`run.sh`** builds the Docker image (if needed), extracts your Claude and GitHub tokens from macOS Keychain, and launches a container.
2. If `--pr <url>` is provided, the script fetches the last comment containing "Agent Trial Results" from the PR (including collapsed `<details>` sections) and saves it as `/tasks/trajectory_analysis.md` inside the container.
3. Claude Code runs in `--dangerously-skip-permissions` mode inside the container — safe because the container is the sandbox.
4. Your project directory is mounted **read-only** at `/workspace`. Each run gets its own writable directory at `/tasks` (persisted to `tasks/<run-id>/` on your host).
5. Output streams through **`format-stream.py`** so you see thinking, tool calls, and responses in real time instead of raw JSON.

## Usage

### From a PR (recommended)

Pass `--pr` with a terminal-bench PR URL. The script pre-fetches the `/run` and `/cheat` result comments, the PR description and diff, and the five sticky CI bot comments (`static-checks`, `rubric-review`, `task-overview`, `task-validation`, `pr-status`) into `/tasks/` before Claude starts.

With no prompt, the script uses a built-in trajectory-review prompt that tells Claude to follow `GUIDE.md`, download the trial artifacts, and produce its own analysis from scratch (rather than rubber-stamping the pre-fetched results summary):

```bash
./run.sh --pr https://github.com/harbor-framework/terminal-bench-3/pull/330
```

Pass your own prompt to override the default — useful when you want the fuller PR review that uses the pre-fetched CI comments and rubrics:

```bash
./run.sh "use GUIDE.md end-to-end: read ci/*.md, both rubrics, all trials, \
  and write /tasks/review-summary.md" \
  --pr https://github.com/harbor-framework/terminal-bench-3/pull/330
```

### With local task files

Place task definition `.md` files in the repo root alongside `GUIDE.md`. These are not checked into git — they're specific to your analysis instance.

```bash
# Download a task description from a terminal-bench PR
gh api repos/harbor-framework/terminal-bench-3/contents/tasks/my-task/instruction.md \
  --jq '.content' | base64 -d > my-task.md

# Run the analysis
./run.sh "use GUIDE.md to analyze the task described in my-task.md"
```

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
└── tasks/              # Created at runtime, one subdirectory per run (gitignored)
    └── run-YYYYMMDD-HHMMSS-PID/
```

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
