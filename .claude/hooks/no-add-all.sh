#!/usr/bin/env bash
# Claude Code PreToolUse hook on Bash: refuses `git add -A`, `git add --all`, `git add .`,
# `git add -u` without a path and `git commit -a` (and their equivalents, which
# no_add_all.py beside this file lists), because the work tree
# may hold another session's uncommitted work: stage explicit paths (CLAUDE.md). Exit 2
# refuses the call, with the reason on stderr for the session.
#
# The parsing is Python 3 (stdlib). Without a Python 3 that runs the parser, or when it
# fails, the hook lets the call through: it must never stop a session by itself, and the
# rule in CLAUDE.md still holds. The same files serve every minos-moderation repository.
set -u
here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd) || exit 0
[ -f "$here/no_add_all.py" ] || exit 0
command -v python3 > /dev/null 2>&1 || exit 0
python3 -I "$here/no_add_all.py"
[ "$?" -eq 2 ] && exit 2
exit 0
