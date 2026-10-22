#!/bin/zsh
# Install the same portable feedback skill for either coding agent.
set -euo pipefail
cd "$(dirname "$0")/.."

agent="${1:-}"
if [[ "$agent" == "--help" || "$agent" == "-h" || -z "$agent" ]]; then
  echo 'Usage: scripts/install-skill.sh codex|claude-code|both [--dest <skill-folder>]'
  echo 'Codex: ~/.agents/skills/feedback; Claude Code: ~/.claude/skills/feedback'
  [[ -n "$agent" ]] && exit 0 || exit 2
fi
shift
custom_destination=""
if (( $# )); then
  if [[ $# != 2 || "$1" != "--dest" || "$agent" == "both" ]]; then
    echo 'Use --dest <skill-folder> with one agent only.' >&2
    exit 2
  fi
  custom_destination="$2"
fi

install_for() {
  local target="$1" destination="$2"
  [[ -n "$custom_destination" ]] && destination="$custom_destination"
  mkdir -p "$destination"
  cp skill/SKILL.md skill/session_tail.py "$destination/"
  chmod +x "$destination/session_tail.py"
  echo "Installed feedback for $target: $destination"
}

case "$agent" in
  codex) install_for Codex "$HOME/.agents/skills/feedback" ;;
  claude-code) install_for 'Claude Code' "$HOME/.claude/skills/feedback" ;;
  both)
    install_for Codex "$HOME/.agents/skills/feedback"
    install_for 'Claude Code' "$HOME/.claude/skills/feedback"
    ;;
  *) echo "Unknown agent: $agent" >&2; exit 2 ;;
esac
