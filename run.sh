#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
IMAGE_NAME="claude-sandbox"

# Parse arguments: extract --pr and --review flags; everything else is the prompt
PROMPT=""
PR_URL=""
SUBMIT_REVIEW=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --pr)
      PR_URL="$2"
      shift 2
      ;;
    --review)
      SUBMIT_REVIEW=1
      shift
      ;;
    *)
      PROMPT="$PROMPT $1"
      shift
      ;;
  esac
done
PROMPT="${PROMPT# }"  # trim leading space

# Parse PR identity early so the task directory and pre-fetch can both reuse it.
if [ -n "$PR_URL" ]; then
  # Strip URL fragments (#issuecomment-...) and query strings before splitting,
  # so a comment-anchored or files-tab URL doesn't pollute REPO / PR_NUMBER.
  PR_URL="${PR_URL%%#*}"
  PR_URL="${PR_URL%%\?*}"
  PR_PATH="${PR_URL#https://github.com/}"
  REPO="$(echo "$PR_PATH" | cut -d/ -f1-2)"
  PR_NUMBER="$(echo "$PR_PATH" | cut -d/ -f4)"
  # Belt: trim PR_NUMBER at the first non-digit, so path suffixes like
  # /files, /commits, or trailing slashes also can't leak in.
  PR_NUMBER="${PR_NUMBER%%[!0-9]*}"
fi

# Built-in prompt used when --pr is given with no explicit prompt. Drives the
# full GUIDE.md review end-to-end (rubric, bloat review, failure taxonomy from
# primary artifacts, full review-summary.md). Avoids rubber-stamping pre-fetched
# summaries.
DEFAULT_PROMPT="Full task review of this PR following GUIDE.md end-to-end. All pre-fetched inputs are in /tasks/ root (trajectory_analysis.md, cheat_results.md, pr-description.md, pr-diff.patch, ci/*.md). Download both rubrics (rubrics/task-implementation.toml and rubrics/trial-analysis.toml), the /run and /cheat trial artifacts, and the task files (instruction.md, task.toml, environment/, solution/, tests/). Apply the Instruction Bloat review from Step 3. Reconstruct the failure taxonomy from primary artifacts (per-trial result.json, ctrf.json, episode trajectories) rather than rubber-stamping pre-fetched summaries. Write /tasks/review-summary.md per the Step 5 template, including the Non-Expert Explainer. ultrathink."

if [ -z "$PROMPT" ]; then
  if [ -z "$PR_URL" ]; then
    echo "Usage: ./run.sh --pr <github-pr-url>"
    echo "       ./run.sh \"your prompt\" [--pr <github-pr-url>]"
    echo ""
    echo "  With --pr and no prompt, performs the full GUIDE.md task review."
    exit 1
  fi
  PROMPT="$DEFAULT_PROMPT"
  echo "No prompt given — using built-in full-review prompt."
fi

# Build the container if needed
echo "Building container..."
docker build -q -t "$IMAGE_NAME" "$SCRIPT_DIR" > /dev/null

# Task directory: when --pr is given, namespace under tasks/<owner>/<repo>/pr-<N>
# so concurrent runs against different PRs don't collide and outputs survive
# the container keyed by PR. The no-PR custom-prompt mode falls back to the
# legacy timestamped layout.
if [ -n "$PR_URL" ]; then
  TASKS_DIR="$SCRIPT_DIR/tasks/$REPO/pr-$PR_NUMBER"
else
  RUN_ID="run-$(date +%Y%m%d-%H%M%S)-$$"
  TASKS_DIR="$SCRIPT_DIR/tasks/$RUN_ID"
fi
mkdir -p "$TASKS_DIR"
echo "Task directory: $TASKS_DIR"

# If --pr was provided, pre-fetch all PR metadata the in-container analysis needs
if [ -n "$PR_URL" ]; then
  echo "Fetching PR metadata from $REPO#$PR_NUMBER..."
  mkdir -p "$TASKS_DIR/ci"

  # Cache the full issue-comments payload once so downstream jq filters are cheap
  COMMENTS_JSON="$TASKS_DIR/pr-comments.json"
  gh api "repos/$REPO/issues/$PR_NUMBER/comments" --paginate > "$COMMENTS_JSON" 2>/dev/null || echo '[]' > "$COMMENTS_JSON"

  # PR description, diff, inline review comments
  gh api "repos/$REPO/pulls/$PR_NUMBER" --jq '.body // ""' > "$TASKS_DIR/pr-description.md" 2>/dev/null || true
  gh api "repos/$REPO/pulls/$PR_NUMBER" -H "Accept: application/vnd.github.v3.diff" > "$TASKS_DIR/pr-diff.patch" 2>/dev/null || true
  gh api "repos/$REPO/pulls/$PR_NUMBER/comments" --paginate > "$TASKS_DIR/pr-review-comments.json" 2>/dev/null || echo '[]' > "$TASKS_DIR/pr-review-comments.json"

  # Sticky CI bot comments — identified by the sticky-pull-request-comment HTML marker
  for header in static-checks rubric-review task-overview task-validation pr-status; do
    gh api "repos/$REPO/issues/$PR_NUMBER/comments" --paginate \
      --jq "[.[] | select(.body | contains(\"<!-- Sticky Pull Request Comment${header} -->\"))] | last | .body // \"\"" \
      > "$TASKS_DIR/ci/${header}.md" 2>/dev/null || true
  done

  # /run results — Agent Trial Results, excluding the cheating variant
  gh api "repos/$REPO/issues/$PR_NUMBER/comments" --paginate \
    --jq '[.[] | select(.body | test("Agent Trial Results")) | select(.body | test("Cheating") | not)] | last | .body // ""' \
    > "$TASKS_DIR/trajectory_analysis.md" 2>/dev/null || true

  # /cheat results
  gh api "repos/$REPO/issues/$PR_NUMBER/comments" --paginate \
    --jq '[.[] | select(.body | test("Cheating Agent Trial Results"))] | last | .body // ""' \
    > "$TASKS_DIR/cheat_results.md" 2>/dev/null || true

  echo "Pre-fetched inputs:"
  for f in trajectory_analysis.md cheat_results.md pr-description.md pr-diff.patch \
           ci/static-checks.md ci/rubric-review.md ci/task-overview.md ci/task-validation.md ci/pr-status.md; do
    if [ -s "$TASKS_DIR/$f" ]; then
      printf "  ✓ %-28s (%s lines)\n" "$f" "$(wc -l < "$TASKS_DIR/$f" | tr -d ' ')"
    else
      printf "  · %-28s (empty)\n" "$f"
    fi
  done
