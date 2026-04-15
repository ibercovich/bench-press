#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
IMAGE_NAME="claude-sandbox"

# Parse arguments: extract --pr flag, everything else is the prompt
PROMPT=""
PR_URL=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --pr)
      PR_URL="$2"
      shift 2
      ;;
    *)
      PROMPT="$PROMPT $1"
      shift
      ;;
  esac
done
PROMPT="${PROMPT# }"  # trim leading space

if [ -z "$PROMPT" ]; then
  echo "Usage: ./run.sh \"your prompt here\" [--pr <github-pr-url>]"
  exit 1
fi

# Build the container if needed
echo "Building container..."
docker build -q -t "$IMAGE_NAME" "$SCRIPT_DIR" > /dev/null

# Unique task directory for this container run
RUN_ID="run-$(date +%Y%m%d-%H%M%S)-$$"
TASKS_DIR="$SCRIPT_DIR/tasks/$RUN_ID"
mkdir -p "$TASKS_DIR"
echo "Task directory: $TASKS_DIR"

# If --pr was provided, extract the last "Agent Trial Results" comment
if [ -n "$PR_URL" ]; then
  # Parse owner/repo and PR number from URL
  # Handles: https://github.com/owner/repo/pull/123
  PR_PATH="${PR_URL#https://github.com/}"
  REPO="$(echo "$PR_PATH" | cut -d/ -f1-2)"
  PR_NUMBER="$(echo "$PR_PATH" | cut -d/ -f4)"

  echo "Fetching last Agent Trial Results from $REPO#$PR_NUMBER..."
  COMMENT_BODY="$(gh api "repos/$REPO/issues/$PR_NUMBER/comments" \
    --paginate \
    --jq '[.[] | select(.body | test("🧪 Agent Trial Results"))] | last | .body' 2>/dev/null || true)"

  if [ -n "$COMMENT_BODY" ]; then
    echo "$COMMENT_BODY" > "$TASKS_DIR/trajectory_analysis.md"
    echo "Saved trajectory_analysis.md ($(wc -l < "$TASKS_DIR/trajectory_analysis.md") lines)"
  else
    echo "Warning: No 'Agent Trial Results' comment found in $REPO#$PR_NUMBER"
  fi
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
