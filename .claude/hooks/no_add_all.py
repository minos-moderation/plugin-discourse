"""Claude Code PreToolUse hook (Bash): refuse staging the whole work tree.

The work tree may hold another session's uncommitted work, so the rules say never
`git add -A`: stage explicit paths. Refused, for `git add` and its alias `git stage`:

* `-A` (alone or in a cluster such as `-Av`), `--all`, `--no-ignore-removal`, and the
  abbreviations of `--all` git accepts (`--a`, `--al`);
* `-u` (alone or in a cluster) or `--update` (`--u`, `--up`…) WITHOUT a pathspec, which
  stages every tracked change; with one it stages no more than the pathspec;
* a pathspec naming the whole tree: `.`, `./`, `*`, `:`, `:/`, `:/*`, `:(top)` (also after
  `--`);

and `git commit -a` (also in a cluster such as `-am`, before any option that takes a value)
or `--all` (`--al`), which stages every tracked change before committing.

Only `git` in command position counts: the first word of a simple command, after variable
assignments, shell keywords and wrappers that run their arguments (`sudo`, `env`, `nice`,
`timeout`, `command`, `xargs`…); `git -C dir add .` too. The string of `bash -c`/`sh -c` and
the words of `eval` are read again. The command is split with `shlex`, so a quoted string
(a commit message, a grep pattern) is one word and never reads as `git add`, and the bodies
of here-documents are dropped first, as data. Input it cannot read passes: the hook must
never stop a session by itself.

Reads the hook's JSON on stdin; exit 2 with a message on stderr refuses, exit 0 lets it run.
"""

from __future__ import annotations

import json
import re
import shlex
import sys

#: git's global options that take the next word as their value.
_GIT_VALUE_OPTIONS = {"-C", "-c", "--git-dir", "--work-tree", "--namespace", "--config-env", "--exec-path"}

#: `git add` options that take the next word as their value.
_ADD_VALUE_OPTIONS = {"--pathspec-from-file", "--chmod"}

#: Long options of `git add` that stage everything.
_ADD_ALL = {"--all", "--a", "--al", "--no-ignore-removal"}

#: The abbreviations of `git add --update` git accepts.
_ADD_UPDATE = {"--u", "--up", "--upd", "--upda", "--updat", "--update"}

#: Short options of `git commit` that take a value: the rest of the cluster, or the next word
#: when the cluster ends with them.
_COMMIT_SHORT_VALUE = set("mFCct")

#: Short options of `git commit` whose optional value can only be attached (`-uno`, `-Skey`).
_COMMIT_SHORT_OPTIONAL = set("uS")

#: Long options of `git commit` whose value may be the next word.
_COMMIT_LONG_VALUE = {"--message", "--file", "--author", "--date", "--reuse-message", "--reedit-message",
                      "--fixup", "--squash", "--trailer", "--template", "--cleanup", "--pathspec-from-file"}

#: Pathspecs that name the whole tree.
_WHOLE_TREE = {".", "./", "*", ":", ":/", ":/*", ":/.", ":(top)", ":(top)."}

#: Words after which the next word is again in command position.
_KEYWORDS = {"!", "{", "(", "then", "do", "else", "elif", "if", "while", "until", "time"}

#: Commands that run their arguments as a command: `git` in any later word counts.
_WRAPPERS = {"sudo", "doas", "env", "nice", "ionice", "nohup", "setsid", "timeout", "command",
             "builtin", "exec", "xargs", "stdbuf", "flock", "chronic"}

#: Shells whose `-c` string is read again.
_SHELLS = {"bash", "sh", "zsh", "dash", "ksh"}

#: Tokens that end a simple command.
_SEPARATORS = {";", "&", "&&", "|", "||", "|&", "(", ")", ";;"}

_ASSIGNMENT = re.compile(r"[A-Za-z_][A-Za-z0-9_]*=")
_HEREDOC = re.compile(r"(?<!<)<<(?!<)-?\s*(['\"]?)([A-Za-z_][A-Za-z0-9_]*)\1")

MESSAGE = (
    "Refused by .claude/hooks/no-add-all.sh: `{command}` stages the whole work tree, or every "
    "tracked change in it, which may hold another session's uncommitted work. Stage explicit "
    "paths (`git add <path> ...`, then `git commit` without `-a`); the rule is in CLAUDE.md "
    "(never `git add -A`)."
)


def without_heredocs(command: str) -> str:
    """The command without the body lines of its here-documents, which are data."""
    lines = command.split("\n")
    kept: list[str] = []
    ends: list[str] = []
    for line in lines:
        if ends:
            if line.strip() == ends[0]:
                ends.pop(0)
            continue
        kept.append(line)
        ends.extend(match.group(2) for match in _HEREDOC.finditer(line))
    return "\n".join(kept)


