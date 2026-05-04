#!/usr/bin/env bash
# memory-aggregate.sh — SessionStart hook
# Emits a compact index of all per-cwd MEMORY.md files (excluding the current cwd)
# so cross-cwd memory becomes discoverable. Pure read; no side effects.

set -uo pipefail

# Always exit 0 — don't break session startup if anything goes wrong.
trap 'exit 0' ERR

input=$(cat 2>/dev/null || true)
current_cwd=$(printf '%s' "$input" | jq -r '.cwd // empty' 2>/dev/null || true)

projects_dir="$HOME/.claude/projects"
[ -d "$projects_dir" ] || exit 0

resolve_cwd() {
    local project_dir="$1"
    local latest
    latest=$(ls -t "$project_dir"/*.jsonl 2>/dev/null | head -1 || true)
    if [ -n "$latest" ]; then
        head -1 "$latest" 2>/dev/null | jq -r '.cwd // empty' 2>/dev/null || true
    fi
}

body=""
dir_count=0
entry_count_total=0

for memdir in "$projects_dir"/*/memory; do
    [ -d "$memdir" ] || continue
    memfile="$memdir/MEMORY.md"
    [ -f "$memfile" ] || continue

    project_dir="${memdir%/memory}"
    encoded="${project_dir##*/}"

    cwd=$(resolve_cwd "$project_dir")
    cwd="${cwd:-$encoded}"

    [ "$cwd" = "$current_cwd" ] && continue

    entries=$(grep '^- ' "$memfile" 2>/dev/null || true)
    [ -z "$entries" ] && continue
    entry_n=$(printf '%s\n' "$entries" | wc -l | tr -d ' ')

    dir_count=$((dir_count + 1))
    entry_count_total=$((entry_count_total + entry_n))

    body+="### \`$cwd\` ($entry_n entries) — \`$memfile\`"$'\n'
    body+="$entries"$'\n\n'
done

[ "$dir_count" -eq 0 ] && exit 0

cat <<EOF
<system-reminder>
# Cross-cwd memory index ($entry_count_total entries across $dir_count other cwds)

The current cwd's MEMORY.md is already auto-loaded. The block below indexes memory files from OTHER cwds you have worked in. Each pointer is a markdown file readable with the Read tool.

$body
## When to consult this index

- User references past work in another project ("remember when we did X in the other repo?")
- Current topic echoes a known memory entry from another cwd
- User asks cross-project questions ("which of my projects touched topic X?")

## When to ignore this index

- Current task is fully scoped to the active cwd
- No entry titles match the current topic

Do not speculate about cross-cwd memory contents — Read the source file when an entry looks relevant. Treat this as a reference card, not authoritative content.
</system-reminder>
EOF