fi

# CPU count (macOS)
CPUS="$(sysctl -n hw.ncpu 2>/dev/null || nproc)"

# Extract GitHub token from macOS keychain (gh stores it there, not in config files)
GH_TOKEN="$(gh auth token 2>/dev/null || true)"
if [ -z "$GH_TOKEN" ]; then
  echo "Warning: Could not retrieve GitHub token. gh will not be authenticated."
fi

# Claude API key: prefer .env file (long-lived), fall back to Keychain OAuth token (may expire)
if [ -f "$SCRIPT_DIR/.env" ]; then
  CLAUDE_TOKEN="$(grep '^ANTHROPIC_API_KEY=' "$SCRIPT_DIR/.env" | cut -d= -f2-)"
fi
if [ -z "$CLAUDE_TOKEN" ]; then
  CLAUDE_CREDS="$(security find-generic-password -s "Claude Code-credentials" -w 2>/dev/null || true)"
  if [ -n "$CLAUDE_CREDS" ]; then
    CLAUDE_TOKEN="$(echo "$CLAUDE_CREDS" | python3 -c "import sys,json; print(json.load(sys.stdin)['claudeAiOauth']['accessToken'])")"
  else
    echo "Error: No API key found. Add ANTHROPIC_API_KEY to .env or log in to Claude Code."
    exit 1
  fi
fi

echo "Running Claude in sandbox (cpus=$CPUS, mem=8g)..."
docker run --rm \
  --cpus="$CPUS" \
  --memory="8g" \
  --mount type=tmpfs,destination=/workspace/tasks \
  -e ANTHROPIC_API_KEY="$CLAUDE_TOKEN" \
  -e GH_TOKEN="$GH_TOKEN" \
  -v "$SCRIPT_DIR:/workspace:ro" \
  -v "$TASKS_DIR:/tasks:rw" \
  -v "$HOME/.claude.json:/home/node/.claude.json:ro" \
  -v "$HOME/.claude/settings.json:/home/node/.claude/settings.json:ro" \
  -v "$HOME/.claude/settings.local.json:/home/node/.claude/settings.local.json:ro" \
  -v "$HOME/.gitconfig:/home/node/.gitconfig:ro" \
  "$IMAGE_NAME" \
  -p --dangerously-skip-permissions --verbose --output-format stream-json "$PROMPT" \
  | python3 "$SCRIPT_DIR/format-stream.py"

# Post-process: if the agent wrote review-summary.md, extract the
# "## Issues Found" section verbatim into a sibling issues-found.md
# so it can be referenced or posted standalone.
if [ -s "$TASKS_DIR/review-summary.md" ]; then
  awk '
    /^## Issues Found/ { flag = 1 }
    /^## / && flag && !/^## Issues Found/ { exit }
    flag
  ' "$TASKS_DIR/review-summary.md" > "$TASKS_DIR/issues-found.md"
  if [ -s "$TASKS_DIR/issues-found.md" ]; then
    echo "Extracted Issues Found section → $TASKS_DIR/issues-found.md"
  else
    rm -f "$TASKS_DIR/issues-found.md"
  fi
fi

# If --review was passed, post a REQUEST_CHANGES review to the PR using
# issues-found.md as the body. The full review-summary.md is intentionally
# not inlined — it stays on disk for reference and avoids GitHub's review
# body size limit.
if [ "$SUBMIT_REVIEW" = "1" ]; then
  if [ -z "$PR_URL" ]; then
    echo "--review requires --pr; skipping review submission."
  elif [ ! -s "$TASKS_DIR/issues-found.md" ]; then
    echo "--review: issues-found.md is empty or missing; skipping review submission."
  else
    echo "Submitting REQUEST_CHANGES review to $REPO#$PR_NUMBER..."

    PREAMBLE="This is an automatic review. The author might disagree with some of the feedback."
    ISSUES="$(cat "$TASKS_DIR/issues-found.md")"
    BODY="$PREAMBLE

$ISSUES"

    if REVIEW_URL=$(gh api "repos/$REPO/pulls/$PR_NUMBER/reviews" \
        --method POST \
        -f event="REQUEST_CHANGES" \
        -f body="$BODY" \
        --jq '.html_url' 2>&1); then
      echo "Review posted: $REVIEW_URL"
    else
      echo "Warning: review submission failed: $REVIEW_URL"
    fi
  fi
fi
