# bench-press

A sandboxed Docker environment for running [Claude Code](https://docs.anthropic.com/en/docs/claude-code) against [terminal-bench](https://github.com/harbor-framework/terminal-bench-3) task analyses — no permissions prompts, no host filesystem risk.

Claude runs inside a locked-down container with read-only access to your workspace and a per-run writable task directory. Credentials come from a `.env` file in the repo root — either a Console API key or a Claude subscription OAuth token.

## Prerequisites

- macOS
- [Docker Desktop](https://www.docker.com/products/docker-desktop/)
- An `ANTHROPIC_API_KEY` **or** a `CLAUDE_CODE_OAUTH_TOKEN` (from `claude setup-token`) in `<repo>/.env`
- [GitHub CLI](https://cli.github.com/) logged in (`gh auth login`)
- Python 3

## Credentials

`run.sh` reads Anthropic credentials from `.env` in the repo root (`cp .env.example .env` to create it; `.env` is gitignored so it never gets committed). Set exactly one of:

1. **`ANTHROPIC_API_KEY=sk-ant-api03-…`** — Console API key, billed per-token. Get one at <https://console.anthropic.com/settings/keys>.

2. **`CLAUDE_CODE_OAUTH_TOKEN=sk-ant-oat01-…`** — Claude subscription (Pro/Max) token, no API key needed. Mint it once with `claude setup-token` (browser flow); it lasts about a year. Container usage counts against the same subscription rate limits as your interactive sessions.

If both are set, the API key wins. If neither resolves, the script exits with setup instructions.

With `--engine codex`, credentials resolve instead as: **`OPENAI_API_KEY=sk-…`** in `.env` (per-token billing), or — if unset — a host **`codex login`** session (ChatGPT Plus/Pro subscription; `~/.codex` is mounted into the container so token refreshes persist). `CODEX_MODEL` (default `gpt-6-astra`) and `CODEX_EFFORT` (default `xhigh`) are also read from `.env`; both settings apply to the main run and the rewrite step. Codex runs with `--dangerously-bypass-approvals-and-sandbox`: the container is the sandbox, and any approval prompt would hang a headless run.

> **Note:** the short-lived claude.ai accessToken in the macOS Keychain / `~/.claude/.credentials.json` does *not* work here — the API rejects it when presented as an API key, and it expires within hours. Earlier versions of `run.sh` tried it as a fallback; that path was removed.

`GH_TOKEN` is taken from your `gh auth login` session. Posting reviews via `--review` requires that token to have write scope on the target repository.

### Model and effort

`.env` also controls the model and reasoning effort used inside the container:

```
CLAUDE_MODEL=claude-fable-5    # any model ID claude CLI accepts
CLAUDE_EFFORT=xhigh            # low / medium / high / xhigh / max (Fable 5); other models fall back to high
```

Defaults to `claude-fable-5` + `xhigh` if either is missing. No host `~/.claude*` files are bind-mounted into the container, so model and effort are the only Claude Code knobs that carry over.

## Quick start

```bash
git clone <this-repo> && cd bench-press

# Full GUIDE.md task review of a PR — the only command you typically need
./run.sh --pr https://github.com/harbor-framework/terminal-bench-3/pull/166

# Same, but driven by OpenAI Codex (gpt-6-astra, xhigh effort) instead of Claude Code
./run.sh --pr <url> --engine codex
```

That's it. `--pr` triggers a complete review: rubric alignment, instruction-bloat check, per-trial failure taxonomy reconstructed from primary artifacts, and a `review-summary.md` written to the task directory.

Concurrent runs against different PRs work in parallel — each PR has its own namespaced directory (see [File layout](#file-layout)).

## How it works

1. **`run.sh`** builds the Docker image (if needed), reads your Anthropic credentials from `.env` and your GitHub token from `gh`, and launches a container.
2. With `--pr <url>`, the script pre-fetches the `/run` and `/cheat` result comments, the PR description and diff, all PR comments, and the five sticky CI bot comments into a per-PR directory at `tasks/<owner>/<repo>/pr-<N>/`.
3. Claude Code runs in `--dangerously-skip-permissions` mode inside the container — safe because the container is the sandbox.
4. The PR directory is bind-mounted at `/tasks` inside the container (writable; outputs survive container exit). The project root is mounted read-only at `/workspace` so the agent can read `GUIDE.md`; the host's `tasks/` history is hidden behind a tmpfs so the agent can't read prior runs by accident. Your `~/.gitconfig` is bind-mounted so any in-container git activity is attributed to you.
5. Output streams through **`format-stream.py`** so you see thinking, tool calls, and responses in real time instead of raw JSON.

## Usage

### From a PR (the common case)

```bash
./run.sh --pr https://github.com/harbor-framework/terminal-bench-3/pull/330
```

The built-in prompt drives the full GUIDE.md review end-to-end. No customization needed. URL fragments (`#issuecomment-…`), query strings, and path suffixes (`/files`, `/commits`) are stripped automatically — paste copy-from-browser URLs without scrubbing.

After the run completes, the script also extracts the `## Issues Found` section from `review-summary.md` into a sibling `issues-found.md` (always, regardless of `--review`).

On exit, including errors and interrupts, `run.sh` prints the exit code, the task directory (if assigned), and the PR URL as its last line. Runs without `--pr` explicitly say no PR was supplied. The original exit code is preserved.

### Submit a review automatically

Add `--review` to post a `REQUEST_CHANGES` review to the PR after the analysis finishes. The review body is composed in this order, prefixed with a short preamble that explains the review is automated, asks the author to accept-or-reject each point, and links to the [task-quality guide](https://github.com/harbor-framework/terminal-bench-3/discussions/224) (see `PREAMBLE` in `run.sh` for the exact text):

0. **Agentic-task warning** (only if the agentic check failed) — a prominent blockquote at the top recommending the reviewer consider closing the PR rather than iterating on it. See [GUIDE.md → Agentic task check](GUIDE.md) for criteria.
1. `issues-found.md` (extracted from `## Issues Found`) — current-round blockers
2. `unaddressed-prior-feedback.md` (extracted from `## Unaddressed Prior Feedback`) — prior reviewer comments the author hasn't addressed yet (only if non-empty)
3. `natural-difficulty-extensions.md` (extracted from `## Natural Difficulty Extensions`) — forward-looking suggestions (only if non-empty)

```bash
./run.sh --review --pr https://github.com/harbor-framework/terminal-bench-3/pull/330
```

If `issues-found.md` is empty *and* the agentic check passed, no review is submitted. If the agentic check failed, the review posts even when there are no concrete issues — the close-PR recommendation is the body. The full `review-summary.md` stays on disk in the PR's task directory for reference but is not inlined into the review (avoids GitHub's body-size limit). Posts under the GitHub identity associated with your local `gh auth`.

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
| `jq` | JSON parsing for trial `result.json` / `ctrf.json` |
| `python3` | Available for in-container scripting (parsing, math, plotting) |
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
├── .env                # (gitignored) ANTHROPIC_API_KEY or CLAUDE_CODE_OAUTH_TOKEN
└── tasks/              # Created at runtime, gitignored
    ├── <owner>/<repo>/pr-<N>/        # PR mode: namespaced per PR, persists across runs
    │   ├── trajectory_analysis.md    # /run results comment       (pre-fetched)
    │   ├── cheat_results.md          # /cheat results comment     (pre-fetched)
    │   ├── pr-description.md         # PR body                    (pre-fetched)
    │   ├── pr-diff.patch             # full unified diff          (pre-fetched)
    │   ├── pr-comments.json          # all issue comments, raw    (pre-fetched)
    │   ├── pr-review-comments.json   # all inline review comments (pre-fetched)
    │   ├── pr-reviews.json           # review-level summaries     (pre-fetched)
    │   ├── pr-authors.txt            # PR opener + every commit author/committer (pre-fetched)
    │   ├── ci/                       # five sticky CI bot comments (pre-fetched)
    │   │   ├── static-checks.md
    │   │   ├── rubric-review.md
    │   │   ├── task-overview.md
    │   │   ├── task-validation.md
    │   │   └── pr-status.md
    │   ├── review-summary.md                 # written by the agent
    │   ├── agentic-check.md                   # auto-extracted from `## Agentic Task Check`
    │   ├── issues-found.md                    # auto-extracted from `## Issues Found`
    │   ├── unaddressed-prior-feedback.md      # auto-extracted from `## Unaddressed Prior Feedback`
    │   └── natural-difficulty-extensions.md   # auto-extracted from `## Natural Difficulty Extensions`
    └── run-YYYYMMDD-HHMMSS-PID/      # Custom-prompt mode (no --pr): timestamped
```

Re-running the same PR refreshes the pre-fetched snapshot in place. Outputs from earlier runs (e.g. `review-summary.md`, `issues-found.md`) survive unless the agent overwrites them.

## Output format

A typical `--pr` run looks roughly like:

```
Building container...
Task directory: /…/tasks/harbor-framework/terminal-bench-3/pr-330
Fetching PR metadata from harbor-framework/terminal-bench-3#330...
Pre-fetched inputs:
  ✓ trajectory_analysis.md       (207 lines)
  ✓ cheat_results.md             (117 lines)
  ✓ pr-description.md             (25 lines)
  ✓ pr-diff.patch              (1,615 lines)
  ✓ ci/static-checks.md           (18 lines)
  ✓ ci/rubric-review.md           (53 lines)
  ✓ ci/task-overview.md          (144 lines)
  ✓ ci/task-validation.md         (22 lines)
  ✓ ci/pr-status.md                (9 lines)
Running Claude in sandbox (cpus=14, mem=8g)...
[init] model=claude-sonnet-4-6 mode=bypassPermissions
💭 Let me start by reading GUIDE.md and the pre-fetched inputs.
[tool] Read: /workspace/GUIDE.md
[tool] Read: /tasks/trajectory_analysis.md
…
[tool] Write: /tasks/review-summary.md
[done] 46 turns, 733.2s, $2.0985
Extracted Issues Found section → /…/tasks/.../pr-330/issues-found.md

Run ended (exit code 0).
Task directory: /…/tasks/harbor-framework/terminal-bench-3/pr-330
PR: https://github.com/harbor-framework/terminal-bench-3/pull/330
```

With `--review`, the posted review URL appears before the final run reference:

```
Submitting REQUEST_CHANGES review to harbor-framework/terminal-bench-3#330...
Review posted: https://github.com/harbor-framework/terminal-bench-3/pull/330#pullrequestreview-...

Run ended (exit code 0).
Task directory: /…/tasks/harbor-framework/terminal-bench-3/pr-330
PR: https://github.com/harbor-framework/terminal-bench-3/pull/330
```

## Security notes

- The workspace is **read-only** — Claude cannot modify your files
- Claude writes only to `/tasks` (mapped to `tasks/<run-id>/`)
- Credentials are passed as environment variables, never baked into the image
- No `--privileged`, no Docker socket mount, no host network
- The `node` user (non-root) runs inside the container
