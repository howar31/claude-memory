#!/usr/bin/env bash
# memory-checkpoint.sh — emits the memory-audit prompt as additional context.
# Used by PreCompact and SessionEnd hooks.
# Pure read; never blocks the action; exits 0 on any error.

set -uo pipefail
trap 'exit 0' ERR

# Consume stdin (hook event JSON) — not used, but be polite to the hook contract.
cat 2>/dev/null > /dev/null || true

prompt_file="$HOME/.claude/hooks/memory-checkpoint-prompt.txt"
[ -f "$prompt_file" ] || exit 0

cat "$prompt_file"
