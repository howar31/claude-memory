#!/usr/bin/env bash
# claude-memory setup — idempotent installer for memory hooks.
#
# Symlinks repo hook files into ~/.claude/hooks/, patches ~/.claude/settings.json
# to wire SessionStart / PreCompact / SessionEnd, and creates ~/.claude/system/memory.
#
# Safe to re-run. Backs up before any destructive action. Verifies after install.
#
# Flags:
#   --dry-run   Show what would happen, don't apply
#   --force     Replace existing real files at ~/.claude/hooks/memory-*
#               (settings.json conflicts always stop — fix manually)
#   -h, --help  Show this help

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOK_FILES=("memory-aggregate.sh" "memory-checkpoint.sh" "memory-checkpoint-prompt.txt")
CLAUDE_HOOKS_DIR="$HOME/.claude/hooks"
SETTINGS="$HOME/.claude/settings.json"
SYSTEM_LINK="$HOME/.claude/system/memory"
TIMESTAMP="$(date +%Y%m%d-%H%M%S)"

SETTINGS_HOOKS=(
  "SessionStart|.*|bash ~/.claude/hooks/memory-aggregate.sh"
  "PreCompact|.*|bash ~/.claude/hooks/memory-checkpoint.sh"
  "SessionEnd|.*|bash ~/.claude/hooks/memory-checkpoint.sh"
)

DRY_RUN=0
FORCE=0
for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY_RUN=1 ;;
    --force)   FORCE=1 ;;
    -h|--help)
      sed -n '2,16p' "$0" | sed 's/^# \?//'
      exit 0
      ;;
    *) echo "Unknown flag: $arg" >&2; exit 2 ;;
  esac
done

if [ -t 1 ]; then
  C_OK=$'\033[0;32m'; C_ERR=$'\033[0;31m'; C_WARN=$'\033[0;33m'; C_DIM=$'\033[0;90m'; C_RST=$'\033[0m'
else
  C_OK=""; C_ERR=""; C_WARN=""; C_DIM=""; C_RST=""
fi

ok()    { printf '  %sok%s   %s\n'   "$C_OK"   "$C_RST" "$*"; }
warn()  { printf '  %swarn%s %s\n'   "$C_WARN" "$C_RST" "$*"; }
err()   { printf '  %serr%s  %s\n'   "$C_ERR"  "$C_RST" "$*" >&2; }
note()  { printf '  %s··%s   %s\n'   "$C_DIM"  "$C_RST" "$*"; }
header(){ printf '\n=== %s ===\n' "$*"; }

run() {
  if [ "$DRY_RUN" -eq 1 ]; then
    printf '  %s[dry-run]%s would: %s\n' "$C_DIM" "$C_RST" "$*"
  else
    eval "$@"
  fi
}

# --- Tool dependency check ---
header "Tool dependencies"
missing=0
for cmd in jq bash; do
  if command -v "$cmd" >/dev/null 2>&1; then ok "$cmd"; else err "$cmd missing"; missing=1; fi
done
[ "$missing" -eq 1 ] && { err "Install missing dependencies and re-run"; exit 1; }

# --- Phase 1: install hook files (symlinks) ---
header "Phase 1 — install hook files"
mkdir -p "$CLAUDE_HOOKS_DIR"
backup_dir="$CLAUDE_HOOKS_DIR/.bak/$TIMESTAMP"

for f in "${HOOK_FILES[@]}"; do
  src="$SCRIPT_DIR/hooks/$f"
  dst="$CLAUDE_HOOKS_DIR/$f"

  [ -f "$src" ] || { err "Source missing: $src"; exit 1; }

  if [ -L "$dst" ]; then
    actual="$(readlink "$dst")"
    if [ "$actual" = "$src" ]; then
      ok "$f symlink already correct"
    elif [ "$FORCE" -eq 1 ]; then
      run "rm '$dst' && ln -s '$src' '$dst'"
      ok "$f relinked (was: $actual)"
    else
      err "$f symlink points elsewhere: $actual"
      err "  use --force to relink"
      exit 1
    fi
  elif [ -e "$dst" ]; then
    if cmp -s "$src" "$dst"; then
      run "mkdir -p '$backup_dir' && mv '$dst' '$backup_dir/$f' && ln -s '$src' '$dst'"
      ok "$f real file matched repo, symlinked (backup: $backup_dir/$f)"
    elif [ "$FORCE" -eq 1 ]; then
      run "mkdir -p '$backup_dir' && mv '$dst' '$backup_dir/$f' && ln -s '$src' '$dst'"
      ok "$f real file differed, symlinked (backup: $backup_dir/$f)"
    else
      err "$f real file differs from repo"
      err "  diff:"
      diff "$dst" "$src" | sed 's/^/    /' | head -20 >&2
      err "  use --force to backup-and-replace"
      exit 1
    fi
  else
    run "ln -s '$src' '$dst'"
    ok "$f symlinked (fresh)"
  fi
done

# --- Phase 2: patch settings.json ---
header "Phase 2 — wire settings.json"

[ -f "$SETTINGS" ] || { err "settings.json missing: $SETTINGS"; err "Run Claude Code at least once first"; exit 1; }
jq . "$SETTINGS" >/dev/null 2>&1 || { err "settings.json is malformed"; exit 1; }

settings_backup="$SETTINGS.bak.$TIMESTAMP"
run "cp '$SETTINGS' '$settings_backup'"
note "Backup: $settings_backup"

