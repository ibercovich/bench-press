#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
IMAGE_NAME="claude-sandbox"

# Build the container if needed
echo "Building container..."
docker build -q -t "$IMAGE_NAME" "$SCRIPT_DIR" > /dev/null

if [ $# -eq 0 ]; then
  echo "Usage: ./run.sh \"your prompt here\""
  exit 1
fi

PROMPT="$*"

# Unique task directory for this container run
RUN_ID="run-$(date +%Y%m%d-%H%M%S)-$$"
TASKS_DIR="$SCRIPT_DIR/tasks/$RUN_ID"
mkdir -p "$TASKS_DIR"
echo "Task directory: $TASKS_DIR"

# CPU count (macOS)
CPUS="$(sysctl -n hw.ncpu 2>/dev/null || nproc)"

# Extract GitHub token from macOS keychain (gh stores it there, not in config files)
GH_TOKEN="$(gh auth token 2>/dev/null || true)"
if [ -z "$GH_TOKEN" ]; then
  echo "Warning: Could not retrieve GitHub token. gh will not be authenticated."
fi

# Extract Claude OAuth token from macOS keychain
CLAUDE_CREDS="$(security find-generic-password -s "Claude Code-credentials" -w 2>/dev/null || true)"
if [ -n "$CLAUDE_CREDS" ]; then
  CLAUDE_TOKEN="$(echo "$CLAUDE_CREDS" | python3 -c "import sys,json; print(json.load(sys.stdin)['claudeAiOauth']['accessToken'])")"
else
  echo "Error: Could not retrieve Claude credentials from keychain."
  exit 1
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
