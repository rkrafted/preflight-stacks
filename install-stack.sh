#!/usr/bin/env bash
# One command (or one double-click on Linux) to install a Preflight mod stack.
#
#   1. plan the stack against the installed build (exit 3 = blocked)
#   2. install the GitHub frameworks (0 Nexus clicks, undoable)
#   3. walk the Nexus queue: one page, one click per file, then Vortex takes over
#
# Usage: ./install-stack.sh [stack.yaml] [game-dir]
#   PREFLIGHT=/path/to/preflight   override the binary
#   DOWNLOADS=/path/to/folder      override the watched downloads folder
#   PLAN_ONLY=1                    stop after the plan
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)

find_preflight() {
  if [ -n "${PREFLIGHT:-}" ]; then printf '%s\n' "$PREFLIGHT"; return; fi
  for candidate in "$here/preflight" "$here/../preflight/target/release/preflight" "$here/../preflight/target/debug/preflight"; do
    if [ -x "$candidate" ]; then printf '%s\n' "$candidate"; return; fi
  done
  if command -v preflight >/dev/null 2>&1; then command -v preflight; return; fi
  echo "preflight binary not found: build it (cargo build --release -p preflight-cli) or set PREFLIGHT=" >&2
  exit 2
}

find_game() {
  local given="${1:-}"
  if [ -n "$given" ]; then printf '%s\n' "$given"; return; fi
  if [ -n "${PREFLIGHT_GAME:-}" ]; then printf '%s\n' "$PREFLIGHT_GAME"; return; fi
  for candidate in \
    "$HOME/.steam/steam/steamapps/common/Cyberpunk 2077" \
    "$HOME/.local/share/Steam/steamapps/common/Cyberpunk 2077"; do
    if [ -x "$candidate/bin/x64/Cyberpunk2077.exe" ]; then printf '%s\n' "$candidate"; return; fi
  done
  read -r -p "Game folder (the one containing bin/x64): " answer
  printf '%s\n' "$answer"
}

find_stack() {
  local given="${1:-}"
  if [ -n "$given" ]; then printf '%s\n' "$given"; return; fi
  local -a stacks=()
  while IFS= read -r file; do stacks+=("$file"); done < <(find "$here/stacks" -maxdepth 1 -name '*.yaml' ! -name '*.example.yaml' | sort)
  if [ ${#stacks[@]} -eq 1 ]; then printf '%s\n' "${stacks[0]}"; return; fi
  printf 'Stacks:\n' >&2
  local i=1
  for file in "${stacks[@]}"; do printf '  %d. %s\n' "$i" "$(basename "$file")" >&2; i=$((i+1)); done
  read -r -p "Pick one [1]: " choice
  choice=${choice:-1}
  printf '%s\n' "${stacks[$((choice-1))]}"
}

find_downloads() {
  if [ -n "${DOWNLOADS:-}" ]; then printf '%s\n' "$DOWNLOADS"; return; fi
  for candidate in \
    "$HOME/.config/Vortex/downloads/cyberpunk2077" \
    "$HOME/.local/share/Vortex/downloads/cyberpunk2077" \
    "$HOME/Downloads"; do
    if [ -d "$candidate" ]; then printf '%s\n' "$candidate"; return; fi
  done
  printf '%s\n' "$HOME/Downloads"
}

# Use a locally built rules bundle when the project ships one; otherwise rely on the state dir.
rules_args=()
local_rules=$(ls -t "$here"/../preflight-rules/dist/rules-*.json 2>/dev/null | head -1 || true)
if [ -n "$local_rules" ] && [ -f "$local_rules.sig" ]; then
  rules_args=(--rules "$local_rules")
fi

preflight=$(find_preflight)
game=$(find_game "${2:-}")
stack=$(find_stack "${1:-}")
downloads=$(find_downloads)

printf '\npreflight : %s\ngame      : %s\nstack     : %s\ndownloads : %s\n\n' "$preflight" "$game" "$stack" "$downloads"

set +e
"$preflight" stack plan "$stack" --game "$game" "${rules_args[@]}"
status=$?
set -e
if [ "$status" -eq 3 ]; then
  printf '\nThis stack does not fit the installed build (see BLOCKED above). Nothing was changed.\n'
  exit 3
fi
[ "$status" -eq 0 ] || exit "$status"

if [ "${PLAN_ONLY:-}" = "1" ]; then exit 0; fi

printf '\nInstalling the public frameworks (0 Nexus clicks, undoable)...\n'
"$preflight" install core --game "$game" "${rules_args[@]}" --apply

printf '\nWalk the Nexus queue: each page opens once, click "Mod manager download".\n'
exec "$preflight" stack run "$stack" --downloads "$downloads"