def words(command: str) -> list[str] | None:
    """The command's words and operators, or None when it cannot be split."""
    # A newline ends a command like `;` does; a backslash before it joins the lines.
    text = without_heredocs(command).replace("\\\n", "").replace("\n", " ; ")
    lexer = shlex.shlex(text, posix=True, punctuation_chars=";&|()<>")
    lexer.whitespace_split = True
    try:
        return list(lexer)
    except ValueError:
        return None


def simple_commands(tokens: list[str]) -> list[list[str]]:
    """The tokens grouped into simple commands, split at every operator and newline."""
    commands: list[list[str]] = [[]]
    for token in tokens:
        if token in _SEPARATORS or (token and set(token) <= set(";&|()")):
            commands.append([])
        else:
            commands[-1].append(token)
    return [command for command in commands if command]


def stages_everything(arguments: list[str]) -> bool:
    """Whether the arguments of `git add` stage the whole tree, or every tracked change in it."""
    after_dashes = False
    skip = False
    update = False
    pathspec = False
    for argument in arguments:
        if skip:
            skip = False
            continue
        if after_dashes:
            if argument in _WHOLE_TREE:
                return True
            pathspec = True
            continue
        if argument == "--":
            after_dashes = True
        elif argument.startswith("--"):
            name = argument.split("=", 1)[0]
            if name in _ADD_ALL:
                return True
            update = update or name in _ADD_UPDATE
            pathspec = pathspec or name == "--pathspec-from-file"
            skip = name in _ADD_VALUE_OPTIONS and "=" not in argument
        elif argument.startswith("-") and len(argument) > 1:
            if "A" in argument[1:]:
                return True
            update = update or "u" in argument[1:]
        elif argument in _WHOLE_TREE:
            return True
        else:
            pathspec = True
    return update and not pathspec


def commits_everything(arguments: list[str]) -> bool:
    """Whether the arguments of `git commit` stage every tracked change (`-a`, `--all`)."""
    skip = False
    for argument in arguments:
        if skip:
            skip = False
            continue
        if argument == "--":
            return False
        if argument.startswith("--"):
            name = argument.split("=", 1)[0]
            if name in ("--al", "--all"):
                return True
            skip = name in _COMMIT_LONG_VALUE and "=" not in argument
        elif argument.startswith("-") and len(argument) > 1:
            cluster = argument[1:]
            for at, letter in enumerate(cluster):
                if letter == "a":
                    return True
                if letter in _COMMIT_SHORT_OPTIONAL:
                    break
                if letter in _COMMIT_SHORT_VALUE:
                    skip = at == len(cluster) - 1
                    break
    return False


def refused(command: str, depth: int = 0) -> bool:
    """Whether a shell command stages the whole tree with `git add` (`git stage`) or `git commit -a`."""
    tokens = words(command)
    if tokens is None or depth > 4:
        return False
    for simple in simple_commands(tokens):
        i = 0
        while i < len(simple) and (simple[i] in _KEYWORDS or _ASSIGNMENT.match(simple[i])):
            i += 1
        rest = simple[i:]
        if not rest:
            continue
        if rest[0] in _WRAPPERS:
            # `sudo -u x git add -A`, `env A=1 git add .`: the first `git` after the wrapper.
            if "git" in rest[1:]:
                rest = rest[rest.index("git", 1):]
            else:
                rest = []
        if not rest:
            continue
        name = rest[0].rsplit("/", 1)[-1]
        if name in _SHELLS and "-c" in rest[1:]:
            at = rest.index("-c", 1)
            if at + 1 < len(rest) and refused(rest[at + 1], depth + 1):
                return True
            continue
        if name == "eval":
            if refused(" ".join(rest[1:]), depth + 1):
                return True
            continue
        if name != "git":
            continue
        j = 1
        while j < len(rest) and rest[j].startswith("-"):
            j += 2 if rest[j] in _GIT_VALUE_OPTIONS else 1
        if j < len(rest) and rest[j] in ("add", "stage") and stages_everything(rest[j + 1:]):
            return True
        if j < len(rest) and rest[j] == "commit" and commits_everything(rest[j + 1:]):
            return True
    return False


def main() -> int:
    """Reads the hook's input and refuses (2) or lets the call run (0)."""
    try:
        payload = json.load(sys.stdin)
        command = payload["tool_input"]["command"]
    except (ValueError, KeyError, TypeError):
        return 0
    if not isinstance(command, str) or not refused(command):
        return 0
    shown = " ".join(command.split())
    print(MESSAGE.format(command=shown if len(shown) <= 120 else shown[:117] + "..."), file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main())
