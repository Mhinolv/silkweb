#!/bin/sh
# Regenerates the client SKILL.md copies in agent-packages/ from the one canonical workflow,
# agent-packages/shared/silkweb-memory.md (#138). Each copy is the client frontmatter below followed
# by the shared file byte for byte; AgentPackagesTests fails when a copy drifts.
# Usage: scripts/agent_packages.sh [--check]
#   (no args)  rewrite the copies
#   --check    exit 0 when every copy matches, 1 when one drifted, 2 on a bad argument
set -e
cd "$(dirname "$0")/.."
case "$1" in
  "" | --check) ;;
  *) echo "usage: scripts/agent_packages.sh [--check]" >&2; exit 2 ;;
esac
if [ $# -gt 1 ]; then echo "usage: scripts/agent_packages.sh [--check]" >&2; exit 2; fi

SHARED=agent-packages/shared/silkweb-memory.md
DESCRIPTION="Recall and save this project's memory in Silkweb. Use before substantial work, and at milestones, plan changes, blockers and handoffs."
COPIES="agent-packages/claude/skills/silkweb-memory/SKILL.md
agent-packages/codex/skills/silkweb-memory/SKILL.md
agent-packages/gemini/silkweb-memory/skills/silkweb-memory/SKILL.md"

render() {
  printf -- '---\nname: silkweb-memory\ndescription: %s\n---\n\n' "$DESCRIPTION"
  cat "$SHARED"
}

drifted=0
for copy in $COPIES; do
  if [ "$1" = "--check" ]; then
    if ! render | cmp -s - "$copy"; then
      echo "drifted: $copy" >&2
      drifted=1
    fi
  else
    mkdir -p "$(dirname "$copy")"
    render > "$copy.tmp"
    mv "$copy.tmp" "$copy"
    echo "wrote $copy"
  fi
done
if [ "$drifted" -ne 0 ]; then
  echo "Skill copies drifted — run ./scripts/agent_packages.sh and commit the result." >&2
  exit 1
fi
[ "$1" = "--check" ] && echo "Skill copies match $SHARED."
exit 0