settings_changed=0
for entry in "${SETTINGS_HOOKS[@]}"; do
  IFS='|' read -r event matcher cmd <<< "$entry"

  exists=$(jq --arg ev "$event" --arg cmd "$cmd" \
    '[(.hooks[$ev] // [])[].hooks[]? | select(.command == $cmd)] | length' \
    "$SETTINGS")

  if [ "$exists" -gt 0 ]; then
    ok "$event hook already wired"
    continue
  fi

  conflict=$(jq --arg ev "$event" \
    '[(.hooks[$ev] // [])[].hooks[]? | select((.command // "") | test("memory-(aggregate|checkpoint)\\.sh"))] | length' \
    "$SETTINGS")

  if [ "$conflict" -gt 0 ]; then
    err "$event has memory-* hook with different command:"
    jq --arg ev "$event" \
      '(.hooks[$ev] // [])[].hooks[]? | select((.command // "") | test("memory-")) | "    \(.command)"' \
      -r "$SETTINGS" >&2
    err "  expected: $cmd"
    err "  edit settings.json manually then re-run (--force does not apply here)"
    exit 1
  fi

  if [ "$DRY_RUN" -eq 1 ]; then
    note "[dry-run] would add $event matcher='$matcher' command='$cmd'"
    continue
  fi

  tmp="$SETTINGS.tmp.$$"
  jq --arg ev "$event" --arg matcher "$matcher" --arg cmd "$cmd" '
    .hooks //= {} |
    .hooks[$ev] //= [] |
    if (.hooks[$ev] | map(.matcher == $matcher) | any) then
      .hooks[$ev] |= map(
        if .matcher == $matcher then
          .hooks += [{type: "command", command: $cmd}]
        else . end
      )
    else
      .hooks[$ev] += [{matcher: $matcher, hooks: [{type: "command", command: $cmd}]}]
    end
  ' "$SETTINGS" > "$tmp" && mv "$tmp" "$SETTINGS"

  ok "$event hook added"
  settings_changed=1
done

if ! jq . "$SETTINGS" >/dev/null 2>&1; then
  err "settings.json corrupted after patch — restoring backup"
  cp "$settings_backup" "$SETTINGS"
  exit 1
fi

[ "$settings_changed" -eq 0 ] && note "settings.json unchanged"

# --- Phase 3: backwards-compat symlink ---
header "Phase 3 — system link"
mkdir -p "$HOME/.claude/system"
if [ -L "$SYSTEM_LINK" ]; then
  if [ "$(readlink "$SYSTEM_LINK")" = "$SCRIPT_DIR" ]; then
    ok "$SYSTEM_LINK already correct"
  elif [ "$FORCE" -eq 1 ]; then
    run "rm '$SYSTEM_LINK' && ln -s '$SCRIPT_DIR' '$SYSTEM_LINK'"
    ok "$SYSTEM_LINK relinked"
  else
    err "$SYSTEM_LINK points elsewhere: $(readlink "$SYSTEM_LINK")"
    err "  use --force to relink"
  fi
elif [ -e "$SYSTEM_LINK" ]; then
  err "$SYSTEM_LINK exists as real path; refusing to clobber"
else
  run "ln -s '$SCRIPT_DIR' '$SYSTEM_LINK'"
  ok "$SYSTEM_LINK linked → $SCRIPT_DIR"
fi

# --- Phase 4: verify ---
header "Phase 4 — verify"
fail=0

verify_link() {
  local f="$1"; local label="$2"
  local path="$CLAUDE_HOOKS_DIR/$f"
  if [ ! -L "$path" ]; then err "$label: $path not a symlink"; fail=1; return; fi
  local target; target="$(readlink "$path")"
  if [ "$target" != "$SCRIPT_DIR/hooks/$f" ]; then
    err "$label: symlink → $target (expected repo)"; fail=1; return
  fi
  ok "$label symlink → repo"
}

verify_link "memory-aggregate.sh"          "Layer 1 file"
verify_link "memory-checkpoint.sh"         "Layer 2 file"
verify_link "memory-checkpoint-prompt.txt" "Layer 2 prompt"

if smoke=$(echo '{"cwd":"/__verify__","session_id":"v"}' | bash "$CLAUDE_HOOKS_DIR/memory-aggregate.sh" 2>&1); then
  if [ -z "$smoke" ]; then
    note "Layer 1 smoke: empty output (no other-cwd memories yet — expected on fresh machine)"
  elif echo "$smoke" | grep -q "Cross-cwd memory index"; then
    ok "Layer 1 smoke: header emitted"
  else
    err "Layer 1 smoke: unexpected output"; fail=1
  fi
else
  err "Layer 1 smoke: script failed"; fail=1
fi

if smoke=$(echo '{}' | bash "$CLAUDE_HOOKS_DIR/memory-checkpoint.sh" 2>&1); then
  if echo "$smoke" | grep -q "Memory checkpoint"; then
    ok "Layer 2 smoke: prompt emitted"
  else
    err "Layer 2 smoke: prompt sentinel missing"; fail=1
  fi
else
  err "Layer 2 smoke: script failed"; fail=1
fi

for entry in "${SETTINGS_HOOKS[@]}"; do
  IFS='|' read -r event _ cmd <<< "$entry"
  count=$(jq --arg ev "$event" --arg cmd "$cmd" \
    '[(.hooks[$ev] // [])[].hooks[]? | select(.command == $cmd)] | length' \
    "$SETTINGS")
  if [ "$count" -gt 0 ]; then
    ok "settings.json: $event wired"
  else
    err "settings.json: $event NOT wired"; fail=1
  fi
done

# --- Summary ---
header "Summary"
if [ "$fail" -eq 0 ]; then
  printf '  %sAll checks passed.%s Memory system fully operational.\n\n' "$C_OK" "$C_RST"
  printf '  Restart Claude Code to load the SessionStart hook.\n'
  exit 0
else
  printf '  %sVerification failed.%s See errors above.\n' "$C_ERR" "$C_RST"
  exit 1
fi
